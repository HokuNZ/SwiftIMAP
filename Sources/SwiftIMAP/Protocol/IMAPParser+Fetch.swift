import Foundation

extension IMAPParser {
    func parseFetchAttributes(_ input: String) throws -> [IMAPResponse.FetchAttribute] {
        var literalDataQueue: [Data]? = nil
        return try parseFetchAttributesInternal(input, literalDataQueue: &literalDataQueue)
    }

    func parseFetchAttributesInternal(
        _ input: String,
        literalDataQueue: inout [Data]?
    ) throws -> [IMAPResponse.FetchAttribute] {
        guard input.hasPrefix("(") && input.hasSuffix(")") else {
            throw IMAPError.parsingError("Fetch attributes must be parenthesized")
        }

        let content = String(input.dropFirst().dropLast())
        var attributes: [IMAPResponse.FetchAttribute] = []

        let scanner = Scanner(string: content)
        scanner.charactersToBeSkipped = nil

        while !scanner.isAtEnd {
            let startIndex = scanner.currentIndex
            if let attr = try parseFetchAttribute(scanner, literalDataQueue: &literalDataQueue) {
                attributes.append(attr)
            } else {
                // If no attribute was parsed, advance the scanner to prevent infinite loop
                if scanner.currentIndex == startIndex {
                    _ = scanner.scanCharacter()
                }
            }
        }

        return attributes
    }

    func parseFetchAttribute(
        _ scanner: Scanner,
        literalDataQueue: inout [Data]?
    ) throws -> IMAPResponse.FetchAttribute? {
        _ = scanner.scanCharacters(from: .whitespaces)
        guard let name = scanner.scanUpToCharacters(from: CharacterSet(charactersIn: " (")) else {
            return nil
        }

        switch name.uppercased() {
        case "UID":
            _ = scanner.scanCharacters(from: .whitespaces)
            guard let uid = scanner.scanUInt32() else {
                throw IMAPError.parsingError("Invalid UID value")
            }
            return .uid(uid)

        case "FLAGS":
            _ = scanner.scanCharacters(from: .whitespaces)
            let flags = try parseParenthesizedList(scanner)
            return .flags(flags)

        case "INTERNALDATE":
            _ = scanner.scanCharacters(from: .whitespaces)
            let dateStr = try parseQuotedString(scanner)
            guard let date = parseInternalDate(dateStr) else {
                throw IMAPError.parsingError("Invalid internal date format")
            }
            return .internalDate(date)

        case "RFC822.SIZE":
            _ = scanner.scanCharacters(from: .whitespaces)
            guard let size = scanner.scanUInt32() else {
                throw IMAPError.parsingError("Invalid RFC822.SIZE value")
            }
            return .rfc822Size(size)

        case "RFC822":
            let (data, consumed) = try parseFetchDataValue(scanner, literalDataQueue: &literalDataQueue)
            guard consumed else { return nil }
            return .body(section: nil, origin: nil, data: data)

        case "RFC822.HEADER":
            let (data, consumed) = try parseFetchDataValue(scanner, literalDataQueue: &literalDataQueue)
            guard consumed else { return nil }
            return .header(data ?? Data())

        case "RFC822.TEXT":
            let (data, consumed) = try parseFetchDataValue(scanner, literalDataQueue: &literalDataQueue)
            guard consumed else { return nil }
            return .text(data ?? Data())

        case "ENVELOPE":
            _ = scanner.scanCharacters(from: .whitespaces)
            let envelope = try parseEnvelopeData(scanner)
            return .envelope(envelope)

        case "BODYSTRUCTURE":
            _ = scanner.scanCharacters(from: .whitespaces)
            let bodyStructure = try parseBodyStructure(scanner)
            return .bodyStructure(bodyStructure)

        default:
            // Check if this might be a BODY attribute
            if name.uppercased().hasPrefix("BODY") {
                return try parseBodyAttribute(
                    name: name,
                    scanner: scanner,
                    literalDataQueue: &literalDataQueue
                )
            }

            // Skip unknown attributes
            _ = scanner.scanUpToCharacters(from: .whitespaces)
            return nil
        }
    }

