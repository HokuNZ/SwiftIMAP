import Foundation

public enum IMAPResponse: Sendable, Equatable {
    case tagged(tag: String, status: ResponseStatus)
    case untagged(UntaggedResponse)
    case continuation(String)
    
    public enum ResponseStatus: Sendable, Equatable {
        case ok(ResponseCode?, String?)
        case no(ResponseCode?, String?)
        case bad(ResponseCode?, String?)
        case preauth(ResponseCode?, String?)
        case bye(ResponseCode?, String?)
    }
    
    public enum UntaggedResponse: Sendable, Equatable {
        case status(ResponseStatus)
        case capability([String])
        case list(ListResponse)
        case lsub(ListResponse)
        case search([UInt32])
        case flags([String])
        case exists(UInt32)
        case recent(UInt32)
        case expunge(UInt32)
        case fetch(UInt32, [FetchAttribute])
        case statusResponse(String, MailboxStatus)
    }
    
    public enum ResponseCode: Sendable, Equatable {
        case alert
        case badCharset([String]?)
        case capability([String])
        case parse
        case permanentFlags([String])
        case readOnly
        case readWrite
        case tryCreate
        case uidNext(UInt32)
        case uidValidity(UInt32)
        case unseen(UInt32)
        case other(String, String?)
    }
    
    public struct ListResponse: Sendable, Equatable {
        public let attributes: [String]
        public let delimiter: String?
        public let name: String
        public let rawName: Data?
        
        public init(attributes: [String], delimiter: String?, name: String, rawName: Data? = nil) {
            self.attributes = attributes
            self.delimiter = delimiter
            self.name = name
            self.rawName = rawName
        }
    }
    
    public enum FetchAttribute: Sendable, Equatable {
        case uid(UInt32)
        case flags([String])
        case internalDate(Date)
        case rfc822Size(UInt32)
        case envelope(EnvelopeData)
        case bodyStructure(BodyStructureData)
        case body(section: String?, origin: UInt32?, data: Data?)
        case bodyPeek(section: String?, origin: UInt32?, data: Data?)
        case header(Data)
        case headerFields(fields: [String], data: Data)
        case headerFieldsNot(fields: [String], data: Data)
        case text(Data)
    }
    
    public struct EnvelopeData: Sendable, Equatable {
        public let date: String?
        public let subject: String?
        public let from: [AddressData]?
        public let sender: [AddressData]?
        public let replyTo: [AddressData]?
        public let to: [AddressData]?
        public let cc: [AddressData]?
        public let bcc: [AddressData]?
        public let inReplyTo: String?
        public let messageID: String?
        public let rawDate: Data?
        public let rawSubject: Data?
        public let rawInReplyTo: Data?
        public let rawMessageID: Data?
    }
    
    public struct AddressData: Sendable, Equatable {
        public let name: String?
        public let adl: String?
        public let mailbox: String?
        public let host: String?
        public let rawName: Data?
        public let rawAdl: Data?
        public let rawMailbox: Data?
        public let rawHost: Data?
    }
    
    public struct BodyStructureData: Sendable, Equatable {
        public let type: String
        public let subtype: String
        public let parameters: [String: String]?
        public let id: String?
        public let description: String?
        public let encoding: String
        public let size: UInt32
        public let lines: UInt32?
        public let md5: String?
        public let disposition: DispositionData?
        public let language: [String]?
        public let location: String?
        public let extensions: [String]?
        public let parts: [BodyStructureData]?
    }
    
    public struct DispositionData: Sendable, Equatable {
        public let type: String
        public let parameters: [String: String]?
    }
}
