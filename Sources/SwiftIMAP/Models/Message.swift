import Foundation

public typealias UID = UInt32
public typealias MessageSequenceNumber = UInt32

public struct MessageSummary: Sendable {
    public let uid: UID
    public let sequenceNumber: MessageSequenceNumber
    public let flags: Set<Flag>
    public let internalDate: Date
    public let size: UInt32
    public let envelope: Envelope?
    
    public init(
        uid: UID,
        sequenceNumber: MessageSequenceNumber,
        flags: Set<Flag> = [],
        internalDate: Date,
        size: UInt32,
        envelope: Envelope? = nil
    ) {
        self.uid = uid
        self.sequenceNumber = sequenceNumber
        self.flags = flags
        self.internalDate = internalDate
        self.size = size
        self.envelope = envelope
    }
}

public enum Flag: String, Hashable, Sendable {
    case seen = "\\Seen"
    case answered = "\\Answered"
    case flagged = "\\Flagged"
    case deleted = "\\Deleted"
    case draft = "\\Draft"
    case recent = "\\Recent"
}

public struct Envelope: Sendable {
    public let date: Date?
    public let subject: String?
    public let from: [Address]
    public let sender: [Address]
    public let replyTo: [Address]
    public let to: [Address]
    public let cc: [Address]
    public let bcc: [Address]
    public let inReplyTo: String?
    public let messageID: String?
    
    public init(
        date: Date? = nil,
        subject: String? = nil,
        from: [Address] = [],
        sender: [Address] = [],
        replyTo: [Address] = [],
        to: [Address] = [],
        cc: [Address] = [],
        bcc: [Address] = [],
        inReplyTo: String? = nil,
        messageID: String? = nil
    ) {
        self.date = date
        self.subject = subject
        self.from = from
        self.sender = sender
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.inReplyTo = inReplyTo
        self.messageID = messageID
    }
}

public struct Address: Sendable, Hashable {
    public let name: String?
    public let mailbox: String
    public let host: String
    
    public init(name: String? = nil, mailbox: String, host: String) {
        self.name = name
        self.mailbox = mailbox
        self.host = host
    }
    
    public var emailAddress: String {
        "\(mailbox)@\(host)"
    }
    
    public var displayName: String {
        if let name = name, !name.isEmpty {
            return "\(name) <\(emailAddress)>"
        }
        return emailAddress
    }
}

public struct BodyStructure: Sendable {
    public let type: String
    public let subtype: String
    public let parameters: [String: String]
    public let id: String?
    public let description: String?
    public let encoding: String
    public let size: UInt32
    public let parts: [BodyStructure]
    
    public init(
        type: String,
        subtype: String,
        parameters: [String: String] = [:],
        id: String? = nil,
        description: String? = nil,
        encoding: String,
        size: UInt32,
        parts: [BodyStructure] = []
    ) {
        self.type = type
        self.subtype = subtype
        self.parameters = parameters
        self.id = id
        self.description = description
        self.encoding = encoding
        self.size = size
        self.parts = parts
    }
    
    public var mimeType: String {
        "\(type)/\(subtype)".lowercased()
    }
    
    public var isMultipart: Bool {
        type.lowercased() == "multipart"
    }
}