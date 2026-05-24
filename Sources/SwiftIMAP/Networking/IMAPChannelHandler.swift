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

    func setResponseHandler(_ handler: ((Result<[IMAPResponse], Error>) -> Void)?) {
        let drained: [Result<[IMAPResponse], Error>] = lock.withLock {
            _responseHandler = handler
            guard handler != nil else { return [] }
            let pending = _pendingResults
            _pendingResults.removeAll()
            return pending
        }
        guard let handler else { return }
        for result in drained {
            handler(result)
        }
    }

    private func dispatch(_ result: Result<[IMAPResponse], Error>) {
        let handler: ((Result<[IMAPResponse], Error>) -> Void)? = lock.withLock {
            if let handler = _responseHandler {
                return handler
            }
            _pendingResults.append(result)
            return nil
        }
        handler?(result)
    }
}

final class IMAPMessageEncoder: MessageToByteEncoder, @unchecked Sendable {
    typealias OutboundIn = Data
    
    func encode(data: Data, out: inout ByteBuffer) throws {
        out.writeBytes(data)
    }
}