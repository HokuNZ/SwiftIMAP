import XCTest
@testable import SwiftIMAP

final class RFC2047DecoderTests: XCTestCase {

    // MARK: - Plain text passes through unchanged

    func testPlainAsciiPassesThrough() {
        XCTAssertEqual(RFC2047.decode("Just a plain subject"), "Just a plain subject")
    }

    func testEmptyStringPassesThrough() {
        XCTAssertEqual(RFC2047.decode(""), "")
    }

    // MARK: - Base64 encoding (B)

    func testBase64UTF8EncodedWord() {
        // =?utf-8?b?Q2Fmw6k=?= == "Café"
        XCTAssertEqual(RFC2047.decode("=?utf-8?b?Q2Fmw6k=?="), "Café")
    }

    func testBase64UpperCaseEncodingMarker() {
        XCTAssertEqual(RFC2047.decode("=?UTF-8?B?Q2Fmw6k=?="), "Café")
    }

    func testBase64EmDash() {
        // =?utf-8?b?4oCU?= == "—"
        XCTAssertEqual(RFC2047.decode("=?utf-8?b?4oCU?="), "—")
    }

    // MARK: - Quoted-printable encoding (Q)

    func testQuotedPrintableUTF8() {
        // =?utf-8?q?caf=C3=A9?= == "café"
        XCTAssertEqual(RFC2047.decode("=?utf-8?q?caf=C3=A9?="), "café")
    }

    func testQuotedPrintableUnderscoreMeansSpace() {
        // =?utf-8?q?Hello_World?= == "Hello World"
        XCTAssertEqual(RFC2047.decode("=?utf-8?q?Hello_World?="), "Hello World")
    }

    func testQuotedPrintableISOLatin1() {
        // =?iso-8859-1?q?caf=E9?= == "café"
        XCTAssertEqual(RFC2047.decode("=?iso-8859-1?q?caf=E9?="), "café")
    }

    /// Q-encoded text whose first byte is non-ASCII begins with `=` (e.g. `=C3` for `Þ`).
    /// The separator after the encoding marker (`Q?`) then directly precedes the `=`,
    /// producing a `?=` substring inside the encoded-text. A naive forward search for the
    /// closing `?=` from after `=?` matches that boundary instead of the real closer.
    /// Regression for the v1.2.2 envelope-decoder gap that surfaced in MailTriage UAT.
    func testQuotedPrintableLeadingNonAscii() {
        XCTAssertEqual(
            RFC2047.decode("=?UTF-8?Q?=C3=9E=C3=B3rd=C3=ADs_Halld=C3=B3ra?="),
            "Þórdís Halldóra"
        )
    }

    /// Same shape as above but with a 4-byte UTF-8 leading sequence (emoji) and a trailing
    /// plain-ASCII literal. Exercises both the closer-ambiguity fix and the literal
    /// continuation past the close.
    func testQuotedPrintableLeadingEmojiWithTrailingPlain() {
        XCTAssertEqual(
            RFC2047.decode("=?utf-8?q?=F0=9F=8E=89?= Welcome aboard!"),
            "🎉 Welcome aboard!"
        )
    }

    // MARK: - Mixed plain and encoded text

    func testEncodedWordWithSurroundingPlainText() {
        XCTAssertEqual(
            RFC2047.decode("Project Kickoff =?utf-8?b?4oCU?= schedule"),
            "Project Kickoff — schedule"
        )
    }

    func testFullEncodedWordWithTrailingPlain() {
        XCTAssertEqual(
            RFC2047.decode("=?utf-8?b?Q2Fmw6kgbWVldGluZw==?= today"),
            "Café meeting today"
        )
    }

    // MARK: - Adjacent encoded words drop intervening whitespace (RFC 2047 §6.2)

    func testAdjacentEncodedWordsSuppressInterveningWhitespace() {
        // Two adjacent encoded words separated by a space — the space should be dropped.
        let input = "=?utf-8?b?SGVsbG8=?= =?utf-8?b?V29ybGQ=?="
        XCTAssertEqual(RFC2047.decode(input), "HelloWorld")
    }

    func testWhitespaceBetweenEncodedAndLiteralIsPreserved() {
        // Encoded word then plain literal: the space stays.
        XCTAssertEqual(
            RFC2047.decode("=?utf-8?b?SGVsbG8=?= world"),
            "Hello world"
        )
    }

    // MARK: - Malformed / unsupported survives untouched

    func testMalformedEncodedWordPassesThrough() {
        // Missing question marks — not a valid encoded word, keep verbatim.
        XCTAssertEqual(RFC2047.decode("=?utf-8?notvalid?="), "=?utf-8?notvalid?=")
    }

    func testUnknownEncodingPassesThrough() {
        // Encoding marker isn't B or Q, leave intact.
        XCTAssertEqual(RFC2047.decode("=?utf-8?x?somedata?="), "=?utf-8?x?somedata?=")
    }

    func testUnterminatedEncodedWordPassesThrough() {
        // No closing ?=, treat the rest as literal.
        XCTAssertEqual(RFC2047.decode("=?utf-8?b?SGVsbG8="), "=?utf-8?b?SGVsbG8=")
    }

    func testInvalidBase64InsideEncodedWordPassesThrough() {
        // The encoded text isn't valid base64; the whole encoded word is passed through verbatim.
        XCTAssertEqual(RFC2047.decode("=?utf-8?b?!!notbase64!!?="), "=?utf-8?b?!!notbase64!!?=")
    }

    // MARK: - Charset coverage

    func testWindows1252CharsetResolves() {
        // Windows-1252 encoded "café" via quoted-printable.
        XCTAssertEqual(RFC2047.decode("=?windows-1252?q?caf=E9?="), "café")
    }

    func testUnknownCharsetFallsBackToUTF8() {
        // Our fallback policy: unknown charset → try UTF-8 anyway. The bytes here happen
        // to be valid UTF-8 ("Hello"), so decoding succeeds via the fallback.
        XCTAssertEqual(RFC2047.decode("=?x-unknown-charset?b?SGVsbG8=?="), "Hello")
    }
}
