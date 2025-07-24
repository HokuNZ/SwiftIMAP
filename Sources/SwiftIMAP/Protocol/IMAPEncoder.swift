import Foundation

public final class IMAPEncoder {
    public init() {}
    
    public func encode(_ command: IMAPCommand) throws -> Data {
        let commandString = try encodeCommand(command)
        guard let data = commandString.data(using: .utf8) else {
            throw IMAPError.protocolError("Failed to encode command as UTF-8")
        }
        return data
    }
    
    private func encodeCommand(_ command: IMAPCommand) throws -> String {
        var parts: [String] = [command.tag]
        
        switch command.command {
        case .capability:
            parts.append("CAPABILITY")
            
        case .noop:
            parts.append("NOOP")
            
        case .logout:
            parts.append("LOGOUT")
            
        case .starttls:
            parts.append("STARTTLS")
            
        case .authenticate(let mechanism, let initialResponse):
            parts.append("AUTHENTICATE")
            parts.append(mechanism)
            if let response = initialResponse {
                parts.append(response)
            }
            
        case .login(let username, let password):
            parts.append("LOGIN")
            parts.append(quote(username, force: true))
            parts.append(quote(password, force: true))
            
        case .select(let mailbox):
            parts.append("SELECT")
            parts.append(encodeMailboxName(mailbox))
            
        case .examine(let mailbox):
            parts.append("EXAMINE")
            parts.append(encodeMailboxName(mailbox))
            
        case .create(let mailbox):
            parts.append("CREATE")
            parts.append(encodeMailboxName(mailbox))
            
        case .delete(let mailbox):
            parts.append("DELETE")
            parts.append(encodeMailboxName(mailbox))
            
        case .rename(let from, let to):
            parts.append("RENAME")
            parts.append(encodeMailboxName(from))
            parts.append(encodeMailboxName(to))
            
        case .subscribe(let mailbox):
            parts.append("SUBSCRIBE")
            parts.append(encodeMailboxName(mailbox))
            
        case .unsubscribe(let mailbox):
            parts.append("UNSUBSCRIBE")
            parts.append(encodeMailboxName(mailbox))
            
        case .list(let reference, let pattern):
            parts.append("LIST")
            parts.append(quote(reference, force: true))
            parts.append(encodeListPattern(pattern))
            
        case .lsub(let reference, let pattern):
            parts.append("LSUB")
            parts.append(quote(reference))
            parts.append(encodeListPattern(pattern))
            
        case .status(let mailbox, let items):
            parts.append("STATUS")
            parts.append(encodeMailboxName(mailbox))
            parts.append("(" + items.map { $0.rawValue }.joined(separator: " ") + ")")
            
        case .append(let mailbox, let flags, let date, let data):
            parts.append("APPEND")
            parts.append(encodeMailboxName(mailbox))
            
            if let flags = flags, !flags.isEmpty {
                parts.append("(" + flags.joined(separator: " ") + ")")
            }
            
            if let date = date {
                parts.append(quote(formatInternalDate(date)))
            }
            
            parts.append("{\(data.count)}")
            
        case .check:
            parts.append("CHECK")
            
        case .close:
            parts.append("CLOSE")
            
        case .expunge:
            parts.append("EXPUNGE")
            
        case .search(let charset, let criteria):
            parts.append("SEARCH")
            if let charset = charset {
                parts.append("CHARSET")
                parts.append(charset)
            }
            parts.append(encodeSearchCriteria(criteria))
            
        case .fetch(let sequence, let items):
            parts.append("FETCH")
            parts.append(sequence.stringValue)
            parts.append(encodeFetchItems(items))
            
        case .store(let sequence, let flags, let silent):
            parts.append("STORE")
            parts.append(sequence.stringValue)
            parts.append(encodeStoreFlags(flags, silent: silent))
            
        case .copy(let sequence, let mailbox):
            parts.append("COPY")
            parts.append(sequence.stringValue)
            parts.append(encodeMailboxName(mailbox))
            
        case .move(let sequence, let mailbox):
            parts.append("MOVE")
            parts.append(sequence.stringValue)
            parts.append(encodeMailboxName(mailbox))
            
        case .uid(let uidCommand):
            parts.append("UID")
            parts.append(contentsOf: encodeUIDCommand(uidCommand))
            
        case .idle:
            parts.append("IDLE")
            
        case .done:
            return "DONE\r\n"
        }
        
        return parts.joined(separator: " ") + "\r\n"
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
    
    private func encodeMailboxName(_ name: String) -> String {
        let encoded = encodeModifiedUTF7(name)
        return quote(encoded, force: true)
    }
    
    private func encodeListPattern(_ pattern: String) -> String {
        if pattern == "*" || pattern == "%" || !needsQuoting(pattern) {
            return pattern
        }
        return quote(pattern)
    }
    
    private func encodeModifiedUTF7(_ input: String) -> String {
        var result = ""
        var utf16Buffer: [UInt16] = []
        var inBase64 = false
        
        for scalar in input.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7E && scalar.value != 0x26 {
                if inBase64 {
                    result += encodeBase64(utf16Buffer) + "-"
                    utf16Buffer.removeAll()
                    inBase64 = false
                }
                result.append(Character(scalar))
            } else if scalar.value == 0x26 {
                if inBase64 {
                    result += encodeBase64(utf16Buffer) + "-"
                    utf16Buffer.removeAll()
                    inBase64 = false
                }
                result += "&-"
            } else {
                if !inBase64 {
                    result += "&"
                    inBase64 = true
                }
                
                let utf16 = Array(scalar.utf16)
                utf16Buffer.append(contentsOf: utf16)
            }
        }
        
        if inBase64 {
            result += encodeBase64(utf16Buffer) + "-"
        }
        
        return result
    }
    
    private func encodeBase64(_ buffer: [UInt16]) -> String {
        var data = Data()
        for value in buffer {
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }
        
        var base64 = data.base64EncodedString()
        base64 = base64.replacingOccurrences(of: "/", with: ",")
        base64 = base64.replacingOccurrences(of: "=", with: "")
        return base64
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
    
    private func encodeUIDCommand(_ command: IMAPCommand.UIDCommand) -> [String] {
        switch command {
        case .copy(let sequence, let mailbox):
            return ["COPY", sequence.stringValue, encodeMailboxName(mailbox)]
        case .move(let sequence, let mailbox):
            return ["MOVE", sequence.stringValue, encodeMailboxName(mailbox)]
        case .fetch(let sequence, let items):
            return ["FETCH", sequence.stringValue, encodeFetchItems(items)]
        case .search(let charset, let criteria):
            var parts = ["SEARCH"]
            if let charset = charset {
                parts.append("CHARSET")
                parts.append(charset)
            }
            parts.append(encodeSearchCriteria(criteria))
            return parts
        case .store(let sequence, let flags, let silent):
            return ["STORE", sequence.stringValue, encodeStoreFlags(flags, silent: silent)]
        case .expunge(let sequence):
            return ["EXPUNGE", sequence.stringValue]
        }
    }
}