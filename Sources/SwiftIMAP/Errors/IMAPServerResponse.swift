import Foundation

/// A structured representation of a server's tagged completion (or `BYE`) when it
/// rejects a command. Captures the status, response code, and human text that the
/// server sent, plus the argument-free name of the command that was rejected.
///
/// Surfaced via ``IMAPError/commandFailed(_:)`` so callers can distinguish causes
/// (missing mailbox vs. over quota vs. server-side rule) and log a faithful
/// server response line without re-parsing.
public struct IMAPServerResponse: Sendable, Equatable {
    /// The completion status the server returned.
    ///
    /// `no`/`bad` are tagged command completions and only ever appear via
    /// ``IMAPError/commandFailed(_:)``. `bye` is an untagged connection-termination
    /// status and only ever appears via ``IMAPError/connectionClosed(_:)``. The two
    /// never cross over: a response surfaced through `commandFailed` is never `bye`,
    /// and one surfaced through `connectionClosed` is always `bye`.
    public enum Status: String, Sendable, Equatable {
        /// Operational failure (`NO`). The command was understood but could not be done.
        case no = "NO"
        /// Protocol/syntax error (`BAD`). Indicates a client-side bug; never retry.
        case bad = "BAD"
        /// Connection terminated by the server (`BYE`), e.g. shutdown or rejected connection.
        case bye = "BYE"
    }

    /// `NO`, `BAD`, or `BYE`.
    public let status: Status

    /// The bracketed response code (`[TRYCREATE]`, `[NONEXISTENT]`, `[OVERQUOTA]`, ...),
    /// if the server included one. This is the most machine-actionable field.
    public let code: IMAPResponse.ResponseCode?

    /// The human-readable text the server sent after any response code.
    public let text: String?

    /// The argument-free verb of the rejected command (e.g. `"UID MOVE"`, `"LOGIN"`).
    /// Never contains credentials, mailbox names, or message data.
    public let commandName: String

    public init(
        status: Status,
        code: IMAPResponse.ResponseCode?,
        text: String?,
        commandName: String
    ) {
        self.status = status
        self.code = code
        self.text = text
        self.commandName = commandName
    }

    /// A reconstructed server response line suitable for logging, e.g.
    /// `NO [TRYCREATE] Mailbox does not exist`. Contains only the status, response
    /// code, and the server's own text — never command arguments, credentials, or
    /// message data. Note that `text` is server-supplied and some servers echo
    /// mailbox names or usernames, so treat it as potentially user-specific before
    /// exporting to third parties.
    public var line: String {
        var parts = [status.rawValue]
        if let code {
            parts.append("[\(IMAPServerResponse.render(code))]")
        }
        if let text, !text.isEmpty {
            parts.append(text)
        }
        return parts.joined(separator: " ")
    }

    /// The response code's name in upper case (e.g. `"NONEXISTENT"`, `"OVERQUOTA"`),
    /// or `nil` if the server sent no response code. Lets callers branch on RFC 5530
    /// codes without re-deriving them from ``line``.
    ///
    /// - Note: this is the *raw* code token, so `[TRYCREATE]` returns `"TRYCREATE"`,
    ///   not `"NONEXISTENT"`. The two codes both mean "mailbox absent", so prefer the
    ///   semantic accessors (e.g. ``isMailboxNotFound``) over `codeName` comparisons
    ///   for condition checks; use `codeName` only when you need the literal token.
    public var codeName: String? {
        guard let code else { return nil }
        return IMAPServerResponse.render(code)
            .split(separator: " ", maxSplits: 1).first
            .map { String($0).uppercased() }
    }

    /// The target mailbox does not exist (`[NONEXISTENT]`) or must be created first
    /// (`[TRYCREATE]`) — typically a stale or renamed destination folder.
    public var isMailboxNotFound: Bool {
        if case .tryCreate = code { return true }
        return codeName == "NONEXISTENT"
    }

    /// The operation was refused because a quota was exceeded (`[OVERQUOTA]`).
    public var isOverQuota: Bool {
        codeName == "OVERQUOTA"
    }

    /// The user lacks permission for the operation (`[NOPERM]`).
    public var isPermissionDenied: Bool {
        codeName == "NOPERM"
    }

    /// Authentication or authorisation was rejected (`[AUTHENTICATIONFAILED]`,
    /// `[AUTHORIZATIONFAILED]`).
    public var isAuthenticationFailure: Bool {
        codeName == "AUTHENTICATIONFAILED" || codeName == "AUTHORIZATIONFAILED"
    }

    /// Render a parsed ``IMAPResponse/ResponseCode`` back to its on-the-wire form
    /// (without the surrounding brackets).
    static func render(_ code: IMAPResponse.ResponseCode) -> String {
        switch code {
        case .alert:
            return "ALERT"
        case .badCharset(let charsets):
            guard let charsets, !charsets.isEmpty else { return "BADCHARSET" }
            return "BADCHARSET (\(charsets.joined(separator: " ")))"
        case .capability(let caps):
            return (["CAPABILITY"] + caps).joined(separator: " ")
        case .parse:
            return "PARSE"
        case .permanentFlags(let flags):
            return "PERMANENTFLAGS (\(flags.joined(separator: " ")))"
        case .readOnly:
            return "READ-ONLY"
        case .readWrite:
            return "READ-WRITE"
        case .tryCreate:
            return "TRYCREATE"
        case .uidNext(let value):
            return "UIDNEXT \(value)"
        case .uidValidity(let value):
            return "UIDVALIDITY \(value)"
        case .unseen(let value):
            return "UNSEEN \(value)"
        case .other(let name, let value):
            return value.map { "\(name) \($0)" } ?? name
        }
    }
}
