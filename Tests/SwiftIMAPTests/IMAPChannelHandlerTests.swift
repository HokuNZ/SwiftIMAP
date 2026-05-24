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
}
