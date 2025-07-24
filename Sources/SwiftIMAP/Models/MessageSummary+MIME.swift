import Foundation
import MimeParser

extension MessageSummary {
    /// Parse MIME content from the given body data
    public func parseMimeContent(from bodyData: Data) throws -> ParsedMimeMessage? {
        // Convert Data to String for MimeParser
        guard let bodyString = String(data: bodyData, encoding: .utf8) else {
            throw IMAPError.parsingError("Failed to decode body data as UTF-8")
        }
        
        // Parse the MIME content
        let parser = MimeParser()
        let mime = try parser.parse(bodyString)
        
        return ParsedMimeMessage(from: mime)
    }
}

/// A parsed MIME message with convenient access to parts
public struct ParsedMimeMessage {
    public let headers: [String: String]
    public let contentType: String?
    public let charset: String?
    public let transferEncoding: String?
    public let parts: [MimePart]
    public let boundary: String?
    public let isMultipart: Bool
    
    init(from mime: Mime) {
        // Extract headers from other fields
        var headers: [String: String] = [:]
        for field in mime.header.other {
            headers[field.name.lowercased()] = field.body
        }
        self.headers = headers
        
        // Extract content type info
        if let contentType = mime.header.contentType {
            self.contentType = contentType.raw
            self.charset = contentType.charset
            self.boundary = contentType.parameters["boundary"]
            self.isMultipart = contentType.raw.lowercased().hasPrefix("multipart/")
        } else {
            self.contentType = nil
            self.charset = nil
            self.boundary = nil
            self.isMultipart = false
        }
        
        // Extract transfer encoding
        if let encoding = mime.header.contentTransferEncoding {
            switch encoding {
            case .sevenBit: self.transferEncoding = "7bit"
            case .eightBit: self.transferEncoding = "8bit"
            case .binary: self.transferEncoding = "binary"
            case .quotedPrintable: self.transferEncoding = "quoted-printable"
            case .base64: self.transferEncoding = "base64"
            case .other(let value): self.transferEncoding = value
            }
        } else {
            self.transferEncoding = nil
        }
        
        // Parse parts recursively
        self.parts = ParsedMimeMessage.extractParts(from: mime)
    }
    
    /// Recursively extract all parts from a MIME message
    private static func extractParts(from mime: Mime) -> [MimePart] {
        var allParts: [MimePart] = []
        
        switch mime.content {
        case .body(let body):
            // Single body part
            let parsed = ParsedMimeMessage(from: mime)
            let part = MimePart(
                body: body,
                headers: parsed.headers,
                contentType: parsed.contentType,
                charset: parsed.charset,
                transferEncoding: parsed.transferEncoding,
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
    public func parts(withContentType contentType: String) -> [MimePart] {
        parts.filter { part in
            part.contentType?.lowercased().hasPrefix(contentType.lowercased()) ?? false
        }
    }
    
    /// Get the first part matching a content type
    public func firstPart(withContentType contentType: String) -> MimePart? {
        parts.first { part in
            part.contentType?.lowercased().hasPrefix(contentType.lowercased()) ?? false
        }
    }
    
    /// Get all text parts (both plain and HTML)
    public var textParts: [MimePart] {
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
    public var attachments: [MimePart] {
        parts.filter { $0.isAttachment }
    }
    
    /// Get all inline parts (e.g., embedded images)
    public var inlineParts: [MimePart] {
        parts.filter { $0.isInline }
    }
    
    /// Get all parts grouped by content type
    public var partsByType: [String: [MimePart]] {
        var grouped: [String: [MimePart]] = [:]
        for part in parts {
            if let mimeType = part.mimeType {
                grouped[mimeType, default: []].append(part)
            }
        }
        return grouped
    }
}

/// A single MIME part
public struct MimePart {
    public let body: MimeBody
    public let headers: [String: String]
    public let contentType: String?
    public let charset: String?
    public let transferEncoding: String?
    public let contentDisposition: String?
    public let contentID: String?
    private let mime: Mime?
    
    init(body: MimeBody, headers: [String: String], contentType: String? = nil, charset: String? = nil, transferEncoding: String? = nil, mime: Mime? = nil) {
        self.body = body
        self.headers = headers
        self.contentType = contentType ?? headers["content-type"]
        self.charset = charset
        self.transferEncoding = transferEncoding ?? headers["content-transfer-encoding"]
        self.contentDisposition = headers["content-disposition"]
        self.contentID = headers["content-id"]
        self.mime = mime
    }
    
    /// Get decoded text content
    public var decodedText: String? {
        do {
            let decodedData = try body.decodedContentData()
            return String(data: decodedData, encoding: encoding)
        } catch {
            // Fallback to raw content
            return body.raw
        }
    }
    
    /// Get decoded data content (for attachments)
    public var decodedData: Data? {
        try? body.decodedContentData()
    }
    
    /// Check if this part is an attachment
    public var isAttachment: Bool {
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
}

// Helper extension to extract body from MimeContent
private extension MimeContent {
    func extractBody() -> MimeBody {
        switch self {
        case .body(let body):
            return body
        case .mixed(let mimes), .alternative(let mimes):
            // Return the first body found
            return mimes.first?.content.extractBody() ?? MimeBody("")
        }
    }
}