import Foundation

extension IMAPResponse {
    /// A description safe to write to logs and crash reports.
    ///
    /// A raw `"\(response)"` renders associated `Data` payloads in full, so a
    /// `FETCH` response would dump entire message bodies, headers, and decoded
    /// envelope fields (subjects, addresses) into logs at `.debug`/`.trace`. This
    /// replaces every content-bearing payload with a byte count. Non-`FETCH`
    /// responses carry only protocol metadata and server status text, so they
    /// render normally.
    var loggingDescription: String {
        guard case .untagged(.fetch(let number, let attributes)) = self else {
            return "\(self)"
        }
        let parts = attributes.map { $0.loggingDescription }
        return "untagged(fetch(\(number), [\(parts.joined(separator: ", "))]))"
    }
}

extension IMAPResponse.FetchAttribute {
    /// Per-attribute logging form: structural metadata is kept; message content
    /// (body/header/text `Data` and envelope fields) is reduced to a byte count or
    /// a redaction marker so it never reaches logs.
    var loggingDescription: String {
        func section(_ section: String?, _ origin: UInt32?) -> String {
            "section: \(section ?? "nil"), origin: \(origin.map(String.init) ?? "nil")"
        }
        switch self {
        case .uid(let value):
            return "uid(\(value))"
        case .flags(let flags):
            return "flags(\(flags))"
        case .internalDate(let date):
            return "internalDate(\(date))"
        case .rfc822Size(let size):
            return "rfc822Size(\(size))"
        case .envelope:
            return "envelope(<redacted>)"
        case .bodyStructure:
            return "bodyStructure(<redacted>)"
        case let .body(sec, origin, data):
            return "body(\(section(sec, origin)), <\(data?.count ?? 0) bytes>)"
        case let .bodyPeek(sec, origin, data):
            return "bodyPeek(\(section(sec, origin)), <\(data?.count ?? 0) bytes>)"
        case .header(let data):
            return "header(<\(data.count) bytes>)"
        case let .headerFields(fields, data):
            return "headerFields(\(fields), <\(data.count) bytes>)"
        case let .headerFieldsNot(fields, data):
            return "headerFieldsNot(\(fields), <\(data.count) bytes>)"
        case .text(let data):
            return "text(<\(data.count) bytes>)"
        }
    }
}
