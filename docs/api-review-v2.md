# SwiftIMAP v2.0 external API review

Date: 2026-06-06. Branch under review: `version/v2.0` (post-#27 error-handling work).

## Brief

- v2.0 already contains breaking changes (`IMAPError` reshape, #27), so MailTriage must
  adapt regardless. This major is the cheap window for any other breaking fixes; the next
  window is v3.0.
- Every candidate break is weighed against MailTriage's **measured** migration cost
  (its source was audited for this review), not hypothetical cost.
- Clean breaks, no deprecation shims.
- The repo is public, so the surface should also be coherent and well documented for
  unknown future consumers, with a migration guide.
- Enum policy: library enums may gain new cases in **minor** releases. This is
  published guidance, not something the library can enforce: Swift source packages are
  non-resilient, so consumers *can* switch exhaustively and `@unknown default` is
  unavailable to them. The README advises a plain `default` arm when switching over
  library enums; consumers who switch exhaustively accept source breakage on minors.
- Swift 6 strict concurrency is out of scope (parked for v3.0).
- Internal-detail exposure is bounded by what MailTriage demonstrably needs or has
  worked around.

## Method

- Full read of the public surface (~47 public types, ~232 public members) on
  `version/v2.0`.
- Producer audit: every `IMAPError` case traced to its `throw` sites.
- Consumer audit: every SwiftIMAP symbol referenced by MailTriage, including its error
  handling sites and the workarounds it carries for library limitations.
- In-repo consumers checked: `IMAPCLITool` and `Examples/` use only the high-level
  client API; tests use `@testable import` throughout.

## Measured MailTriage surface

Load-bearing API (everything MailTriage production code touches):

- `IMAPClient`: `init`, `connect`, `disconnect`, `listMailboxes`, `searchMessages`,
  `fetchMessageBody`, `storeFlags` (3 overloads), `moveMessages`, `appendMessage`,
  `mailboxStatus`
- `IMAPConfiguration` (+ `TLSMode`, `AuthMethod.login`), `RetryConfiguration.default`
- `IMAPCommand.SearchCriteria` (`.since`, `.unseen`, `.unkeyword`, `.header`),
  `IMAPCommand.FetchItem`, `IMAPCommand.StatusItem.uidValidity`,
  `IMAPCommand.StoreFlags.Action.add`
- `MessageSummary` (`uid`, `flags`, `keywords`, `envelope`, `internalDate`,
  `references`), `Envelope`, `Address`, `Flag`, `Mailbox` (+ `Attribute`),
  `MailboxStatus.uidValidity`, `parseMimeContent`/`ParsedMimeMessage`/`MimePart`
  (decoded accessors only)
- `IMAPError`: exhaustive switch in `IMAPService.swift` (error classification) and
  case extraction in `IMAPMailAccount+WriteErrors.swift` (Bugsnag metadata)

Everything else on the public surface is unused by MailTriage and can be reshaped
freely. Total forced MailTriage migration for all changes proposed below: **the two
error-handling files it must already touch for #27**.

---

## Findings

### A. Error surface (completes the #27 cleanup)

#### A1 ⛔️ Remove dead case `IMAPError.serverError`

No producers anywhere in the library (verified by grep over all `throw` sites). Same
situation as the four cases removed in #27. It also has dead string-matching branches
in `RetryHandler.isRetryableError` and `requiresReconnection`
(`RetryHandler.swift:141-143`, `212-215`) that should go with it.
MailTriage cost: one switch arm deleted in code it is already editing.

#### A2 ⛔️ Remove case `IMAPError.connectionError`

Sole producer is the `lastError ?? IMAPError.connectionError(...)` fallback in
`RetryHandler.swift:48` and `:108`, which is unreachable (`maxAttempts >= 1` is
enforced at construction, so `lastError` is always set when the loop exits). Replace
the fallback with `connectionFailed` (or a precondition) and delete the case. It
currently duplicates `connectionFailed` and forces consumers to handle both.
MailTriage cost: one switch arm deleted.

#### A3 ⛔️ Fold `IMAPError.disconnected` into `connectionClosed(nil)`

`.disconnected` means "connection is gone, server said nothing";
`.connectionClosed(IMAPServerResponse?)` already models "connection is gone" with an
*optional* server response. Two cases for the same consumer decision is a trap: every
caller must remember to handle both. Producers (`IMAPChannelHandler.swift:54`,
`ConnectionActor.swift:202,331,568`) become `connectionClosed(nil)`.
MailTriage cost: one switch arm deleted (it already maps both to the same category).

#### A4 ⛔️ Reconnect classification must treat abrupt loss as reconnectable

`requiresReconnection` (`RetryHandler.swift:208-219`) does not include
`.disconnected`, yet an abrupt TCP drop fails pending commands with exactly
`.disconnected` (`IMAPChannelHandler.swift:54`). Result: a dropped connection
mid-session is neither retried nor reconnected; the operation just fails. This is a
root cause of MailTriage's "reset the Core actor and rebuild the client on any error"
workaround. A3 fixes this mechanically (`connectionClosed` is already classified as
reconnectable), but it needs its own regression test. Internal behaviour change, no
API impact.

#### A5 ⛔️ Server-rejected authentication should surface as `authenticationFailed`

`.authenticationFailed(String)` is currently thrown only for *local* failures
(credential encoding, nil SASL handler response — `IMAPClient+Connection.swift:138,153`,
`ConnectionActor.swift:632`). A real server rejection of LOGIN/AUTHENTICATE surfaces
as `.commandFailed(response)` like any other command. Consumers will naturally
pattern-match `.authenticationFailed` for auth UX (MailTriage's classifier does
exactly this) and silently miss the actual server rejection.

Recommendation (reworked after independent review): reshape to
`authenticationFailed(String, response: IMAPServerResponse?)`. The `String` keeps the
existing local-failure detail (encoding failures, nil SASL handler response, with
`response: nil`); the auth path maps a `NO`/`BAD` completion of LOGIN/AUTHENTICATE
into the same case with the server response carried. Auth UX consumers match one
case and lose nothing. The semantic accessor `isAuthenticationFailure` remains useful
for rejections outside the auth flow.
MailTriage cost: inside the switch arm it already has.

### B. Over-exposed wire layer

In-repo evidence: no consumer (MailTriage, CLI tool, Examples) touches any of these;
tests reach them via `@testable`.

#### B1 ⛔️ Internalise `IMAPParser` and `IMAPEncoder`

Wire-format codecs with `public` classes and methods. Internalising removes the
implied stability contract for the parser's incremental-feed design, which we may
want to change freely.

#### B2 ⛔️ Internalise the `IMAPResponse` hierarchy; hoist `ResponseCode`

`IMAPResponse` and its nested types (`UntaggedResponse`, `FetchAttribute`,
`EnvelopeData`, `AddressData`, `BodyStructureData`, `DispositionData`, ...) are ~45
public declarations of raw wire format, including `raw*: Data` fields. Nothing public
returns them. The single public dependency is `IMAPServerResponse.code:
IMAPResponse.ResponseCode`.

Recommendation: hoist `ResponseCode` to a top-level `public enum IMAPResponseCode`
(internal `typealias` keeps library code unchanged), make everything else internal.
MailTriage cost: nil (it reads `code` via the semantic accessors and `codeName`).

#### B3 ⛔️ Internalise `IMAPCommand`'s wire half, keep the criteria namespace

`IMAPCommand.Command` (which includes `.login(username:password:)`),
`UIDCommand`, `tag`, `command`, and `init(tag:command:)` are wire-level and unused by
consumers. `IMAPCommand.SearchCriteria`, `FetchItem`, `StatusItem`, `StoreFlags`, and
`SequenceSet` are genuine client API used by MailTriage, and must keep their nesting
(so `IMAPCommand.SearchCriteria` spellings keep compiling).

Note: the unreleased CHANGELOG advertises `IMAPCommand.Command.label` as public; that
entry should be revised (the public face of "which command failed" is
`IMAPServerResponse.commandName`).

#### B4 ⛔️ Stop leaking `MimeBody` (MimeParser type) via `MimePart.body`

`MimePart.body: MimeBody` (`MessageSummary+MIME.swift:205`) requires consumers to
`import MimeParser` to use it, coupling our public API to a dependency's type.
The decoded accessors (`decodedText`, `decodedData`) cover real use — they are all
MailTriage touches. Make `body` internal. Also enables D-grade `Sendable` work (G2).

### C. Resilience is inconsistently applied

#### C1 ⛔️ Make `connect()` idempotent

`ConnectionActor.swift:118` throws `invalidState("Already connected or connecting")`
on a second `connect()`. Combined with A4, this forces MailTriage to discard and
rebuild the entire client after any error. Recommendation: `connect()` on an
already-connected client is a no-op; on a stale/disconnected client it reconnects.
Documented as the contract. MailTriage can then delete its rebuild machinery
(its choice; no forced change).

#### C2 ⛔️ Apply retry/reconnect uniformly across operations

Only `connect`, `listMessageUIDs`, `listMessages`, and `fetchMessage` are wrapped in
`executeWithReconnect`. `fetchMessageBody`, `storeFlags`, `moveMessages`,
`copyMessages`, `appendMessage`, `expunge`, and all mailbox operations call
`connection.sendCommand` bare — so precisely the write operations (where transient
failure hurts most) get no resilience.

Nuance: writes are not idempotent. A retry after an *ambiguous* failure (command may
have been executed) could double-APPEND or double-MOVE. Recommendation:

- Reconnect-and-retry when the failure is provably pre-execution (connection was
  already dead, command never sent).
- For ambiguous failures, surface the error (current behaviour) — do not blind-retry
  writes.
- Reads (`fetchMessageBody`) get full retry like `fetchMessage`.

This is behavioural, not a signature change.

#### C3 ⚠️ `disconnect()` can block up to `commandTimeout` (default 60 s)

`disconnect()` awaits LOGOUT, which on a dead-but-open channel waits the full command
timeout (`ConnectionActor.swift:674` path). MailTriage works around this with
fire-and-forget teardown. Recommendation: cap LOGOUT inside `disconnect()` at a short
bound (e.g. 5 s), then close the channel regardless. Non-breaking.

### D. Footguns

#### D1 ⛔️ `expunge(uids:in:)` silently expunges the whole mailbox without UIDPLUS

`IMAPClient+MessageOps.swift:189-201`: when the server lacks UIDPLUS, the targeted
expunge falls back to a plain `EXPUNGE` — permanently deleting **every** `\Deleted`
message in the mailbox, not just the named UIDs. Silent data loss on the worst
possible operation. `deleteMessage`/`deleteMessages` inherit the blast radius (any
pre-existing `\Deleted` messages from other sessions are collateral).
Recommendation: throw `unsupportedCapability("UIDPLUS")` instead of falling back;
document `expunge(mailbox:)` as the explicit whole-mailbox form.
MailTriage cost: nil (does not call expunge).

#### D2 ⛔️ `deleteMessages(uids:in:)` issues N round-trips then a whole-mailbox expunge

`IMAPClient+MessageOps.swift:210-217` loops `markForDeletion` per UID despite a batch
`storeFlags(uids:)` existing, then calls full `expunge(mailbox:)`. Batch the store and
route through the UID-safe expunge (per D1).

#### D3 ⛔️ `SequenceSet.set([])` returns `.single(0)`

`IMAPCommand.swift:215-218`. UID 0 is invalid in IMAP; sending it is a protocol
error. The public client methods guard with `isEmpty`, but the public static func
itself is a trap (the comment even says "shouldn't happen"). Make it `precondition`
or return an optional.

#### D4 ⚠️ `searchMessages` fetches N+1, sequentially

`IMAPClient+Search.swift:46-55` issues one `UID FETCH` per result UID, serially. A
single `UID FETCH` with a sequence set does this in one round trip. Directly speeds
up MailTriage's inbox load. Behaviour-compatible (same results, same order can be
preserved).

#### D5 ⚠️ `moveMessage(s)` sends a CAPABILITY command per call

`capability()` issues a network round trip every time (`IMAPClient+Connection.swift:74`);
`moveMessage(s)` calls it per move. Use the cached capabilities
(`connection.getCapabilities()`) for the MOVE-support check.

### E. Workaround knockouts (additive)

#### E1 ⛔️ Parsed references: `MessageSummary.referenceIDs: [String]`

`references` is the raw header value (angle brackets, folding already handled).
MailTriage strips brackets and re-splits manually. Add a parsed accessor returning
bare message-IDs; keep `references` for raw access. Additive.

#### E2 ⛔️ UIDVALIDITY guard on write operations

MailTriage manually checks `mailboxStatus().uidValidity` before every STORE/MOVE to
avoid mutating the wrong messages after a validity change — an extra round trip and a
TOCTOU race (validity can change between STATUS and the write). The library SELECTs
the mailbox inside each write anyway and the SELECT response carries UIDVALIDITY, so
it can enforce this atomically and for free.

Recommendation: optional `expectedUIDValidity: UInt32?` parameter (default `nil`) on
`storeFlags`, `moveMessages`, `copyMessages`, `expunge(uids:)`, throwing a typed
error on mismatch. Additive, race-free, removes a STATUS round trip per write.

#### E3 ⚠️ `appendMessage` should return the new UID (APPENDUID)

UIDPLUS servers return `[APPENDUID uidvalidity uid]` on APPEND. Returning
`@discardableResult ... -> UID?` (nil without UIDPLUS) is source-compatible and
directly serves MailTriage's send-pipeline work (its #163). Recommend including in
v2.0 since the response-code plumbing from #27 makes it cheap.

### F. Surface bloat

#### F1 ⛔️ Remove the convenience search wrappers

`searchMessagesFrom`, `searchMessagesBySubject`, `searchMessagesByText`,
`searchMessagesSince`, `searchUnreadMessages`, `searchFlaggedMessages`, and
`searchMessagesComplex` (`IMAPClient+Search.swift:79-198`) are trivial one-line
delegations to `searchMessages(criteria:)`, except `searchMessagesComplex`, which is
a 9-parameter footprint reimplementing `.and([...])`. None are used by any known
consumer. Seven fewer methods to document and keep compatible; README examples show
the criteria form instead.

#### F2 ⛔️ Remove deprecated `listMessages` and the sequence-number fetch path

`listMessages` has carried `@available(*, deprecated)` since v1.x; a major is when it
goes. `fetchMessageBySequence` has the same instability problem (sequence numbers
shift under concurrent changes) and no deprecation, no retry wrapper, and no known
consumer; remove it too. `MessageSequenceNumber` stays (it is a field of
`MessageSummary`).

#### F3 ✅ Keep: `storeFlags` overload family, mark-as helpers, mailbox management

The four `storeFlags` overloads ([Flag]/[String] × single/batch) are all load-bearing
or symmetric with load-bearing ones. `markAsRead`/`markAsUnread`/`markForDeletion`
are used by the MOVE fallback internally and are harmless. Mailbox CRUD is standard
IMAP and exercised by integration tests.

### G. Models and conformances

#### G1 ⚠️ Add `Equatable`/`Hashable` where missing

`MessageSummary`, `Envelope`, `BodyStructure` lack `Equatable` (e.g. `Mailbox` and
`MailboxStatus` have it). Additive, harmless, helps testing in consumers. Can also
land in a minor; include in v2.0 for tidiness.

#### G2 ⚠️ Make `ParsedMimeMessage` and `MimePart` `Sendable`

The only model types missing `Sendable`, so they cannot cross actor boundaries in
consumers without warnings (and will be errors under Swift 6). Blocked today by
`MimePart.body: MimeBody` (dependency type, not Sendable) — B4 unblocks this by
internalising `body` (storing decoded data). Do together with B4.

#### G3 ⚠️ Defer: NIOSSL types in `TLSConfiguration` (v3.0)

`minimumTLSVersion: TLSVersion`, `trustRoots: NIOSSLTrustRoots`,
`certificateVerification: CertificateVerification` leak NIOSSL types into the public
surface; customising TLS requires `import NIOSSL`. Wrapping them is real work and no
known consumer customises TLS (MailTriage uses defaults). Park for v3.0 alongside the
Swift 6 pass.

#### G4 ✅ Fine as is

- `UID = UInt32` typealias: a wrapper type would be purer but the break is not worth it.
- `Envelope`'s paired `from`/`fromEntries` properties: clunky but functional; both
  forms have users in principle (groups vs flattened); leave.
- `Flag` closed enum + `keywords: Set<String>` escape hatch: right design.
- `IMAPConfiguration` shape, defaults, and `LogLevel`: fine.
- `RetryConfiguration` + presets: fine (presets unused but cheap and self-documenting).
- `IMAPServerResponse`: well designed; semantic accessors are the right pattern.
- `RFC2047.decode`: fine as a public utility.

## Deliberately internal (revisit on demand)

- The wire layer: `IMAPParser`, `IMAPEncoder`, `IMAPResponse` (post-B1/B2/B3),
  `ConnectionActor`, channel handlers.
- IDLE: `Command.idle`/`.done` exist internally but no public API drives them. A
  future additive `idle()` AsyncSequence API is the natural v2.x feature when a
  consumer needs push semantics. Not in v2.0 scope.
- Capabilities cache: `capability()` (network) is public; the cached set is not.
  Revisit if a consumer needs sync access.

## Proposed v1.3 → v2.0 migration guide (summary)

For the README / release notes once changes land:

1. `IMAPError` is leaner and richer:
   - removed: `mailboxNotFound`, `messageNotFound`, `quotaExceeded`,
     `permissionDenied` (#27), `serverError`, `connectionError`, `disconnected`
   - reshaped: `commandFailed(IMAPServerResponse)`,
     `connectionClosed(IMAPServerResponse?)` (nil = abrupt loss),
     `authenticationFailed(IMAPServerResponse?)`, `connectionFailed(_:underlying:)`,
     `tlsError(_:underlying:)`, `timeout(command:)`
   - replace case-matching on removed cases with `IMAPServerResponse` semantic
     accessors (`isMailboxNotFound`, `isOverQuota`, `isPermissionDenied`,
     `isAuthenticationFailure`)
   - always include a `default` arm: new cases may be added in minor releases
2. Wire-level types (`IMAPResponse`, `IMAPParser`, `IMAPEncoder`,
   `IMAPCommand.Command`) are no longer public; `IMAPServerResponse.code` is now
   `IMAPResponseCode`
3. Removed convenience methods: use `searchMessages(in:criteria:)`
4. `expunge(uids:)`/`deleteMessage(s)` now require UIDPLUS rather than silently
   expunging the whole mailbox
5. `connect()` is now idempotent; `appendMessage` returns the new UID where the
   server supports UIDPLUS

## Implementation order (revised per Decisions below)

1. A1-A5 (error surface) — one PR, extends #27, includes RetryHandler dead branches
2. D1-D3 + D5 (footguns and the per-move CAPABILITY round trip) — one PR
3. C1 (idempotent `connect()`) — own PR, needs GreenMail coverage
4. B4 + G2 (MimeBody internalisation, Sendable) — one PR
5. F2 + `searchMessagesComplex` removal (surface trim) — one PR, deletions +
   README/Examples updates
6. Migration guide + CHANGELOG consolidation + enum-policy README note — final PR

---

## Independent review notes

The review is mostly sound, but it overstates the urgency of several items. I would
separate "must fix before v2.0" from "nice cleanup while the surface is already
moving."

### Poorly considered / too broad

1. **B1-B3: internalising the whole wire layer**

   The argument is MailTriage-centric: "unused by known consumers". For a public IMAP
   package, `IMAPParser`, `IMAPEncoder`, `IMAPResponse`, and `IMAPCommand.Command`
   may plausibly be useful for diagnostics, testing servers, proxies, or advanced
   clients. Removing them from public API is defensible, but the doc treats it as
   obvious. I would either keep them public but mark them as low-level/unstable in
   docs, or move this to a separate deliberate API-positioning decision.

2. **F1: removing convenience search wrappers**

   This feels unnecessary. The wrappers in `IMAPClient+Search.swift` are small and
   user-friendly. Removing them saves little maintenance and makes the API less
   approachable. `searchMessagesComplex` is uglier and could go, but deleting all
   convenience methods because MailTriage does not use them is too aggressive.

3. **E2: UIDVALIDITY guard on write operations**

   The goal is valid, but the "atomically and for free" claim is overstated. The
   library SELECTs before writes today, yes, but adding `expectedUIDValidity` to many
   write APIs expands the API and requires careful semantics around selected mailbox
   state, reconnects, and servers that omit or behave oddly. This is useful, not
   obviously v2-blocking.

4. **C2: uniform retry/reconnect across writes**

   The doc correctly notes ambiguity for writes, but the proposed "provably
   pre-execution" split is non-trivial. Today `sendCommandInternal` registers pending
   commands before write completion, and write failure handling is low-level. Building
   a correct sent/not-sent retry contract is worthwhile, but risky enough that I would
   not bundle it into an API cleanup unless there are failing production cases.

5. **E3: `appendMessage` returning UID**

   Additive and useful, but not necessary for v2. It depends on parsing APPENDUID
   response codes correctly and deciding what to return when UIDPLUS is absent. Fine
   for v2.x. Not a release blocker.

6. **G1: add `Equatable`/`Hashable` "for tidiness"**

   Harmless, but explicitly not urgent. Additive conformances can land later. I would
   not spend release focus here unless tests need them.

7. **A5: `authenticationFailed(IMAPServerResponse?)` shape**

   The problem is real: LOGIN/AUTHENTICATE rejection currently emerges as
   `commandFailed`. But changing local auth failures from a useful `String` to `nil`
   risks losing detail. Better shape would be something like
   `authenticationFailed(String, response: IMAPServerResponse?)`, or keep
   `commandFailed` plus add an `isAuthenticationFailure` classifier. The suggested
   shape is under-specified.

### Strong suggestions I agree with

- **D1 is the most important fix.** Falling back from targeted `UID EXPUNGE` to
  whole-mailbox `EXPUNGE` is a real data-loss footgun.
- **D2 should follow D1.** `deleteMessages` loops per UID and then calls
  whole-mailbox expunge.
- **D3 is valid.** `SequenceSet.set([])` returning UID `0` is a bad public trap.
- **A1-A4 are reasonable.** The error cleanup and reconnect classification are
  coherent, especially since `requiresReconnection` excludes `.disconnected` today.
- **D5 is cheap and worthwhile.** `moveMessage(s)` paying a network `CAPABILITY` each
  time is unnecessary after capabilities are cached.
- **B4 is reasonable.** Publicly exposing `MimeBody` leaks a dependency type.

### Suggested priority

For v2.0: do A1-A4, D1-D3, D5, B4, maybe C1.

Defer: B1-B3, C2, E2, E3, G1, most of F1.

Rework before accepting: A5 and the enum-policy claim that consumers "must" include
default arms. That is guidance, not something the library can enforce cleanly for
Swift package enums.

---

## Decisions (2026-06-06, post-review)

Independent review accepted; loose ends resolved as follows.

### In scope for v2.0

- **A1–A4** — error-case cleanup and reconnect classification (with regression test)
- **A5** — reworked shape: `authenticationFailed(String, response: IMAPServerResponse?)`
  (recommendation above updated to match)
- **B4 + G2** — internalise `MimePart.body`, then make `ParsedMimeMessage`/`MimePart`
  `Sendable` (G2 becomes trivial once B4 lands; bundled in one PR)
- **C1** — idempotent `connect()`: cheapest part of the resilience story, direct
  driver of the MailTriage rebuild workaround, and unlike C2 carries no
  write-idempotency risk
- **D1–D3, D5** — footguns and the per-move CAPABILITY round trip
- **F1 (partial)** — remove `searchMessagesComplex` only; the simple wrappers stay
- **F2** — remove deprecated `listMessages` and `fetchMessageBySequence` (a major is
  the only clean removal point; the latter gets no deprecation grace because it has
  the same instability problem and no known consumer)
- Migration guide, CHANGELOG consolidation, enum-policy guidance in README (reworded
  per review: guidance, not enforcement)

### Deferred

- **B1–B3** (wire-layer internalisation) — needs a deliberate API-positioning
  decision for the public package, not a side effect of this review
- **C2** (uniform write retry) — correct sent/not-sent contract is non-trivial;
  revisit if production failures demand it
- **C3** (bounded LOGOUT in `disconnect()`), **D4** (batch fetch in
  `searchMessages`), **E1** (`referenceIDs`), **E2** (UIDVALIDITY guard),
  **E3** (APPENDUID return) — all non-breaking; no major required, land in v2.x
  as needed
- **G1** (Equatable/Hashable), **G3** (NIOSSL wrapping), rest of **F1** — v2.x/v3.0

### Migration-guide impact

Items 2 and 3 of the draft migration guide shrink accordingly (wire types stay
public; only `searchMessagesComplex`, `listMessages`, and `fetchMessageBySequence`
are removed; `appendMessage` keeps its current signature).
