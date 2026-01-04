import XCTest
@testable import SwiftIMAP

extension IMAPParserTests {
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
}
