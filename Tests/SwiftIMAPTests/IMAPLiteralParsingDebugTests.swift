import XCTest
@testable import SwiftIMAP

final class IMAPLiteralParsingDebugTests: XCTestCase {
    func testDebugParseFetchWithLiteral() throws {
        let parser = IMAPParser()
        
        // Simulate a FETCH response with a literal
        let responseHeader = "* 1 FETCH (BODY[] {46}\r\n"
        let literalData = "From: test@example.com\r\nSubject: Test\r\n\r\nHello"
        let responseTrailer = ")\r\nA001 OK Fetch completed\r\n"
        
        print("\n=== DEBUG: Starting literal parsing test ===")
        
        // Add the response header
        print("1. Adding header: \(responseHeader.debugDescription)")
        parser.append(responseHeader.data(using: .utf8)!)
        
        // First parse should return empty (waiting for literal)
        print("2. First parse...")
        var responses = try parser.parseResponses()
        print("   Got \(responses.count) responses")
        for (index, response) in responses.enumerated() {
            print("   Response \(index): \(response)")
        }
        
        // Add the literal data
        print("\n3. Adding literal data: \(literalData.count) bytes")
        parser.append(literalData.data(using: .utf8)!)
        
        // Second parse
        print("4. Second parse...")
        responses = try parser.parseResponses()
        print("   Got \(responses.count) responses")
        for (index, response) in responses.enumerated() {
            print("   Response \(index): \(response)")
        }
        
        // Add the response trailer
        print("\n5. Adding trailer: \(responseTrailer.debugDescription)")
        parser.append(responseTrailer.data(using: .utf8)!)
        
        // Final parse
        print("6. Final parse...")
        responses = try parser.parseResponses()
        print("   Got \(responses.count) responses")
        for (index, response) in responses.enumerated() {
            print("   Response \(index): \(response)")
        }
        
        print("\n=== DEBUG: Test complete ===")
    }
}
