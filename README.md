# SwiftIMAP

A modern, pure-Swift IMAP client library with async/await support. SwiftIMAP provides a clean, type-safe API for interacting with IMAP email servers without any C dependencies.

## Features

- **Pure Swift**: No C or Objective-C dependencies
- **Modern Async/Await**: Built with Swift Concurrency from the ground up
- **Type-Safe**: Strongly typed commands and responses
- **Secure by Default**: TLS 1.2+ with certificate validation
- **Memory Efficient**: Streaming support for large messages
- **Well-Tested**: Comprehensive unit test coverage

## Requirements

- Swift 5.10+
- macOS 13+, iOS 16+, tvOS 16+, watchOS 9+

## Installation

### Swift Package Manager

Add SwiftIMAP to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/SwiftIMAP.git", from: "0.1.0")
]
```

## Quick Start

```swift
import SwiftIMAP

// Configure the client
let config = IMAPConfiguration(
    hostname: "imap.example.com",
    port: 993,
    authMethod: .login(username: "user@example.com", password: "password")
)

// Create client
let client = IMAPClient(configuration: config)

// Connect and authenticate
try await client.connect()

// List mailboxes
let mailboxes = try await client.listMailboxes()
for mailbox in mailboxes {
    print("Mailbox: \(mailbox.name)")
}

// Select a mailbox
let status = try await client.selectMailbox("INBOX")
print("Messages in INBOX: \(status.messages)")

// Search for messages
let messageUIDs = try await client.listMessages(in: "INBOX")

// Fetch a message
if let firstUID = messageUIDs.first {
    if let message = try await client.fetchMessage(uid: firstUID, in: "INBOX") {
        print("Subject: \(message.envelope?.subject ?? "No subject")")
    }
}

// Disconnect
await client.disconnect()
```

## Command-Line Tool

SwiftIMAP includes a command-line tool for testing IMAP connections.

### Building the CLI

```bash
swift build --product swift-imap-tester
```

### Basic Usage

```bash
# Connect and list mailboxes
.build/debug/swift-imap-tester connect \
  --host imap.gmail.com \
  --username your@email.com \
  --password yourpassword \
  --command list

# Fetch a specific message
.build/debug/swift-imap-tester connect \
  --host imap.gmail.com \
  --username your@email.com \
  --password yourpassword \
  --command fetch \
  --mailbox INBOX \
  --uid 12345
```

### Interactive Mode

```bash
.build/debug/swift-imap-tester interactive \
  --host imap.gmail.com \
  --username your@email.com \
  --password yourpassword
```

Interactive commands:
- `list [pattern]` - List mailboxes
- `select <mailbox>` - Select a mailbox
- `status [mailbox]` - Show mailbox status
- `search` - Search messages in selected mailbox
- `fetch <uid>` - Fetch a message by UID
- `capability` - Show server capabilities
- `help` - Show available commands
- `quit` - Disconnect and exit

## API Documentation

### Configuration

```swift
let config = IMAPConfiguration(
    hostname: "imap.example.com",
    port: 993,  // Default IMAP SSL/TLS port
    tlsMode: .requireTLS,  // .requireTLS, .startTLS, or .disabled
    authMethod: .login(username: "user", password: "pass"),
    connectionTimeout: 30,  // seconds
    commandTimeout: 60,     // seconds
    logLevel: .info        // .none, .error, .warning, .info, .debug, .trace
)
```

### Authentication Methods

```swift
// Username/Password
.login(username: "user", password: "password")

// PLAIN mechanism
.plain(username: "user", password: "password")

// OAuth 2.0
.oauth2(username: "user", accessToken: "token")

// External (client certificate)
.external
```

### Working with Mailboxes

```swift
// List all mailboxes
let mailboxes = try await client.listMailboxes()

// List with pattern
let inboxSubfolders = try await client.listMailboxes(pattern: "INBOX.*")

// Get mailbox status without selecting
let status = try await client.mailboxStatus("Sent")
```

### Message Operations

```swift
// Search messages
let allMessages = try await client.listMessages(
    in: "INBOX",
    searchCriteria: .all
)

let unreadMessages = try await client.listMessages(
    in: "INBOX", 
    searchCriteria: .unseen
)

let fromAlice = try await client.listMessages(
    in: "INBOX",
    searchCriteria: .from("alice@example.com")
)

// Fetch message summary
let summary = try await client.fetchMessage(
    uid: 12345,
    in: "INBOX",
    items: [.uid, .flags, .envelope, .bodyStructure]
)

// Fetch full message body
let bodyData = try await client.fetchMessageBody(
    uid: 12345,
    in: "INBOX",
    peek: true  // Don't mark as read
)
```

## Testing

Run the test suite:

```bash
swift test
```

Run tests with verbose output:

```bash
swift test --enable-code-coverage --verbose
```

## Architecture

SwiftIMAP is built with a layered architecture:

1. **Network Layer** (SwiftNIO + NIOSSL): Handles TCP connections and TLS
2. **Protocol Layer** (Parser/Encoder): Implements IMAP protocol parsing and encoding
3. **API Layer** (IMAPClient): Provides high-level async/await APIs

## Security

- TLS 1.2+ is required by default
- Certificate validation enabled
- Sensitive data (passwords) never logged
- Support for certificate pinning via custom TLSConfiguration

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

SwiftIMAP is released under the Apache 2.0 license. See LICENSE for details.