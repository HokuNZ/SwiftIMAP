import XCTest
@testable import SwiftIMAP

extension IMAPParserTests {
    func testParseFetchResponse() throws {
        let input = "* 12 FETCH (UID 234 FLAGS (\\Seen))\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .untagged(.fetch(let seqNum, let attributes)) = responses[0] {
            XCTAssertEqual(seqNum, 12)
            XCTAssertEqual(attributes.count, 2)

            if case .uid(let uid) = attributes[0] {
                XCTAssertEqual(uid, 234)
            } else {
                XCTFail("Expected UID attribute")
            }

            if case .flags(let flags) = attributes[1] {
                XCTAssertEqual(flags, ["\\Seen"])
            } else {
                XCTFail("Expected FLAGS attribute")
            }
        } else {
            XCTFail("Expected FETCH response")
        }
    }

    func testParseFetchWithEnvelope() throws {
        let input = "* 1 FETCH (ENVELOPE (NIL NIL NIL NIL NIL NIL NIL NIL NIL NIL))\r\nA001 OK\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()
        XCTAssertEqual(responses.count, 2)

        guard case .untagged(.fetch(let seqNum, let attributes)) = responses[0] else {
            XCTFail("Expected untagged FETCH response")
            return
        }

        XCTAssertEqual(seqNum, 1)
        XCTAssertEqual(attributes.count, 1)

        guard case .envelope(let envelope) = attributes[0] else {
            XCTFail("Expected ENVELOPE attribute")
            return
        }

        XCTAssertNil(envelope.date)
        XCTAssertNil(envelope.subject)
        XCTAssertNil(envelope.from)
    }

    func testParseFetchWithNilEnvelopeFields() throws {
        let input = "* 2 FETCH (ENVELOPE (\"Mon, 7 Feb 1994 21:52:25 -0800\" \"Test\" ((\"Terry Gray\" NIL \"gray\" \"cac.washington.edu\")) NIL NIL ((\"Terry Gray\" NIL \"gray\" \"cac.washington.edu\")) NIL NIL NIL \"<B27397-0100000@cac.washington.edu>\"))\r\nA001 OK Fetch completed\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()
        XCTAssertEqual(responses.count, 2)

        guard case .untagged(.fetch(let seqNum, let attributes)) = responses[0] else {
            XCTFail("Expected untagged FETCH response")
            return
        }

        XCTAssertEqual(seqNum, 2)
        XCTAssertEqual(attributes.count, 1)

        guard case .envelope(let envelope) = attributes[0] else {
            XCTFail("Expected ENVELOPE attribute")
            return
        }

        XCTAssertEqual(envelope.date, "Mon, 7 Feb 1994 21:52:25 -0800")
        XCTAssertEqual(envelope.subject, "Test")
        XCTAssertNil(envelope.sender)
        XCTAssertNil(envelope.replyTo)
        XCTAssertEqual(envelope.from?.count, 1)
        XCTAssertEqual(envelope.to?.count, 1)
    }

    func testParseFetchWithMultipleAddresses() throws {
        let input = "* 3 FETCH (ENVELOPE (NIL \"Multiple Recipients\" ((\"Sender\" NIL \"sender\" \"example.com\")) NIL NIL ((\"First\" NIL \"first\" \"example.org\") (\"Second\" NIL \"second\" \"example.net\")) ((\"CC User\" NIL \"cc\" \"example.com\")) NIL NIL NIL))\r\nA001 OK Fetch completed\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        guard case .untagged(.fetch(_, let attributes)) = responses[0] else {
            XCTFail("Expected untagged FETCH response")
            return
        }

        guard case .envelope(let envelope) = attributes[0] else {
            XCTFail("Expected ENVELOPE attribute")
            return
        }

        XCTAssertEqual(envelope.subject, "Multiple Recipients")
        XCTAssertEqual(envelope.to?.count, 2)
        if let firstTo = envelope.to?[0] {
            XCTAssertEqual(firstTo.name, "First")
            XCTAssertEqual(firstTo.mailbox, "first")
            XCTAssertEqual(firstTo.host, "example.org")
        }
        if let secondTo = envelope.to?[1] {
            XCTAssertEqual(secondTo.name, "Second")
            XCTAssertEqual(secondTo.mailbox, "second")
            XCTAssertEqual(secondTo.host, "example.net")
        }

        XCTAssertEqual(envelope.cc?.count, 1)
        if let cc = envelope.cc?.first {
            XCTAssertEqual(cc.name, "CC User")
        }
    }

    func testParseEnvelopeWithBinaryLiteralSubject() throws {
        let header = "* 1 FETCH (ENVELOPE (NIL {3}\r\n"
        let literal = Data([0xFF, 0x00, 0x41])
        let trailer = " NIL NIL NIL NIL NIL NIL NIL NIL))\r\nA001 OK\r\n"

        parser.append(header.data(using: .utf8)!)
        parser.append(literal)
        parser.append(trailer.data(using: .utf8)!)

        let responses = try parser.parseResponses()
        XCTAssertEqual(responses.count, 2)

        guard case .untagged(.fetch(_, let attributes)) = responses[0] else {
            XCTFail("Expected FETCH response")
            return
        }

        guard case .envelope(let envelope) = attributes.first else {
            XCTFail("Expected ENVELOPE attribute")
            return
        }

        XCTAssertEqual(envelope.rawSubject, literal)
        XCTAssertEqual(envelope.subject, String(data: literal, encoding: .isoLatin1))
    }
}
