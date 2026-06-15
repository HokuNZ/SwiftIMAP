# Migrating from SwiftIMAP 1.x to 2.0

SwiftIMAP 2.0 reshapes the error surface, removes a handful of unstable or
dead APIs, and tightens a few unsafe behaviours. This guide lists every change
that requires a code update, with the replacement for each.

Most apps need to touch only their error-handling code; everything else is
either a mechanical rename or a behaviour you were unlikely to depend on.

## At a glance

| Area | Change | Action |
|------|--------|--------|
| `IMAPError` | reshaped; some cases removed | update `switch`/`catch` (see below) |
| `listMessages`, `fetchMessageBySequence` | removed | use the UID-based equivalents |
| `searchMessagesComplex` | removed | use `searchMessages(in:matching:)` |
| `MimePart.body` | removed | use `decodedText` / `decodedData` |
| `messageID` / `inReplyTo` | now `MessageId?` (was `String?`) | read `.value` / `.bracketed` |
| `references` | now `[MessageId]` (was `String?`) | iterate; `.value` / `.bracketed` per entry |
| Targeted `expunge`/`delete` | throws without UIDPLUS | catch, or use `expunge(mailbox:)` |
| `SequenceSet.set([])` | precondition failure | guard `isEmpty` before calling |
| `Mime`/`ID` casing | `ParsedMimeMessage`→`ParsedMIMEMessage`, `MimePart`→`MIMEPart`, `parseMimeContent`→`parseMIMEContent`, `MessageID`→`MessageId` | rename references |

## `IMAPError` is reshaped

The error enum is leaner and carries structured, leak-free diagnostics.

**Reshaped cases:**

| 1.x | 2.0 |
|-----|-----|
| `commandFailed(command: String, response: String)` | `commandFailed(IMAPServerResponse)` |
| `connectionClosed` | `connectionClosed(IMAPServerResponse?)` |
| `connectionFailed(String)` | `connectionFailed(String, underlying: (any Error)?)` |
| `tlsError(String)` | `tlsError(String, underlying: (any Error)?)` |
| `timeout` | `timeout(command: String?)` |
| `authenticationFailed(String)` | `authenticationFailed(String, response: IMAPServerResponse?)` |

**Removed cases** (none of these were ever thrown in 1.x):
`mailboxNotFound`, `messageNotFound`, `quotaExceeded`, `permissionDenied`,
`serverError`, `connectionError`, `disconnected`.

