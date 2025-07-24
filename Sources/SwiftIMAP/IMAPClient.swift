import Foundation
import Crypto

public final class IMAPClient: Sendable {
    private let configuration: IMAPConfiguration
    private let tlsConfiguration: TLSConfiguration
    private let connection: ConnectionActor
    private let retryHandler: RetryHandler
    private let logger: Logger
    
    public init(configuration: IMAPConfiguration, tlsConfiguration: TLSConfiguration = TLSConfiguration()) {
        self.configuration = configuration
        self.tlsConfiguration = tlsConfiguration
        self.logger = Logger(label: "IMAPClient", level: configuration.logLevel)
        self.connection = ConnectionActor(configuration: configuration, tlsConfiguration: tlsConfiguration)
        self.retryHandler = RetryHandler(configuration: configuration.retryConfiguration, logger: logger)
    }
    
    public func connect() async throws {
        try await retryHandler.execute(operation: "connect") {
            try await self.connection.connect()
            
            let capabilities = try await self.capability()
            
            if self.configuration.tlsMode == .startTLS {
                if capabilities.contains("STARTTLS") {
                    try await self.startTLS()
                } else {
                    throw IMAPError.unsupportedCapability("STARTTLS")
                }
            }
            
            try await self.authenticate()
        }
    }
    
    public func disconnect() async {
        _ = try? await logout()
        await connection.disconnect()
    }
    
    public func capability() async throws -> Set<String> {
        let responses = try await connection.sendCommand(.capability)
        
        for response in responses {
            if case .untagged(.capability(let caps)) = response {
                return Set(caps)
            }
        }
        
        return await connection.getCapabilities()
    }
    
    public func listMailboxes(reference: String = "", pattern: String = "*") async throws -> [Mailbox] {
        let responses = try await connection.sendCommand(.list(reference: reference, pattern: pattern))
        
        var mailboxes: [Mailbox] = []
        
        for response in responses {
            if case .untagged(.list(let listResponse)) = response {
                let attributes = Set(listResponse.attributes.compactMap { attr in
                    Mailbox.Attribute(rawValue: attr)
                })
                
                let mailbox = Mailbox(
                    name: listResponse.name,
                    attributes: attributes,
                    delimiter: listResponse.delimiter
                )
                mailboxes.append(mailbox)
            }
        }
        
        return mailboxes
    }
    
    public func selectMailbox(_ mailbox: String) async throws -> MailboxStatus {
        let responses = try await connection.sendCommand(.select(mailbox: mailbox))
        
        var exists: UInt32 = 0
        var recent: UInt32 = 0
        var uidNext: UInt32 = 0
        var uidValidity: UInt32 = 0
        var unseen: UInt32 = 0
        
        for response in responses {
            switch response {
            case .untagged(let untagged):
                switch untagged {
                case .exists(let count):
                    exists = count
                case .recent(let count):
                    recent = count
                case .flags(_):
                    break
                default:
                    break
                }
                
            case .tagged(_, let status):
                switch status {
                case .ok(let code, _):
                    if let code = code {
                        switch code {
                        case .uidNext(let uid):
                            uidNext = uid
                        case .uidValidity(let uid):
                            uidValidity = uid
                        case .unseen(let num):
                            unseen = num
                        case .permanentFlags(_):
                            break
                        default:
                            break
                        }
                    }
                default:
                    break
                }
                
            default:
                break
            }
        }
        
        await connection.setSelected(mailbox: mailbox)
        
        return MailboxStatus(
            messages: exists,
            recent: recent,
            uidNext: uidNext,
            uidValidity: uidValidity,
            unseen: unseen
        )
    }
    
    public func mailboxStatus(_ mailbox: String, items: [IMAPCommand.StatusItem] = [.messages, .recent, .uidNext, .uidValidity, .unseen]) async throws -> MailboxStatus {
        let responses = try await connection.sendCommand(.status(mailbox: mailbox, items: items))
        
        for response in responses {
            if case .untagged(.statusResponse(_, let status)) = response {
                return status
            }
        }
        
        throw IMAPError.protocolError("No STATUS response received")
    }
    
