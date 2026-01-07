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

    public func listSubscribedMailboxes(reference: String = "", pattern: String = "*") async throws -> [Mailbox] {
        let responses = try await connection.sendCommand(.lsub(reference: reference, pattern: pattern))

        var mailboxes: [Mailbox] = []

        for response in responses {
            if case .untagged(.lsub(let listResponse)) = response {
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

    public func subscribeMailbox(_ mailbox: String) async throws {
        _ = try await connection.sendCommand(.subscribe(mailbox: mailbox))
    }

    public func unsubscribeMailbox(_ mailbox: String) async throws {
        _ = try await connection.sendCommand(.unsubscribe(mailbox: mailbox))
    }

    public func selectMailbox(_ mailbox: String) async throws -> MailboxStatus {
        let responses = try await connection.sendCommand(.select(mailbox: mailbox))
        let status = parseMailboxStatus(from: responses)
        await connection.setSelected(mailbox: mailbox)

        return status
    }

    public func examineMailbox(_ mailbox: String) async throws -> MailboxStatus {
        let responses = try await connection.sendCommand(.examine(mailbox: mailbox))
        let status = parseMailboxStatus(from: responses)
        await connection.setSelected(mailbox: mailbox)

        return status
    }

    public func checkMailbox() async throws {
        _ = try await connection.sendCommand(.check)
    }

    public func closeMailbox() async throws {
        _ = try await connection.sendCommand(.close)
        await connection.setAuthenticated()
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

private extension IMAPClient {
    func parseMailboxStatus(from responses: [IMAPResponse]) -> MailboxStatus {
        var exists: UInt32 = 0
        var recent: UInt32 = 0
        var uidNext: UInt32 = 0
        var uidValidity: UInt32 = 0
        var unseen: UInt32 = 0
        
        func applyStatusCode(_ code: IMAPResponse.ResponseCode?) {
            guard let code = code else { return }
            switch code {
            case .uidNext(let uid):
                uidNext = uid
            case .uidValidity(let uid):
                uidValidity = uid
            case .unseen(let num):
                unseen = num
            case .permanentFlags, .alert, .badCharset, .capability, .parse, .readOnly, .readWrite, .tryCreate, .other:
                break
            }
        }

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
                case .status(let status):
                    if case .ok(let code, _) = status {
                        applyStatusCode(code)
                    }
                default:
                    break
                }

            case .tagged(_, let status):
                switch status {
                case .ok(let code, _):
                    applyStatusCode(code)
                default:
                    break
                }

            default:
                break
            }
        }

        return MailboxStatus(
            messages: exists,
            recent: recent,
            uidNext: uidNext,
            uidValidity: uidValidity,
            unseen: unseen
        )
    }
}
