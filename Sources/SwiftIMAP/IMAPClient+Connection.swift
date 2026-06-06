import Foundation

private final class SASLInitialResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var initialResponse: String?

    init(initialResponse: String?) {
        self.initialResponse = initialResponse
    }

    func takeInitialResponse() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let response = initialResponse else {
            return nil
        }
        initialResponse = nil
        return response
    }
}

/// Serialises connect attempts so concurrent `connect()` callers coalesce onto
/// a single in-flight attempt instead of racing the connection actor (which
/// would fail the loser with `invalidState`).
actor ConnectCoordinator {
    private var inFlight: Task<Void, Error>?

    /// Run `work` as the single in-flight connect attempt. Callers arriving
    /// while an attempt is running await that attempt's outcome rather than
    /// starting another.
    ///
    /// - Note: the attempt runs in its own task, so cancelling one waiting
    ///   caller does not abort an attempt other callers may be sharing.
    func run(_ work: @escaping @Sendable () async throws -> Void) async throws {
        if let inFlight {
            try await inFlight.value
            return
        }
        let task = Task { try await work() }
        inFlight = task
        // Actor serialisation guarantees this fires before any later caller can
        // enter run(): there is no suspension point between task.value resolving
        // and the defer, so a completed task is never observed as in-flight.
        // Cancelling the awaiting caller cannot fire this early either:
        // Task.value is not responsive to the awaiter's cancellation — it waits
        // for the task to complete regardless — so inFlight is never cleared
        // while the attempt is still running (verified empirically).
        defer { inFlight = nil }
        try await task.value
    }
}

extension IMAPClient {
    /// Establish (or re-establish) the connection and authenticate.
    ///
    /// Idempotent (#37):
    /// - on an already-connected, healthy client this is a no-op;
    /// - on a disconnected or stale client (e.g. the connection dropped) it
    ///   reconnects and re-authenticates;
    /// - concurrent calls coalesce onto a single attempt — the second caller
    ///   awaits the in-flight attempt instead of failing with `invalidState`.
    ///
    /// - Note: the coalescing guarantee covers concurrent `connect()` calls
    ///   only. Calling `disconnect()` while a `connect()` attempt is in flight
    ///   races it at the connection layer and the attempt may fail; serialise
    ///   connect/disconnect pairs in the caller if that ordering matters.
    public func connect() async throws {
        try await connectCoordinator.run { [self] in
            if await connection.isHealthy() {
                return
            }
            try await connectAttempt()
        }
    }

    private func connectAttempt() async throws {
        try await retryHandler.execute(operation: "connect") {
            do {
                try await self.establishSession()
            } catch {
                // A failed attempt must not leave a half-established session: the
                // channel can be up with state .connected/.authenticated when a
                // later step throws (STARTTLS unsupported, PREAUTH under
                // .startTLS, an auth or capability failure). Without teardown,
                // isHealthy() could report the failed connect as usable — for
                // the PREAUTH/STARTTLS case that would silently keep an
                // unencrypted session — and a retry would die on invalidState
                // against the still-open channel.
                await self.connection.disconnect()
                throw error
            }
        }
    }

    private func establishSession() async throws {
        let greeting = try await self.connection.connect()
        let preauthenticated = {
            if case .untagged(.status(.preauth(_, _))) = greeting {
                return true
            }
            return false
        }()

        if case .untagged(.status(.bye(let code, let text))) = greeting {
            let response = IMAPServerResponse(
                status: .bye,
                code: code,
                text: text,
                commandName: "CONNECT"
            )
            throw IMAPError.connectionClosed(response)
        }

        let capabilities = try await self.capability()

        if self.configuration.tlsMode == .startTLS {
            if preauthenticated {
                throw IMAPError.invalidState("STARTTLS not permitted after PREAUTH")
            }
            if capabilities.contains("STARTTLS") {
                try await self.startTLS()
                _ = try await self.capability()
            } else {
                throw IMAPError.unsupportedCapability("STARTTLS")
            }
        }

        if !preauthenticated {
            try await self.authenticate()
        }
    }

    public func disconnect() async {
        do {
            _ = try await logout()
        } catch {
            // A failed LOGOUT during teardown is non-fatal, but log it so a server
            // that rejects or hangs on LOGOUT is diagnosable rather than invisible.
            logger.debug("LOGOUT during disconnect failed (ignored): \(error.localizedDescription)")
        }
        await connection.disconnect()
    }

    public func capability() async throws -> Set<String> {
        let responses = try await connection.sendCommand(.capability)

        for response in responses {
            if case .untagged(.capability(let caps)) = response {
                return Set(caps)
            }
        }

        return await connection.getCapabilities()
    }

