import XCTest
@testable import SwiftIMAP

final class IMAPParserTests: XCTestCase {
    var parser: IMAPParser!
    
    override func setUp() {
        super.setUp()
        parser = IMAPParser()
    }
    
    func testParseOKResponse() throws {
        let input = "A001 OK LOGIN completed\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .tagged(let tag, let status) = responses[0] {
            XCTAssertEqual(tag, "A001")
            if case .ok(let code, let text) = status {
                XCTAssertNil(code)
                XCTAssertEqual(text, "LOGIN completed")
            } else {
                XCTFail("Expected OK status")
            }
        } else {
            XCTFail("Expected tagged response")
        }
    }
    
    func testParseNOResponse() throws {
        let input = "A002 NO LOGIN failed\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .tagged(let tag, let status) = responses[0] {
            XCTAssertEqual(tag, "A002")
            if case .no(let code, let text) = status {
                XCTAssertNil(code)
                XCTAssertEqual(text, "LOGIN failed")
            } else {
                XCTFail("Expected NO status")
            }
        } else {
            XCTFail("Expected tagged response")
        }
    }
    
    func testParseBADResponse() throws {
        let input = "A003 BAD Invalid command\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .tagged(let tag, let status) = responses[0] {
            XCTAssertEqual(tag, "A003")
            if case .bad(let code, let text) = status {
                XCTAssertNil(code)
                XCTAssertEqual(text, "Invalid command")
            } else {
                XCTFail("Expected BAD status")
            }
        } else {
            XCTFail("Expected tagged response")
        }
    }
    
    func testParseCapabilityResponse() throws {
        let input = "* CAPABILITY IMAP4rev1 STARTTLS AUTH=PLAIN AUTH=LOGIN\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .untagged(.capability(let caps)) = responses[0] {
            XCTAssertEqual(caps, ["IMAP4rev1", "STARTTLS", "AUTH=PLAIN", "AUTH=LOGIN"])
        } else {
            XCTFail("Expected CAPABILITY response")
        }
    }
    
    func testParseExistsResponse() throws {
        let input = "* 23 EXISTS\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .untagged(.exists(let count)) = responses[0] {
            XCTAssertEqual(count, 23)
        } else {
            XCTFail("Expected EXISTS response")
        }
    }
    
    func testParseRecentResponse() throws {
        let input = "* 5 RECENT\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .untagged(.recent(let count)) = responses[0] {
            XCTAssertEqual(count, 5)
        } else {
            XCTFail("Expected RECENT response")
        }
    }
    
    func testParseFlagsResponse() throws {
        let input = "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .untagged(.flags(let flags)) = responses[0] {
            XCTAssertEqual(flags, ["\\Answered", "\\Flagged", "\\Deleted", "\\Seen", "\\Draft"])
        } else {
            XCTFail("Expected FLAGS response")
        }
    }
    
    func testParseListResponse() throws {
        let input = "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .untagged(.list(let listResponse)) = responses[0] {
            XCTAssertEqual(listResponse.attributes, ["\\HasNoChildren"])
            XCTAssertEqual(listResponse.delimiter, "/")
            XCTAssertEqual(listResponse.name, "INBOX")
        } else {
            XCTFail("Expected LIST response")
        }
    }
    
    func testParseListResponseWithNilDelimiter() throws {
        let input = "* LIST (\\Noselect) NIL \"\"\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .untagged(.list(let listResponse)) = responses[0] {
            XCTAssertEqual(listResponse.attributes, ["\\Noselect"])
            XCTAssertNil(listResponse.delimiter)
            XCTAssertEqual(listResponse.name, "")
        } else {
            XCTFail("Expected LIST response")
        }
    }

    func testParseListResponseWithLiteralMailbox() throws {
        let input = "* LIST (\\HasNoChildren) \"/\" {5}\r\nINBOX\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        XCTAssertEqual(responses.count, 1)
        if case .untagged(.list(let listResponse)) = responses[0] {
            XCTAssertEqual(listResponse.attributes, ["\\HasNoChildren"])
            XCTAssertEqual(listResponse.delimiter, "/")
            XCTAssertEqual(listResponse.name, "INBOX")
        } else {
            XCTFail("Expected LIST response")
        }
    }

    func testParseQuotedStringWithEscapes() throws {
        let input = "* LIST (\\HasNoChildren) \"/\" \"Folder\\\\\\\"Name\"\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .untagged(.list(let listResponse)) = responses[0] {
            XCTAssertEqual(listResponse.name, "Folder\\\"Name")
        } else {
            XCTFail("Expected LIST response")
        }
    }
    
    func testParseSearchResponse() throws {
        let input = "* SEARCH 2 3 6 9 12 15\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .untagged(.search(let numbers)) = responses[0] {
            XCTAssertEqual(numbers, [2, 3, 6, 9, 12, 15])
        } else {
            XCTFail("Expected SEARCH response")
        }
    }
    
    func testParseEmptySearchResponse() throws {
        let input = "* SEARCH\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .untagged(.search(let numbers)) = responses[0] {
            XCTAssertEqual(numbers, [])
        } else {
            XCTFail("Expected SEARCH response")
        }
    }

    func testParseBodyStructureMultipartFields() throws {
        let input = "* 1 FETCH (BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 1152 23 NIL NIL NIL NIL) (\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"QUOTED-PRINTABLE\" 2048 45 NIL NIL NIL NIL) \"MIXED\" (\"BOUNDARY\" \"abc\") (\"INLINE\" (\"FILENAME\" \"demo\")) (\"EN\" \"US\") \"loc\" (\"EXT\" \"VALUE\")))\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        guard case .untagged(.fetch(_, let attributes)) = responses.first else {
            return XCTFail("Expected FETCH response")
        }

        guard let bodyStructure = attributes.compactMap({
            if case .bodyStructure(let data) = $0 { return data }
            return nil
        }).first else {
            return XCTFail("Expected BODYSTRUCTURE attribute")
        }

        XCTAssertEqual(bodyStructure.subtype, "MIXED")
        XCTAssertEqual(bodyStructure.parameters?["boundary"], "abc")
        XCTAssertEqual(bodyStructure.disposition?.type, "INLINE")
        XCTAssertEqual(bodyStructure.disposition?.parameters?["filename"], "demo")
        XCTAssertEqual(bodyStructure.language ?? [], ["EN", "US"])
        XCTAssertEqual(bodyStructure.location, "loc")
        XCTAssertEqual(bodyStructure.extensions ?? [], ["(EXT VALUE)"])
        XCTAssertEqual(bodyStructure.parts?.count, 2)
    }

    func testParseBodyStructureSinglePartExtensions() throws {
        let input = "* 1 FETCH (BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 12 1 \"md5hash\" (\"ATTACHMENT\" (\"FILENAME\" \"a.txt\")) \"EN\" \"loc\" (\"X\" \"Y\")))\r\n"
        parser.append(Data(input.utf8))

        let responses = try parser.parseResponses()

        guard case .untagged(.fetch(_, let attributes)) = responses.first else {
            return XCTFail("Expected FETCH response")
        }

        guard let bodyStructure = attributes.compactMap({
            if case .bodyStructure(let data) = $0 { return data }
            return nil
        }).first else {
            return XCTFail("Expected BODYSTRUCTURE attribute")
        }

        XCTAssertEqual(bodyStructure.md5, "md5hash")
        XCTAssertEqual(bodyStructure.disposition?.type, "ATTACHMENT")
        XCTAssertEqual(bodyStructure.disposition?.parameters?["filename"], "a.txt")
        XCTAssertEqual(bodyStructure.language ?? [], ["EN"])
        XCTAssertEqual(bodyStructure.location, "loc")
        XCTAssertEqual(bodyStructure.extensions ?? [], ["(X Y)"])
    }
    
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
    
    func testParseStatusResponse() throws {
        let input = "* STATUS INBOX (MESSAGES 231 RECENT 1 UIDNEXT 44292 UIDVALIDITY 1436256798 UNSEEN 0)\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .untagged(.statusResponse(let mailbox, let status)) = responses[0] {
            XCTAssertEqual(mailbox, "INBOX")
            XCTAssertEqual(status.messages, 231)
            XCTAssertEqual(status.recent, 1)
            XCTAssertEqual(status.uidNext, 44292)
            XCTAssertEqual(status.uidValidity, 1436256798)
            XCTAssertEqual(status.unseen, 0)
        } else {
            XCTFail("Expected STATUS response")
        }
    }
    
    func testParseResponseWithCode() throws {
        let input = "A001 OK [UIDVALIDITY 1436256798] SELECT completed\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .tagged(let tag, let status) = responses[0] {
            XCTAssertEqual(tag, "A001")
            if case .ok(let code, let text) = status {
                if case .uidValidity(let uid) = code {
                    XCTAssertEqual(uid, 1436256798)
                } else {
                    XCTFail("Expected UIDVALIDITY code")
                }
                XCTAssertEqual(text, "SELECT completed")
            } else {
                XCTFail("Expected OK status")
            }
        } else {
            XCTFail("Expected tagged response")
        }
    }
    
    func testParseContinuationResponse() throws {
        let input = "+ Ready for additional command text\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .continuation(let text) = responses[0] {
            XCTAssertEqual(text, "Ready for additional command text")
        } else {
            XCTFail("Expected continuation response")
        }
    }
    
    func testParseEmptyContinuationResponse() throws {
        let input = "+\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .continuation(let text) = responses[0] {
            XCTAssertEqual(text, "")
        } else {
            XCTFail("Expected continuation response")
        }
    }
    
    func testParsePreauthWithCapabilityResponseCode() throws {
        let input = "* PREAUTH [CAPABILITY IMAP4rev1 AUTH=PLAIN] Ready\r\n"
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 1)
        if case .untagged(.status(let status)) = responses[0] {
            if case .preauth(let code, let text) = status {
                if case .capability(let caps) = code {
                    XCTAssertEqual(caps, ["IMAP4rev1", "AUTH=PLAIN"])
                } else {
                    XCTFail("Expected CAPABILITY response code")
                }
                XCTAssertEqual(text, "Ready")
            } else {
                XCTFail("Expected PREAUTH status")
            }
        } else {
            XCTFail("Expected status response")
        }
    }
    
    func testParseMultipleResponses() throws {
        let input = """
            * 172 EXISTS\r\n\
            * 1 RECENT\r\n\
            * OK [UNSEEN 12] Message 12 is first unseen\r\n\
            * OK [UIDVALIDITY 3857529045] UIDs valid\r\n\
            * OK [UIDNEXT 4392] Predicted next UID\r\n\
            * FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n\
            * OK [PERMANENTFLAGS (\\Deleted \\Seen \\*)] Limited\r\n\
            A142 OK [READ-WRITE] SELECT completed\r\n
            """
        parser.append(Data(input.utf8))
        
        let responses = try parser.parseResponses()
        
        XCTAssertEqual(responses.count, 8)
        
        if case .untagged(.exists(let count)) = responses[0] {
            XCTAssertEqual(count, 172)
        } else {
            XCTFail("Expected EXISTS response")
        }
        
        if case .untagged(.recent(let count)) = responses[1] {
            XCTAssertEqual(count, 1)
        } else {
            XCTFail("Expected RECENT response")
        }
        
        if case .tagged(let tag, let status) = responses[7] {
            XCTAssertEqual(tag, "A142")
            if case .ok(let code, let text) = status {
                if case .readWrite = code {
                    // Success
                } else {
                    XCTFail("Expected READ-WRITE code")
                }
                XCTAssertEqual(text, "SELECT completed")
            } else {
                XCTFail("Expected OK status")
            }
        } else {
            XCTFail("Expected tagged response")
        }
    }
    
    func testParseInvalidResponse() {
        let input = "INVALID RESPONSE FORMAT\r\n"
        parser.append(Data(input.utf8))
        
        XCTAssertThrowsError(try parser.parseResponses()) { error in
            if let imapError = error as? IMAPError {
                if case .parsingError = imapError {
                    // Success
                } else {
                    XCTFail("Expected parsing error")
                }
            } else {
                XCTFail("Expected IMAPError")
            }
        }
    }
    
    func testParsePartialData() throws {
        let input1 = "* 172 EXI"
        let input2 = "STS\r\n"
        
        parser.append(Data(input1.utf8))
        var responses = try parser.parseResponses()
        XCTAssertEqual(responses.count, 0)
        
        parser.append(Data(input2.utf8))
        responses = try parser.parseResponses()
        XCTAssertEqual(responses.count, 1)
        
        if case .untagged(.exists(let count)) = responses[0] {
            XCTAssertEqual(count, 172)
        } else {
            XCTFail("Expected EXISTS response")
        }
    }
    
    func testParseFetchWithEnvelope() throws {
        // Test with a simple envelope first
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
        
        // All fields should be nil
        XCTAssertNil(envelope.date)
        XCTAssertNil(envelope.subject)
        XCTAssertNil(envelope.from)
    }
    
    func testParseFetchWithNilEnvelopeFields() throws {
        // Test with actual data
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
        XCTAssertNil(envelope.sender) // Should be NIL
        XCTAssertNil(envelope.replyTo) // Should be NIL
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
        
        // Check multiple TO addresses
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
        
        // Check CC address
        XCTAssertEqual(envelope.cc?.count, 1)
        if let cc = envelope.cc?.first {
            XCTAssertEqual(cc.name, "CC User")
        }
    }
}
