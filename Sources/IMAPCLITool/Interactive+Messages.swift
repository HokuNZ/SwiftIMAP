import Foundation
import SwiftIMAP

extension Interactive {
    func fetchMessage(client: IMAPClient, mailbox: String, uid: UID) async throws {
        print("Fetching message UID \(uid)...")

        guard let summary = try await client.fetchMessage(uid: uid, in: mailbox) else {
            print("Message not found")
            return
        }

        print("\nMessage UID \(uid):")
        print("  Sequence: #\(summary.sequenceNumber)")
        print("  Date: \(formatDate(summary.internalDate))")
        print("  Size: \(formatBytes(summary.size))")
        print("  Flags: \(summary.flags.isEmpty ? "(none)" : summary.flags.map { $0.rawValue }.joined(separator: " "))")

        if let envelope = summary.envelope {
            print("\nEnvelope:")
            if let subject = envelope.subject {
                print("  Subject: \(subject)")
            }
            if !envelope.from.isEmpty {
                print("  From: \(envelope.from.map { $0.displayName }.joined(separator: ", "))")
            }
            if !envelope.to.isEmpty {
                print("  To: \(envelope.to.map { $0.displayName }.joined(separator: ", "))")
            }
            if let date = envelope.date {
                print("  Date: \(formatDate(date))")
            }
        }

        print("\nFetch body? (y/n): ", terminator: "")
        if let response = readLine()?.lowercased(), response == "y" {
            if let bodyData = try await client.fetchMessageBody(uid: uid, in: mailbox) {
                print("\nBody (\(formatBytes(UInt32(bodyData.count)))):")
                print(String(repeating: "=", count: 80))

                let tempSummary = MessageSummary(
                    uid: uid,
                    sequenceNumber: summary.sequenceNumber,
                    flags: summary.flags,
                    internalDate: summary.internalDate,
                    size: summary.size,
                    envelope: summary.envelope
                )

                do {
                    if let mimeMessage = try tempSummary.parseMimeContent(from: bodyData) {
                        print("MIME Type: \(mimeMessage.contentType ?? "text/plain")")
                        if let charset = mimeMessage.charset {
                            print("Charset: \(charset)")
                        }
                        if let encoding = mimeMessage.transferEncoding {
                            print("Transfer Encoding: \(encoding)")
                        }
                        print("")

                        if let plainText = mimeMessage.plainTextContent {
                            print("=== Plain Text Content ===")
                            print(plainText)
                        } else if let htmlContent = mimeMessage.htmlContent {
                            print("=== HTML Content ===")
                            print(htmlContent)
                        }

                        let attachments = mimeMessage.attachments
                        if !attachments.isEmpty {
                            print("\n=== Attachments ===")
                            for (index, attachment) in attachments.enumerated() {
                                let filename = attachment.filename ?? "attachment\(index + 1)"
                                let size = attachment.decodedData?.count ?? 0
                                print("  - \(filename) (\(formatBytes(UInt32(size))))")
                            }
                        }
                    } else {
                        if let bodyString = String(data: bodyData, encoding: .utf8) {
                            print(bodyString)
                        } else if let bodyString = String(data: bodyData, encoding: .ascii) {
                            print(bodyString)
                        } else {
                            print("(Unable to decode as UTF-8/ASCII)")
                        }
                    }
                } catch {
                    print("MIME parsing failed: \(error)")
                    print("\n=== Raw Content ===")
                    if let bodyString = String(data: bodyData, encoding: .utf8) {
                        print(bodyString)
                    } else if let bodyString = String(data: bodyData, encoding: .ascii) {
                        print(bodyString)
                    } else {
                        print("(Unable to decode as UTF-8/ASCII, showing hex dump of first 500 bytes)")
                        let hexDump = bodyData.prefix(500)
                            .map { String(format: "%02x", $0) }
                            .joined(separator: " ")
                        print(hexDump)
                    }
                }
                print(String(repeating: "=", count: 80))
            } else {
                print("Failed to fetch message body")
            }
        }
    }

