import XCTest
@testable import SwiftIMAP

final class IMAPLiteralParsingSimpleTest: XCTestCase {
    func testSimpleLiteralParsing() throws {
        let parser = IMAPParser()
        
        // Very simple test case
        let response = "* 1 FETCH (BODY[] {5}\r\nHello)\r\nA001 OK\r\n"
        let data = response.data(using: .utf8)!
        
        print("Test data:")
        print("  Total bytes: \(data.count)")
        print("  As string: \(response.debugDescription)")
        
        // Add all data at once
        parser.append(data)
        
        // Parse
        let responses = try parser.parseResponses()
        
        print("\nParsed \(responses.count) responses:")
        for (index, response) in responses.enumerated() {
            print("  [\(index)]: \(response)")
        }
        
        XCTAssertEqual(responses.count, 2)
        
        // Check FETCH response
        if case .untagged(.fetch(let num, let attrs)) = responses[0] {
            XCTAssertEqual(num, 1)
            XCTAssertEqual(attrs.count, 1)
            
            if case .body(let section, _, let data) = attrs[0] {
                XCTAssertNil(section)
                XCTAssertNotNil(data)
                XCTAssertEqual(String(data: data!, encoding: .utf8), "Hello")
            } else {
                XCTFail("Expected body attribute")
            }
        } else {
            XCTFail("Expected fetch response")
        }
        
        // Check tagged response
        if case .tagged(let tag, .ok(_, _)) = responses[1] {
            XCTAssertEqual(tag, "A001")
        } else {
            XCTFail("Expected tagged OK response")
        }
    }
}
