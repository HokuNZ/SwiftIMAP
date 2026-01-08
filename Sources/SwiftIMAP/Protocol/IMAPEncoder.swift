import Foundation

struct IMAPEncodedCommand {
    let initialData: Data
    let continuationSegments: [Data]
}

public final class IMAPEncoder {
    public init() {}

    enum LiteralMode {
        case synchronizing
        case nonSynchronizing
    }
    
    public func encode(_ command: IMAPCommand) throws -> Data {
        let encoded = try encodeCommandSegments(command)
        guard encoded.continuationSegments.isEmpty else {
            throw IMAPError.protocolError("Command requires literal continuation data")
        }
        return encoded.initialData
    }

    func encodeCommandSegments(
        _ command: IMAPCommand,
        literalMode: LiteralMode = .synchronizing
    ) throws -> IMAPEncodedCommand {
        let parts = try encodeCommandParts(command, literalMode: literalMode)
        return encodeParts(parts)
    }

    private enum CommandPart {
        case text(String)
        case literal(Data, isNonSync: Bool)
    }

    private func encodeCommandParts(
        _ command: IMAPCommand,
        literalMode: LiteralMode
    ) throws -> [CommandPart] {
        if case .done = command.command {
            return [.text("DONE")]
        }

        var parts: [CommandPart] = [.text(command.tag)]
        appendCommandParts(&parts, command: command.command, literalMode: literalMode)
        return parts
    }

    private func appendCommandParts(
        _ parts: inout [CommandPart],
        command: IMAPCommand.Command,
        literalMode: LiteralMode
    ) {
        switch command {
        case .capability, .noop, .logout, .starttls, .check, .close, .expunge, .idle:
            parts.append(.text(simpleCommandName(for: command)))

        case .authenticate(let mechanism, let initialResponse):
            appendAuthenticateParts(&parts, mechanism: mechanism, initialResponse: initialResponse)

        case .login(let username, let password):
            appendLoginParts(&parts, username: username, password: password, literalMode: literalMode)

        case .select(let mailbox),
             .examine(let mailbox),
             .create(let mailbox),
             .delete(let mailbox),
             .subscribe(let mailbox),
             .unsubscribe(let mailbox):
            appendMailboxParts(&parts, command: command, mailbox: mailbox)

        case .rename(let from, let to):
            appendRenameParts(&parts, from: from, to: to)

        case .list(let reference, let pattern):
            appendListParts(&parts, reference: reference, pattern: pattern, literalMode: literalMode)

        case .lsub(let reference, let pattern):
            appendLsubParts(&parts, reference: reference, pattern: pattern, literalMode: literalMode)

        case .status(let mailbox, let items):
            appendStatusParts(&parts, mailbox: mailbox, items: items)

        case .append(let mailbox, let flags, let date, let data):
            appendAppendParts(&parts, mailbox: mailbox, flags: flags, date: date, data: data, literalMode: literalMode)

        case .search(let charset, let criteria):
            appendSearchParts(&parts, charset: charset, criteria: criteria, literalMode: literalMode)

        case .fetch(let sequence, let items):
            parts.append(.text("FETCH"))
            parts.append(.text(sequence.stringValue))
            parts.append(.text(encodeFetchItems(items)))

        case .store(let sequence, let flags, let silent):
            parts.append(.text("STORE"))
            parts.append(.text(sequence.stringValue))
            parts.append(.text(encodeStoreFlags(flags, silent: silent)))

        case .copy(let sequence, let mailbox),
             .move(let sequence, let mailbox):
            appendCopyMoveParts(&parts, command: command, sequence: sequence, mailbox: mailbox)

        case .uid(let uidCommand):
            parts.append(.text("UID"))
            parts.append(contentsOf: encodeUIDCommandParts(uidCommand, literalMode: literalMode))

        case .done:
            break
        }
    }

    private func simpleCommandName(for command: IMAPCommand.Command) -> String {
        switch command {
        case .capability: return "CAPABILITY"
        case .noop: return "NOOP"
        case .logout: return "LOGOUT"
        case .starttls: return "STARTTLS"
        case .check: return "CHECK"
        case .close: return "CLOSE"
        case .expunge: return "EXPUNGE"
        case .idle: return "IDLE"
        case .authenticate, .login, .select, .examine, .create, .delete,
             .rename, .subscribe, .unsubscribe, .list, .lsub, .status,
             .append, .search, .fetch, .store, .copy, .move, .uid, .done:
            return ""
        }
    }

