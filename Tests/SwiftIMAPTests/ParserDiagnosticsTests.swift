import XCTest
@testable import SwiftIMAP

final class ParserDiagnosticsTests: XCTestCase {
    func testShortInputIsUnchanged() {
        let input = "* OK ready"
        XCTAssertEqual(input.truncatedForDiagnostics(), input)
    }

    func testOversizedInputIsTruncatedWithMarker() {
        let input = String(repeating: "x", count: 5000)
        let result = input.truncatedForDiagnostics(limit: 200)
        XCTAssertTrue(result.hasPrefix(String(repeating: "x", count: 200)))
        XCTAssertTrue(result.contains("5000 chars total, truncated"))
        XCTAssertLessThan(result.count, 260)
    }

    /// A parser error on an oversized line must not echo the whole line (which could
    /// carry message content) into the error message.
    func testParserErrorDoesNotEchoOversizedLine() {
        let parser = IMAPParser()
        // A tagged response whose status keyword is an oversized unknown token.
        let huge = "A1 " + String(repeating: "Z", count: 4000) + "\r\n"
        parser.append(Data(huge.utf8))
        do {
            _ = try parser.parseResponses()
            XCTFail("Expected a parsing error")
        } catch let IMAPError.parsingError(message) {
            XCTAssertLessThan(message.count, 400, "Parser error echoed an oversized line: \(message.count) chars")
            XCTAssertTrue(message.contains("truncated"))
        } catch {
            XCTFail("Expected IMAPError.parsingError, got: \(error)")
        }
    }
}
