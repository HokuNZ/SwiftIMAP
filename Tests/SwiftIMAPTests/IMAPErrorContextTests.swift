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

            guard case .commandFailed(let response) = error else {
                XCTFail("Expected commandFailed, got: \(error)")
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
}
