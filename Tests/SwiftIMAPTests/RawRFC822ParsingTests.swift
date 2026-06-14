import XCTest
@testable import SwiftIMAP

/// Tests for the raw-RFC822 path: `Envelope(parsingHeaders:)`,
/// `MessageSummary.parse(rfc822:)`, and the internal RFC 2822 date/address
/// parsing they rely on.
final class RawRFC822ParsingTests: XCTestCase {

    // MARK: - Date parsing

    /// The four formats a real-world client must handle, plus the trailing
    /// timezone-comment strip. Each parses to the same instant.
    func testDateParserCoversAllFourFormats() {
        // 2021-10-05 11:03:08 -0400  ==  2021-10-05 15:03:08 UTC
        let expected = Date(timeIntervalSince1970: 1_633_446_188)

        let inputs = [
            "Tue, 05 Oct 2021 11:03:08 -0400",            // weekday, 24h
            "05 Oct 2021 11:03:08 -0400",                 // no weekday, 24h
            "Tue, 05 Oct 2021 11:03:08 am -0400",         // weekday, AM/PM
            "05 Oct 2021 11:03:08 am -0400"               // no weekday, AM/PM
        ]
        for input in inputs {
            XCTAssertEqual(RFC2822.parseDate(input), expected, "format failed: \(input)")
        }
    }

    func testDateParserStripsTrailingComment() {
        let expected = Date(timeIntervalSince1970: 1_633_446_188)
        XCTAssertEqual(RFC2822.parseDate("Tue, 05 Oct 2021 11:03:08 -0400 (EDT)"), expected)
        XCTAssertEqual(RFC2822.parseDate("05 Oct 2021 11:03:08 -0400  (Eastern Daylight Time)"), expected)
    }

    func testDateParserAMPMAfternoon() {
        // 11:27:33 pm +13:00 on 2025-08-12  ==  2025-08-12 10:27:33 UTC
        let expected = Date(timeIntervalSince1970: 1_754_994_453)
        XCTAssertEqual(RFC2822.parseDate("Tue, 12 Aug 2025 11:27:33 pm +13:00"), expected)
    }

    func testDateParserReturnsNilForGarbage() {
        XCTAssertNil(RFC2822.parseDate(""))
        XCTAssertNil(RFC2822.parseDate("not a date"))
        XCTAssertNil(RFC2822.parseDate("2021-10-05T11:03:08Z"))  // ISO 8601, not RFC 2822
    }

    // MARK: - Address-list parsing

    func testAddressListParsesNameAndBareForms() {
        let addresses = RFC2822.parseAddressList(
            "Alice Wonderland <alice@example.com>, bob@example.org, Carol <carol@x.com>"
        )
        XCTAssertEqual(addresses, [
            Address(name: "Alice Wonderland", mailbox: "alice", host: "example.com"),
            Address(name: nil, mailbox: "bob", host: "example.org"),
            Address(name: "Carol", mailbox: "carol", host: "x.com")
        ])
    }

    /// A comma inside a quoted display name must not split the address, and the
    /// surrounding quotes are stripped from the name.
    func testAddressListRespectsQuotedCommaAndStripsQuotes() {
        let addresses = RFC2822.parseAddressList("\"Doe, John\" <john@example.com>")
        XCTAssertEqual(addresses, [Address(name: "Doe, John", mailbox: "john", host: "example.com")])
    }

    /// RFC 2047 encoded display names are decoded.
    func testAddressListDecodesEncodedName() {
        let addresses = RFC2822.parseAddressList("=?UTF-8?Q?J=C3=BCrgen?= <jurgen@example.com>")
        XCTAssertEqual(addresses, [Address(name: "Jürgen", mailbox: "jurgen", host: "example.com")])
    }

    /// A bare group label with no addresses yields nothing (no spurious entry).
    func testAddressListDropsUnparseableEntries() {
        XCTAssertEqual(RFC2822.parseAddressList("Undisclosed recipients:;"), [])
        XCTAssertEqual(RFC2822.parseAddressList(""), [])
        XCTAssertEqual(RFC2822.parseAddressList(nil), [])
    }