    private func appendAuthenticateParts(
        _ parts: inout [CommandPart],
        mechanism: String,
        initialResponse: String?
    ) {
        parts.append(.text("AUTHENTICATE"))
        parts.append(.text(mechanism))
        if let response = initialResponse {
            parts.append(.text(response.isEmpty ? "=" : response))
        }
    }

    private func appendLoginParts(
        _ parts: inout [CommandPart],
        username: String,
        password: String,
        literalMode: LiteralMode
    ) {
        parts.append(.text("LOGIN"))
        parts.append(encodeAStringPart(username, forceQuote: true, literalMode: literalMode))
        parts.append(encodeAStringPart(password, forceQuote: true, literalMode: literalMode))
    }

    private func appendMailboxParts(
        _ parts: inout [CommandPart],
        command: IMAPCommand.Command,
        mailbox: String
    ) {
        let name: String
        switch command {
        case .select: name = "SELECT"
        case .examine: name = "EXAMINE"
        case .create: name = "CREATE"
        case .delete: name = "DELETE"
        case .subscribe: name = "SUBSCRIBE"
        case .unsubscribe: name = "UNSUBSCRIBE"
        default: return
        }
        parts.append(.text(name))
        parts.append(.text(encodeMailboxName(mailbox)))
    }

    private func appendRenameParts(
        _ parts: inout [CommandPart],
        from: String,
        to: String
    ) {
        parts.append(.text("RENAME"))
        parts.append(.text(encodeMailboxName(from)))
        parts.append(.text(encodeMailboxName(to)))
    }

    private func appendListParts(
        _ parts: inout [CommandPart],
        reference: String,
        pattern: String,
        literalMode: LiteralMode
    ) {
        parts.append(.text("LIST"))
        parts.append(encodeAStringPart(reference, forceQuote: true, literalMode: literalMode))
        parts.append(encodeListPatternPart(pattern, literalMode: literalMode))
    }

    private func appendLsubParts(
        _ parts: inout [CommandPart],
        reference: String,
        pattern: String,
        literalMode: LiteralMode
    ) {
        parts.append(.text("LSUB"))
        parts.append(encodeAStringPart(reference, forceQuote: false, literalMode: literalMode))
        parts.append(encodeListPatternPart(pattern, literalMode: literalMode))
    }

    private func appendStatusParts(
        _ parts: inout [CommandPart],
        mailbox: String,
        items: [IMAPCommand.StatusItem]
    ) {
        parts.append(.text("STATUS"))
        parts.append(.text(encodeMailboxName(mailbox)))
        parts.append(.text("(" + items.map { $0.rawValue }.joined(separator: " ") + ")"))
    }

    private func appendAppendParts(
        _ parts: inout [CommandPart],
        mailbox: String,
        flags: [String]?,
        date: Date?,
        data: Data,
        literalMode: LiteralMode
    ) {
        parts.append(.text("APPEND"))
        parts.append(.text(encodeMailboxName(mailbox)))

        if let flags = flags, !flags.isEmpty {
            parts.append(.text("(" + flags.joined(separator: " ") + ")"))
        }

        if let date = date {
            parts.append(.text(quote(formatInternalDate(date))))
        }

        parts.append(encodeLiteralPart(data, literalMode: literalMode))
    }

    private func appendSearchParts(
        _ parts: inout [CommandPart],
        charset: String?,
        criteria: IMAPCommand.SearchCriteria,
        literalMode: LiteralMode
    ) {
        parts.append(.text("SEARCH"))
        if let charset = charset {
            parts.append(.text("CHARSET"))
            parts.append(encodeAStringPart(charset, forceQuote: false, literalMode: literalMode))
        }
        appendSearchCriteriaParts(&parts, criteria: criteria, literalMode: literalMode, wrapIfNeeded: false)
    }

