# RFC 3501 Coverage Checklist

This document tracks SwiftIMAP's coverage of RFC 3501 (IMAP4rev1). It is meant to be a living checklist we can walk through and update as gaps are closed.

Legend:
- [x] Implemented
- [ ] Missing
- [ ] (partial) Partially implemented; see notes

Reference:
- RFC text in `rfc3501.txt`
- Core protocol types: `Sources/SwiftIMAP/Protocol/IMAPCommand.swift`, `Sources/SwiftIMAP/Protocol/IMAPResponse.swift`

## 1. Protocol States and Flow (RFC 3)
- [x] Track connection state (disconnected/connected/authenticated/selected) (`Sources/SwiftIMAP/Networking/ConnectionActor.swift`).
- [x] Enforce legal command/state combinations (`Sources/SwiftIMAP/Protocol/IMAPCommandState.swift`).

## 2. Data Formats (RFC 4)
- [x] Atom parsing for ASTRING/NSTRING (`Sources/SwiftIMAP/Protocol/IMAPParser+Scanner.swift`).
- [x] Number parsing (`Sources/SwiftIMAP/Protocol/IMAPParser+Scanner.swift`).
- [x] Quoted string parsing with escapes (`Sources/SwiftIMAP/Protocol/IMAPParser+Scanner.swift`).
- [x] Literal handling in responses (single/multiple literals) (`Sources/SwiftIMAP/Protocol/IMAPParser.swift`, `Sources/SwiftIMAP/Protocol/IMAPParser+Literal.swift`).
- [x] Literal handling in commands (ASTRINGs using literals when needed) (`Sources/SwiftIMAP/Protocol/IMAPEncoder.swift`).
- [x] Parenthesized lists with quoted strings and nested lists (`Sources/SwiftIMAP/Protocol/IMAPParser+Scanner.swift`).
- [x] NIL handling (`Sources/SwiftIMAP/Protocol/IMAPParser+Envelope.swift`).
- [x] 8-bit/binary strings preserved via raw literal data capture (`Sources/SwiftIMAP/Protocol/IMAPParser.swift`).

## 3. Message Attributes (RFC 2.3)
- [x] FLAGS (`Sources/SwiftIMAP/Protocol/IMAPParser+Fetch.swift`).
- [x] INTERNALDATE (`Sources/SwiftIMAP/Protocol/IMAPParser+Fetch.swift`).
- [x] RFC822.SIZE (`Sources/SwiftIMAP/Protocol/IMAPParser+Fetch.swift`).
- [x] ENVELOPE (raw envelope parsing) (`Sources/SwiftIMAP/Protocol/IMAPParser+Envelope.swift`).
- [x] ENVELOPE group address semantics preserved in mapping (`Sources/SwiftIMAP/IMAPClient+Parsing.swift`).
- [x] BODYSTRUCTURE with multipart parameters/disposition/language/extensions (`Sources/SwiftIMAP/Protocol/IMAPParser+BodyStructure.swift`).

## 4. Client Commands (RFC 6)

### 4.1 Any State (RFC 6.1)
- [x] CAPABILITY (`Sources/SwiftIMAP/Protocol/IMAPCommand.swift`).
- [x] NOOP (`Sources/SwiftIMAP/Protocol/IMAPCommand.swift`).
- [x] LOGOUT (`Sources/SwiftIMAP/Protocol/IMAPCommand.swift`).

### 4.2 Not Authenticated (RFC 6.2)
- [x] STARTTLS (`Sources/SwiftIMAP/IMAPClient+Connection.swift`).
- [ ] (partial) AUTHENTICATE (multi-challenge supported, limited SASL mechanisms in client) (`Sources/SwiftIMAP/IMAPClient+Connection.swift`).
- [x] LOGIN (`Sources/SwiftIMAP/IMAPClient+Connection.swift`).

### 4.3 Authenticated (RFC 6.3)
- [x] SELECT (`Sources/SwiftIMAP/IMAPClient+Mailboxes.swift`).
- [x] EXAMINE (`Sources/SwiftIMAP/Protocol/IMAPCommand.swift`).
- [x] CREATE (`Sources/SwiftIMAP/IMAPClient+Mailboxes.swift`).
- [x] DELETE (`Sources/SwiftIMAP/IMAPClient+Mailboxes.swift`).
- [x] RENAME (`Sources/SwiftIMAP/IMAPClient+Mailboxes.swift`).
- [x] SUBSCRIBE (`Sources/SwiftIMAP/Protocol/IMAPCommand.swift`).
- [x] UNSUBSCRIBE (`Sources/SwiftIMAP/Protocol/IMAPCommand.swift`).
- [x] LIST (`Sources/SwiftIMAP/IMAPClient+Mailboxes.swift`).
- [x] LSUB (`Sources/SwiftIMAP/Protocol/IMAPCommand.swift`).
- [x] STATUS (`Sources/SwiftIMAP/IMAPClient+Mailboxes.swift`).
- [x] APPEND (`Sources/SwiftIMAP/IMAPClient+MessageOps.swift`).

### 4.4 Selected (RFC 6.4)
- [x] CHECK (`Sources/SwiftIMAP/Protocol/IMAPCommand.swift`).
- [x] CLOSE (`Sources/SwiftIMAP/Protocol/IMAPCommand.swift`).
- [x] EXPUNGE (`Sources/SwiftIMAP/IMAPClient+MessageOps.swift`).
- [x] SEARCH (full criteria list encoded) (`Sources/SwiftIMAP/Protocol/IMAPEncoder+Search.swift`).
- [x] FETCH (RFC822.* and header/text variants mapped) (`Sources/SwiftIMAP/Protocol/IMAPParser+Fetch.swift`).
- [x] STORE (`Sources/SwiftIMAP/IMAPClient+MessageOps.swift`).
- [x] COPY (`Sources/SwiftIMAP/IMAPClient+MessageOps.swift`).
- [x] UID (`Sources/SwiftIMAP/Protocol/IMAPCommand.swift`).

