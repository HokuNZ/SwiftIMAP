import Foundation

extension IMAPClient {
    // MARK: - Advanced Search

    /// Search for messages using advanced criteria and return full message summaries
    public func searchMessages(
        in mailbox: String,
        criteria: IMAPCommand.SearchCriteria,
        fetchItems: [IMAPCommand.FetchItem] = [.uid, .flags, .internalDate, .rfc822Size, .envelope],
        limit: Int? = nil,
        charset: String? = nil
    ) async throws -> [MessageSummary] {
        // First, get the sequence numbers matching the criteria
        let sequenceNumbers = try await listMessages(in: mailbox, searchCriteria: criteria, charset: charset)

        guard !sequenceNumbers.isEmpty else {
            return []
        }

        // Apply limit if specified
        let numbersToFetch = if let limit = limit {
            Array(sequenceNumbers.suffix(limit))
        } else {
            sequenceNumbers
        }

        // Fetch details for each message
        var summaries: [MessageSummary] = []
        for seqNum in numbersToFetch {
            if let summary = try await fetchMessageBySequence(sequenceNumber: seqNum, in: mailbox, items: fetchItems) {
                summaries.append(summary)
            }
        }

        return summaries
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

    /// Search with complex criteria combining multiple conditions
    public func searchMessagesComplex(
        in mailbox: String,
        from sender: String? = nil,
        to recipient: String? = nil,
        subject: String? = nil,
        text: String? = nil,
        since: Date? = nil,
        before: Date? = nil,
        flags: Set<Flag>? = nil,
        excludeFlags: Set<Flag>? = nil,
        limit: Int? = nil
    ) async throws -> [MessageSummary] {
        var criteria: [IMAPCommand.SearchCriteria] = []

        if let sender = sender {
            criteria.append(.from(sender))
        }
        if let recipient = recipient {
            criteria.append(.to(recipient))
        }
        if let subject = subject {
            criteria.append(.subject(subject))
        }
        if let text = text {
            criteria.append(.text(text))
        }
        if let since = since {
            criteria.append(.since(since))
        }
        if let before = before {
            criteria.append(.before(before))
        }

        // Add flag criteria
        if let flags = flags {
            for flag in flags {
                switch flag {
                case .seen: criteria.append(.seen)
                case .answered: criteria.append(.answered)
                case .flagged: criteria.append(.flagged)
                case .deleted: criteria.append(.deleted)
                case .draft: criteria.append(.draft)
                case .recent: criteria.append(.recent)
                }
            }
        }

        // Add excluded flag criteria
        if let excludeFlags = excludeFlags {
            for flag in excludeFlags {
                switch flag {
                case .seen: criteria.append(.unseen)
                case .answered: criteria.append(.unanswered)
                case .flagged: criteria.append(.unflagged)
                case .deleted: criteria.append(.undeleted)
                case .draft: criteria.append(.undraft)
                case .recent: criteria.append(.not(.recent))
                }
            }
        }

        // If no criteria specified, search all
        if criteria.isEmpty {
            criteria.append(.all)
        }

        return try await searchMessages(in: mailbox, matching: criteria, limit: limit)
    }
}
