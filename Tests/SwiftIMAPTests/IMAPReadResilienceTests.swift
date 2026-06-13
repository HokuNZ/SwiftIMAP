import XCTest
@testable import SwiftIMAP
import NIO

/// Tests for read-path resilience (#46): fetchMessageBody reconnects and
/// retries on an abrupt drop like fetchMessage, and disconnect() bounds its
/// LOGOUT so a silent server cannot make it hang for the full commandTimeout.
final class IMAPReadResilienceTests: XCTestCase {
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

    /// fetchMessageBody reconnects and retries transparently after the
    /// connection drops mid-fetch — the read-path equivalent of the
    /// listMessageUIDs reconnect regression (#35 / A4, #46 / C2-read).
    func testFetchMessageBodyReconnectsAndRetriesAfterDrop() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID FETCH", response: """
            * 1 FETCH (UID 1 BODY[] {11}
            Hello World)
            """)
        // First UID FETCH gets its untagged reply, then the server hangs up; the
        // retry layer must reconnect and re-run it to a successful result.
        mockServer.closeOnceAfterResponse(toCommandContaining: "UID FETCH")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass"),
            retryConfiguration: RetryConfiguration(maxAttempts: 2, initialDelay: 0, maxDelay: 0)
        )
        let client = IMAPClient(configuration: config)
        try await client.connect()

        let body = try await client.fetchMessageBody(uid: 1, in: "INBOX")
        XCTAssertEqual(body.flatMap { String(data: $0, encoding: .utf8) }, "Hello World",
                       "Body fetch should succeed transparently after reconnect")

        let logins = mockServer.receivedCommands.filter { $0.uppercased().contains("LOGIN") }
        XCTAssertEqual(logins.count, 2, "Expected a second LOGIN proving a reconnect happened")

        await client.disconnect()
    }

    /// disconnect() returns promptly when the server accepts LOGOUT but never
    /// answers it, rather than waiting out the full commandTimeout (#46 / C3).
    /// The bound is min(commandTimeout, 5s); with the default 60s timeout a
    /// regression that dropped the bound would hang ~60s.
    func testDisconnectBoundsUnansweredLogout() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.blackHoleCommand(containing: "LOGOUT")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
            // commandTimeout defaults to 60s, so the 5s bound is what saves us.
        )
        let client = IMAPClient(configuration: config)
        try await client.connect()

        let start = DispatchTime.now()
        await client.disconnect()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        XCTAssertLessThan(elapsed, 20, "disconnect() must be bounded well under the 60s commandTimeout (got \(elapsed)s)")
    }
}
