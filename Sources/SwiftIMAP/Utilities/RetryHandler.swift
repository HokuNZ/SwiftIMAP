import Foundation

/// Handles retry logic with exponential backoff and jitter
actor RetryHandler {
    private let configuration: RetryConfiguration
    private let logger: Logger
    
    init(configuration: RetryConfiguration, logger: Logger) {
        self.configuration = configuration
        self.logger = logger
    }
    
    /// Execute an operation with retry logic
    func execute<T>(
        operation: String,
        work: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 1...configuration.maxAttempts {
            do {
                logger.debug("[\(operation)] Attempt \(attempt) of \(configuration.maxAttempts)")
                return try await work()
            } catch {
                lastError = error
                
                // Check if error is retryable
                let isRetryable = isRetryableError(error)
                
                if !isRetryable {
                    logger.error("[\(operation)] Non-retryable error: \(error)")
                    throw error
                }
                
                if attempt == configuration.maxAttempts {
                    logger.error("[\(operation)] Max attempts reached. Last error: \(error)")
                    break
                }
                
                // Calculate delay with exponential backoff and jitter
                let delay = calculateDelay(for: attempt)
                logger.warning("[\(operation)] Attempt \(attempt) failed: \(error). Retrying in \(String(format: "%.2f", delay))s...")
                
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        throw lastError ?? IMAPError.connectionError("Operation failed after \(configuration.maxAttempts) attempts")
    }
    
    /// Execute an operation that might need reconnection
    func executeWithReconnect<T>(
        operation: String,
        needsReconnect: @Sendable (Error) -> Bool,
        reconnect: @Sendable () async throws -> Void,
        work: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 1...configuration.maxAttempts {
            do {
                logger.debug("[\(operation)] Attempt \(attempt) of \(configuration.maxAttempts)")
                return try await work()
            } catch {
                // The error under consideration. If reconnection is attempted and
                // itself fails, this becomes the reconnect error so the retryability
                // check and the thrown/recorded error stay consistent rather than
                // diverging from the original work() error.
                var currentError = error
                lastError = currentError

                // Check if we need to reconnect
                if needsReconnect(currentError) && attempt < configuration.maxAttempts {
                    logger.warning("[\(operation)] Connection lost. Attempting to reconnect...")
                    do {
                        try await reconnect()
                        logger.info("[\(operation)] Reconnected successfully")
                        // Continue to next attempt without delay
                        continue
                    } catch let reconnectError {
                        logger.error("[\(operation)] Reconnection failed: \(reconnectError)")
                        currentError = reconnectError
                        lastError = reconnectError
                    }
                }

                // Check if error is retryable
                let isRetryable = isRetryableError(currentError)

                if !isRetryable {
                    logger.error("[\(operation)] Non-retryable error: \(currentError)")
                    throw currentError
                }

                if attempt == configuration.maxAttempts {
                    logger.error("[\(operation)] Max attempts reached. Last error: \(currentError)")
                    break
                }

                // Calculate delay with exponential backoff and jitter
                let delay = calculateDelay(for: attempt)
                logger.warning("[\(operation)] Attempt \(attempt) failed: \(currentError). Retrying in \(String(format: "%.2f", delay))s...")

                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        throw lastError ?? IMAPError.connectionError("Operation failed after \(configuration.maxAttempts) attempts")
    }
    
    private func calculateDelay(for attempt: Int) -> TimeInterval {
        // Calculate base delay with exponential backoff
        let baseDelay = configuration.initialDelay * pow(configuration.multiplier, Double(attempt - 1))
        
        // Apply max delay cap
        let cappedDelay = min(baseDelay, configuration.maxDelay)
        
        // Add jitter (random variation)
        let jitterRange = cappedDelay * configuration.jitter
        let jitter = Double.random(in: -jitterRange...jitterRange)
        
        return max(0, cappedDelay + jitter)
    }
    
    private func isRetryableError(_ error: Error) -> Bool {
        // Check for specific IMAP errors
        if let imapError = error as? IMAPError {
            switch imapError {
            case .connectionClosed(let response):
                guard configuration.retryableErrors.contains(.connectionLost) else { return false }
                // A `BYE` that names a definitive condition (or any typed code) is the
                // server actively rejecting us — e.g. a `* BYE` greeting — so retrying
                // is pointless. Retry only a bare closure (no response) or a BYE that
                // names a transient condition like `[UNAVAILABLE]`.
                if let response { return RetryHandler.isTransientServerResponse(response) }
                return true
            case .connectionError, .connectionFailed:
                return configuration.retryableErrors.contains(.connectionLost)
            case .timeout:
                return configuration.retryableErrors.contains(.timeout)
            case .serverError(let message):
                return RetryHandler.isTransientText(message)
                    && configuration.retryableErrors.contains(.temporaryFailure)
            case .commandFailed(let response):
                // Only NO completions can be transient; BAD is a client bug and BYE
                // is terminal. Classify on the typed response code where present,
                // falling back to the server's text for servers that omit codes.
                guard response.status == .no else { return false }
                return RetryHandler.isTransientServerResponse(response)
                    && configuration.retryableErrors.contains(.temporaryFailure)
            default:
                return false
            }
        }
        
        // Check for network errors
        let errorDescription = error.localizedDescription.lowercased()
        if errorDescription.contains("network") || 
           errorDescription.contains("connection") ||
           errorDescription.contains("timed out") {
            return configuration.retryableErrors.contains(.networkError)
        }
        
        if errorDescription.contains("tls") || 
           errorDescription.contains("handshake") ||
           errorDescription.contains("certificate") {
            return configuration.retryableErrors.contains(.tlsHandshakeFailure)
        }
        
        return false
    }

    /// Whether free-form server text names a transient condition.
    private static func isTransientText(_ text: String) -> Bool {
        let transient = ["UNAVAILABLE", "TRY AGAIN", "TEMPORARY", "BUSY"]
        let upper = text.uppercased()
        return transient.contains { upper.contains($0) }
    }

    /// Whether a `NO` server response indicates a transient, retryable condition.
    /// Prefers the typed response code (`[UNAVAILABLE]`, `[INUSE]`, `[SERVERBUG]`),
    /// and falls back to the response text only for servers that omit a code.
    private static func isTransientServerResponse(_ response: IMAPServerResponse) -> Bool {
        // UNAVAILABLE, INUSE, and SERVERBUG are RFC 5530 codes with no typed case in
        // IMAPResponse.ResponseCode, so they always arrive as `.other`. If a named
        // case is ever added for one of these, add it to this check too.
        let transientCodes: Set<String> = ["UNAVAILABLE", "INUSE", "SERVERBUG"]
        // A code, when present, is authoritative: a definitive code like
        // `[NONEXISTENT]` must not be retried just because the free text happens to
        // contain words like "try again". Only consult the text when no code is sent.
        if let code = response.code {
            if case .other(let name, _) = code {
                return transientCodes.contains(name.uppercased())
            }
            return false
        }
        if let text = response.text {
            return isTransientText(text)
        }
        return false
    }
}

// MARK: - Error Classification

extension IMAPError {
    /// Determines if the error indicates a lost connection that requires reconnection
    var requiresReconnection: Bool {
        switch self {
        case .connectionError, .connectionClosed, .connectionFailed:
            return true
        case .serverError(let message):
            // Some server errors indicate connection issues
            let connectionErrors = ["BYE", "DISCONNECTED", "CONNECTION RESET"]
            return connectionErrors.contains { message.uppercased().contains($0) }
        default:
            return false
        }
    }
}