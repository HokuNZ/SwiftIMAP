import XCTest
@testable import SwiftIMAP

final class MIMEParsingAdditionalTests: XCTestCase {
    func testParseMimeContentRejectsNonUtf8() {
        let bodyData = Data([0xFF, 0xFE, 0xFD])
        let summary = makeSummary()

        XCTAssertThrowsError(try summary.parseMimeContent(from: bodyData)) { error in
            guard case IMAPError.parsingError(let message) = error else {
                return XCTFail("Expected parsingError")
            }
            XCTAssertTrue(message.contains("UTF-8"))
        }
    }

    func testHeadersAndTransferEncodingCaptured() throws {
        let messageData = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Encoding Test
        X-Custom: CustomValue
        Content-Type: text/plain; charset=iso-8859-1
        Content-Transfer-Encoding: quoted-printable

        Hello=20World
        """.data(using: .utf8)!

        let summary = makeSummary()
        let parsed = try summary.parseMimeContent(from: messageData)

        XCTAssertEqual(parsed?.headers["x-custom"], "CustomValue")
        XCTAssertEqual(parsed?.charset, "iso-8859-1")
        XCTAssertEqual(parsed?.transferEncoding, "quoted-printable")
        XCTAssertEqual(parsed?.plainTextContent, "Hello World")
    }

    func testInlineDispositionOverridesAttachment() throws {
        let messageData = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Inline Part
        Content-Type: image/png; name="inline.png"
        Content-Disposition: inline; filename="inline.png"
        Content-Transfer-Encoding: base64

        AAA=
        """.data(using: .utf8)!

        let summary = makeSummary()
        let parsed = try summary.parseMimeContent(from: messageData)
        let part = parsed?.parts.first

        XCTAssertEqual(part?.mimeType, "image/png")
        XCTAssertEqual(part?.filename, "inline.png")
        XCTAssertTrue(part?.isInline ?? false)
        XCTAssertFalse(part?.isAttachment ?? true)
    }

    func testAttachmentDetectedByContentTypeWithoutDisposition() throws {
        let messageData = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Attachment Part
        Content-Type: application/pdf; name="doc.pdf"
        Content-Transfer-Encoding: base64

        AAA=
        """.data(using: .utf8)!

        let summary = makeSummary()
        let parsed = try summary.parseMimeContent(from: messageData)
        let part = parsed?.parts.first

        XCTAssertEqual(part?.mimeType, "application/pdf")
        XCTAssertEqual(part?.filename, "doc.pdf")
        XCTAssertTrue(part?.isAttachment ?? false)
        XCTAssertFalse(part?.isInline ?? true)
    }

    func testDecodedTextFallsBackOnInvalidBase64() throws {
        let messageData = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Invalid Base64
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64

        NotBase64!!
        """.data(using: .utf8)!

        let summary = makeSummary()
        let parsed = try summary.parseMimeContent(from: messageData)
        let part = parsed?.parts.first

        XCTAssertEqual(part?.decodedText, "NotBase64!!")
    }

    private func makeSummary() -> MessageSummary {
        MessageSummary(
            uid: 1,
            sequenceNumber: 1,
            flags: [],
            internalDate: Date(),
            size: 100,
            envelope: nil
        )
    }
}
