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
            state: .selected(readOnly: false)
        )
        try IMAPCommandStateValidator.validate(
            command: .uid(.search(charset: nil, criteria: .all)),
            state: .selected(readOnly: false)
        )
    }

    func testSelectedReadOnlyRejectsWriteCommands() {
        XCTAssertThrowsError(
            try IMAPCommandStateValidator.validate(
                command: .store(sequence: .single(1), flags: IMAPCommand.StoreFlags(action: .add, flags: ["\\Seen"]), silent: false),
                state: .selected(readOnly: true)
            )
        )
        XCTAssertThrowsError(
            try IMAPCommandStateValidator.validate(command: .expunge, state: .selected(readOnly: true))
        )
        XCTAssertThrowsError(
            try IMAPCommandStateValidator.validate(
                command: .move(sequence: .single(1), mailbox: "Archive"),
                state: .selected(readOnly: true)
            )
        )
        XCTAssertThrowsError(
            try IMAPCommandStateValidator.validate(
                command: .uid(.store(sequence: .single(1), flags: IMAPCommand.StoreFlags(action: .add, flags: ["\\Seen"]), silent: false)),
                state: .selected(readOnly: true)
            )
        )
        XCTAssertThrowsError(
            try IMAPCommandStateValidator.validate(
                command: .uid(.expunge(sequence: .single(1))),
                state: .selected(readOnly: true)
            )
        )
        XCTAssertThrowsError(
            try IMAPCommandStateValidator.validate(
                command: .uid(.move(sequence: .single(1), mailbox: "Archive")),
                state: .selected(readOnly: true)
            )
        )
    }

    func testSelectedReadOnlyAllowsSafeCommands() throws {
        try IMAPCommandStateValidator.validate(command: .fetch(sequence: .single(1), items: [.uid]), state: .selected(readOnly: true))
        try IMAPCommandStateValidator.validate(command: .search(charset: nil, criteria: .all), state: .selected(readOnly: true))
        try IMAPCommandStateValidator.validate(command: .copy(sequence: .single(1), mailbox: "Archive"), state: .selected(readOnly: true))
        try IMAPCommandStateValidator.validate(command: .uid(.fetch(sequence: .single(1), items: [.uid])), state: .selected(readOnly: true))
        try IMAPCommandStateValidator.validate(command: .uid(.search(charset: nil, criteria: .all)), state: .selected(readOnly: true))
        try IMAPCommandStateValidator.validate(command: .uid(.copy(sequence: .single(1), mailbox: "Archive")), state: .selected(readOnly: true))
    }
}
