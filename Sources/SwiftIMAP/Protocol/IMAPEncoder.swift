import Foundation

struct IMAPEncodedCommand {
    let initialData: Data
    let continuationSegments: [Data]
}

public final class IMAPEncoder {
    public init() {}
    
    public func encode(_ command: IMAPCommand) throws -> Data {
        let encoded = try encodeCommandSegments(command)
        guard encoded.continuationSegments.isEmpty else {
            throw IMAPError.protocolError("Command requires literal continuation data")
        }
        return encoded.initialData
    }

    func encodeCommandSegments(_ command: IMAPCommand) throws -> IMAPEncodedCommand {
        let parts = try encodeCommandParts(command)
        return encodeParts(parts)
    }

    private enum CommandPart {
        case text(String)
        case literal(Data)
    }

    private func encodeCommandParts(_ command: IMAPCommand) throws -> [CommandPart] {
        if case .done = command.command {
            return [.text("DONE")]
        }

        var parts: [CommandPart] = [.text(command.tag)]

        switch command.command {
        case .capability:
            parts.append(.text("CAPABILITY"))

        case .noop:
            parts.append(.text("NOOP"))

        case .logout:
            parts.append(.text("LOGOUT"))

        case .starttls:
            parts.append(.text("STARTTLS"))

        case .authenticate(let mechanism, let initialResponse):
            parts.append(.text("AUTHENTICATE"))
            parts.append(.text(mechanism))
            if let response = initialResponse {
                parts.append(.text(response))
            }

        case .login(let username, let password):
            parts.append(.text("LOGIN"))
            parts.append(encodeAStringPart(username, forceQuote: true))
            parts.append(encodeAStringPart(password, forceQuote: true))

        case .select(let mailbox):
            parts.append(.text("SELECT"))
            parts.append(.text(encodeMailboxName(mailbox)))

        case .examine(let mailbox):
            parts.append(.text("EXAMINE"))
            parts.append(.text(encodeMailboxName(mailbox)))

        case .create(let mailbox):
            parts.append(.text("CREATE"))
            parts.append(.text(encodeMailboxName(mailbox)))

        case .delete(let mailbox):
            parts.append(.text("DELETE"))
            parts.append(.text(encodeMailboxName(mailbox)))

        case .rename(let from, let to):
            parts.append(.text("RENAME"))
            parts.append(.text(encodeMailboxName(from)))
            parts.append(.text(encodeMailboxName(to)))

        case .subscribe(let mailbox):
            parts.append(.text("SUBSCRIBE"))
            parts.append(.text(encodeMailboxName(mailbox)))

        case .unsubscribe(let mailbox):
            parts.append(.text("UNSUBSCRIBE"))
            parts.append(.text(encodeMailboxName(mailbox)))

        case .list(let reference, let pattern):
            parts.append(.text("LIST"))
            parts.append(encodeAStringPart(reference, forceQuote: true))
            parts.append(encodeListPatternPart(pattern))

        case .lsub(let reference, let pattern):
            parts.append(.text("LSUB"))
            parts.append(encodeAStringPart(reference, forceQuote: false))
            parts.append(encodeListPatternPart(pattern))

        case .status(let mailbox, let items):
            parts.append(.text("STATUS"))
            parts.append(.text(encodeMailboxName(mailbox)))
            parts.append(.text("(" + items.map { $0.rawValue }.joined(separator: " ") + ")"))

        case .append(let mailbox, let flags, let date, let data):
            parts.append(.text("APPEND"))
            parts.append(.text(encodeMailboxName(mailbox)))

            if let flags = flags, !flags.isEmpty {
                parts.append(.text("(" + flags.joined(separator: " ") + ")"))
            }

            if let date = date {
                parts.append(.text(quote(formatInternalDate(date))))
            }

            parts.append(.literal(data))

        case .check:
            parts.append(.text("CHECK"))

        case .close:
            parts.append(.text("CLOSE"))

        case .expunge:
            parts.append(.text("EXPUNGE"))

        case .search(let charset, let criteria):
            parts.append(.text("SEARCH"))
            if let charset = charset {
                parts.append(.text("CHARSET"))
                parts.append(.text(charset))
            }
            parts.append(.text(encodeSearchCriteria(criteria)))

        case .fetch(let sequence, let items):
            parts.append(.text("FETCH"))
            parts.append(.text(sequence.stringValue))
            parts.append(.text(encodeFetchItems(items)))

        case .store(let sequence, let flags, let silent):
            parts.append(.text("STORE"))
            parts.append(.text(sequence.stringValue))
            parts.append(.text(encodeStoreFlags(flags, silent: silent)))

        case .copy(let sequence, let mailbox):
            parts.append(.text("COPY"))
            parts.append(.text(sequence.stringValue))
            parts.append(.text(encodeMailboxName(mailbox)))

        case .move(let sequence, let mailbox):
            parts.append(.text("MOVE"))
            parts.append(.text(sequence.stringValue))
            parts.append(.text(encodeMailboxName(mailbox)))

        case .uid(let uidCommand):
            parts.append(.text("UID"))
            parts.append(contentsOf: encodeUIDCommandParts(uidCommand))

        case .idle:
            parts.append(.text("IDLE"))

        case .done:
            break
        }

        return parts
    }

