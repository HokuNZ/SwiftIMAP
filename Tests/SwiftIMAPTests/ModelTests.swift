import XCTest
@testable import SwiftIMAP

final class ModelTests: XCTestCase {
    
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
            messageID: "<12345@example.com>"
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
    
    func testSequenceSetStringValue() {
        let single = IMAPCommand.SequenceSet.single(42)
        XCTAssertEqual(single.stringValue, "42")
        
        let range = IMAPCommand.SequenceSet.range(from: 10, to: 20)
        XCTAssertEqual(range.stringValue, "10:20")
        
        let openRange = IMAPCommand.SequenceSet.range(from: 100, to: nil)
        XCTAssertEqual(openRange.stringValue, "100:*")
        
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