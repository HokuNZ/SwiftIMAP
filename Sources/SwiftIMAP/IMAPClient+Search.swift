import Foundation

extension IMAPClient {
    // MARK: - Advanced Search

    /// Search for messages using advanced criteria and return full message summaries.
    ///
    /// This method uses UID-based search and fetch operations internally, which are stable
    /// even when the mailbox changes between operations. This prevents race conditions
    /// that could occur if messages are deleted or moved during the search.
    ///
    /// - Note: If a message is deleted between search and fetch, it will be skipped and
    ///   logged. The returned array may contain fewer items than the search found.
    ///
    /// - Parameters:
    ///   - mailbox: The mailbox to search in
    ///   - criteria: The search criteria
    ///   - fetchItems: Items to fetch for each message (defaults to common envelope data)
    ///   - limit: Optional limit on number of results (takes the most recent)
    ///   - charset: Optional charset for the search
    /// - Returns: Array of message summaries matching the criteria
    /// - Throws: `IMAPError` if the connection fails, authentication is required,
    ///           or the mailbox cannot be selected.
    public func searchMessages(
        in mailbox: String,
        criteria: IMAPCommand.SearchCriteria,
        fetchItems: [IMAPCommand.FetchItem] = [.uid, .flags, .internalDate, .rfc822Size, .envelope],
        limit: Int? = nil,
        charset: String? = nil
    ) async throws -> [MessageSummary] {
        // Use UID SEARCH to get stable UIDs (not sequence numbers which can shift)
        let uids = try await listMessageUIDs(in: mailbox, searchCriteria: criteria, charset: charset)

        guard !uids.isEmpty else {
            return []
        }

        // Apply limit if specified (UIDs are strictly ascending per RFC 3501, so suffix gives most recent)
        let uidsToFetch = if let limit = limit {
            Array(uids.suffix(limit))
        } else {
            uids
        }

        // A limit of 0 (or a non-positive limit) yields an empty set; return
        // early rather than building a SequenceSet from [] (which traps).
        guard !uidsToFetch.isEmpty else {
            return []
        }

        // Fetch all matching messages in a single UID FETCH rather than one round
        // trip per UID. Reconnect-and-retry is safe (a fetch is an idempotent
        // read), matching fetchMessage.
        return try await retryHandler.executeWithReconnect(
            operation: "searchMessages.fetch",
            needsReconnect: { error in
                (error as? IMAPError)?.requiresReconnection ?? false
            },
            reconnect: {
                try await self.connect()
            },
            work: {
                _ = try await self.selectMailbox(mailbox)

                // Ensure the summary's required attributes are fetched from a
                // reduced item set; UID also maps each response back to its
                // requested UID (responses may arrive in any order, and a UID may
                // be absent if the message was deleted between search and fetch).
                let items = IMAPClient.summaryFetchItems(fetchItems)

                let responses = try await self.connection.sendCommand(
                    .uid(.fetch(sequence: .set(uidsToFetch), items: items))
                )

                var byUID: [UID: MessageSummary] = [:]
                for response in responses {
                    guard case let .untagged(.fetch(seqNum, attributes)) = response else { continue }
                    let responseUID = attributes.compactMap { attribute -> UID? in
                        if case .uid(let fetchedUID) = attribute { return fetchedUID }
                        return nil
                    }.first
                    guard let responseUID else {
                        self.logger.warning("FETCH response missing UID attribute during searchMessages")
                        continue
                    }
                    byUID[responseUID] = try self.parseMessageSummary(sequenceNumber: seqNum, attributes: attributes)
                }

                // Preserve the requested order; drop UIDs the server did not return
                // (deleted between search and fetch — expected under concurrent access).
                return uidsToFetch.compactMap { uid in
                    if let summary = byUID[uid] { return summary }
                    self.logger.debug("UID \(uid) not found during fetch - message may have been deleted")
                    return nil
                }
            }
        )
    }

    /// Convenience method to search by multiple criteria using AND
    public func searchMessages(
        in mailbox: String,
        matching allCriteria: [IMAPCommand.SearchCriteria],
        fetchItems: [IMAPCommand.FetchItem] = [.uid, .flags, .internalDate, .rfc822Size, .envelope],
        limit: Int? = nil,
        charset: String? = nil
    ) async throws -> [MessageSummary] {
        let criteria: IMAPCommand.SearchCriteria = allCriteria.count == 1 ? allCriteria[0] : .and(allCriteria)
        return try await searchMessages(
            in: mailbox,
            criteria: criteria,
            fetchItems: fetchItems,
            limit: limit,
            charset: charset
        )
    }

    /// Search for messages from a specific sender
    public func searchMessagesFrom(
        _ sender: String,
        in mailbox: String,
        limit: Int? = nil
    ) async throws -> [MessageSummary] {
        try await searchMessages(in: mailbox, criteria: .from(sender), limit: limit)
    }

    /// Search for messages with a specific subject
    public func searchMessagesBySubject(
        _ subject: String,
        in mailbox: String,
        limit: Int? = nil
    ) async throws -> [MessageSummary] {
        try await searchMessages(in: mailbox, criteria: .subject(subject), limit: limit)
    }

    /// Search for messages containing text in body or headers
    public func searchMessagesByText(
        _ text: String,
        in mailbox: String,
        limit: Int? = nil
    ) async throws -> [MessageSummary] {
        try await searchMessages(in: mailbox, criteria: .text(text), limit: limit)
    }

    /// Search for messages received since a specific date
    public func searchMessagesSince(
        _ date: Date,
        in mailbox: String,
        limit: Int? = nil
    ) async throws -> [MessageSummary] {
        try await searchMessages(in: mailbox, criteria: .since(date), limit: limit)
    }

    /// Search for unread messages
    public func searchUnreadMessages(
        in mailbox: String,
        limit: Int? = nil
    ) async throws -> [MessageSummary] {
        try await searchMessages(in: mailbox, criteria: .unseen, limit: limit)
    }

    /// Search for flagged/starred messages
    public func searchFlaggedMessages(
        in mailbox: String,
        limit: Int? = nil
    ) async throws -> [MessageSummary] {
        try await searchMessages(in: mailbox, criteria: .flagged, limit: limit)
    }
}
