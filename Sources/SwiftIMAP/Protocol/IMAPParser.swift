import Foundation

public final class IMAPParser {
    private var buffer: Data
    private var pendingLiteral: PendingLiteral?
    private var literalQueue: [Data] = []
    
    private struct PendingLiteral {
        let size: Int
        var collectedData: Data
        let partialLine: String
        var collectedLiterals: [Data] = []
    }
    
    public init() {
        self.buffer = Data()
    }
    
    public func append(_ data: Data) {
        buffer.append(data)
    }
    
    public func parseResponses() throws -> [IMAPResponse] {
        var responses: [IMAPResponse] = []
        
        // If we're collecting a literal, continue
        if var literal = pendingLiteral {
            let needed = literal.size - literal.collectedData.count
            if buffer.count >= needed {
                // Complete the literal
                literal.collectedData.append(buffer.prefix(needed))
                buffer.removeFirst(needed)
                
                
                // After literal data, the line continues until CRLF
                if let crlfRange = buffer.range(of: Data([0x0D, 0x0A])) {
                    let continuationData = buffer.subdata(in: buffer.startIndex..<crlfRange.lowerBound)
                    let continuation = String(data: continuationData, encoding: .utf8) ?? ""
                    buffer.removeSubrange(buffer.startIndex..<crlfRange.upperBound)
                    
                    // Check if continuation has another literal marker
                    if let nextLiteral = IMAPLiteralParser.findLiteral(in: continuation) {
                        // The continuation contains another literal
                        // We need to continue collecting literals
                        let partialWithFirstLiteral = literal.partialLine + "~LITERAL~" + String(continuation[..<nextLiteral.range.lowerBound])
                        
                        // Save the current literal data
                        var collectedSoFar = literal.collectedLiterals
                        collectedSoFar.append(literal.collectedData)
                        
                        pendingLiteral = PendingLiteral(
                            size: nextLiteral.size,
                            collectedData: Data(),
                            partialLine: partialWithFirstLiteral,
                            collectedLiterals: collectedSoFar
                        )
                        
                        // Continue parsing to collect the next literal
                        let moreResponses = try parseResponses()
                        responses.append(contentsOf: moreResponses)
                        return responses
                    }
                    
                    // Reconstruct the complete line
                    // partialLine already includes everything up to {size}
                    // We inject a placeholder for the literal data
                    let completeLine = literal.partialLine + "~LITERAL~" + continuation
                    
                    // Collect all literals including the current one
                    var allLiterals = literal.collectedLiterals
                    allLiterals.append(literal.collectedData)
                    
                    pendingLiteral = nil
                    
                    // Parse the complete line with literal data
                    // For multiple literals, we need to pass all of them
                    if allLiterals.count > 1 {
                        if let response = try parseLineWithMultipleLiterals(completeLine, literalDataArray: allLiterals) {
                            responses.append(response)
                        }
                    } else {
                        if let response = try parseLineWithLiteral(completeLine, literalData: literal.collectedData) {
                            responses.append(response)
                        }
                    }
                    
                    // Continue parsing remaining lines recursively
                    let moreResponses = try parseResponses()
                    responses.append(contentsOf: moreResponses)
                    return responses
                } else {
                    // Still waiting for the line to complete
                    pendingLiteral = literal
                    return responses
                }
            } else {
                // Still collecting literal data
                literal.collectedData.append(buffer)
                buffer.removeAll()
                pendingLiteral = literal
                return responses
            }
        }
        
        // Parse normal lines
        while let line = extractLine() {
            if let literalInfo = IMAPLiteralParser.findLiteral(in: line) {
                // Start collecting a literal
                // The line includes everything up to the literal marker
                pendingLiteral = PendingLiteral(
                    size: literalInfo.size,
                    collectedData: Data(),
                    partialLine: String(line[..<literalInfo.range.lowerBound]),
                    collectedLiterals: []
                )
                // Recursively continue parsing to handle the literal
                let moreResponses = try parseResponses()
                responses.append(contentsOf: moreResponses)
                return responses
            } else {
                // Normal line
                if let response = try parseLine(line) {
                    responses.append(response)
                }
            }
        }
        
        return responses
    }
    
    private func extractLine() -> String? {
        guard let crlfRange = buffer.range(of: Data([0x0D, 0x0A])) else {
            return nil
        }
        
        let lineData = buffer.subdata(in: buffer.startIndex..<crlfRange.lowerBound)
        guard let line = String(data: lineData, encoding: .utf8) else {
            return nil
        }
        
        buffer.removeSubrange(buffer.startIndex..<crlfRange.upperBound)
        return line
    }
    
    private func parseLineWithLiteral(_ line: String, literalData: Data) throws -> IMAPResponse? {
        // This line contains ~LITERAL~ as a placeholder for the actual literal data
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        if trimmed.hasPrefix("* ") {
            let remainder = String(trimmed.dropFirst(2))
            if isFetchResponse(remainder) {
                return try parseUntaggedResponseWithLiteral(remainder, literalData: literalData)
            }
        }
        
        return try withLiteralQueue([literalData]) {
            return try parseLine(line)
        }
    }
    
    private func parseLineWithMultipleLiterals(_ line: String, literalDataArray: [Data]) throws -> IMAPResponse? {
        // This line contains multiple ~LITERAL~ placeholders
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        
        if trimmed.hasPrefix("* ") {
            let remainder = String(trimmed.dropFirst(2))
            if isFetchResponse(remainder) {
                return try parseUntaggedResponseWithMultipleLiterals(remainder, literalDataArray: literalDataArray)
            }
        }
        
        return try withLiteralQueue(literalDataArray) {
            return try parseLine(line)
        }
    }

    func withLiteralQueue<T>(
        _ dataArray: [Data],
        parse: () throws -> T
    ) rethrows -> T {
        let previousQueue = literalQueue
        literalQueue = dataArray
        defer { literalQueue = previousQueue }
        return try parse()
    }

    private func isFetchResponse(_ untaggedLine: String) -> Bool {
        let parts = untaggedLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, UInt32(parts[0]) != nil else {
            return false
        }
        return parts[1].uppercased() == "FETCH"
    }

    func nextLiteralData() throws -> Data {
        guard !literalQueue.isEmpty else {
            throw IMAPError.parsingError("Missing literal data for placeholder")
        }
        return literalQueue.removeFirst()
    }

    func nextLiteralString() throws -> String {
        let data = try nextLiteralData()
        return decodeLiteralData(data)
    }

    func decodeLiteralData(_ data: Data) -> String {
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}
