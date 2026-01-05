import XCTest
@testable import SwiftIMAP

final class IMAPParserTests: XCTestCase {
    var parser: IMAPParser!

    override func setUp() {
        super.setUp()
        parser = IMAPParser()
    }

    func testParseOKResponse() throws {
        let input = "A001 OK LOGIN completed\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .tagged(let tag, let status) = responses[0] {
            XCTAssertEqual(tag, "A001")
            if case .ok(let code, let text) = status {
                XCTAssertNil(code)
                XCTAssertEqual(text, "LOGIN completed")
            } else {
                XCTFail("Expected OK status")
            }
        } else {
            XCTFail("Expected tagged response")
        }
    }

    func testParseNOResponse() throws {
        let input = "A002 NO LOGIN failed\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .tagged(let tag, let status) = responses[0] {
            XCTAssertEqual(tag, "A002")
            if case .no(let code, let text) = status {
                XCTAssertNil(code)
                XCTAssertEqual(text, "LOGIN failed")
            } else {
                XCTFail("Expected NO status")
            }
        } else {
            XCTFail("Expected tagged response")
        }
    }

    func testParseBADResponse() throws {
        let input = "A003 BAD Invalid command\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .tagged(let tag, let status) = responses[0] {
            XCTAssertEqual(tag, "A003")
            if case .bad(let code, let text) = status {
                XCTAssertNil(code)
                XCTAssertEqual(text, "Invalid command")
            } else {
                XCTFail("Expected BAD status")
            }
        } else {
            XCTFail("Expected tagged response")
        }
    }

    func testParseParenthesizedListWithQuotesAndNestedLists() throws {
        let scanner = Scanner(string: "(\"Foo Bar\" Baz (\"Inner Value\" Qux) NIL)")
        scanner.charactersToBeSkipped = nil

        let items = try parser.parseParenthesizedList(scanner)

        XCTAssertEqual(items, ["Foo Bar", "Baz", "(\"Inner Value\" Qux)", "NIL"])
    }
}