    /// An escaped quote inside a quoted display name does not end the quote (so
    /// the comma inside it is not a separator), and is unescaped in the result.
    func testAddressListHandlesEscapedQuotesInName() {
        let addresses = RFC2822.parseAddressList("\"Smith, \\\"Bob\\\"\" <bob@example.com>")
        XCTAssertEqual(addresses, [Address(name: "Smith, \"Bob\"", mailbox: "bob", host: "example.com")])
    }

    /// An RFC 2822 address group is flattened to its member addresses; the group
    /// label and trailing `;` are dropped.
    func testAddressListFlattensGroups() {
        let addresses = RFC2822.parseAddressList("Friends: alice@example.com, Bob <bob@example.org>;")
        XCTAssertEqual(addresses, [
            Address(name: nil, mailbox: "alice", host: "example.com"),
            Address(name: "Bob", mailbox: "bob", host: "example.org")
        ])
    }

    // MARK: - Envelope(parsingHeaders:)

    func testEnvelopeFromHeadersMapsAllFields() {
        let headers = [
            "From": "Alice <alice@example.com>",
            "Sender": "sender@example.com",
            "Reply-To": "Alice Reply <reply@example.com>",
            "To": "bob@example.org, Carol <carol@x.com>",
            "Cc": "cc@example.net",
            "Bcc": "bcc@example.net",
            "Subject": "Hello there",
            "Date": "Tue, 05 Oct 2021 11:03:08 -0400",
            "Message-ID": "<msg-1@example.com>",
            "In-Reply-To": "<parent@example.com>"
        ]
        let envelope = Envelope(parsingHeaders: headers)

        XCTAssertEqual(envelope.subject, "Hello there")
        XCTAssertEqual(envelope.from, [Address(name: "Alice", mailbox: "alice", host: "example.com")])
        XCTAssertEqual(envelope.sender, [Address(name: nil, mailbox: "sender", host: "example.com")])
        XCTAssertEqual(envelope.replyTo, [Address(name: "Alice Reply", mailbox: "reply", host: "example.com")])
        XCTAssertEqual(envelope.to, [
            Address(name: nil, mailbox: "bob", host: "example.org"),
            Address(name: "Carol", mailbox: "carol", host: "x.com")
        ])
        XCTAssertEqual(envelope.cc, [Address(name: nil, mailbox: "cc", host: "example.net")])
        XCTAssertEqual(envelope.bcc, [Address(name: nil, mailbox: "bcc", host: "example.net")])
        XCTAssertEqual(envelope.date, Date(timeIntervalSince1970: 1_633_446_188))
        XCTAssertEqual(envelope.messageId, MessageId(parsing: "msg-1@example.com"))
        XCTAssertEqual(envelope.inReplyTo, MessageId(parsing: "parent@example.com"))
    }

    /// Header names are matched case-insensitively.
    func testEnvelopeFromHeadersIsCaseInsensitive() {
        let envelope = Envelope(parsingHeaders: [
            "from": "alice@example.com",
            "MESSAGE-ID": "<m@example.com>"
        ])
        XCTAssertEqual(envelope.from, [Address(name: nil, mailbox: "alice", host: "example.com")])
        XCTAssertEqual(envelope.messageId, MessageId(parsing: "m@example.com"))
    }

    func testEnvelopeFromHeadersToleratesMissingFields() {
        let envelope = Envelope(parsingHeaders: [:])
        XCTAssertNil(envelope.date)
        XCTAssertNil(envelope.subject)
        XCTAssertNil(envelope.messageId)
        XCTAssertTrue(envelope.from.isEmpty)
        XCTAssertTrue(envelope.to.isEmpty)
    }

    // MARK: - MessageSummary.parse(rfc822:)

    private let fixture = """
    From: Alice <alice@example.com>
    To: Bob <bob@example.org>
    Cc: carol@x.com
    Subject: Round trip
    Date: Tue, 05 Oct 2021 11:03:08 -0400
    Message-ID: <child@example.com>
    In-Reply-To: <parent@example.com>
    References: <grandparent@example.com> <parent@example.com>
    Content-Type: text/plain; charset=utf-8

    Hello, this is the body.
    """.replacingOccurrences(of: "\n", with: "\r\n")

