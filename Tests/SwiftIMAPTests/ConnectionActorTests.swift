import XCTest
@testable import SwiftIMAP
import NIO

final class ConnectionActorTests: XCTestCase {
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

    func testSendCommandThrowsWhenDisconnected() async {
        let connection = ConnectionActor(configuration: makeConfig(), tlsConfiguration: TLSConfiguration())

        do {
            _ = try await connection.sendCommand(.capability)
            XCTFail("Expected sendCommand to throw")
        } catch {
            guard case IMAPError.invalidState(let message) = error else {
                return XCTFail("Expected invalidState error")
            }
            XCTAssertEqual(message, "Not connected")
        }
    }

    func testStartTLSThrowsWhenDisconnected() async {
        let connection = ConnectionActor(configuration: makeConfig(), tlsConfiguration: TLSConfiguration())

        do {
            try await connection.startTLS()
            XCTFail("Expected startTLS to throw")
        } catch {
            guard case IMAPError.disconnected = error else {
                return XCTFail("Expected disconnected error")
            }
        }
    }

    func testConnectionStateTransitions() async throws {
        let connection = ConnectionActor(configuration: makeConfig(), tlsConfiguration: TLSConfiguration())

        _ = try await connection.connect()
        let connectedState = await connection.getConnectionState()
        XCTAssertEqual(connectedState, "connected")

        await connection.setAuthenticated()
        let authenticatedState = await connection.getConnectionState()
        XCTAssertEqual(authenticatedState, "authenticated")

        await connection.setSelected(mailbox: "INBOX", readOnly: true)
        let selectedState = await connection.getConnectionState()
        XCTAssertEqual(selectedState, "selected(INBOX, readOnly: true)")

        await connection.disconnect()
        let disconnectedState = await connection.getConnectionState()
        XCTAssertEqual(disconnectedState, "disconnected")
    }

    func testConnectRejectsSecondConnection() async throws {
        let connection = ConnectionActor(configuration: makeConfig(), tlsConfiguration: TLSConfiguration())

        _ = try await connection.connect()

        do {
            _ = try await connection.connect()
            XCTFail("Expected second connect to throw")
        } catch {
            guard case IMAPError.invalidState(let message) = error else {
                return XCTFail("Expected invalidState error")
            }
            XCTAssertEqual(message, "Already connected or connecting")
        }

        await connection.disconnect()
    }

    private func makeConfig() -> IMAPConfiguration {
        IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "user", password: "pass")
        )
    }
}
