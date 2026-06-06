import Foundation
import NIO
import NIOConcurrencyHelpers
@testable import SwiftIMAP

// MARK: - Mock IMAP Server

/// Mock IMAP server used by the in-process integration tests. State touched by
/// both the test thread (set/asserted) and the NIO event loop (handler
/// callbacks) lives in the `_`-prefixed properties below, serialised via
/// `lock`. `channel` is only touched from the test task (start/shutdown). See
/// #21 for the failure mode this fixes.
class MockIMAPServer {
    private let lock = NIOLock()
    private let eventLoopGroup: EventLoopGroup
    private var channel: Channel?

    private var _responses: [String: String] = [:]
    private var _authenticateResponse: String?
    private var _authenticateChallenges: [String] = []
    private var _pendingAuthTag: String?
    private var _pendingAuthChallenges: [String] = []
    private var _receivedCommands: [String] = []
    private var _receivedContinuations: [String] = []
    private var _closeAfterKeywords: Set<String> = []

    var receivedCommands: [String] {
        lock.withLock { Array(_receivedCommands) }
    }

    var receivedContinuations: [String] {
        lock.withLock { Array(_receivedContinuations) }
    }

    var isAwaitingContinuation: Bool {
        lock.withLock { _pendingAuthTag != nil }
    }

    init(eventLoopGroup: EventLoopGroup) {
        self.eventLoopGroup = eventLoopGroup
        _responses["GREETING"] = "* OK Mock IMAP Server Ready"
    }

    func setResponse(for command: String, response: String) {
        lock.withLock { _responses[command] = response }
    }

    /// After responding to a command whose line contains `keyword`, close the
    /// connection — simulating an unsolicited server hang-up (e.g. after a `* BYE`).
    func closeAfterResponse(toCommandContaining keyword: String) {
        lock.withLock { _ = _closeAfterKeywords.insert(keyword.uppercased()) }
    }

    func shouldCloseAfter(_ command: String) -> Bool {
        lock.withLock {
            let upper = command.uppercased()
            return _closeAfterKeywords.contains { upper.contains($0) }
        }
    }

    func setAuthenticateResponse(_ response: String) {
        lock.withLock { _authenticateResponse = response }
    }

    func setAuthenticateChallenges(_ challenges: [String]) {
        lock.withLock { _authenticateChallenges = challenges }
    }

    func greeting() -> String {
        lock.withLock { _responses["GREETING"] ?? "* OK Ready" }
    }

