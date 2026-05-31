import XCTest
@testable import SwiftIMAP

final class IMAPServerResponseTests: XCTestCase {
    func testLineReconstructsStatusCodeAndText() {
        let response = IMAPServerResponse(
            status: .no,
            code: .tryCreate,
            text: "Mailbox does not exist",
            commandName: "UID MOVE"
        )
        XCTAssertEqual(response.line, "NO [TRYCREATE] Mailbox does not exist")
    }

    func testLineWithoutCode() {
        let response = IMAPServerResponse(status: .bad, code: nil, text: "Syntax error", commandName: "FETCH")
        XCTAssertEqual(response.line, "BAD Syntax error")
    }

    func testLineWithCodeAndNoText() {
        let response = IMAPServerResponse(status: .no, code: .parse, text: nil, commandName: "FETCH")
        XCTAssertEqual(response.line, "NO [PARSE]")
    }

    func testLineRendersOtherCodeWithValue() {
        let response = IMAPServerResponse(
            status: .no,
            code: .other("BADURL", "/bad/url"),
            text: "Bad URL",
            commandName: "APPEND"
        )
        XCTAssertEqual(response.line, "NO [BADURL /bad/url] Bad URL")
    }

    func testCodeName() {
        XCTAssertEqual(IMAPServerResponse(status: .no, code: .tryCreate, text: nil, commandName: "X").codeName, "TRYCREATE")
        XCTAssertEqual(IMAPServerResponse(status: .no, code: .other("OVERQUOTA", nil), text: nil, commandName: "X").codeName, "OVERQUOTA")
        XCTAssertNil(IMAPServerResponse(status: .no, code: nil, text: "x", commandName: "X").codeName)
    }

    func testSemanticAccessors() {
        let nonexistent = IMAPServerResponse(status: .no, code: .other("NONEXISTENT", nil), text: nil, commandName: "UID MOVE")
        XCTAssertTrue(nonexistent.isMailboxNotFound)
        XCTAssertFalse(nonexistent.isOverQuota)

        let tryCreate = IMAPServerResponse(status: .no, code: .tryCreate, text: nil, commandName: "UID COPY")
        XCTAssertTrue(tryCreate.isMailboxNotFound)

        let overQuota = IMAPServerResponse(status: .no, code: .other("OVERQUOTA", nil), text: nil, commandName: "APPEND")
        XCTAssertTrue(overQuota.isOverQuota)

        let noPerm = IMAPServerResponse(status: .no, code: .other("NOPERM", nil), text: nil, commandName: "UID STORE")
        XCTAssertTrue(noPerm.isPermissionDenied)

        let authFail = IMAPServerResponse(status: .no, code: .other("AUTHENTICATIONFAILED", nil), text: nil, commandName: "LOGIN")
        XCTAssertTrue(authFail.isAuthenticationFailure)

        let plain = IMAPServerResponse(status: .no, code: nil, text: "denied", commandName: "UID MOVE")
        XCTAssertFalse(plain.isMailboxNotFound)
        XCTAssertFalse(plain.isPermissionDenied)
    }
}