## 5. Server Responses (RFC 7)
- [x] Status responses OK/NO/BAD/PREAUTH/BYE (`Sources/SwiftIMAP/Protocol/IMAPParser+Responses.swift`).
- [x] CAPABILITY (`Sources/SwiftIMAP/Protocol/IMAPParser+Responses.swift`).
- [x] LIST (`Sources/SwiftIMAP/Protocol/IMAPParser+Responses.swift`).
- [x] LSUB (`Sources/SwiftIMAP/Protocol/IMAPParser+Responses.swift`).
- [x] STATUS (`Sources/SwiftIMAP/Protocol/IMAPParser+Responses.swift`).
- [x] SEARCH (`Sources/SwiftIMAP/Protocol/IMAPParser+Responses.swift`).
- [x] FLAGS (`Sources/SwiftIMAP/Protocol/IMAPParser+Responses.swift`).
- [x] EXISTS (`Sources/SwiftIMAP/Protocol/IMAPParser+Responses.swift`).
- [x] RECENT (`Sources/SwiftIMAP/Protocol/IMAPParser+Responses.swift`).
- [x] EXPUNGE (`Sources/SwiftIMAP/Protocol/IMAPParser+Responses.swift`).
- [ ] (partial) FETCH (see section 6) (`Sources/SwiftIMAP/Protocol/IMAPParser+Fetch.swift`).
- [x] Continuation response (`+`) (`Sources/SwiftIMAP/Protocol/IMAPParser+Responses.swift`).

### 5.1 Response Codes (RFC 7.1)
- [x] ALERT
- [x] BADCHARSET
- [x] CAPABILITY
- [x] PARSE
- [x] PERMANENTFLAGS
- [x] READ-ONLY
- [x] READ-WRITE
- [x] TRYCREATE
- [x] UIDNEXT
- [x] UIDVALIDITY
- [x] UNSEEN
  - Implementation: `Sources/SwiftIMAP/Protocol/IMAPParser+Responses.swift`

## 6. FETCH Attributes (RFC 7.4.2)
- [x] UID
- [x] FLAGS
- [x] INTERNALDATE
- [x] RFC822.SIZE
- [x] ENVELOPE
- [x] BODYSTRUCTURE
- [x] BODY[section] / BODY.PEEK[section]
- [x] RFC822
- [x] RFC822.HEADER
- [x] RFC822.TEXT
- [x] BODY[HEADER]
- [x] BODY[TEXT]
- [x] BODY[HEADER.FIELDS]
- [x] BODY[HEADER.FIELDS.NOT]
  - Implementation: `Sources/SwiftIMAP/Protocol/IMAPParser+Fetch.swift`, `Sources/SwiftIMAP/Protocol/IMAPResponse.swift`

## 7. SEARCH Criteria (RFC 6.4.4)
- [x] ALL
- [x] ANSWERED
- [x] BCC
- [x] BEFORE
- [x] BODY
- [x] CC
- [x] DELETED
- [x] DRAFT
- [x] FLAGGED
- [x] FROM
- [x] HEADER
- [x] KEYWORD
- [x] LARGER
- [x] NEW
- [x] NOT
- [x] OLD
- [x] ON
- [x] OR
- [x] RECENT
- [x] SEEN
- [x] SENTBEFORE
- [x] SENTON
- [x] SENTSINCE
- [x] SINCE
- [x] SMALLER
- [x] SUBJECT
- [x] TEXT
- [x] TO
- [x] UID
- [x] UNANSWERED
- [x] UNDELETED
- [x] UNDRAFT
- [x] UNFLAGGED
- [x] UNKEYWORD
- [x] UNSEEN
  - Implementation: `Sources/SwiftIMAP/Protocol/IMAPEncoder+Search.swift`

## 8. Sequence Sets (RFC 2.3.1.2)
- [x] `*` (last message) is supported via `.last` and `*:n` via `.rangeFromLast(to:)`.

## 9. Testing Coverage
- [x] Encoder unit tests (`Tests/SwiftIMAPTests/IMAPEncoderTests.swift`).
- [x] Parser unit tests (`Tests/SwiftIMAPTests/IMAPParserTests*.swift`).
- [x] Literal parsing tests (`Tests/SwiftIMAPTests/IMAPLiteralParsingTests.swift`).
- [ ] (partial) Integration tests require mock server (skipped in CI) and GreenMail tests are opt-in.

## 10. Non-RFC3501 Extensions (Tracked Separately)
- [x] IDLE (RFC 2177) command encoded (`Sources/SwiftIMAP/Protocol/IMAPCommand.swift`).
- [x] MOVE (RFC 6851) command encoded (`Sources/SwiftIMAP/Protocol/IMAPCommand.swift`).
- [x] UID EXPUNGE (RFC 4315) command encoded (`Sources/SwiftIMAP/Protocol/IMAPCommand.swift`).
- [ ] LITERAL+ (RFC 7888) non-synchronizing literals not implemented.

---

Planned next passes (suggested order):
1) 8-bit/binary string handling in literals.
2) AUTHENTICATE mechanism coverage.
