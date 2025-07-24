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