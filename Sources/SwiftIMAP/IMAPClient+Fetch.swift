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
    /// - Throws: `IMAPError` if the connection fails, authentication is required,
    ///           or the mailbox cannot be selected.
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

    /// Fetches a message by its UID.
    ///
    /// - Note: UID is automatically included in fetch items if not present, to verify
    ///   the response matches the requested message.
    ///
    /// - Parameters:
    ///   - uid: The UID of the message to fetch
    ///   - mailbox: The mailbox containing the message
    ///   - items: The fetch items to request (defaults to common envelope data)
    /// - Returns: The message summary if found with matching UID, nil if not found
    ///   or if server returned responses with non-matching UIDs
    /// - Throws: `IMAPError` for connection failures, mailbox selection errors,
    ///   command failures, or if the response cannot be parsed.
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

                // Ensure UID is included in fetch items so we can verify the response.
                // Without the UID in the response, we cannot confirm we received the
                // correct message when concurrent fetches are in flight.
                let hasUID = items.contains { item in
                    if case .uid = item { return true }
                    return false
                }
                var fetchItems = items
                if !hasUID {
                    fetchItems.insert(.uid, at: 0)
                }

                let responses = try await self.connection.sendCommand(
                    .uid(.fetch(sequence: .single(uid), items: fetchItems))
                )

                for response in responses {
                    if case .untagged(.fetch(let seqNum, let attributes)) = response {
                        // Verify the UID in the response matches the requested UID.
                        // Concurrent fetch requests may receive interleaved responses,
                        // so we must filter to find the correct one.
                        let responseUID = attributes.compactMap { attribute -> UID? in
                            if case .uid(let fetchedUID) = attribute {
                                return fetchedUID
                            }
                            return nil
                        }.first

                        if let responseUID = responseUID {
                            if responseUID == uid {
                                return try self.parseMessageSummary(sequenceNumber: seqNum, attributes: attributes)
                            } else {
                                self.logger.debug("UID mismatch in fetchMessage: requested \(uid), received \(responseUID) - skipping response")
                            }
                        } else {
                            self.logger.warning("FETCH response missing UID attribute for request UID \(uid)")
                        }
                    }
                }

                return nil
            }
        )
    }

    /// Fetches the body of a message by its UID.
    ///
    /// - Parameters:
    ///   - uid: The UID of the message to fetch
    ///   - mailbox: The mailbox containing the message
    ///   - peek: If true, fetching won't mark the message as read (default: true)
    /// - Returns: The message body data if found, nil otherwise
    /// - Throws: `IMAPError` if the connection fails or the mailbox cannot be selected.
    public func fetchMessageBody(
        uid: UID,
        in mailbox: String,
        peek: Bool = true
    ) async throws -> Data? {
        _ = try await selectMailbox(mailbox)

        // Request UID along with body for verification
        let responses = try await connection.sendCommand(
            .uid(.fetch(
                sequence: .single(uid),
                items: [.uid, .bodySection(section: nil, peek: peek)]
            ))
        )

        for response in responses {
            if case .untagged(.fetch(_, let attributes)) = response {
                // Extract UID from response for verification
                var responseUID: UID?
                var bodyData: Data?

                for attribute in attributes {
                    switch attribute {
                    case .uid(let fetchedUID):
                        responseUID = fetchedUID
                    case .body(_, _, let data), .bodyPeek(_, _, let data):
                        bodyData = data
                    default:
                        continue
                    }
                }

                // Only return body if UID matches the requested UID
                // This prevents returning wrong data when multiple fetches are pending
                if let responseUID = responseUID {
                    if responseUID == uid, let data = bodyData {
                        return data
                    } else if responseUID != uid {
                        self.logger.debug("UID mismatch in fetchMessageBody: requested \(uid), received \(responseUID) - skipping response")
                    }
                } else {
                    self.logger.warning("FETCH response missing UID attribute for request UID \(uid)")
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
