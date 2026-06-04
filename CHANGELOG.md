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
- `IMAPCommand.Command.label` / `IMAPCommand.UIDCommand.label`: the argument-free IMAP verb, safe to log.

### Changed
- **Breaking.** `IMAPError` reshaped for richer, leak-free diagnostics (#27):
  - `commandFailed(command:response:)` → `commandFailed(IMAPServerResponse)`.
  - `connectionClosed` → `connectionClosed(IMAPServerResponse?)`, capturing the `BYE` greeting's code and text instead of discarding them.
  - `connectionFailed(String)` → `connectionFailed(String, underlying: (any Error)?)` and `tlsError(String)` → `tlsError(String, underlying: (any Error)?)`, preserving the typed NIO/SSL cause.
  - `timeout` → `timeout(command: String?)`, identifying which operation timed out.
- The greeting wait now honours `IMAPConfiguration.connectionTimeout` instead of a hardcoded 5 seconds.
- `connect()` failures (which surface as `connectionFailed`) are now retryable; previously the retry wrapper around `connect()` was a no-op for them. Retry classification of server rejections now branches on the typed response code (`[UNAVAILABLE]`, `[INUSE]`, `[SERVERBUG]`) and never retries `BAD`. When a code is present it is authoritative: a definitive code such as `[NONEXISTENT]` is not retried even if the free text contains retry-flavoured words, and the text is consulted only when no code is sent. A `* BYE` greeting that names a definitive condition is treated as the server rejecting the connection and is no longer retried (a bare close or a `[UNAVAILABLE]`-style transient BYE still is).

### Removed
- **Breaking.** Dead `IMAPError` cases `mailboxNotFound`, `messageNotFound`, `quotaExceeded`, and `permissionDenied`, which had no producers (#27). The equivalent information is available uniformly via `IMAPServerResponse.code` and its semantic accessors.

### Fixed
- `ConnectionActor.waitForGreeting` no longer drops responses that arrive between the greeting and the persistent handler being installed (#26). The greeting handler is now a one-shot — it consumes the greeting batch and clears itself (inside the channel handler's lock, so no re-entrant deadlock), reverting the channel to buffering. The greeting closure's bare `resumedState` read was also replaced with a compare-and-exchange to remove a TOCTOU with the timeout task.
- An unsolicited mid-session `* BYE` now surfaces its reason on in-flight commands: when the server sends `BYE` and drops the connection, pending commands fail with `connectionClosed(IMAPServerResponse)` carrying the BYE code and text rather than a bare `disconnected`. The reason is captured and applied at teardown — including an explicit `disconnect()` that races the channel closing — so it never interferes with a `BYE` that legitimately precedes a `LOGOUT` completion.
- `executeWithReconnect` now classifies and throws the reconnect failure (not the original error) when reconnection itself fails, so the surfaced error matches what actually went wrong.
- A failed `LOGOUT` during `disconnect()` is now logged at debug level instead of being silently discarded.
- `RetryConfiguration` now rejects `maxAttempts < 1` at construction with a clear precondition message, instead of trapping deep in the retry loop on the `1...maxAttempts` range.

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
