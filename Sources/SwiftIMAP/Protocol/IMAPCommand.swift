import Foundation

public struct IMAPCommand: Sendable {
    public let tag: String
    public let command: Command
    
    public init(tag: String, command: Command) {
        self.tag = tag
        self.command = command
    }
    
    public enum Command: Sendable {
        case capability
        case noop
        case logout
        case starttls
        case authenticate(mechanism: String, initialResponse: String?)
        case login(username: String, password: String)
        case select(mailbox: String)
        case examine(mailbox: String)
        case create(mailbox: String)
        case delete(mailbox: String)
        case rename(from: String, to: String)
        case subscribe(mailbox: String)
        case unsubscribe(mailbox: String)
        case list(reference: String, pattern: String)
        case lsub(reference: String, pattern: String)
        case status(mailbox: String, items: [StatusItem])
        case append(mailbox: String, flags: [String]?, date: Date?, data: Data)
        case check
        case close
        case expunge
        case search(charset: String?, criteria: SearchCriteria)
        case fetch(sequence: SequenceSet, items: [FetchItem])
        case store(sequence: SequenceSet, flags: StoreFlags, silent: Bool)
        case copy(sequence: SequenceSet, mailbox: String)
        case move(sequence: SequenceSet, mailbox: String)
        case uid(UIDCommand)
        case idle
        case done
    }
    
    public enum StatusItem: String, Sendable {
        case messages = "MESSAGES"
        case recent = "RECENT"
        case uidNext = "UIDNEXT"
        case uidValidity = "UIDVALIDITY"
        case unseen = "UNSEEN"
    }
    
    public enum FetchItem: Sendable {
        case all
        case fast
        case full
        case uid
        case flags
        case internalDate
        case rfc822Size
        case rfc822
        case rfc822Header
        case rfc822Text
        case envelope
        case body
        case bodyStructure
        case bodySection(section: String?, peek: Bool)
        case bodyHeaderFields(fields: [String], peek: Bool)
        case bodyHeaderFieldsNot(fields: [String], peek: Bool)
        case bodyText(peek: Bool)
    }
    
    public indirect enum SearchCriteria: Sendable {
        case all
        case answered
        case deleted
        case draft
        case flagged
        case new
        case old
        case recent
        case seen
        case unanswered
        case undeleted
        case undraft
        case unflagged
        case unseen
        case keyword(String)
        case unkeyword(String)
        case before(Date)
        case on(Date)
        case since(Date)
        case sentBefore(Date)
        case sentOn(Date)
        case sentSince(Date)
        case from(String)
        case to(String)
        case cc(String)
        case bcc(String)
        case subject(String)
        case body(String)
        case text(String)
        case header(field: String, value: String)
        case larger(UInt32)
        case smaller(UInt32)
        case uid(SequenceSet)
        case not(SearchCriteria)
        case or(SearchCriteria, SearchCriteria)
        case and([SearchCriteria])
        case sequence(SequenceSet)
    }
    
    public struct StoreFlags: Sendable {
        public enum Action: Sendable {
            case set
            case add
            case remove
        }
        
        public let action: Action
        public let flags: [String]
        
        public init(action: Action, flags: [String]) {
            self.action = action
            self.flags = flags
        }
        
        public init(action: Action, flags: [Flag]) {
            self.action = action
            self.flags = flags.map { $0.rawValue }
        }
    }
    
    public enum UIDCommand: Sendable {
        case copy(sequence: SequenceSet, mailbox: String)
        case move(sequence: SequenceSet, mailbox: String)
        case fetch(sequence: SequenceSet, items: [FetchItem])
        case search(charset: String?, criteria: SearchCriteria)
        case store(sequence: SequenceSet, flags: StoreFlags, silent: Bool)
        case expunge(sequence: SequenceSet)
    }
    
    public enum SequenceSet: Sendable {
        case single(UInt32)
        case last
        case range(from: UInt32, to: UInt32?)
        case rangeFromLast(to: UInt32)
        case list([SequenceSet])
        
        public var stringValue: String {
            switch self {
            case .single(let num):
                return "\(num)"
            case .last:
                return "*"
            case .range(let from, let to):
                if let to = to {
                    return "\(from):\(to)"
                } else {
                    return "\(from):*"
                }
            case .rangeFromLast(let to):
                return "*:\(to)"
            case .list(let items):
                return items.map { $0.stringValue }.joined(separator: ",")
            }
        }
        
        /// Helper method to create a SequenceSet from an array of UIDs
        public static func set(_ uids: [UInt32]) -> SequenceSet {
            guard !uids.isEmpty else {
                return .single(0) // This shouldn't happen in practice
            }
            
            if uids.count == 1 {
                return .single(uids[0])
            }
            
            // Sort UIDs and create comma-separated list
            let sorted = uids.sorted()
            return .list(sorted.map { .single($0) })
        }
    }
}
