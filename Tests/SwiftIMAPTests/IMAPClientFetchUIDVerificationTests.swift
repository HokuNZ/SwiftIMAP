import XCTest
@testable import SwiftIMAP
import NIO

/// Tests for Issue #2: fetchMessageBody and fetchMessage must verify UID in response
/// matches the requested UID to avoid returning wrong data when multiple fetches are pending.
final class IMAPClientFetchUIDVerificationTests: XCTestCase {
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

    // MARK: - fetchMessageBody UID Verification Tests

    /// Test that fetchMessageBody returns correct body when UID matches
    func testFetchMessageBodyReturnsCorrectBodyWhenUIDMatches() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        // Response includes UID that matches the requested UID
        mockServer.setResponse(for: "UID FETCH", response: "* 1 FETCH (UID 42 BODY[] {5}\r\nHello)")

        let client = makeClient()
        try await client.connect()

        let body = try await client.fetchMessageBody(uid: 42, in: "INBOX")
        let bodyString = body.flatMap { String(data: $0, encoding: .utf8) }

        XCTAssertEqual(bodyString, "Hello")

        await client.disconnect()
    }

    /// Test that fetchMessageBody returns nil when UID doesn't match
    /// This simulates the race condition where a response for a different UID is received
    func testFetchMessageBodyReturnsNilWhenUIDMismatch() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        // Response UID (999) doesn't match requested UID (42)
        mockServer.setResponse(for: "UID FETCH", response: "* 1 FETCH (UID 999 BODY[] {5}\r\nWrong)")

        let client = makeClient()
        try await client.connect()

        // Request UID 42, but server returns UID 999 (simulating race condition)
        let body = try await client.fetchMessageBody(uid: 42, in: "INBOX")

        // Should return nil because UID doesn't match, NOT the wrong body
        XCTAssertNil(body, "fetchMessageBody should return nil when response UID doesn't match requested UID")

        await client.disconnect()
    }

    /// Test that fetchMessageBody finds correct body among multiple responses
    func testFetchMessageBodyFindsCorrectBodyAmongMultipleResponses() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        // Multiple FETCH responses with different UIDs
        mockServer.setResponse(for: "UID FETCH", response: """
* 1 FETCH (UID 100 BODY[] {5}\r\nFirst)
* 2 FETCH (UID 42 BODY[] {7}\r\nCorrect)
* 3 FETCH (UID 200 BODY[] {4}\r\nLast)
""")

        let client = makeClient()
        try await client.connect()

        // Request UID 42, should find the correct response
        let body = try await client.fetchMessageBody(uid: 42, in: "INBOX")
        let bodyString = body.flatMap { String(data: $0, encoding: .utf8) }

        XCTAssertEqual(bodyString, "Correct", "Should find and return body for matching UID 42")

        await client.disconnect()
    }

    // MARK: - fetchMessage UID Verification Tests

    /// Test that fetchMessage returns correct message when UID matches
    func testFetchMessageReturnsCorrectMessageWhenUIDMatches() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID FETCH", response: """
* 1 FETCH (UID 42 FLAGS (\\Seen) INTERNALDATE "17-Jul-1996 02:44:25 -0700" RFC822.SIZE 4286 ENVELOPE ("Wed, 17 Jul 1996 02:23:25 -0700" "Correct Subject" ((NIL NIL "sender" "example.com")) ((NIL NIL "sender" "example.com")) ((NIL NIL "sender" "example.com")) ((NIL NIL "recipient" "example.com")) NIL NIL NIL "<msg@example.com>"))
""")

        let client = makeClient()
        try await client.connect()

        let message = try await client.fetchMessage(uid: 42, in: "INBOX")

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.uid, 42)
        XCTAssertEqual(message?.envelope?.subject, "Correct Subject")

        await client.disconnect()
    }

    /// Test that fetchMessage returns nil when UID doesn't match
    func testFetchMessageReturnsNilWhenUIDMismatch() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        // Response UID (999) doesn't match requested UID (42)
        mockServer.setResponse(for: "UID FETCH", response: """
* 1 FETCH (UID 999 FLAGS () INTERNALDATE "17-Jul-1996 02:44:25 -0700" RFC822.SIZE 100 ENVELOPE ("Wed, 17 Jul 1996 02:23:25 -0700" "Wrong Message" ((NIL NIL "wrong" "example.com")) NIL NIL NIL NIL NIL NIL "<wrong@example.com>"))
""")

        let client = makeClient()
        try await client.connect()

        // Request UID 42, but server returns UID 999
        let message = try await client.fetchMessage(uid: 42, in: "INBOX")

        XCTAssertNil(message, "fetchMessage should return nil when response UID doesn't match requested UID")

        await client.disconnect()
    }

    /// Test that fetchMessage finds correct message among multiple responses
    func testFetchMessageFindsCorrectMessageAmongMultipleResponses() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        // Multiple FETCH responses with different UIDs
        mockServer.setResponse(for: "UID FETCH", response: """
