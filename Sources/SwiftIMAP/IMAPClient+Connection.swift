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

extension IMAPClient {
    public func connect() async throws {
        try await retryHandler.execute(operation: "connect") {
            let greeting = try await self.connection.connect()
            let preauthenticated = {
                if case .untagged(.status(.preauth(_, _))) = greeting {
                    return true
                }
                return false
            }()

            if case .untagged(.status(.bye(_, _))) = greeting {
                throw IMAPError.connectionClosed
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
    }

    public func disconnect() async {
        _ = try? await logout()
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

        _ = try await connection.sendCommand(.login(username: username, password: password))
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

        _ = try await connection.sendCommand(
            .authenticate(mechanism: mechanism, initialResponse: commandInitialResponse),
            continuationHandler: continuationHandler
        )
        await connection.setAuthenticated()
    }

    private func authenticatePlain(username: String, password: String) async throws {
        let authString = "\0\(username)\0\(password)"
        guard let authData = authString.data(using: .utf8) else {
            throw IMAPError.authenticationFailed("Failed to encode credentials")
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
            throw IMAPError.authenticationFailed("Failed to encode OAuth2 credentials")
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
