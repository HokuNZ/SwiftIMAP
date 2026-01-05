import Foundation

extension IMAPParser {
    func parseLine(_ line: String) throws -> IMAPResponse? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("* ") {
            return try parseUntaggedResponse(String(trimmed.dropFirst(2)))
        } else if trimmed == "+" {
            return .continuation("")
        } else if trimmed.hasPrefix("+ ") {
            return .continuation(String(trimmed.dropFirst(2)))
        } else {
            return try parseTaggedResponse(trimmed)
        }
    }

    private func parseTaggedResponse(_ line: String) throws -> IMAPResponse {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw IMAPError.parsingError("Invalid tagged response: \(line)")
        }

        let tag = String(parts[0])
        let statusStr = String(parts[1]).uppercased()
        let remainder = parts.count > 2 ? String(parts[2]) : nil

        let (code, text) = try parseResponseCodeAndText(remainder)

        let status: IMAPResponse.ResponseStatus
        switch statusStr {
        case "OK":
            status = .ok(code, text)
        case "NO":
            status = .no(code, text)
        case "BAD":
            status = .bad(code, text)
        case "PREAUTH":
            status = .preauth(code, text)
        case "BYE":
            status = .bye(code, text)
        default:
            throw IMAPError.parsingError("Unknown response status: \(statusStr)")
        }

        return .tagged(tag: tag, status: status)
    }

    private func parseUntaggedResponse(_ line: String) throws -> IMAPResponse {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard !parts.isEmpty else {
            throw IMAPError.parsingError("Empty untagged response")
        }

        let first = String(parts[0]).uppercased()
        let remainder = parts.count > 1 ? String(parts[1]) : ""

        if let number = UInt32(first) {
            return try parseNumericUntaggedResponse(number, remainder: remainder)
        } else {
            return try parseNonNumericUntaggedResponse(first, remainder: remainder)
        }
    }

    private func parseNumericUntaggedResponse(_ number: UInt32, remainder: String) throws -> IMAPResponse {
        let parts = remainder.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard !parts.isEmpty else {
            throw IMAPError.parsingError("Invalid numeric untagged response")
        }

        let command = String(parts[0]).uppercased()

        switch command {
        case "EXISTS":
            return .untagged(.exists(number))
        case "RECENT":
            return .untagged(.recent(number))
        case "EXPUNGE":
            return .untagged(.expunge(number))
        case "FETCH":
            let fetchData = parts.count > 1 ? String(parts[1]) : ""
            let attributes = try parseFetchAttributes(fetchData)
            return .untagged(.fetch(number, attributes))
        default:
            throw IMAPError.parsingError("Unknown numeric untagged response: \(command)")
        }
    }

    private func parseNonNumericUntaggedResponse(_ command: String, remainder: String) throws -> IMAPResponse {
        switch command {
        case "OK", "NO", "BAD", "PREAUTH", "BYE":
            let (code, text) = try parseResponseCodeAndText(remainder)
            let status: IMAPResponse.ResponseStatus
            switch command {
            case "OK":
                status = .ok(code, text)
            case "NO":
                status = .no(code, text)
            case "BAD":
                status = .bad(code, text)
            case "PREAUTH":
                status = .preauth(code, text)
            case "BYE":
                status = .bye(code, text)
            default:
                fatalError("Unreachable")
            }
            return .untagged(.status(status))

        case "CAPABILITY":
            let capabilities = remainder.split(separator: " ").map(String.init)
            return .untagged(.capability(capabilities))

        case "LIST", "LSUB":
            let listResponse = try parseListResponse(remainder)
            return .untagged(command == "LIST" ? .list(listResponse) : .lsub(listResponse))

        case "SEARCH":
            let numbers = remainder.split(separator: " ")
                .compactMap { UInt32($0) }
            return .untagged(.search(numbers))

        case "FLAGS":
            let flags = try parseParenthesizedList(remainder)
            return .untagged(.flags(flags))

        case "STATUS":
            let (mailbox, status) = try parseStatusResponse(remainder)
            return .untagged(.statusResponse(mailbox, status))

        default:
            throw IMAPError.parsingError("Unknown untagged response: \(command)")
        }
    }

    private func parseResponseCodeAndText(_ input: String?) throws -> (IMAPResponse.ResponseCode?, String?) {
        guard let input = input, !input.isEmpty else {
            return (nil, nil)
        }

        if input.hasPrefix("[") {
            guard let closeBracket = input.firstIndex(of: "]") else {
                throw IMAPError.parsingError("Unclosed response code bracket")
            }

            let codeStr = String(input[input.index(after: input.startIndex)..<closeBracket])
            let code = try parseResponseCode(codeStr)

            let textStart = input.index(after: closeBracket)
            let text = textStart < input.endIndex ? String(input[textStart...]).trimmingCharacters(in: .whitespaces) : nil

            return (code, text?.isEmpty == true ? nil : text)
        } else {
            return (nil, input)
        }
    }

    private func parseResponseCode(_ code: String) throws -> IMAPResponse.ResponseCode {
        let parts = code.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard !parts.isEmpty else {
            throw IMAPError.parsingError("Empty response code")
        }

        let codeName = String(parts[0]).uppercased()
        let codeValue = parts.count > 1 ? String(parts[1]) : nil

        switch codeName {
        case "ALERT":
            return .alert
        case "BADCHARSET":
            if let value = codeValue {
                let charsets = try parseParenthesizedList(value)
                return .badCharset(charsets)
            }
            return .badCharset(nil)
        case "CAPABILITY":
            let capabilities = codeValue?.split(separator: " ").map(String.init) ?? []
            return .capability(capabilities)
        case "PARSE":
            return .parse
        case "PERMANENTFLAGS":
            if let value = codeValue {
                let flags = try parseParenthesizedList(value)
                return .permanentFlags(flags)
            }
            return .permanentFlags([])
        case "READ-ONLY":
            return .readOnly
        case "READ-WRITE":
            return .readWrite
        case "TRYCREATE":
            return .tryCreate
        case "UIDNEXT":
            guard let value = codeValue, let uid = UInt32(value) else {
                throw IMAPError.parsingError("Invalid UIDNEXT value")
            }
            return .uidNext(uid)
        case "UIDVALIDITY":
            guard let value = codeValue, let uid = UInt32(value) else {
                throw IMAPError.parsingError("Invalid UIDVALIDITY value")
            }
            return .uidValidity(uid)
        case "UNSEEN":
            guard let value = codeValue, let num = UInt32(value) else {
                throw IMAPError.parsingError("Invalid UNSEEN value")
            }
            return .unseen(num)
        default:
            return .other(codeName, codeValue)
        }
    }

    private func parseListResponse(_ input: String) throws -> IMAPResponse.ListResponse {
        let scanner = Scanner(string: input)
        scanner.charactersToBeSkipped = nil

        let attributes = try parseParenthesizedList(scanner)

        _ = scanner.scanCharacter()

        let delimiter: String?
        if scanner.scanString("NIL") != nil {
            delimiter = nil
        } else {
            delimiter = try parseQuotedString(scanner)
        }

        _ = scanner.scanCharacter()

        var rawName: Data?
        let name = try parseAString(scanner, literalData: &rawName)

        return IMAPResponse.ListResponse(
            attributes: attributes,
            delimiter: delimiter,
            name: name,
            rawName: rawName
        )
    }

    private func parseStatusResponse(_ input: String) throws -> (String, MailboxStatus) {
        let scanner = Scanner(string: input)
        scanner.charactersToBeSkipped = CharacterSet.whitespaces

        let mailbox = try parseAString(scanner)

        guard scanner.scanString("(") != nil else {
            throw IMAPError.parsingError("Expected opening parenthesis for status items")
        }

        var messages: UInt32 = 0
        var recent: UInt32 = 0
        var uidNext: UInt32 = 0
        var uidValidity: UInt32 = 0
        var unseen: UInt32 = 0

        while scanner.scanString(")") == nil {
            guard let item = scanner.scanUpToCharacters(from: .whitespaces) else {
                break
            }

            switch item.uppercased() {
            case "MESSAGES":
                messages = scanner.scanUInt32() ?? 0
            case "RECENT":
                recent = scanner.scanUInt32() ?? 0
            case "UIDNEXT":
                uidNext = scanner.scanUInt32() ?? 0
            case "UIDVALIDITY":
                uidValidity = scanner.scanUInt32() ?? 0
            case "UNSEEN":
                unseen = scanner.scanUInt32() ?? 0
            default:
                _ = scanner.scanUpToCharacters(from: .whitespaces)
            }
        }

        let status = MailboxStatus(
            messages: messages,
            recent: recent,
            uidNext: uidNext,
            uidValidity: uidValidity,
            unseen: unseen
        )

        return (mailbox, status)
    }

    private func parseParenthesizedList(_ input: String) throws -> [String] {
        let scanner = Scanner(string: input)
        return try parseParenthesizedList(scanner)
    }
}
