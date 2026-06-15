import XCTest
@testable import SwiftIMAP
import NIO

/// Tests for the expunge/delete footgun fixes and the cached-capability gating
/// a targeted expunge must never silently widen to a whole-mailbox
/// `EXPUNGE`, deletes batch their STORE, and capability-gated operations read
/// the cached capability set instead of issuing CAPABILITY per call.
final class IMAPExpungeSafetyTests: XCTestCase {
    private var eventLoopGroup: MultiThreadedEventLoopGroup!
    private var mockServer: MockIMAPServer!
    private var serverPort: Int!

    override func setUp() async throws {
        try await super.setUp()
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        mockServer = MockIMAPServer(eventLoopGroup: eventLoopGroup)
        serverPort = try await mockServer.start()
    }

    override func tearDown() async throws {
        if let mockServer {
            try await mockServer.shutdown()
            self.mockServer = nil
        }
        if let eventLoopGroup {
            try await eventLoopGroup.shutdownGracefully()
            self.eventLoopGroup = nil
        }
        serverPort = nil
        try await super.tearDown()
    }

    private func makeClient(capabilities: String) async throws -> IMAPClient {
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY \(capabilities)")
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )
        let client = IMAPClient(configuration: config)
        try await client.connect()
        return client
    }

    /// Without UIDPLUS, a targeted expunge must throw rather than fall back to a
    /// whole-mailbox EXPUNGE (which would delete every \Deleted message, not just
    /// the named UIDs).
    func testTargetedExpungeWithoutUIDPLUSThrows() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN")

        do {
            try await client.expunge(uids: [7, 9], in: "INBOX")
            XCTFail("Expected expunge(uids:) to throw without UIDPLUS")
        } catch IMAPError.unsupportedCapability(let capability) {
            XCTAssertEqual(capability, "UIDPLUS")
        }

        let expunges = mockServer.receivedCommands.filter { $0.uppercased().contains("EXPUNGE") }
        XCTAssertTrue(expunges.isEmpty, "No EXPUNGE of any kind may reach the server: \(expunges)")

        // The guard fires before SELECT: a doomed call must not change the
        // selected-mailbox state as a side effect.
        let selects = mockServer.receivedCommands.filter { $0.uppercased().contains("SELECT") }
        XCTAssertTrue(selects.isEmpty, "No SELECT may reach the server: \(selects)")

        await client.disconnect()
    }

    /// With UIDPLUS, a targeted expunge sends UID EXPUNGE with the named UIDs only.
    func testTargetedExpungeWithUIDPLUSSendsUIDExpunge() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN UIDPLUS")
        mockServer.setResponse(for: "UID EXPUNGE", response: "OK Expunge completed")

        try await client.expunge(uids: [7, 9], in: "INBOX")

        let expunges = mockServer.receivedCommands.filter { $0.uppercased().contains("EXPUNGE") }
        XCTAssertEqual(expunges.count, 1)
        XCTAssertTrue(expunges[0].uppercased().contains("UID EXPUNGE 7,9"),
                      "Expected a targeted UID EXPUNGE, got: \(expunges[0])")

        await client.disconnect()
    }

    /// deleteMessages issues one batched STORE for all UIDs (not one per UID) and
    /// routes through the UID-safe expunge.
    func testDeleteMessagesBatchesStoreAndUsesUIDExpunge() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN UIDPLUS")
        mockServer.setResponse(for: "UID STORE", response: "OK Store completed")
        mockServer.setResponse(for: "UID EXPUNGE", response: "OK Expunge completed")

        try await client.deleteMessages(uids: [3, 5, 8], in: "INBOX")

        let stores = mockServer.receivedCommands.filter { $0.uppercased().contains("UID STORE") }
        XCTAssertEqual(stores.count, 1, "Expected one batched STORE, got: \(stores)")
        XCTAssertTrue(stores[0].uppercased().contains("3,5,8"), "STORE should carry all UIDs: \(stores[0])")

        let expunges = mockServer.receivedCommands.filter { $0.uppercased().contains("EXPUNGE") }
        XCTAssertEqual(expunges.count, 1)
        XCTAssertTrue(expunges[0].uppercased().contains("UID EXPUNGE 3,5,8"),
                      "Expected a targeted UID EXPUNGE, got: \(expunges[0])")

        await client.disconnect()
    }

    /// deleteMessages must also refuse to run without UIDPLUS, before storing any
    /// \Deleted flags it could not safely expunge.
    func testDeleteMessagesWithoutUIDPLUSThrows() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "UID STORE", response: "OK Store completed")

        do {
            try await client.deleteMessages(uids: [3, 5], in: "INBOX")
            XCTFail("Expected deleteMessages to throw without UIDPLUS")
        } catch IMAPError.unsupportedCapability(let capability) {
            XCTAssertEqual(capability, "UIDPLUS")
        }

        let expunges = mockServer.receivedCommands.filter { $0.uppercased().contains("EXPUNGE") }
        XCTAssertTrue(expunges.isEmpty, "No EXPUNGE may reach the server: \(expunges)")

        // The guard must fire BEFORE the STORE: throwing after it would leave
        // \Deleted flags set with no safe targeted expunge to follow.
        let stores = mockServer.receivedCommands.filter { $0.uppercased().contains("STORE") }
        XCTAssertTrue(stores.isEmpty, "No STORE may reach the server: \(stores)")

        // And before SELECT, so the doomed call has no selected-mailbox side effect.
        let selects = mockServer.receivedCommands.filter { $0.uppercased().contains("SELECT") }
        XCTAssertTrue(selects.isEmpty, "No SELECT may reach the server: \(selects)")

        await client.disconnect()
    }

    /// moveMessages gates on the cached capability set: no CAPABILITY command is
    /// issued per move. connect() itself issues exactly two (pre- and post-auth).
    func testMoveDoesNotIssueCapabilityPerCall() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN MOVE")
        mockServer.setResponse(for: "UID MOVE", response: "OK Move completed")

        let capabilityCountAfterConnect = mockServer.receivedCommands
            .filter { $0.uppercased().contains("CAPABILITY") }.count

        try await client.moveMessages(uids: [4], from: "INBOX", to: "Archive")
        try await client.moveMessages(uids: [6], from: "INBOX", to: "Archive")

        let capabilityCountAfterMoves = mockServer.receivedCommands
            .filter { $0.uppercased().contains("CAPABILITY") }.count
        XCTAssertEqual(capabilityCountAfterMoves, capabilityCountAfterConnect,
                       "Moves must not issue CAPABILITY commands")

        let moves = mockServer.receivedCommands.filter { $0.uppercased().contains("UID MOVE") }
        XCTAssertEqual(moves.count, 2)

        await client.disconnect()
    }

    /// The MOVE-capability check still works from the cache: a server without
    /// MOVE gets the COPY + \Deleted fallback, with no per-move CAPABILITY.
    func testMoveFallsBackToCopyFromCachedCapabilities() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "UID COPY", response: "OK Copy completed")
        mockServer.setResponse(for: "UID STORE", response: "OK Store completed")

        let capabilityCountAfterConnect = mockServer.receivedCommands
            .filter { $0.uppercased().contains("CAPABILITY") }.count

        try await client.moveMessages(uids: [4], from: "INBOX", to: "Archive")

        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("UID COPY") }, "Expected COPY fallback")
        XCTAssertTrue(commands.contains { $0.contains("UID STORE") && $0.contains("\\DELETED") },
                      "Expected \\Deleted store fallback")

        let capabilityCountAfterMove = mockServer.receivedCommands
            .filter { $0.uppercased().contains("CAPABILITY") }.count
        XCTAssertEqual(capabilityCountAfterMove, capabilityCountAfterConnect)

        await client.disconnect()
    }

    /// connect() refreshes capabilities once after authentication, so the cache
    /// reflects the post-auth capability set that gates MOVE/UIDPLUS — here the
    /// server advertises a reduced set pre-auth and the full set post-auth.
    func testConnectCachesPostAuthCapabilitySet() async throws {
        mockServer.setResponseSequence(for: "CAPABILITY", responses: [
            "* CAPABILITY IMAP4rev1 LOGIN",                 // pre-auth: no extensions
            "* CAPABILITY IMAP4rev1 LOGIN MOVE UIDPLUS"     // post-auth: full set
        ])
        mockServer.setResponse(for: "LOGIN", response: "OK LOGIN completed")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID MOVE", response: "OK Move completed")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )
        let client = IMAPClient(configuration: config)
        try await client.connect()

        let capabilityCommands = mockServer.receivedCommands
            .filter { $0.uppercased().contains("CAPABILITY") }
        XCTAssertEqual(capabilityCommands.count, 2,
                       "connect() should issue CAPABILITY pre-auth and once post-auth, got: \(capabilityCommands)")

        // MOVE only appears in the post-auth set: the move succeeding via UID
        // MOVE (not the COPY fallback) proves the post-auth set is cached.
        try await client.moveMessages(uids: [4], from: "INBOX", to: "Archive")
        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("UID MOVE") },
                      "Expected UID MOVE gated on the post-auth capability set")
        XCTAssertFalse(commands.contains { $0.contains("UID COPY") })

        await client.disconnect()
    }

    /// Capability tokens are case-insensitive (RFC 3501): a server advertising
    /// lowercase tokens must still gate MOVE/UIDPLUS correctly. Tokens are
    /// normalised to upper case at the capability-cache boundary.
    func testLowercaseCapabilityTokensGateCorrectly() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN move uidplus")
        mockServer.setResponse(for: "UID MOVE", response: "OK Move completed")
        mockServer.setResponse(for: "UID EXPUNGE", response: "OK Expunge completed")

        try await client.moveMessages(uids: [4], from: "INBOX", to: "Archive")
        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("UID MOVE") },
                      "Lowercase 'move' capability must still select UID MOVE")
        XCTAssertFalse(commands.contains { $0.contains("UID COPY") })

        try await client.expunge(uids: [7], in: "INBOX")
        XCTAssertTrue(mockServer.receivedCommands.contains { $0.uppercased().contains("UID EXPUNGE") },
                      "Lowercase 'uidplus' capability must still allow targeted expunge")

        await client.disconnect()
    }

    /// A PREAUTH session needs no separate post-auth refresh: the CAPABILITY
    /// command that connect() issues after the greeting already runs in
    /// authenticated state, so the cache holds the post-auth set.
    func testPreauthSessionGatesOnAuthenticatedCapabilities() async throws {
        mockServer.setResponse(for: "GREETING", response: "* PREAUTH IMAP4rev1")
        mockServer.setResponse(for: "CAPABILITY", response: "* CAPABILITY IMAP4rev1 MOVE UIDPLUS")
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID MOVE", response: "OK Move completed")

        let config = IMAPConfiguration(
            hostname: "localhost",
            port: serverPort,
            tlsMode: .disabled,
            authMethod: .login(username: "testuser", password: "testpass")
        )
        let client = IMAPClient(configuration: config)
        try await client.connect()

        try await client.moveMessages(uids: [4], from: "INBOX", to: "Archive")
        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("UID MOVE") },
                      "PREAUTH session must gate MOVE on the fetched capability set")
        XCTAssertFalse(commands.contains { $0.uppercased().contains("LOGIN") })

        await client.disconnect()
    }

    // MARK: - expectedUIDValidity guard

    /// A write with a matching expectedUIDValidity proceeds normally.
    func testWriteWithMatchingUIDValidityProceeds() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "SELECT", response: "* OK [UIDVALIDITY 12345]")
        mockServer.setResponse(for: "UID STORE", response: "OK Store completed")

        try await client.storeFlags(uid: 7, in: "INBOX", flags: [.seen], action: .add, expectedUIDValidity: 12345)

        XCTAssertTrue(mockServer.receivedCommands.contains { $0.uppercased().contains("UID STORE") },
                      "A matching validity must let the store proceed")
        await client.disconnect()
    }

    /// A mismatched expectedUIDValidity throws before the write command is sent
    /// (the SELECT that reads validity is the only command that reaches the server).
    func testStoreWithMismatchedUIDValidityThrowsBeforeSending() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "SELECT", response: "* OK [UIDVALIDITY 999]")
        mockServer.setResponse(for: "UID STORE", response: "OK Store completed")

        do {
            try await client.storeFlags(uids: [3, 5], in: "INBOX", flags: [.seen], action: .add, expectedUIDValidity: 12345)
            XCTFail("Expected uidValidityChanged")
        } catch IMAPError.uidValidityChanged(let expected, let actual) {
            XCTAssertEqual(expected, 12345)
            XCTAssertEqual(actual, 999)
        }

        let stores = mockServer.receivedCommands.filter { $0.uppercased().contains("STORE") }
        XCTAssertTrue(stores.isEmpty, "No STORE may be sent on validity mismatch: \(stores)")
        await client.disconnect()
    }

    /// The guard also blocks MOVE before any UID MOVE reaches the server.
    func testMoveWithMismatchedUIDValidityThrowsBeforeSending() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN MOVE")
        mockServer.setResponse(for: "SELECT", response: "* OK [UIDVALIDITY 999]")
        mockServer.setResponse(for: "UID MOVE", response: "OK Move completed")

        do {
            try await client.moveMessages(uids: [4], from: "INBOX", to: "Archive", expectedUIDValidity: 12345)
            XCTFail("Expected uidValidityChanged")
        } catch IMAPError.uidValidityChanged(let expected, let actual) {
            XCTAssertEqual(expected, 12345)
            XCTAssertEqual(actual, 999)
        }

        XCTAssertFalse(mockServer.receivedCommands.contains { $0.uppercased().contains("UID MOVE") },
                       "No UID MOVE may be sent on validity mismatch")
        await client.disconnect()
    }

    /// And expunge: mismatch throws after the UIDPLUS guard, before UID EXPUNGE.
    func testExpungeWithMismatchedUIDValidityThrowsBeforeSending() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN UIDPLUS")
        mockServer.setResponse(for: "SELECT", response: "* OK [UIDVALIDITY 999]")
        mockServer.setResponse(for: "UID EXPUNGE", response: "OK Expunge completed")

        do {
            try await client.expunge(uids: [7], in: "INBOX", expectedUIDValidity: 12345)
            XCTFail("Expected uidValidityChanged")
        } catch IMAPError.uidValidityChanged { /* expected */ }

        XCTAssertFalse(mockServer.receivedCommands.contains { $0.uppercased().contains("UID EXPUNGE") },
                       "No UID EXPUNGE may be sent on validity mismatch")
        await client.disconnect()
    }

    /// And delete: a mismatch throws after the UIDPLUS guard, before any STORE
    /// or UID EXPUNGE reaches the server.
    func testDeleteWithMismatchedUIDValidityThrowsBeforeSending() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN UIDPLUS")
        mockServer.setResponse(for: "SELECT", response: "* OK [UIDVALIDITY 999]")
        mockServer.setResponse(for: "UID STORE", response: "OK Store completed")
        mockServer.setResponse(for: "UID EXPUNGE", response: "OK Expunge completed")

        do {
            try await client.deleteMessages(uids: [3, 5], in: "INBOX", expectedUIDValidity: 12345)
            XCTFail("Expected uidValidityChanged")
        } catch IMAPError.uidValidityChanged { /* expected */ }

        let sent = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertFalse(sent.contains { $0.contains("UID STORE") }, "No STORE may be sent on validity mismatch")
        XCTAssertFalse(sent.contains { $0.contains("UID EXPUNGE") }, "No UID EXPUNGE may be sent on validity mismatch")
        await client.disconnect()
    }

    /// deleteMessages selects the mailbox once for both the STORE and the UID
    /// EXPUNGE, rather than re-selecting per step.
    func testDeleteSelectsMailboxOnce() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN UIDPLUS")
        mockServer.setResponse(for: "UID STORE", response: "OK Store completed")
        mockServer.setResponse(for: "UID EXPUNGE", response: "OK Expunge completed")

        try await client.deleteMessages(uids: [3, 5], in: "INBOX")

        let selects = mockServer.receivedCommands.filter { $0.uppercased().contains("SELECT") }
        XCTAssertEqual(selects.count, 1, "deleteMessages should SELECT once, got: \(selects)")
        await client.disconnect()
    }

    /// The default (no expectedUIDValidity) is behaviour-identical: a write
    /// proceeds regardless of the server's validity value.
    func testWriteWithoutExpectedValidityIgnoresValidity() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN")
        mockServer.setResponse(for: "SELECT", response: "* OK [UIDVALIDITY 42]")
        mockServer.setResponse(for: "UID STORE", response: "OK Store completed")

        try await client.storeFlags(uid: 7, in: "INBOX", flags: [.seen], action: .add)

        XCTAssertTrue(mockServer.receivedCommands.contains { $0.uppercased().contains("UID STORE") })
        await client.disconnect()
    }

    /// When the SELECT response carries no UIDVALIDITY, an expectedUIDValidity
    /// guard cannot be honoured: the write is refused with uidValidityUnavailable
    /// rather than silently passing a comparison against the parser's 0 sentinel.
    func testGuardThrowsWhenServerOmitsUIDValidity() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN")
        // SELECT completes but reports no UIDVALIDITY code.
        mockServer.setResponse(for: "SELECT", response: "OK [READ-WRITE] SELECT completed")
        mockServer.setResponse(for: "UID STORE", response: "OK Store completed")

        do {
            try await client.storeFlags(uid: 7, in: "INBOX", flags: [.seen], action: .add, expectedUIDValidity: 12345)
            XCTFail("Expected uidValidityUnavailable when the server reports no UIDVALIDITY")
        } catch IMAPError.uidValidityUnavailable(let expected) {
            XCTAssertEqual(expected, 12345)
        }

        let stores = mockServer.receivedCommands.filter { $0.uppercased().contains("STORE") }
        XCTAssertTrue(stores.isEmpty, "No STORE may be sent when validity cannot be verified: \(stores)")
        await client.disconnect()
    }

    /// The MOVE COPY-fallback path (server without MOVE) also honours the guard:
    /// a mismatch throws on the copy's SELECT before any COPY or STORE is sent.
    func testMoveCopyFallbackHonoursUIDValidityGuard() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN")  // no MOVE
        mockServer.setResponse(for: "SELECT", response: "* OK [UIDVALIDITY 999]")
        mockServer.setResponse(for: "UID COPY", response: "OK Copy completed")
        mockServer.setResponse(for: "UID STORE", response: "OK Store completed")

        do {
            try await client.moveMessages(uids: [4], from: "INBOX", to: "Archive", expectedUIDValidity: 12345)
            XCTFail("Expected uidValidityChanged on the COPY-fallback path")
        } catch let IMAPError.uidValidityChanged(expected, actual) {
            XCTAssertEqual(expected, 12345)
            XCTAssertEqual(actual, 999)
        }

        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertFalse(commands.contains { $0.contains("UID COPY") }, "No COPY on validity mismatch")
        XCTAssertFalse(commands.contains { $0.contains("UID STORE") }, "No \\Deleted STORE on validity mismatch")
        await client.disconnect()
    }

    /// In the MOVE COPY-fallback, when UIDVALIDITY changes between the COPY's
    /// SELECT (which matches) and the deletion's SELECT (which does not), the
    /// deletion STORE is guarded too: it throws rather than deleting against
    /// stale UIDs. The COPY happened; the STORE did not.
    func testMoveCopyFallbackGuardsDeletionAfterValidityChangesMidway() async throws {
        let client = try await makeClient(capabilities: "IMAP4rev1 LOGIN")  // no MOVE
        // First SELECT (for COPY) reports 12345 (matches); second SELECT (for the
        // deletion STORE) reports 999 (changed mid-operation).
        mockServer.setResponseSequence(for: "SELECT", responses: [
            "* OK [UIDVALIDITY 12345]",
            "* OK [UIDVALIDITY 999]"
        ])
        mockServer.setResponse(for: "UID COPY", response: "OK Copy completed")
        mockServer.setResponse(for: "UID STORE", response: "OK Store completed")

        do {
            try await client.moveMessages(uids: [4], from: "INBOX", to: "Archive", expectedUIDValidity: 12345)
            XCTFail("Expected uidValidityChanged when validity changes before the deletion STORE")
        } catch let IMAPError.uidValidityChanged(expected, actual) {
            XCTAssertEqual(expected, 12345)
            XCTAssertEqual(actual, 999)
        }

        let commands = mockServer.receivedCommands.map { $0.uppercased() }
        XCTAssertTrue(commands.contains { $0.contains("UID COPY") }, "The COPY (validity matched) should have been sent")
        XCTAssertFalse(commands.contains { $0.contains("UID STORE") },
                       "The deletion STORE must not run once validity changed")
        await client.disconnect()
    }
}