    private func appendSearchCriteriaParts(
        _ parts: inout [CommandPart],
        criteria: IMAPCommand.SearchCriteria,
        literalMode: LiteralMode,
        wrapIfNeeded: Bool
    ) {
        switch criteria {
        case .all:
            parts.append(.text("ALL"))
        case .answered:
            parts.append(.text("ANSWERED"))
        case .deleted:
            parts.append(.text("DELETED"))
        case .draft:
            parts.append(.text("DRAFT"))
        case .flagged:
            parts.append(.text("FLAGGED"))
        case .new:
            parts.append(.text("NEW"))
        case .old:
            parts.append(.text("OLD"))
        case .recent:
            parts.append(.text("RECENT"))
        case .seen:
            parts.append(.text("SEEN"))
        case .unanswered:
            parts.append(.text("UNANSWERED"))
        case .undeleted:
            parts.append(.text("UNDELETED"))
        case .undraft:
            parts.append(.text("UNDRAFT"))
        case .unflagged:
            parts.append(.text("UNFLAGGED"))
        case .unseen:
            parts.append(.text("UNSEEN"))
        case .keyword(let keyword):
            parts.append(.text("KEYWORD"))
            parts.append(.text(keyword))
        case .unkeyword(let keyword):
            parts.append(.text("UNKEYWORD"))
            parts.append(.text(keyword))
        case .before(let date):
            parts.append(.text("BEFORE"))
            parts.append(.text(formatSearchDate(date)))
        case .on(let date):
            parts.append(.text("ON"))
            parts.append(.text(formatSearchDate(date)))
        case .since(let date):
            parts.append(.text("SINCE"))
            parts.append(.text(formatSearchDate(date)))
        case .sentBefore(let date):
            parts.append(.text("SENTBEFORE"))
            parts.append(.text(formatSearchDate(date)))
        case .sentOn(let date):
            parts.append(.text("SENTON"))
            parts.append(.text(formatSearchDate(date)))
        case .sentSince(let date):
            parts.append(.text("SENTSINCE"))
            parts.append(.text(formatSearchDate(date)))
        case .from(let address):
            parts.append(.text("FROM"))
            parts.append(encodeAStringPart(address, forceQuote: false, literalMode: literalMode))
        case .to(let address):
            parts.append(.text("TO"))
            parts.append(encodeAStringPart(address, forceQuote: false, literalMode: literalMode))
        case .cc(let address):
            parts.append(.text("CC"))
            parts.append(encodeAStringPart(address, forceQuote: false, literalMode: literalMode))
        case .bcc(let address):
            parts.append(.text("BCC"))
            parts.append(encodeAStringPart(address, forceQuote: false, literalMode: literalMode))
        case .subject(let text):
            parts.append(.text("SUBJECT"))
            parts.append(encodeAStringPart(text, forceQuote: true, literalMode: literalMode))
        case .body(let text):
            parts.append(.text("BODY"))
            parts.append(encodeAStringPart(text, forceQuote: true, literalMode: literalMode))
        case .text(let text):
            parts.append(.text("TEXT"))
            parts.append(encodeAStringPart(text, forceQuote: true, literalMode: literalMode))
        case .header(let field, let value):
            parts.append(.text("HEADER"))
            parts.append(encodeAStringPart(field, forceQuote: false, literalMode: literalMode))
            parts.append(encodeAStringPart(value, forceQuote: false, literalMode: literalMode))
        case .larger(let size):
            parts.append(.text("LARGER"))
            parts.append(.text(String(size)))
        case .smaller(let size):
            parts.append(.text("SMALLER"))
            parts.append(.text(String(size)))
        case .uid(let sequence):
            parts.append(.text("UID"))
            parts.append(.text(sequence.stringValue))
        case .not(let nested):
            parts.append(.text("NOT"))
            appendSearchCriteriaParts(&parts, criteria: nested, literalMode: literalMode, wrapIfNeeded: true)
        case .or(let criteria1, let criteria2):
            parts.append(.text("OR"))
            appendSearchCriteriaParts(&parts, criteria: criteria1, literalMode: literalMode, wrapIfNeeded: true)
            appendSearchCriteriaParts(&parts, criteria: criteria2, literalMode: literalMode, wrapIfNeeded: true)
        case .and(let criteriaList):
            guard !criteriaList.isEmpty else { return }
            if wrapIfNeeded && criteriaList.count > 1 {
                parts.append(.text("("))
                for criteria in criteriaList {
                    appendSearchCriteriaParts(&parts, criteria: criteria, literalMode: literalMode, wrapIfNeeded: false)
                }
                parts.append(.text(")"))
            } else {
                for criteria in criteriaList {
                    appendSearchCriteriaParts(&parts, criteria: criteria, literalMode: literalMode, wrapIfNeeded: false)
                }
            }
        case .sequence(let set):
            parts.append(.text(set.stringValue))
        }
    }

