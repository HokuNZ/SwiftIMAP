import Foundation
import NIOCore
import NIOPosix
import NIOSSL

// Thread-safe mutable state wrapper
private final class MutableState<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    
    init(value: T) {
        self._value = value
    }
    
    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    
    func compareAndExchange(expected: T, new: T) -> Bool where T: Equatable {
        lock.lock()
        defer { lock.unlock() }
        if _value == expected {
            _value = new
            return true
        }
        return false
    }
}

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
    private var pendingContinuationTag: String?
    private var connectionState: ConnectionState = .disconnected
    private var serverCapabilities: Set<String> = []
    
    private struct PendingCommand {
        let command: IMAPCommand
        let continuation: CheckedContinuation<[IMAPResponse], Error>
        var responses: [IMAPResponse] = []
        var continuationSequence: [Data]
        var continuationHandler: (@Sendable (String?) async throws -> String?)?
        let timeoutTask: Task<Void, Never>
    }
    
    private enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case authenticated
        case selected(mailbox: String, readOnly: Bool)
    }
    
    init(configuration: IMAPConfiguration, tlsConfiguration: TLSConfiguration) {
        self.configuration = configuration
        self.tlsConfiguration = tlsConfiguration
        self.logger = Logger(label: "ConnectionActor", level: configuration.logLevel)
    }
    
    func connect() async throws -> IMAPResponse {
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
            
            if case .untagged(.status(.preauth(_, _))) = greeting {
                connectionState = .authenticated
            }
            
            // Now set the regular response handler after greeting is received
            channelHandler.setResponseHandler { [weak self] result in
                Task { [weak self] in
                    await self?.handleResponses(result)
                }
            }
            
            return greeting
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
    
    func startTLS() async throws {
        guard let channel = channel else {
            throw IMAPError.disconnected
        }
        
        do {
            let sslHandler = try makeTLSHandler(hostname: configuration.hostname)
            try await channel.pipeline.addHandler(sslHandler, position: .first).get()
        } catch {
            throw IMAPError.tlsError(error.localizedDescription)
        }
    }
    
    func sendCommand(
        _ command: IMAPCommand.Command,
        continuationResponse: String? = nil,
        continuationHandler: (@Sendable (String?) async throws -> String?)? = nil
    ) async throws -> [IMAPResponse] {
        guard connectionState != .disconnected && connectionState != .connecting else {
            throw IMAPError.invalidState("Not connected")
        }
        guard pendingContinuationTag == nil else {
            throw IMAPError.invalidState("Command continuation pending")
        }

        let sessionState = mapSessionState()
        try IMAPCommandStateValidator.validate(command: command, state: sessionState)
        
        let tag = nextTag()
        let imapCommand = IMAPCommand(tag: tag, command: command)
        
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await self.sendCommandInternal(
                    imapCommand,
                    continuationResponse: continuationResponse,
                    continuationHandler: continuationHandler,
                    continuation: continuation
                )
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
        case .selected(let mailbox, let readOnly):
            return "selected(\(mailbox), readOnly: \(readOnly))"
        }
    }
    
    func setAuthenticated() {
        switch connectionState {
        case .connected, .selected:
            connectionState = .authenticated
        case .authenticated, .disconnected, .connecting:
            break
        }
    }
    
    func setSelected(mailbox: String, readOnly: Bool) {
        connectionState = .selected(mailbox: mailbox, readOnly: readOnly)
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

    private func mapSessionState() -> IMAPSessionState {
        switch connectionState {
        case .connected:
            return .notAuthenticated
        case .authenticated:
            return .authenticated
        case .selected(_, let readOnly):
            return .selected(readOnly: readOnly)
        case .disconnected, .connecting:
            return .notAuthenticated
        }
    }
    
    private func sendCommandInternal(
        _ command: IMAPCommand,
        continuationResponse: String?,
        continuationHandler: (@Sendable (String?) async throws -> String?)?,
        continuation: CheckedContinuation<[IMAPResponse], Error>
    ) async {
        do {
            let literalMode: IMAPEncoder.LiteralMode = serverCapabilities.contains("LITERAL+")
                ? .nonSynchronizing
                : .synchronizing
            let encoded = try encoder.encodeCommandSegments(command, literalMode: literalMode)
            
            guard let channel = channel else {
                continuation.resume(throwing: IMAPError.disconnected)
                return
            }

            let crlf = Data([0x0D, 0x0A])
            var continuationSequence = encoded.continuationSegments

            if let continuationResponse = continuationResponse {
                guard continuationSequence.isEmpty else {
                    continuation.resume(throwing: IMAPError.invalidState("Literal continuation already configured"))
                    return
                }
                guard continuationHandler == nil else {
                    continuation.resume(throwing: IMAPError.invalidState("Multiple continuation handlers configured"))
                    return
                }
                var data = Data(continuationResponse.utf8)
                data.append(crlf)
                continuationSequence = [data]
            }

            if continuationHandler != nil {
                guard continuationSequence.isEmpty else {
                    continuation.resume(throwing: IMAPError.invalidState("Literal continuation already configured"))
                    return
                }
            }

            if !continuationSequence.isEmpty || continuationHandler != nil {
                guard pendingContinuationTag == nil else {
                    continuation.resume(throwing: IMAPError.invalidState("Another command is awaiting continuation"))
                    return
                }
                pendingContinuationTag = command.tag
            }
            
            let timeoutNanoseconds = UInt64(configuration.commandTimeout * 1_000_000_000)
            let timeoutTask = Task { [commandTag = command.tag] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await self.handleTimeout(for: commandTag)
            }

            let pending = PendingCommand(
                command: command,
                continuation: continuation,
                continuationSequence: continuationSequence,
                continuationHandler: continuationHandler,
                timeoutTask: timeoutTask
            )
            pendingCommands[command.tag] = pending

            logger.log(level: .debug, "Sending command \(command.tag): \(command.command)")

            do {
                try await channel.writeAndFlush(encoded.initialData)
            } catch {
                guard pendingCommands[command.tag] != nil else {
                    return
                }
                pending.timeoutTask.cancel()
                pendingCommands[command.tag] = nil
                if pendingContinuationTag == command.tag {
                    pendingContinuationTag = nil
                }
                continuation.resume(throwing: error)
                return
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
                pending.timeoutTask.cancel()
                pending.continuation.resume(throwing: error)
            }
            pendingCommands.removeAll()
            pendingContinuationTag = nil
        }
    }
    
    private func handleResponse(_ response: IMAPResponse) async {
        logger.log(level: .trace, "Handling response: \(response)")
        
        switch response {
        case .tagged(let tag, let status):
            if var pending = pendingCommands[tag] {
                pendingCommands[tag] = nil
                pending.timeoutTask.cancel()
                if pendingContinuationTag == tag {
                    pendingContinuationTag = nil
                }
                updateCapabilitiesIfPresent(status)
                
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
            case .status(let status):
                updateCapabilitiesIfPresent(status)
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
            
        case .continuation(let text):
            await handleContinuationResponse(text)
        }
    }
    
    private func waitForGreeting() async throws -> IMAPResponse {
        return try await withCheckedThrowingContinuation { continuation in
            let resumedState = MutableState(value: false)
            let greetingState = MutableState(value: false)
            
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                if resumedState.compareAndExchange(expected: false, new: true) {
                    continuation.resume(throwing: IMAPError.timeout)
                }
            }
            
            channelHandler?.setResponseHandler { [weak self] result in
                guard !resumedState.value else { return }
                
                switch result {
                case .success(let responses):
                    // Only handle the first set of responses as greeting
                    if greetingState.compareAndExchange(expected: false, new: true) {
                        if resumedState.compareAndExchange(expected: false, new: true) {
                            timeoutTask.cancel()
                            
                            if let greeting = responses.first {
                                // Process any CAPABILITY responses that came with the greeting
                                Task { [weak self] in
                                    for response in responses {
                                        if case .untagged(.capability(let caps)) = response {
                                            await self?.updateCapabilities(Set(caps))
                                        } else if case .untagged(.status(let status)) = response {
                                            await self?.updateCapabilitiesIfPresent(status)
                                        }
                                    }
                                }
                                continuation.resume(returning: greeting)
                            } else {
                                continuation.resume(throwing: IMAPError.protocolError("No greeting received"))
                            }
                        }
                    }
                case .failure(let error):
                    if resumedState.compareAndExchange(expected: false, new: true) {
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
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: IMAPError.disconnected)
        }
        pendingCommands.removeAll()
        pendingContinuationTag = nil
    }
}

private extension ConnectionActor {
    func makeTLSHandler(hostname: String) throws -> NIOSSLClientHandler {
        var tlsConfig = NIOSSL.TLSConfiguration.makeClientConfiguration()
        tlsConfig.trustRoots = tlsConfiguration.trustRoots
        tlsConfig.certificateVerification = tlsConfiguration.certificateVerification
        tlsConfig.minimumTLSVersion = tlsConfiguration.minimumTLSVersion
        
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        return try NIOSSLClientHandler(
            context: sslContext,
            serverHostname: tlsConfiguration.hostnameOverride ?? hostname
        )
    }
    
    func handleContinuationResponse(_ responseText: String) async {
        guard let tag = pendingContinuationTag,
              var pending = pendingCommands[tag] else {
            return
        }

        let challenge = responseText.isEmpty ? nil : responseText

        if !pending.continuationSequence.isEmpty {
            let data = pending.continuationSequence.removeFirst()
            pendingCommands[tag] = pending

            do {
                try await channel?.writeAndFlush(data)
            } catch {
                guard pendingCommands[tag] != nil else {
                    return
                }
                pending.timeoutTask.cancel()
                pendingCommands[tag] = nil
                if pendingContinuationTag == tag {
                    pendingContinuationTag = nil
                }
                pending.continuation.resume(throwing: error)
            }

            if pending.continuationSequence.isEmpty && pending.continuationHandler == nil {
                pendingContinuationTag = nil
            }
            return
        }

        if let handler = pending.continuationHandler {
            do {
                guard let response = try await handler(challenge) else {
                    guard pendingCommands[tag] != nil else {
                        return
                    }
                    await cancelContinuation(
                        tag: tag,
                        pending: pending,
                        error: IMAPError.authenticationFailed("SASL response handler returned nil")
                    )
                    return
                }
                guard pendingCommands[tag] != nil else {
                    return
                }
                var data = Data(response.utf8)
                data.append(contentsOf: [0x0D, 0x0A])
                try await channel?.writeAndFlush(data)
            } catch {
                guard pendingCommands[tag] != nil else {
                    return
                }
                await cancelContinuation(tag: tag, pending: pending, error: error)
            }
            return
        }

        await cancelContinuation(
            tag: tag,
            pending: pending,
            error: IMAPError.invalidState("Missing continuation handler")
        )
    }

    private func cancelContinuation(tag: String, pending: PendingCommand, error: Error) async {
        pendingContinuationTag = nil
        pending.timeoutTask.cancel()
        pendingCommands[tag] = nil

        let cancelData = Data("*\r\n".utf8)
        _ = try? await channel?.writeAndFlush(cancelData)
        pending.continuation.resume(throwing: error)
    }
    
    func handleTimeout(for tag: String) async {
        if let pending = pendingCommands[tag] {
            pendingCommands[tag] = nil
            if pendingContinuationTag == tag {
                pendingContinuationTag = nil
            }
            pending.continuation.resume(throwing: IMAPError.timeout)
        }
    }

    func updateCapabilitiesIfPresent(_ status: IMAPResponse.ResponseStatus) {
        let code: IMAPResponse.ResponseCode?
        switch status {
        case .ok(let statusCode, _),
             .no(let statusCode, _),
             .bad(let statusCode, _),
             .preauth(let statusCode, _),
             .bye(let statusCode, _):
            code = statusCode
        }
        
        if case .capability(let caps) = code {
            serverCapabilities = Set(caps)
        }
    }
}

private struct ByteBufferDecoder: ByteToMessageDecoder, @unchecked Sendable {
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
