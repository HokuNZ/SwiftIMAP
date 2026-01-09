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

    func testListMessagesWithCharsetReturnsEmpty() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "SEARCH", response: "* SEARCH")

        let client = makeClient()
        try await client.connect()

        let results = try await client.listMessages(
            in: "INBOX",
            searchCriteria: .header(field: "Subject", value: "Test"),
            charset: "UTF-8"
        )
        XCTAssertTrue(results.isEmpty)

        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("SEARCH") && $0.contains("CHARSET") })
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
