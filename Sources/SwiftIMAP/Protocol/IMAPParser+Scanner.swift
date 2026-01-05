import Foundation

extension IMAPParser {
    func parseParenthesizedList(_ scanner: Scanner) throws -> [String] {
        guard scanner.scanString("(") != nil else {
            throw IMAPError.parsingError("Expected opening parenthesis")
        }

        var items: [String] = []

        while true {
            _ = scanner.scanCharacters(from: .whitespaces)
            if scanner.scanString(")") != nil {
                return items
            }

            guard !scanner.isAtEnd else {
                throw IMAPError.parsingError("Unclosed parenthesis")
            }

            if scanner.scanString("(") != nil {
                let nested = try scanParenthesizedSubstring(scanner)
                items.append(nested)
                continue
            }

            if scanner.scanString("\"") != nil {
                scanner.currentIndex = scanner.string.index(before: scanner.currentIndex)
                let value = try parseQuotedString(scanner)
                items.append(value)
                continue
            }

            if let item = scanner.scanUpToCharacters(
                from: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ")"))
            ) {
                items.append(item)
                continue
            }

            _ = scanner.scanCharacter()
        }
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

    private func scanParenthesizedSubstring(_ scanner: Scanner) throws -> String {
        let string = scanner.string
        let startIndex = string.index(before: scanner.currentIndex)
        var depth = 1
        var index = scanner.currentIndex

        while index < string.endIndex {
            let character = string[index]

            if character == "\"" {
                index = string.index(after: index)
                while index < string.endIndex {
                    let inner = string[index]
                    if inner == "\\" {
                        index = string.index(after: index)
                        if index < string.endIndex {
                            index = string.index(after: index)
                        }
                        continue
                    }
                    if inner == "\"" {
                        index = string.index(after: index)
                        break
                    }
                    index = string.index(after: index)
                }
                continue
            }

            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    let endIndex = string.index(after: index)
                    scanner.currentIndex = endIndex
                    return String(string[startIndex..<endIndex])
                }
            }

            index = string.index(after: index)
        }

        throw IMAPError.parsingError("Unclosed parenthesis")
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
