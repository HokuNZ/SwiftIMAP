# SwiftIMAP (working title) – Specification Document

## 1. Purpose

Build a modern, **pure‑Swift** IMAP client framework that provides a lightweight, async/await‑first API for common mail operations. It should be comparable to MailCore2 in capability but cleaner, safer, and free of Objective‑C/C dependencies.

## 2. Scope

Initial (v0.1) delivers **three core user stories**:

1. **Authentication** – connect & sign‑in (username/password and OAuth 2.0) over TLS.
2. **Mailbox Enumeration** – list and inspect folders (IMAP `LIST`, `LSUB`, `STATUS`).
3. **Message Access** – list message summaries and fetch full message content (headers, body, attachments).

## 3. Non‑Goals (v0.1)

- SMTP, POP3, or sending mail.
- IDLE push notifications.
- Message composition or MIME building.
- Offline caching or Core Data integration.

## 4. Design Principles

- **Pure Swift 5.10+** – no C libraries.
- **Swift Concurrency First** – every network operation is `async throws`.
- **Back‑Pressure Friendly** – streaming bodies via `AsyncSequence` to avoid memory spikes.
- **Modular** – clear separation between protocol parsing, networking, and high‑level API.
- **Security by Default** – TLS 1.2+, cert pinning hooks, sensitive data never logged.

## 5. High‑Level Architecture

```
┌─────────┐     ┌─────────────┐     ┌─────────────────┐
│ TLS I\/O │ ◄──► │  IMAPCodec  │ ◄──► │  Async High‑Level │
│ (SwiftNIO)│     │  (parser)   │     │     API Layer     │
└─────────┘     └─────────────┘     └─────────────────┘
```

- **Network Layer** – built on `SwiftNIO` + `NIOSSL`.
- **IMAPCodec** – bidirectional parser/encoder producing strongly‑typed `IMAPCommand` & `IMAPResponse` structs.
- **API Layer** – exposes developer‑friendly models (`Mailbox`, `Message`, etc.) and convenience methods.

## 6. Public API (draft)

```swift
public struct IMAPConfiguration {
    public var hostname: String
    public var port: Int = 993
    public var tlsMode: TLSMode = .requireTLS
    public var authMethod: AuthMethod
}

public final class IMAPClient {
    public init(configuration: IMAPConfiguration)
    
    public func connect() async throws
    public func disconnect() async

    // MARK: Mailboxes
    public func listMailboxes() async throws -> [Mailbox]
    public func mailboxStatus(_ mailbox: Mailbox) async throws -> MailboxStatus

    // MARK: Messages
    public func listMessages(in mailbox: Mailbox, _ query: MessageQuery) async throws -> [MessageSummary]
    public func fetchMessage(id: UID, in mailbox: Mailbox, options: FetchOptions) async throws -> Message
}
```

### Supporting Models

```swift
struct Mailbox { let name: String; let attributes: Set<Attribute> }
struct MessageSummary { let uid: UID; let subject: String; let date: Date; let flags: Set<Flag> }
struct Message { let header: Header; let body: Body; let attachments: [Attachment] }
```

## 7. Concurrency Model

- All public APIs are **single‑entry async**; they resume on the **Main Actor** only when returning UI‑ready values.
- Long transfers (e.g., large bodies) expose `AsyncThrowingStream<ByteBuffer>` for incremental consumption.
- Internal state mutation is isolated in an `actor` (`ConnectionActor`) for thread‑safety.

## 8. Error Handling

`enum IMAPError: Error` encapsulates network failures, authentication errors, parse errors, and RFC 3501 status responses (`NO`, `BAD`). All errors include the raw server message for debugging.

## 9. Security Considerations

- Default TLS with server cert validation (via `NIOSSL`).
- Optional **certificate pinning**.
- OAuth 2.0 support follows RFC 7628 (`AUTH=XOAUTH2`).
- Sensitive data removed from debug logs.

## 10. Testing Strategy

- **Unit Tests** – parser codecs, model mapping, error handling.
- **Integration Tests** – run against [GreenMail] or Dockerised Dovecot in CI (GitHub Actions).
- **Mutation/Fuzz Tests** – ensure parser resilience.

## 11. Dependencies

| Package           | Reason               | Notes     |
| ----------------- | -------------------- | --------- |
| **swift‑nio**     | Non‑blocking sockets | MIT       |
| **swift‑nio‑ssl** | TLS over NIO         | MIT       |
| **swift‑crypto**  | OAuth HMAC/SHA utils | Apple BSD |

## 12. CI & Tooling

- GitHub Actions: build on macOS & Linux (Swift 5.10), run full test suite.
- [Swift‑DocC] for API docs; published via GitHub Pages.
- Semantic‑release style versioning (`0.x` while unstable).

## 13. Roadmap

| Milestone | Key Deliverables                                   |
| --------- | -------------------------------------------------- |
| **0.1.0** | Connect/Auth, `LIST`, `FETCH` envelope headers     |
| **0.2.0** | Body streaming, attachments, OAuth2                |
| **0.3.0** | IMAP `IDLE`, folder create/delete, flag operations |

## 14. Licensing

- Apache‑2.0 to match Swift standard libraries and encourage open‑source adoption.

---

*Last updated: 24 July 2025 (NZST)*

