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
    // The code/text of an unsolicited mid-session `* BYE`, captured so that when the
    // connection then drops, pending commands fail with the server's stated reason
    // rather than a generic `disconnected`. Only surfaced at teardown, so it never
    // interferes with a `* BYE` that legitimately precedes a LOGOUT completion.
    private var pendingBye: (code: IMAPResponse.ResponseCode?, text: String?)?

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
    
    func isHealthy() -> Bool {
        switch connectionState {
        case .authenticated, .selected:
            return channel?.isActive == true
        case .connected, .connecting, .disconnected:
            return false
        }
    }

    func connect() async throws -> IMAPResponse {
        if connectionState != .disconnected, connectionState != .connecting,
           channel?.isActive != true {
            // Reset here so reconnecting does not require a manual disconnect() first
            connectionState = .disconnected
            await cleanup()
        }

        guard case .disconnected = connectionState else {
            throw IMAPError.invalidState("Already connected or connecting")
        }

        connectionState = .connecting
        
        do {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.eventLoopGroup = group
            
            let channelHandler = IMAPChannelHandler(logger: logger)
            self.channelHandler = channelHandler
            
            // No response handler installed yet — waitForGreeting will install one below.
            // IMAPChannelHandler buffers any bytes that arrive in the meantime, so the
            // greeting cannot be dropped if the server beats us to setResponseHandler
            
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
            logger.log(level: .debug, "Received greeting: \(greeting.loggingDescription)")
            
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
        } catch let error as IMAPError {
            // Preserve typed IMAP errors (e.g. timeout(command:), connectionClosed)
            connectionState = .disconnected
            await cleanup()
            throw error
        } catch {
            connectionState = .disconnected
            await cleanup()
            throw IMAPError.connectionFailed(error.localizedDescription, underlying: error)
        }
    }
    
    func disconnect() async {
        guard connectionState != .disconnected else { return }
        
        if let channel = channel {
            do {
                try await channel.close()
            } catch {
                // Teardown continues regardless (we still reset state and clean
                // up below), but a channel that fails to close — most likely on
                // the wedged/dead-channel path that bounded disconnect() targets
                // — should be diagnosable rather than silently swallowed.
                logger.debug("Channel close during disconnect failed (continuing teardown): \(error.localizedDescription)")
            }
        }

        connectionState = .disconnected
        await cleanup()
    }
    
    func startTLS() async throws {
        guard let channel = channel else {
            throw IMAPError.connectionClosed(nil)
        }
        
        do {
            let sslHandler = try makeTLSHandler(hostname: configuration.hostname)
            try await channel.pipeline.addHandler(sslHandler, position: .first).get()
        } catch {
            throw IMAPError.tlsError(error.localizedDescription, underlying: error)
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
        serverCapabilities = ConnectionActor.normalised(caps)
    }

    /// IMAP capability tokens are case-insensitive (RFC 3501 §7.2.1)
    /// Normalise to upper case at the cache boundary
    private static func normalised(_ caps: some Sequence<String>) -> Set<String> {
        Set(caps.map { $0.uppercased() })
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

    /// Convert a timeout in seconds to nanoseconds, clamped to a non-negative, finite value.
    private static func nanoseconds(fromSeconds seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let nanos = seconds * 1_000_000_000
        return nanos >= Double(UInt64.max) ? UInt64.max : UInt64(nanos)
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
                continuation.resume(throwing: IMAPError.connectionClosed(nil))
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
            
            let timeoutNanoseconds = ConnectionActor.nanoseconds(fromSeconds: configuration.commandTimeout)
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

            logger.log(level: .debug, "Sending command \(command.tag): \(command.command.label)")

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
                if let bye = pendingBye {
                    // The connection dropped after the server sent a `* BYE`
                    let response = IMAPServerResponse(
                        status: .bye,
                        code: bye.code,
                        text: bye.text,
                        commandName: pending.command.command.label
                    )
                    pending.continuation.resume(throwing: IMAPError.connectionClosed(response))
                } else {
                    pending.continuation.resume(throwing: error)
                }
            }
            pendingCommands.removeAll()
            pendingContinuationTag = nil
            pendingBye = nil

            // If the channel is actually gone (abrupt drop / errorCaught-then-close,
            // as opposed to a parse error on a live connection), reset the actor
            // state so a later connect() can re-establish. Without this the state
            // stays .authenticated/.selected and connect() throws invalidState,
            // making reconnect-after-drop impossible.
            if channel?.isActive != true {
                connectionState = .disconnected
                await cleanup()
            }
        }
    }

    private func handleResponse(_ response: IMAPResponse) async {
        logger.log(level: .trace, "Handling response: \(response.loggingDescription)")
        
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
                case .no(let code, let text), .bad(let code, let text):
                    let serverStatus: IMAPServerResponse.Status = {
                        if case .bad = status { return .bad }
                        return .no
                    }()
                    let response = IMAPServerResponse(
                        status: serverStatus,
                        code: code,
                        text: text,
                        commandName: pending.command.command.label
                    )
                    pending.continuation.resume(throwing: IMAPError.commandFailed(response))
                default:
                    pending.responses.append(response)
                    pending.continuation.resume(returning: pending.responses)
                }
            }
            
        case .untagged(let untagged):
            switch untagged {
            case .capability(let caps):
                serverCapabilities = ConnectionActor.normalised(caps)
            case .status(let status):
                updateCapabilitiesIfPresent(status)
                if case .bye(let code, let text) = status {
                    pendingBye = (code: code, text: text)
                }
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
            // `resumedState` guarantees the continuation is resumed exactly once
            // across the racing timeout task and the greeting handler.
            let resumedState = MutableState(value: false)

            let greetingTimeout = ConnectionActor.nanoseconds(fromSeconds: configuration.connectionTimeout)
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: greetingTimeout)
                if resumedState.compareAndExchange(expected: false, new: true) {
                    continuation.resume(throwing: IMAPError.timeout(command: "CONNECT"))
                }
            }
            
            // One-shot: the handler is delivered the first response batch (the greeting) and then cleared, 
            // so any response arriving before the persistent handler is installed in connect() is buffered, not dropped.
            channelHandler?.setResponseHandler({ [weak self] result in
                switch result {
                case .success(let responses):
                    // CAS, not a bare read: the timeout task may have already won.
                    guard resumedState.compareAndExchange(expected: false, new: true) else { return }
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
                case .failure(let error):
                    guard resumedState.compareAndExchange(expected: false, new: true) else { return }
                    timeoutTask.cancel()
                    continuation.resume(throwing: error)
                }
            }, oneShot: true)
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
            if let bye = pendingBye {
                // Teardown after a `* BYE` was seen (e.g. an explicit disconnect that races the channel going inactive): 
                // Surface the BYE reason rather than a bare transport error, matching the handleResponses path.
                let response = IMAPServerResponse(
                    status: .bye,
                    code: bye.code,
                    text: bye.text,
                    commandName: pending.command.command.label
                )
                pending.continuation.resume(throwing: IMAPError.connectionClosed(response))
            } else {
                pending.continuation.resume(throwing: IMAPError.connectionClosed(nil))
            }
        }
        pendingCommands.removeAll()
        pendingContinuationTag = nil
        pendingBye = nil
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
                        error: IMAPError.authenticationFailed("SASL response handler returned nil", response: nil)
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
            pending.continuation.resume(throwing: IMAPError.timeout(command: pending.command.command.label))
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
            serverCapabilities = ConnectionActor.normalised(caps)
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
