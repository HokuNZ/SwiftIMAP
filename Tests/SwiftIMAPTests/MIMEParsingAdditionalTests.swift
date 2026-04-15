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

    func testInlinePartWithFilenameIsAttachment() throws {
        // Issue #5: Inline parts WITH a filename should be treated as attachments
        // (e.g., Apple Mail marks PDF attachments as inline with filename)
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
        XCTAssertTrue(part?.isAttachment ?? false)  // Changed: inline WITH filename IS attachment
        XCTAssertEqual(parsed?.attachments.count, 1)
    }

    func testInlinePartWithoutFilenameIsNotAttachment() throws {
        // Truly embedded content (e.g., cid: referenced images) should NOT be attachments
        let boundary = "boundary"
        let messageData = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Inline Image
        Content-Type: multipart/related; boundary="\(boundary)"

        --\(boundary)
        Content-Type: text/html

        <html><body><img src="cid:img1"></body></html>
        --\(boundary)
        Content-Type: image/png
        Content-Disposition: inline
        Content-ID: <img1>
        Content-Transfer-Encoding: base64

        AAA=
        --\(boundary)--
        """.data(using: .utf8)!

        let summary = makeSummary()
        let parsed = try summary.parseMimeContent(from: messageData)
        let inlinePart = parsed?.parts.first { $0.contentID != nil }

        XCTAssertNotNil(inlinePart)
        XCTAssertTrue(inlinePart?.isInline ?? false)
        XCTAssertNil(inlinePart?.filename)
        XCTAssertFalse(inlinePart?.isAttachment ?? true)  // No filename = NOT attachment
        XCTAssertEqual(parsed?.attachments.count, 0)
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

    func testInlineImageWithContentIdIsNotAttachment() throws {
        // Edge case: inline image WITH filename but also Content-ID
        // These are embedded via cid: in HTML and should NOT be attachments
        let boundary = "boundary"
        let messageData = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Email with embedded logo
        Content-Type: multipart/related; boundary="\(boundary)"

        --\(boundary)
        Content-Type: text/html

        <html><body><img src="cid:logo"></body></html>
        --\(boundary)
        Content-Type: image/png; name="company-logo.png"
        Content-Disposition: inline; filename="company-logo.png"
        Content-ID: <logo>
        Content-Transfer-Encoding: base64

        AAA=
        --\(boundary)--
        """.data(using: .utf8)!

        let summary = makeSummary()
        let parsed = try summary.parseMimeContent(from: messageData)
        let imagePart = parsed?.parts.first { $0.contentID != nil }

        XCTAssertNotNil(imagePart)
        XCTAssertEqual(imagePart?.filename, "company-logo.png")
        XCTAssertEqual(imagePart?.contentID, "<logo>")
        XCTAssertTrue(imagePart?.isInline ?? false)
        XCTAssertFalse(imagePart?.isAttachment ?? true)  // Has Content-ID = embedded, not attachment
        XCTAssertEqual(parsed?.attachments.count, 0)
    }

    func testAppleMailInlinePdfIsAttachment() throws {
        // Real-world case from issue #5: Apple Mail marks PDFs as inline with filename
        let messageData = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Apple Mail PDF
        Content-Type: application/pdf; x-unix-mode=0644; name="document.pdf"
        Content-Disposition: inline; filename="document.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQKJeLjz9MKCg==
        """.data(using: .utf8)!

        let summary = makeSummary()
        let parsed = try summary.parseMimeContent(from: messageData)
        let part = parsed?.parts.first

        XCTAssertEqual(part?.filename, "document.pdf")
        XCTAssertEqual(part?.mimeType, "application/pdf")
        XCTAssertTrue(part?.isInline ?? false)
        XCTAssertTrue(part?.isAttachment ?? false)
        XCTAssertEqual(parsed?.attachments.count, 1)
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
