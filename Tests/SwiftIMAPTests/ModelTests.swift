import XCTest
@testable import SwiftIMAP

final class ModelTests: XCTestCase {

    /// Build a MessageId from a known-good bare value (test convenience).
    private func mid(_ value: String) -> MessageId { MessageId(parsing: value)! }
    
    func testMailboxCreation() {
        let mailbox = Mailbox(
            name: "INBOX",
            attributes: [.hasNoChildren, .marked],
            delimiter: "/"
        )
        
        XCTAssertEqual(mailbox.name, "INBOX")
        XCTAssertTrue(mailbox.attributes.contains(.hasNoChildren))
        XCTAssertTrue(mailbox.attributes.contains(.marked))
        XCTAssertEqual(mailbox.delimiter, "/")
        XCTAssertTrue(mailbox.isSelectable)
    }
    
    func testMailboxNotSelectable() {
        let mailbox = Mailbox(
            name: "NonSelectable",
            attributes: [.noselect],
            delimiter: nil
        )
        
        XCTAssertFalse(mailbox.isSelectable)
    }
    
    func testAddressFormatting() {
        let address1 = Address(
            name: "Alice Wonderland",
            mailbox: "alice",
            host: "example.com"
        )
        
        XCTAssertEqual(address1.emailAddress, "alice@example.com")
        XCTAssertEqual(address1.displayName, "Alice Wonderland <alice@example.com>")
        
        let address2 = Address(
            name: nil,
            mailbox: "bob",
            host: "example.org"
        )
        
        XCTAssertEqual(address2.emailAddress, "bob@example.org")
        XCTAssertEqual(address2.displayName, "bob@example.org")
    }
    
    func testBodyStructureMimeType() {
        let bodyStructure = BodyStructure(
            type: "TEXT",
            subtype: "PLAIN",
            parameters: ["charset": "UTF-8"],
            id: nil,
            description: nil,
            encoding: "7BIT",
            size: 1234,
            parts: []
        )
        
        XCTAssertEqual(bodyStructure.mimeType, "text/plain")
        XCTAssertFalse(bodyStructure.isMultipart)
    }
    
    func testMultipartBodyStructure() {
        let bodyStructure = BodyStructure(
            type: "MULTIPART",
            subtype: "MIXED",
            parameters: [:],
            id: nil,
            description: nil,
            encoding: "7BIT",
            size: 0,
            parts: []
        )
        
        XCTAssertEqual(bodyStructure.mimeType, "multipart/mixed")
        XCTAssertTrue(bodyStructure.isMultipart)
    }
    
    func testMessageSummaryCreation() {
        let date = Date()
        let envelope = Envelope(
            date: date,
            subject: "Test Subject",
            from: [Address(name: "Sender", mailbox: "sender", host: "example.com")],
            sender: [],
            replyTo: [],
            to: [Address(name: nil, mailbox: "recipient", host: "example.com")],
            cc: [],
            bcc: [],
            inReplyTo: nil,
            messageId: mid("12345@example.com")
        )
        
        let summary = MessageSummary(
            uid: 12345,
            sequenceNumber: 42,
            flags: [.seen, .answered],
            internalDate: date,
            size: 2048,
            envelope: envelope
        )
        
        XCTAssertEqual(summary.uid, 12345)
        XCTAssertEqual(summary.sequenceNumber, 42)
        XCTAssertTrue(summary.flags.contains(.seen))
        XCTAssertTrue(summary.flags.contains(.answered))
        XCTAssertEqual(summary.internalDate, date)
        XCTAssertEqual(summary.size, 2048)
        XCTAssertNotNil(summary.envelope)
        XCTAssertEqual(summary.envelope?.subject, "Test Subject")
    }

    /// The model snapshots are Equatable so consumers can diff and assert
    /// against whole values: MessageSummary, Envelope, BodyStructure.
    func testModelEquatableConformance() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func makeSummary(subject: String) -> MessageSummary {
            MessageSummary(
                uid: 1,
                sequenceNumber: 1,
                flags: [.seen],
                keywords: ["@Triaged"],
                internalDate: date,
                size: 100,
                envelope: Envelope(date: date, subject: subject,
                                   from: [Address(name: "A", mailbox: "a", host: "x.com")]),
                references: [mid("r1@x.com")]
            )
        }

        XCTAssertEqual(makeSummary(subject: "Same"), makeSummary(subject: "Same"))
        XCTAssertNotEqual(makeSummary(subject: "One"), makeSummary(subject: "Two"))

        // Envelope: two independently-built instances with equal inputs compare
        // equal (incl. the derived *Entries), and differ when a field differs.
        func makeEnvelope(subject: String) -> Envelope {
            Envelope(date: date, subject: subject,
                     from: [Address(name: "A", mailbox: "a", host: "x.com")],
                     to: [Address(name: nil, mailbox: "t", host: "x.com")])
        }
        XCTAssertEqual(makeEnvelope(subject: "S"), makeEnvelope(subject: "S"))
        XCTAssertNotEqual(makeEnvelope(subject: "S"), makeEnvelope(subject: "T"))

