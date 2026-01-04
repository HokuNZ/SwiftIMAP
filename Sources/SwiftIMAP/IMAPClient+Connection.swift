import Foundation

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

    private func authenticatePlain(username: String, password: String) async throws {
        let authString = "\0\(username)\0\(password)"
        guard let authData = authString.data(using: .utf8) else {
            throw IMAPError.authenticationFailed("Failed to encode credentials")
        }

        let base64Auth = authData.base64EncodedString()
        let supportsSaslIR = await supportsSaslInitialResponse()

        let continuationHandler = makeSaslContinuationHandler(initialResponse: supportsSaslIR ? nil : base64Auth)

        if supportsSaslIR {
            _ = try await connection.sendCommand(
                .authenticate(mechanism: "PLAIN", initialResponse: base64Auth),
                continuationHandler: continuationHandler
            )
        } else {
            _ = try await connection.sendCommand(
                .authenticate(mechanism: "PLAIN", initialResponse: nil),
                continuationHandler: continuationHandler
            )
        }
        await connection.setAuthenticated()
    }

    private func authenticateOAuth2(username: String, accessToken: String) async throws {
        let authString = "user=\(username)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        guard let authData = authString.data(using: .utf8) else {
            throw IMAPError.authenticationFailed("Failed to encode OAuth2 credentials")
        }

        let base64Auth = authData.base64EncodedString()
        let supportsSaslIR = await supportsSaslInitialResponse()

        let continuationHandler = makeSaslContinuationHandler(initialResponse: supportsSaslIR ? nil : base64Auth)

        if supportsSaslIR {
            _ = try await connection.sendCommand(
                .authenticate(mechanism: "XOAUTH2", initialResponse: base64Auth),
                continuationHandler: continuationHandler
            )
        } else {
            _ = try await connection.sendCommand(
                .authenticate(mechanism: "XOAUTH2", initialResponse: nil),
                continuationHandler: continuationHandler
            )
        }
        await connection.setAuthenticated()
    }

    private func authenticateExternal() async throws {
        let continuationHandler = makeSaslContinuationHandler(initialResponse: "")
        _ = try await connection.sendCommand(
            .authenticate(mechanism: "EXTERNAL", initialResponse: nil),
            continuationHandler: continuationHandler
        )
        await connection.setAuthenticated()
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

    private func makeSaslContinuationHandler(initialResponse: String?) -> (String?) -> String? {
        var didSendInitial = false
        return { _ in
            if let initialResponse, !didSendInitial {
                didSendInitial = true
                return initialResponse
            }
            return ""
        }
    }
}
