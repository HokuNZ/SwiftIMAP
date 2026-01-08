import Foundation

public struct Mailbox: Hashable, Sendable {
    public let name: String
    public let attributes: Set<Attribute>
    public let delimiter: String?
    
    public init(name: String, attributes: Set<Attribute> = [], delimiter: String? = nil) {
        self.name = name
        self.attributes = attributes
        self.delimiter = delimiter
    }
    
    public enum Attribute: String, Hashable, Sendable {
        case noinferiors = "\\Noinferiors"
        case noselect = "\\Noselect"
        case marked = "\\Marked"
        case unmarked = "\\Unmarked"
        case hasNoChildren = "\\HasNoChildren"
        case hasChildren = "\\HasChildren"
        case sent = "\\Sent"
        case drafts = "\\Drafts"
        case trash = "\\Trash"
        case junk = "\\Junk"
        case all = "\\All"
        case archive = "\\Archive"
        case flagged = "\\Flagged"
        case important = "\\Important"
    }
    
    public var isSelectable: Bool {
        !attributes.contains(.noselect)
    }
}

public struct MailboxStatus: Sendable, Equatable {
    public enum Access: String, Sendable {
        case readOnly
        case readWrite
    }

    public let messages: UInt32
    public let recent: UInt32
    public let uidNext: UInt32
    public let uidValidity: UInt32
    public let unseen: UInt32
    public let flags: [String]?
    public let permanentFlags: [String]?
    public let access: Access?
    
    public init(
        messages: UInt32,
        recent: UInt32,
        uidNext: UInt32,
        uidValidity: UInt32,
        unseen: UInt32,
        flags: [String]? = nil,
        permanentFlags: [String]? = nil,
        access: Access? = nil
    ) {
        self.messages = messages
        self.recent = recent
        self.uidNext = uidNext
        self.uidValidity = uidValidity
        self.unseen = unseen
        self.flags = flags
        self.permanentFlags = permanentFlags
        self.access = access
    }
}
