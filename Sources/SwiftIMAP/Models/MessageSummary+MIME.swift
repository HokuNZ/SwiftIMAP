import Foundation
import MimeParser

extension MessageSummary {
    /// Parse MIME content from raw RFC 822 body data.
    ///
    /// Reads no instance state, so callers with raw bytes but no populated
    /// `MessageSummary` (e.g. an `.eml` fixture harness) can parse without
    /// synthesising a stub instance.
    public static func parseMIMEContent(from bodyData: Data) throws -> ParsedMIMEMessage? {
        // Convert Data to String for MimeParser
        guard let bodyString = String(data: bodyData, encoding: .utf8) else {
            throw IMAPError.parsingError("Failed to decode body data as UTF-8")
        }

        // Parse the MIME content
        let parser = MimeParser()
        let mime = try parser.parse(bodyString)

        return ParsedMIMEMessage(from: mime)
    }

    /// Parse MIME content from the given body data.
    ///
    /// Convenience wrapper over the static `parseMIMEContent(from:)` for callers
    /// that already hold a `MessageSummary`. No instance state is used.
    public func parseMIMEContent(from bodyData: Data) throws -> ParsedMIMEMessage? {
        try MessageSummary.parseMIMEContent(from: bodyData)
    }

    /// Build a `MessageSummary` from a complete RFC 822 message.
    ///
    /// For consumers with raw message bytes rather than a live IMAP `FETCH`
    /// (`.eml` importers, Maildir readers, webhook payloads, offline fixtures):
    /// parses the headers into a typed `Envelope` (see
    /// ``Envelope/init(parsingHeaders:)``) and populates `references` from the
    /// `References` header.
    ///
    /// The `uid` and `sequenceNumber` are synthesised as `0` — there is no IMAP
    /// session to assign them. `internalDate` comes from the `Date` header, or
    /// the current time if it is missing or unparseable. `size` is the byte
    /// length of `data`.
    ///
    /// Treat a parsed summary as read-only metadata: its `uid` is a placeholder
    /// (`0` is not a valid IMAP UID), so do not pass it back into UID-based
    /// operations such as `fetchMessage(uid:in:)` or `storeFlags(uid:in:)`.
    ///
    /// Throws `IMAPError.parsingError` if the bytes are not valid UTF-8 or the
    /// MIME structure cannot be parsed.
    public static func parse(rfc822 data: Data) throws -> MessageSummary {
        // parseMIMEContent throws on bad input rather than returning nil; the
        // guard is defensive against the optional return type.
        guard let parsed = try parseMIMEContent(from: data) else {
            throw IMAPError.parsingError("Could not parse RFC822 message")
        }

        let envelope = Envelope(parsingHeaders: parsed.headers)
        // ParsedMIMEMessage stores header names lower-cased, so look up the
        // lower-cased key directly.
        let references = MessageId.parseList(parsed.headers["references"] ?? "")

        return MessageSummary(
            uid: 0,
            sequenceNumber: 0,
            internalDate: envelope.date ?? Date(),
            // size is informational; saturate rather than trap on a message
            // larger than UInt32.max (~4 GB).
            size: UInt32(clamping: data.count),
            envelope: envelope,
            references: references
        )
    }
}

/// A parsed MIME message with convenient access to parts
public struct ParsedMIMEMessage: Sendable, Equatable {
    public let headers: [String: String]
    public let contentType: String?
    public let charset: String?
    public let transferEncoding: String?
    public let parts: [MIMEPart]
    public let boundary: String?
    public let isMultipart: Bool

    private struct HeaderInfo {
        let headers: [String: String]
        let contentType: String?
        let charset: String?
        let transferEncoding: String?
        let boundary: String?
        let isMultipart: Bool
    }

    init(from mime: Mime) {
        let headerInfo = ParsedMIMEMessage.parseHeaderInfo(from: mime.header)
        self.headers = headerInfo.headers
        self.contentType = headerInfo.contentType
        self.charset = headerInfo.charset
        self.transferEncoding = headerInfo.transferEncoding
        self.boundary = headerInfo.boundary
        self.isMultipart = headerInfo.isMultipart
        self.parts = ParsedMIMEMessage.extractParts(from: mime)
    }

