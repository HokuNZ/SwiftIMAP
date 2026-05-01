# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- `RFC2047Decoder` now compiles on Linux. The unknown-charset fallback used CoreFoundation's IANA registry (`CFStringConvertIANACharSetNameToEncoding` etc.), which is unavailable in swift-corelibs-foundation, so v1.2.2 and v1.2.3 failed to build on non-Apple platforms. The CoreFoundation path is now gated on `canImport(Darwin)`; Linux falls back to UTF-8 for unrecognised charsets, matching the existing "unknown CF charset → UTF-8" semantics on Apple platforms. Also adds explicit cases for `shift_jis`, `iso-2022-jp`, `euc-jp`, `utf-16le`, and `utf-16be` so common non-Latin charsets resolve to the correct encoding cross-platform without going through the CF path.

### Changed
- CI gains a `test-linux` job (Ubuntu, `swift:5.10`, `swift build` + `swift test --skip GreenMailIntegrationTests`) so a Linux compile failure can no longer be masked by an unrelated GreenMail service issue. `release` now depends on it alongside the existing macOS, lint, and GreenMail jobs.

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