    func parseBodyAttribute(
        name: String,
        scanner: Scanner,
        literalDataQueue: inout [Data]?
    ) throws -> IMAPResponse.FetchAttribute? {
        // Parse BODY[section]<origin> or similar
        let upperName = name.uppercased()
        let isPeek = upperName.contains("PEEK")

        var section: String? = nil
        var origin: UInt32? = nil
        var sectionIncomplete = false

        if let sectionStart = name.firstIndex(of: "[") {
            let contentStart = name.index(after: sectionStart)
            if let sectionEnd = name[contentStart...].firstIndex(of: "]") {
                section = String(name[contentStart..<sectionEnd])
            } else {
                section = String(name[contentStart...])
                sectionIncomplete = true
            }
        }

        if sectionIncomplete || (section == nil && scanner.scanString("[") != nil) {
            if section == nil {
                section = ""
            }
            if let sectionRemainder = scanner.scanUpToString("]") {
                section = (section ?? "") + sectionRemainder
            }
            _ = scanner.scanString("]")
        }

        if let originStart = name.firstIndex(of: "<"),
           let originEnd = name[originStart...].firstIndex(of: ">"),
           originStart < originEnd {
            let originString = name[name.index(after: originStart)..<originEnd]
            origin = UInt32(originString)
        }

        if origin == nil, scanner.scanString("<") != nil {
            origin = scanner.scanUInt32()
            _ = scanner.scanString(">")
        }

        if let trimmed = section?.trimmingCharacters(in: .whitespacesAndNewlines) {
            section = trimmed.isEmpty ? nil : trimmed
        }

        let (data, consumed) = try parseFetchDataValue(scanner, literalDataQueue: &literalDataQueue)
        guard consumed else {
            return nil
        }

        if let section = section {
            if let headerFields = parseHeaderFieldsSection(section) {
                let payload = data ?? Data()
                if headerFields.isNot {
                    return .headerFieldsNot(fields: headerFields.fields, data: payload)
                }
                return .headerFields(fields: headerFields.fields, data: payload)
            }

            switch section.uppercased() {
            case "HEADER":
                return .header(data ?? Data())
            case "TEXT":
                return .text(data ?? Data())
            default:
                break
            }
        }

        if isPeek {
            return .bodyPeek(section: section, origin: origin, data: data)
        } else {
            return .body(section: section, origin: origin, data: data)
        }
    }

    private func parseFetchDataValue(
        _ scanner: Scanner,
        literalDataQueue: inout [Data]?
    ) throws -> (Data?, Bool) {
        let startIndex = scanner.currentIndex
        _ = scanner.scanCharacters(from: .whitespaces)

        if scanner.scanString("~LITERAL~") != nil {
            if var queue = literalDataQueue, !queue.isEmpty {
                let data = queue.removeFirst()
                literalDataQueue = queue
                return (data, true)
            }

            let data = try nextLiteralData()
            return (data, true)
        }

        if scanner.scanString("NIL") != nil {
            return (nil, true)
        }

        if scanner.scanString("\"") != nil {
            scanner.currentIndex = scanner.string.index(before: scanner.currentIndex)
            let bodyStr = try parseQuotedString(scanner)
            return (Data(bodyStr.utf8), true)
        }

        scanner.currentIndex = startIndex
        return (nil, false)
    }

    private func parseHeaderFieldsSection(
        _ section: String
    ) -> (fields: [String], isNot: Bool)? {
        let scanner = Scanner(string: section)
        scanner.charactersToBeSkipped = nil

        guard let name = scanner.scanUpToCharacters(from: .whitespaces) else {
            return nil
        }

        let upperName = name.uppercased()
        let isNot = upperName == "HEADER.FIELDS.NOT"
        guard upperName == "HEADER.FIELDS" || isNot else {
            return nil
        }

        _ = scanner.scanCharacters(from: .whitespaces)
        guard scanner.scanString("(") != nil else {
            return nil
        }

        var fields: [String] = []

        while scanner.scanString(")") == nil {
            guard !scanner.isAtEnd else {
                return nil
            }

            if let field = scanner.scanUpToCharacters(
                from: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ")"))
            ) {
                fields.append(field)
            }

            _ = scanner.scanCharacters(from: .whitespaces)
        }

        return (fields, isNot)
    }
}
