import XCTest
@testable import SwiftIMAP

/// Thread-safe counter for use in async test closures
private actor Counter {
    private var value: Int = 0

    func increment() -> Int {
        value += 1
        return value
    }

    func get() -> Int {
        value
    }
}

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
        let attempts = Counter()

        let result: String = try await handler.execute(operation: "success") {
            _ = await attempts.increment()
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        let attemptCount = await attempts.get()
        XCTAssertEqual(attemptCount, 1)
    }

    func testExecuteRetriesOnTimeout() async throws {
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.timeout])
        let attempts = Counter()

        let result: String = try await handler.execute(operation: "timeout") {
            let count = await attempts.increment()
            if count == 1 {
                throw IMAPError.timeout
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        let attemptCount = await attempts.get()
        XCTAssertEqual(attemptCount, 2)
    }

    func testExecuteRetriesOnTemporaryServerError() async throws {
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.temporaryFailure])
        let attempts = Counter()

        let result: String = try await handler.execute(operation: "server-temp") {
            let count = await attempts.increment()
            if count == 1 {
                throw IMAPError.serverError("Temporary unavailable")
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        let attemptCount = await attempts.get()
        XCTAssertEqual(attemptCount, 2)
    }

    func testExecuteRetriesOnNetworkError() async throws {
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.networkError])
        let attempts = Counter()

        let result: String = try await handler.execute(operation: "network") {
            let count = await attempts.increment()
            if count == 1 {
                throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "network unreachable"])
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        let attemptCount = await attempts.get()
        XCTAssertEqual(attemptCount, 2)
    }

    func testExecuteThrowsNonRetryableError() async {
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.timeout])
        let attempts = Counter()

        do {
            _ = try await handler.execute(operation: "invalid") {
                _ = await attempts.increment()
                throw IMAPError.invalidState("not retryable")
            }
            XCTFail("Expected non-retryable error")
        } catch {
            let attemptCount = await attempts.get()
            XCTAssertEqual(attemptCount, 1)
        }
    }

    func testExecuteWithReconnectRecoversAfterReconnect() async throws {
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.connectionLost])
        let attempts = Counter()
        let reconnects = Counter()

        let result: String = try await handler.executeWithReconnect(
            operation: "reconnect",
            needsReconnect: { error in
                if case IMAPError.connectionClosed = error { return true }
                return false
            },
            reconnect: {
                _ = await reconnects.increment()
            },
            work: {
                let count = await attempts.increment()
                if count == 1 {
                    throw IMAPError.connectionClosed
                }
                return "ok"
            }
        )

        XCTAssertEqual(result, "ok")
        let attemptCount = await attempts.get()
        let reconnectCount = await reconnects.get()
        XCTAssertEqual(attemptCount, 2)
        XCTAssertEqual(reconnectCount, 1)
    }

    func testExecuteWithReconnectRetriesOnTimeout() async throws {
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.timeout])
        let attempts = Counter()

        let result: String = try await handler.executeWithReconnect(
            operation: "timeout-retry",
            needsReconnect: { _ in false },
            reconnect: {},
            work: {
                let count = await attempts.increment()
                if count == 1 {
                    throw IMAPError.timeout
                }
                return "ok"
            }
        )

        XCTAssertEqual(result, "ok")
        let attemptCount = await attempts.get()
        XCTAssertEqual(attemptCount, 2)
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
