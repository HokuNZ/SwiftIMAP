import XCTest
@testable import SwiftIMAP
import NIO

/// Integration tests for IMAP authentication flow
/// These tests use a mock IMAP server to verify the complete authentication process
final class IMAPIntegrationTests: XCTestCase {
    
    var eventLoopGroup: MultiThreadedEventLoopGroup!
    var mockServer: MockIMAPServer!
    var serverPort: Int!
    
    override func setUp() async throws {
        try await super.setUp()
        if ProcessInfo.processInfo.environment["CI"] != nil {
            throw XCTSkip("Integration tests are disabled in CI")
        }
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        mockServer = MockIMAPServer(eventLoopGroup: eventLoopGroup)
        serverPort = try await mockServer.start()
    }
    
    override func tearDown() async throws {
        try await mockServer.shutdown()
        try await eventLoopGroup.shutdownGracefully()
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