    func start() async throws -> Int {
        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    ByteToMessageHandler(MockIMAPDecoder()),
                    MessageToByteHandler(MockIMAPEncoder()),
                    MockIMAPHandler(server: self)
                ])
            }

        channel = try await bootstrap.bind(host: "localhost", port: 0).get()
        guard let localAddress = channel?.localAddress,
              let port = localAddress.port else {
            throw IMAPError.connectionFailed("Failed to get server port", underlying: nil)
        }

        return port
    }

    func shutdown() async throws {
        try await channel?.close()
    }

    func handleCommand(_ command: String) -> String {
        lock.withLock { handleCommandLocked(command) }
    }

    private func handleCommandLocked(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        _receivedCommands.append(trimmed)

        if let pendingTag = _pendingAuthTag {
            _receivedContinuations.append(trimmed)
            if !_pendingAuthChallenges.isEmpty {
                let challenge = _pendingAuthChallenges.removeFirst()
                return challenge.isEmpty ? "+" : "+ \(challenge)"
            }
            _pendingAuthTag = nil
            return formatAuthenticateResponseLocked(tag: pendingTag)
        }

        guard !trimmed.isEmpty else {
            return "* BAD Empty command"
        }

        let parts = trimmed.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            return ""
        }

        let tagCandidate = String(parts[0])
        let isTagged = tagCandidate.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil
        guard isTagged else {
            return ""
        }

        let tag = tagCandidate
        let cmd = String(parts[1]).uppercased()
        let remainder = parts.count > 2 ? String(parts[2]) : ""
        let commandAndArgs = String(trimmed.dropFirst(tag.count + 1))
        let remainderParts = remainder.split(separator: " ", maxSplits: 1)
        let subcommandKey = remainderParts.first.map { "\(cmd) \(String($0))" }

        if cmd == "AUTHENTICATE" {
            let remainderParts = remainder.split(separator: " ", maxSplits: 1)
            let mechanism = remainderParts.first.map { String($0).uppercased() } ?? ""
            let hasInitialResponse = remainderParts.count > 1

            if !_authenticateChallenges.isEmpty {
                _pendingAuthTag = tag
                _pendingAuthChallenges = _authenticateChallenges
                let challenge = _pendingAuthChallenges.removeFirst()
                return challenge.isEmpty ? "+" : "+ \(challenge)"
            }

            if hasInitialResponse {
                return formatAuthenticateResponseLocked(tag: tag)
            }

            _pendingAuthTag = tag
            return _responses["AUTHENTICATE \(mechanism)"] ?? "+"
        }

        let prefixMatch = _responses.keys.first { key in
            commandAndArgs.uppercased().hasPrefix(key.uppercased())
        }.flatMap { _responses[$0] }

        if let response = _responses[commandAndArgs]
            ?? _responses[commandAndArgs.uppercased()]
            ?? prefixMatch
            ?? subcommandKey.flatMap({ _responses[$0] ?? _responses[$0.uppercased()] })
            ?? _responses[cmd] {
            if response.hasPrefix("*") || response.hasPrefix("+") {
                // For a close-after command, send the untagged line alone (no tagged
                // completion) so the client command stays pending until the hang-up.
                let upperLine = trimmed.uppercased()
                if _closeAfterKeywords.contains(where: { upperLine.contains($0) }) {
                    return response
                }
                return "\(response)\r\n\(tag) OK \(cmd) completed"
            }

            let upper = response.uppercased()
            if upper.hasPrefix("OK") || upper.hasPrefix("NO") || upper.hasPrefix("BAD") {
                return "\(tag) \(response)"
            }

            return "\(tag) OK \(response)"
        }

        return "\(tag) OK \(cmd) completed"
    }

    private func formatAuthenticateResponseLocked(tag: String) -> String {
        let response = _authenticateResponse ?? "OK AUTHENTICATE completed"

        if response.hasPrefix("*") {
            return "\(response)\r\n\(tag) OK AUTHENTICATE completed"
        }

        if response.uppercased().hasPrefix("\(tag) ") {
            return response
        }

        return "\(tag) \(response)"
    }
}

// MARK: - Mock IMAP Codec

class MockIMAPDecoder: ByteToMessageDecoder {
    typealias InboundOut = String
    
    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let view = buffer.readableBytesView
        guard let lfIndex = view.firstIndex(of: UInt8(ascii: "\n")) else {
            return .needMoreData
        }
        
        let length = view.distance(from: view.startIndex, to: lfIndex) + 1
        guard var lineBuffer = buffer.readSlice(length: length),
              let line = lineBuffer.readString(length: lineBuffer.readableBytes) else {
            return .needMoreData
        }
        
        context.fireChannelRead(wrapInboundOut(line))
        return .continue
    }
}

class MockIMAPEncoder: MessageToByteEncoder {
    typealias OutboundIn = String
    
    func encode(data: String, out: inout ByteBuffer) throws {
        let normalized = data.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        out.writeString(normalized)
        if !normalized.hasSuffix("\r\n") {
            out.writeString("\r\n")
        }
    }
}

class MockIMAPHandler: ChannelInboundHandler {
    typealias InboundIn = String
    typealias OutboundOut = String
    
    private weak var server: MockIMAPServer?
    private var hasGreeted = false
    
    init(server: MockIMAPServer) {
        self.server = server
    }
    
    func channelActive(context: ChannelHandlerContext) {
        let greeting = server?.greeting() ?? "* OK Ready"
        context.writeAndFlush(wrapOutboundOut(greeting), promise: nil)
        hasGreeted = true
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let rawCommand = unwrapInboundIn(data)
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.isEmpty && (server?.isAwaitingContinuation != true) {
            return
        }
        
        if let response = server?.handleCommand(rawCommand) {
            if response.isEmpty {
                return
            }
            context.writeAndFlush(wrapOutboundOut(response), promise: nil)
            // Flush is enqueued before the close on the same event loop, so the
            // response bytes are written before the connection is torn down.
            if server?.shouldCloseAfter(command) == true {
                context.close(promise: nil)
            }
        }
    }
}
