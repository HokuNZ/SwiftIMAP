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
                throw IMAPError.timeout(command: nil)
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        let attemptCount = await attempts.get()
        XCTAssertEqual(attemptCount, 2)
    }

    func testExecuteRetriesOnConnectionFailed() async throws {
        // connect() failures surface as connectionFailed; these must be retryable
        // (previously they fell through to non-retryable, making retries a no-op).
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.connectionLost])
        let attempts = Counter()

        let result: String = try await handler.execute(operation: "connect") {
            let count = await attempts.increment()
            if count == 1 {
                throw IMAPError.connectionFailed("refused", underlying: nil)
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        let attemptCount = await attempts.get()
        XCTAssertEqual(attemptCount, 2)
    }

    func testExecuteRetriesOnTransientCommandFailure() async throws {
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.temporaryFailure])
        let attempts = Counter()
        let transient = IMAPServerResponse(
            status: .no,
            code: .other("UNAVAILABLE", nil),
            text: "Server busy, try again",
            commandName: "UID MOVE"
        )

        let result: String = try await handler.execute(operation: "transient") {
            let count = await attempts.increment()
            if count == 1 {
                throw IMAPError.commandFailed(transient)
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        let attemptCount = await attempts.get()
        XCTAssertEqual(attemptCount, 2)
    }

    func testExecuteDoesNotRetryPermanentCommandFailure() async {
        // A NO [NONEXISTENT] is permanent; a BAD is a client bug. Neither retries.
        let handler = makeHandler(maxAttempts: 3, retryableErrors: [.temporaryFailure])
        let attempts = Counter()
        let permanent = IMAPServerResponse(
            status: .no,
            code: .other("NONEXISTENT", nil),
            text: "Mailbox does not exist",
            commandName: "UID MOVE"
        )

        do {
            _ = try await handler.execute(operation: "permanent") {
                _ = await attempts.increment()
                throw IMAPError.commandFailed(permanent)
            }
            XCTFail("Expected permanent failure to propagate")
        } catch {
            let attemptCount = await attempts.get()
            XCTAssertEqual(attemptCount, 1, "Permanent command failure must not be retried")
        }
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
                    throw IMAPError.connectionClosed(nil)
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
                    throw IMAPError.timeout(command: nil)
                }
                return "ok"
            }
        )

        XCTAssertEqual(result, "ok")
        let attemptCount = await attempts.get()
        XCTAssertEqual(attemptCount, 2)
    }

    func testExecuteWithReconnectThrowsReconnectErrorOnReconnectFailure() async {
        // When reconnection itself fails, the reconnect error must surface, not the
        // original work() error that triggered the reconnect.
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.connectionLost])
        let attempts = Counter()

        do {
            _ = try await handler.executeWithReconnect(
                operation: "reconnect-fail",
                needsReconnect: { _ in true },
                reconnect: { throw IMAPError.invalidState("reconnect boom") },
                work: {
                    _ = await attempts.increment()
                    throw IMAPError.connectionClosed(nil)
                }
            )
            XCTFail("Expected the reconnect failure to propagate")
        } catch {
            guard case IMAPError.invalidState(let message) = error else {
                return XCTFail("Expected the reconnect error (invalidState), got: \(error)")
            }
            XCTAssertEqual(message, "reconnect boom")
            let count = await attempts.get()
            XCTAssertEqual(count, 1)
        }
    }

    func testErrorDescriptionsCoverAllCases() {
        let cases: [(IMAPError, String)] = [
            (.connectionFailed("oops", underlying: nil), "Connection failed: oops"),
            (.connectionClosed(nil), "Connection closed unexpectedly"),
            (.connectionClosed(IMAPServerResponse(status: .bye, code: .alert, text: "Too many connections", commandName: "CONNECT")),
             "Connection closed by server: BYE [ALERT] Too many connections"),
            (.authenticationFailed("bad", response: nil), "Authentication failed: bad"),
            (.authenticationFailed(
                "Server rejected LOGIN",
                response: IMAPServerResponse(status: .no, code: .other("AUTHENTICATIONFAILED", nil), text: "Invalid credentials", commandName: "LOGIN")
             ),
             "Authentication failed: Server rejected LOGIN: NO [AUTHENTICATIONFAILED] Invalid credentials"),
            (.tlsError("nope", underlying: nil), "TLS error: nope"),
            (.protocolError("bad"), "Protocol error: bad"),
            (.parsingError("bad"), "Parsing error: bad"),
            (.commandFailed(IMAPServerResponse(status: .no, code: .tryCreate, text: "Mailbox does not exist", commandName: "UID MOVE")),
             "Command 'UID MOVE' failed: NO [TRYCREATE] Mailbox does not exist"),
            (.timeout(command: nil), "Operation timed out"),
            (.timeout(command: "UID MOVE"), "Operation 'UID MOVE' timed out"),
            (.invalidState("state"), "Invalid state: state"),
            (.unsupportedCapability("ID"), "Unsupported capability: ID"),
            (.invalidArgument("bad"), "Invalid argument: bad")
        ]

        for (error, expected) in cases {
            XCTAssertEqual(error.errorDescription, expected)
        }
    }

    func testDoesNotRetryNonTransientCodeDespiteTransientText() async {
        // A definitive code ([NONEXISTENT]) is authoritative: the command must not be
        // retried just because the free text happens to contain "try again".
        let handler = makeHandler(maxAttempts: 3, retryableErrors: [.temporaryFailure])
        let attempts = Counter()
        let response = IMAPServerResponse(
            status: .no,
            code: .other("NONEXISTENT", nil),
            text: "Mailbox busy, try again later",
            commandName: "UID MOVE"
        )

        do {
            _ = try await handler.execute(operation: "code-wins") {
                _ = await attempts.increment()
                throw IMAPError.commandFailed(response)
            }
            XCTFail("Expected the permanent failure to propagate")
        } catch {
            let count = await attempts.get()
            XCTAssertEqual(count, 1, "A non-transient code must not be retried on a text match")
        }
    }

    func testRetriesOnTransientTextWhenNoCode() async {
        // With no code present, the free text is the only signal, so a transient
        // phrase should still trigger a retry.
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.temporaryFailure])
        let attempts = Counter()
        let response = IMAPServerResponse(
            status: .no,
            code: nil,
            text: "Please try again",
            commandName: "UID MOVE"
        )

        do {
            _ = try await handler.execute(operation: "text-fallback") {
                _ = await attempts.increment()
                throw IMAPError.commandFailed(response)
            }
            XCTFail("Expected failure after retries are exhausted")
        } catch {
            let count = await attempts.get()
            XCTAssertEqual(count, 2, "Transient text with no code should be retried")
        }
    }

    func testDoesNotRetryDefinitiveByeGreeting() async {
        // A `* BYE` greeting with a definitive code is the server actively rejecting
        // the connection; retrying with backoff is pointless and must not happen.
        let handler = makeHandler(maxAttempts: 3, retryableErrors: [.connectionLost])
        let attempts = Counter()
        let bye = IMAPServerResponse(status: .bye, code: .alert, text: "Server going away", commandName: "CONNECT")

        do {
            _ = try await handler.execute(operation: "bye-greeting") {
                _ = await attempts.increment()
                throw IMAPError.connectionClosed(bye)
            }
            XCTFail("Expected the BYE greeting to propagate")
        } catch {
            let count = await attempts.get()
            XCTAssertEqual(count, 1, "A definitive BYE greeting must not be retried")
        }
    }

    func testRetriesBareConnectionClose() async {
        // A bare connection loss (no server response) is transient: retry it.
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.connectionLost])
        let attempts = Counter()

        do {
            _ = try await handler.execute(operation: "bare-close") {
                _ = await attempts.increment()
                throw IMAPError.connectionClosed(nil)
            }
            XCTFail("Expected failure after retries are exhausted")
        } catch {
            let count = await attempts.get()
            XCTAssertEqual(count, 2, "A bare connection close should be retried")
        }
    }

    func testRetriesByeNamingTransientCondition() async {
        // A BYE that names a transient condition ([UNAVAILABLE]) should still retry.
        let handler = makeHandler(maxAttempts: 2, retryableErrors: [.connectionLost])
        let attempts = Counter()
        let bye = IMAPServerResponse(status: .bye, code: .other("UNAVAILABLE", nil), text: "Restarting", commandName: "CONNECT")

        do {
            _ = try await handler.execute(operation: "bye-transient") {
                _ = await attempts.increment()
                throw IMAPError.connectionClosed(bye)
            }
            XCTFail("Expected failure after retries are exhausted")
        } catch {
            let count = await attempts.get()
            XCTAssertEqual(count, 2, "A BYE naming a transient condition should be retried")
        }
    }

    func testRequiresReconnectionFlagsConnectionErrors() {
        // connectionClosed(nil) is what an abrupt TCP drop produces (see
        // IMAPChannelHandler.channelInactive); it must be reconnectable or a
        // dropped connection mid-session fails permanently (#35 / A4).
        XCTAssertTrue(IMAPError.connectionClosed(nil).requiresReconnection)
        XCTAssertTrue(IMAPError.connectionFailed("refused", underlying: nil).requiresReconnection)
        XCTAssertFalse(IMAPError.timeout(command: nil).requiresReconnection)
        XCTAssertFalse(IMAPError.commandFailed(
            IMAPServerResponse(status: .no, code: nil, text: "nope", commandName: "STORE")
        ).requiresReconnection)
    }
}