    private static func parseHeaderInfo(from header: MimeHeader) -> HeaderInfo {
        var headers: [String: String] = [:]
        for field in header.other {
            headers[field.name.lowercased()] = field.body
        }

        let contentType: String?
        let charset: String?
        let boundary: String?
        let isMultipart: Bool

        if let type = header.contentType {
            contentType = type.raw
            charset = type.charset
            boundary = type.parameters["boundary"]
            isMultipart = type.raw.lowercased().hasPrefix("multipart/")
        } else {
            contentType = nil
            charset = nil
            boundary = nil
            isMultipart = false
        }

        let transferEncoding: String?
        if let encoding = header.contentTransferEncoding {
            switch encoding {
            case .sevenBit: transferEncoding = "7bit"
            case .eightBit: transferEncoding = "8bit"
            case .binary: transferEncoding = "binary"
            case .quotedPrintable: transferEncoding = "quoted-printable"
            case .base64: transferEncoding = "base64"
            case .other(let value): transferEncoding = value
            }
        } else {
            transferEncoding = nil
        }

        return HeaderInfo(
            headers: headers,
            contentType: contentType,
            charset: charset,
            transferEncoding: transferEncoding,
            boundary: boundary,
            isMultipart: isMultipart
        )
    }
    
    /// Recursively extract all parts from a MIME message
    private static func extractParts(from mime: Mime) -> [MIMEPart] {
        var allParts: [MIMEPart] = []
        
        switch mime.content {
        case .body(let body):
            let headerInfo = ParsedMIMEMessage.parseHeaderInfo(from: mime.header)
            let part = MIMEPart(
                body: body,
                headers: headerInfo.headers,
                contentType: headerInfo.contentType,
                charset: headerInfo.charset,
                transferEncoding: headerInfo.transferEncoding,
                mime: mime
            )
            allParts.append(part)
            
        case .mixed(let mimes), .alternative(let mimes):
            // Multipart - recursively extract all parts
            for childMime in mimes {
                let childParts = extractParts(from: childMime)
                allParts.append(contentsOf: childParts)
            }
        }
        
        return allParts
    }
    
    /// Get all parts of a specific content type
    public func parts(withContentType contentType: String) -> [MIMEPart] {
        parts.filter { part in
            part.contentType?.lowercased().hasPrefix(contentType.lowercased()) ?? false
        }
    }
    
    /// Get the first part matching a content type
    public func firstPart(withContentType contentType: String) -> MIMEPart? {
        parts.first { part in
            part.contentType?.lowercased().hasPrefix(contentType.lowercased()) ?? false
        }
    }
    
    /// Get all text parts (both plain and HTML)
    public var textParts: [MIMEPart] {
        parts(withContentType: "text/")
    }
    
    /// Get the plain text content of the message
    public var plainTextContent: String? {
        // First, look for text/plain parts
        if let plainPart = parts.first(where: { $0.contentType?.hasPrefix("text/plain") ?? false }) {
            return plainPart.decodedText
        }
        
        // If no text/plain, look for any text part
        if let textPart = parts.first(where: { $0.contentType?.hasPrefix("text/") ?? false }) {
            return textPart.decodedText
        }
        
        // If single part message, return its content
        if parts.count == 1 {
            return parts[0].decodedText
        }
        
        return nil
    }
    
    /// Get the HTML content of the message
    public var htmlContent: String? {
        parts.first(where: { $0.contentType?.hasPrefix("text/html") ?? false })?.decodedText
    }
    
    /// Get all attachments
    public var attachments: [MIMEPart] {
        parts.filter { $0.isAttachment }
    }
    
    /// Get all inline parts (e.g., embedded images)
    public var inlineParts: [MIMEPart] {
        parts.filter { $0.isInline }
    }
    
    /// Get all parts grouped by content type
    public var partsByType: [String: [MIMEPart]] {
        var grouped: [String: [MIMEPart]] = [:]
        for part in parts {
            if let mimeType = part.mimeType {
                grouped[mimeType, default: []].append(part)
            }
        }
        return grouped
    }
}

/// A single MIME part.
///
/// Holds only decoded value types (the MimeParser wire objects are consumed at construction)
public struct MIMEPart: Sendable, Equatable {
    public let headers: [String: String]
    public let contentType: String?
    public let charset: String?
    public let transferEncoding: String?
    public let contentDisposition: String?
    public let contentID: String?
    public let decodedData: Data?
    private let rawBody: String
    private let dispositionFilename: String?
    private let contentTypeName: String?

