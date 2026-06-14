import Foundation

extension Envelope {
    /// Build a typed `Envelope` from a raw RFC 2822 header dictionary.
    ///
    /// For consumers holding message headers rather than a live IMAP `ENVELOPE`
    /// (`.eml` importers, Maildir readers, webhook payloads, offline fixtures).
    /// Header names are matched case-insensitively. The recognised headers are
    /// `From`, `Sender`, `Reply-To`, `To`, `Cc`, `Bcc`, `Subject`, `Date`,
    /// `Message-ID`, and `In-Reply-To`; address lists are parsed into `Address`
    /// values, the subject is RFC 2047 decoded, and the date is parsed from the
    /// common RFC 2822 formats (see ``RFC2822/parseDate(_:)``). A missing or
    /// unparseable header yields an empty/`nil` field rather than an error.
    ///
    /// `References` is not part of `Envelope`; populate it yourself by passing
    /// the `References` header value (under whatever key your dict uses) to
    /// `MessageId.parseList(_:)`, or use ``MessageSummary/parse(rfc822:)`` which
    /// reads it for you.
    public init(parsingHeaders headers: [String: String]) {
        // Match header names case-insensitively (RFC 5322 §1.2.2 field names are
        // case-insensitive, and a raw dict may key them however the source did).
        let byLowerName = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        func value(_ name: String) -> String? { byLowerName[name.lowercased()] }

        self.init(
            date: value("Date").flatMap(RFC2822.parseDate),
            subject: value("Subject").map(RFC2047.decode),
            from: RFC2822.parseAddressList(value("From")),
            sender: RFC2822.parseAddressList(value("Sender")),
            replyTo: RFC2822.parseAddressList(value("Reply-To")),
            to: RFC2822.parseAddressList(value("To")),
            cc: RFC2822.parseAddressList(value("Cc")),
            bcc: RFC2822.parseAddressList(value("Bcc")),
            inReplyTo: value("In-Reply-To").flatMap(MessageId.init(parsing:)),
            messageId: value("Message-ID").flatMap(MessageId.init(parsing:))
        )
    }
}

