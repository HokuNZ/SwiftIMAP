import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix

/// Inbound IMAP response handler. Buffers parsed responses (and parse/IO
/// errors) when no `responseHandler` is registered, so the greeting is not
/// lost in the race between `bootstrap.connect()` resolving and the consumer
/// installing a handler via `setResponseHandler`. See #21.
final class IMAPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let parser = IMAPParser()
    private let lock = NIOLock()
    private var _responseHandler: ((Result<[IMAPResponse], Error>) -> Void)?
    private var _oneShot = false
    private var _pendingResults: [Result<[IMAPResponse], Error>] = []
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        let data = Data(bytes)

        logger.log(level: .trace, "Received \(data.count) bytes")

        parser.append(data)

        do {
            let responses = try parser.parseResponses()
            if !responses.isEmpty {
                logger.log(level: .debug, "Parsed \(responses.count) responses")
                dispatch(.success(responses))
            }
        } catch {
            logger.log(level: .error, "Parse error: \(error)")
            dispatch(.failure(error))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.log(level: .error, "Channel error: \(error)")
        dispatch(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.log(level: .info, "Channel became inactive")
        dispatch(.failure(IMAPError.disconnected))
    }

    // The handler is invoked while `lock` is held so that a buffer drain and a
    // concurrent live `dispatch` cannot deliver out of order or run the handler
    // on two threads at once. Handlers must therefore not synchronously re-enter
    // `setResponseHandler`/`dispatch` (NIOLock is non-reentrant); the connect
    // path's handlers only spawn a Task / resume a continuation, so they don't.
    //
    // A `oneShot` handler is delivered exactly one result batch and then cleared
    // (under the same lock, without re-entry) so the channel reverts to buffering.
    // The greeting handler uses this so any response arriving between the greeting
    // and the persistent handler being installed is buffered rather than dropped
    // by a stale greeting closure (#26).
    func setResponseHandler(_ handler: ((Result<[IMAPResponse], Error>) -> Void)?, oneShot: Bool = false) {
        lock.withLock {
            _responseHandler = handler
            _oneShot = oneShot
            guard _responseHandler != nil else { return }
            // Drain buffered results. A one-shot handler consumes only the first
            // batch and then clears itself, leaving the remainder buffered for the
            // next handler.
            while !_pendingResults.isEmpty, let handler = _responseHandler {
                handler(_pendingResults.removeFirst())
                if _oneShot {
                    _responseHandler = nil
                    _oneShot = false
                    break
                }
            }
        }
    }

    private func dispatch(_ result: Result<[IMAPResponse], Error>) {
        lock.withLock {
            if let handler = _responseHandler {
                handler(result)
                if _oneShot {
                    _responseHandler = nil
                    _oneShot = false
                }
            } else {
                _pendingResults.append(result)
            }
        }
    }
}

final class IMAPMessageEncoder: MessageToByteEncoder, @unchecked Sendable {
    typealias OutboundIn = Data
    
    func encode(data: Data, out: inout ByteBuffer) throws {
        out.writeBytes(data)
    }
}