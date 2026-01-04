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

        return Envelope(
            date: date,
            subject: data.subject,
            from: parseAddresses(data.from),
            sender: parseAddresses(data.sender),
            replyTo: parseAddresses(data.replyTo),
            to: parseAddresses(data.to),
            cc: parseAddresses(data.cc),
            bcc: parseAddresses(data.bcc),
            inReplyTo: data.inReplyTo,
            messageID: data.messageID
        )
    }

    func parseAddresses(_ addresses: [IMAPResponse.AddressData]?) -> [Address] {
        guard let addresses = addresses else { return [] }

        return addresses.compactMap { addr in
            guard let mailbox = addr.mailbox,
                  let host = addr.host else {
                return nil
            }

            return Address(
                name: addr.name,
                mailbox: mailbox,
                host: host
            )
        }
    }
}
