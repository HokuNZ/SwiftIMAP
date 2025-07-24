import Foundation

/// A parser specifically for handling IMAP literals in responses
struct IMAPLiteralParser {
    /// Check if a string contains a literal marker and extract its size
    static func findLiteral(in string: String) -> (range: Range<String.Index>, size: Int)? {
        // Look for {digits} pattern
        guard let match = string.range(of: #"\{(\d+)\}"#, options: .regularExpression) else {
            return nil
        }
        
        // Extract the size
        let sizeStr = String(string[match]).dropFirst().dropLast()
        guard let size = Int(sizeStr) else {
            return nil
        }
        
        return (match, size)
    }
    
    /// Parse a fetch response that may contain literals
    static func parseFetchResponse(line: String, buffer: inout Data) throws -> (attributes: [IMAPResponse.FetchAttribute], consumed: Int)? {
        // Check if this line contains a literal
        guard let literal = findLiteral(in: line) else {
            // No literal, can be parsed normally
            return nil
        }
        
        // We need at least 'size' bytes in the buffer after the CRLF
        let literalSize = literal.size
        
        // The literal data starts after the CRLF that follows the literal marker
        // We need to check if we have enough data
        guard buffer.count >= literalSize else {
            // Not enough data yet
            return ([], 0)
        }
        
        // Extract the literal data
        let literalData = buffer.prefix(literalSize)
        
        // Parse the fetch response with the literal data
        var attributes: [IMAPResponse.FetchAttribute] = []
        
        // Parse the part before the literal
        let beforeLiteral = String(line[..<literal.range.lowerBound])
        
        // Determine what kind of attribute this is
        if beforeLiteral.uppercased().contains("BODY") {
            let isPeek = beforeLiteral.uppercased().contains("PEEK")
            
            // Extract section if present
            var section: String? = nil
            if let sectionStart = beforeLiteral.lastIndex(of: "["),
               let sectionEnd = beforeLiteral.lastIndex(of: "]"),
               sectionStart < sectionEnd {
                let sectionContent = String(beforeLiteral[beforeLiteral.index(after: sectionStart)..<sectionEnd])
                section = sectionContent.isEmpty ? nil : sectionContent
            }
            
            if isPeek {
                attributes.append(.bodyPeek(section: section, origin: nil, data: Data(literalData)))
            } else {
                attributes.append(.body(section: section, origin: nil, data: Data(literalData)))
            }
        }
        
        // After consuming the literal, we need to consume any remaining fetch attributes
        // This is complex because the response might continue after the literal
        
        return (attributes, literalSize)
    }
}