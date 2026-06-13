import XCTest
@testable import SwiftIMAP
import Foundation

final class MIMEParsingTests: XCTestCase {
    
    func testSimplePlainTextMessage() throws {
        let messageData = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Test Message
        Content-Type: text/plain; charset=utf-8
        
        This is a simple plain text message.
        """.data(using: .utf8)!
        
        let summary = createTestSummary()
        let parsed = try summary.parseMimeContent(from: messageData)
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.parts.count, 1)
        XCTAssertEqual(parsed?.plainTextContent, "This is a simple plain text message.")
        XCTAssertNil(parsed?.htmlContent)
        XCTAssertTrue(parsed?.attachments.isEmpty ?? false)
    }
    
    func testMultipartAlternativeMessage() throws {
        let boundary = "boundary123"
        let messageData = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Multipart Test
        Content-Type: multipart/alternative; boundary="\(boundary)"
        
        --\(boundary)
        Content-Type: text/plain; charset=utf-8
        
        Plain text version
        --\(boundary)
        Content-Type: text/html; charset=utf-8
        
        <html><body>HTML version</body></html>
        --\(boundary)--
        """.data(using: .utf8)!
        
        let summary = createTestSummary()
        let parsed = try summary.parseMimeContent(from: messageData)
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.parts.count, 2)
        XCTAssertEqual(parsed?.plainTextContent, "Plain text version")
        XCTAssertEqual(parsed?.htmlContent, "<html><body>HTML version</body></html>")
        XCTAssertTrue(parsed?.isMultipart ?? false)
        XCTAssertEqual(parsed?.boundary, boundary)
    }
    
    func testMultipartMixedWithAttachment() throws {
        let boundary = "mixed-boundary"
        let messageData = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Message with Attachment
        Content-Type: multipart/mixed; boundary="\(boundary)"
        
        --\(boundary)
        Content-Type: text/plain
        
        Message with attachment
        --\(boundary)
        Content-Type: application/pdf; name="document.pdf"
        Content-Disposition: attachment; filename="document.pdf"
        Content-Transfer-Encoding: base64
        
        JVBERi0xLjQKJeLjz9MKCg==
        --\(boundary)--
        """.data(using: .utf8)!
        
        let summary = createTestSummary()
        let parsed = try summary.parseMimeContent(from: messageData)
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.parts.count, 2)
        XCTAssertEqual(parsed?.plainTextContent, "Message with attachment")
        XCTAssertEqual(parsed?.attachments.count, 1)
        
        let attachment = parsed?.attachments.first
        XCTAssertNotNil(attachment)
        XCTAssertEqual(attachment?.filename, "document.pdf")
        XCTAssertEqual(attachment?.mimeType, "application/pdf")
        XCTAssertTrue(attachment?.isAttachment ?? false)
        XCTAssertFalse(attachment?.isInline ?? true)
    }
    
    func testNestedMultipartMessage() throws {
        let outerBoundary = "outer"
        let innerBoundary = "inner"
        
        let messageData = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Nested Multipart
        Content-Type: multipart/mixed; boundary="\(outerBoundary)"
        
        --\(outerBoundary)
        Content-Type: multipart/alternative; boundary="\(innerBoundary)"
        
        --\(innerBoundary)
        Content-Type: text/plain
        
        Plain text in nested part
        --\(innerBoundary)
        Content-Type: text/html
        
        <p>HTML in nested part</p>
        --\(innerBoundary)--
        --\(outerBoundary)
        Content-Type: image/png; name="image.png"
        Content-Disposition: attachment; filename="image.png"
        Content-Transfer-Encoding: base64
        
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=
        --\(outerBoundary)--
        """.data(using: .utf8)!
        
        let summary = createTestSummary()
        let parsed = try summary.parseMimeContent(from: messageData)
        
        XCTAssertNotNil(parsed)
        // Should have 3 parts total: 2 from inner multipart + 1 attachment
        XCTAssertEqual(parsed?.parts.count, 3)
        XCTAssertEqual(parsed?.plainTextContent, "Plain text in nested part")
        XCTAssertEqual(parsed?.htmlContent, "<p>HTML in nested part</p>")
        XCTAssertEqual(parsed?.attachments.count, 1)
        XCTAssertEqual(parsed?.attachments.first?.filename, "image.png")
    }
    
    func testInlineImageDetection() throws {
        let boundary = "boundary"
        let messageData = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Inline Image Test
        Content-Type: multipart/related; boundary="\(boundary)"
        
        --\(boundary)
        Content-Type: text/html
        
        <html><body><img src="cid:image1"></body></html>
        --\(boundary)
        Content-Type: image/png
        Content-Disposition: inline
        Content-ID: <image1>
        Content-Transfer-Encoding: base64
        
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=
        --\(boundary)--
        """.data(using: .utf8)!
        
        let summary = createTestSummary()
        let parsed = try summary.parseMimeContent(from: messageData)
        
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.parts.count, 2)
        XCTAssertEqual(parsed?.inlineParts.count, 1)
        
        let inlinePart = parsed?.inlineParts.first
        XCTAssertNotNil(inlinePart)
        XCTAssertTrue(inlinePart?.isInline ?? false)
        XCTAssertFalse(inlinePart?.isAttachment ?? true)
        XCTAssertEqual(inlinePart?.contentID, "<image1>")
    }
    
    func testPartsByTypeGrouping() throws {
        let boundary = "boundary"
        let messageData = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Multiple Parts Test
        Content-Type: multipart/mixed; boundary="\(boundary)"
        
        --\(boundary)
        Content-Type: text/plain
        
        First text part
        --\(boundary)
        Content-Type: text/plain
        
        Second text part
        --\(boundary)
        Content-Type: image/jpeg; name="photo1.jpg"
        Content-Disposition: attachment
        
        /9j/4AAQ
        --\(boundary)
        Content-Type: image/jpeg; name="photo2.jpg"
        Content-Disposition: attachment
        
        /9j/4BBQ
        --\(boundary)--
        """.data(using: .utf8)!
        
        let summary = createTestSummary()
        let parsed = try summary.parseMimeContent(from: messageData)
        
        XCTAssertNotNil(parsed)
        let partsByType = parsed?.partsByType ?? [:]
        
        XCTAssertEqual(partsByType["text/plain"]?.count, 2)
        XCTAssertEqual(partsByType["image/jpeg"]?.count, 2)
        
        // Test convenience methods
        XCTAssertEqual(parsed?.parts(withContentType: "text/plain").count, 2)
        XCTAssertEqual(parsed?.parts(withContentType: "image/").count, 2)
        XCTAssertNotNil(parsed?.firstPart(withContentType: "image/jpeg"))
    }
    
    func testStaticParseMimeContentNeedsNoInstance() throws {
        let messageData = """
        From: sender@example.com
        To: recipient@example.com
        Subject: Static Parse
        Content-Type: text/plain; charset=utf-8

        Parsed without a MessageSummary instance.
        """.data(using: .utf8)!

        // No stub instance required.
        let parsed = try MessageSummary.parseMimeContent(from: messageData)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.plainTextContent, "Parsed without a MessageSummary instance.")
    }

    func testInstanceParseMimeContentMatchesStatic() throws {
        let messageData = """
        From: sender@example.com
        Subject: Parity
        Content-Type: text/plain; charset=utf-8

        Body.
        """.data(using: .utf8)!

        let viaInstance = try createTestSummary().parseMimeContent(from: messageData)
        let viaStatic = try MessageSummary.parseMimeContent(from: messageData)

        XCTAssertEqual(viaInstance?.plainTextContent, viaStatic?.plainTextContent)
        XCTAssertEqual(viaInstance?.parts.count, viaStatic?.parts.count)
    }

    func testStaticParseMimeContentThrowsOnInvalidUTF8() {
        let invalid = Data([0xFF, 0xFE, 0xFD])
        XCTAssertThrowsError(try MessageSummary.parseMimeContent(from: invalid))
    }

    /// The decodedText raw fallback (#38): when the transfer encoding cannot be
    /// decoded, decodedText returns the raw body text rather than nil, and
    /// decodedData is nil. Pins the only reason rawBody is retained.
    func testUndecodableTransferEncodingFallsBackToRawText() throws {
        let raw = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: x-custom\r\n\r\nraw payload text"
        let parsed = try XCTUnwrap(MessageSummary.parseMimeContent(from: Data(raw.utf8)))
        let part = try XCTUnwrap(parsed.parts.first)

        XCTAssertNil(part.decodedData, "Unknown transfer encoding should fail to decode")
        XCTAssertEqual(part.decodedText, "raw payload text",
                       "decodedText must fall back to the raw body when decoding fails")
    }

    /// Compile-time guarantee for #38: ParsedMimeMessage and MimePart are
    /// Sendable, so parsed results can cross actor/task boundaries. This test
    /// fails to compile (under strict concurrency it errors) if the conformance
    /// is removed or invalidated by a non-Sendable stored property.
    func testParsedMimeMessageCrossesActorBoundary() async throws {
        let raw = "Content-Type: text/plain; charset=utf-8\r\n\r\nHello across actors"
        let parsed = try XCTUnwrap(MessageSummary.parseMimeContent(from: Data(raw.utf8)))

        let text = await Task.detached { parsed.plainTextContent }.value
        XCTAssertEqual(text, "Hello across actors")

        let parts: [MimePart] = parsed.parts
        let decoded = await Task.detached { parts.compactMap(\.decodedText) }.value
        XCTAssertEqual(decoded, ["Hello across actors"])
    }

    /// ParsedMimeMessage and MimePart are Equatable: parsing identical bytes
    /// twice yields equal values; differing bodies are unequal.
    func testParsedMimeMessageEquatableConformance() throws {
        let raw = "Content-Type: text/plain; charset=utf-8\r\n\r\nbody one"
        let a = try XCTUnwrap(MessageSummary.parseMimeContent(from: Data(raw.utf8)))
        let b = try XCTUnwrap(MessageSummary.parseMimeContent(from: Data(raw.utf8)))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.parts, b.parts)

        let other = raw.replacingOccurrences(of: "body one", with: "body two")
        let c = try XCTUnwrap(MessageSummary.parseMimeContent(from: Data(other.utf8)))
        XCTAssertNotEqual(a, c)
    }

    /// Equality on the MimePart decode-failure branch (where rawBody is
    /// populated, not the decoded-success branch). Two parts that both fail to
    /// decode with the same raw body compare equal; a decoded part and a
    /// failed-decode part with the same bytes compare unequal (they differ in
    /// decodedData: one has bytes, the other is nil).
    func testMimePartEqualityOnDecodeFailureBranch() throws {
        // An unknown transfer encoding makes decodedContentData() throw, so
        // decodedData == nil and rawBody is retained.
        let undecodable = "Content-Type: text/plain\r\nContent-Transfer-Encoding: x-custom\r\n\r\nsame body"
        let p1 = try XCTUnwrap(MessageSummary.parseMimeContent(from: Data(undecodable.utf8))).parts.first
        let p2 = try XCTUnwrap(MessageSummary.parseMimeContent(from: Data(undecodable.utf8))).parts.first
        XCTAssertEqual(p1, p2, "Two equal failed-decode parts must compare equal")
        XCTAssertNil(p1?.decodedData)

        // A decodable part with the same body text decodes to bytes, so its
        // decodedData differs from the failed part's nil — they are unequal.
        let decodable = "Content-Type: text/plain\r\n\r\nsame body"
        let p3 = try XCTUnwrap(MessageSummary.parseMimeContent(from: Data(decodable.utf8))).parts.first
        XCTAssertNotNil(p3?.decodedData)
        XCTAssertNotEqual(p1, p3, "A failed-decode part and a decoded part must compare unequal")
    }

    // Helper to create a test message summary
    private func createTestSummary() -> MessageSummary {
        MessageSummary(
            uid: 1,
            sequenceNumber: 1,
            flags: [],
            internalDate: Date(),
            size: 1000,
            envelope: nil
        )
    }
}