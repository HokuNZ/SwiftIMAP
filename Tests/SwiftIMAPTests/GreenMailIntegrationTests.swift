import XCTest
@testable import SwiftIMAP

final class GreenMailIntegrationTests: XCTestCase {
    private struct Config {
        let host: String
        let port: Int
        let username: String
        let password: String
        let required: Bool
    }
    
    private var config: Config?
    
    override func setUp() async throws {
        try await super.setUp()
        
        let env = ProcessInfo.processInfo.environment
        if env["CI"] != nil && env["GREENMAIL_ENABLED"] != "1" {
            throw XCTSkip("GreenMail integration tests are disabled in CI unless GREENMAIL_ENABLED=1")
        }
        
        config = Self.loadConfig()
        if config == nil {
            throw XCTSkip("Set GREENMAIL_HOST (or run scripts/run-greenmail-tests.sh) to enable GreenMail tests")
        }
    }
    
    func testConnectCapabilityAndInbox() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }
        
        let capabilities = try await client.capability()
        XCTAssertTrue(capabilities.contains("IMAP4rev1"))
        
        let mailboxes = try await client.listMailboxes()
        XCTAssertTrue(mailboxes.contains { $0.name.uppercased() == "INBOX" })
        
        _ = try await client.selectMailbox("INBOX")
    }

    func testSearchFlagMoveAndDelete() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }

        let targetMailbox = makeMailboxName(prefix: "Move")
        try await client.createMailbox(targetMailbox)
        defer { Task { try? await client.deleteMailbox(targetMailbox) } }

        let subject = "GreenMail Subject \(UUID().uuidString.prefix(8))"
        let bodyToken = "Body-\(UUID().uuidString.prefix(8))"
        let message = makeMessage(subject: subject, body: bodyToken)

        try await client.appendMessage(message, to: "INBOX")

        let subjectMatches = try await client.searchMessagesBySubject(subject, in: "INBOX")
        XCTAssertFalse(subjectMatches.isEmpty)
        guard let uid = subjectMatches.first?.uid else {
            XCTFail("Expected UID from subject search")
            return
        }

        let textMatches = try await client.searchMessagesByText(bodyToken, in: "INBOX")
        XCTAssertTrue(textMatches.contains { $0.uid == uid })

        try await client.storeFlags(uid: uid, in: "INBOX", flags: [.flagged], action: .add)
        let flagged = try await client.searchFlaggedMessages(in: "INBOX")
        XCTAssertTrue(flagged.contains { $0.uid == uid })

        try await client.moveMessage(uid: uid, from: "INBOX", to: targetMailbox)
        try? await client.expunge(mailbox: "INBOX")

        let moved = try await client.searchMessages(in: targetMailbox, criteria: .all)
        XCTAssertFalse(moved.isEmpty)
        if let movedUid = moved.first?.uid {
            try await client.deleteMessage(uid: movedUid, in: targetMailbox)
        }
    }

    func testAppendFetchFlagsAndBody() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }

        let mailbox = makeMailboxName(prefix: "Append")
        try await client.createMailbox(mailbox)
        defer { Task { try? await client.deleteMailbox(mailbox) } }

        let subject = "GreenMail Append \(UUID().uuidString.prefix(8))"
        let bodyToken = "AppendBody-\(UUID().uuidString.prefix(8))"
        let now = Date()
        let message = makeMessage(subject: subject, body: bodyToken, date: now)

        try await client.appendMessage(message, to: mailbox, flags: [.seen, .flagged], date: now)

        let matches = try await client.searchMessagesBySubject(subject, in: mailbox)
        XCTAssertEqual(matches.count, 1)
        guard let summary = matches.first else {
            XCTFail("Expected message summary from subject search")
            return
        }

        XCTAssertEqual(summary.envelope?.subject, subject)
        XCTAssertTrue(summary.flags.contains(.seen))
        XCTAssertTrue(summary.flags.contains(.flagged))
        XCTAssertLessThan(abs(summary.internalDate.timeIntervalSince(now)), 120)

        let bodyData = try await client.fetchMessageBody(uid: summary.uid, in: mailbox)
        let bodyString = bodyData.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertNotNil(bodyString)
        XCTAssertTrue(bodyString?.contains(bodyToken) ?? false)

        try await client.storeFlags(uid: summary.uid, in: mailbox, flags: [.answered], action: .add, silent: true)
        let answered = try await client.searchMessages(in: mailbox, criteria: .answered)
        XCTAssertTrue(answered.contains { $0.uid == summary.uid })

        try await client.markAsUnread(uid: summary.uid, in: mailbox)
        let unread = try await client.searchUnreadMessages(in: mailbox)
        XCTAssertTrue(unread.contains { $0.uid == summary.uid })

        try await client.markAsRead(uid: summary.uid, in: mailbox)
        let unreadAfter = try await client.searchUnreadMessages(in: mailbox)
        XCTAssertFalse(unreadAfter.contains { $0.uid == summary.uid })
    }

    func testMailboxStatusAndFetchBySequence() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }

        let mailbox = makeMailboxName(prefix: "Status")
        try await client.createMailbox(mailbox)
        defer { Task { try? await client.deleteMailbox(mailbox) } }

        let subject = "GreenMail Status \(UUID().uuidString.prefix(8))"
        let message = makeMessage(subject: subject, body: "StatusBody")
        try await client.appendMessage(message, to: mailbox)

        let status = try await client.mailboxStatus(mailbox)
        XCTAssertGreaterThanOrEqual(status.messages, 1)
        XCTAssertGreaterThan(status.uidNext, 0)
        XCTAssertGreaterThan(status.uidValidity, 0)

        let sequenceNumbers = try await client.listMessages(in: mailbox)
        guard let sequenceNumber = sequenceNumbers.first else {
            XCTFail("Expected message sequence number")
            return
        }

        let summary = try await client.fetchMessageBySequence(sequenceNumber: sequenceNumber, in: mailbox)
        XCTAssertEqual(summary?.envelope?.subject, subject)
    }

    func testKeywordLabelSearchAndClear() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }

        let mailbox = makeMailboxName(prefix: "Labels")
        try await client.createMailbox(mailbox)
        defer { Task { try? await client.deleteMailbox(mailbox) } }

        let subject = "GreenMail Label \(UUID().uuidString.prefix(8))"
        let message = makeMessage(subject: subject, body: "LabelBody")
        try await client.appendMessage(message, to: mailbox)

        let matches = try await client.searchMessagesBySubject(subject, in: mailbox)
        guard let uid = matches.first?.uid else {
            XCTFail("Expected UID from subject search")
            return
        }

        let keyword = "Label\(UUID().uuidString.prefix(6))"
        try await client.storeFlags(uid: uid, in: mailbox, flags: [keyword], action: .add)

        let keywordMatches = try await client.searchMessages(in: mailbox, criteria: .keyword(keyword))
        XCTAssertTrue(keywordMatches.contains { $0.uid == uid })

        try await client.storeFlags(uid: uid, in: mailbox, flags: [keyword], action: .remove, silent: true)

        let keywordRemoved = try await client.searchMessages(in: mailbox, criteria: .keyword(keyword))
        XCTAssertFalse(keywordRemoved.contains { $0.uid == uid })

        let unkeywordMatches = try await client.searchMessages(in: mailbox, criteria: .unkeyword(keyword))
        XCTAssertTrue(unkeywordMatches.contains { $0.uid == uid })
    }

    func testDeleteMessagesConvenience() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }

        let mailbox = makeMailboxName(prefix: "Delete")
        try await client.createMailbox(mailbox)
        defer { Task { try? await client.deleteMailbox(mailbox) } }

        let subject = "GreenMail Delete \(UUID().uuidString.prefix(8))"
        let messageA = makeMessage(subject: subject, body: "DeleteBodyA")
        let messageB = makeMessage(subject: subject, body: "DeleteBodyB")

        try await client.appendMessage(messageA, to: mailbox)
        try await client.appendMessage(messageB, to: mailbox)

        let matches = try await client.searchMessagesBySubject(subject, in: mailbox)
        XCTAssertEqual(matches.count, 2)

        let uids = matches.map(\.uid)
        try await client.deleteMessages(uids: uids, in: mailbox)

        let remaining = try await client.searchMessagesBySubject(subject, in: mailbox)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCopyAndRenameMailbox() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }

        let sourceMailbox = makeMailboxName(prefix: "Source")
        let destinationMailbox = makeMailboxName(prefix: "Dest")
        let renamedMailbox = makeMailboxName(prefix: "Renamed")

        try await client.createMailbox(sourceMailbox)
        try await client.createMailbox(destinationMailbox)
        defer {
            Task {
                try? await client.deleteMailbox(sourceMailbox)
                try? await client.deleteMailbox(destinationMailbox)
                try? await client.deleteMailbox(renamedMailbox)
            }
        }

        let subject = "GreenMail Copy \(UUID().uuidString.prefix(8))"
        let bodyToken = "CopyBody-\(UUID().uuidString.prefix(8))"
        let message = makeMessage(subject: subject, body: bodyToken)

        try await client.appendMessage(message, to: sourceMailbox)

        let matches = try await client.searchMessagesBySubject(subject, in: sourceMailbox)
        guard let uid = matches.first?.uid else {
            XCTFail("Expected UID from source mailbox search")
            return
        }

        try await client.copyMessage(uid: uid, from: sourceMailbox, to: destinationMailbox)

        let copied = try await client.searchMessagesBySubject(subject, in: destinationMailbox)
        XCTAssertFalse(copied.isEmpty)

        try await client.renameMailbox(from: destinationMailbox, to: renamedMailbox)

        let renamed = try await client.searchMessagesBySubject(subject, in: renamedMailbox)
        XCTAssertFalse(renamed.isEmpty)
    }

    func testSearchByFromToAndSince() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }

        let mailbox = makeMailboxName(prefix: "Search")
        try await client.createMailbox(mailbox)
        defer { Task { try? await client.deleteMailbox(mailbox) } }

        let now = Date()
        let oldDate = Calendar.current.date(byAdding: .day, value: -2, to: now) ?? now
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now

        let oldFrom = "alice@example.com"
        let oldTo = "bob@example.com"
        let newFrom = "carol@example.com"
        let newTo = "dave@example.com"

        let oldSubject = "GreenMail Search Old \(UUID().uuidString.prefix(8))"
        let newSubject = "GreenMail Search New \(UUID().uuidString.prefix(8))"

        let oldMessage = makeMessage(subject: oldSubject, body: "OldBody", date: oldDate, from: oldFrom, to: oldTo)
        let newMessage = makeMessage(subject: newSubject, body: "NewBody", date: now, from: newFrom, to: newTo)

        try await client.appendMessage(oldMessage, to: mailbox, date: oldDate)
        try await client.appendMessage(newMessage, to: mailbox, date: now)

        let fromMatches = try await client.searchMessages(in: mailbox, criteria: .from(oldFrom))
        XCTAssertTrue(fromMatches.contains { $0.envelope?.subject == oldSubject })

        let toMatches = try await client.searchMessages(in: mailbox, criteria: .to(newTo))
        XCTAssertTrue(toMatches.contains { $0.envelope?.subject == newSubject })

        let sinceMatches = try await client.searchMessages(in: mailbox, criteria: .since(cutoffDate))
        XCTAssertTrue(sinceMatches.contains { $0.envelope?.subject == newSubject })
        XCTAssertFalse(sinceMatches.contains { $0.envelope?.subject == oldSubject })
    }

    func testSearchHelpersComplexAndLimit() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }

        let mailbox = makeMailboxName(prefix: "Helpers")
        try await client.createMailbox(mailbox)
        defer { Task { try? await client.deleteMailbox(mailbox) } }

        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now

        let fromA = "helper-a@example.com"
        let fromB = "helper-b@example.com"
        let subjectA = "GreenMail Helper A \(UUID().uuidString.prefix(8))"
        let subjectB = "GreenMail Helper B \(UUID().uuidString.prefix(8))"
        let bodyA = "HelperBodyA-\(UUID().uuidString.prefix(8))"
        let bodyB = "HelperBodyB-\(UUID().uuidString.prefix(8))"

        let messageA = makeMessage(subject: subjectA, body: bodyA, date: now, from: fromA, to: "to@example.com")
        let messageB = makeMessage(subject: subjectB, body: bodyB, date: now, from: fromB, to: "to@example.com")

        guard let messageAString = String(data: messageA, encoding: .utf8) else {
            XCTFail("Expected UTF-8 string for message")
            return
        }
        try await client.appendMessage(messageAString, to: mailbox, date: now)
        try await client.appendMessage(messageB, to: mailbox, date: now)

        let fromMatches = try await client.searchMessagesFrom(fromA, in: mailbox)
        XCTAssertTrue(fromMatches.contains { $0.envelope?.subject == subjectA })

        let textMatches = try await client.searchMessagesByText(bodyB, in: mailbox)
        XCTAssertTrue(textMatches.contains { $0.envelope?.subject == subjectB })

        let sinceMatches = try await client.searchMessagesSince(yesterday, in: mailbox)
        XCTAssertGreaterThanOrEqual(sinceMatches.count, 2)

        let singleCriteria = try await client.searchMessages(in: mailbox, matching: [.from(fromA)])
        XCTAssertTrue(singleCriteria.contains { $0.envelope?.subject == subjectA })

        let andMatches = try await client.searchMessages(in: mailbox, matching: [.from(fromA), .subject(subjectA)])
        XCTAssertEqual(andMatches.count, 1)

        guard let uidA = andMatches.first?.uid else {
            XCTFail("Expected UID for helper message A")
            return
        }
        let uidB = (try await client.searchMessagesBySubject(subjectB, in: mailbox)).first?.uid
        guard let uidB else {
            XCTFail("Expected UID for helper message B")
            return
        }

        try await client.storeFlags(uid: uidA, in: mailbox, flags: [.seen], action: .add)
        try await client.storeFlags(uid: uidB, in: mailbox, flags: [.seen, .flagged], action: .add)

        let complexFiltered = try await client.searchMessagesComplex(
            in: mailbox,
            flags: [.seen],
            excludeFlags: [.flagged]
        )
        XCTAssertTrue(complexFiltered.contains { $0.uid == uidA })
        XCTAssertFalse(complexFiltered.contains { $0.uid == uidB })

        let complexAll = try await client.searchMessagesComplex(in: mailbox)
        XCTAssertGreaterThanOrEqual(complexAll.count, 2)

        let limited = try await client.searchMessages(in: mailbox, criteria: .all, limit: 1)
        XCTAssertEqual(limited.count, 1)
    }

    func testSearchByCcBccHeaderWithCharset() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }

        let mailbox = makeMailboxName(prefix: "Headers")
        try await client.createMailbox(mailbox)
        defer { Task { try? await client.deleteMailbox(mailbox) } }

        let ccAddress = "cc-user@example.com"
        let bccAddress = "bcc-user@example.com"
        let headerName = "X-Tracking-ID"
        let headerValue = "track-\(UUID().uuidString.prefix(8))"

        let targetSubject = "GreenMail CC/BCC \(UUID().uuidString.prefix(8))"
        let otherSubject = "GreenMail CC/BCC Other \(UUID().uuidString.prefix(8))"

        let targetMessage = makeMessage(
            subject: targetSubject,
            body: "CCBody",
            cc: ccAddress,
            bcc: bccAddress,
            additionalHeaders: ["\(headerName): \(headerValue)"]
        )
        let otherMessage = makeMessage(
            subject: otherSubject,
            body: "OtherBody",
            cc: "other@example.com",
            bcc: "otherbcc@example.com",
            additionalHeaders: ["\(headerName): other-\(UUID().uuidString.prefix(6))"]
        )

        try await client.appendMessage(targetMessage, to: mailbox)
        try await client.appendMessage(otherMessage, to: mailbox)

        let charset = "UTF-8"

        let ccMatches = try await client.searchMessages(in: mailbox, criteria: .cc(ccAddress), charset: charset)
        XCTAssertTrue(ccMatches.contains { $0.envelope?.subject == targetSubject })
        XCTAssertFalse(ccMatches.contains { $0.envelope?.subject == otherSubject })

        let bccMatches = try await client.searchMessages(in: mailbox, criteria: .bcc(bccAddress), charset: charset)
        XCTAssertTrue(bccMatches.contains { $0.envelope?.subject == targetSubject })
        XCTAssertFalse(bccMatches.contains { $0.envelope?.subject == otherSubject })

        let headerMatches = try await client.searchMessages(
            in: mailbox,
            criteria: .header(field: headerName, value: headerValue),
            charset: charset
        )
        XCTAssertTrue(headerMatches.contains { $0.envelope?.subject == targetSubject })
        XCTAssertFalse(headerMatches.contains { $0.envelope?.subject == otherSubject })
    }

    func testSearchWithUtf8LiteralText() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }

        let mailbox = makeMailboxName(prefix: "Utf8Search")
        try await client.createMailbox(mailbox)
        defer { Task { try? await client.deleteMailbox(mailbox) } }

        let token = "caf\u{00E9}-\(UUID().uuidString.prefix(8))"
        let subject = "GreenMail UTF8 \(UUID().uuidString.prefix(8))"
        let message = makeMessage(
            subject: subject,
            body: "Body \(token)",
            additionalHeaders: [
                "Content-Type: text/plain; charset=UTF-8",
                "Content-Transfer-Encoding: 8bit"
            ]
        )
        try await client.appendMessage(message, to: mailbox)

        let matches = try await client.searchMessages(in: mailbox, criteria: .text(token), charset: "UTF-8")
        XCTAssertTrue(matches.contains { $0.envelope?.subject == subject })
    }

    func testSearchHeaderWithCharset() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }

        let mailbox = makeMailboxName(prefix: "HeaderLiteral")
        try await client.createMailbox(mailbox)
        defer { Task { try? await client.deleteMailbox(mailbox) } }

        let headerName = "X-Search-Note"
        let token = "note-\(UUID().uuidString.prefix(8))"
        let subject = "GreenMail Header Literal \(UUID().uuidString.prefix(8))"
        let message = makeMessage(
            subject: subject,
            body: "HeaderBody",
            additionalHeaders: [
                "\(headerName): \(token)"
            ]
        )
        try await client.appendMessage(message, to: mailbox)

        let matches = try await client.searchMessages(
            in: mailbox,
            criteria: .header(field: headerName, value: token),
            charset: "UTF-8"
        )
        XCTAssertTrue(matches.contains { $0.envelope?.subject == subject })
    }

    func testUtf7MailboxNameRoundTrip() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }

        let mailbox = "SwiftIMAP-UTF7-\u{00DF}-\(UUID().uuidString.prefix(8))"
        try await client.createMailbox(mailbox)
        defer { Task { try? await client.deleteMailbox(mailbox) } }

        let mailboxes = try await client.listMailboxes()
        XCTAssertTrue(mailboxes.contains { $0.name == mailbox })

        let subject = "GreenMail UTF7 \(UUID().uuidString.prefix(8))"
        let message = makeMessage(subject: subject, body: "UTF7Body")
        try await client.appendMessage(message, to: mailbox)

        let matches = try await client.searchMessagesBySubject(subject, in: mailbox)
        XCTAssertTrue(matches.contains { $0.envelope?.subject == subject })
    }

    func testUtf7RenameAndLsub() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }

        let original = "SwiftIMAP-UTF7-\u{00DF}-\(UUID().uuidString.prefix(8))"
        let renamed = "SwiftIMAP-UTF7-\u{00FC}-\(UUID().uuidString.prefix(8))"
        try await client.createMailbox(original)
        defer {
            Task {
                try? await client.deleteMailbox(original)
                try? await client.deleteMailbox(renamed)
            }
        }

        try await client.subscribeMailbox(original)
        let subscribed = try await client.listSubscribedMailboxes()
        XCTAssertTrue(subscribed.contains { $0.name == original })

        try await client.renameMailbox(from: original, to: renamed)

        let mailboxes = try await client.listMailboxes()
        XCTAssertTrue(mailboxes.contains { $0.name == renamed })

        try await client.subscribeMailbox(renamed)
        let subscribedAfter = try await client.listSubscribedMailboxes()
        XCTAssertTrue(subscribedAfter.contains { $0.name == renamed })
    }

    func testBulkCopyMoveAndUidExpunge() async throws {
        let client = try await connectClient()
        defer { Task { await client.disconnect() } }

        let sourceMailbox = makeMailboxName(prefix: "BulkSource")
        let copyMailbox = makeMailboxName(prefix: "BulkCopy")
        let moveMailbox = makeMailboxName(prefix: "BulkMove")

        try await client.createMailbox(sourceMailbox)
        try await client.createMailbox(copyMailbox)
        try await client.createMailbox(moveMailbox)
        defer {
            Task {
                try? await client.deleteMailbox(sourceMailbox)
                try? await client.deleteMailbox(copyMailbox)
                try? await client.deleteMailbox(moveMailbox)
            }
        }

        let subject = "GreenMail Bulk \(UUID().uuidString.prefix(8))"
        for index in 1...3 {
            let message = makeMessage(subject: subject, body: "BulkBody-\(index)")
            try await client.appendMessage(message, to: sourceMailbox)
        }

        let sourceMessages = try await client.searchMessagesBySubject(subject, in: sourceMailbox)
        XCTAssertEqual(sourceMessages.count, 3)

        let sourceUids = sourceMessages.map(\.uid)
        try await client.copyMessages(uids: sourceUids, from: sourceMailbox, to: copyMailbox)

        let copied = try await client.searchMessagesBySubject(subject, in: copyMailbox)
        XCTAssertEqual(copied.count, 3)

        try await client.moveMessages(uids: sourceUids, from: sourceMailbox, to: moveMailbox)
        try? await client.expunge(mailbox: sourceMailbox)

        let moved = try await client.searchMessagesBySubject(subject, in: moveMailbox)
        XCTAssertEqual(moved.count, 3)

        let deleteUids = moved.prefix(2).map(\.uid)
        try await client.storeFlags(uids: deleteUids, in: moveMailbox, flags: [.deleted], action: .add)
        try await client.expunge(uids: deleteUids, in: moveMailbox)

        let remaining = try await client.searchMessagesBySubject(subject, in: moveMailbox)
        XCTAssertEqual(remaining.count, 1)
    }
}