        let structure = BodyStructure(type: "text", subtype: "plain", encoding: "7bit", size: 10)
        XCTAssertEqual(structure, BodyStructure(type: "text", subtype: "plain", encoding: "7bit", size: 10))
        XCTAssertNotEqual(structure, BodyStructure(type: "text", subtype: "html", encoding: "7bit", size: 10))
    }

    /// MessageId canonicalises to the bare form, so bracketed and bare framings
    /// of the same identifier compare equal — the property that makes threading
    /// comparisons bracket-safe.
    func testMessageIdNormalisationAndEquality() {
        XCTAssertEqual(MessageId(parsing: "<a@x.com>"), mid("a@x.com"))
        XCTAssertEqual(MessageId(parsing: "  <a@x.com> "), MessageId(parsing: "a@x.com"))
        XCTAssertEqual(MessageId(parsing: "<a@x.com>")?.value, "a@x.com")
        XCTAssertEqual(mid("a@x.com").bracketed, "<a@x.com>")
        XCTAssertNil(MessageId(parsing: "   "))
        XCTAssertNil(MessageId(parsing: "<>"))

        // Malformed half-bracketed tokens still canonicalise to the bare id
        // (brackets stripped independently), so threading still matches.
        XCTAssertEqual(MessageId(parsing: "<a@x.com"), mid("a@x.com"))
        XCTAssertEqual(MessageId(parsing: "a@x.com>"), mid("a@x.com"))
        // A lone bracket has no identity and is dropped.
        XCTAssertNil(MessageId(parsing: "<"))
        XCTAssertNil(MessageId(parsing: ">"))
    }

    /// MessageId.parseList tokenises a raw References header into ordered,
    /// normalised identifiers, accepting space or comma separators and dropping
    /// empty tokens.
    func testMessageIdParseList() {
        XCTAssertEqual(MessageId.parseList("<a@x.com> <b@y.com>"),
                       [mid("a@x.com"), mid("b@y.com")])
        XCTAssertEqual(MessageId.parseList("<a@x.com>,<b@y.com>"),
                       [mid("a@x.com"), mid("b@y.com")])
        XCTAssertEqual(MessageId.parseList("  <only@x.com>  "), [mid("only@x.com")])
        XCTAssertEqual(MessageId.parseList("bare@x.com"), [mid("bare@x.com")])
        XCTAssertEqual(MessageId.parseList("   "), [])
        // Empty/garbage tokens between valid ones are dropped; order is preserved.
        XCTAssertEqual(MessageId.parseList("<a@x.com> <> <b@x.com>"),
                       [mid("a@x.com"), mid("b@x.com")])
    }

    /// Threading is bracket-safe by construction: a reply's inReplyTo and the
    /// parent's messageId compare equal regardless of how each was framed.
    func testThreadingComparisonIsBracketSafe() {
        let parentID = MessageId(parsing: "<parent@x.com>")!          // from ENVELOPE (bracketed)
        let reply = Envelope(inReplyTo: MessageId(parsing: "parent@x.com"),  // however framed
                             messageId: mid("child@x.com"))
        XCTAssertEqual(reply.inReplyTo, parentID)
        XCTAssertTrue([parentID].contains(reply.inReplyTo!))
    }

    func testSequenceSetStringValue() {
        let single = IMAPCommand.SequenceSet.single(42)
        XCTAssertEqual(single.stringValue, "42")
        
        let range = IMAPCommand.SequenceSet.range(from: 10, to: 20)
        XCTAssertEqual(range.stringValue, "10:20")
        
        let openRange = IMAPCommand.SequenceSet.range(from: 100, to: nil)
        XCTAssertEqual(openRange.stringValue, "100:*")

        let last = IMAPCommand.SequenceSet.last
        XCTAssertEqual(last.stringValue, "*")

        let lastRange = IMAPCommand.SequenceSet.rangeFromLast(to: 7)
        XCTAssertEqual(lastRange.stringValue, "*:7")
        
        let list = IMAPCommand.SequenceSet.list([
            .single(1),
            .single(3),
            .range(from: 5, to: 7),
            .single(10)
        ])
        XCTAssertEqual(list.stringValue, "1,3,5:7,10")
    }
    
    func testIMAPConfigurationDefaults() {
        let config = IMAPConfiguration(
            hostname: "imap.example.com",
            authMethod: .login(username: "user", password: "pass")
        )
        
        XCTAssertEqual(config.hostname, "imap.example.com")
        XCTAssertEqual(config.port, 993)
        XCTAssertEqual(config.connectionTimeout, 30)
        XCTAssertEqual(config.commandTimeout, 60)
        
        if case .requireTLS = config.tlsMode {
            // Success
        } else {
            XCTFail("Expected requireTLS as default")
        }
        
        if case .login(let username, let password) = config.authMethod {
            XCTAssertEqual(username, "user")
            XCTAssertEqual(password, "pass")
        } else {
            XCTFail("Expected login auth method")
        }
    }
}
