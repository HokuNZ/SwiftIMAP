import XCTest
@testable import SwiftIMAP

extension IMAPParserTests {
    func testParseCapabilityResponse() throws {
        let input = "* CAPABILITY IMAP4rev1 STARTTLS AUTH=PLAIN AUTH=LOGIN\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .untagged(.capability(let caps)) = responses[0] {
            XCTAssertEqual(caps, ["IMAP4rev1", "STARTTLS", "AUTH=PLAIN", "AUTH=LOGIN"])
        } else {
            XCTFail("Expected CAPABILITY response")
        }
    }

    func testParseExistsResponse() throws {
        let input = "* 23 EXISTS\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .untagged(.exists(let count)) = responses[0] {
            XCTAssertEqual(count, 23)
        } else {
            XCTFail("Expected EXISTS response")
        }
    }

    func testParseRecentResponse() throws {
        let input = "* 5 RECENT\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .untagged(.recent(let count)) = responses[0] {
            XCTAssertEqual(count, 5)
        } else {
            XCTFail("Expected RECENT response")
        }
    }

    func testParseFlagsResponse() throws {
        let input = "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .untagged(.flags(let flags)) = responses[0] {
            XCTAssertEqual(flags, ["\\Answered", "\\Flagged", "\\Deleted", "\\Seen", "\\Draft"])
        } else {
            XCTFail("Expected FLAGS response")
        }
    }

    func testParseListResponse() throws {
        let input = "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .untagged(.list(let listResponse)) = responses[0] {
            XCTAssertEqual(listResponse.attributes, ["\\HasNoChildren"])
            XCTAssertEqual(listResponse.delimiter, "/")
            XCTAssertEqual(listResponse.name, "INBOX")
        } else {
            XCTFail("Expected LIST response")
        }
    }

    func testParseListResponseWithNilDelimiter() throws {
        let input = "* LIST (\\Noselect) NIL \"\"\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .untagged(.list(let listResponse)) = responses[0] {
            XCTAssertEqual(listResponse.attributes, ["\\Noselect"])
            XCTAssertNil(listResponse.delimiter)
            XCTAssertEqual(listResponse.name, "")
        } else {
            XCTFail("Expected LIST response")
        }
    }

    func testParseListResponseWithLiteralMailbox() throws {
        let input = "* LIST (\\HasNoChildren) \"/\" {5}\r\nINBOX\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .untagged(.list(let listResponse)) = responses[0] {
            XCTAssertEqual(listResponse.attributes, ["\\HasNoChildren"])
            XCTAssertEqual(listResponse.delimiter, "/")
            XCTAssertEqual(listResponse.name, "INBOX")
            XCTAssertEqual(listResponse.rawName, Data("INBOX".utf8))
        } else {
            XCTFail("Expected LIST response")
        }
    }

    func testParseQuotedStringWithEscapes() throws {
        let input = "* LIST (\\HasNoChildren) \"/\" \"Folder\\\\\\\"Name\"\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .untagged(.list(let listResponse)) = responses[0] {
            XCTAssertEqual(listResponse.name, "Folder\\\"Name")
        } else {
            XCTFail("Expected LIST response")
        }
    }

    func testParseSearchResponse() throws {
        let input = "* SEARCH 2 3 6 9 12 15\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .untagged(.search(let numbers)) = responses[0] {
            XCTAssertEqual(numbers, [2, 3, 6, 9, 12, 15])
        } else {
            XCTFail("Expected SEARCH response")
        }
    }

    func testParseEmptySearchResponse() throws {
        let input = "* SEARCH\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .untagged(.search(let numbers)) = responses[0] {
            XCTAssertEqual(numbers, [])
        } else {
            XCTFail("Expected SEARCH response")
        }
    }
}
