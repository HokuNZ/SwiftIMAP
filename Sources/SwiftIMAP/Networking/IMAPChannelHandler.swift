import Foundation
import NIOCore
import NIOPosix

final class IMAPChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    private let parser = IMAPParser()
    private var responseHandler: ((Result<[IMAPResponse], Error>) -> Void)?
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
                responseHandler?(.success(responses))
            }
        } catch {
            logger.log(level: .error, "Parse error: \(error)")
            responseHandler?(.failure(error))
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.log(level: .error, "Channel error: \(error)")
        responseHandler?(.failure(error))
        context.close(promise: nil)
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        logger.log(level: .info, "Channel became inactive")
        responseHandler?(.failure(IMAPError.disconnected))
    }
    
    func setResponseHandler(_ handler: ((Result<[IMAPResponse], Error>) -> Void)?) {
        self.responseHandler = handler
    }
}

final class IMAPMessageEncoder: MessageToByteEncoder {
    typealias OutboundIn = Data
    
    func encode(data: Data, out: inout ByteBuffer) throws {
        out.writeBytes(data)
    }
}