The information those removed cases implied is now available uniformly from the
`IMAPServerResponse` carried by `commandFailed` — via its semantic accessors
`isMailboxNotFound`, `isOverQuota`, `isPermissionDenied`,
`isAuthenticationFailure`, and the raw `code` / `codeName`. "Connection is gone"
is now the single case `connectionClosed(IMAPServerResponse?)` (the response is
the server's `BYE` when there was one, or `nil` for an abrupt drop). A
server-rejected `LOGIN`/`AUTHENTICATE` now surfaces as `authenticationFailed`
carrying the response, where 1.x produced the generic `commandFailed`.

```swift
// 1.x
catch let error as IMAPError {
    switch error {
    case .commandFailed(let command, let response):
        log.error("\(command): \(response)")
    case .mailboxNotFound(let name):
        ...
    case .disconnected:
        reconnect()
    }
}

// 2.0
catch let error as IMAPError {
    switch error {
    case .commandFailed(let response):
        log.error("\(response.commandName): \(response.line)")  // safe to log
        if response.isMailboxNotFound { ... }
    case .connectionClosed(let response):
        log.error("closed: \(response?.line ?? "abruptly")")
    case .authenticationFailed(let message, let response):
        log.error("auth: \(message) \(response?.line ?? "")")
    default:                                  // see "Enum evolution" below
        log.error("\(error.localizedDescription)")
    }
}
```

## Removed: sequence-number APIs

`listMessages` (deprecated since 1.1) and `fetchMessageBySequence` are gone.
Both used message sequence numbers, which shift when the mailbox changes between
calls. Use the UID-based equivalents — same signatures, but the results are
stable UIDs:

```swift
// 1.x
let seqs = try await client.listMessages(in: "INBOX", searchCriteria: .unseen)
let msg  = try await client.fetchMessageBySequence(sequenceNumber: 2, in: "INBOX")

// 2.0
let uids = try await client.listMessageUIDs(in: "INBOX", searchCriteria: .unseen)
let msg  = try await client.fetchMessage(uid: uids[0], in: "INBOX")
```

> If your 1.x code already passed `listMessages` results into `fetchMessage(uid:)`,
> it was mixing sequence numbers and UIDs — a latent bug. The rename to
> `listMessageUIDs` fixes it.

## Removed: `searchMessagesComplex`

Use `searchMessages(in:matching:)` with `SearchCriteria` values. The simple
convenience wrappers (`searchMessagesFrom`, `searchMessagesBySubject`,
`searchUnreadMessages`, `searchFlaggedMessages`, …) remain.

```swift
// 1.x
let results = try await client.searchMessagesComplex(
    in: "INBOX", from: "a@x.com", flags: [.seen], excludeFlags: [.flagged])

// 2.0
let results = try await client.searchMessages(
    in: "INBOX", matching: [.from("a@x.com"), .seen, .unflagged])
```

## Removed: `MimePart.body`

`body` exposed a MimeParser dependency type (`MimeBody`) on the public surface.
Use the decoded accessors, which need no `import MimeParser`:

```swift
// 1.x
let text = String(data: try part.body.decodedContentData(), encoding: .utf8)

// 2.0
let text = part.decodedText      // decoded text, raw fallback on decode failure
let data = part.decodedData      // decoded bytes (e.g. for attachments)
```

## Message identifiers are now `MessageId`

`Envelope.messageId`, `Envelope.inReplyTo`, and each entry of
`MessageSummary.references` are now `MessageId` values rather than `String`s.
`MessageId` canonicalises to the bare form (no angle brackets), so identifiers
compare equal regardless of how the server framed them — threading needs no
bracket-stripping.

```swift
// 1.x — String, bracketed, compared by hand
if msg.envelope?.messageID == "<\(parentId)>" { ... }
let refs = (summary.references ?? "").split(separator: " ").map { /* strip <> */ }

// 2.0
if msg.envelope?.messageId == parentMessageId { ... }   // MessageId == MessageId
let refs: [MessageId] = summary.references               // already parsed, ordered

id.value        // "abc@host"  — bare canonical identity (also `description`)
id.bracketed    // "<abc@host>" — to write into an outgoing header
```

Working from raw header strings (e.g. a full-message fetch) rather than the
model? Normalise the same way with the stateless parsers:

```swift
let mid  = MessageId(parsing: headers["Message-Id"] ?? "")      // MessageId?
let refs = MessageId.parseList(headers["References"] ?? "")      // [MessageId]
```

## Behavioural: targeted expunge/delete require UIDPLUS

`expunge(uids:in:)`, `deleteMessage(uid:in:)`, and `deleteMessages(uids:in:)`
now throw `IMAPError.unsupportedCapability("UIDPLUS")` on a server without
UIDPLUS, instead of silently falling back to a whole-mailbox `EXPUNGE` (which
deleted *every* `\Deleted` message, not just the named UIDs — a data-loss
footgun). Handle the error, or call `expunge(mailbox:)` explicitly when a
whole-mailbox expunge is what you intend.

## Behavioural: `SequenceSet.set([])`

Passing an empty array to `IMAPCommand.SequenceSet.set(_:)` now triggers a
precondition failure rather than emitting the invalid UID `0`. The `IMAPClient`
methods already guard with `isEmpty`; if you call `SequenceSet.set` directly,
guard first.

## Things you can now delete from your code

These are not required changes, but 2.0 lets you remove workarounds:

- **Rebuild-on-error**: `connect()` is now idempotent — a no-op on a healthy
  client, a reconnect on a stale one. Keep one `IMAPClient` and call `connect()`
  again after an error instead of discarding and rebuilding it.
- **`STATUS`-then-write UIDVALIDITY guards**: pass `expectedUIDValidity:` to
  `storeFlags` / `moveMessage(s)` / `copyMessage(s)` / `expunge(uids:)` /
  `deleteMessage(s)` instead.
  The check rides on the operation's own `SELECT` (atomic, no extra round trip).
- **Manual message-ID bracket handling**: identifiers are now `MessageId`
  (see below), so threading comparisons need no bracket-stripping.
- **Fire-and-forget `disconnect()`**: `disconnect()` now bounds a hung `LOGOUT`
  itself (`min(commandTimeout, 5s)`).
- **Hand-rolled RFC 2822 parsers**: if you build a typed model from raw message
  bytes or headers (`.eml` files, Maildir, webhook payloads, test fixtures), use
  `MessageSummary.parse(rfc822:)` or `Envelope(parsingHeaders:)` instead of a
  parallel parser, so the raw-bytes path maps through the same code as a live
  `FETCH`.
  - Note one difference between the two paths: a live `ENVELOPE` preserves
    address-group structure in the `*Entries` arrays (e.g. `toEntries`), whereas
    the raw-header path (`Envelope(parsingHeaders:)`) flattens a group to its
    member addresses. Both paths populate `*Entries`; only the `FETCH`/`ENVELOPE`
    path emits `.group` entries — the raw-header path emits only `.mailbox`.

## Naming standardisation

Two cosmetic renames to a consistent house style (both mechanical — rename the
references):

- **`MIME` is upper-cased** as an initialism: `ParsedMimeMessage` →
  `ParsedMIMEMessage`, `MimePart` → `MIMEPart`, and `parseMimeContent(from:)` →
  `parseMIMEContent(from:)` (static and instance).
- **Identifier names use `Id`, not `ID`**: the `MessageID` type is now
  `MessageId`, and `Envelope.messageID` is now `messageId`.

The `UID` typealias is **unchanged** — it is established IMAP/RFC vocabulary.
The external `MimeParser` dependency keeps its own name.

## Enum evolution

Library enums (`IMAPError`, `IMAPResponse.ResponseCode`, `SearchCriteria`, …)
may gain new cases in **minor** releases. Always include a `default:` arm when
switching over them so a future case does not break your build. (Swift source
packages cannot use `@unknown default`, so a plain `default` is the tool.)