private extension GreenMailIntegrationTests {
    func connectClient() async throws -> IMAPClient {
        guard let config else {
            throw XCTSkip("GreenMail config missing")
        }

        let imapConfig = IMAPConfiguration(
            hostname: config.host,
            port: config.port,
            tlsMode: .disabled,
            authMethod: .login(username: config.username, password: config.password),
            connectionTimeout: 5,
            commandTimeout: 5,
            logLevel: .warning
        )

        let maxAttempts = 5
        var client: IMAPClient?
        var lastError: Error?

        for attempt in 1...maxAttempts {
            let candidate = IMAPClient(configuration: imapConfig)
            do {
                try await candidate.connect()
                client = candidate
                lastError = nil
                break
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }

        guard let client else {
            if let lastError, config.required {
                throw lastError
            }
            throw XCTSkip("GreenMail not reachable")
        }

        return client
    }

    func makeMessage(
        subject: String,
        body: String,
        date: Date = Date(),
        from: String = "test@example.com",
        to: String = "test@example.com",
        cc: String? = nil,
        bcc: String? = nil,
        additionalHeaders: [String] = []
    ) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let dateHeader = formatter.string(from: date)

        var lines = [
            "From: \(from)",
            "To: \(to)",
            "Subject: \(subject)",
            "Date: \(dateHeader)"
        ]
        if let cc {
            lines.append("Cc: \(cc)")
        }
        if let bcc {
            lines.append("Bcc: \(bcc)")
        }
        if !additionalHeaders.isEmpty {
            lines.append(contentsOf: additionalHeaders)
        }
        lines.append("")
        lines.append(body)
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    func makeMailboxName(prefix: String) -> String {
        "SwiftIMAP-\(prefix)-\(UUID().uuidString)"
    }

    private static func loadConfig() -> Config? {
        let env = ProcessInfo.processInfo.environment
        let enabled = env["GREENMAIL_ENABLED"] == "1"
        let host = env["GREENMAIL_HOST"] ?? (enabled ? "127.0.0.1" : nil)
        guard let host else { return nil }
        
        let port = Int(env["GREENMAIL_IMAP_PORT"] ?? "") ?? 3143
        let user = env["GREENMAIL_USER"] ?? "test"
        let domain = env["GREENMAIL_DOMAIN"] ?? "example.com"
        let password = env["GREENMAIL_PASSWORD"] ?? "test"
        let required = env["GREENMAIL_REQUIRED"] == "1"
        
        return Config(
            host: host,
            port: port,
            username: "\(user)@\(domain)",
            password: password,
            required: required
        )
    }
}