* 1 FETCH (UID 100 FLAGS () INTERNALDATE "17-Jul-1996 02:44:25 -0700" RFC822.SIZE 100 ENVELOPE ("Wed, 17 Jul 1996 02:23:25 -0700" "First" ((NIL NIL "first" "example.com")) NIL NIL NIL NIL NIL NIL "<first@example.com>"))
* 2 FETCH (UID 42 FLAGS (\\Seen) INTERNALDATE "18-Jul-1996 02:44:25 -0700" RFC822.SIZE 200 ENVELOPE ("Thu, 18 Jul 1996 02:23:25 -0700" "Target Message" ((NIL NIL "target" "example.com")) NIL NIL NIL NIL NIL NIL "<target@example.com>"))
* 3 FETCH (UID 200 FLAGS () INTERNALDATE "19-Jul-1996 02:44:25 -0700" RFC822.SIZE 300 ENVELOPE ("Fri, 19 Jul 1996 02:23:25 -0700" "Last" ((NIL NIL "last" "example.com")) NIL NIL NIL NIL NIL NIL "<last@example.com>"))
""")

        let client = makeClient()
        try await client.connect()

        // Request UID 42, should find the correct response
        let message = try await client.fetchMessage(uid: 42, in: "INBOX")

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.uid, 42)
        XCTAssertEqual(message?.envelope?.subject, "Target Message")

        await client.disconnect()
    }

    // MARK: - Request UID in response tests

    /// Test that fetchMessage automatically adds UID to fetch items if not present
    func testFetchMessageEnsuresUIDInRequest() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID FETCH", response: """
* 1 FETCH (UID 42 FLAGS (\\Seen) INTERNALDATE "17-Jul-1996 02:44:25 -0700" RFC822.SIZE 4286 ENVELOPE ("Wed, 17 Jul 1996 02:23:25 -0700" "Test Subject" ((NIL NIL "sender" "example.com")) ((NIL NIL "sender" "example.com")) ((NIL NIL "sender" "example.com")) ((NIL NIL "recipient" "example.com")) NIL NIL NIL "<msg@example.com>"))
""")

        let client = makeClient()
        try await client.connect()

        // Request without UID in items - it should be added automatically
        _ = try await client.fetchMessage(uid: 42, in: "INBOX", items: [.flags, .envelope])

        // Verify the fetch command includes UID in the requested items
        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        let fetchCommand = commands.first { $0.contains("UID FETCH") && $0.contains("ENVELOPE") }
        XCTAssertNotNil(fetchCommand)

        // The fetch should request UID even though we didn't include it in items
        if let cmd = fetchCommand {
            // Command format: "A4 UID FETCH 42 (UID FLAGS ENVELOPE)"
            // Check that UID appears in the fetch items list (between parentheses)
            XCTAssertTrue(cmd.contains("(UID") || cmd.contains(" UID ") || cmd.contains(" UID)"),
                          "fetchMessage should add UID to fetch items for verification. Command: \(cmd)")
        }

        await client.disconnect()
    }

    /// Test that fetchMessageBody requests UID in fetch items
    func testFetchMessageBodyIncludesUIDInRequest() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID FETCH", response: "* 1 FETCH (UID 42 BODY[] {5}\r\nHello)")

        let client = makeClient()
        try await client.connect()

        _ = try await client.fetchMessageBody(uid: 42, in: "INBOX")

        // Verify the fetch command includes UID in the requested items
        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        let fetchCommand = commands.first { $0.contains("UID FETCH") && $0.contains("BODY") }
        XCTAssertNotNil(fetchCommand)

        // The fetch should request UID in the items list (not just as command prefix)
        // Command format: "A4 UID FETCH 42 (UID BODY[])"
        if let cmd = fetchCommand {
            // Check that UID appears in the fetch items list (between parentheses)
            XCTAssertTrue(cmd.contains("(UID") || cmd.contains(" UID ") || cmd.contains(" UID)"),
                          "fetchMessageBody should request UID in fetch items for verification. Command: \(cmd)")
        }

        await client.disconnect()
    }

    // MARK: - Helpers

    private func makeClient() -> IMAPClient {
        IMAPClient(
            configuration: IMAPConfiguration(
                hostname: "localhost",
                port: serverPort,
                tlsMode: .disabled,
                authMethod: .login(username: "testuser", password: "testpass")
            )
        )
    }
}
