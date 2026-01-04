import Foundation

extension IMAPClient {
    public func listMailboxes(reference: String = "", pattern: String = "*") async throws -> [Mailbox] {
        let responses = try await connection.sendCommand(.list(reference: reference, pattern: pattern))

        var mailboxes: [Mailbox] = []

        for response in responses {
            if case .untagged(.list(let listResponse)) = response {
                let decodedName = IMAPMailboxNameCodec.decode(listResponse.name)
                let attributes = Set(listResponse.attributes.compactMap { attr in
                    Mailbox.Attribute(rawValue: attr)
                })

                let mailbox = Mailbox(
                    name: decodedName,
                    attributes: attributes,
                    delimiter: listResponse.delimiter
                )
                mailboxes.append(mailbox)
            }
        }

        return mailboxes
    }

    // MARK: - Mailbox Management

    public func createMailbox(_ mailbox: String) async throws {
        _ = try await connection.sendCommand(.create(mailbox: mailbox))
    }

    public func deleteMailbox(_ mailbox: String) async throws {
        _ = try await connection.sendCommand(.delete(mailbox: mailbox))
    }

    public func renameMailbox(from sourceMailbox: String, to destinationMailbox: String) async throws {
        _ = try await connection.sendCommand(.rename(from: sourceMailbox, to: destinationMailbox))
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
                case .flags:
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
                        case .permanentFlags:
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

    public func mailboxStatus(
        _ mailbox: String,
        items: [IMAPCommand.StatusItem] = [.messages, .recent, .uidNext, .uidValidity, .unseen]
    ) async throws -> MailboxStatus {
        let responses = try await connection.sendCommand(.status(mailbox: mailbox, items: items))

        for response in responses {
            if case .untagged(.statusResponse(_, let status)) = response {
                return status
            }
        }

        throw IMAPError.protocolError("No STATUS response received")
    }
}