    public func listMessages(
        in mailbox: String,
        searchCriteria: IMAPCommand.SearchCriteria = .all
    ) async throws -> [MessageSequenceNumber] {
        try await retryHandler.executeWithReconnect(
            operation: "listMessages",
            needsReconnect: { error in
                (error as? IMAPError)?.requiresReconnection ?? false
            },
            reconnect: {
                try await self.connect()
            },
            work: {
                _ = try await self.selectMailbox(mailbox)
                
                let responses = try await self.connection.sendCommand(.search(charset: nil, criteria: searchCriteria))
                
                for response in responses {
                    if case .untagged(.search(let numbers)) = response {
                        return numbers
                    }
                }
                
                return []
            }
        )
    }
    
    public func fetchMessage(
        uid: UID,
        in mailbox: String,
        items: [IMAPCommand.FetchItem] = [.uid, .flags, .internalDate, .rfc822Size, .envelope, .bodyStructure]
    ) async throws -> MessageSummary? {
        try await retryHandler.executeWithReconnect(
            operation: "fetchMessage",
            needsReconnect: { error in
                (error as? IMAPError)?.requiresReconnection ?? false
            },
            reconnect: {
                try await self.connect()
            },
            work: {
                _ = try await self.selectMailbox(mailbox)
                
                let responses = try await self.connection.sendCommand(
                    .uid(.fetch(sequence: .single(uid), items: items))
                )
                
                for response in responses {
                    if case .untagged(.fetch(let seqNum, let attributes)) = response {
                        return try self.parseMessageSummary(sequenceNumber: seqNum, attributes: attributes)
                    }
                }
                
                return nil
            }
        )
    }
    
    public func fetchMessageBody(
        uid: UID,
        in mailbox: String,
        peek: Bool = true
    ) async throws -> Data? {
        _ = try await selectMailbox(mailbox)
        
        let responses = try await connection.sendCommand(
            .uid(.fetch(
                sequence: .single(uid),
                items: [.bodySection(section: nil, peek: peek)]
            ))
        )
        
        for response in responses {
            if case .untagged(.fetch(_, let attributes)) = response {
                for attribute in attributes {
                    switch attribute {
                    case .body(_, _, let data), .bodyPeek(_, _, let data):
                        return data
                    default:
                        continue
                    }
                }
            }
        }
        
        return nil
    }
    
    // Fetch message by sequence number (not UID)
    public func fetchMessageBySequence(
        sequenceNumber: MessageSequenceNumber,
        in mailbox: String,
        items: [IMAPCommand.FetchItem] = [.uid, .flags, .internalDate, .rfc822Size, .envelope]
    ) async throws -> MessageSummary? {
        _ = try await selectMailbox(mailbox)
        
        let responses = try await connection.sendCommand(
            .fetch(sequence: .single(sequenceNumber), items: items)
        )
        
        for response in responses {
            if case .untagged(.fetch(let seqNum, let attributes)) = response {
                return try parseMessageSummary(sequenceNumber: seqNum, attributes: attributes)
            }
        }
        
        return nil
    }
    
    // MARK: - Message Manipulation
    
    /// Store flags for a message (e.g., mark as read, flagged, etc.)
    public func storeFlags(
        uid: UID,
        in mailbox: String,
        flags: [Flag],
        action: IMAPCommand.StoreFlags.Action = .set,
        silent: Bool = false
    ) async throws {
        _ = try await selectMailbox(mailbox)
        
        let storeFlags = IMAPCommand.StoreFlags(action: action, flags: flags)
        
        _ = try await connection.sendCommand(
            .uid(.store(sequence: .single(uid), flags: storeFlags, silent: silent))
        )
    }
    
    /// Store flags for multiple messages
    public func storeFlags(
        uids: [UID],
        in mailbox: String,
        flags: [Flag],
        action: IMAPCommand.StoreFlags.Action = .set,
        silent: Bool = false
    ) async throws {
        guard !uids.isEmpty else { return }
        
        _ = try await selectMailbox(mailbox)
        
        let storeFlags = IMAPCommand.StoreFlags(action: action, flags: flags)
        let sequence = IMAPCommand.SequenceSet.set(uids)
        
        _ = try await connection.sendCommand(
            .uid(.store(sequence: sequence, flags: storeFlags, silent: silent))
        )
    }
    