    private func appendCopyMoveParts(
        _ parts: inout [CommandPart],
        command: IMAPCommand.Command,
        sequence: IMAPCommand.SequenceSet,
        mailbox: String
    ) {
        let name: String
        switch command {
        case .copy: name = "COPY"
        case .move: name = "MOVE"
        default: return
        }
        parts.append(.text(name))
        parts.append(.text(sequence.stringValue))
        parts.append(.text(encodeMailboxName(mailbox)))
    }

    private func encodeParts(_ parts: [CommandPart]) -> IMAPEncodedCommand {
        let crlf = Data([0x0D, 0x0A])
        var initialData = Data()
        var continuationSegments: [Data] = []
        var currentContinuation: Data?
        var hasLiteral = false
        var previousWasOpenParen = false

        for (index, part) in parts.enumerated() {
            var isOpenParen = false
            var isCloseParen = false
            if case .text(let text) = part {
                isOpenParen = text == "("
                isCloseParen = text == ")"
            }
            let prefix = index == 0 || previousWasOpenParen || isCloseParen ? "" : " "
            switch part {
            case .text(let text):
                if hasLiteral {
                    currentContinuation?.append(contentsOf: (prefix + text).utf8)
                } else {
                    initialData.append(contentsOf: (prefix + text).utf8)
                }

            case .literal(let data, let isNonSync):
                let marker = "\(prefix){\(data.count)\(isNonSync ? "+" : "")}"
                if isNonSync {
                    if hasLiteral {
                        if currentContinuation == nil {
                            currentContinuation = Data()
                        }
                        currentContinuation?.append(contentsOf: marker.utf8)
                        currentContinuation?.append(crlf)
                        currentContinuation?.append(data)
                    } else {
                        initialData.append(contentsOf: marker.utf8)
                        initialData.append(crlf)
                        initialData.append(data)
                    }
                } else {
                    if !hasLiteral {
                        initialData.append(contentsOf: marker.utf8)
                        initialData.append(crlf)
                        hasLiteral = true
                        currentContinuation = Data()
                        currentContinuation?.append(data)
                    } else {
                        if var continuation = currentContinuation {
                            continuation.append(contentsOf: marker.utf8)
                            continuation.append(crlf)
                            continuationSegments.append(continuation)
                        }
                        currentContinuation = Data()
                        currentContinuation?.append(data)
                    }
                }
            }

            previousWasOpenParen = isOpenParen
        }

        if hasLiteral {
            if var continuation = currentContinuation {
                continuation.append(crlf)
                continuationSegments.append(continuation)
            }
        } else {
            initialData.append(crlf)
        }

        return IMAPEncodedCommand(initialData: initialData, continuationSegments: continuationSegments)
    }

    private func encodeAStringPart(
        _ value: String,
        forceQuote: Bool,
        literalMode: LiteralMode
    ) -> CommandPart {
        if requiresLiteral(value) {
            return encodeLiteralPart(Data(value.utf8), literalMode: literalMode)
        }
        return .text(quote(value, force: forceQuote))
    }

    private func encodeListPatternPart(
        _ pattern: String,
        literalMode: LiteralMode
    ) -> CommandPart {
        if requiresLiteral(pattern) {
            return encodeLiteralPart(Data(pattern.utf8), literalMode: literalMode)
        }
        return .text(encodeListPattern(pattern))
    }

    private func encodeLiteralPart(_ data: Data, literalMode: LiteralMode) -> CommandPart {
        let isNonSync = literalMode == .nonSynchronizing
        return .literal(data, isNonSync: isNonSync)
    }

