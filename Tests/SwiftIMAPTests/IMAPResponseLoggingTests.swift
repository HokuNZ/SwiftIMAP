import XCTest
@testable import SwiftIMAP

final class IMAPResponseLoggingTests: XCTestCase {
    func testFetchBodyDataIsRedactedFromLogging() {
        let secret = "Subject: Payslip\r\nFrom: hr@example.com\r\n\r\nYour salary is..."
        let body = Data(secret.utf8)
        let response = IMAPResponse.untagged(.fetch(7, [
            .uid(7),
            .body(section: "TEXT", origin: nil, data: body)
        ]))

        let logged = response.loggingDescription
        XCTAssertFalse(logged.contains("Payslip"), "Message content must not appear in logs")
        XCTAssertFalse(logged.contains("salary"), "Message content must not appear in logs")
        XCTAssertTrue(logged.contains("<\(body.count) bytes>"), "Body should be reduced to a byte count")
        XCTAssertTrue(logged.contains("uid(7)"), "Structural metadata should be preserved")
    }

    func testFetchHeaderAndEnvelopeAreRedacted() {
        let header = Data("From: ceo@example.com\r\nSubject: Secret\r\n".utf8)
        let envelope = IMAPResponse.EnvelopeData(date: nil, subject: "Secret", from: nil, sender: nil, replyTo: nil, to: nil, cc: nil, bcc: nil, inReplyTo: nil, messageID: nil, rawDate: nil, rawSubject: nil, rawInReplyTo: nil, rawMessageID: nil)
        let response = IMAPResponse.untagged(.fetch(1, [.header(header), .envelope(envelope)]))

        let logged = response.loggingDescription
        XCTAssertFalse(logged.contains("ceo@example.com"))
        XCTAssertFalse(logged.contains("Secret"))
        XCTAssertTrue(logged.contains("header(<\(header.count) bytes>)"))
        XCTAssertTrue(logged.contains("envelope(<redacted>)"))
    }

    func testNonFetchResponseRendersNormally() {
        // Non-fetch responses carry only protocol metadata, so they render in full.
        let response = IMAPResponse.tagged(tag: "A001", status: .ok(nil, "LOGIN completed"))
        XCTAssertEqual(response.loggingDescription, "\(response)")
    }
}
