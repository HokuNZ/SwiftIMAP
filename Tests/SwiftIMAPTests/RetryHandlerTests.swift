import XCTest
@testable import SwiftIMAP

final class RetryHandlerTests: XCTestCase {
    private func makeHandler(
        maxAttempts: Int = 3,
        retryableErrors: Set<RetryableError> = .default
    ) -> RetryHandler {
        let config = RetryConfiguration(
            maxAttempts: maxAttempts,
            initialDelay: 0,
            maxDelay: 0,
            multiplier: 1,
            jitter: 0,
            retryableErrors: retryableErrors
        )
        return RetryHandler(configuration: config, logger: Logger(label: "RetryHandlerTests", level: .none))
    }

    func testExecuteReturnsOnFirstAttempt() async throws {
        let handler = makeHandler()
        var attempts = 0

        let result: String = try await handler.execute(operation: "success") {
            attempts += 1
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(attempts, 1)
    }

    func testExecuteRetriesOnTimeout() async throws {
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.timeout])
        var attempts = 0

        let result: String = try await handler.execute(operation: "timeout") {
            attempts += 1
            if attempts == 1 {
                throw IMAPError.timeout
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(attempts, 2)
    }

    func testExecuteRetriesOnTemporaryServerError() async throws {
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.temporaryFailure])
        var attempts = 0

        let result: String = try await handler.execute(operation: "server-temp") {
            attempts += 1
            if attempts == 1 {
                throw IMAPError.serverError("Temporary unavailable")
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(attempts, 2)
    }

    func testExecuteRetriesOnNetworkError() async throws {
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.networkError])
        var attempts = 0

        let result: String = try await handler.execute(operation: "network") {
            attempts += 1
            if attempts == 1 {
                throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "network unreachable"])
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(attempts, 2)
    }

    func testExecuteThrowsNonRetryableError() async {
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.timeout])
        var attempts = 0

        do {
            _ = try await handler.execute(operation: "invalid") {
                attempts += 1
                throw IMAPError.invalidState("not retryable")
            }
            XCTFail("Expected non-retryable error")
        } catch {
            XCTAssertEqual(attempts, 1)
        }
    }

    func testExecuteWithReconnectRecoversAfterReconnect() async throws {
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.connectionLost])
        var attempts = 0
        var reconnects = 0

        let result: String = try await handler.executeWithReconnect(
            operation: "reconnect",
            needsReconnect: { error in
                if case IMAPError.connectionClosed = error { return true }
                return false
            },
            reconnect: {
                reconnects += 1
            },
            work: {
                attempts += 1
                if attempts == 1 {
                    throw IMAPError.connectionClosed
                }
                return "ok"
            }
        )

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(reconnects, 1)
    }

    func testExecuteWithReconnectRetriesOnTimeout() async throws {
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.timeout])
        var attempts = 0

        let result: String = try await handler.executeWithReconnect(
            operation: "timeout-retry",
            needsReconnect: { _ in false },
            reconnect: {},
            work: {
                attempts += 1
                if attempts == 1 {
                    throw IMAPError.timeout
                }
                return "ok"
            }
        )

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(attempts, 2)
    }

    func testErrorDescriptionsCoverAllCases() {
        let cases: [(IMAPError, String)] = [
            (.connectionFailed("oops"), "Connection failed: oops"),
            (.connectionError("down"), "Connection error: down"),
            (.connectionClosed, "Connection closed unexpectedly"),
            (.authenticationFailed("bad"), "Authentication failed: bad"),
            (.tlsError("nope"), "TLS error: nope"),
            (.protocolError("bad"), "Protocol error: bad"),
            (.parsingError("bad"), "Parsing error: bad"),
            (.commandFailed(command: "LOGIN", response: "NO"), "Command 'LOGIN' failed: NO"),
            (.serverError("BUSY"), "Server error: BUSY"),
            (.timeout, "Operation timed out"),
            (.disconnected, "Connection disconnected"),
            (.invalidState("state"), "Invalid state: state"),
            (.unsupportedCapability("ID"), "Unsupported capability: ID"),
            (.mailboxNotFound("INBOX"), "Mailbox not found: INBOX"),
            (.messageNotFound(uid: 42), "Message not found: UID 42"),
            (.quotaExceeded, "Quota exceeded"),
            (.permissionDenied, "Permission denied"),
            (.invalidArgument("bad"), "Invalid argument: bad")
        ]

        for (error, expected) in cases {
            XCTAssertEqual(error.errorDescription, expected)
        }
    }

    func testRequiresReconnectionFlagsConnectionErrors() {
        XCTAssertTrue(IMAPError.connectionError("down").requiresReconnection)
        XCTAssertTrue(IMAPError.connectionClosed.requiresReconnection)
        XCTAssertTrue(IMAPError.serverError("BYE server closed").requiresReconnection)
        XCTAssertFalse(IMAPError.serverError("oops").requiresReconnection)
        XCTAssertFalse(IMAPError.timeout.requiresReconnection)
    }
}
