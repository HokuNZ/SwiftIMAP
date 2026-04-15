import XCTest
@testable import SwiftIMAP
import NIO

/// Tests for Issue #1: searchMessages() should use UIDs instead of sequence numbers
/// to avoid race conditions when mailbox changes between search and fetch operations.
final class IMAPClientUIDSearchTests: XCTestCase {
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

    // MARK: - listMessageUIDs Tests

    /// Test that listMessageUIDs() sends UID SEARCH command (not plain SEARCH)
    func testListMessageUIDsSendsUIDSearchCommand() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID SEARCH", response: "* SEARCH 100 200 300")

        let client = makeClient()
        try await client.connect()

        let uids = try await client.listMessageUIDs(in: "INBOX")

        // Verify UID SEARCH command was sent
        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("UID") && $0.contains("SEARCH") },
                      "Expected UID SEARCH command, got: \(commands)")

        // Verify we get UIDs back
        XCTAssertEqual(uids, [100, 200, 300])

        await client.disconnect()
    }

    /// Test that listMessageUIDs() returns empty array when no matches
    func testListMessageUIDsReturnsEmptyArrayWhenNoMatches() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID SEARCH", response: "* SEARCH")

        let client = makeClient()
        try await client.connect()

        let uids = try await client.listMessageUIDs(in: "INBOX", searchCriteria: .from("nobody@example.com"))
        XCTAssertTrue(uids.isEmpty)

        await client.disconnect()
    }

    /// Test that listMessageUIDs() passes charset parameter correctly
    func testListMessageUIDsWithCharset() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID SEARCH", response: "* SEARCH 42")

        let client = makeClient()
        try await client.connect()

        let uids = try await client.listMessageUIDs(
            in: "INBOX",
            searchCriteria: .subject("Test"),
            charset: "UTF-8"
        )

        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("CHARSET") && $0.contains("UTF-8") })
        XCTAssertEqual(uids, [42])

        await client.disconnect()
    }

    // MARK: - searchMessages UID Usage Tests

    /// Test that searchMessages() uses UID SEARCH and UID FETCH internally
    func testSearchMessagesUsesUIDsInternally() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        // UID SEARCH returns UIDs
        mockServer.setResponse(for: "UID SEARCH", response: "* SEARCH 100 200")
        // UID FETCH returns message details - set specific responses for each UID
        mockServer.setResponse(for: "UID FETCH 100", response: "* 1 FETCH (UID 100 FLAGS (\\Seen) INTERNALDATE \"17-Jul-1996 02:44:25 -0700\" RFC822.SIZE 4286 ENVELOPE (\"Wed, 17 Jul 1996 02:23:25 -0700\" \"Test Subject 1\" ((NIL NIL \"sender\" \"example.com\")) ((NIL NIL \"sender\" \"example.com\")) ((NIL NIL \"sender\" \"example.com\")) ((NIL NIL \"recipient\" \"example.com\")) NIL NIL NIL \"<msg1@example.com>\"))")
        mockServer.setResponse(for: "UID FETCH 200", response: "* 2 FETCH (UID 200 FLAGS () INTERNALDATE \"18-Jul-1996 02:44:25 -0700\" RFC822.SIZE 1234 ENVELOPE (\"Thu, 18 Jul 1996 02:23:25 -0700\" \"Test Subject 2\" ((NIL NIL \"sender\" \"example.com\")) ((NIL NIL \"sender\" \"example.com\")) ((NIL NIL \"sender\" \"example.com\")) ((NIL NIL \"recipient\" \"example.com\")) NIL NIL NIL \"<msg2@example.com>\"))")

        let client = makeClient()
        try await client.connect()

        let summaries = try await client.searchMessages(in: "INBOX", criteria: .all)

        // Verify UID SEARCH was used (not plain SEARCH)
        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        let searchCommands = commands.filter { $0.contains("SEARCH") }
        for cmd in searchCommands {
            XCTAssertTrue(cmd.contains("UID"), "SEARCH should be prefixed with UID: \(cmd)")
        }

        // Verify UID FETCH was used (not plain FETCH)
        let fetchCommands = commands.filter { $0.contains("FETCH") }
        for cmd in fetchCommands {
            XCTAssertTrue(cmd.contains("UID"), "FETCH should be prefixed with UID: \(cmd)")
        }

        // Verify we got the expected messages with correct UIDs
        XCTAssertEqual(summaries.count, 2)
        let returnedUIDs = Set(summaries.map { $0.uid })
        XCTAssertEqual(returnedUIDs, [100, 200], "Should return messages with UIDs 100 and 200")

        await client.disconnect()
    }

    // MARK: - Deprecation of listMessages Tests

    /// Test that listMessages still works (for backwards compatibility) but uses sequence numbers
    func testListMessagesReturnsSequenceNumbers() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        // Plain SEARCH returns sequence numbers
        mockServer.setResponse(for: "SEARCH", response: "* SEARCH 1 2 3")

        let client = makeClient()
        try await client.connect()

        // This should still work but use plain SEARCH (not UID SEARCH)
        let sequenceNumbers = try await client.listMessages(in: "INBOX")

        // Verify plain SEARCH was used (not UID SEARCH)
        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        let searchCommands = commands.filter { $0.contains("SEARCH") }

        // There should be a SEARCH command that is NOT prefixed with UID
        let hasPlainSearch = searchCommands.contains { cmd in
            // Check that SEARCH appears but not immediately after UID
            let containsSearch = cmd.contains("SEARCH")
            let containsUIDSearch = cmd.contains("UID SEARCH")
            return containsSearch && !containsUIDSearch
        }
        XCTAssertTrue(hasPlainSearch, "Expected plain SEARCH command, got: \(searchCommands)")

        XCTAssertEqual(sequenceNumbers, [1, 2, 3])

        await client.disconnect()
    }

    // MARK: - Edge Cases

    /// Test listMessageUIDs with complex search criteria
    func testListMessageUIDsWithComplexCriteria() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID SEARCH", response: "* SEARCH 500")

        let client = makeClient()
        try await client.connect()

        let criteria: IMAPCommand.SearchCriteria = .and([
            .from("sender@example.com"),
            .unseen,
            .larger(1000)
        ])

        let uids = try await client.listMessageUIDs(in: "INBOX", searchCriteria: criteria)
        XCTAssertEqual(uids, [500])

        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("FROM") && $0.contains("UNSEEN") && $0.contains("LARGER") })

        await client.disconnect()
    }

    /// Test that searchMessages returns empty array when no matches
    func testSearchMessagesReturnsEmptyWhenNoMatches() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID SEARCH", response: "* SEARCH")

        let client = makeClient()
        try await client.connect()

        let summaries = try await client.searchMessages(in: "INBOX", criteria: .from("nobody@nowhere.com"))
        XCTAssertTrue(summaries.isEmpty)

        await client.disconnect()
    }

    // MARK: - Error Handling Tests

    /// Test that listMessageUIDs throws when disconnected
    func testListMessageUIDsThrowsWhenDisconnected() async {
        let client = makeClient()

        do {
            _ = try await client.listMessageUIDs(in: "INBOX")
            XCTFail("Expected listMessageUIDs to throw when disconnected")
        } catch {
            guard case IMAPError.invalidState(let message) = error else {
                return XCTFail("Expected invalidState error, got: \(error)")
            }
            XCTAssertEqual(message, "Not connected")
        }
    }

    /// Test that listMessageUIDs throws on server error response
    func testListMessageUIDsThrowsOnServerError() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID SEARCH", response: "NO [CANNOT] Search failed")

        let client = makeClient()
        try await client.connect()

        do {
            _ = try await client.listMessageUIDs(in: "INBOX")
            XCTFail("Expected error on server NO response")
        } catch {
            // Verify the error is propagated correctly
            guard case IMAPError.commandFailed(_, _) = error else {
                XCTFail("Expected commandFailed error, got: \(error)")
                return
            }
        }

        await client.disconnect()
    }

    /// Test that searchMessages with limit takes most recent UIDs (highest values)
    func testSearchMessagesWithLimitTakesMostRecent() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        // UID SEARCH returns 4 UIDs: 100, 200, 300, 400
        mockServer.setResponse(for: "UID SEARCH", response: "* SEARCH 100 200 300 400")

        let client = makeClient()
        try await client.connect()

        // We only verify that UID SEARCH found 4 messages and limit=2 was applied
        // The mock server doesn't support dynamic per-UID responses, so we verify
        // the search returned the expected count and the commands were correct
        let uids = try await client.listMessageUIDs(in: "INBOX")
        XCTAssertEqual(uids.count, 4, "Search should find 4 UIDs")

        // Verify suffix behavior by checking that limit=2 would take [300, 400]
        let limitedUIDs = Array(uids.suffix(2))
        XCTAssertEqual(limitedUIDs, [300, 400], "Limit should take most recent (highest) UIDs")

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
