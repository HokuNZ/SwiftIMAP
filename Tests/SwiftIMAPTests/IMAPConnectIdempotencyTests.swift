import XCTest
@testable import SwiftIMAP
import NIO

/// Tests for the idempotent `connect()` contract (issue #37): no-op when
/// healthy, reconnect when stale, and coalescing of concurrent calls.
final class IMAPConnectIdempotencyTests: XCTestCase {
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

    private func makeClient() -> IMAPClient {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass"),
            retryConfiguration: RetryConfiguration(maxAttempts: 2, initialDelay: 0, maxDelay: 0)
        )
        return IMAPClient(configuration: config)
    }

    private var loginCount: Int {
        mockServer.receivedCommands.filter { $0.uppercased().contains("LOGIN") }.count
    }

    /// connect() on an already-connected, healthy client is a no-op: no second
    /// connection, no second LOGIN, no thrown invalidState.
    func testSecondConnectOnHealthyClientIsNoOp() async throws {
        let client = makeClient()

        try await client.connect()
        XCTAssertEqual(loginCount, 1)

        try await client.connect()
        XCTAssertEqual(loginCount, 1, "A healthy client must not re-authenticate")

        await client.disconnect()
    }

    /// connect() after the server drops the connection re-establishes and
    /// re-authenticates, without requiring a disconnect() first.
    func testConnectAfterDropReestablishes() async throws {
        let client = makeClient()
        mockServer.setResponse(for: "SELECT", response: "* 1 EXISTS")
        mockServer.closeOnceAfterResponse(toCommandContaining: "SELECT")

        try await client.connect()
        XCTAssertEqual(loginCount, 1)

        do {
            _ = try await client.selectMailbox("INBOX")
            XCTFail("Expected the hang-up to fail SELECT")
        } catch IMAPError.connectionClosed(nil) {
            // expected: abrupt drop, no server response
        }

        try await client.connect()
        XCTAssertEqual(loginCount, 2, "Expected a fresh LOGIN on the new connection")

        let status = try await client.selectMailbox("INBOX")
        XCTAssertEqual(status.messages, 1)

        await client.disconnect()
    }

    /// connect() after an explicit disconnect() also re-establishes.
    func testConnectAfterDisconnectReestablishes() async throws {
        let client = makeClient()

        try await client.connect()
        await client.disconnect()

        try await client.connect()
        XCTAssertEqual(loginCount, 2)

        await client.disconnect()
    }

    /// Concurrent connect() calls coalesce onto one attempt: exactly one LOGIN,
    /// and neither caller throws invalidState.
    func testConcurrentConnectsCoalesce() async throws {
        let client = makeClient()

        async let first: Void = client.connect()
        async let second: Void = client.connect()
        _ = try await (first, second)

        XCTAssertEqual(loginCount, 1, "Concurrent connects must share one attempt")

        await client.disconnect()
    }
}
