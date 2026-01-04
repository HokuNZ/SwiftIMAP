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

        let targetMailbox = "SwiftIMAP-Test-\(UUID().uuidString)"
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

    func makeMessage(subject: String, body: String) -> Data {
        let lines = [
            "From: test@example.com",
            "To: test@example.com",
            "Subject: \(subject)",
            "Date: Tue, 02 Jan 2024 00:00:00 +0000",
            "",
            body
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
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
