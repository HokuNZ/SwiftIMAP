import XCTest
@testable import SwiftIMAP
import NIO

/// Integration tests for the operational context carried by `IMAPError`
/// (issue #27): server response lines, and the guarantee that credentials never
/// leak into error output.
final class IMAPErrorContextTests: XCTestCase {
    private var eventLoopGroup: MultiThreadedEventLoopGroup!
    private var mockServer: MockIMAPServer!
    private var serverPort: Int!

    override func setUp() async throws {
        try await super.setUp()
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        mockServer = MockIMAPServer(eventLoopGroup: eventLoopGroup)
        serverPort = try await mockServer.start()
    }

    override func tearDown() async throws {
        if let mockServer {
            try await mockServer.shutdown()
            self.mockServer = nil
        }
        if let eventLoopGroup {
            try await eventLoopGroup.shutdownGracefully()
            self.eventLoopGroup = nil
        }
        serverPort = nil
        try await super.tearDown()
    }

    /// Regression: a rejected LOGIN must never leak the username or password into
    /// the thrown error or its description (issue #27). The command label replaces
    /// String(describing:), which used to embed the credentials.
    func testRejectedLoginDoesNotLeakCredentials() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "NO [AUTHENTICATIONFAILED] Invalid credentials")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "secret-user@example.com", password: "hunter2-secret")
        )
        let client = IMAPClient(configuration: config)

        do {
            try await client.connect()
            XCTFail("Expected login to be rejected")
        } catch let error as IMAPError {
            // The full diagnostic string must not contain the credentials.
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.contains("secret-user@example.com"),
                           "Username leaked into error description: \(description)")
            XCTAssertFalse(description.contains("hunter2-secret"),
                           "Password leaked into error description: \(description)")

            // String(reflecting:) of the whole error must not carry the credentials
            // either, so a consumer that reflects/logs the error cannot leak them.
            let reflected = String(reflecting: error)
            XCTAssertFalse(reflected.contains("hunter2-secret"),
                           "Password leaked into reflected error: \(reflected)")

            // A server-rejected LOGIN surfaces as authenticationFailed (not the
            // generic commandFailed), carrying the server response (#35 / A5).
            guard case .authenticationFailed(let message, let response) = error else {
                XCTFail("Expected authenticationFailed, got: \(error)")
                return
            }
            XCTAssertEqual(message, "Server rejected LOGIN")
            guard let response else {
                XCTFail("Expected the server response to be carried")
                return
            }
            XCTAssertEqual(response.status, .no)
            XCTAssertEqual(response.commandName, "LOGIN")
            XCTAssertEqual(response.code, .other("AUTHENTICATIONFAILED", nil))
            XCTAssertEqual(response.text, "Invalid credentials")
            XCTAssertEqual(response.line, "NO [AUTHENTICATIONFAILED] Invalid credentials")
            XCTAssertTrue(response.isAuthenticationFailure)
        }
    }

    /// A server-rejected AUTHENTICATE (here SASL PLAIN with SASL-IR) also surfaces
    /// as authenticationFailed carrying the server response (#35 / A5).
    func testRejectedAuthenticateSurfacesAsAuthenticationFailed() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN")
        mockServer.setAuthenticateResponse("NO [AUTHENTICATIONFAILED] Authentication rejected")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .plain(username: "testuser", password: "wrongpass")
        )
        let client = IMAPClient(configuration: config)

        do {
            try await client.connect()
            XCTFail("Expected AUTHENTICATE to be rejected")
        } catch let error as IMAPError {
            guard case .authenticationFailed(let message, let response) = error else {
                XCTFail("Expected authenticationFailed, got: \(error)")
                return
            }
            XCTAssertEqual(message, "Server rejected AUTHENTICATE")
            XCTAssertEqual(response?.status, .no)
            XCTAssertEqual(response?.commandName, "AUTHENTICATE")
            XCTAssertEqual(response?.code, .other("AUTHENTICATIONFAILED", nil))
            XCTAssertTrue(response?.isAuthenticationFailure ?? false)
        }
    }

    /// A MOVE to a missing destination surfaces the server's rejection with the
    /// status, code, and operation intact — the core requirement from MailTriage #226.
    func testRejectedMoveExposesServerResponse() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 MOVE")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID MOVE", response: "NO [TRYCREATE] Mailbox does not exist")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )
        let client = IMAPClient(configuration: config)
        try await client.connect()

        do {
            try await client.moveMessage(uid: 42, from: "INBOX", to: "Archive")
            XCTFail("Expected MOVE to a missing folder to fail")
        } catch let error as IMAPError {
            guard case .commandFailed(let response) = error else {
                XCTFail("Expected commandFailed, got: \(error)")
                return
            }
            XCTAssertEqual(response.status, .no)
            XCTAssertEqual(response.commandName, "UID MOVE")
            XCTAssertEqual(response.code, .tryCreate)
            XCTAssertEqual(response.text, "Mailbox does not exist")
            XCTAssertEqual(response.line, "NO [TRYCREATE] Mailbox does not exist")
            XCTAssertTrue(response.isMailboxNotFound)
        }

        await client.disconnect()
    }

    /// End-to-end regression for #35 / A4: an abrupt connection drop (no BYE)
    /// mid-way through a wrapped operation reconnects and retries transparently.
    /// Previously the drop surfaced as `disconnected` (not reconnectable) and the
    /// actor state was never reset, so the reconnect itself threw `invalidState`.
    func testWrappedOperationReconnectsAndRetriesAfterAbruptDrop() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID SEARCH", response: "* SEARCH 7 9")
        // First UID SEARCH gets its untagged reply but no tagged completion, then
        // the server hangs up; the retry layer must reconnect and re-run it.
        mockServer.closeOnceAfterResponse(toCommandContaining: "UID SEARCH")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass"),
            retryConfiguration: RetryConfiguration(maxAttempts: 2, initialDelay: 0, maxDelay: 0)
        )
        let client = IMAPClient(configuration: config)
        try await client.connect()

        let uids = try await client.listMessageUIDs(in: "INBOX")
        XCTAssertEqual(uids, [7, 9], "Operation should succeed transparently after reconnect")

        let logins = mockServer.receivedCommands.filter { $0.uppercased().contains("LOGIN") }
        XCTAssertEqual(logins.count, 2, "Expected a second LOGIN proving a reconnect happened")

        await client.disconnect()
    }

    /// A local SASL failure (the response handler returning nil) surfaces as
    /// `authenticationFailed` with `response: nil` — no server response involved.
    func testSaslHandlerReturningNilIsLocalAuthenticationFailure() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 AUTH=CUSTOM")
        mockServer.setAuthenticateChallenges(["c2VydmVyLWNoYWxsZW5nZQ=="])

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .sasl(mechanism: "CUSTOM", initialResponse: nil, responseHandler: { _ in nil })
        )
        let client = IMAPClient(configuration: config)

        do {
            try await client.connect()
            XCTFail("Expected SASL nil response to fail authentication")
        } catch let error as IMAPError {
            guard case .authenticationFailed(let message, let response) = error else {
                XCTFail("Expected authenticationFailed, got: \(error)")
                return
            }
            XCTAssertEqual(message, "SASL response handler returned nil")
            XCTAssertNil(response, "A local failure must not carry a server response")
        }
    }

    /// An unsolicited mid-session `* BYE` followed by the server dropping the
    /// connection surfaces the BYE's reason on the in-flight command, rather than a
    /// bare `disconnected` (#26 follow-up).
    func testMidSessionByeSurfacesReasonOnPendingCommand() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        // SELECT gets only an untagged BYE, then the server hangs up.
        mockServer.setResponse(for: "SELECT", response: "* BYE [UNAVAILABLE] Server going down for maintenance")
        mockServer.closeAfterResponse(toCommandContaining: "SELECT")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )
        let client = IMAPClient(configuration: config)
        try await client.connect()

        do {
            _ = try await client.selectMailbox("INBOX")
            XCTFail("Expected the mid-session BYE + hang-up to fail SELECT")
        } catch let error as IMAPError {
            guard case .connectionClosed(let response) = error else {
                XCTFail("Expected connectionClosed carrying the BYE reason, got: \(error)")
                return
            }
            XCTAssertEqual(response?.status, .bye)
            XCTAssertEqual(response?.code, .other("UNAVAILABLE", nil))
            XCTAssertEqual(response?.text, "Server going down for maintenance")
            XCTAssertEqual(response?.commandName, "SELECT")
        }

        await client.disconnect()
    }
}
