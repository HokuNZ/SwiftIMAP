import Foundation

extension IMAPParser {
    func parseBodyStructure(_ scanner: Scanner) throws -> IMAPResponse.BodyStructureData {
        guard scanner.scanString("(") != nil else {
            throw IMAPError.parsingError("Expected opening parenthesis for body structure")
        }

        // Check for multipart
        if scanner.scanString("(") != nil {
            scanner.currentIndex = scanner.string.index(before: scanner.currentIndex) // put back the paren
            var parts: [IMAPResponse.BodyStructureData] = []

            // Keep parsing subparts until we hit the multipart subtype string
            while scanner.scanString("(") != nil {
                scanner.currentIndex = scanner.string.index(before: scanner.currentIndex)
                parts.append(try parseBodyStructure(scanner))
                _ = scanner.scanCharacters(from: .whitespaces)
            }

            let subtype = try parseNString(scanner)

            let parameters = try parseOptionalParameterList(scanner)
            let disposition = try parseOptionalDisposition(scanner)
            let language = try parseOptionalLanguage(scanner)
            let location = try parseOptionalLocation(scanner)
            let extensions = try parseBodyExtensions(scanner)

            guard scanner.scanString(")") != nil else {
                throw IMAPError.parsingError("Expected closing parenthesis for multipart body structure")
            }

            // For multipart, we need to create a BodyStructureData with parts
            return IMAPResponse.BodyStructureData(
                type: "multipart",
                subtype: subtype,
                parameters: parameters,
                id: nil,
                description: nil,
                encoding: "7bit",
                size: 0,
                lines: nil,
                md5: nil,
                disposition: disposition,
                language: language,
                location: location,
                extensions: extensions,
                parts: parts
            )

        } else {
            // Single part
            let part = try parseSingleBodyPart(scanner)
            return part
        }
    }

    private func parseSingleBodyPart(_ scanner: Scanner) throws -> IMAPResponse.BodyStructureData {
        let type = try parseNString(scanner)
        let subtype = try parseNString(scanner)
        let parameters = try parseParameterList(scanner)
        let contentId = try parseNilOrQuotedString(scanner)
        let description = try parseNilOrQuotedString(scanner)
        let encoding = try parseNString(scanner)

        _ = scanner.scanCharacters(from: .whitespaces)
        guard let size = scanner.scanUInt() else {
            throw IMAPError.parsingError("Invalid size in body part")
        }

        var lines: UInt32? = nil
        var md5: String? = nil
        var disposition: IMAPResponse.DispositionData? = nil
        var language: [String]? = nil
        var location: String? = nil
        var extensions: [String]? = nil

        if type.lowercased() == "text" {
            _ = scanner.scanCharacters(from: .whitespaces)
            if let lineCount = scanner.scanUInt() {
                lines = UInt32(lineCount)
            }
        } else if type.lowercased() == "message" && subtype.lowercased() == "rfc822" {
            _ = scanner.scanCharacters(from: .whitespaces)
            _ = try parseEnvelopeData(scanner)
            _ = scanner.scanCharacters(from: .whitespaces)
            _ = try parseBodyStructure(scanner)
            _ = scanner.scanCharacters(from: .whitespaces)
            if let lineCount = scanner.scanUInt() {
                lines = UInt32(lineCount)
            }
        }

        if !peekIsClosingParen(scanner) {
            md5 = try parseNilOrQuotedString(scanner)
        }

        if !peekIsClosingParen(scanner) {
            disposition = try parseDisposition(scanner)
        }

        if !peekIsClosingParen(scanner) {
            language = try parseLanguage(scanner)
        }

        if !peekIsClosingParen(scanner) {
            location = try parseNilOrQuotedString(scanner)
        }

        if !peekIsClosingParen(scanner) {
            extensions = try parseBodyExtensions(scanner)
        }

        guard scanner.scanString(")") != nil else {
            throw IMAPError.parsingError("Expected closing parenthesis for single part body structure")
        }

        return IMAPResponse.BodyStructureData(
            type: type,
            subtype: subtype,
            parameters: parameters,
            id: contentId,
            description: description,
            encoding: encoding,
            size: UInt32(size),
            lines: lines,
            md5: md5,
            disposition: disposition,
            language: language,
            location: location,
            extensions: extensions,
            parts: nil
        )
    }

    private func peekIsClosingParen(_ scanner: Scanner) -> Bool {
        let currentPos = scanner.currentIndex
        _ = scanner.scanCharacters(from: .whitespaces)
        let isClosing = scanner.scanString(")") != nil
        scanner.currentIndex = currentPos
        return isClosing
    }

