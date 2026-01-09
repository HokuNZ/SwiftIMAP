import XCTest
@testable import SwiftIMAP
import NIO

final class IMAPClientAuthenticationTests: XCTestCase {
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

    func testAuthenticateSaslUsesInitialResponseWithSaslIR() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR")
        mockServer.setAuthenticateResponse("OK AUTHENTICATE completed")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .sasl(
                mechanism: "PLAIN",
                initialResponse: "initial-response",
                responseHandler: { _ in "ignored" }
            )
        )

        let client = IMAPClient(configuration: config)
        try await client.connect()

        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("AUTHENTICATE PLAIN") })
        XCTAssertTrue(commands.contains { $0.contains("INITIAL-RESPONSE") })
        XCTAssertTrue(mockServer.receivedContinuations.isEmpty)

        await client.disconnect()
    }

    func testAuthenticateOAuth2UsesSaslMechanism() async throws {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 AUTH=XOAUTH2 SASL-IR")
        mockServer.setAuthenticateResponse("OK AUTHENTICATE completed")

        let username = "user@example.com"
        let token = "token123"
        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .oauth2(username: username, accessToken: token)
        )

        let client = IMAPClient(configuration: config)
        try await client.connect()

        let authString = "user=\(username)\u{01}auth=Bearer \(token)\u{01}\u{01}"
        let expected = Data(authString.utf8).base64EncodedString().uppercased()

        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("AUTHENTICATE XOAUTH2") })
        XCTAssertTrue(commands.contains { $0.contains(expected) })
        XCTAssertTrue(mockServer.receivedContinuations.isEmpty)

        await client.disconnect()
    }
}