    /// Mark a message as read
    public func markAsRead(uid: UID, in mailbox: String) async throws {
        try await storeFlags(uid: uid, in: mailbox, flags: [.seen], action: .add)
    }
    
    /// Mark a message as unread
    public func markAsUnread(uid: UID, in mailbox: String) async throws {
        try await storeFlags(uid: uid, in: mailbox, flags: [.seen], action: .remove)
    }
    
    /// Mark a message for deletion
    public func markForDeletion(uid: UID, in mailbox: String) async throws {
        try await storeFlags(uid: uid, in: mailbox, flags: [.deleted], action: .add)
    }
    
    /// Copy a message to another mailbox
    public func copyMessage(uid: UID, from sourceMailbox: String, to destinationMailbox: String) async throws {
        _ = try await selectMailbox(sourceMailbox)
        
        _ = try await connection.sendCommand(
            .uid(.copy(sequence: .single(uid), mailbox: destinationMailbox))
        )
    }
    
    /// Copy multiple messages to another mailbox
    public func copyMessages(uids: [UID], from sourceMailbox: String, to destinationMailbox: String) async throws {
        guard !uids.isEmpty else { return }
        
        _ = try await selectMailbox(sourceMailbox)
        
        let sequence = IMAPCommand.SequenceSet.set(uids)
        
        _ = try await connection.sendCommand(
            .uid(.copy(sequence: sequence, mailbox: destinationMailbox))
        )
    }
    
    /// Move a message to another mailbox (if server supports MOVE extension)
    /// Falls back to COPY + mark as deleted if MOVE is not supported
    public func moveMessage(uid: UID, from sourceMailbox: String, to destinationMailbox: String) async throws {
        // Check if server supports MOVE extension
        let capabilities = try await capability()
        if capabilities.contains("MOVE") {
            _ = try await selectMailbox(sourceMailbox)
            
            _ = try await connection.sendCommand(
                .uid(.move(sequence: .single(uid), mailbox: destinationMailbox))
            )
        } else {
            // Fallback: COPY + mark as deleted
            try await copyMessage(uid: uid, from: sourceMailbox, to: destinationMailbox)
            try await markForDeletion(uid: uid, in: sourceMailbox)
        }
    }
    
    /// Move multiple messages to another mailbox
    public func moveMessages(uids: [UID], from sourceMailbox: String, to destinationMailbox: String) async throws {
        guard !uids.isEmpty else { return }
        
        // Check if server supports MOVE extension
        let capabilities = try await capability()
        if capabilities.contains("MOVE") {
            _ = try await selectMailbox(sourceMailbox)
            
            let sequence = IMAPCommand.SequenceSet.set(uids)
            _ = try await connection.sendCommand(
                .uid(.move(sequence: sequence, mailbox: destinationMailbox))
            )
        } else {
            // Fallback: COPY + mark as deleted
            try await copyMessages(uids: uids, from: sourceMailbox, to: destinationMailbox)
            for uid in uids {
                try await markForDeletion(uid: uid, in: sourceMailbox)
            }
        }
    }
    
    /// Permanently delete messages marked with \Deleted flag
    public func expunge(mailbox: String) async throws {
        _ = try await selectMailbox(mailbox)
        
        _ = try await connection.sendCommand(.expunge)
    }
    
    /// Delete a message (mark as deleted and expunge)
    public func deleteMessage(uid: UID, in mailbox: String) async throws {
        try await markForDeletion(uid: uid, in: mailbox)
        try await expunge(mailbox: mailbox)
    }
    
    /// Delete multiple messages
    public func deleteMessages(uids: [UID], in mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        
        for uid in uids {
            try await markForDeletion(uid: uid, in: mailbox)
        }
        try await expunge(mailbox: mailbox)
    }
    
