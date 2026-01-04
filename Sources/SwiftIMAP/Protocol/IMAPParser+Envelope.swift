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
        let date = try parseNilOrQuotedString(scanner)
        let subject = try parseNilOrQuotedString(scanner)
        let from = try parseAddressList(scanner)
        let sender = try parseAddressList(scanner)
        let replyTo = try parseAddressList(scanner)
        let to = try parseAddressList(scanner)
        let cc = try parseAddressList(scanner)
        let bcc = try parseAddressList(scanner)
        let inReplyTo = try parseNilOrQuotedString(scanner)
        let messageID = try parseNilOrQuotedString(scanner)

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
            messageID: messageID
        )
    }

    func parseNilOrQuotedString(_ scanner: Scanner) throws -> String? {
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

        return try parseNString(scanner)
    }

    func parseNString(_ scanner: Scanner) throws -> String {
        _ = scanner.scanCharacters(from: .whitespaces)

        if let literal = try parseLiteralPlaceholder(scanner) {
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

        let name = try parseNilOrQuotedString(scanner)
        let adl = try parseNilOrQuotedString(scanner)
        let mailbox = try parseNilOrQuotedString(scanner)
        let host = try parseNilOrQuotedString(scanner)

        _ = scanner.scanCharacters(from: .whitespaces)
        guard scanner.scanString(")") != nil else {
            throw IMAPError.parsingError("Expected closing parenthesis for address")
        }

        return IMAPResponse.AddressData(
            name: name,
            adl: adl,
            mailbox: mailbox,
            host: host
        )
    }
}
