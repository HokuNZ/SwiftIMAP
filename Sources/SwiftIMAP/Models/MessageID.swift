import Foundation

/// A normalised RFC 5322 message identifier — the value behind `Message-ID`,
/// `In-Reply-To`, and each entry of `References`.
///
/// Servers and clients frame the same identifier inconsistently: with or
/// without the angle brackets, with stray whitespace, sometimes comma-separated
/// in `References`. `MessageID` canonicalises to the bare form on parse, so two
/// identifiers that denote the same message always compare equal — threading
/// (`a.messageID == b.inReplyTo`, `b.references.contains(a.messageID)`) is
/// correct by construction, with no bracket-stripping at the call site.
///
/// Use ``bracketed`` when writing an identifier into an outgoing header.
public struct MessageID: Hashable, Sendable {
    /// The identifier without angle brackets or surrounding whitespace,
    /// e.g. `"abc123@mail.example.com"`. This is the canonical identity used
    /// for equality and hashing.
    public let value: String

    /// Wrap an already-bare identifier value. No parsing is performed; pass the
    /// identity without angle brackets.
    public init(value: String) {
        self.value = value
    }

    /// Parse a single header token into a `MessageID`.
    ///
    /// Trims surrounding whitespace and removes one enclosing pair of angle
    /// brackets if present. Returns `nil` for an empty or whitespace-only token,
    /// so a malformed `References` list yields no spurious entries.
    public init?(parsing token: some StringProtocol) {
        var trimmed = Substring(token).trimmingCharacters(in: .whitespacesAndNewlines)[...]
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count >= 2 {
            trimmed = trimmed.dropFirst().dropLast()
        }
        guard !trimmed.isEmpty else { return nil }
        self.value = String(trimmed)
    }

    /// The identifier wrapped in angle brackets, e.g. `"<abc123@mail.example.com>"`,
    /// ready to write into a `Message-ID` / `In-Reply-To` / `References` header.
    public var bracketed: String {
        "<\(value)>"
    }

    /// Tokenise a raw `References` (or `In-Reply-To`) header value into
    /// identifiers, in order. Whitespace separates identifiers per RFC 5322
    /// §3.6.4; commas are also tolerated for legacy mailers that misuse them.
    /// Empty tokens are dropped.
    ///
    /// Exposed so callers working from raw header strings (e.g. a full-message
    /// fetch, not just an `ENVELOPE`) can normalise identically to the parsed
    /// model fields.
    public static func parseList(_ headerValue: some StringProtocol) -> [MessageID] {
        headerValue
            .split { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" || $0 == "," }
            .compactMap { MessageID(parsing: $0) }
    }
}

extension MessageID: CustomStringConvertible {
    /// The bare canonical value (no brackets), for logging.
    public var description: String { value }
}
