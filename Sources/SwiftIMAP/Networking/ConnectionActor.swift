import Foundation
import NIOCore
import NIOPosix
import NIOSSL

private func setupChannelPipeline(
    channel: Channel,
    handler: IMAPChannelHandler,
    tlsMode: IMAPConfiguration.TLSMode,
    tlsConfiguration: TLSConfiguration,
    hostname: String
) -> EventLoopFuture<Void> {
    if tlsMode == .requireTLS {
        do {
            var tlsConfig = NIOSSL.TLSConfiguration.makeClientConfiguration()
            tlsConfig.trustRoots = tlsConfiguration.trustRoots
            tlsConfig.certificateVerification = tlsConfiguration.certificateVerification
            tlsConfig.minimumTLSVersion = tlsConfiguration.minimumTLSVersion
            
            let sslContext = try NIOSSLContext(configuration: tlsConfig)
            
            let sslHandler = try NIOSSLClientHandler(
                context: sslContext,
                serverHostname: tlsConfiguration.hostnameOverride ?? hostname
            )
            
            return channel.pipeline.addHandler(sslHandler).flatMap {
                channel.pipeline.addHandlers([
                    MessageToByteHandler(IMAPMessageEncoder()),
                    ByteToMessageHandler(ByteBufferDecoder()),
                    handler
                ])
            }
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    } else {
        return channel.pipeline.addHandlers([
            MessageToByteHandler(IMAPMessageEncoder()),
            ByteToMessageHandler(ByteBufferDecoder()),
            handler
        ])
    }
}

actor ConnectionActor {
    private let configuration: IMAPConfiguration
    private let tlsConfiguration: TLSConfiguration
    private let logger: Logger
    
    private var eventLoopGroup: EventLoopGroup?
    private var channel: Channel?
    private var channelHandler: IMAPChannelHandler?
    private var encoder = IMAPEncoder()
    
    private var commandTag = 0
    private var pendingCommands: [String: PendingCommand] = [:]
    private var connectionState: ConnectionState = .disconnected
    private var serverCapabilities: Set<String> = []
    
    private struct PendingCommand {
        let command: IMAPCommand
        let continuation: CheckedContinuation<[IMAPResponse], Error>
        var responses: [IMAPResponse] = []
    }
    
    private enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case authenticated
        case selected(mailbox: String)
    }
    
    init(configuration: IMAPConfiguration, tlsConfiguration: TLSConfiguration) {
        self.configuration = configuration
        self.tlsConfiguration = tlsConfiguration
        self.logger = Logger(label: "ConnectionActor", level: configuration.logLevel)
    }
    
    func connect() async throws {
        guard case .disconnected = connectionState else {
            throw IMAPError.invalidState("Already connected or connecting")
        }
        
        connectionState = .connecting
        
        do {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.eventLoopGroup = group
            
            let channelHandler = IMAPChannelHandler(logger: logger)
            self.channelHandler = channelHandler
            
            // Don't set the response handler here - let waitForGreeting handle the first response
            
            let tlsConfig = self.tlsConfiguration
            let imapConfig = self.configuration
            
            let bootstrap = ClientBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.connectTimeout, value: .seconds(Int64(configuration.connectionTimeout)))
                .channelInitializer { channel in
                    SwiftIMAP.setupChannelPipeline(
                        channel: channel,
                        handler: channelHandler,
                        tlsMode: imapConfig.tlsMode,
                        tlsConfiguration: tlsConfig,
                        hostname: imapConfig.hostname
                    )
                }
            
            logger.log(level: .info, "Connecting to \(configuration.hostname):\(configuration.port)")
            
            let channel = try await bootstrap.connect(
                host: configuration.hostname,
                port: configuration.port
            ).get()
            
            self.channel = channel
            connectionState = .connected
            
            let greeting = try await waitForGreeting()
            logger.log(level: .debug, "Received greeting: \(greeting)")
            
            // Now set the regular response handler after greeting is received
            channelHandler.setResponseHandler { [weak self] result in
                Task { [weak self] in
                    await self?.handleResponses(result)
                }
            }
            
        } catch {
            connectionState = .disconnected
            await cleanup()
            throw IMAPError.connectionFailed(error.localizedDescription)
        }
    }
    
    func disconnect() async {
        guard connectionState != .disconnected else { return }
        
        if let channel = channel {
            try? await channel.close()
        }
        
        connectionState = .disconnected
        await cleanup()
    }
    
    func sendCommand(_ command: IMAPCommand.Command) async throws -> [IMAPResponse] {
        guard connectionState != .disconnected && connectionState != .connecting else {
            throw IMAPError.invalidState("Not connected")
        }
        
        let tag = nextTag()
        let imapCommand = IMAPCommand(tag: tag, command: command)
        
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await self.sendCommandInternal(imapCommand, continuation: continuation)
            }
        }
    }
    
    func getCapabilities() -> Set<String> {
        return serverCapabilities
    }
    
    func getConnectionState() -> String {
        switch connectionState {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .authenticated:
            return "authenticated"
        case .selected(let mailbox):
            return "selected(\(mailbox))"
        }
    }
    
    func setAuthenticated() {
        if case .connected = connectionState {
            connectionState = .authenticated
        }
    }
    
    func setSelected(mailbox: String) {
        connectionState = .selected(mailbox: mailbox)
    }
    
    private func updateCapabilities(_ caps: Set<String>) async {
        serverCapabilities = caps
    }
    
    private func setupChannelPipeline(channel: Channel, handler: IMAPChannelHandler) -> EventLoopFuture<Void> {
        SwiftIMAP.setupChannelPipeline(
            channel: channel,
            handler: handler,
            tlsMode: configuration.tlsMode,
            tlsConfiguration: tlsConfiguration,
            hostname: configuration.hostname
        )
    }
    
    private func nextTag() -> String {
        commandTag += 1
        return String(format: "A%04d", commandTag)
    }
    
    private func sendCommandInternal(_ command: IMAPCommand, continuation: CheckedContinuation<[IMAPResponse], Error>) async {
        do {
            let data = try encoder.encode(command)
            
            guard let channel = channel else {
                continuation.resume(throwing: IMAPError.disconnected)
                return
            }
            
            pendingCommands[command.tag] = PendingCommand(command: command, continuation: continuation)
            
            logger.log(level: .debug, "Sending command \(command.tag): \(command.command)")
            
            try await channel.writeAndFlush(data)
            
            Task {
                try await Task.sleep(nanoseconds: UInt64(configuration.commandTimeout * 1_000_000_000))
                if pendingCommands[command.tag] != nil {
                    pendingCommands[command.tag] = nil
                    continuation.resume(throwing: IMAPError.timeout)
                }
            }
            
        } catch {
            continuation.resume(throwing: error)
        }
    }
    
    private func handleResponses(_ result: Result<[IMAPResponse], Error>) async {
        switch result {
        case .success(let responses):
            for response in responses {
                await handleResponse(response)
            }
        case .failure(let error):
            for (_, pending) in pendingCommands {
                pending.continuation.resume(throwing: error)
            }
            pendingCommands.removeAll()
        }
    }
    
    private func handleResponse(_ response: IMAPResponse) async {
        logger.log(level: .trace, "Handling response: \(response)")
        
        switch response {
        case .tagged(let tag, let status):
            if var pending = pendingCommands[tag] {
                pendingCommands[tag] = nil
                
                switch status {
                case .ok:
                    // Return all collected responses plus the tagged response
                    pending.responses.append(response)
                    pending.continuation.resume(returning: pending.responses)
                case .no(_, let message), .bad(_, let message):
                    let error = IMAPError.commandFailed(
                        command: String(describing: pending.command.command),
                        response: message ?? "Unknown error"
                    )
                    pending.continuation.resume(throwing: error)
                default:
                    pending.responses.append(response)
                    pending.continuation.resume(returning: pending.responses)
                }
            }
            
        case .untagged(let untagged):
            switch untagged {
            case .capability(let caps):
                serverCapabilities = Set(caps)
            default:
                break
            }
            
            // Collect untagged responses for relevant commands
            for (tag, var pending) in pendingCommands {
                switch pending.command.command {
                case .capability, .list, .lsub, .fetch, .search, .status, .select, .examine, .uid:
                    pending.responses.append(response)
                    pendingCommands[tag] = pending
                default:
                    continue
                }
            }
            
        case .continuation:
            break
        }
    }
    
    private func waitForGreeting() async throws -> IMAPResponse {
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                if !resumed {
                    resumed = true
                    continuation.resume(throwing: IMAPError.timeout)
                }
            }
            
            var greetingReceived = false
            
            channelHandler?.setResponseHandler { [weak self] result in
                guard !resumed else { return }
                
                switch result {
                case .success(let responses):
                    // Only handle the first set of responses as greeting
                    if !greetingReceived {
                        greetingReceived = true
                        resumed = true
                        timeoutTask.cancel()
                        
                        if let greeting = responses.first {
                            // Process any CAPABILITY responses that came with the greeting
                            Task { @MainActor [weak self] in
                                for response in responses {
                                    if case .untagged(.capability(let caps)) = response {
                                        await self?.updateCapabilities(Set(caps))
                                    }
                                }
                            }
                            continuation.resume(returning: greeting)
                        } else {
                            continuation.resume(throwing: IMAPError.protocolError("No greeting received"))
                        }
                    }
                case .failure(let error):
                    if !resumed {
                        resumed = true
                        timeoutTask.cancel()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
    
    private func cleanup() async {
        channel = nil
        channelHandler = nil
        
        if let group = eventLoopGroup {
            try? await group.shutdownGracefully()
            eventLoopGroup = nil
        }
        
        for (_, pending) in pendingCommands {
            pending.continuation.resume(throwing: IMAPError.disconnected)
        }
        pendingCommands.removeAll()
    }
}

private struct ByteBufferDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    
    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard buffer.readableBytes > 0 else {
            return .needMoreData
        }
        
        context.fireChannelRead(wrapInboundOut(buffer))
        buffer.clear()
        return .continue
    }
}