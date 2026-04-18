# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
