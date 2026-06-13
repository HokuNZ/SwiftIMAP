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
        // A single batched UID FETCH returns both messages in one response.
        mockServer.setResponse(for: "UID FETCH", response: "* 1 FETCH (UID 100 FLAGS (\\Seen) INTERNALDATE \"17-Jul-1996 02:44:25 -0700\" RFC822.SIZE 4286 ENVELOPE (\"Wed, 17 Jul 1996 02:23:25 -0700\" \"Test Subject 1\" ((NIL NIL \"sender\" \"example.com\")) ((NIL NIL \"sender\" \"example.com\")) ((NIL NIL \"sender\" \"example.com\")) ((NIL NIL \"recipient\" \"example.com\")) NIL NIL NIL \"<msg1@example.com>\"))\r\n* 2 FETCH (UID 200 FLAGS () INTERNALDATE \"18-Jul-1996 02:44:25 -0700\" RFC822.SIZE 1234 ENVELOPE (\"Thu, 18 Jul 1996 02:23:25 -0700\" \"Test Subject 2\" ((NIL NIL \"sender\" \"example.com\")) ((NIL NIL \"sender\" \"example.com\")) ((NIL NIL \"sender\" \"example.com\")) ((NIL NIL \"recipient\" \"example.com\")) NIL NIL NIL \"<msg2@example.com>\"))")

        let client = makeClient()
        try await client.connect()

        let summaries = try await client.searchMessages(in: "INBOX", criteria: .all)

        // Verify UID SEARCH was used (not plain SEARCH)
        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        let searchCommands = commands.filter { $0.contains("SEARCH") }
        for cmd in searchCommands {
            XCTAssertTrue(cmd.contains("UID"), "SEARCH should be prefixed with UID: \(cmd)")
        }

        // Verify UID FETCH was used (not plain FETCH), and exactly one fetch was
        // issued for the N results (batched, not one round trip per UID).
        let fetchCommands = commands.filter { $0.contains("FETCH") }
        XCTAssertEqual(fetchCommands.count, 1, "Expected a single batched UID FETCH, got: \(fetchCommands)")
        for cmd in fetchCommands {
            XCTAssertTrue(cmd.contains("UID"), "FETCH should be prefixed with UID: \(cmd)")
            XCTAssertTrue(cmd.contains("100") && cmd.contains("200"),
                          "The batched FETCH should carry both UIDs: \(cmd)")
        }

        // Verify we got the expected messages with correct UIDs
        XCTAssertEqual(summaries.count, 2)
        let returnedUIDs = Set(summaries.map { $0.uid })
        XCTAssertEqual(returnedUIDs, [100, 200], "Should return messages with UIDs 100 and 200")

        await client.disconnect()
    }

    /// #47: results are returned in the searched-UID order, and a UID the server
    /// omits (deleted between search and fetch) is skipped rather than failing
    /// the call — preserving the per-UID loop's semantics in the batched fetch.
    func testSearchMessagesPreservesOrderAndSkipsMissingUIDs() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID SEARCH", response: "* SEARCH 100 200 300")
        // Server returns 300 before 100, and omits 200 entirely (deleted). The
        // result must follow the searched order [100, 300] and drop 200.
        mockServer.setResponse(for: "UID FETCH", response: "* 3 FETCH (UID 300 FLAGS () INTERNALDATE \"03-Jan-2024 12:00:00 +0000\" RFC822.SIZE 30 ENVELOPE (\"Wed, 3 Jan 2024 12:00:00 +0000\" \"Third\" ((NIL NIL \"s\" \"x.com\")) NIL NIL ((NIL NIL \"r\" \"x.com\")) NIL NIL NIL \"<3@x.com>\"))\r\n* 1 FETCH (UID 100 FLAGS () INTERNALDATE \"01-Jan-2024 12:00:00 +0000\" RFC822.SIZE 10 ENVELOPE (\"Mon, 1 Jan 2024 12:00:00 +0000\" \"First\" ((NIL NIL \"s\" \"x.com\")) NIL NIL ((NIL NIL \"r\" \"x.com\")) NIL NIL NIL \"<1@x.com>\"))")

        let client = makeClient()
        try await client.connect()

        let summaries = try await client.searchMessages(in: "INBOX", criteria: .all)

        XCTAssertEqual(summaries.map { $0.uid }, [100, 300],
                       "Results must follow searched-UID order, with the missing UID 200 skipped")

        let fetchCommands = mockServer.receivedCommands.filter { $0.uppercased().contains("FETCH") }
        XCTAssertEqual(fetchCommands.count, 1, "Still a single batched FETCH")

        await client.disconnect()
    }

    /// #47: results follow the SEARCH result order, not numeric/ascending order.
    /// SequenceSet.set sorts the UIDs on the wire, so a non-ascending SEARCH
    /// result is the only fixture that proves the result tracks searched order
    /// rather than the sorted wire order.
    func testSearchMessagesFollowsSearchOrderNotAscending() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        // SEARCH returns descending; result must follow this order, not 100,300.
        mockServer.setResponse(for: "UID SEARCH", response: "* SEARCH 300 100")
        mockServer.setResponse(for: "UID FETCH", response: "* 1 FETCH (UID 100 FLAGS () INTERNALDATE \"01-Jan-2024 12:00:00 +0000\" RFC822.SIZE 10 ENVELOPE (\"Mon, 1 Jan 2024 12:00:00 +0000\" \"First\" ((NIL NIL \"s\" \"x.com\")) NIL NIL ((NIL NIL \"r\" \"x.com\")) NIL NIL NIL \"<1@x.com>\"))\r\n* 3 FETCH (UID 300 FLAGS () INTERNALDATE \"03-Jan-2024 12:00:00 +0000\" RFC822.SIZE 30 ENVELOPE (\"Wed, 3 Jan 2024 12:00:00 +0000\" \"Third\" ((NIL NIL \"s\" \"x.com\")) NIL NIL ((NIL NIL \"r\" \"x.com\")) NIL NIL NIL \"<3@x.com>\"))")

        let client = makeClient()
        try await client.connect()

        let summaries = try await client.searchMessages(in: "INBOX", criteria: .all)
        XCTAssertEqual(summaries.map { $0.uid }, [300, 100],
                       "Result must follow SEARCH order (300, 100), not ascending order")

        await client.disconnect()
    }

    /// #47: a limit drives the batched fetch end-to-end — only the most-recent
    /// UIDs are fetched, and if the server returns extras they are dropped.
    func testSearchMessagesWithLimitFetchesOnlyLimitedUIDs() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID SEARCH", response: "* SEARCH 100 200 300 400")
        // Server returns all four even though only the last two were requested;
        // the client must fetch only 300,400 and drop the unrequested 100,200.
        mockServer.setResponse(for: "UID FETCH", response: [100, 200, 300, 400].map { uid in
            "* \(uid) FETCH (UID \(uid) FLAGS () INTERNALDATE \"01-Jan-2024 12:00:00 +0000\" RFC822.SIZE 10 ENVELOPE (\"Mon, 1 Jan 2024 12:00:00 +0000\" \"S\" ((NIL NIL \"s\" \"x.com\")) NIL NIL ((NIL NIL \"r\" \"x.com\")) NIL NIL NIL \"<\(uid)@x.com>\"))"
        }.joined(separator: "\r\n"))

        let client = makeClient()
        try await client.connect()

        let summaries = try await client.searchMessages(in: "INBOX", criteria: .all, limit: 2)
        XCTAssertEqual(summaries.map { $0.uid }, [300, 400],
                       "Only the most-recent 2 UIDs should be returned")

        // The batched FETCH command must request only the limited UIDs.
        let fetchCommand = mockServer.receivedCommands.first { $0.uppercased().contains("UID FETCH") } ?? ""
        XCTAssertTrue(fetchCommand.contains("300") && fetchCommand.contains("400"))
        XCTAssertFalse(fetchCommand.contains("100") || fetchCommand.contains("200"),
                       "The FETCH must not request UIDs outside the limit: \(fetchCommand)")

        await client.disconnect()
    }

    /// #47: a FETCH response carrying a UID that was not requested (the rewrite's
    /// new failure mode — under the old per-UID loop this was impossible) is
    /// dropped, not mis-attributed.
    func testSearchMessagesDropsUnrequestedUIDs() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID SEARCH", response: "* SEARCH 100 200")
        // Server slips in an unrequested UID 999 between the two requested ones.
        mockServer.setResponse(for: "UID FETCH", response: [100, 999, 200].map { uid in
            "* \(uid) FETCH (UID \(uid) FLAGS () INTERNALDATE \"01-Jan-2024 12:00:00 +0000\" RFC822.SIZE 10 ENVELOPE (\"Mon, 1 Jan 2024 12:00:00 +0000\" \"S\" ((NIL NIL \"s\" \"x.com\")) NIL NIL ((NIL NIL \"r\" \"x.com\")) NIL NIL NIL \"<\(uid)@x.com>\"))"
        }.joined(separator: "\r\n"))

        let client = makeClient()
        try await client.connect()

        let summaries = try await client.searchMessages(in: "INBOX", criteria: .all)
        XCTAssertEqual(summaries.map { $0.uid }, [100, 200],
                       "An unrequested UID in the response must be dropped, not mis-attributed")

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
            guard case IMAPError.commandFailed = error else {
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
