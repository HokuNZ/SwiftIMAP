import Foundation

extension IMAPClient {
    func parseMessageSummary(
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
            case .uid(let uidValue):
                uid = uidValue
            case .flags(let flagValues):
                flags = Set(flagValues.compactMap { Flag(rawValue: $0) })
            case .internalDate(let date):
                internalDate = date
            case .rfc822Size(let sizeValue):
                size = sizeValue
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

    func parseEnvelope(_ data: IMAPResponse.EnvelopeData) -> Envelope {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        let date = data.date.flatMap { dateFormatter.date(from: $0) }

        let fromList = parseAddressList(data.from)
        let senderList = parseAddressList(data.sender)
        let replyToList = parseAddressList(data.replyTo)
        let toList = parseAddressList(data.to)
        let ccList = parseAddressList(data.cc)
        let bccList = parseAddressList(data.bcc)

        return Envelope(
            date: date,
            subject: data.subject,
            from: fromList.flat,
            fromEntries: fromList.entries,
            sender: senderList.flat,
            senderEntries: senderList.entries,
            replyTo: replyToList.flat,
            replyToEntries: replyToList.entries,
            to: toList.flat,
            toEntries: toList.entries,
            cc: ccList.flat,
            ccEntries: ccList.entries,
            bcc: bccList.flat,
            bccEntries: bccList.entries,
            inReplyTo: data.inReplyTo,
            messageID: data.messageID
        )
    }

    private struct ParsedAddressList {
        let flat: [Address]
        let entries: [AddressListEntry]
    }

    private func parseAddressList(_ addresses: [IMAPResponse.AddressData]?) -> ParsedAddressList {
        guard let addresses = addresses else {
            return ParsedAddressList(flat: [], entries: [])
        }

        var flat: [Address] = []
        var entries: [AddressListEntry] = []

        var currentGroupName: String?
        var currentGroupMembers: [Address] = []

        func finishGroupIfNeeded() {
            guard let groupName = currentGroupName else { return }
            entries.append(.group(name: groupName, members: currentGroupMembers))
            currentGroupName = nil
            currentGroupMembers = []
        }

        for addressData in addresses {
            let mailbox = addressData.mailbox
            let host = addressData.host

            if mailbox == nil, host == nil {
                finishGroupIfNeeded()
                continue
            }

            if host == nil, let groupName = mailbox {
                finishGroupIfNeeded()
                currentGroupName = groupName
                currentGroupMembers = []
                continue
            }

            guard let mailbox = mailbox, let host = host else {
                continue
            }

            let address = Address(name: addressData.name, mailbox: mailbox, host: host)
            flat.append(address)

            if currentGroupName != nil {
                currentGroupMembers.append(address)
            } else {
                entries.append(.mailbox(address))
            }
        }

        finishGroupIfNeeded()

        return ParsedAddressList(flat: flat, entries: entries)
    }
}
