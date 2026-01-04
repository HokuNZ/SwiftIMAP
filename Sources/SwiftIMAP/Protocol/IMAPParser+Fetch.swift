import Foundation

extension IMAPParser {
    func parseFetchAttributes(_ input: String) throws -> [IMAPResponse.FetchAttribute] {
        guard input.hasPrefix("(") && input.hasSuffix(")") else {
            throw IMAPError.parsingError("Fetch attributes must be parenthesized")
        }

        let content = String(input.dropFirst().dropLast())
        var attributes: [IMAPResponse.FetchAttribute] = []

        let scanner = Scanner(string: content)
        scanner.charactersToBeSkipped = nil

        while !scanner.isAtEnd {
            let startIndex = scanner.currentIndex
            if let attr = try parseFetchAttribute(scanner) {
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

    func parseFetchAttribute(_ scanner: Scanner) throws -> IMAPResponse.FetchAttribute? {
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
                return try parseBodyAttribute(name: name, scanner: scanner)
            }

            // Skip unknown attributes
            _ = scanner.scanUpToCharacters(from: .whitespaces)
            return nil
        }
    }

    func parseBodyAttribute(name: String, scanner: Scanner) throws -> IMAPResponse.FetchAttribute? {
        // Parse BODY[section]<origin> or similar
        let upperName = name.uppercased()
        let isPeek = upperName.contains("PEEK")

        var section: String? = nil
        var origin: UInt32? = nil

        // Check for section specifier
        if scanner.scanString("[") != nil {
            if let sectionStr = scanner.scanUpToString("]") {
                section = sectionStr.isEmpty ? nil : sectionStr
            }
            _ = scanner.scanString("]")
        }

        // Check for origin
        if scanner.scanString("<") != nil {
            origin = scanner.scanUInt32()
            _ = scanner.scanString(">")
        }

        _ = scanner.scanCharacters(from: .whitespaces)

        // Check for literal
        if scanner.scanString("{") != nil {
            guard scanner.scanInt() != nil else {
                throw IMAPError.parsingError("Invalid literal size")
            }
            guard scanner.scanString("}") != nil else {
                throw IMAPError.parsingError("Expected closing brace for literal")
            }

            // At this point, we need to read 'size' bytes from the buffer
            // For now, we'll return a placeholder indicating we need a literal
            if isPeek {
                return .bodyPeek(section: section, origin: origin, data: nil)
            } else {
                return .body(section: section, origin: origin, data: nil)
            }
        } else if scanner.scanString("NIL") != nil {
            // Body is NIL
            if isPeek {
                return .bodyPeek(section: section, origin: origin, data: nil)
            } else {
                return .body(section: section, origin: origin, data: nil)
            }
        } else if scanner.scanString("\"") != nil {
            // Quoted string body (rare but possible for small bodies)
            scanner.currentIndex = scanner.string.index(before: scanner.currentIndex)
            let bodyStr = try parseQuotedString(scanner)
            let data = Data(bodyStr.utf8)

            if isPeek {
                return .bodyPeek(section: section, origin: origin, data: data)
            } else {
                return .body(section: section, origin: origin, data: data)
            }
        }

        return nil
    }
}
