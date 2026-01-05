import Foundation

extension IMAPParser {
    func parseInternalDate(_ dateStr: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: dateStr)
    }

    func parseEnvelopeData(_ scanner: Scanner) throws -> IMAPResponse.EnvelopeData {
        guard scanner.scanString("(") != nil else {
            throw IMAPError.parsingError("Expected opening parenthesis for envelope")
        }

        // ENVELOPE format: (date subject from sender reply-to to cc bcc in-reply-to message-id)
        var rawDate: Data?
        var rawSubject: Data?
        var rawInReplyTo: Data?
        var rawMessageID: Data?

        let date = try parseNilOrQuotedString(scanner, literalData: &rawDate)
        let subject = try parseNilOrQuotedString(scanner, literalData: &rawSubject)
        let from = try parseAddressList(scanner)
        let sender = try parseAddressList(scanner)
        let replyTo = try parseAddressList(scanner)
        let to = try parseAddressList(scanner)
        let cc = try parseAddressList(scanner)
        let bcc = try parseAddressList(scanner)
        let inReplyTo = try parseNilOrQuotedString(scanner, literalData: &rawInReplyTo)
        let messageID = try parseNilOrQuotedString(scanner, literalData: &rawMessageID)

        guard scanner.scanString(")") != nil else {
            throw IMAPError.parsingError("Expected closing parenthesis for envelope")
        }

        return IMAPResponse.EnvelopeData(
            date: date,
            subject: subject,
            from: from,
            sender: sender,
            replyTo: replyTo,
            to: to,
            cc: cc,
            bcc: bcc,
            inReplyTo: inReplyTo,
            messageID: messageID,
            rawDate: rawDate,
            rawSubject: rawSubject,
            rawInReplyTo: rawInReplyTo,
            rawMessageID: rawMessageID
        )
    }

    func parseNilOrQuotedString(_ scanner: Scanner) throws -> String? {
        var literalData: Data?
        return try parseNilOrQuotedString(scanner, literalData: &literalData)
    }

    func parseNilOrQuotedString(_ scanner: Scanner, literalData: inout Data?) throws -> String? {
        literalData = nil
        _ = scanner.scanCharacters(from: .whitespaces)

        let currentPos = scanner.currentIndex
        if scanner.scanString("NIL") != nil {
            if scanner.isAtEnd {
                return nil
            }

            let nextPos = scanner.currentIndex
            if nextPos < scanner.string.endIndex {
                let nextChar = scanner.string[nextPos]
                if " ()\r\n".contains(nextChar) {
                    return nil
                }
            }

            scanner.currentIndex = currentPos
        }

        return try parseNString(scanner, literalData: &literalData)
    }

    func parseNString(_ scanner: Scanner) throws -> String {
        var literalData: Data?
        return try parseNString(scanner, literalData: &literalData)
    }

    func parseNString(_ scanner: Scanner, literalData: inout Data?) throws -> String {
        literalData = nil
        _ = scanner.scanCharacters(from: .whitespaces)

        if let literal = try parseLiteralPlaceholder(scanner, literalData: &literalData) {
            return literal
        }

        let currentPosition = scanner.currentIndex
        let nextChar = currentPosition < scanner.string.endIndex ? scanner.string[currentPosition] : nil

        if nextChar == "\"" {
            return try parseQuotedString(scanner)
        }

        if let atom = scanner.scanUpToCharacters(from: CharacterSet(charactersIn: " ()\"\r\n")) {
            return atom
        }

        if let char = nextChar, " ()\"\r\n".contains(char) {
            return ""
        }

        throw IMAPError.parsingError("Expected string value")
    }

    func parseAddressList(_ scanner: Scanner) throws -> [IMAPResponse.AddressData]? {
        _ = scanner.scanCharacters(from: .whitespaces)

        let currentPos = scanner.currentIndex
        if scanner.scanString("NIL") != nil {
            let nextPos = scanner.currentIndex
            if nextPos < scanner.string.endIndex {
                let nextChar = scanner.string[nextPos]
                if " ()\r\n".contains(nextChar) {
                    return nil
                }
            } else {
                return nil
            }
            scanner.currentIndex = currentPos
        }

        guard scanner.scanString("(") != nil else {
            throw IMAPError.parsingError("Expected opening parenthesis for address list")
        }

        var addresses: [IMAPResponse.AddressData] = []
        _ = scanner.scanCharacters(from: .whitespaces)

        while scanner.scanString(")") == nil {
            guard !scanner.isAtEnd else {
                throw IMAPError.parsingError("Unclosed address list")
            }

            let address = try parseAddress(scanner)
            addresses.append(address)

            _ = scanner.scanCharacters(from: .whitespaces)
        }

        return addresses
    }

    func parseAddress(_ scanner: Scanner) throws -> IMAPResponse.AddressData {
        _ = scanner.scanCharacters(from: .whitespaces)

        guard scanner.scanString("(") != nil else {
            throw IMAPError.parsingError("Expected opening parenthesis for address")
        }

        _ = scanner.scanCharacters(from: .whitespaces)

        var rawName: Data?
        var rawAdl: Data?
        var rawMailbox: Data?
        var rawHost: Data?

        let name = try parseNilOrQuotedString(scanner, literalData: &rawName)
        let adl = try parseNilOrQuotedString(scanner, literalData: &rawAdl)
        let mailbox = try parseNilOrQuotedString(scanner, literalData: &rawMailbox)
        let host = try parseNilOrQuotedString(scanner, literalData: &rawHost)

        _ = scanner.scanCharacters(from: .whitespaces)
        guard scanner.scanString(")") != nil else {
            throw IMAPError.parsingError("Expected closing parenthesis for address")
        }

        return IMAPResponse.AddressData(
            name: name,
            adl: adl,
            mailbox: mailbox,
            host: host,
            rawName: rawName,
            rawAdl: rawAdl,
            rawMailbox: rawMailbox,
            rawHost: rawHost
        )
    }
}
