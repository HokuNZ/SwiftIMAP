import XCTest
import NIOCore
import NIOEmbedded
@testable import SwiftIMAP

final class IMAPChannelHandlerTests: XCTestCase {

    private func makeHandler() -> IMAPChannelHandler {
        IMAPChannelHandler(logger: Logger(label: "test", level: .error))
    }

    private func writeGreeting(into channel: EmbeddedChannel) throws {
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("* OK Mock IMAP Server Ready\r\n")
        try channel.writeInbound(buffer)
    }

    /// Greeting that arrives before any handler is installed must be replayed
    /// to the next handler set, not dropped. This is the #21 fix.
    func testResponsesArrivingBeforeHandlerAreBufferedAndReplayed() throws {
        let handler = makeHandler()
        let channel = EmbeddedChannel(handler: handler)
        defer { try? channel.finish() }

        try writeGreeting(into: channel)

        var received: [IMAPResponse] = []
        handler.setResponseHandler { result in
            if case .success(let responses) = result {
                received.append(contentsOf: responses)
            }
        }

        XCTAssertEqual(received.count, 1, "Buffered greeting should be replayed when handler attaches")
    }

    /// Responses arriving after the handler is installed are delivered live,
    /// not via the buffer (regression guard against double-delivery).
    func testResponsesArrivingAfterHandlerAreDeliveredLive() throws {
        let handler = makeHandler()
        let channel = EmbeddedChannel(handler: handler)
        defer { try? channel.finish() }

        var received: [IMAPResponse] = []
        handler.setResponseHandler { result in
            if case .success(let responses) = result {
                received.append(contentsOf: responses)
            }
        }

        try writeGreeting(into: channel)

        XCTAssertEqual(received.count, 1)
    }

    /// A handler set after buffered responses, then replaced, must not see
    /// the buffered responses a second time.
    func testBufferIsDrainedExactlyOnce() throws {
        let handler = makeHandler()
        let channel = EmbeddedChannel(handler: handler)
        defer { try? channel.finish() }

        try writeGreeting(into: channel)

        var firstHandlerCount = 0
        handler.setResponseHandler { result in
            if case .success = result { firstHandlerCount += 1 }
        }

        var secondHandlerCount = 0
        handler.setResponseHandler { result in
            if case .success = result { secondHandlerCount += 1 }
        }

        XCTAssertEqual(firstHandlerCount, 1, "First handler should receive the buffered greeting")
        XCTAssertEqual(secondHandlerCount, 0, "Second handler should not see the already-drained buffer")
    }

    private func writeLine(_ line: String, into channel: EmbeddedChannel) throws {
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString(line + "\r\n")
        try channel.writeInbound(buffer)
    }

    /// A one-shot handler receives the first live batch and is then cleared, so
    /// subsequent responses buffer for the next handler rather than hitting the
    /// stale one-shot closure (#26).
    func testOneShotHandlerConsumesFirstBatchThenBuffers() throws {
        let handler = makeHandler()
        let channel = EmbeddedChannel(handler: handler)
        defer { try? channel.finish() }

        var oneShotCount = 0
        handler.setResponseHandler({ result in
            if case .success = result { oneShotCount += 1 }
        }, oneShot: true)

        try writeLine("* OK greeting", into: channel)
        try writeLine("* BYE later", into: channel)

        XCTAssertEqual(oneShotCount, 1, "One-shot handler must see only the first batch")

        var nextCount = 0
        handler.setResponseHandler { result in
            if case .success = result { nextCount += 1 }
        }
        XCTAssertEqual(nextCount, 1, "Response after the one-shot fired must buffer for the next handler")
    }

    /// A one-shot handler is cleared after a `.failure` batch too (not just
    /// `.success`), so the next handler still drains a later buffered batch
    /// rather than the failure being delivered twice or the one-shot lingering.
    func testOneShotHandlerClearsAfterFailureBatch() throws {
        let handler = makeHandler()
        let channel = EmbeddedChannel(handler: handler)
        defer { try? channel.finish() }

        var oneShotResults: [Result<[IMAPResponse], Error>] = []
        handler.setResponseHandler({ result in oneShotResults.append(result) }, oneShot: true)

        // A malformed line makes the parser throw, which `channelRead` dispatches
        // as a `.failure` batch.
        try writeLine("A1 BOGUS", into: channel)
        XCTAssertEqual(oneShotResults.count, 1)
        if case .success = oneShotResults.first {
            XCTFail("Expected a .failure batch")
        }

        // One-shot must have cleared, so a subsequent valid batch buffers for the
        // next handler instead of hitting the spent one-shot closure.
        try writeLine("* OK ready", into: channel)
        var nextCount = 0
        handler.setResponseHandler { result in
            if case .success = result { nextCount += 1 }
        }
        XCTAssertEqual(nextCount, 1, "Batch after a one-shot failure must buffer for the next handler")
    }