    func listMessagesWithDetails(client: IMAPClient, mailbox: String) async throws {
        print("Fetching message list...")

        let messageNumbers = try await client.listMessages(in: mailbox)

        if messageNumbers.isEmpty {
            print("No messages found in \(mailbox)")
            return
        }

        print("Found \(messageNumbers.count) messages. Fetching details...")

        let limit = min(messageNumbers.count, 20)
        let messagesToShow = Array(messageNumbers.suffix(limit))

        print("\nMessages in \(mailbox) (showing \(limit) most recent):")
        print(String(repeating: "=", count: 100))

        var messages: [(seq: UInt32, summary: MessageSummary)] = []

        for sequenceNumber in messagesToShow {
            if let summary = try await client.fetchMessageBySequence(sequenceNumber: sequenceNumber, in: mailbox) {
                messages.append((sequenceNumber, summary))
            }
        }

        for (sequenceNumber, summary) in messages.reversed() {
            let fromAddr = summary.envelope?.from.first
            let from = fromAddr?.displayName ?? fromAddr?.emailAddress ?? "Unknown"
            let subject = summary.envelope?.subject ?? "(No subject)"
            let date = formatMessageDate(summary.internalDate)
            let size = formatBytes(summary.size)
            let flags = summary.flags.map { $0.rawValue }.joined(separator: " ")

            print("\n#\(sequenceNumber) (UID: \(summary.uid))")
            print("  Date: \(date)")
            print("  From: \(from)")
            print("  Subject: \(subject)")
            print("  Size: \(size)")
            if !flags.isEmpty {
                print("  Flags: \(flags)")
            }

            if summary.envelope == nil {
                print("  [DEBUG: No envelope data received]")
            }

            print(String(repeating: "-", count: 100))
        }

        if messageNumbers.count > limit {
            print("\n(Showing \(limit) of \(messageNumbers.count) total messages)")
        }
    }

    func markAsRead(client: IMAPClient, mailbox: String, uid: UID) async throws {
        print("Marking message \(uid) as read...")
        try await client.markAsRead(uid: uid, in: mailbox)
        print("Message marked as read")
    }

    func markAsUnread(client: IMAPClient, mailbox: String, uid: UID) async throws {
        print("Marking message \(uid) as unread...")
        try await client.markAsUnread(uid: uid, in: mailbox)
        print("Message marked as unread")
    }

    func flagMessage(client: IMAPClient, mailbox: String, uid: UID) async throws {
        print("Flagging message \(uid)...")
        try await client.storeFlags(uid: uid, in: mailbox, flags: [.flagged], action: .add)
        print("Message flagged")
    }

    func unflagMessage(client: IMAPClient, mailbox: String, uid: UID) async throws {
        print("Removing flag from message \(uid)...")
        try await client.storeFlags(uid: uid, in: mailbox, flags: [.flagged], action: .remove)
        print("Flag removed")
    }

    func copyMessage(client: IMAPClient, from sourceMailbox: String, uid: UID, to destinationMailbox: String) async throws {
        print("Copying message \(uid) from '\(sourceMailbox)' to '\(destinationMailbox)'...")
        try await client.copyMessage(uid: uid, from: sourceMailbox, to: destinationMailbox)
        print("Message copied successfully")
    }

    func moveMessage(client: IMAPClient, from sourceMailbox: String, uid: UID, to destinationMailbox: String) async throws {
        print("Moving message \(uid) from '\(sourceMailbox)' to '\(destinationMailbox)'...")
        try await client.moveMessage(uid: uid, from: sourceMailbox, to: destinationMailbox)
        print("Message moved successfully")
    }

    func deleteMessage(client: IMAPClient, mailbox: String, uid: UID) async throws {
        print("Marking message \(uid) for deletion...")
        try await client.markForDeletion(uid: uid, in: mailbox)
        print("Message marked for deletion")
        print("  (Use 'expunge' to permanently delete)")
    }

    func expungeMailbox(client: IMAPClient, mailbox: String) async throws {
        print("Expunging deleted messages from '\(mailbox)'...")
        try await client.expunge(mailbox: mailbox)
        print("Deleted messages permanently removed")
    }
}