    init(body: MimeBody, headers: [String: String], contentType: String? = nil, charset: String? = nil, transferEncoding: String? = nil, mime: Mime? = nil) {
        let headerDisposition = mime?.header.contentDisposition?.type
        let headerTransferEncoding = MIMEPart.transferEncodingString(from: mime?.header.contentTransferEncoding)

        self.headers = headers
        self.contentType = contentType ?? headers["content-type"]
        self.charset = charset
        self.transferEncoding = transferEncoding ?? headers["content-transfer-encoding"] ?? headerTransferEncoding
        self.contentDisposition = headers["content-disposition"] ?? headerDisposition
        self.contentID = headers["content-id"]
        let decoded = try? body.decodedContentData()
        self.decodedData = decoded
        self.rawBody = decoded == nil ? body.raw : ""
        self.dispositionFilename = mime?.header.contentDisposition?.filename
        self.contentTypeName = mime?.header.contentType?.name
    }

    /// Get decoded text content
    public var decodedText: String? {
        guard let decodedData else {
            // Could not decode the transfer encoding; fall back to raw content.
            return rawBody
        }
        return String(data: decodedData, encoding: encoding)
    }
    
    /// Check if this part is an attachment
    public var isAttachment: Bool {
        // Inline parts WITHOUT a filename are truly embedded (e.g., cid: referenced images)
        if isInline && filename == nil {
            return false
        }

        // Inline images with Content-ID are embedded via cid: references in HTML
        // These should not be treated as attachments even if they have a filename
        if isInline, let mimeType = mimeType?.lowercased(),
           mimeType.hasPrefix("image/"), contentID != nil {
            return false
        }

        // Check Content-Disposition
        if let disposition = contentDisposition?.lowercased() {
            if disposition.contains("attachment") {
                return true
            }
        }
        
        // Check if it's not a text type and has a filename
        if let contentType = contentType?.lowercased() {
            if !contentType.hasPrefix("text/") && filename != nil {
                return true
            }
            
            // Common attachment types
            let attachmentTypes = ["application/", "image/", "video/", "audio/"]
            for type in attachmentTypes {
                if contentType.hasPrefix(type) {
                    return true
                }
            }
        }
        
        return false
    }
    
    /// Check if this part is inline (embedded in the message)
    public var isInline: Bool {
        contentDisposition?.lowercased().contains("inline") ?? false
    }
    
    /// Get the MIME type without parameters
    public var mimeType: String? {
        guard let contentType = contentType else { return nil }
        if let semicolonIndex = contentType.firstIndex(of: ";") {
            return String(contentType[..<semicolonIndex]).trimmingCharacters(in: .whitespaces)
        }
        return contentType
    }
    
    /// Get the filename if this is an attachment
    public var filename: String? {
        if let filename = dispositionFilename {
            return filename
        }

        if let name = contentTypeName {
            return name
        }

        // Check Content-Disposition header
        if let disposition = headers["content-disposition"] {
            if let match = disposition.range(of: #"filename="([^"]+)""#, options: .regularExpression) {
                let filenameWithQuotes = String(disposition[match])
                return filenameWithQuotes
                    .replacingOccurrences(of: "filename=\"", with: "")
                    .replacingOccurrences(of: "\"", with: "")
            }
        }
        
        // Check Content-Type header
        if let contentType = headers["content-type"] {
            if let match = contentType.range(of: #"name="([^"]+)""#, options: .regularExpression) {
                let nameWithQuotes = String(contentType[match])
                return nameWithQuotes
                    .replacingOccurrences(of: "name=\"", with: "")
                    .replacingOccurrences(of: "\"", with: "")
            }
        }
        
        return nil
    }
    
    private var encoding: String.Encoding {
        guard let charset = charset?.lowercased() else {
            return .utf8
        }
        
        switch charset {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "latin1":
            return .isoLatin1
        case "us-ascii", "ascii":
            return .ascii
        case "utf-16":
            return .utf16
        case "windows-1252", "cp1252":
            return .windowsCP1252
        default:
            return .utf8
        }
    }

    private static func transferEncodingString(from encoding: ContentTransferEncoding?) -> String? {
        guard let encoding else { return nil }
        switch encoding {
        case .sevenBit: return "7bit"
        case .eightBit: return "8bit"
        case .binary: return "binary"
        case .quotedPrintable: return "quoted-printable"
        case .base64: return "base64"
        case .other(let value): return value
        }
    }
}