    /// A one-shot handler installed after responses were buffered consumes only
    /// the first buffered batch; the rest stays buffered for the next handler.
    func testOneShotHandlerDrainsOnlyFirstBufferedBatch() throws {
        let handler = makeHandler()
        let channel = EmbeddedChannel(handler: handler)
        defer { try? channel.finish() }

        // Two batches buffered before any handler is installed.
        try writeLine("* OK greeting", into: channel)
        try writeLine("* BYE later", into: channel)

        var oneShotCount = 0
        handler.setResponseHandler({ result in
            if case .success = result { oneShotCount += 1 }
        }, oneShot: true)
        XCTAssertEqual(oneShotCount, 1, "One-shot must drain only the first buffered batch")

        var nextCount = 0
        handler.setResponseHandler { result in
            if case .success = result { nextCount += 1 }
        }
        XCTAssertEqual(nextCount, 1, "Remaining buffered batch must go to the next handler")
    }

    /// Setting the handler to nil clears it without losing future responses.
    func testClearingHandlerThenSettingNewOneBuffersInBetween() throws {
        let handler = makeHandler()
        let channel = EmbeddedChannel(handler: handler)
        defer { try? channel.finish() }

        var firstCount = 0
        handler.setResponseHandler { _ in firstCount += 1 }
        handler.setResponseHandler(nil)

        try writeGreeting(into: channel)
        XCTAssertEqual(firstCount, 0, "Cleared handler should not be invoked")

        var secondCount = 0
        handler.setResponseHandler { result in
            if case .success = result { secondCount += 1 }
        }

        XCTAssertEqual(secondCount, 1, "Response buffered while handler was nil should be delivered to new handler")
    }

    /// Transport errors surfaced via errorCaught (TLS failures, read errors) are
    /// terminal — the handler closes the channel — so they must arrive as a
    /// typed, reconnectable IMAPError, not the raw NIO error, or they bypass
    /// requiresReconnection (PR #41 review).
    func testErrorCaughtWrapsTransportErrorAsReconnectable() throws {
        struct TransportError: Error {}
        let handler = makeHandler()
        let channel = EmbeddedChannel(handler: handler)
        defer { try? channel.finish() }

        var failures: [Error] = []
        handler.setResponseHandler { result in
            if case .failure(let error) = result {
                failures.append(error)
            }
        }

        channel.pipeline.fireErrorCaught(TransportError())

        // errorCaught dispatches first; the close it triggers then fires
        // channelInactive, which dispatches connectionClosed(nil). The first
        // failure is the one pending commands receive.
        guard let imapError = failures.first as? IMAPError,
              case .connectionFailed(_, let underlying) = imapError else {
            return XCTFail("Expected connectionFailed wrapping the transport error, got: \(failures)")
        }
        XCTAssertTrue(underlying is TransportError, "The original error must be preserved as the underlying cause")
        XCTAssertTrue(imapError.requiresReconnection,
                      "A terminal transport error must be classified as reconnectable")
    }

    /// Regression for #35 / A4: an abrupt connection drop (channelInactive with no
    /// server response) must surface as `connectionClosed(nil)`, which the retry
    /// layer classifies as reconnectable. Previously it surfaced as `.disconnected`,
    /// which was neither retryable nor reconnectable, so a dropped connection
    /// mid-session failed permanently.
    func testAbruptDropSurfacesAsReconnectableConnectionClosed() throws {
        let handler = makeHandler()
        let channel = EmbeddedChannel(handler: handler)
        defer { try? channel.finish() }

        var failure: Error?
        handler.setResponseHandler { result in
            if case .failure(let error) = result {
                failure = error
            }
        }

        channel.pipeline.fireChannelInactive()

        guard let imapError = failure as? IMAPError,
              case .connectionClosed(nil) = imapError else {
            return XCTFail("Expected connectionClosed(nil), got: \(String(describing: failure))")
        }
        XCTAssertTrue(imapError.requiresReconnection,
                      "An abrupt drop must be classified as reconnectable")
    }
}
