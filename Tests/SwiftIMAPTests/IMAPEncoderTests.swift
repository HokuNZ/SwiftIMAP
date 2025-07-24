import XCTest
@testable import SwiftIMAP

final class IMAPEncoderTests: XCTestCase {
    var encoder: IMAPEncoder!
    
    override func setUp() {
        super.setUp()
        encoder = IMAPEncoder()
    }
    
    func testEncodeCapabilityCommand() throws {
        let command = IMAPCommand(tag: "A001", command: .capability)
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A001 CAPABILITY\r\n")
    }
    
    func testEncodeNOOPCommand() throws {
        let command = IMAPCommand(tag: "A002", command: .noop)
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A002 NOOP\r\n")
    }
    
    func testEncodeLogoutCommand() throws {
        let command = IMAPCommand(tag: "A003", command: .logout)
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A003 LOGOUT\r\n")
    }
    
    func testEncodeLoginCommand() throws {
        let command = IMAPCommand(tag: "A004", command: .login(username: "alice", password: "wonderland"))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A004 LOGIN \"alice\" \"wonderland\"\r\n")
    }
    
    func testEncodeLoginCommandWithSpecialCharacters() throws {
        let command = IMAPCommand(tag: "A005", command: .login(username: "user@example.com", password: "pass\"word"))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A005 LOGIN \"user@example.com\" \"pass\\\"word\"\r\n")
    }
    
    func testEncodeSelectCommand() throws {
        let command = IMAPCommand(tag: "A006", command: .select(mailbox: "INBOX"))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A006 SELECT \"INBOX\"\r\n")
    }
    
    func testEncodeExamineCommand() throws {
        let command = IMAPCommand(tag: "A007", command: .examine(mailbox: "Sent Messages"))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A007 EXAMINE \"Sent Messages\"\r\n")
    }
    
    func testEncodeListCommand() throws {
        let command = IMAPCommand(tag: "A008", command: .list(reference: "", pattern: "*"))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A008 LIST \"\" *\r\n")
    }
    
    func testEncodeListCommandWithPattern() throws {
        let command = IMAPCommand(tag: "A009", command: .list(reference: "INBOX", pattern: "%"))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A009 LIST \"INBOX\" %\r\n")
    }
    
    func testEncodeStatusCommand() throws {
        let command = IMAPCommand(tag: "A010", command: .status(
            mailbox: "INBOX",
            items: [.messages, .recent, .uidNext, .uidValidity, .unseen]
        ))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A010 STATUS \"INBOX\" (MESSAGES RECENT UIDNEXT UIDVALIDITY UNSEEN)\r\n")
    }
    
    func testEncodeSearchCommand() throws {
        let command = IMAPCommand(tag: "A011", command: .search(charset: nil, criteria: .all))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A011 SEARCH ALL\r\n")
    }
    
    func testEncodeSearchCommandWithCharset() throws {
        let command = IMAPCommand(tag: "A012", command: .search(charset: "UTF-8", criteria: .from("alice@example.com")))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A012 SEARCH CHARSET UTF-8 FROM \"alice@example.com\"\r\n")
    }
    
    func testEncodeFetchCommand() throws {
        let command = IMAPCommand(tag: "A013", command: .fetch(
            sequence: .single(1),
            items: [.flags, .internalDate, .rfc822Size]
        ))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A013 FETCH 1 (FLAGS INTERNALDATE RFC822.SIZE)\r\n")
    }
    
    func testEncodeFetchCommandWithRange() throws {
        let command = IMAPCommand(tag: "A014", command: .fetch(
            sequence: .range(from: 1, to: 5),
            items: [.uid, .flags]
        ))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A014 FETCH 1:5 (UID FLAGS)\r\n")
    }
    
    func testEncodeFetchCommandWithOpenRange() throws {
        let command = IMAPCommand(tag: "A015", command: .fetch(
            sequence: .range(from: 10, to: nil),
            items: [.full]
        ))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A015 FETCH 10:* FULL\r\n")
    }
    
    func testEncodeStoreCommand() throws {
        let command = IMAPCommand(tag: "A016", command: .store(
            sequence: .single(1),
            flags: IMAPCommand.StoreFlags(action: .add, flags: ["\\Seen", "\\Flagged"]),
            silent: false
        ))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A016 STORE 1 +FLAGS (\\Seen \\Flagged)\r\n")
    }
    
    func testEncodeStoreSilentCommand() throws {
        let command = IMAPCommand(tag: "A017", command: .store(
            sequence: .single(1),
            flags: IMAPCommand.StoreFlags(action: .remove, flags: ["\\Deleted"]),
            silent: true
        ))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A017 STORE 1 -FLAGS.SILENT (\\Deleted)\r\n")
    }
    
    func testEncodeCopyCommand() throws {
        let command = IMAPCommand(tag: "A018", command: .copy(
            sequence: .list([.single(1), .single(3), .range(from: 5, to: 7)]),
            mailbox: "Trash"
        ))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A018 COPY 1,3,5:7 \"Trash\"\r\n")
    }
    
    func testEncodeUIDFetchCommand() throws {
        let command = IMAPCommand(tag: "A019", command: .uid(.fetch(
            sequence: .single(12345),
            items: [.bodySection(section: nil, peek: true)]
        )))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A019 UID FETCH 12345 BODY.PEEK[]\r\n")
    }
    
    func testEncodeComplexSearchCriteria() throws {
        let criteria = IMAPCommand.SearchCriteria.or(
            .from("alice@example.com"),
            .and([
                .subject("Important"),
                .unseen
            ])
        )
        let command = IMAPCommand(tag: "A020", command: .search(charset: nil, criteria: criteria))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A020 SEARCH OR FROM \"alice@example.com\" SUBJECT \"Important\" UNSEEN\r\n")
    }
    
    func testEncodeAuthenticateCommand() throws {
        let command = IMAPCommand(tag: "A021", command: .authenticate(mechanism: "PLAIN", initialResponse: "AGFsaWNlAHdvbmRlcmxhbmQ="))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A021 AUTHENTICATE PLAIN AGFsaWNlAHdvbmRlcmxhbmQ=\r\n")
    }
    
    func testEncodeCreateCommand() throws {
        let command = IMAPCommand(tag: "A022", command: .create(mailbox: "Work/Projects"))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A022 CREATE \"Work/Projects\"\r\n")
    }
    
    func testEncodeDeleteCommand() throws {
        let command = IMAPCommand(tag: "A023", command: .delete(mailbox: "Old Stuff"))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A023 DELETE \"Old Stuff\"\r\n")
    }
    
    func testEncodeRenameCommand() throws {
        let command = IMAPCommand(tag: "A024", command: .rename(from: "Drafts", to: "Draft Messages"))
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A024 RENAME \"Drafts\" \"Draft Messages\"\r\n")
    }
    
    func testEncodeIdleCommand() throws {
        let command = IMAPCommand(tag: "A025", command: .idle)
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "A025 IDLE\r\n")
    }
    
    func testEncodeDoneCommand() throws {
        let command = IMAPCommand(tag: "IGNORED", command: .done)
        let encoded = try encoder.encode(command)
        let result = String(data: encoded, encoding: .utf8)
        
        XCTAssertEqual(result, "DONE\r\n")
    }
    
    func testEncodeUIDFetchWithEnvelope() throws {
        let command = IMAPCommand(
            tag: "A026",
            command: .uid(.fetch(
                sequence: .single(100),
                items: [.uid, .flags, .internalDate, .rfc822Size, .envelope]
            ))
        )
        let encoded = try encoder.encode(command)
        
        let expected = "A026 UID FETCH 100 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)\r\n"
        XCTAssertEqual(String(data: encoded, encoding: .utf8), expected)
    }
    
    func testEncodeUIDSearchCommand() throws {
        let command = IMAPCommand(
            tag: "A027",
            command: .uid(.search(charset: nil, criteria: .all))
        )
        let encoded = try encoder.encode(command)
        
        let expected = "A027 UID SEARCH ALL\r\n"
        XCTAssertEqual(String(data: encoded, encoding: .utf8), expected)
    }
    
    func testEncodeUIDCopyCommand() throws {
        let command = IMAPCommand(
            tag: "A028",
            command: .uid(.copy(sequence: .range(from: 1, to: 10), mailbox: "Archive"))
        )
        let encoded = try encoder.encode(command)
        
        let expected = "A028 UID COPY 1:10 \"Archive\"\r\n"
        XCTAssertEqual(String(data: encoded, encoding: .utf8), expected)
    }
    
    func testEncodeUIDStoreCommand() throws {
        let command = IMAPCommand(
            tag: "A029",
            command: .uid(.store(
                sequence: .single(456),
                flags: IMAPCommand.StoreFlags(action: .add, flags: ["\\Seen"]),
                silent: false
            ))
        )
        let encoded = try encoder.encode(command)
        
        let expected = "A029 UID STORE 456 +FLAGS (\\Seen)\r\n"
        XCTAssertEqual(String(data: encoded, encoding: .utf8), expected)
    }
}