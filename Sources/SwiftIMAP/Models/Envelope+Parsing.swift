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
    /// `References` is not part of `Envelope`; read it from the header dict with
    /// `MessageId.parseList(headers["References"] ?? "")`, or use
    /// ``MessageSummary/parse(rfc822:)`` which populates it.
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
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// Returns `nil` for an empty result so `Address.name` stays absent rather
    /// than an empty string.
    private static func cleanDisplayName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
            name = String(name.dropFirst().dropLast())
        }
        name = RFC2047.decode(name).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Split an address list on commas that are at the top level: not inside a
    /// quoted string and not inside angle brackets. Empty pieces are dropped.
    private static func splitTopLevel(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote = false
        var angleDepth = 0

        for character in value {
            switch character {
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