/// Internal RFC 2822 header-value parsing for the raw-bytes path
/// (``Envelope/init(parsingHeaders:)`` / ``MessageSummary/parse(rfc822:)``).
enum RFC2822 {
    /// Parse the RFC 5322 header block of a raw message into a `[name: value]`
    /// dictionary with lower-cased field names — independent of the MIME body.
    ///
    /// Tolerant of real-world archive input:
    /// - decodes as UTF-8 with an ISO-8859-1 fallback, so non-UTF-8 bytes (almost
    ///   always in the body) do not defeat header parsing;
    /// - strips a leading mbox `From ` envelope line (RFC 4155), which archive
    ///   converters emit and which is not an RFC 5322 header;
    /// - unfolds folded header lines (RFC 5322 §2.2.3);
    /// - keeps the first occurrence of a repeated field name.
    static func parseHeaderFields(from data: Data) -> [String: String] {
        // Headers are 7-bit per RFC 5322, but real messages carry ISO-8859-1 (or
        // RFC 2047 encoded-words). Latin-1 maps every byte losslessly, so it is a
        // safe fallback when the bytes are not valid UTF-8.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        var normalised = text.replacingOccurrences(of: "\r\n", with: "\n")

        if normalised.hasPrefix("From ") {
            if let newline = normalised.firstIndex(of: "\n") {
                normalised = String(normalised[normalised.index(after: newline)...])
            } else {
                normalised = ""
            }
        }

        // The header block ends at the first blank line.
        let headerBlock = normalised.range(of: "\n\n").map { normalised[..<$0.lowerBound] }
            ?? normalised[...]

        var headers: [String: String] = [:]
        var logical = ""
        func commit(_ line: String) {
            guard let colon = line.firstIndex(of: ":") else { return }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, headers[name] == nil else { return }
            headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        for line in headerBlock.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t" {
                logical += " " + line.trimmingCharacters(in: .whitespaces)   // unfold
            } else {
                if !logical.isEmpty { commit(logical) }
                logical = String(line)
            }
        }
        if !logical.isEmpty { commit(logical) }
        return headers
    }

    /// RFC 2822 date formats, tried in order. Mirrors the set a real-world mail
    /// client must handle: with and without the leading weekday, and 24-hour
    /// and AM/PM clocks. `en_US_POSIX` keeps month/weekday/AM-PM parsing locale
    /// independent.
    static let dateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss ZZZZZ",
        "dd MMM yyyy HH:mm:ss ZZZZZ",
        "EEE, dd MMM yyyy hh:mm:ss a ZZZZZ",
        "dd MMM yyyy hh:mm:ss a ZZZZZ"
    ]

    /// Parse an RFC 2822 `Date` header value into a `Date`.
    ///
    /// Strips a trailing parenthesised timezone comment (`... -0400 (EDT)`) per
    /// RFC 2822 §3.3, then tries each format in ``dateFormats``. Returns `nil` if
    /// none match, leaving the caller to decide a fallback.
    static func parseDate(_ value: String) -> Date? {
        let cleaned = value
            .replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    /// Parse an RFC 2822 address-list header value (`From`, `To`, `Cc`, ...) into
    /// `Address` values. Display names are unquoted and RFC 2047 decoded.
    ///
    /// Splits on top-level commas only, so a quoted display name containing a
    /// comma (`"Doe, John" <j@x>`) or an address group stays intact. Entries
    /// without a parseable `local@domain` (e.g. a bare group label such as
    /// `Undisclosed recipients:`) are dropped. Group structure is flattened to
    /// its member addresses.
    static func parseAddressList(_ value: String?) -> [Address] {
        guard let value, !value.isEmpty else { return [] }
        return splitTopLevel(value).compactMap(parseAddress)
    }

    /// Parse a single address spec (`Display Name <local@domain>` or a bare
    /// `local@domain`) into an `Address`. Returns `nil` if there is no
    /// `local@domain` with non-empty local and domain parts.
    private static func parseAddress(_ spec: String) -> Address? {
        let trimmed = stripGroupSyntax(spec.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return nil }

        var name: String?
        let addrSpec: String
        if let open = trimmed.lastIndex(of: "<"),
           let close = trimmed[open...].firstIndex(of: ">") {
            addrSpec = String(trimmed[trimmed.index(after: open)..<close])
            let display = String(trimmed[..<open])
            name = cleanDisplayName(display)
        } else {
            addrSpec = trimmed
        }

        // Split on the last '@' so a quoted local part containing '@' keeps the
        // domain correct (the domain has no '@').
        guard let at = addrSpec.lastIndex(of: "@") else { return nil }
        let mailbox = String(addrSpec[..<at]).trimmingCharacters(in: .whitespacesAndNewlines)
        let host = String(addrSpec[addrSpec.index(after: at)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mailbox.isEmpty, !host.isEmpty else { return nil }

        return Address(name: name, mailbox: mailbox, host: host)
    }

    /// Strip surrounding double quotes and RFC 2047 decode a display name.
    /// A quoted name has its RFC 2822 quoted-pairs (`\"`, `\\`) unescaped.
    /// Returns `nil` for an empty result so `Address.name` stays absent rather
    /// than an empty string.
    private static func cleanDisplayName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
            name = unescapeQuotedPairs(String(name.dropFirst().dropLast()))
        }
        name = RFC2047.decode(name).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Drop an RFC 2822 address-group wrapper from a single token: a leading
    /// `Group Name:` label (top-level colon before any address token) and a
    /// trailing `;`. Group members are thereby flattened to bare addresses; a
    /// label-only token (`Undisclosed recipients:`) collapses to empty and is
    /// dropped by the caller.
    private static func stripGroupSyntax(_ token: String) -> String {
        var result = token.hasSuffix(";") ? String(token.dropLast()) : token

        // A group label ends at a top-level colon that precedes any address
        // token. Stop at the first `<` or `@` — past there we are inside an
        // address, where a colon is not a group delimiter.
        var inQuote = false
        var labelEnd: String.Index?
        var index = result.startIndex
        while index < result.endIndex {
            let character = result[index]
            if character == "\"" {
                inQuote.toggle()
            } else if !inQuote {
                if character == "<" || character == "@" { break }
                if character == ":" { labelEnd = index; break }
            }
            index = result.index(after: index)
        }
        if let labelEnd {
            result = String(result[result.index(after: labelEnd)...])
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve RFC 2822 quoted-pairs (`\x` -> `x`) inside an already-unwrapped
    /// quoted string, so an escaped quote or backslash in a display name reads
    /// literally.
    private static func unescapeQuotedPairs(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    /// Split an address list on commas that are at the top level: not inside a
    /// quoted string and not inside angle brackets. An escaped quote (`\"`)
    /// inside a quoted string does not end the quote. Empty pieces are dropped.
    private static func splitTopLevel(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false
        var angleDepth = 0

        for character in value {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inQuote:
                current.append(character)
                escaped = true
            case "\"":
                inQuote.toggle()
                current.append(character)
            case "<" where !inQuote:
                angleDepth += 1
                current.append(character)
            case ">" where !inQuote:
                angleDepth = max(0, angleDepth - 1)
                current.append(character)
            case "," where !inQuote && angleDepth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)

        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
