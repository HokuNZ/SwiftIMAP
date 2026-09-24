import Foundation

/// A message's MIME structure as the server reports it in a `BODYSTRUCTURE` fetch, without
/// any part bodies. Enough to decide which parts to fetch before fetching any of them.
public struct BodyStructure: Sendable, Equatable {
    public let type: String
    public let subtype: String
    /// Content-Type parameters. Keys are lowercased; values are as the server sent them.
    public let parameters: [String: String]
    public let id: String?
    public let description: String?
    public let encoding: String
    /// The part's size in octets as it sits in the message, transfer encoding included.
    /// Zero for a multipart. See `estimatedDecodedSize`.
    public let size: UInt32
    /// The Content-Disposition type (`attachment`, `inline`), as the server sent it.
    public let disposition: String?
    /// Content-Disposition parameters. Keys are lowercased; values are as the server sent them.
    public let dispositionParameters: [String: String]
    public let parts: [BodyStructure]

    public init(
        type: String,
        subtype: String,
        parameters: [String: String] = [:],
        id: String? = nil,
        description: String? = nil,
        encoding: String,
        size: UInt32,
        disposition: String? = nil,
        dispositionParameters: [String: String] = [:],
        parts: [BodyStructure] = []
    ) {
        self.type = type
        self.subtype = subtype
        self.parameters = parameters
        self.id = id
        self.description = description
        self.encoding = encoding
        self.size = size
        self.disposition = disposition
        self.dispositionParameters = dispositionParameters
        self.parts = parts
    }

    init(_ data: IMAPResponse.BodyStructureData) {
        self.init(
            type: data.type,
            subtype: data.subtype,
            parameters: data.parameters ?? [:],
            id: data.id,
            description: data.description,
            encoding: data.encoding,
            size: data.size,
            disposition: data.disposition?.type,
            dispositionParameters: data.disposition?.parameters ?? [:],
            parts: (data.parts ?? []).map(BodyStructure.init)
        )
    }

    public var mimeType: String {
        "\(type)/\(subtype)".lowercased()
    }

    public var isMultipart: Bool {
        type.lowercased() == "multipart"
    }
}

// MARK: - Sections

extension BodyStructure {
    /// A leaf part and the part number that addresses it in `BODY[<number>]`.
    public struct Section: Sendable, Equatable {
        public let number: String
        public let part: BodyStructure

        public init(number: String, part: BodyStructure) {
            self.number = number
            self.part = part
        }
    }

    /// Every leaf part with its IMAP part number (RFC 3501 §6.4.5). A message that is not
    /// multipart has the single part `1`; multipart children number positionally from 1, and
    /// nested multiparts extend the parent's number (`2.1`). An attached `message/rfc822` is
    /// one leaf: its own parts are not listed.
    public var sections: [Section] {
        isMultipart ? Self.leaves(of: self, prefix: nil) : [Section(number: "1", part: self)]
    }

    private static func leaves(of node: BodyStructure, prefix: String?) -> [Section] {
        node.parts.enumerated().flatMap { index, child -> [Section] in
            let number = prefix.map { "\($0).\(index + 1)" } ?? "\(index + 1)"
            return child.isMultipart ? leaves(of: child, prefix: number) : [Section(number: number, part: child)]
        }
    }
}

// MARK: - Attachments

extension BodyStructure {
    /// The part's file name: the Content-Disposition `filename`, else the Content-Type `name`.
    /// Decodes RFC 2231 extended and continued values (`filename*=`, `filename*0*=`) and the
    /// RFC 2047 encoded words many clients use instead, although RFC 2047 forbids them there.
    public var filename: String? {
        Self.decodedParameter("filename", in: dispositionParameters)
            ?? Self.decodedParameter("name", in: parameters)
    }

    /// Whether the part is an attachment rather than message content. The same rules as
    /// `MIMEPart.isAttachment`, so a message's attachments are the same whether they are read
    /// from its structure or from its parsed body.
    public var isAttachment: Bool {
        guard !isMultipart else { return false }
        let disposition = disposition?.lowercased()
        let isInline = disposition?.contains("inline") ?? false
        let type = type.lowercased()

        if isInline && filename == nil { return false }
        if isInline, type == "image", id != nil { return false }
        if disposition?.contains("attachment") ?? false { return true }
        if type != "text" && filename != nil { return true }
        return ["application", "image", "video", "audio"].contains(type)
    }

    /// The part's size once its transfer encoding is removed, estimated from `size`. Exact for
    /// `7bit`, `8bit` and `binary`; `base64` assumes MIME's 76-character lines, where 78
    /// octets carry 57 bytes; `quoted-printable` is left as reported.
    public var estimatedDecodedSize: Int {
        encoding.lowercased() == "base64" ? Int(size) * 57 / 78 : Int(size)
    }

