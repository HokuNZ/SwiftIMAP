import Foundation

/// Decodes RFC 2047 encoded-word headers (`=?charset?encoding?text?=`) found in
/// header fields like Subject and the address display-name component.
///
/// IMAP servers return envelope strings containing raw RFC 2047 source. Without
/// decoding, callers see `=?utf-8?b?...?=` literals instead of human-readable text.
/// This decoder runs at the envelope-parse boundary so consumers see the decoded
/// form on `Envelope.subject` and `Address.name`.
///
/// Behaviour:
/// - Both `B` (base64) and `Q` (quoted-printable with `_` meaning space) encodings.
/// - Whitespace separating two adjacent encoded-words is suppressed (RFC 2047 §6.2).
/// - Whitespace between an encoded-word and a literal token is preserved.
/// - Malformed or unsupported encoded-words are passed through verbatim — the caller
///   never loses information they could otherwise have shown raw.
public enum RFC2047 {

    public static func decode(_ input: String) -> String {
        var runs: [Run] = []
        var cursor = input.startIndex

        while cursor < input.endIndex {
            guard let startRange = input.range(of: "=?", range: cursor..<input.endIndex) else {
                runs.append(.literal(String(input[cursor..<input.endIndex])))
                break
            }
            if startRange.lowerBound > cursor {
                runs.append(.literal(String(input[cursor..<startRange.lowerBound])))
            }
            guard let endRange = input.range(of: "?=", range: startRange.upperBound..<input.endIndex) else {
                runs.append(.literal(String(input[startRange.lowerBound..<input.endIndex])))
                break
            }
            let encodedWord = input[startRange.upperBound..<endRange.lowerBound]
            let parts = encodedWord.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3,
               let decoded = decodeEncodedWord(charset: String(parts[0]),
                                               encoding: String(parts[1]),
                                               text: String(parts[2])) {
                runs.append(.decoded(decoded))
            } else {
                runs.append(.literal(String(input[startRange.lowerBound..<endRange.upperBound])))
            }
            cursor = endRange.upperBound
        }

        var output = ""
        for (index, run) in runs.enumerated() {
            switch run {
            case .literal(let text):
                if text.allSatisfy({ $0.isWhitespace }),
                   index > 0, index < runs.count - 1,
                   case .decoded = runs[index - 1],
                   case .decoded = runs[index + 1] {
                    continue
                }
                output += text
            case .decoded(let text):
                output += text
            }
        }
        return output
    }

    // MARK: - Internals

    private enum Run {
        case literal(String)
        case decoded(String)
    }

    private static func decodeEncodedWord(charset: String, encoding: String, text: String) -> String? {
        let bytes: Data?
        switch encoding.uppercased() {
        case "B":
            bytes = Data(base64Encoded: text)
        case "Q":
            bytes = decodeQuotedPrintable(text)
        default:
            return nil
        }
        guard let data = bytes else { return nil }
        return String(data: data, encoding: stringEncoding(for: charset))
    }

    /// RFC 2047 Q encoding: `_` is space, `=XX` is a hex byte, ASCII passes through.
    private static func decodeQuotedPrintable(_ text: String) -> Data? {
        var bytes: [UInt8] = []
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "_" {
                bytes.append(0x20)
            } else if scalar == "=" {
                guard let hi = iterator.next(),
                      let lo = iterator.next(),
                      let value = UInt8(String(hi) + String(lo), radix: 16) else {
                    return nil
                }
                bytes.append(value)
            } else {
                guard scalar.isASCII else { return nil }
                bytes.append(UInt8(scalar.value))
            }
        }
        return Data(bytes)
    }

    /// IANA charset name → Foundation encoding. Common names mapped directly; others
    /// resolved via CoreFoundation's IANA registry. Unknown charsets fall back to UTF-8
    /// so the caller still gets *something* readable for the common case where the
    /// payload happens to be UTF-8 anyway.
    private static func stringEncoding(for charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8", "utf8":         return .utf8
        case "us-ascii", "ascii":     return .ascii
        case "iso-8859-1", "latin1":  return .isoLatin1
        case "iso-8859-2", "latin2":  return .isoLatin2
        case "windows-1252", "cp1252": return .windowsCP1252
        case "windows-1250":          return .windowsCP1250
        case "windows-1251":          return .windowsCP1251
        case "windows-1253":          return .windowsCP1253
        case "windows-1254":          return .windowsCP1254
        case "utf-16":                return .utf16
        default:
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return .utf8 }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: nsEncoding)
        }
    }
}
