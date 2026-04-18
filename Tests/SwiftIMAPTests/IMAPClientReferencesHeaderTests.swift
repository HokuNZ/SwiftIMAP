import XCTest
@testable import SwiftIMAP

final class IMAPClientReferencesHeaderTests: XCTestCase {
    private func makeClient() -> IMAPClient {
        let config = IMAPConfiguration(
            hostname: "example.com",
            authMethod: .login(username: "user", password: "pass")
        )
        return IMAPClient(configuration: config)
    }

    func testParsesSingleReference() {
        let client = makeClient()
        let raw = "References: <abc@example.com>\r\n\r\n"
        let data = Data(raw.utf8)

        XCTAssertEqual(client.parseReferencesHeader(from: data), "<abc@example.com>")
    }

    func testParsesMultipleReferencesOnSingleLine() {
        let client = makeClient()
        let raw = "References: <a@example.com> <b@example.com> <c@example.com>\r\n\r\n"
        let data = Data(raw.utf8)

        XCTAssertEqual(
            client.parseReferencesHeader(from: data),
            "<a@example.com> <b@example.com> <c@example.com>"
        )
    }

    func testUnfoldsFoldedHeaderWithSpaceContinuation() {
        let client = makeClient()
        let raw = "References: <a@example.com>\r\n <b@example.com>\r\n <c@example.com>\r\n\r\n"
        let data = Data(raw.utf8)

        XCTAssertEqual(
            client.parseReferencesHeader(from: data),
            "<a@example.com> <b@example.com> <c@example.com>"
        )
    }

    func testUnfoldsFoldedHeaderWithTabContinuation() {
        let client = makeClient()
        let raw = "References: <a@example.com>\r\n\t<b@example.com>\r\n\r\n"
        let data = Data(raw.utf8)

        XCTAssertEqual(
            client.parseReferencesHeader(from: data),
            "<a@example.com> <b@example.com>"
        )
    }

    func testReturnsNilWhenHeaderMissing() {
        let client = makeClient()
        let raw = "Subject: Hello\r\n\r\n"
        let data = Data(raw.utf8)

        XCTAssertNil(client.parseReferencesHeader(from: data))
    }

    func testReturnsNilForEmptyValue() {
        let client = makeClient()
        let raw = "References: \r\n\r\n"
        let data = Data(raw.utf8)

        XCTAssertNil(client.parseReferencesHeader(from: data))
    }

    func testIgnoresOtherHeadersAndPicksReferences() {
        let client = makeClient()
        let raw = """
        Subject: Re: Hello\r
        References: <a@example.com> <b@example.com>\r
        In-Reply-To: <b@example.com>\r
        \r

        """
        let data = Data(raw.utf8)

        XCTAssertEqual(
            client.parseReferencesHeader(from: data),
            "<a@example.com> <b@example.com>"
        )
    }

    func testIsCaseInsensitiveOnHeaderName() {
        let client = makeClient()
        let raw = "REFERENCES: <a@example.com>\r\n\r\n"
        let data = Data(raw.utf8)

        XCTAssertEqual(client.parseReferencesHeader(from: data), "<a@example.com>")
    }

    func testFallsBackToISOLatin1ForNonUTF8Data() {
        let client = makeClient()
        // 0xE9 is é in ISO-8859-1 but not valid UTF-8 on its own.
        var bytes: [UInt8] = Array("References: <\u{00E9}@example.com>\r\n\r\n".utf8)
        // Replace the é UTF-8 bytes (0xC3 0xA9) with raw ISO-8859-1 0xE9.
        if let c3Index = bytes.firstIndex(of: 0xC3), bytes.count > c3Index + 1, bytes[c3Index + 1] == 0xA9 {
            bytes.remove(at: c3Index + 1)
            bytes[c3Index] = 0xE9
        }
        let data = Data(bytes)

        // UTF-8 decoding should fail, so this exercises the ISO-8859-1 fallback.
        XCTAssertNil(String(data: data, encoding: .utf8))
        XCTAssertEqual(client.parseReferencesHeader(from: data), "<é@example.com>")
    }
}
