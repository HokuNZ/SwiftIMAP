import Foundation

extension IMAPClient {
    // MARK: - Message Manipulation

    /// Select `mailbox` and, when `expectedUIDValidity` is non-nil, verify the
    /// server's current `UIDVALIDITY` matches before the caller issues a write.
    ///
    /// Throws `IMAPError.uidValidityChanged` on mismatch — the caller's write
    /// command is never sent. The check is atomic with the `SELECT` whose
    /// response carries the validity, so there is no window (unlike a separate
    /// `STATUS` call) in which validity could change between the check and the
    /// write.
    ///
    /// If the `SELECT` response carries no `UIDVALIDITY` (the parser reports it
    /// as `0`, which RFC 3501 forbids as a real value), the validity cannot be
    /// verified and the write is refused with `IMAPError.uidValidityUnavailable`
    /// rather than silently comparing against the `0` sentinel — a verify the
    /// caller asked for must not pass when nothing was actually verified.
    @discardableResult
    private func selectMailbox(_ mailbox: String, verifyingUIDValidity expectedUIDValidity: UInt32?) async throws -> MailboxStatus {
        let status = try await selectMailbox(mailbox)
        if let expectedUIDValidity {
            guard status.uidValidity != 0 else {
                throw IMAPError.uidValidityUnavailable(expected: expectedUIDValidity)
            }
            if expectedUIDValidity != status.uidValidity {
                throw IMAPError.uidValidityChanged(expected: expectedUIDValidity, actual: status.uidValidity)
            }
        }
        return status
    }

    public func appendMessage(
        _ messageData: Data,
        to mailbox: String,
        flags: [Flag]? = nil,
        date: Date? = nil
    ) async throws {
        let flagStrings = flags?.map { $0.rawValue }
        _ = try await connection.sendCommand(
            .append(mailbox: mailbox, flags: flagStrings, date: date, data: messageData)
        )
    }

    public func appendMessage(
        _ message: String,
        to mailbox: String,
        flags: [Flag]? = nil,
        date: Date? = nil
    ) async throws {
        guard let data = message.data(using: .utf8) else {
            throw IMAPError.invalidArgument("Message must be UTF-8")
        }
        try await appendMessage(data, to: mailbox, flags: flags, date: date)
    }

    /// Store flags for a message (e.g., mark as read, flagged, etc.)
    ///
    /// - Parameter expectedUIDValidity: when non-nil, the store is refused with
    ///   `IMAPError.uidValidityChanged` if the mailbox's current `UIDVALIDITY`
    ///   differs, guarding against acting on UIDs from a stale mailbox view.
    public func storeFlags(
        uid: UID,
        in mailbox: String,
        flags: [Flag],
        action: IMAPCommand.StoreFlags.Action = .set,
        silent: Bool = false,
        expectedUIDValidity: UInt32? = nil
    ) async throws {
        _ = try await selectMailbox(mailbox, verifyingUIDValidity: expectedUIDValidity)

        let storeFlags = IMAPCommand.StoreFlags(action: action, flags: flags)

        _ = try await connection.sendCommand(
            .uid(.store(sequence: .single(uid), flags: storeFlags, silent: silent))
        )
    }

    /// Store raw flags (including custom keywords) for a message.
    public func storeFlags(
        uid: UID,
        in mailbox: String,
        flags: [String],
        action: IMAPCommand.StoreFlags.Action = .set,
        silent: Bool = false,
        expectedUIDValidity: UInt32? = nil
    ) async throws {
        _ = try await selectMailbox(mailbox, verifyingUIDValidity: expectedUIDValidity)

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
        silent: Bool = false,
        expectedUIDValidity: UInt32? = nil
    ) async throws {
        guard !uids.isEmpty else { return }

        _ = try await selectMailbox(mailbox, verifyingUIDValidity: expectedUIDValidity)

        let storeFlags = IMAPCommand.StoreFlags(action: action, flags: flags)
        let sequence = IMAPCommand.SequenceSet.set(uids)

        _ = try await connection.sendCommand(
            .uid(.store(sequence: sequence, flags: storeFlags, silent: silent))
        )
    }

