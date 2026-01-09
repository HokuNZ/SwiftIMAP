import XCTest
@testable import SwiftIMAP
import NIO

/// Integration tests for IMAP authentication flow
/// These tests use a mock IMAP server to verify the complete authentication process
final class IMAPIntegrationTests: XCTestCase {
    
    var eventLoopGroup: MultiThreadedEventLoopGroup!
    var mockServer: MockIMAPServer!
    var serverPort: Int!

    private actor ChallengeRecorder {
        private var challenges: [String?] = []

        func record(_ value: String?) {
            challenges.append(value)
        }

        func all() -> [String?] {
            challenges
        }
    }
    
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
    
    // MARK: - Authentication Tests
    
    func testLoginAuthentication() async throws {
        // Configure mock server responses
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        
        // Create client with test configuration
        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass"),
            logLevel: .debug
        )
        
        let client = IMAPClient(configuration: config)
        
        // Test connection and authentication
        try await client.connect()
        
        // Verify server received correct commands
        let commands = mockServer.receivedCommands
        XCTAssertTrue(commands.contains { $0.contains("CAPABILITY") })
        XCTAssertTrue(commands.contains { command in
            command.uppercased().contains("LOGIN") &&
            command.contains("testuser") &&
            command.contains("testpass")
        })
        