    private func authenticate() async throws {
        switch configuration.authMethod {
        case .plain(let username, let password):
            try await authenticatePlain(username: username, password: password)
        case .login(let username, let password):
            try await authenticateLogin(username: username, password: password)
        case .oauth2(let username, let accessToken):
            try await authenticateOAuth2(username: username, accessToken: accessToken)
        case .external:
            try await authenticateExternal()
        }
    }
    
    private func authenticateLogin(username: String, password: String) async throws {
        _ = try await connection.sendCommand(.login(username: username, password: password))
        await connection.setAuthenticated()
    }
    
    private func authenticatePlain(username: String, password: String) async throws {
        let authString = "\0\(username)\0\(password)"
        guard let authData = authString.data(using: .utf8) else {
            throw IMAPError.authenticationFailed("Failed to encode credentials")
        }
        
        let base64Auth = authData.base64EncodedString()
        
        _ = try await connection.sendCommand(
            .authenticate(mechanism: "PLAIN", initialResponse: base64Auth)
        )
        await connection.setAuthenticated()
    }
    
    private func authenticateOAuth2(username: String, accessToken: String) async throws {
        let authString = "user=\(username)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        guard let authData = authString.data(using: .utf8) else {
            throw IMAPError.authenticationFailed("Failed to encode OAuth2 credentials")
        }
        
        let base64Auth = authData.base64EncodedString()
        
        _ = try await connection.sendCommand(
            .authenticate(mechanism: "XOAUTH2", initialResponse: base64Auth)
        )
        await connection.setAuthenticated()
    }
    
    private func authenticateExternal() async throws {
        _ = try await connection.sendCommand(
            .authenticate(mechanism: "EXTERNAL", initialResponse: nil)
        )
        await connection.setAuthenticated()
    }
    
    private func startTLS() async throws {
        _ = try await connection.sendCommand(.starttls)
    }
    
    private func logout() async throws {
        _ = try await connection.sendCommand(.logout)
    }
    
    private func parseMessageSummary(
        sequenceNumber: MessageSequenceNumber,
        attributes: [IMAPResponse.FetchAttribute]
    ) throws -> MessageSummary {
        var uid: UID?
        var flags = Set<Flag>()
        var internalDate: Date?
        var size: UInt32?
        var envelope: Envelope?
        
        for attribute in attributes {
            switch attribute {
            case .uid(let u):
                uid = u
            case .flags(let f):
                flags = Set(f.compactMap { Flag(rawValue: $0) })
            case .internalDate(let date):
                internalDate = date
            case .rfc822Size(let s):
                size = s
            case .envelope(let env):
                envelope = parseEnvelope(env)
            default:
                break
            }
        }
        
        guard let uid = uid,
              let internalDate = internalDate,
              let size = size else {
            throw IMAPError.parsingError("Missing required message attributes")
        }
        
        return MessageSummary(
            uid: uid,
            sequenceNumber: sequenceNumber,
            flags: flags,
            internalDate: internalDate,
            size: size,
            envelope: envelope
        )
    }
    
    private func parseEnvelope(_ data: IMAPResponse.EnvelopeData) -> Envelope {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        
        let date = data.date.flatMap { dateFormatter.date(from: $0) }
        
        return Envelope(
            date: date,
            subject: data.subject,
            from: parseAddresses(data.from),
            sender: parseAddresses(data.sender),
            replyTo: parseAddresses(data.replyTo),
            to: parseAddresses(data.to),
            cc: parseAddresses(data.cc),
            bcc: parseAddresses(data.bcc),
            inReplyTo: data.inReplyTo,
            messageID: data.messageID
        )
    }
    
    private func parseAddresses(_ addresses: [IMAPResponse.AddressData]?) -> [Address] {
        guard let addresses = addresses else { return [] }
        
        return addresses.compactMap { addr in
            guard let mailbox = addr.mailbox,
                  let host = addr.host else {
                return nil
            }
            
            return Address(
                name: addr.name,
                mailbox: mailbox,
                host: host
            )
        }
    }
}