    func testParseRFC822RoundTrip() throws {
        let data = Data(fixture.utf8)
        let summary = try MessageSummary.parse(rfc822: data)

        // Synthesised, since there is no IMAP session.
        XCTAssertEqual(summary.uid, 0)
        XCTAssertEqual(summary.sequenceNumber, 0)
        XCTAssertEqual(summary.size, UInt32(data.count))

        // internalDate from the Date header.
        XCTAssertEqual(summary.internalDate, Date(timeIntervalSince1970: 1_633_446_188))

        let envelope = try XCTUnwrap(summary.envelope)
        XCTAssertEqual(envelope.subject, "Round trip")
        XCTAssertEqual(envelope.from, [Address(name: "Alice", mailbox: "alice", host: "example.com")])
        XCTAssertEqual(envelope.to, [Address(name: "Bob", mailbox: "bob", host: "example.org")])
        XCTAssertEqual(envelope.cc, [Address(name: nil, mailbox: "carol", host: "x.com")])
        XCTAssertEqual(envelope.messageId, MessageId(parsing: "child@example.com"))
        XCTAssertEqual(envelope.inReplyTo, MessageId(parsing: "parent@example.com"))

        // References populated and normalised, oldest first.
        XCTAssertEqual(summary.references, [
            MessageId(parsing: "grandparent@example.com"),
            MessageId(parsing: "parent@example.com")
        ])
    }

    /// A reply threads onto its parent without bracket handling at the call site.
    func testParseRFC822ThreadsByMessageId() throws {
        let summary = try MessageSummary.parse(rfc822: Data(fixture.utf8))
        let parent = try XCTUnwrap(summary.envelope?.inReplyTo)
        XCTAssertTrue(summary.references.contains(parent))
    }

    /// With no Date header, internalDate falls back to roughly now.
    func testParseRFC822FallsBackToNowWithoutDate() throws {
        let noDate = """
        From: alice@example.com
        Subject: No date
        Content-Type: text/plain

        Body.
        """.replacingOccurrences(of: "\n", with: "\r\n")

        let before = Date()
        let summary = try MessageSummary.parse(rfc822: Data(noDate.utf8))
        let after = Date()

        XCTAssertNil(summary.envelope?.date)
        XCTAssertGreaterThanOrEqual(summary.internalDate, before)
        XCTAssertLessThanOrEqual(summary.internalDate, after)
    }

    /// Non-message input (no parseable headers at all) throws.
    func testParseRFC822ThrowsWhenNoHeaders() {
        let data = Data([0xFF, 0xFE, 0x00])  // not UTF-8, no colon-delimited header lines
        XCTAssertThrowsError(try MessageSummary.parse(rfc822: data)) { error in
            guard case IMAPError.parsingError = error else {
                return XCTFail("Expected IMAPError.parsingError, got \(error)")
            }
        }
    }

