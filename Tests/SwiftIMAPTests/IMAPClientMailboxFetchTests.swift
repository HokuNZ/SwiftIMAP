import XCTest
@testable import SwiftIMAP
import NIO

final class IMAPClientMailboxFetchTests: XCTestCase {
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

    func testListMailboxesAndSubscribedMailboxes() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "LIST", response: #"""
* LIST (\HasNoChildren) "/" "INBOX"
* LIST (\Noselect \HasChildren) "/" "Archive"
"""#)
        mockServer.setResponse(for: "LSUB", response: #"""
* LSUB (\HasNoChildren) "/" "INBOX"
"""#)

        let client = makeClient()
        try await client.connect()

        let mailboxes = try await client.listMailboxes()
        XCTAssertEqual(mailboxes.count, 2)
        let inbox = mailboxes.first { $0.name == "INBOX" }
        let archive = mailboxes.first { $0.name == "Archive" }

        XCTAssertEqual(inbox?.delimiter, "/")
        XCTAssertTrue(inbox?.attributes.contains(.hasNoChildren) ?? false)
        XCTAssertTrue(archive?.attributes.contains(.noselect) ?? false)
        XCTAssertTrue(archive?.attributes.contains(.hasChildren) ?? false)

        let subscribed = try await client.listSubscribedMailboxes()
        XCTAssertEqual(subscribed.count, 1)
        XCTAssertEqual(subscribed.first?.name, "INBOX")

        await client.disconnect()
    }

    func testMailboxManagementCommandsAreSent() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "CREATE", response: "OK CREATE completed")
        mockServer.setResponse(for: "RENAME", response: "OK RENAME completed")
        mockServer.setResponse(for: "SUBSCRIBE", response: "OK SUBSCRIBE completed")
        mockServer.setResponse(for: "UNSUBSCRIBE", response: "OK UNSUBSCRIBE completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "CHECK", response: "OK CHECK completed")
        mockServer.setResponse(for: "CLOSE", response: "OK CLOSE completed")
        mockServer.setResponse(for: "DELETE", response: "OK DELETE completed")

        let client = makeClient()
        try await client.connect()

        try await client.createMailbox("Projects")
        try await client.renameMailbox(from: "Projects", to: "Projects/2024")
        try await client.subscribeMailbox("Projects/2024")
        try await client.unsubscribeMailbox("Projects/2024")

        _ = try await client.selectMailbox("INBOX")
        try await client.checkMailbox()
        try await client.closeMailbox()

        try await client.deleteMailbox("Projects/2024")

        await client.disconnect()

        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("CREATE") })
        XCTAssertTrue(commands.contains { $0.contains("RENAME") })
        XCTAssertTrue(commands.contains { $0.contains("SUBSCRIBE") })
        XCTAssertTrue(commands.contains { $0.contains("UNSUBSCRIBE") })
        XCTAssertTrue(commands.contains { $0.contains("SELECT") })
        XCTAssertTrue(commands.contains { $0.contains("CHECK") })
        XCTAssertTrue(commands.contains { $0.contains("CLOSE") })
        XCTAssertTrue(commands.contains { $0.contains("DELETE") })
    }

    func testMailboxStatusThrowsWithoutUntaggedStatus() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")

        let client = makeClient()
        try await client.connect()

        do {
            _ = try await client.mailboxStatus("INBOX")
            XCTFail("Expected mailboxStatus to throw")
        } catch {
            guard case IMAPError.protocolError(let message) = error else {
                return XCTFail("Expected protocolError")
            }
            XCTAssertTrue(message.contains("STATUS"))
        }

        await client.disconnect()
    }

    func testListMessageUIDsWithCharsetReturnsEmpty() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID SEARCH", response: "* SEARCH")

        let client = makeClient()
        try await client.connect()

        let results = try await client.listMessageUIDs(
            in: "INBOX",
            searchCriteria: .header(field: "Subject", value: "Test"),
            charset: "UTF-8"
        )
        XCTAssertTrue(results.isEmpty)

        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("UID SEARCH") && $0.contains("CHARSET") },
                      "Charset must propagate on the UID SEARCH command")
        XCTAssertTrue(commands.contains { $0.contains("UTF-8") })

        await client.disconnect()
    }

    func testFetchMessageReturnsNilWhenMissingFetch() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID FETCH", response: "OK UID FETCH completed")

        let client = makeClient()
        try await client.connect()

        let summary = try await client.fetchMessage(uid: 42, in: "INBOX")
        XCTAssertNil(summary)

        await client.disconnect()
    }

    func testFetchMessageBodyPeekControlsCommand() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID FETCH", response: "* 1 FETCH (UID 1 BODY[] {5}\r\nHello)")

        let client = makeClient()
        try await client.connect()

        let peekData = try await client.fetchMessageBody(uid: 1, in: "INBOX", peek: true)
        let peekString = peekData.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(peekString, "Hello")

        let fullData = try await client.fetchMessageBody(uid: 1, in: "INBOX", peek: false)
        let fullString = fullData.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(fullString, "Hello")

        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("BODY.PEEK[]") })
        XCTAssertTrue(commands.contains { $0.contains("BODY[]") && !$0.contains("BODY.PEEK[]") })

        await client.disconnect()
    }

    func testFetchMessageBodyReturnsNilWhenNoBodyAttribute() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID FETCH", response: "* 1 FETCH (UID 1 FLAGS (\\Seen))")

        let client = makeClient()
        try await client.connect()

        let data = try await client.fetchMessageBody(uid: 1, in: "INBOX")
        XCTAssertNil(data)

        await client.disconnect()
    }

    func testFetchMessageBodyHandlesPeekAttribute() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID FETCH", response: "* 1 FETCH (UID 1 BODY.PEEK[] {5}\r\nHello)")

        let client = makeClient()
        try await client.connect()

        let data = try await client.fetchMessageBody(uid: 1, in: "INBOX", peek: true)
        XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "Hello")

        await client.disconnect()
    }

    func testFetchMessageSurfacesCustomKeywords() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(
            for: "UID FETCH",
            response: "* 1 FETCH (UID 1 FLAGS (\\Answered $Forwarded @Triaged) " +
                      "INTERNALDATE \"17-Jul-1996 02:44:25 -0700\" RFC822.SIZE 4286)"
        )

        let client = makeClient()
        try await client.connect()

        let summary = try await client.fetchMessage(
            uid: 1,
            in: "INBOX",
            items: [.uid, .flags, .internalDate, .rfc822Size]
        )

        XCTAssertNotNil(summary)
        // Standard system flags stay in `flags`; custom keywords are surfaced separately.
        XCTAssertEqual(summary?.flags, [.answered])
        XCTAssertEqual(summary?.keywords, ["$Forwarded", "@Triaged"])

        await client.disconnect()
    }

    /// A reduced item set still yields a complete summary: the required
    /// attributes (UID, internal date, size) are auto-added to the fetch, so the
    /// caller never hits a "missing required attributes" parse failure.
    func testFetchWithReducedItemSetAutoAddsSummaryAttributes() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(
            for: "UID FETCH",
            response: "* 1 FETCH (UID 1 FLAGS (\\Seen) " +
                      "INTERNALDATE \"17-Jul-1996 02:44:25 -0700\" RFC822.SIZE 42)"
        )

        let client = makeClient()
        try await client.connect()

        // Caller requests only flags; UID/INTERNALDATE/RFC822.SIZE are added.
        let summary = try await client.fetchMessage(uid: 1, in: "INBOX", items: [.flags])

        XCTAssertNotNil(summary, "A reduced item set must still yield a summary, not a parse failure")
        XCTAssertEqual(summary?.uid, 1)
        XCTAssertEqual(summary?.size, 42)

        let fetch = mockServer.receivedCommands.first { $0.uppercased().contains("UID FETCH") } ?? ""
        let upper = fetch.uppercased()
        // Assert UID is in the fetch item list (inside the parens), not just the
        // "UID FETCH" verb — `contains("UID")` would pass on the verb alone.
        XCTAssertTrue(upper.contains("(UID"), "auto-added UID in item list: \(fetch)")
        XCTAssertTrue(upper.contains("INTERNALDATE"), "auto-added INTERNALDATE: \(fetch)")
        XCTAssertTrue(upper.contains("RFC822.SIZE"), "auto-added RFC822.SIZE: \(fetch)")

        await client.disconnect()
    }

    /// `summaryFetchItems` adds the missing required attributes, never duplicates
    /// present ones, and treats the ALL/FAST/FULL macros as already covering
    /// INTERNALDATE/RFC822.SIZE (adding only UID, which no macro includes).
    func testSummaryFetchItemsAddsMissingWithoutDuplicating() {
        func count(_ items: [IMAPCommand.FetchItem], _ test: (IMAPCommand.FetchItem) -> Bool) -> Int {
            items.filter(test).count
        }
        let isUID: (IMAPCommand.FetchItem) -> Bool = { if case .uid = $0 { return true }; return false }
        let isDate: (IMAPCommand.FetchItem) -> Bool = { if case .internalDate = $0 { return true }; return false }
        let isSize: (IMAPCommand.FetchItem) -> Bool = { if case .rfc822Size = $0 { return true }; return false }

        // Reduced set: all three required attributes are added.
        let fromFlags = IMAPClient.summaryFetchItems([.flags])
        XCTAssertEqual(count(fromFlags, isUID), 1)
        XCTAssertEqual(count(fromFlags, isDate), 1)
        XCTAssertEqual(count(fromFlags, isSize), 1)

        // Partial set: items already present are not duplicated.
        let fromUIDFlags = IMAPClient.summaryFetchItems([.uid, .flags])
        XCTAssertEqual(count(fromUIDFlags, isUID), 1, "UID must not be duplicated")
        XCTAssertEqual(count(fromUIDFlags, isDate), 1)
        XCTAssertEqual(count(fromUIDFlags, isSize), 1)

        // Macro covers date/size; only UID is added (no redundant explicit items).
        let fromAll = IMAPClient.summaryFetchItems([.all])
        XCTAssertEqual(count(fromAll, isUID), 1)
        XCTAssertEqual(count(fromAll, isDate), 0, "ALL already covers INTERNALDATE")
        XCTAssertEqual(count(fromAll, isSize), 0, "ALL already covers RFC822.SIZE")

        // Complete set is unchanged.
        XCTAssertEqual(IMAPClient.summaryFetchItems([.uid, .internalDate, .rfc822Size, .flags]).count, 4)
    }

    func testFetchMessageWithoutCustomKeywordsHasEmptyKeywords() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(
            for: "UID FETCH",
            response: "* 1 FETCH (UID 1 FLAGS (\\Seen) " +
                      "INTERNALDATE \"17-Jul-1996 02:44:25 -0700\" RFC822.SIZE 100)"
        )

        let client = makeClient()
        try await client.connect()

        let summary = try await client.fetchMessage(
            uid: 1,
            in: "INBOX",
            items: [.uid, .flags, .internalDate, .rfc822Size]
        )

        XCTAssertEqual(summary?.flags, [.seen])
        XCTAssertTrue(summary?.keywords.isEmpty ?? false)

        await client.disconnect()
    }

    func testListMessageUIDsThrowsWhenDisconnected() async {
        let client = makeClient()

        do {
            _ = try await client.listMessageUIDs(in: "INBOX")
            XCTFail("Expected listMessageUIDs to throw when disconnected")
        } catch {
            guard case IMAPError.invalidState(let message) = error else {
                return XCTFail("Expected invalidState error")
            }
            XCTAssertEqual(message, "Not connected")
        }
    }

    func testFetchMessageThrowsWhenDisconnected() async {
        let client = makeClient()

        do {
            _ = try await client.fetchMessage(uid: 1, in: "INBOX")
            XCTFail("Expected fetchMessage to throw when disconnected")
        } catch {
            guard case IMAPError.invalidState(let message) = error else {
                return XCTFail("Expected invalidState error")
            }
            XCTAssertEqual(message, "Not connected")
        }
    }

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
