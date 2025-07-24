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
                lastError = error
                
                // Check if we need to reconnect
                if needsReconnect(error) && attempt < configuration.maxAttempts {
                    logger.warning("[\(operation)] Connection lost. Attempting to reconnect...")
                    do {
                        try await reconnect()
                        logger.info("[\(operation)] Reconnected successfully")
                        // Continue to next attempt without delay
                        continue
                    } catch {
                        logger.error("[\(operation)] Reconnection failed: \(error)")
                        lastError = error
                    }
                }
                
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
            case .connectionError, .connectionClosed:
                return configuration.retryableErrors.contains(.connectionLost)
            case .timeout:
                return configuration.retryableErrors.contains(.timeout)
            case .serverError(let message):
                // Check for temporary server errors
                let temporaryErrors = ["UNAVAILABLE", "TRY AGAIN", "TEMPORARY", "BUSY"]
                let isTemporary = temporaryErrors.contains { message.uppercased().contains($0) }
                return isTemporary && configuration.retryableErrors.contains(.temporaryFailure)
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
}

// MARK: - Error Classification

extension IMAPError {
    /// Determines if the error indicates a lost connection that requires reconnection
    var requiresReconnection: Bool {
        switch self {
        case .connectionError, .connectionClosed:
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