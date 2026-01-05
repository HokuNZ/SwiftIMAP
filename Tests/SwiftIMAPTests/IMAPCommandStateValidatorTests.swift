import XCTest
@testable import SwiftIMAP

final class IMAPCommandStateValidatorTests: XCTestCase {
    func testNotAuthenticatedAllowsLoginAndStartTLS() throws {
        try IMAPCommandStateValidator.validate(command: .login(username: "u", password: "p"), state: .notAuthenticated)
        try IMAPCommandStateValidator.validate(command: .starttls, state: .notAuthenticated)
        try IMAPCommandStateValidator.validate(command: .capability, state: .notAuthenticated)
    }

    func testNotAuthenticatedRejectsSelect() {
        XCTAssertThrowsError(
            try IMAPCommandStateValidator.validate(command: .select(mailbox: "INBOX"), state: .notAuthenticated)
        ) { error in
            guard case IMAPError.invalidState = error else {
                XCTFail("Expected invalidState error")
                return
            }
        }
    }

    func testAuthenticatedAllowsListAndAppend() throws {
        try IMAPCommandStateValidator.validate(command: .list(reference: "", pattern: "*"), state: .authenticated)
        try IMAPCommandStateValidator.validate(
            command: .append(mailbox: "INBOX", flags: nil, date: nil, data: Data()),
            state: .authenticated
        )
    }

    func testAuthenticatedRejectsFetch() {
        XCTAssertThrowsError(
            try IMAPCommandStateValidator.validate(
                command: .fetch(sequence: .single(1), items: [.uid]),
                state: .authenticated
            )
        ) { error in
            guard case IMAPError.invalidState = error else {
                XCTFail("Expected invalidState error")
                return
            }
        }
    }

    func testSelectedAllowsFetchAndUID() throws {
        try IMAPCommandStateValidator.validate(
            command: .fetch(sequence: .single(1), items: [.uid]),
            state: .selected
        )
        try IMAPCommandStateValidator.validate(
            command: .uid(.search(charset: nil, criteria: .all)),
            state: .selected
        )
    }
}