    /// Store raw flags (including custom keywords) for multiple messages.
    public func storeFlags(
        uids: [UID],
        in mailbox: String,
        flags: [String],
        action: IMAPCommand.StoreFlags.Action = .set,
        silent: Bool = false,
        expectedUIDValidity: UInt32? = nil
    ) async throws {
        guard !uids.isEmpty else { return }

        _ = try await selectMailbox(mailbox, verifyingUIDValidity: expectedUIDValidity)

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
    ///
    /// - Parameter expectedUIDValidity: when non-nil, refuses with
    ///   `IMAPError.uidValidityChanged` if the source mailbox's `UIDVALIDITY`
    ///   differs (see `storeFlags`).
    public func copyMessage(uid: UID, from sourceMailbox: String, to destinationMailbox: String, expectedUIDValidity: UInt32? = nil) async throws {
        _ = try await selectMailbox(sourceMailbox, verifyingUIDValidity: expectedUIDValidity)

        _ = try await connection.sendCommand(
            .uid(.copy(sequence: .single(uid), mailbox: destinationMailbox))
        )
    }

    /// Copy multiple messages to another mailbox
    public func copyMessages(uids: [UID], from sourceMailbox: String, to destinationMailbox: String, expectedUIDValidity: UInt32? = nil) async throws {
        guard !uids.isEmpty else { return }

        _ = try await selectMailbox(sourceMailbox, verifyingUIDValidity: expectedUIDValidity)

        let sequence = IMAPCommand.SequenceSet.set(uids)

        _ = try await connection.sendCommand(
            .uid(.copy(sequence: sequence, mailbox: destinationMailbox))
        )
    }

    /// Move a message to another mailbox (if server supports MOVE extension)
    /// Falls back to COPY + mark as deleted if MOVE is not supported
    ///
    /// - Parameter expectedUIDValidity: when non-nil, refuses with
    ///   `IMAPError.uidValidityChanged` if the source mailbox's `UIDVALIDITY`
    ///   differs (see `storeFlags`).
    public func moveMessage(uid: UID, from sourceMailbox: String, to destinationMailbox: String, expectedUIDValidity: UInt32? = nil) async throws {
        let capabilities = await connection.getCapabilities()
        if capabilities.contains("MOVE") {
            _ = try await selectMailbox(sourceMailbox, verifyingUIDValidity: expectedUIDValidity)

            _ = try await connection.sendCommand(
                .uid(.move(sequence: .single(uid), mailbox: destinationMailbox))
            )
        } else {
            // Fallback: COPY + mark as deleted. Both steps carry the validity
            // check — guarding only the COPY would let the deletion STORE run on
            // stale UIDs if UIDVALIDITY changed between the two SELECTs.
            try await copyMessage(uid: uid, from: sourceMailbox, to: destinationMailbox, expectedUIDValidity: expectedUIDValidity)
            try await storeFlags(uid: uid, in: sourceMailbox, flags: [.deleted], action: .add, expectedUIDValidity: expectedUIDValidity)
        }
    }

    /// Move multiple messages to another mailbox
    public func moveMessages(uids: [UID], from sourceMailbox: String, to destinationMailbox: String, expectedUIDValidity: UInt32? = nil) async throws {
        guard !uids.isEmpty else { return }

        let capabilities = await connection.getCapabilities()
        if capabilities.contains("MOVE") {
            _ = try await selectMailbox(sourceMailbox, verifyingUIDValidity: expectedUIDValidity)

            let sequence = IMAPCommand.SequenceSet.set(uids)
            _ = try await connection.sendCommand(
                .uid(.move(sequence: sequence, mailbox: destinationMailbox))
            )
        } else {
            // Fallback: COPY + mark as deleted (one batched STORE). Both steps
            // carry the validity check — guarding only the COPY would let the
            // deletion STORE run on stale UIDs if UIDVALIDITY changed between the
            // two SELECTs.
            try await copyMessages(uids: uids, from: sourceMailbox, to: destinationMailbox, expectedUIDValidity: expectedUIDValidity)
            try await storeFlags(uids: uids, in: sourceMailbox, flags: [.deleted], action: .add, expectedUIDValidity: expectedUIDValidity)
        }
    }

    /// Permanently delete messages marked with \Deleted flag
    public func expunge(mailbox: String) async throws {
        _ = try await selectMailbox(mailbox)

        _ = try await connection.sendCommand(.expunge)
    }

    /// Permanently delete specific messages via `UID EXPUNGE`.
    ///
    /// Throws: `IMAPError.unsupportedCapability("UIDPLUS")` if the server does not support UIDPLUS. 
    /// Falling back to a whole-mailbox `EXPUNGE` would permanently delete every `\Deleted` message in the mailbox — not just the named UIDs. 
    /// Use ``expunge(mailbox:)`` if whole-mailbox expunge is actually what you want.
    public func expunge(uids: [UID], in mailbox: String, expectedUIDValidity: UInt32? = nil) async throws {
        guard !uids.isEmpty else { return }

        // Guard before SELECT: a doomed call should not change the selected
        // mailbox as a side effect.
        let capabilities = await connection.getCapabilities()
        guard capabilities.contains("UIDPLUS") else {
            throw IMAPError.unsupportedCapability("UIDPLUS")
        }

        _ = try await selectMailbox(mailbox, verifyingUIDValidity: expectedUIDValidity)

        let sequence = IMAPCommand.SequenceSet.set(uids)
        _ = try await connection.sendCommand(.uid(.expunge(sequence: sequence)))
    }

    /// Delete a message (mark as deleted, then `UID EXPUNGE` it).
    public func deleteMessage(uid: UID, in mailbox: String) async throws {
        try await deleteMessages(uids: [uid], in: mailbox)
    }

    /// Delete multiple messages (one batched STORE, then `UID EXPUNGE`).
    public func deleteMessages(uids: [UID], in mailbox: String) async throws {
        guard !uids.isEmpty else { return }

        // Refuse before storing \Deleted: throwing only at the expunge step
        // would leave the flags set with no safe targeted expunge to follow.
        let capabilities = await connection.getCapabilities()
        guard capabilities.contains("UIDPLUS") else {
            throw IMAPError.unsupportedCapability("UIDPLUS")
        }

        try await storeFlags(uids: uids, in: mailbox, flags: [.deleted], action: .add)
        try await expunge(uids: uids, in: mailbox)
    }
}
