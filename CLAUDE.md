# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SwiftIMAP is a modern, pure-Swift IMAP client framework providing a lightweight, async/await-first API for common mail operations, comparable to MailCore2 but without C/Objective-C dependencies.

## Development Commands

```bash
# Build the project
swift build

# Build the CLI tool specifically
swift build --product imap-cli

# Run tests
swift test

# Run tests with coverage
swift test --enable-code-coverage

# Run specific test
swift test --filter IMAPParserTests

# Generate documentation
swift package generate-documentation

# Clean build artifacts
swift package clean

# Run the CLI tool
.build/debug/imap-cli --help
```

## Architecture

The project follows a three-layer architecture:

```
┌─────────┐     ┌─────────────┐     ┌─────────────────┐
│ TLS I/O │ ◄──► │  IMAPCodec  │ ◄──► │  Async High-Level │
│(SwiftNIO)│     │  (parser)   │     │     API Layer     │
└─────────┘     └─────────────┘     └─────────────────┘
```

- **Network Layer**: SwiftNIO + NIOSSL for non-blocking I/O
- **IMAPCodec**: Bidirectional parser/encoder for IMAP protocol
- **API Layer**: Developer-friendly async/await APIs

## Key Components

1. **IMAPClient** (Sources/SwiftIMAP/IMAPClient.swift): Main client API
2. **IMAPParser** (Sources/SwiftIMAP/Protocol/IMAPParser.swift): Parses IMAP server responses
3. **IMAPEncoder** (Sources/SwiftIMAP/Protocol/IMAPEncoder.swift): Encodes IMAP commands
4. **ConnectionActor** (Sources/SwiftIMAP/Networking/ConnectionActor.swift): Manages network connection state
5. **Models** (Sources/SwiftIMAP/Models/): Data models for mailboxes, messages, etc.

## Implementation Guidelines

1. **Swift Version**: Use Swift 5.10+ features, particularly Swift Concurrency (async/await)
2. **Dependencies**: Only swift-nio, swift-nio-ssl, and swift-crypto (no C dependencies)
3. **Security**: TLS 1.2+ required by default, certificate pinning hooks, no sensitive data in logs
4. **Concurrency**: All public APIs must be async throws, use actors for thread-safe state management
5. **Error Handling**: Use IMAPError enum for all errors, include raw server messages
6. **Testing**: Write unit tests for all new functionality

## Testing Approach

- Unit tests for parser codecs, model mapping, and error handling
- Integration tests against Dockerized Dovecot or GreenMail
- Use the CLI tool for manual testing against real servers

## Current Implementation Status

### Completed:
- Basic IMAP protocol parser and encoder
- Networking layer with TLS support
- Authentication (LOGIN, PLAIN)
- Core commands: CAPABILITY, LIST, SELECT, FETCH, SEARCH
- High-level async/await client API
- Command-line testing tool
- Comprehensive unit tests for parser and encoder

### TODO:
- OAuth2 authentication implementation
- IDLE command for push notifications
- Message manipulation (STORE, COPY, MOVE)
- Retry logic and connection pooling
- Integration tests with mock server
- Performance optimizations for large mailboxes

## Debugging Tips

1. Use `--verbose` flag with CLI tool to see detailed logs
2. Set log level to `.trace` for maximum detail
3. Parser errors include the problematic input line
4. Network errors include connection state information

## Common Issues

1. **Modified UTF-7 encoding**: Mailbox names use a special encoding - see IMAPEncoder.encodeModifiedUTF7
2. **Response parsing**: Some servers send non-standard responses - parser attempts to be lenient
3. **TLS issues**: Some servers require specific TLS versions or cipher suites
4. **Authentication**: Different servers support different auth mechanisms - check CAPABILITY response

## Release Management

### Versioning Strategy
This project uses [Semantic Versioning](https://semver.org/). Version tags follow the format `vMAJOR.MINOR.PATCH`.

**How consumers reference versions:**
```swift
// Package.swift - consumers use version ranges
.package(url: "https://github.com/HokuNZ/SwiftIMAP.git", from: "1.0.0")
```

**Branch and tag strategy:**
- Tags (e.g., `v1.0`, `v1.1`) are immutable release points
- `main` branch contains development work for the next release
- Existing apps continue building against tagged versions while new work happens on main

### Maintaining CHANGELOG.md
- **Every merge to `main` must include a CHANGELOG.md update**
- Add entries under `[Unreleased]` section
- Use categories: Added, Changed, Deprecated, Removed, Fixed, Security
- Link to relevant PRs/issues using `(#N)` format
- When releasing, move Unreleased items to a new version section with date

### GitHub Milestones
- Create milestones for upcoming releases (e.g., `v1.1`)
- Assign all related PRs and issues to the appropriate milestone
- Close milestones when the version is released

### Releasing a Version

**Pre-release checklist:**
- [ ] All PRs for the milestone are merged
- [ ] All tests pass: `swift test`
- [ ] CHANGELOG.md has entries for all changes

**Release steps:**
```bash
# 1. Update CHANGELOG.md: move [Unreleased] to new version section
#    Change: ## [Unreleased]
#    To:     ## [1.x.x] - YYYY-MM-DD

# 2. Update version in README.md package reference if needed

# 3. Commit the release prep
git add CHANGELOG.md README.md
git commit -m "Prepare release v1.x.x"

# 4. Create annotated tag
git tag -a v1.x.x -m "Release v1.x.x"

# 5. Push commit and tag
git push origin main
git push origin v1.x.x

# 6. Create GitHub Release
gh release create v1.x.x --title "v1.x.x" --notes-file <(sed -n '/## \[1.x.x\]/,/## \[/p' CHANGELOG.md | head -n -1)
```

**Post-release:**
- Close the GitHub milestone
- Notify dependent projects (e.g., MailTriage) that they can update their version reference