    private func encodeParts(_ parts: [CommandPart]) -> IMAPEncodedCommand {
        let crlf = Data([0x0D, 0x0A])
        var initialData = Data()
        var continuationSegments: [Data] = []
        var currentContinuation: Data?
        var hasLiteral = false

        for (index, part) in parts.enumerated() {
            let prefix = index == 0 ? "" : " "
            switch part {
            case .text(let text):
                if hasLiteral {
                    currentContinuation?.append(contentsOf: (prefix + text).utf8)
                } else {
                    initialData.append(contentsOf: (prefix + text).utf8)
                }

            case .literal(let data):
                let marker = "\(prefix){\(data.count)}"
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

    private func encodeAStringPart(_ value: String, forceQuote: Bool) -> CommandPart {
        if requiresLiteral(value) {
            return .literal(Data(value.utf8))
        }
        return .text(quote(value, force: forceQuote))
    }

    private func encodeListPatternPart(_ pattern: String) -> CommandPart {
        if requiresLiteral(pattern) {
            return .literal(Data(pattern.utf8))
        }
        return .text(encodeListPattern(pattern))
    }

    private func quote(_ string: String, force: Bool = false) -> String {
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
    
    private func encodeSearchCriteria(_ criteria: IMAPCommand.SearchCriteria) -> String {
        switch criteria {
        case .all:
            return "ALL"
        case .answered:
            return "ANSWERED"
        case .deleted:
            return "DELETED"
        case .draft:
            return "DRAFT"
        case .flagged:
            return "FLAGGED"
        case .new:
            return "NEW"
        case .old:
            return "OLD"
        case .recent:
            return "RECENT"
        case .seen:
            return "SEEN"
        case .unanswered:
            return "UNANSWERED"
        case .undeleted:
            return "UNDELETED"
        case .undraft:
            return "UNDRAFT"
        case .unflagged:
            return "UNFLAGGED"
        case .unseen:
            return "UNSEEN"
        case .keyword(let keyword):
            return "KEYWORD \(keyword)"
        case .unkeyword(let keyword):
            return "UNKEYWORD \(keyword)"
        case .before(let date):
            return "BEFORE \(formatSearchDate(date))"
        case .on(let date):
            return "ON \(formatSearchDate(date))"
        case .since(let date):
            return "SINCE \(formatSearchDate(date))"
        case .sentBefore(let date):
            return "SENTBEFORE \(formatSearchDate(date))"
        case .sentOn(let date):
            return "SENTON \(formatSearchDate(date))"
        case .sentSince(let date):
            return "SENTSINCE \(formatSearchDate(date))"
        case .from(let address):
            return "FROM \(quote(address))"
        case .to(let address):
            return "TO \(quote(address))"
        case .cc(let address):
            return "CC \(quote(address))"
        case .bcc(let address):
            return "BCC \(quote(address))"
        case .subject(let text):
            return "SUBJECT \(quote(text, force: true))"
        case .body(let text):
            return "BODY \(quote(text, force: true))"
        case .text(let text):
            return "TEXT \(quote(text, force: true))"
        case .header(let field, let value):
            return "HEADER \(quote(field)) \(quote(value))"
        case .larger(let size):
            return "LARGER \(size)"
        case .smaller(let size):
            return "SMALLER \(size)"
        case .uid(let sequence):
            return "UID \(sequence.stringValue)"
        case .not(let criteria):
            return "NOT \(encodeSearchCriteria(criteria))"
        case .or(let criteria1, let criteria2):
            return "OR \(encodeSearchCriteria(criteria1)) \(encodeSearchCriteria(criteria2))"
        case .and(let criteriaList):
            return criteriaList.map { encodeSearchCriteria($0) }.joined(separator: " ")
        case .sequence(let set):
            return set.stringValue
        }
    }
    
    private func formatSearchDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MMM-yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return quote(formatter.string(from: date))
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
    
    private func encodeUIDCommandParts(_ command: IMAPCommand.UIDCommand) -> [CommandPart] {
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
                parts.append(.text(charset))
            }
            parts.append(.text(encodeSearchCriteria(criteria)))
            return parts
        case .store(let sequence, let flags, let silent):
            return [.text("STORE"), .text(sequence.stringValue), .text(encodeStoreFlags(flags, silent: silent))]
        case .expunge(let sequence):
            return [.text("EXPUNGE"), .text(sequence.stringValue)]
        }
    }
}