    private func authenticate() async throws {
        switch configuration.authMethod {
        case .plain(let username, let password):
            try await authenticatePlain(username: username, password: password)
        case .login(let username, let password):
            try await authenticateLogin(username: username, password: password)
        case .oauth2(let username, let accessToken):
            try await authenticateOAuth2(username: username, accessToken: accessToken)
        case .external:
            try await authenticateExternal()
        case .sasl(let mechanism, let initialResponse, let responseHandler):
            try await authenticateSasl(
                mechanism: mechanism,
                initialResponse: initialResponse,
                responseHandler: responseHandler
            )
        }
    }

    private func authenticateLogin(username: String, password: String) async throws {
        let capabilities = await connection.getCapabilities()
        if capabilities.contains("LOGINDISABLED") {
            throw IMAPError.unsupportedCapability("LOGINDISABLED")
        }

        do {
            _ = try await connection.sendCommand(.login(username: username, password: password))
        } catch IMAPError.commandFailed(let response) {
            // A NO/BAD completion of LOGIN is an authentication failure, not a
            // generic command failure: surface it as such, carrying the server
            // response so callers can inspect the code and text.
            throw IMAPError.authenticationFailed("Server rejected LOGIN", response: response)
        }
        await connection.setAuthenticated()
    }

    private func authenticateSasl(
        mechanism: String,
        initialResponse: String?,
        responseHandler: @escaping IMAPConfiguration.SASLResponseHandler
    ) async throws {
        let supportsSaslIR = await supportsSaslInitialResponse()
        let commandInitialResponse = supportsSaslIR ? initialResponse : nil
        let continuationInitialResponse = supportsSaslIR ? nil : initialResponse
        let continuationHandler = IMAPClient.makeSaslContinuationHandler(
            initialResponse: continuationInitialResponse,
            responseHandler: responseHandler
        )

        do {
            _ = try await connection.sendCommand(
                .authenticate(mechanism: mechanism, initialResponse: commandInitialResponse),
                continuationHandler: continuationHandler
            )
        } catch IMAPError.commandFailed(let response) {
            // As with LOGIN: a NO/BAD completion of AUTHENTICATE is an
            // authentication failure carrying the server's response.
            throw IMAPError.authenticationFailed("Server rejected AUTHENTICATE", response: response)
        }
        await connection.setAuthenticated()
    }

    private func authenticatePlain(username: String, password: String) async throws {
        let authString = "\0\(username)\0\(password)"
        guard let authData = authString.data(using: .utf8) else {
            throw IMAPError.authenticationFailed("Failed to encode credentials", response: nil)
        }

        let base64Auth = authData.base64EncodedString()
        let responseHandler: IMAPConfiguration.SASLResponseHandler = { _ in "" }
        try await authenticateSasl(
            mechanism: "PLAIN",
            initialResponse: base64Auth,
            responseHandler: responseHandler
        )
    }

    private func authenticateOAuth2(username: String, accessToken: String) async throws {
        let authString = "user=\(username)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        guard let authData = authString.data(using: .utf8) else {
            throw IMAPError.authenticationFailed("Failed to encode OAuth2 credentials", response: nil)
        }

        let base64Auth = authData.base64EncodedString()
        let responseHandler: IMAPConfiguration.SASLResponseHandler = { _ in "" }
        try await authenticateSasl(
            mechanism: "XOAUTH2",
            initialResponse: base64Auth,
            responseHandler: responseHandler
        )
    }

    private func authenticateExternal() async throws {
        let responseHandler: IMAPConfiguration.SASLResponseHandler = { _ in "" }
        try await authenticateSasl(
            mechanism: "EXTERNAL",
            initialResponse: "",
            responseHandler: responseHandler
        )
    }

    private func startTLS() async throws {
        _ = try await connection.sendCommand(.starttls)
        try await connection.startTLS()
    }

    private func logout() async throws {
        _ = try await connection.sendCommand(.logout)
    }

    private func supportsSaslInitialResponse() async -> Bool {
        let capabilities = await connection.getCapabilities()
        return capabilities.contains("SASL-IR")
    }

    static func makeSaslContinuationHandler(
        initialResponse: String?,
        responseHandler: @escaping IMAPConfiguration.SASLResponseHandler
    ) -> IMAPConfiguration.SASLResponseHandler {
        let state = SASLInitialResponseState(initialResponse: initialResponse)
        return { challenge in
            if let response = state.takeInitialResponse() {
                return response
            }
            return try await responseHandler(challenge)
        }
    }
}
