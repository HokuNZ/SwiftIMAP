# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security
- `IMAPError` no longer embeds command arguments in its messages, closing a credential/payload leak (#27). The `commandFailed` error previously built its command field with `String(describing:)`, so a rejected `LOGIN` produced an error (and `localizedDescription`) containing the cleartext password; `APPEND` embedded the whole message body. The debug log line for every outgoing command and the `invalidState` validator messages had the same leak. All now use a new argument-free `IMAPCommand.Command.label` (e.g. `"UID MOVE"`, `"LOGIN"`).
- Parser errors now truncate the offending server input (`String.truncatedForDiagnostics`), so a malformed or oversized response line can no longer dump unbounded content (including message data) into logs or crash reports.
- `FETCH` responses are now redacted in `.debug`/`.trace` logs: message bodies, headers, and decoded envelope fields are reduced to byte counts via `IMAPResponse.loggingDescription` rather than rendered in full, so enabling verbose logging can no longer spill message content (PII) into logs or crash reports.

### Added
- `IMAPServerResponse` value type carrying the server's `status` (`NO`/`BAD`/`BYE`), parsed `code`, `text`, and the argument-free `commandName`, plus a reconstructed `line` for logging (e.g. `NO [TRYCREATE] Mailbox does not exist`) (#27). Surfaced on `commandFailed` and `connectionClosed` so callers (e.g. MailTriage #226) can log a faithful server response line and distinguish causes. Includes semantic accessors: `isMailboxNotFound`, `isOverQuota`, `isPermissionDenied`, `isAuthenticationFailure`, and `codeName`.
- `IMAPServerResponse.commandName` gives the argument-free verb of the command a server rejected (e.g. `"UID MOVE"`, `"LOGIN"`) — the supported way to learn which command failed without touching the wire types. It is backed by `IMAPCommand.Command.label` / `IMAPCommand.UIDCommand.label`, which are also public for low-level use.
- `MessageSummary`, `Envelope`, `BodyStructure`, `ParsedMIMEMessage`, and `MIMEPart` now conform to `Equatable` (#49), so consumers can diff and assert against whole model values in tests. Additive; identity/collection types (`Mailbox`, `Address`) remain `Hashable` as before.
- `MessageId` value type for message identifiers (#59): `Hashable`/`Sendable`, canonicalises to the bare form on parse (so bracketed and bare framings compare equal), with `bracketed` for emitting on the wire and stateless `MessageId(parsing:)` / `MessageId.parseList(_:)` for callers working from raw header strings. Makes threading comparisons correct by construction, with no bracket handling at the call site.
- Raw-RFC822 parsing for consumers with message bytes rather than a live IMAP `FETCH` (`.eml` importers, Maildir readers, webhook payloads, offline fixtures) (#61): `Envelope(parsingHeaders: [String: String])` builds a typed `Envelope` from a header dict (case-insensitive names; parses `From`/`Sender`/`Reply-To`/`To`/`Cc`/`Bcc`/`Subject`/`Date`/`Message-ID`/`In-Reply-To` into addresses, an RFC 2047 decoded subject, and a `Date`), and `MessageSummary.parse(rfc822: Data)` builds a full `MessageSummary` from message bytes (MIME parse → `Envelope` → `references` populated; `uid`/`sequenceNumber` synthesised as `0`, `internalDate` from the `Date` header or now). The Date parser covers the common RFC 2822 forms: with and without leading weekday, 24-hour and AM/PM clocks, and a trailing `(...)` timezone comment.
- `expectedUIDValidity: UInt32?` parameter (default `nil`) on `storeFlags` (all overloads), `moveMessage(s)`, `copyMessage(s)`, `expunge(uids:in:)`, and `deleteMessage(s)` (#48, #65). When set, the operation is refused with the new `IMAPError.uidValidityChanged(expected:actual:)` if the mailbox's current `UIDVALIDITY` differs, guarding writes against UIDs from a stale mailbox view. The check rides on the `SELECT` the operation already issues, so it is atomic with the write and costs no extra round trip — replacing any consumer-side `STATUS`-then-write guard (which has a TOCTOU window). If the server reports no `UIDVALIDITY`, the write is refused with `IMAPError.uidValidityUnavailable(expected:)` rather than passing unverified. Default `nil` preserves existing behaviour exactly.

### Changed
- **Breaking.** Public naming standardised (#62): the `MessageID` type is now `MessageId` (and `Envelope.messageID` is now `messageId`); the MIME initialism is upper-cased — `ParsedMimeMessage` → `ParsedMIMEMessage`, `MimePart` → `MIMEPart`, `parseMimeContent(from:)` → `parseMIMEContent(from:)` (static and instance). The `UID` typealias is left unchanged (established IMAP vocabulary).
- **Breaking.** Message identifiers are now typed `MessageId` instead of `String` (#59): `Envelope.messageId` and `Envelope.inReplyTo` are `MessageId?`, and `MessageSummary.references` is `[MessageId]` (ordered; replaces the raw `String?` and the `referenceIDs` accessor). Read `.value` for the bare identity or `.bracketed` to re-emit. Identifiers now compare equal regardless of bracket framing, so threading needs no bracket-stripping at the call site.
- **Breaking.** `IMAPError` reshaped for richer, leak-free diagnostics (#27):
  - `commandFailed(command:response:)` → `commandFailed(IMAPServerResponse)`.
  - `connectionClosed` → `connectionClosed(IMAPServerResponse?)`, capturing the `BYE` greeting's code and text instead of discarding them.
  - `connectionFailed(String)` → `connectionFailed(String, underlying: (any Error)?)` and `tlsError(String)` → `tlsError(String, underlying: (any Error)?)`, preserving the typed NIO/SSL cause.
  - `timeout` → `timeout(command: String?)`, identifying which operation timed out.
  - `authenticationFailed(String)` → `authenticationFailed(String, response: IMAPServerResponse?)` (#35). A server-rejected `LOGIN` or `AUTHENTICATE` now surfaces as `authenticationFailed` carrying the server's response; previously it surfaced as the generic `commandFailed`, so callers pattern-matching `authenticationFailed` for auth UX silently missed real rejections. Local failures (credential encoding, SASL handler returning nil) keep their message with `response: nil`.
- `connect()` is now idempotent (#37): a call on an already-connected, healthy client is a no-op; a call on a disconnected or stale client (e.g. after the connection dropped) reconnects and re-authenticates; and concurrent calls coalesce onto a single attempt instead of one of them throwing `invalidState`. Calling code that disposed of and rebuilt the `IMAPClient` after a connection error can keep one instance and simply call `connect()` again. Note the coalescing guarantee covers concurrent `connect()` calls only — a `disconnect()` racing an in-flight `connect()` remains the caller's ordering to manage.
- **Breaking.** `expunge(uids:in:)`, `deleteMessage(uid:in:)`, and `deleteMessages(uids:in:)` now throw `unsupportedCapability("UIDPLUS")` on servers without UIDPLUS, instead of silently falling back to a whole-mailbox `EXPUNGE` that permanently deleted every `\Deleted` message in the mailbox rather than just the named UIDs (#36). Calling code on non-UIDPLUS servers must catch the error (or check `capability()` first) and decide explicitly; call `expunge(mailbox:)` when a whole-mailbox expunge is genuinely intended.
- `deleteMessages(uids:in:)` now issues one batched `STORE` for all UIDs instead of one per UID, and expunges only the named UIDs via `UID EXPUNGE` (#36). The delete now also issues a single `SELECT` covering both the `STORE` and the `UID EXPUNGE` rather than re-selecting per step (#66).
- `moveMessage(s)` and `expunge(uids:in:)` now gate on the cached capability set instead of issuing a `CAPABILITY` round trip per call; `connect()` refreshes capabilities once after authentication so the cache reflects the post-auth set (#36).
- `IMAPCommand.SequenceSet.set(_:)` now requires a non-empty array (precondition) instead of silently producing UID `0`, which is invalid on the wire (#36). Calling code that may hold an empty UID list must guard with `isEmpty` before constructing a sequence set (the `IMAPClient` methods already do).
- `searchMessages` now fetches all matching messages in a single `UID FETCH` over a sequence set, instead of one round trip per result (#47). Same results, same order, and the skip-if-deleted-between-search-and-fetch behaviour is preserved; large result sets load in one round trip rather than N. Behaviour-compatible, no signature change.
- The greeting wait now honours `IMAPConfiguration.connectionTimeout` instead of a hardcoded 5 seconds.
- `connect()` failures (which surface as `connectionFailed`) are now retryable; previously the retry wrapper around `connect()` was a no-op for them. Retry classification of server rejections now branches on the typed response code (`[UNAVAILABLE]`, `[INUSE]`, `[SERVERBUG]`) and never retries `BAD`. When a code is present it is authoritative: a definitive code such as `[NONEXISTENT]` is not retried even if the free text contains retry-flavoured words, and the text is consulted only when no code is sent. A `* BYE` greeting that names a definitive condition is treated as the server rejecting the connection and is no longer retried (a bare close or a `[UNAVAILABLE]`-style transient BYE still is).
- `ParsedMIMEMessage` and `MIMEPart` are now `Sendable` (#38): parts hold only decoded value types (the MimeParser wire objects are consumed at construction), so parsed results can cross actor and task boundaries — previously they were the only model types that could not. Decoding now happens eagerly at parse time rather than lazily per accessor call.

### Removed
- **Breaking.** Dead `IMAPError` cases `mailboxNotFound`, `messageNotFound`, `quotaExceeded`, and `permissionDenied`, which had no producers (#27). The equivalent information is available uniformly via `IMAPServerResponse.code` and its semantic accessors.
- **Breaking.** Three more `IMAPError` cases (#35): `serverError` (no producers), `connectionError` (sole producer was an unreachable retry-exhaustion fallback, now `connectionFailed`), and `disconnected` (folded into `connectionClosed(nil)`: one case for "connection is gone", with the server's response when there was one and `nil` for an abrupt loss).
- **Breaking.** `MIMEPart.body` removed (#38). Replace any `part.body` access with `decodedText` (text content, raw fallback on decode failure) or `decodedData` (decoded bytes, now a stored property); `import MimeParser` is no longer needed in calling code. `body` was the only public API exposing a MimeParser dependency type (`MimeBody`).
- **Breaking.** Removed `listMessages(in:searchCriteria:charset:)` (deprecated since v1.1) and `fetchMessageBySequence(sequenceNumber:in:items:)` (#39). Replace with the UID-based equivalents: `listMessageUIDs(in:searchCriteria:charset:)` and `fetchMessage(uid:in:items:)` — same signatures otherwise, but results are UIDs, which stay stable when the mailbox changes concurrently (sequence numbers shift). Code that already passed `listMessages` results to UID-based APIs was buggy and is fixed by the rename alone.
- **Breaking.** Removed `searchMessagesComplex(in:from:to:subject:text:since:before:flags:excludeFlags:limit:)` (#39). Replace with `searchMessages(in:matching:)`, passing the equivalent criteria — e.g. `searchMessagesComplex(in: m, from: a, flags: [.seen], excludeFlags: [.flagged])` becomes `searchMessages(in: m, matching: [.from(a), .seen, .unflagged])`. The simple convenience wrappers (`searchMessagesFrom`, `searchUnreadMessages`, etc.) remain.

### Fixed
- A connect attempt that fails part-way through session establishment (STARTTLS unavailable, rejected credentials, a capability failure) now tears the connection down before the error is thrown (#37). The client is always cleanly disconnected after a failed `connect()`: a retry re-attempts with a fresh connection, and a subsequent `connect()` can never silently treat the failed session as healthy — which for a PREAUTH greeting under `.startTLS` would have meant continuing on an unencrypted connection.
- `ConnectionActor.waitForGreeting` no longer drops responses that arrive between the greeting and the persistent handler being installed (#26). The greeting handler is now a one-shot — it consumes the greeting batch and clears itself (inside the channel handler's lock, so no re-entrant deadlock), reverting the channel to buffering. The greeting closure's bare `resumedState` read was also replaced with a compare-and-exchange to remove a TOCTOU with the timeout task.
- An unsolicited mid-session `* BYE` now surfaces its reason on in-flight commands: when the server sends `BYE` and drops the connection, pending commands fail with `connectionClosed(IMAPServerResponse)` carrying the BYE code and text rather than a bare `disconnected`. The reason is captured and applied at teardown — including an explicit `disconnect()` that races the channel closing — so it never interferes with a `BYE` that legitimately precedes a `LOGOUT` completion.
- `executeWithReconnect` now classifies and throws the reconnect failure (not the original error) when reconnection itself fails, so the surfaced error matches what actually went wrong.
- A failed `LOGOUT` during `disconnect()` is now logged at debug level instead of being silently discarded.
- `RetryConfiguration` now rejects `maxAttempts < 1` at construction with a clear precondition message, instead of trapping deep in the retry loop on the `1...maxAttempts` range.
- An abrupt mid-session connection drop is now reconnectable (#35). Two independent defects made reconnect-after-drop impossible: the drop surfaced as `disconnected`, which the retry layer classified as neither retryable nor requiring reconnection; and the connection actor never reset its state when the channel died, so the reconnect attempt itself threw `invalidState("Already connected or connecting")`. The drop now surfaces as `connectionClosed(nil)`, the actor resets to disconnected when the channel is gone, and wrapped operations reconnect and retry transparently (covered by an end-to-end regression test). A `connectionClosed` carrying a *definitive* `BYE` (e.g. `[ALERT]`) is deliberately not reconnected — mirroring retry classification — so the server's stated reason survives to the caller instead of being replaced by the reconnect's outcome.
- `fetchMessageBody` now reconnects and retries on a lost connection like `fetchMessage` (#46). A body fetch is an idempotent read (re-issuing it is safe; with the default `peek` it does not touch `\Seen` at all), so a mid-fetch drop now reconnects and retries instead of failing the call outright.
- `disconnect()` no longer waits the full `commandTimeout` (default 60s) for a `LOGOUT` the server never answers (#46). The `LOGOUT` is now bounded at `min(commandTimeout, 5s)`; once the bound elapses the connection is closed regardless, which also resolves the pending `LOGOUT`. A fast, healthy `LOGOUT` still returns immediately. Removes the need for consumer-side fire-and-forget teardown.

## [1.3.0] - 2026-06-01

### Added
- `MessageSummary.parseMimeContent(from:)` is now available as a `static` method, so callers with raw RFC 822 bytes but no populated `MessageSummary` (e.g. an `.eml` fixture harness) can parse without synthesising a stub instance (#22). The existing instance method is retained as a thin wrapper; both reach the same code path.
- `MessageSummary.keywords: Set<String>` surfaces custom IMAP keywords the server reports that are not standard system flags — e.g. `$Forwarded`, `$Junk`/`$NotJunk`, or client-defined keywords like `@Triaged` (#23). Previously these were silently dropped because `flags` is a closed `Flag` enum. Purely additive: `flags` behaviour is unchanged and the new init parameter defaults to `[]`.

### Changed
- MimeParser dependency now points at the HokuNZ-maintained fork (`HokuNZ/MimeParser`) pinned by semver (`.upToNextMinor(from: "0.2.6")`) instead of a `revision:` SHA on `miximka/MimeParser` (#12, #13). SwiftPM treats branch/revision pins as unstable, so any downstream consumer pinning SwiftIMAP by a version requirement (`exactVersion`, `from:`, etc.) failed to resolve. A semver-tagged dependency makes SwiftIMAP's graph stable and resolvable. The fork's library sources are identical to the previously pinned commit (`miximka/MimeParser` master tip `0903ca7` at fork time), so there is no behavioural change; the tagged commit additionally adds a sync workflow and a README maintenance note. That scheduled workflow watches the dormant upstream and opens a tracking issue if it advances.

## [1.2.4] - 2026-05-24

### Fixed
- `RFC2047Decoder` now compiles on Linux. The unknown-charset fallback used CoreFoundation's IANA registry (`CFStringConvertIANACharSetNameToEncoding` etc.), which is unavailable in swift-corelibs-foundation, so v1.2.2 and v1.2.3 failed to build on non-Apple platforms. The CoreFoundation path is now gated on `canImport(Darwin)`; Linux falls back to UTF-8 for unrecognised charsets, matching the existing "unknown CF charset → UTF-8" semantics on Apple platforms. Also adds explicit cases for `shift_jis`, `iso-2022-jp`, `euc-jp`, `utf-16le`, and `utf-16be` so common non-Latin charsets resolve to the correct encoding cross-platform without going through the CF path.

### Changed
- CI gains a `test-linux` job (Ubuntu, `swift:5.10`, `swift build` + `swift test`) so a Linux compile failure can no longer be masked by an unrelated GreenMail service issue. `release` now depends on it alongside the existing macOS, lint, and GreenMail jobs.

## [1.2.3] - 2026-05-01

### Fixed
- `RFC2047.decode` no longer returns the input unchanged when a Q-encoded encoded-word's first byte is non-ASCII (e.g. `=?UTF-8?Q?=C3=9E...?=` for `Þ...`, `=?utf-8?q?=F0=9F=8E=89?=` for `🎉`) (#17). The decoder's forward search for the closing `?=` was matching the boundary between the encoding marker and the first encoded byte; now it skips past the two structural `?` separators before searching, so `?=` after the second `?` is unambiguously the closer per RFC 2047 §2. Adds two regression tests for Q-encoded words leading with non-ASCII bytes; B-encoded inputs and Q-encoded inputs with ASCII-leading text were already covered.

## [1.2.2] - 2026-04-30

### Added
- `RFC2047` decoder applied at the envelope-parse boundary so `Envelope.subject` and `Address.name` come back as decoded human-readable text rather than raw `=?charset?encoding?text?=` source. Supports both base64 (`B`) and quoted-printable (`Q`) encodings, common charsets, and adjacent-encoded-word whitespace suppression per RFC 2047 §6.2. Malformed encoded-words pass through verbatim.

### Fixed
- Envelope parser no longer hangs indefinitely on quoted strings containing raw non-ASCII bytes that do not form valid UTF-8 sequences (#15). `extractLine()` falls back to ISO-8859-1 when UTF-8 decoding fails so every byte maps to a code point and the parser progresses; previously the line stayed in the buffer and the parser silently waited for a CRLF that had already arrived.

### Changed
- Repository guidance migrated from `CLAUDE.md` to `AGENTS.md` (#11). `CLAUDE.md` is now a one-line `@AGENTS.md` import.

## [1.2.1] - 2026-04-29

### Changed
- Pin `MimeParser` dependency by revision (`0903ca7e`) instead of `branch: "master"` (#12)
  - Allows downstream consumers to depend on SwiftIMAP via any stable version constraint (for example, Exact Version or Up to Next Major)
  - Preserves current MimeParser behaviour exactly (no source impact)

## [1.2.0] - 2026-04-18

### Added
- `MessageSummary.references` field exposing the RFC 5322 References header for email threading (#8, #9)
  - Populated when the fetch includes `BODY[HEADER.FIELDS (REFERENCES)]` (with or without `.PEEK`)
  - Handles RFC 5322 folded headers (CRLF + WSP continuations)
  - Falls back to ISO-8859-1 when header bytes are not valid UTF-8

## [1.1.0] - 2026-04-18

### Added
- `listMessageUIDs()` method for stable message identifiers using UID SEARCH (#1)

### Changed
- `searchMessages()` now uses UIDs internally to prevent race conditions (#1)

### Fixed
- `fetchMessage()` and `fetchMessageBody()` now verify UID in response to prevent returning wrong data (#2)
- `MimePart.isAttachment` now correctly identifies inline parts with filenames as attachments (#5)
  - Apple Mail marks PDF attachments as `Content-Disposition: inline` with a filename
  - Previously these were incorrectly excluded from the `attachments` array
  - Embedded images with Content-ID (cid: references) are still excluded, even with filenames

### Deprecated
- `listMessages()` - use `listMessageUIDs()` instead (sequence numbers are unstable)

## [1.0.0] - 2026-04-13

### Added
- Initial release
- IMAP protocol parser and encoder
- Networking layer with TLS support (SwiftNIO + NIOSSL)
- Authentication methods: LOGIN, PLAIN, OAuth2, External, custom SASL
- Core commands: CAPABILITY, LIST, SELECT, FETCH, SEARCH, STORE
- High-level async/await client API
- Command-line testing tool
- Comprehensive unit test coverage