        // Disconnect
        await client.disconnect()
    }
    
    func testPlainAuthentication() async throws {
        // Configure mock server responses
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 AUTH=PLAIN")
        mockServer.setResponse(for: "AUTHENTICATE PLAIN", response: "+")
        mockServer.setAuthenticateResponse("OK AUTHENTICATE completed")
        
        // Create client with PLAIN auth
        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .plain(username: "testuser", password: "testpass"),
            logLevel: .debug
        )
        
        let client = IMAPClient(configuration: config)
        
        // Test connection and authentication
        try await client.connect()
        
        // Verify PLAIN authentication was used
        let commands = mockServer.receivedCommands
        XCTAssertTrue(commands.contains { $0.contains("AUTHENTICATE PLAIN") })
        
        // Disconnect
        await client.disconnect()
    }

    func testPreauthGreetingSkipsAuthentication() async throws {
        mockServer.responses["GREETING"] = "* PREAUTH IMAP4rev1"
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 AUTH=PLAIN")
        
        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass"),
            logLevel: .debug
        )
        
        let client = IMAPClient(configuration: config)
        
        try await client.connect()
        
        let commands = mockServer.receivedCommands
        XCTAssertFalse(commands.contains { $0.uppercased().contains("LOGIN") })
        XCTAssertFalse(commands.contains { $0.uppercased().contains("AUTHENTICATE") })
        
        await client.disconnect()
    }

    func testExternalAuthenticationContinuation() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 AUTH=EXTERNAL")
        mockServer.setResponse(for: "AUTHENTICATE EXTERNAL", response: "+")
        mockServer.setAuthenticateResponse("OK AUTHENTICATE completed")
        
        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .external,
            logLevel: .debug
        )
        
        let client = IMAPClient(configuration: config)
        
        try await client.connect()
        
        let commands = mockServer.receivedCommands
        XCTAssertTrue(commands.contains { $0.uppercased().contains("AUTHENTICATE EXTERNAL") })
        
        await client.disconnect()
    }

    func testAuthenticatePlainHandlesMultipleChallenges() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 AUTH=PLAIN")
        mockServer.setAuthenticateChallenges(["first", "second"])
        mockServer.setAuthenticateResponse("OK AUTHENTICATE completed")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .plain(username: "testuser", password: "testpass"),
            logLevel: .debug
        )

        let client = IMAPClient(configuration: config)

        try await client.connect()

        let expectedAuth = Data("\0testuser\0testpass".utf8).base64EncodedString()
        XCTAssertEqual(mockServer.receivedContinuations.first ?? "", expectedAuth)
        XCTAssertEqual(mockServer.receivedContinuations.last ?? "", "")

        await client.disconnect()
    }

    func testAuthenticateSaslHandlesMultipleChallenges() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 AUTH=PLAIN")
        mockServer.setAuthenticateChallenges(["first", "second", "third"])
        mockServer.setAuthenticateResponse("OK AUTHENTICATE completed")

        let recorder = ChallengeRecorder()
        let handler: IMAPConfiguration.SASLResponseHandler = { challenge in
            await recorder.record(challenge)
            switch challenge {
            case "second":
                return "response-2"
            case "third":
                return "response-3"
            default:
                return ""
            }
        }

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .sasl(
                mechanism: "PLAIN",
                initialResponse: "initial",
                responseHandler: handler
            ),
            logLevel: .debug
        )

        let client = IMAPClient(configuration: config)

        try await client.connect()

        let challenges = await recorder.all()

        XCTAssertTrue(mockServer.receivedCommands.contains { $0.uppercased().contains("AUTHENTICATE PLAIN") })
        XCTAssertEqual(mockServer.receivedContinuations, ["initial", "response-2", "response-3"])
        XCTAssertEqual(challenges, ["second", "third"])

        await client.disconnect()
    }

    func testLoginDisabledCapabilityBlocksLogin() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGINDISABLED")
        
        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass"),
            logLevel: .debug
        )
        
        let client = IMAPClient(configuration: config)
        
        do {
            try await client.connect()
            XCTFail("Expected LOGINDISABLED to block LOGIN")
        } catch {
            if case IMAPError.unsupportedCapability(let capability) = error {
                XCTAssertEqual(capability, "LOGINDISABLED")
            } else {
                XCTFail("Expected unsupportedCapability error")
            }
        }
        
        let commands = mockServer.receivedCommands
        XCTAssertTrue(commands.contains { $0.uppercased().contains("CAPABILITY") })
        XCTAssertFalse(commands.contains { $0.uppercased().contains("LOGIN") })
    }
    
    func testAuthenticationFailure() async throws {
        // Configure mock server to reject login
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "NO [AUTHENTICATIONFAILED] Invalid credentials")
        
        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "baduser", password: "badpass"),
            logLevel: .debug
        )
        
        let client = IMAPClient(configuration: config)
        
        // Test that authentication failure is properly handled
        do {
            try await client.connect()
            XCTFail("Expected authentication to fail")
        } catch {
            // Expected error
            XCTAssertTrue(error.localizedDescription.contains("authentication") || 
                         error.localizedDescription.contains("Invalid credentials"))
        }
    }
    
    // MARK: - Connection Tests
    
    func testConnectionTimeout() async throws {
        // Create a client that connects to a non-existent server
        let config = IMAPConfiguration(
            hostname: "localhost",
            port: 9999, // Invalid port
            tlsMode: .disabled,
            authMethod: .login(username: "user", password: "pass"),
            connectionTimeout: 1.0 // 1 second timeout
        )
        
        let client = IMAPClient(configuration: config)
        
        // Test that connection times out
        do {
            try await client.connect()
            XCTFail("Expected connection to fail")
        } catch {
            if let imapError = error as? IMAPError {
                switch imapError {
                case .timeout, .connectionFailed, .connectionError:
                    break
                default:
                    XCTFail("Unexpected error: \(imapError)")
                }
            } else {
                XCTAssertTrue(error.localizedDescription.contains("timeout") ||
                              error.localizedDescription.contains("connect"))
            }
        }
    }
    
    func testReconnection() async throws {
        // Configure mock server
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT \"INBOX\"", response: "OK [READ-WRITE] SELECT completed")
        
        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )
        
        let client = IMAPClient(configuration: config)
        
        // First connection
        try await client.connect()
        let status1 = try await client.selectMailbox("INBOX")
        XCTAssertNotNil(status1)
        
        // Disconnect
        await client.disconnect()
        
        // Reconnect
        try await client.connect()
        let status2 = try await client.selectMailbox("INBOX")
        XCTAssertNotNil(status2)
        
        await client.disconnect()
    }
    
    // MARK: - Command Flow Tests
    
    func testCompleteMessageFetchFlow() async throws {
        // Configure mock server with complete flow
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT \"INBOX\"", response: """
            * 42 EXISTS
            * 1 RECENT
            * OK [UNSEEN 1]
            * OK [UIDVALIDITY 1234567890]
            * OK [UIDNEXT 43]
            """)
        mockServer.setResponse(for: "SEARCH ALL", response: """
            * SEARCH 1 2 3
            """)
        mockServer.setResponse(for: "UID FETCH", response: """
            * 1 FETCH (UID 1 FLAGS (\\Seen) INTERNALDATE "01-Jan-2024 12:00:00 +0000" RFC822.SIZE 1234 ENVELOPE ("Mon, 1 Jan 2024 12:00:00 +0000" "Test Subject" (("Test Sender" NIL "sender" "example.com")) NIL NIL (("Test Recipient" NIL "recipient" "example.com")) NIL NIL NIL "<message-id@example.com>"))
            """)
        
        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )
        
        let client = IMAPClient(configuration: config)
        
        // Execute complete flow
        try await client.connect()
        
        // Select mailbox
        let selectStatus = try await client.selectMailbox("INBOX")
        XCTAssertEqual(selectStatus.messages, 42)
        XCTAssertEqual(selectStatus.recent, 1)
        
        // Search messages
        let messageNumbers = try await client.listMessages(in: "INBOX")
        XCTAssertEqual(messageNumbers, [1, 2, 3])
        
        // Fetch message
        let message = try await client.fetchMessage(uid: 1, in: "INBOX")
        XCTAssertNotNil(message)
        XCTAssertEqual(message?.uid, 1)
        XCTAssertEqual(message?.envelope?.subject, "Test Subject")
        
        await client.disconnect()
    }

    func testMailboxStatusParsesResponse() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "STATUS", response: """
            * STATUS "INBOX" (MESSAGES 4 RECENT 1 UIDNEXT 7 UIDVALIDITY 42 UNSEEN 2)
            """)

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )

        let client = IMAPClient(configuration: config)

        try await client.connect()
        let status = try await client.mailboxStatus("INBOX")
        XCTAssertEqual(status.messages, 4)
        XCTAssertEqual(status.recent, 1)
        XCTAssertEqual(status.uidNext, 7)
        XCTAssertEqual(status.uidValidity, 42)
        XCTAssertEqual(status.unseen, 2)
        await client.disconnect()
    }

    func testFetchMessageBySequenceReturnsSummary() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT \"INBOX\"", response: "* 1 EXISTS")
        mockServer.setResponse(for: "FETCH", response: """
            * 2 FETCH (UID 99 FLAGS (\\Seen) INTERNALDATE "01-Jan-2024 12:00:00 +0000" RFC822.SIZE 1234 ENVELOPE ("Mon, 1 Jan 2024 12:00:00 +0000" "Seq Subject" (("Sender" NIL "sender" "example.com")) NIL NIL (("Recipient" NIL "recipient" "example.com")) NIL NIL NIL "<seq-id@example.com>"))
            """)

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )

        let client = IMAPClient(configuration: config)

        try await client.connect()
        let summary = try await client.fetchMessageBySequence(sequenceNumber: 2, in: "INBOX")
        XCTAssertEqual(summary?.uid, 99)
        XCTAssertEqual(summary?.sequenceNumber, 2)
        XCTAssertEqual(summary?.envelope?.subject, "Seq Subject")
        await client.disconnect()
    }

    func testFetchMessageBodyReturnsLiteral() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT \"INBOX\"", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID FETCH", response: """
            * 1 FETCH (UID 1 BODY[] {11}
            Hello World)
            """)

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )

        let client = IMAPClient(configuration: config)

        try await client.connect()
        let data = try await client.fetchMessageBody(uid: 1, in: "INBOX")
        XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "Hello World")
        await client.disconnect()
    }

    func testMoveMessageFallsBackWithoutMoveCapability() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT \"INBOX\"", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID COPY", response: "OK UID COPY completed")
        mockServer.setResponse(for: "UID STORE", response: "OK UID STORE completed")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )

        let client = IMAPClient(configuration: config)

        try await client.connect()
        try await client.moveMessage(uid: 7, from: "INBOX", to: "Archive")

        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("UID COPY") })
        XCTAssertTrue(commands.contains { $0.contains("UID STORE") })
        XCTAssertFalse(commands.contains { $0.contains("UID MOVE") })

        await client.disconnect()
    }

    func testExpungeUsesUidPlusWhenSupported() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 UIDPLUS LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT \"INBOX\"", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID EXPUNGE", response: "OK UID EXPUNGE completed")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )

        let client = IMAPClient(configuration: config)

        try await client.connect()
        try await client.expunge(uids: [1, 2], in: "INBOX")

        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("UID EXPUNGE") })

        await client.disconnect()
    }

    func testExpungeFallsBackWithoutUidPlus() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT \"INBOX\"", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "EXPUNGE", response: "OK EXPUNGE completed")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )

        let client = IMAPClient(configuration: config)

        try await client.connect()
        try await client.expunge(uids: [3], in: "INBOX")

        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("EXPUNGE") && !$0.contains("UID EXPUNGE") })
        XCTAssertFalse(commands.contains { $0.contains("UID EXPUNGE") })

        await client.disconnect()
    }

    func testSelectParsesUntaggedStatusCodes() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT \"INBOX\"", response: """
            * 5 EXISTS
            * 2 RECENT
            * OK [UNSEEN 2]
            * OK [UIDVALIDITY 999]
            * OK [UIDNEXT 6]
            """)

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )

        let client = IMAPClient(configuration: config)

        try await client.connect()
        let status = try await client.selectMailbox("INBOX")
        XCTAssertEqual(status.messages, 5)
        XCTAssertEqual(status.recent, 2)
        XCTAssertEqual(status.unseen, 2)
        XCTAssertEqual(status.uidValidity, 999)
        XCTAssertEqual(status.uidNext, 6)
        await client.disconnect()
    }

    func testSelectParsesFlagsAndAccess() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT \"INBOX\"", response: """
            * 3 EXISTS
            * FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)
            * OK [PERMANENTFLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft \\*)]
            * OK [READ-WRITE]
            """)

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )

        let client = IMAPClient(configuration: config)

        try await client.connect()
        let status = try await client.selectMailbox("INBOX")

        XCTAssertEqual(status.messages, 3)
        XCTAssertEqual(status.access, .readWrite)
        XCTAssertEqual(Set(status.flags ?? []), Set(["\\Answered", "\\Flagged", "\\Deleted", "\\Seen", "\\Draft"]))
        XCTAssertEqual(
            Set(status.permanentFlags ?? []),
            Set(["\\Answered", "\\Flagged", "\\Deleted", "\\Seen", "\\Draft", "\\*"])
        )

        await client.disconnect()
    }

    func testExamineParsesReadOnlyAccess() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "EXAMINE \"INBOX\"", response: "OK [READ-ONLY] EXAMINE completed")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )

        let client = IMAPClient(configuration: config)

        try await client.connect()
        let status = try await client.examineMailbox("INBOX")
        XCTAssertEqual(status.access, .readOnly)
        await client.disconnect()
    }

    func testExamineSubscribeAndCloseMailbox() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "EXAMINE \"INBOX\"", response: """
            * 2 EXISTS
            * 0 RECENT
            """)
        mockServer.setResponse(for: "CHECK", response: "OK CHECK completed")
        mockServer.setResponse(for: "CLOSE", response: "OK CLOSE completed")
        mockServer.setResponse(for: "SUBSCRIBE", response: "OK SUBSCRIBE completed")
        mockServer.setResponse(for: "UNSUBSCRIBE", response: "OK UNSUBSCRIBE completed")
        mockServer.setResponse(for: "LSUB", response: """
            * LSUB () "/" "INBOX"
            """)

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )

        let client = IMAPClient(configuration: config)

        try await client.connect()

        let status = try await client.examineMailbox("INBOX")
        XCTAssertEqual(status.messages, 2)
        XCTAssertEqual(status.recent, 0)

        try await client.checkMailbox()
        try await client.closeMailbox()

        do {
            try await client.checkMailbox()
            XCTFail("Expected CHECK to fail after CLOSE")
        } catch {
            if case IMAPError.invalidState = error {
                XCTAssertTrue(true)
            } else {
                XCTFail("Expected invalidState error")
            }
        }

        try await client.subscribeMailbox("INBOX")
        let subscribed = try await client.listSubscribedMailboxes()
        XCTAssertTrue(subscribed.contains { $0.name == "INBOX" })
        try await client.unsubscribeMailbox("INBOX")

        await client.disconnect()
    }
}

// MARK: - Mock IMAP Server

class MockIMAPServer {
    private let eventLoopGroup: EventLoopGroup
    private var channel: Channel?
    var responses: [String: String] = [:]
    private var authenticateResponse: String?
    private var authenticateChallenges: [String] = []
    private var pendingAuthTag: String?
    private var pendingAuthChallenges: [String] = []
    private(set) var receivedCommands: [String] = []
    private(set) var receivedContinuations: [String] = []
    
    init(eventLoopGroup: EventLoopGroup) {
        self.eventLoopGroup = eventLoopGroup
        // Set default greeting
        responses["GREETING"] = "* OK Mock IMAP Server Ready"
    }
    
    func setResponse(for command: String, response: String) {
        responses[command] = response
    }
    
    func setAuthenticateResponse(_ response: String) {
        authenticateResponse = response
    }

    func setAuthenticateChallenges(_ challenges: [String]) {
        authenticateChallenges = challenges
    }
    
    func start() async throws -> Int {
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(MockIMAPDecoder()),
                    MessageToByteHandler(MockIMAPEncoder()),
                    MockIMAPHandler(server: self)
                ])
            }
        
        channel = try await bootstrap.bind(host: "localhost", port: 0).get()
        guard let localAddress = channel?.localAddress,
              let port = localAddress.port else {
            throw IMAPError.connectionError("Failed to get server port")
        }
        
        return port
    }
    
    func shutdown() async throws {
        try await channel?.close()
    }
    
    func handleCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        receivedCommands.append(trimmed)

        if let pendingTag = pendingAuthTag {
            receivedContinuations.append(trimmed)
            if !pendingAuthChallenges.isEmpty {
                let challenge = pendingAuthChallenges.removeFirst()
                return challenge.isEmpty ? "+" : "+ \(challenge)"
            }
            pendingAuthTag = nil
            return formatAuthenticateResponse(tag: pendingTag)
        }
        
        guard !trimmed.isEmpty else {
            return "* BAD Empty command"
        }
        
        // Extract tag and command
        let parts = trimmed.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            return "* BAD Invalid command"
        }
        
        let tag = String(parts[0])
        let cmd = String(parts[1]).uppercased()
        let remainder = parts.count > 2 ? String(parts[2]) : ""
        let commandAndArgs = String(trimmed.dropFirst(tag.count + 1))
        let remainderParts = remainder.split(separator: " ", maxSplits: 1)
        let subcommandKey = remainderParts.first.map { "\(cmd) \(String($0))" }
        
        if cmd == "AUTHENTICATE" {
            let remainderParts = remainder.split(separator: " ", maxSplits: 1)
            let mechanism = remainderParts.first.map { String($0).uppercased() } ?? ""
            let hasInitialResponse = remainderParts.count > 1

            if !authenticateChallenges.isEmpty {
                pendingAuthTag = tag
                pendingAuthChallenges = authenticateChallenges
                let challenge = pendingAuthChallenges.removeFirst()
                return challenge.isEmpty ? "+" : "+ \(challenge)"
            }

            if hasInitialResponse {
                return formatAuthenticateResponse(tag: tag)
            }

            pendingAuthTag = tag
            return responses["AUTHENTICATE \(mechanism)"] ?? "+"
        }
        
        // Find response for command
        if let response = responses[commandAndArgs]
            ?? responses[commandAndArgs.uppercased()]
            ?? subcommandKey.flatMap({ responses[$0] ?? responses[$0.uppercased()] })
            ?? responses[cmd] {
            if response.hasPrefix("*") || response.hasPrefix("+") {
                return "\(response)\r\n\(tag) OK \(cmd) completed"
            }
            
            let upper = response.uppercased()
            if upper.hasPrefix("OK") || upper.hasPrefix("NO") || upper.hasPrefix("BAD") {
                return "\(tag) \(response)"
            }
            
            return "\(tag) OK \(response)"
        }
        
        // Default response
        return "\(tag) OK \(cmd) completed"
    }
    
    var isAwaitingContinuation: Bool {
        pendingAuthTag != nil
    }
    
    private func formatAuthenticateResponse(tag: String) -> String {
        let response = authenticateResponse ?? "OK AUTHENTICATE completed"
        
        if response.hasPrefix("*") {
            return "\(response)\r\n\(tag) OK AUTHENTICATE completed"
        }
        
        if response.uppercased().hasPrefix("\(tag) ") {
            return response
        }
        
        return "\(tag) \(response)"
    }
}

// MARK: - Mock IMAP Codec

class MockIMAPDecoder: ByteToMessageDecoder {
    typealias InboundOut = String
    
    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let view = buffer.readableBytesView
        guard let lfIndex = view.firstIndex(of: UInt8(ascii: "\n")) else {
            return .needMoreData
        }
        
        let length = view.distance(from: view.startIndex, to: lfIndex) + 1
        guard var lineBuffer = buffer.readSlice(length: length),
              let line = lineBuffer.readString(length: lineBuffer.readableBytes) else {
            return .needMoreData
        }
        
        context.fireChannelRead(wrapInboundOut(line))
        return .continue
    }
}

class MockIMAPEncoder: MessageToByteEncoder {
    typealias OutboundIn = String
    
    func encode(data: String, out: inout ByteBuffer) throws {
        let normalized = data.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        out.writeString(normalized)
        if !normalized.hasSuffix("\r\n") {
            out.writeString("\r\n")
        }
    }
}

class MockIMAPHandler: ChannelInboundHandler {
    typealias InboundIn = String
    typealias OutboundOut = String
    
    private weak var server: MockIMAPServer?
    private var hasGreeted = false
    
    init(server: MockIMAPServer) {
        self.server = server
    }
    
    func channelActive(context: ChannelHandlerContext) {
        // Send greeting
        let greeting = server?.responses["GREETING"] ?? "* OK Ready"
        context.writeAndFlush(wrapOutboundOut(greeting), promise: nil)
        hasGreeted = true
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let rawCommand = unwrapInboundIn(data)
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.isEmpty && (server?.isAwaitingContinuation != true) {
            return
        }
        
        if let response = server?.handleCommand(rawCommand) {
            context.writeAndFlush(wrapOutboundOut(response), promise: nil)
        }
    }
}