    /// The envelope survives a body that is not valid UTF-8: header parsing is
    /// decoupled from the body, with an ISO-8859-1 fallback for decoding.
    func testParseRFC822RecoversEnvelopeFromNonUTF8Body() throws {
        var bytes = Data("""
        From: Alice <alice@example.com>
        Subject: Plain subject
        Date: Tue, 05 Oct 2021 11:03:08 -0400

        """.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        bytes.append(0xFF)  // invalid as UTF-8, forces the Latin-1 fallback
        bytes.append(contentsOf: Data("\r\nbody".utf8))

        let summary = try MessageSummary.parse(rfc822: bytes)
        XCTAssertEqual(summary.envelope?.from, [Address(name: "Alice", mailbox: "alice", host: "example.com")])
        XCTAssertEqual(summary.envelope?.subject, "Plain subject")
        XCTAssertEqual(summary.envelope?.date, Date(timeIntervalSince1970: 1_633_446_188))
    }

    /// A leading mbox `From ` envelope line (RFC 4155, emitted by archive
    /// converters) is stripped before header parsing.
    func testParseRFC822StripsMboxPreamble() throws {
        let raw = """
        From archive@example.com Mon Jan  1 00:00:00 2024
        From: Bob <bob@example.org>
        Subject: Archived

        body
        """.replacingOccurrences(of: "\n", with: "\r\n")

        let summary = try MessageSummary.parse(rfc822: Data(raw.utf8))
        XCTAssertEqual(summary.envelope?.from, [Address(name: "Bob", mailbox: "bob", host: "example.org")])
        XCTAssertEqual(summary.envelope?.subject, "Archived")
    }

    /// Folded header lines (RFC 5322 §2.2.3) are unfolded before parsing.
    func testParseRFC822UnfoldsHeaders() throws {
        let raw = """
        From: Alice <alice@example.com>
        References: <a@x.com>
        \t<b@x.com> <c@x.com>
        Subject: Folded

        body
        """.replacingOccurrences(of: "\n", with: "\r\n")

        let summary = try MessageSummary.parse(rfc822: Data(raw.utf8))
        XCTAssertEqual(summary.references, [
            MessageId(parsing: "a@x.com"),
            MessageId(parsing: "b@x.com"),
            MessageId(parsing: "c@x.com")
        ])
    }

    /// A header folded with a leading space (not just a tab) is unfolded.
    func testParseRFC822UnfoldsSpaceFoldedHeader() throws {
        let raw = "From: Alice <alice@example.com>\r\nReferences: <a@x.com>\r\n <b@x.com>\r\nSubject: S\r\n\r\nbody"
        let summary = try MessageSummary.parse(rfc822: Data(raw.utf8))
        XCTAssertEqual(summary.references, [MessageId(parsing: "a@x.com"), MessageId(parsing: "b@x.com")])
    }

    /// Bare-CR line endings (old-Mac / malformed) still split into headers
    /// rather than collapsing into one line.
    func testParseRFC822HandlesBareCRLineEndings() throws {
        let raw = "From: Alice <alice@example.com>\rSubject: CR only\r\rbody"
        let summary = try MessageSummary.parse(rfc822: Data(raw.utf8))
        XCTAssertEqual(summary.envelope?.from, [Address(name: "Alice", mailbox: "alice", host: "example.com")])
        XCTAssertEqual(summary.envelope?.subject, "CR only")
    }

    /// Bare-LF line endings (Unix Maildir) parse without the CRLF normalisation.
    func testParseRFC822HandlesBareLFLineEndings() throws {
        let raw = "From: Alice <alice@example.com>\nSubject: LF only\n\nbody"
        let summary = try MessageSummary.parse(rfc822: Data(raw.utf8))
        XCTAssertEqual(summary.envelope?.from, [Address(name: "Alice", mailbox: "alice", host: "example.com")])
        XCTAssertEqual(summary.envelope?.subject, "LF only")
    }

    /// A repeated field keeps the first occurrence, deterministically.
    func testParseRFC822KeepsFirstOccurrenceOfDuplicateField() throws {
        let raw = "From: alice@example.com\r\nSubject: First\r\nSubject: Second\r\n\r\nbody"
        let summary = try MessageSummary.parse(rfc822: Data(raw.utf8))
        XCTAssertEqual(summary.envelope?.subject, "First")
    }

    /// A non-UTF-8 byte inside a header value (an ISO-8859-1 display name) does
    /// not defeat header parsing.
    func testParseRFC822RecoversHeaderWithNonUTF8Byte() throws {
        var bytes = Data("From: ".utf8)
        bytes.append(0xC9)  // É in ISO-8859-1, invalid as a standalone UTF-8 byte
        bytes.append(contentsOf: Data("ric <eric@example.com>\r\nSubject: S\r\n\r\nbody".utf8))

        let summary = try MessageSummary.parse(rfc822: bytes)
        XCTAssertEqual(summary.envelope?.from.first?.mailbox, "eric")
        XCTAssertEqual(summary.envelope?.from.first?.name, "Éric")
    }

    /// A header-only message with no terminating blank line still parses.
    func testParseRFC822ParsesHeadersWithoutTerminatingBlankLine() throws {
        let raw = "From: alice@example.com\r\nSubject: No body"
        let summary = try MessageSummary.parse(rfc822: Data(raw.utf8))
        XCTAssertEqual(summary.envelope?.from.first?.mailbox, "alice")
        XCTAssertEqual(summary.envelope?.subject, "No body")
    }
}
