import XCTest
@testable import SwiftIMAP

final class IMAPLiteralParserTests: XCTestCase {
    func testFindLiteralReturnsSizeAndRange() {
        let line = "* 1 FETCH (BODY[] {12}"
        let result = IMAPLiteralParser.findLiteral(in: line)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.size, 12)
    }

    func testFindLiteralReturnsNilWhenMissing() {
        let line = "* 1 FETCH (FLAGS (\\Seen))"
        XCTAssertNil(IMAPLiteralParser.findLiteral(in: line))
    }

    func testParseFetchResponseReturnsNilWithoutLiteral() throws {
        var buffer = Data()
        let line = "* 1 FETCH (FLAGS (\\Seen))"
        let result = try IMAPLiteralParser.parseFetchResponse(line: line, buffer: &buffer)
        XCTAssertNil(result)
    }

    func testParseFetchResponseReturnsEmptyWhenInsufficientData() throws {
        var buffer = Data("Hel".utf8)
        let line = "* 1 FETCH (BODY[] {5}"
        let result = try IMAPLiteralParser.parseFetchResponse(line: line, buffer: &buffer)
        XCTAssertEqual(result?.consumed, 0)
        XCTAssertEqual(result?.attributes.count, 0)
    }

    func testParseFetchResponseParsesBodyLiteral() throws {
        var buffer = Data("Hello".utf8)
        let line = "* 1 FETCH (BODY[] {5}"
        let result = try IMAPLiteralParser.parseFetchResponse(line: line, buffer: &buffer)
        XCTAssertEqual(result?.consumed, 5)
        XCTAssertEqual(result?.attributes.count, 1)

        guard case .body(let section, _, let data)? = result?.attributes.first else {
            XCTFail("Expected BODY attribute")
            return
        }
        XCTAssertNil(section)
        XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "Hello")
    }

    func testParseFetchResponseParsesBodyPeekWithSection() throws {
        var buffer = Data("Header".utf8)
        let line = "* 1 FETCH (BODY.PEEK[HEADER] {6}"
        let result = try IMAPLiteralParser.parseFetchResponse(line: line, buffer: &buffer)
        XCTAssertEqual(result?.consumed, 6)
        XCTAssertEqual(result?.attributes.count, 1)

        guard case .bodyPeek(let section, _, let data)? = result?.attributes.first else {
            XCTFail("Expected BODY.PEEK attribute")
            return
        }
        XCTAssertEqual(section, "HEADER")
        XCTAssertEqual(String(data: data ?? Data(), encoding: .utf8), "Header")
    }
}
