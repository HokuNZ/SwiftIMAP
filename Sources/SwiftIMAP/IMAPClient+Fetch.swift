import Foundation

extension IMAPClient {
    /// Returns message UIDs matching the search criteria.
    ///
    /// This method uses `UID SEARCH` which returns stable UIDs that persist even when
    /// messages are deleted or moved. Use this for any multi-step operation where you
    /// need to reference messages after the initial search.
    ///
    /// - Parameters:
    ///   - mailbox: The mailbox to search in
    ///   - searchCriteria: The search criteria (defaults to `.all`)
    ///   - charset: Optional charset for the search (e.g., "UTF-8")
    /// - Returns: An array of UIDs matching the criteria
    public func listMessageUIDs(
        in mailbox: String,
        searchCriteria: IMAPCommand.SearchCriteria = .all,
        charset: String? = nil
    ) async throws -> [UID] {
        try await retryHandler.executeWithReconnect(
            operation: "listMessageUIDs",
            needsReconnect: { error in
                (error as? IMAPError)?.requiresReconnection ?? false
            },
            reconnect: {
                try await self.connect()
            },
            work: {
                _ = try await self.selectMailbox(mailbox)

                // Use UID SEARCH to get stable UIDs instead of sequence numbers
                let responses = try await self.connection.sendCommand(
                    .uid(.search(charset: charset, criteria: searchCriteria))
                )

                for response in responses {
                    if case .untagged(.search(let numbers)) = response {
                        return numbers
                    }
                }

                return []
            }
        )
    }

    /// Returns message sequence numbers matching the search criteria.
    ///
    /// - Warning: Sequence numbers are position-dependent and can change when messages
    ///   are deleted or moved. For multi-step operations, use ``listMessageUIDs(in:searchCriteria:charset:)``
    ///   instead to avoid race conditions.
    @available(*, deprecated, message: "Use listMessageUIDs() instead - sequence numbers are unstable when mailbox changes")
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
