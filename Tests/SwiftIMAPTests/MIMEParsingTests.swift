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