    static func decodedParameter(_ name: String, in parameters: [String: String]) -> String? {
        let value: String?
        if let extended = parameters["\(name)*"] {
            value = decodeRFC2231(segments: [(extended, true)])
        } else if parameters["\(name)*0"] != nil || parameters["\(name)*0*"] != nil {
            var segments: [(String, Bool)] = []
            var index = 0
            while true {
                if let encoded = parameters["\(name)*\(index)*"] {
                    segments.append((encoded, true))
                } else if let plain = parameters["\(name)*\(index)"] {
                    segments.append((plain, false))
                } else {
                    break
                }
                index += 1
            }
            value = decodeRFC2231(segments: segments)
        } else {
            value = parameters[name].map(RFC2047.decode)
        }
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// RFC 2231 §4: an extended value is `charset'language'percent-encoded`, where only the
    /// first segment of a continued value carries the charset and language.
    private static func decodeRFC2231(segments: [(value: String, isEncoded: Bool)]) -> String? {
        var charset: String?
        var bytes = Data()
        for (index, segment) in segments.enumerated() {
            var text = Substring(segment.value)
            if index == 0 && segment.isEncoded {
                let pieces = segment.value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if pieces.count == 3 {
                    charset = String(pieces[0])
                    text = pieces[2]
                }
            }
            if segment.isEncoded {
                bytes.append(percentDecoded(text))
            } else {
                bytes.append(Data(text.utf8))
            }
        }
        let encoding = charset.flatMap { MIMEPart.stringEncoding(forIANACharset: $0) } ?? .utf8
        return String(data: bytes, encoding: encoding) ?? String(data: bytes, encoding: .isoLatin1)
    }

    private static func percentDecoded(_ text: Substring) -> Data {
        var bytes = Data()
        var iterator = text.utf8.makeIterator()
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "%"), let high = iterator.next(), let low = iterator.next(),
               let value = UInt8(String(bytes: [high, low], encoding: .ascii) ?? "", radix: 16) {
                bytes.append(value)
            } else {
                bytes.append(byte)
            }
        }
        return bytes
    }
}

// MARK: - Assembly

extension BodyStructure {
    /// Rebuilds a MIME message from part bodies fetched by section, keeping this structure's
    /// multipart nesting. `sectionBodies` maps a part number to the part's body exactly as
    /// `BODY[<number>]` returned it, transfer encoding intact. Leaves missing from it are left
    /// out, as is any multipart left with no parts; nil when nothing remains.
    ///
    /// Part headers are rebuilt from the structure, not fetched: type and parameters,
    /// transfer encoding, Content-ID and disposition. Top-level message headers are not
    /// included. RFC 2231 extended parameters are dropped rather than re-encoded, so a
    /// rebuilt part keeps its charset but may lose a non-ASCII file name; read names from
    /// the structure instead.
    public func assembleMessage(sectionBodies: [String: Data]) -> Data? {
        let boundaryToken = UUID().uuidString
        guard let root = assemble(number: isMultipart ? nil : "1", bodies: sectionBodies, token: boundaryToken) else {
            return nil
        }
        var message = Data("MIME-Version: 1.0\r\n".utf8)
        message.append(root)
        return message
    }

    /// Headers, blank line and body for this node, or nil when none of its leaves has a body.
    private func assemble(number: String?, bodies: [String: Data], token: String) -> Data? {
        guard isMultipart else {
            guard let number, let body = bodies[number] else { return nil }
            var part = Data(partHeaders(boundary: nil).utf8)
            part.append(Data("\r\n".utf8))
            part.append(body)
            return part
        }

        let children: [Data] = parts.enumerated().compactMap { index, child in
            let childNumber = number.map { "\($0).\(index + 1)" } ?? "\(index + 1)"
            return child.assemble(number: childNumber, bodies: bodies, token: token)
        }
        guard !children.isEmpty else { return nil }

        let boundary = "=_SwiftIMAP_\(token)_\(number ?? "0")"
        var node = Data(partHeaders(boundary: boundary).utf8)
        node.append(Data("\r\n".utf8))
        for child in children {
            node.append(Data("--\(boundary)\r\n".utf8))
            node.append(child)
            node.append(Data("\r\n".utf8))
        }
        node.append(Data("--\(boundary)--\r\n".utf8))
        return node
    }

    /// A multipart gets `boundary` in place of the server's (whose delimiters are not in the
    /// rebuilt bytes) and no transfer encoding. Every value that came from the sender is
    /// reduced to what its header allows, so none can end the line or add a parameter.
    private func partHeaders(boundary: String?) -> String {
        let type = Self.token(type, fallback: "application")
        let subtype = Self.token(subtype, fallback: "octet-stream")
        var contentType = parameters
        var headers: String
        if let boundary {
            contentType["boundary"] = nil
            headers = "Content-Type: \(type)/\(subtype)\(Self.parameterList(contentType)); boundary=\"\(boundary)\"\r\n"
        } else {
            headers = "Content-Type: \(type)/\(subtype)\(Self.parameterList(contentType))\r\n"
            headers += "Content-Transfer-Encoding: \(Self.token(encoding, fallback: "7bit"))\r\n"
        }
        if let id {
            let printable = id.unicodeScalars.filter { $0.value > 0x20 && $0.value < 0x7F }
            headers += "Content-ID: \(String(String.UnicodeScalarView(printable)))\r\n"
        }
        if let disposition {
            let type = Self.token(disposition, fallback: "attachment").lowercased()
            headers += "Content-Disposition: \(type)\(Self.parameterList(dispositionParameters))\r\n"
        }
        return headers
    }

    /// RFC 2045 §5.1 token: printable ASCII other than space and `()<>@,;:\"/[]?=`.
    private static func token(_ value: String, fallback: String) -> String {
        let specials = Set("()<>@,;:\\\"/[]?=".unicodeScalars)
        let kept = value.unicodeScalars.filter { $0.value > 0x20 && $0.value < 0x7F && !specials.contains($0) }
        return kept.isEmpty ? fallback : String(String.UnicodeScalarView(kept)).lowercased()
    }

    /// `; key="value"` for each plain parameter, sorted so the output is stable. Extended
    /// (`*`) parameters are skipped: their values are not quoted strings.
    private static func parameterList(_ parameters: [String: String]) -> String {
        parameters
            .filter { !$0.key.contains("*") }
            .sorted { $0.key < $1.key }
            .map { key, value in
                let escaped = value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .filter { $0 != "\r" && $0 != "\n" }
                return "; \(key)=\"\(escaped)\""
            }
            .joined()
    }
}
