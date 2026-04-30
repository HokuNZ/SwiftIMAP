import XCTest
@testable import SwiftIMAP

/// Regression tests for #15: a server that emits raw non-ASCII bytes inside an IMAP
/// quoted string used to wedge `extractLine()` because strict UTF-8 decoding returned
/// nil and the parser kept waiting for a CRLF that had already arrived. The fix falls
/// back to Latin-1 so every byte maps to a code point and the parser progresses.
final class IMAPParserNonASCIITests: XCTestCase {

    func testParserAdvancesOnInvalidUTF8InQuotedString() throws {
        let parser = IMAPParser()

        // Build a FETCH response where the From mailbox local-part contains 0xE9
        // (Latin-1 'é') followed by 'l' — an invalid UTF-8 sequence, mirroring the
        // GreenMail behaviour described in #15.
        var bytes = Data()
        bytes.append(contentsOf: "* 1 FETCH (UID 1 ENVELOPE (\"Thu, 30 Apr 2026 06:00:00 +0000\" \"Test\" ((NIL NIL \"c".utf8)
        bytes.append(0xE9)
        bytes.append(contentsOf: "line\" \"example.org\")) NIL NIL ((NIL NIL \"test\" \"example.com\")) NIL NIL NIL \"<test@example.com>\"))\r\n".utf8)
        bytes.append(contentsOf: "A001 OK FETCH completed\r\n".utf8)

        parser.append(bytes)

        // Pre-fix: this call would loop indefinitely because extractLine() returned nil
        // for the FETCH line, leaving it in the buffer. Post-fix: the line decodes via
        // Latin-1 and the parser produces both responses.
        let responses = try parser.parseResponses()

        XCTAssertGreaterThanOrEqual(responses.count, 1,
                                    "Parser should produce at least the tagged OK once it can advance past the malformed line")

        // The tagged response is the proof we got past the FETCH line that previously stalled.
        let hasTaggedOK = responses.contains { response in
            if case .tagged(let tag, .ok) = response, tag == "A001" {
                return true
            }
            return false
        }
        XCTAssertTrue(hasTaggedOK, "Expected to see A001 OK after parsing past the non-ASCII FETCH line")
    }

    func testParserDoesNotHangOnIncompleteData() throws {
        // Sanity: an incomplete line (no CRLF yet) should still return nil cleanly without
        // blocking. This isn't the #15 path but guards against accidentally over-loosening.
        let parser = IMAPParser()
        parser.append(Data("* 1 FETCH (UID 1 ENVELOPE (".utf8))

        let responses = try parser.parseResponses()
        XCTAssertEqual(responses.count, 0)
    }
}
