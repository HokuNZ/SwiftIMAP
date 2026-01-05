import XCTest
@testable import SwiftIMAP

final class IMAPLiteralParsingTests: XCTestCase {
    func testParseFetchWithLiteral() throws {
        let parser = IMAPParser()
        
        // Simulate a FETCH response with a literal
        let responseHeader = "* 1 FETCH (BODY[] {46}\r\n"
        let literalData = "From: test@example.com\r\nSubject: Test\r\n\r\nHello"
        let responseTrailer = ")\r\nA001 OK Fetch completed\r\n"
        
        // Add the response header
        parser.append(responseHeader.data(using: .utf8)!)
        
        // First parse should return empty (waiting for literal)
        var responses = try parser.parseResponses()
        XCTAssertEqual(responses.count, 0, "Should not parse any responses yet - waiting for literal")
        
        // Add the literal data
        parser.append(literalData.data(using: .utf8)!)
        
        // Second parse should still be waiting (no CRLF after literal yet)
        responses = try parser.parseResponses()
        XCTAssertEqual(responses.count, 0, "Should still be waiting for the rest of the response")
        
        // Add the response trailer
        parser.append(responseTrailer.data(using: .utf8)!)
        
        // Final parse should give us both responses
        responses = try parser.parseResponses()
        XCTAssertEqual(responses.count, 2, "Should have parsed fetch and tagged response")
        
        // Verify the FETCH response
        if case .untagged(.fetch(let num, let attrs)) = responses[0] {
            XCTAssertEqual(num, 1)
            XCTAssertEqual(attrs.count, 1)
            
            if case .body(let section, let origin, let data) = attrs[0] {
                XCTAssertNil(section)
                XCTAssertNil(origin)
                XCTAssertNotNil(data)
                XCTAssertEqual(data?.count, 46)
                
                let content = String(data: data!, encoding: .utf8)
                XCTAssertEqual(content, literalData)
            } else {
                XCTFail("Expected body attribute, got \(attrs[0])")
            }
        } else {
            XCTFail("Expected untagged fetch response, got \(responses[0])")
        }
        
        // Verify the tagged response
        if case .tagged(let tag, let status) = responses[1] {
            XCTAssertEqual(tag, "A001")
            if case .ok(_, let text) = status {
                XCTAssertEqual(text, "Fetch completed")
            } else {
                XCTFail("Expected OK status")
            }
        } else {
            XCTFail("Expected tagged response, got \(responses[1])")
        }
    }
    
    func testParseFetchWithBodyPeekLiteral() throws {
        let parser = IMAPParser()
        
        // Simulate a BODY.PEEK response with a literal
        let response = "* 2 FETCH (UID 123 BODY.PEEK[HEADER] {78}\r\n"
        let literalData = "From: sender@example.com\r\nTo: recipient@example.com\r\nSubject: Test Message\r\n\r\n"
        let trailer = ")\r\nA002 OK Fetch completed\r\n"
        
        // Add all parts
        parser.append(response.data(using: .utf8)!)
        parser.append(literalData.data(using: .utf8)!)
        parser.append(trailer.data(using: .utf8)!)
        
        let responses = try parser.parseResponses()
        XCTAssertEqual(responses.count, 2)
        
        // Verify the FETCH response
        if case .untagged(.fetch(let num, let attrs)) = responses[0] {
            XCTAssertEqual(num, 2)
            XCTAssertEqual(attrs.count, 2)
            
            // Check UID
            if case .uid(let uid) = attrs[0] {
                XCTAssertEqual(uid, 123)
            } else {
                XCTFail("Expected UID attribute")
            }
            
            // Check BODY.PEEK[HEADER]
            if case .header(let data) = attrs[1] {
                XCTAssertEqual(data.count, 78)

                let content = String(data: data, encoding: .utf8)
                XCTAssertEqual(content, literalData)
            } else {
                XCTFail("Expected header attribute, got \(attrs[1])")
            }
        } else {
            XCTFail("Expected untagged fetch response")
        }
    }