    func quote(_ string: String, force: Bool = false) -> String {
        if force || needsQuoting(string) {
            let escaped = string.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return string
    }
    
    private func needsQuoting(_ string: String) -> Bool {
        if string.isEmpty {
            return true
        }
        
        let atomSpecials = CharacterSet(charactersIn: "(){%*\"\\] @")
        return string.rangeOfCharacter(from: atomSpecials) != nil || string.contains("/")
    }

    private func requiresLiteral(_ string: String) -> Bool {
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x0D, 0x0A, 0x00:
                return true
            default:
                if scalar.value < 0x20 || scalar.value > 0x7E {
                    return true
                }
            }
        }
        return false
    }
    
    private func encodeMailboxName(_ name: String) -> String {
        let encoded = IMAPMailboxNameCodec.encode(name)
        return quote(encoded, force: true)
    }
    
    private func encodeListPattern(_ pattern: String) -> String {
        if pattern == "*" || pattern == "%" || !needsQuoting(pattern) {
            return pattern
        }
        return quote(pattern)
    }

    private func formatSearchDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MMM-yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return quote(formatter.string(from: date))
    }
    
    private func formatInternalDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
    
    private func encodeFetchItems(_ items: [IMAPCommand.FetchItem]) -> String {
        if items.count == 1 {
            return encodeFetchItem(items[0])
        }
        
        let encoded = items.map { encodeFetchItem($0) }
        return "(" + encoded.joined(separator: " ") + ")"
    }
    
    private func encodeFetchItem(_ item: IMAPCommand.FetchItem) -> String {
        switch item {
        case .all:
            return "ALL"
        case .fast:
            return "FAST"
        case .full:
            return "FULL"
        case .uid:
            return "UID"
        case .flags:
            return "FLAGS"
        case .internalDate:
            return "INTERNALDATE"
        case .rfc822Size:
            return "RFC822.SIZE"
        case .rfc822:
            return "RFC822"
        case .rfc822Header:
            return "RFC822.HEADER"
        case .rfc822Text:
            return "RFC822.TEXT"
        case .envelope:
            return "ENVELOPE"
        case .body:
            return "BODY"
        case .bodyStructure:
            return "BODYSTRUCTURE"
        case .bodySection(let section, let peek):
            var result = peek ? "BODY.PEEK[" : "BODY["
            if let section = section {
                result += section
            }
            result += "]"
            return result
        case .bodyHeaderFields(let fields, let peek):
            let prefix = peek ? "BODY.PEEK[HEADER.FIELDS" : "BODY[HEADER.FIELDS"
            return "\(prefix) (\(fields.joined(separator: " ")))]"
        case .bodyHeaderFieldsNot(let fields, let peek):
            let prefix = peek ? "BODY.PEEK[HEADER.FIELDS.NOT" : "BODY[HEADER.FIELDS.NOT"
            return "\(prefix) (\(fields.joined(separator: " ")))]"
        case .bodyText(let peek):
            return peek ? "BODY.PEEK[TEXT]" : "BODY[TEXT]"
        }
    }
    
    private func encodeStoreFlags(_ flags: IMAPCommand.StoreFlags, silent: Bool) -> String {
        let action: String
        switch flags.action {
        case .set:
            action = "FLAGS"
        case .add:
            action = "+FLAGS"
        case .remove:
            action = "-FLAGS"
        }
        
        let suffix = silent ? ".SILENT" : ""
        let flagList = "(" + flags.flags.joined(separator: " ") + ")"
        
        return action + suffix + " " + flagList
    }
    
    private func encodeUIDCommandParts(
        _ command: IMAPCommand.UIDCommand,
        literalMode: LiteralMode
    ) -> [CommandPart] {
        switch command {
        case .copy(let sequence, let mailbox):
            return [.text("COPY"), .text(sequence.stringValue), .text(encodeMailboxName(mailbox))]
        case .move(let sequence, let mailbox):
            return [.text("MOVE"), .text(sequence.stringValue), .text(encodeMailboxName(mailbox))]
        case .fetch(let sequence, let items):
            return [.text("FETCH"), .text(sequence.stringValue), .text(encodeFetchItems(items))]
        case .search(let charset, let criteria):
            var parts: [CommandPart] = [.text("SEARCH")]
            if let charset = charset {
                parts.append(.text("CHARSET"))
                parts.append(encodeAStringPart(charset, forceQuote: false, literalMode: literalMode))
            }
            appendSearchCriteriaParts(&parts, criteria: criteria, literalMode: literalMode, wrapIfNeeded: false)
            return parts
        case .store(let sequence, let flags, let silent):
            return [.text("STORE"), .text(sequence.stringValue), .text(encodeStoreFlags(flags, silent: silent))]
        case .expunge(let sequence):
            return [.text("EXPUNGE"), .text(sequence.stringValue)]
        }
    }
}