    private func parseOptionalParameterList(_ scanner: Scanner) throws -> [String: String]? {
        guard !peekIsClosingParen(scanner) else { return nil }
        return try parseParameterList(scanner)
    }

    private func parseOptionalDisposition(_ scanner: Scanner) throws -> IMAPResponse.DispositionData? {
        guard !peekIsClosingParen(scanner) else { return nil }
        return try parseDisposition(scanner)
    }

    private func parseOptionalLanguage(_ scanner: Scanner) throws -> [String]? {
        guard !peekIsClosingParen(scanner) else { return nil }
        return try parseLanguage(scanner)
    }

    private func parseOptionalLocation(_ scanner: Scanner) throws -> String? {
        guard !peekIsClosingParen(scanner) else { return nil }
        return try parseNilOrQuotedString(scanner)
    }

    private func parseDisposition(_ scanner: Scanner) throws -> IMAPResponse.DispositionData? {
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
            throw IMAPError.parsingError("Expected opening parenthesis for disposition")
        }

        let type = try parseNString(scanner)
        let parameters = try parseParameterList(scanner)

        _ = scanner.scanCharacters(from: .whitespaces)
        guard scanner.scanString(")") != nil else {
            throw IMAPError.parsingError("Expected closing parenthesis for disposition")
        }

        return IMAPResponse.DispositionData(type: type, parameters: parameters)
    }

    private func parseLanguage(_ scanner: Scanner) throws -> [String]? {
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

        if scanner.scanString("(") != nil {
            var languages: [String] = []
            _ = scanner.scanCharacters(from: .whitespaces)

            while scanner.scanString(")") == nil {
                guard !scanner.isAtEnd else {
                    throw IMAPError.parsingError("Unclosed language list")
                }
                let language = try parseNString(scanner)
                languages.append(language)
                _ = scanner.scanCharacters(from: .whitespaces)
            }
            return languages
        }

        scanner.currentIndex = currentPos
        return [try parseNString(scanner)]
    }

    private func parseBodyExtensions(_ scanner: Scanner) throws -> [String]? {
        var extensions: [String] = []

        while !peekIsClosingParen(scanner) && !scanner.isAtEnd {
            let extensionValue = try parseBodyExtension(scanner)
            extensions.append(extensionValue)
            _ = scanner.scanCharacters(from: .whitespaces)
        }

        return extensions.isEmpty ? nil : extensions
    }

    private func parseBodyExtension(_ scanner: Scanner) throws -> String {
        _ = scanner.scanCharacters(from: .whitespaces)

        if let literal = try parseLiteralPlaceholder(scanner) {
            return literal
        }

        let currentPos = scanner.currentIndex
        if scanner.scanString("NIL") != nil {
            let nextPos = scanner.currentIndex
            if nextPos < scanner.string.endIndex {
                let nextChar = scanner.string[nextPos]
                if " ()\r\n".contains(nextChar) {
                    return "NIL"
                }
            } else {
                return "NIL"
            }
            scanner.currentIndex = currentPos
        }

        if scanner.scanString("(") != nil {
            var items: [String] = []
            _ = scanner.scanCharacters(from: .whitespaces)

            while scanner.scanString(")") == nil {
                guard !scanner.isAtEnd else {
                    throw IMAPError.parsingError("Unclosed body extension list")
                }
                let item = try parseBodyExtension(scanner)
                items.append(item)
                _ = scanner.scanCharacters(from: .whitespaces)
            }

            return "(" + items.joined(separator: " ") + ")"
        }

        if let number = scanner.scanUInt() {
            return String(number)
        }

        if scanner.scanString("\"") != nil {
            scanner.currentIndex = scanner.string.index(before: scanner.currentIndex)
            return try parseQuotedString(scanner)
        }

        if let atom = scanner.scanUpToCharacters(from: CharacterSet(charactersIn: " ()\"\r\n")) {
            return atom
        }

        throw IMAPError.parsingError("Expected body extension")
    }

    private func parseParameterList(_ scanner: Scanner) throws -> [String: String]? {
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
            throw IMAPError.parsingError("Expected opening parenthesis for parameter list")
        }

        var params = [String: String]()
        while scanner.scanString(")") == nil {
            guard !scanner.isAtEnd else {
                throw IMAPError.parsingError("Unclosed parameter list")
            }
            let key = try parseNString(scanner)
            let value = try parseNString(scanner)
            params[key.lowercased()] = value
            _ = scanner.scanCharacters(from: .whitespaces)
        }
        return params.isEmpty ? nil : params
    }
}