    func testParseFetchWithRFC822HeaderTextAndFull() throws {
        let parser = IMAPParser()

        let headerLiteral = "Subject: Test\r\n\r\n"
        let textLiteral = "Hello\r\n"
        let fullLiteral = "Subject: Test\r\n\r\nHello\r\n"
        let response = "* 4 FETCH (RFC822.HEADER {\(headerLiteral.utf8.count)}\r\n" +
            "\(headerLiteral) RFC822.TEXT {\(textLiteral.utf8.count)}\r\n" +
            "\(textLiteral) RFC822 {\(fullLiteral.utf8.count)}\r\n" +
            "\(fullLiteral))\r\n" +
            "A004 OK Fetch completed\r\n"

        parser.append(response.data(using: .utf8)!)

        let responses = try parser.parseResponses()
        XCTAssertEqual(responses.count, 2)

        guard case .untagged(.fetch(_, let attrs)) = responses[0] else {
            XCTFail("Expected untagged fetch response")
            return
        }

        XCTAssertEqual(attrs.count, 3)

        if case .header(let data) = attrs[0] {
            XCTAssertEqual(String(data: data, encoding: .utf8), headerLiteral)
        } else {
            XCTFail("Expected RFC822.HEADER attribute")
        }

        if case .text(let data) = attrs[1] {
            XCTAssertEqual(String(data: data, encoding: .utf8), textLiteral)
        } else {
            XCTFail("Expected RFC822.TEXT attribute")
        }

        if case .body(let section, let origin, let data) = attrs[2] {
            XCTAssertNil(section)
            XCTAssertNil(origin)
            XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), fullLiteral)
        } else {
            XCTFail("Expected RFC822 attribute")
        }
    }

    func testParseFetchWithHeaderFields() throws {
        let parser = IMAPParser()

        let fieldsLiteral = "Subject: A\r\nFrom: B\r\n\r\n"
        let notLiteral = "Date: Tue\r\n\r\n"
        let response = "* 6 FETCH (BODY[HEADER.FIELDS (Subject From)] {\(fieldsLiteral.utf8.count)}\r\n" +
            "\(fieldsLiteral) BODY[HEADER.FIELDS.NOT (Date)] {\(notLiteral.utf8.count)}\r\n" +
            "\(notLiteral))\r\n" +
            "A006 OK Fetch completed\r\n"

        parser.append(response.data(using: .utf8)!)

        let responses = try parser.parseResponses()
        XCTAssertEqual(responses.count, 2)

        guard case .untagged(.fetch(_, let attrs)) = responses[0] else {
            XCTFail("Expected untagged fetch response")
            return
        }

        XCTAssertEqual(attrs.count, 2)

        if case .headerFields(let fields, let data) = attrs[0] {
            XCTAssertEqual(fields, ["Subject", "From"])
            XCTAssertEqual(String(data: data, encoding: .utf8), fieldsLiteral)
        } else {
            XCTFail("Expected headerFields attribute")
        }

        if case .headerFieldsNot(let fields, let data) = attrs[1] {
            XCTAssertEqual(fields, ["Date"])
            XCTAssertEqual(String(data: data, encoding: .utf8), notLiteral)
        } else {
            XCTFail("Expected headerFieldsNot attribute")
        }
    }
    
    func testParseFetchWithMultipleLiterals() throws {
        let parser = IMAPParser()
        
        // Simulate a response with multiple literals
        let response1 = "* 3 FETCH (BODY[1] {11}\r\n"
        let literal1 = "Part 1 data"
        let response2 = " BODY[2] {11}\r\n"
        let literal2 = "Part 2 data"
        let trailer = ")\r\nA003 OK Fetch completed\r\n"
        
        // Add all parts in sequence
        parser.append(response1.data(using: .utf8)!)
        parser.append(literal1.data(using: .utf8)!)
        parser.append(response2.data(using: .utf8)!)
        parser.append(literal2.data(using: .utf8)!)
        parser.append(trailer.data(using: .utf8)!)
        
        let responses = try parser.parseResponses()
        XCTAssertEqual(responses.count, 2)
        
        // Verify we got both body parts
        if case .untagged(.fetch(let num, let attrs)) = responses[0] {
            XCTAssertEqual(num, 3)
            XCTAssertEqual(attrs.count, 2)
            
            // Check first body part
            if case .body(let section1, _, let data1) = attrs[0] {
                XCTAssertEqual(section1, "1")
                XCTAssertEqual(String(data: data1!, encoding: .utf8), literal1)
            } else {
                XCTFail("Expected body[1] attribute")
            }
            
            // Check second body part
            if case .body(let section2, _, let data2) = attrs[1] {
                XCTAssertEqual(section2, "2")
                XCTAssertEqual(String(data: data2!, encoding: .utf8), literal2)
            } else {
                XCTFail("Expected body[2] attribute")
            }
        } else {
            XCTFail("Expected untagged fetch response")
        }
    }
}
