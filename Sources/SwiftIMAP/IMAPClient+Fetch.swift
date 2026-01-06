import Foundation

extension IMAPClient {
    public func listMessages(
        in mailbox: String,
        searchCriteria: IMAPCommand.SearchCriteria = .all,
        charset: String? = nil
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

                let responses = try await self.connection.sendCommand(.search(charset: charset, criteria: searchCriteria))

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
}
