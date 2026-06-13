import XCTest
@testable import SwiftIMAP
import NIO

/// Tests for the idempotent `connect()` contract: no-op when
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
        } catch let error as IMAPError {
            // The drop arrives with no tagged completion; any connectionClosed
            // shape is acceptable here — the contract under test is the
            // reconnect below, not the precise drop error.
            guard case .connectionClosed = error else {
                XCTFail("Expected connectionClosed, got: \(error)")
                return
            }
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

    /// A failed connect attempt must not leave a half-established session:
    /// STARTTLS-unsupported throws AFTER the channel is up, and without
    /// teardown the live channel makes the next attempt die on invalidState
    /// instead of re-attempting with a fresh connection.
    func testFailedStartTLSConnectTearsDownAndAllowsRetry() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .startTLS,
            authMethod: .login(username: "testuser", password: "testpass"),
            retryConfiguration: RetryConfiguration(maxAttempts: 1)
        )
        let client = IMAPClient(configuration: config)

        for attempt in 1...2 {
            do {
                try await client.connect()
                XCTFail("Expected STARTTLS capability failure on attempt \(attempt)")
            } catch IMAPError.unsupportedCapability(let capability) {
                XCTAssertEqual(capability, "STARTTLS",
                               "Attempt \(attempt) must fail on the real cause, not invalidState from a leaked channel")
            }
        }
    }

    /// The security-critical teardown case: a PREAUTH greeting under .startTLS
    /// throws with the actor already in .authenticated state. Without teardown,
    /// isHealthy() would make the NEXT connect() a silent no-op on an
    /// unencrypted session whose establishment was rejected.
    func testPreauthUnderStartTLSDoesNotLeaveUsableSession() async throws {
        mockServer.setResponse(for: "GREETING", response: "* PREAUTH IMAP4rev1")
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 STARTTLS")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .startTLS,
            authMethod: .login(username: "testuser", password: "testpass"),
            retryConfiguration: RetryConfiguration(maxAttempts: 1)
        )
        let client = IMAPClient(configuration: config)

        do {
            try await client.connect()
            XCTFail("Expected PREAUTH + startTLS to be rejected")
        } catch IMAPError.invalidState(let message) {
            XCTAssertEqual(message, "STARTTLS not permitted after PREAUTH")
        }

        do {
            try await client.connect()
            XCTFail("A second connect() must not silently succeed on the rejected unencrypted session")
        } catch IMAPError.invalidState(let message) {
            XCTAssertEqual(message, "STARTTLS not permitted after PREAUTH")
        }
    }

    /// Rejected credentials leave the client cleanly disconnected: a retry with
    /// the same client re-attempts (fresh connection, fresh LOGIN).
    func testFailedLoginTearsDownAndAllowsRetry() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "NO [AUTHENTICATIONFAILED] Invalid credentials")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "wrongpass"),
            retryConfiguration: RetryConfiguration(maxAttempts: 1)
        )
        let client = IMAPClient(configuration: config)

        for _ in 1...2 {
            do {
                try await client.connect()
                XCTFail("Expected login rejection")
            } catch IMAPError.authenticationFailed(_, let response) {
                XCTAssertNotNil(response)
            }
        }
        XCTAssertEqual(loginCount, 2, "Each attempt must reach the server with a fresh LOGIN")
    }

    /// Concurrent reconnects after a drop coalesce too — the practical case
    /// (e.g. several in-flight operations all hitting the same dead connection
    /// and racing to re-establish): one fresh LOGIN, no invalidState.
    func testConcurrentReconnectsAfterDropCoalesce() async throws {
        let client = makeClient()
        mockServer.setResponse(for: "SELECT", response: "* 1 EXISTS")
        mockServer.closeOnceAfterResponse(toCommandContaining: "SELECT")

        try await client.connect()
        do {
            _ = try await client.selectMailbox("INBOX")
            XCTFail("Expected the hang-up to fail SELECT")
        } catch {
            // expected: connection dropped
        }

        async let first: Void = client.connect()
        async let second: Void = client.connect()
        _ = try await (first, second)

        XCTAssertEqual(loginCount, 2, "One LOGIN from the initial connect, one from the coalesced reconnect")

        let status = try await client.selectMailbox("INBOX")
        XCTAssertEqual(status.messages, 1)

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
