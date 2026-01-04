import Foundation

extension IMAPParser {
    func parseParenthesizedList(_ scanner: Scanner) throws -> [String] {
        guard scanner.scanString("(") != nil else {
            throw IMAPError.parsingError("Expected opening parenthesis")
        }

        var items: [String] = []

        while scanner.scanString(")") == nil {
            guard !scanner.isAtEnd else {
                throw IMAPError.parsingError("Unclosed parenthesis")
            }

            if let item = scanner.scanUpToCharacters(from: CharacterSet(charactersIn: " )")) {
                items.append(item)
            }

            _ = scanner.scanCharacters(from: .whitespaces)
        }

        return items
    }

    func parseQuotedString(_ scanner: Scanner) throws -> String {
        guard scanner.scanString("\"") != nil else {
            throw IMAPError.parsingError("Expected opening quote")
        }

        var result = ""

        while !scanner.isAtEnd {
            if scanner.scanString("\\") != nil {
                guard let escaped = scanner.scanCharacter() else {
                    throw IMAPError.parsingError("Invalid escape sequence")
                }
                result.append(escaped)
                continue
            }

            if scanner.scanString("\"") != nil {
                return result
            }

            if let text = scanner.scanUpToCharacters(from: CharacterSet(charactersIn: "\\\"")) {
                result.append(text)
            } else if let character = scanner.scanCharacter() {
                result.append(character)
            }
        }

        throw IMAPError.parsingError("Unclosed quoted string")
    }

    func parseLiteralPlaceholder(_ scanner: Scanner) throws -> String? {
        let currentPos = scanner.currentIndex
        if scanner.scanString("~LITERAL~") != nil {
            return try nextLiteralString()
        }
        scanner.currentIndex = currentPos
        return nil
    }

    func parseAString(_ scanner: Scanner) throws -> String {
        if let literal = try parseLiteralPlaceholder(scanner) {
            return literal
        }

        if scanner.scanString("\"") != nil {
            scanner.currentIndex = scanner.string.index(before: scanner.currentIndex)
            return try parseQuotedString(scanner)
        } else if let atom = scanner.scanUpToCharacters(from: .whitespaces) {
            return atom
        } else {
            throw IMAPError.parsingError("Expected atom or quoted string")
        }
    }
}

extension Scanner {
    func scanUInt32() -> UInt32? {
        let digits = CharacterSet.decimalDigits
        guard let numberStr = scanCharacters(from: digits) else {
            return nil
        }
        return UInt32(numberStr)
    }

    func scanInt() -> Int? {
        let digits = CharacterSet.decimalDigits
        guard let numberStr = scanCharacters(from: digits) else {
            return nil
        }
        return Int(numberStr)
    }

    func scanUInt() -> UInt? {
        let digits = CharacterSet.decimalDigits
        guard let numberStr = scanCharacters(from: digits) else {
            return nil
        }
        return UInt(numberStr)
    }
}
