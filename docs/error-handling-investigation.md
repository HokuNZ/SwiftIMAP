# Error handling investigation

Investigation prompted by **MailTriage #226** ("enrich IMAPService move/copy errors with folder, UID, and server response"). MailTriage wants to attach the IMAP **server response line** (the `NO`/`BAD` status plus its text and response code) to its Bugsnag metadata. This document records what SwiftIMAP currently exposes, the gaps, and the API change required.

## TL;DR

- The server's response **text** is already available to consumers via `IMAPError.commandFailed(command:response:)` — but the bracketed **response code** (`[TRYCREATE]`, `[NONEXISTENT]`, `[OVERQUOTA]`, ...) and the **`NO` vs `BAD`** distinction are **silently discarded** at the point the error is built. So MailTriage cannot reconstruct a faithful server response line from the current API.
- Four structured error cases (`mailboxNotFound`, `messageNotFound`, `quotaExceeded`, `permissionDenied`) are **declared but never produced**. Every server rejection collapses into the single generic `commandFailed`.
- ⛔️ **Security**: the `command` field of `commandFailed` is `String(describing:)` of the command enum, which embeds the **cleartext password** for `LOGIN` and the **full message body** for `APPEND`. `errorDescription` interpolates this, so `error.localizedDescription` on a failed login leaks credentials into any log or crash report. This directly violates the "never log credentials" rule in `AGENTS.md`.
- The API change MailTriage needs: expose the structured server response (status, response code, text, and a reconstructed line) on the thrown error, and stop embedding command arguments.

## Evidence

### 1. Where the error is built — the lossy site

`Sources/SwiftIMAP/Networking/ConnectionActor.swift:414`

```swift
case .no(_, let message), .bad(_, let message):
    let error = IMAPError.commandFailed(
        command: String(describing: pending.command.command),
        response: message ?? "Unknown error"
    )
    pending.continuation.resume(throwing: error)
```

Three losses happen here:

- **Response code dropped.** `.no(_, ...)` / `.bad(_, ...)` discard the `ResponseCode?` first tuple element. The parser has already extracted it (see below), so `[TRYCREATE]`, `[NONEXISTENT]`, `[OVERQUOTA]`, `[ALERT]`, `[INUSE]`, etc. are thrown away. That code is the single most machine-actionable field for distinguishing the mutually-exclusive causes the MailTriage issue calls out (folder missing vs quota vs server-side rule).
- **`NO` vs `BAD` collapsed.** Both map to one `commandFailed` case. `NO` = operational failure (retry/repair candidate); `BAD` = protocol/syntax error (a client bug, never retry). Consumers cannot tell them apart.
- **Code stripped from the text too.** The parser separates the bracket code from the trailing text, so even `response` does **not** contain `[NONEXISTENT]` — only the human prose after it.

### 2. The parser already has the structured data

`Sources/SwiftIMAP/Protocol/IMAPParser+Responses.swift:137` (`parseResponseCodeAndText`) splits `[CODE] text` into `(ResponseCode?, String?)`, and `parseResponseCode` (`:159`) maps known codes to typed cases, falling back to `.other(name, value)` for unknown ones (`:210`). So the information MailTriage wants is parsed and then deliberately dropped one layer up. No new parsing is required — only plumbing it through the error.

`IMAPResponse.ResponseStatus` and `ResponseCode` are already `public` (`Sources/SwiftIMAP/Protocol/IMAPResponse.swift:8` and `:30`), so they can be surfaced on the error without new public types.

### 3. Dead error cases

Counting producers in `Sources/` (excluding the enum declaration itself):

| Case | Producers | Notes |
|------|-----------|-------|
| `commandFailed` | 1 | the only path for every server `NO`/`BAD` |
| `mailboxNotFound` | 0 | declared, never thrown |
| `messageNotFound` | 0 | declared, never thrown |
| `quotaExceeded` | 0 | declared, never thrown |
| `permissionDenied` | 0 | declared, never thrown |

A `MOVE` to a non-existent folder returns `commandFailed`, not `mailboxNotFound`; an over-quota `APPEND`/`COPY` returns `commandFailed`, not `quotaExceeded`. The structured cases are aspirational. They could be populated by mapping response codes (`[NONEXISTENT]`/`[TRYCREATE]` → `mailboxNotFound`, `[OVERQUOTA]` → `quotaExceeded`, `[NOPERM]` → `permissionDenied`) — but only once the code is actually carried through (gap 1).

### 4. ⛔️ Credential / payload leak via `String(describing:)`

`Sources/SwiftIMAP/Protocol/IMAPCommand.swift:18` — `case login(username: String, password: String)`.

The login path reaches the lossy site: `IMAPClient+Connection.swift:99` calls `connection.sendCommand(.login(...))`, and a rejected login returns a tagged `NO`, so `ConnectionActor.swift:415` builds:

```swift
command: String(describing: .login(username: "user@x", password: "hunter2"))
// => "login(username: \"user@x\", password: \"hunter2\")"
```

`IMAPError.errorDescription` (`Errors/IMAPError.swift:39`) then interpolates that into:

```
Command 'login(username: "user@x", password: "hunter2")' failed: ...
```

So `error.localizedDescription` on a failed login contains the plaintext password. Same mechanism leaks:

- the base64 SASL initial response (PLAIN credentials / OAuth2 access token) for `.authenticate(mechanism:initialResponse:)` (`IMAPCommand.swift:17`);
- the **entire message body** for `.append(... data: Data)` (`IMAPCommand.swift:29`).

If MailTriage forwards `IMAPError` text to Bugsnag (the obvious thing for issue #226 to do), it would publish credentials and message content. This must be fixed as part of the same change, not after.

### 5. Retry classification can't see server intent

`Sources/SwiftIMAP/Utilities/RetryHandler.swift:127` only treats `.serverError` (matched on substrings like `UNAVAILABLE`, `TRY AGAIN`) as a temporary failure. But server rejections arrive as `.commandFailed`, which hits `default: return false` (`:132`) — non-retryable. A transient `NO [INUSE]`/`NO [UNAVAILABLE]` is therefore never retried even when retry would help, and there is no typed signal (status/code) for the retry handler to make that decision correctly. Carrying the structured response would let `isRetryableError` branch on `[INUSE]`/`[UNAVAILABLE]`/`[SERVERBUG]` instead of substring-sniffing free text.

## Other error sites worth fixing in the same pass

Sweeping every `IMAPError` producer (not just the move/copy path) surfaces the same two themes — **context discarded at construction** and **typed information flattened to strings** — in several more places. Folding them into one change avoids churning the public error surface twice.

### 6. `connect()` retries are a no-op for real connection failures

`ConnectionActor.connect()` wraps every failure as `IMAPError.connectionFailed(error.localizedDescription)` (`ConnectionActor.swift:173`). But `RetryHandler.isRetryableError` only retries `.connectionError`/`.connectionClosed` (`RetryHandler.swift:123`) — `.connectionFailed` is absent, so it falls to `default: return false`. Since `IMAPClient.connect()` runs inside `retryHandler.execute(operation: "connect")` (`IMAPClient+Connection.swift:24`), a refused/DNS/transient connection failure is **never retried** — the retry wrapper around connect does nothing. `connectionFailed` and `connectionError` are near-duplicate cases with diverging retry behaviour; they should be unified, or `connectionFailed` added to the retryable set.

### 7. Underlying errors flattened to strings (`connectionFailed`, `tlsError`)

- `ConnectionActor.swift:173` — `connectionFailed(error.localizedDescription)` discards the typed underlying error (NIO `NIOConnectionError`, POSIX errno, DNS failure). On Apple platforms these often stringify to unhelpful generic text, losing exactly the connection-state detail #226 wants for diagnosis.
- `ConnectionActor.swift:197` — `tlsError(error.localizedDescription)` likewise drops the `NIOSSLError` / certificate-chain detail.

Both should retain `underlying: Error` (as an associated value) so consumers can inspect or report the real cause. AGENTS.md already promises "network errors include connection state information" — today they don't.

### 8. `timeout` carries no context

`handleTimeout` (`ConnectionActor.swift:610`) has the `tag` and the full `pending.command` in scope but throws a bare `IMAPError.timeout` (`:616`). The greeting path (`:457`) does the same. A timeout on `UID MOVE` and a timeout on the initial greeting are indistinguishable to the caller — directly the kind of "we can't tell what failed" gap this investigation is about. Attach the command label (the same argument-free label introduced for the security fix) and ideally the elapsed seconds. Note also the greeting timeout is hardcoded to 5s (`:458`) and ignores `configuration.connectionTimeout` — worth correcting while in here.

### 9. `BYE` greeting text discarded — same loss as `NO`/`BAD`

`IMAPClient+Connection.swift:33` maps a `* BYE` greeting to a bare `IMAPError.connectionClosed`, discarding the `ResponseCode?` and text. Servers reject connections with actionable detail here — `BYE [ALERT] Too many connections`, `BYE [UNAVAILABLE] ...`, account-disabled messages. This is the same structured-response loss as the `NO`/`BAD` path and should reuse the same `IMAPServerResponse` treatment (extend `Status` with a `bye` case, or surface it on a `connectionClosed(IMAPServerResponse?)`).

### 10. Parser errors may embed raw message bytes (privacy)

The 50+ `parsingError(String)` sites deliberately include the offending input (AGENTS.md: "parser errors include the problematic input line"). For `FETCH` body/envelope/body-structure failures that "input" is **message content** — subject lines, body fragments. If MailTriage logs `parsingError` text to Bugsnag, email content leaks. Lower severity than the credential leak (gap 4) but the same privacy family. Recommend truncating embedded input and/or tagging these errors so the consumer can choose not to forward the payload.

## The API change MailTriage needs

MailTriage's `IMAPOperationError` wants `serverResponseLine: String?`. To supply it faithfully, SwiftIMAP must surface the structured rejection. Proposed shape:

```swift
public struct IMAPServerResponse: Sendable, Equatable {
    public enum Status: String, Sendable { case no = "NO", bad = "BAD" }

    public let status: Status                       // NO vs BAD
    public let code: IMAPResponse.ResponseCode?     // [TRYCREATE], [OVERQUOTA], .other(...)
    public let text: String?                        // human text after the code
    public let commandName: String                  // sanitised, e.g. "UID MOVE" — NEVER arguments

    /// Reconstructed server line for logging: `NO [TRYCREATE] Mailbox does not exist`
    public var line: String {
        var parts = [status.rawValue]
        if let code { parts.append("[\(Self.render(code))]") }
        if let text { parts.append(text) }
        return parts.joined(separator: " ")
    }
}
```

Then carry it on the error. Cleanest is to redesign the single producing case rather than add a parallel one:

```swift
case commandFailed(IMAPServerResponse)
```

and at `ConnectionActor.swift:414`:

```swift
case .no(let code, let text), .bad(let code, let text):
    let response = IMAPServerResponse(
        status: isNo ? .no : .bad,
        code: code,
        text: text,
        commandName: pending.command.command.label   // new: argument-free label
    )
    pending.continuation.resume(throwing: IMAPError.commandFailed(response))
```

Add an argument-free `label` (or `commandName`) to `IMAPCommand.Command` (`"LOGIN"`, `"UID MOVE"`, `"APPEND"`, ...) and use it everywhere instead of `String(describing:)`. This both gives MailTriage a clean operation string and closes the credential/payload leak.

### Compatibility note

`commandFailed(command:response:)` is part of the public API at v1.2.4, so changing its shape is source-breaking. Options, in order of preference:

1. **Redesign `commandFailed` to carry `IMAPServerResponse`** and ship as **v2.0** (or v1.3 with a deprecation shim). Cleanest long-term; MailTriage is the only known consumer and the team controls it.
2. **Keep `commandFailed(command:response:)`, add `commandRejected(IMAPServerResponse)`** as a new case and switch the producer to it. Additive (minor bump) but leaves a dead legacy case and two ways to express the same thing.

Recommendation: option 1, bundled with the credential-leak fix, as a single v2.0. The leak fix is a security change that justifies the breaking bump on its own, and doing both at once avoids two churns of the public error surface.

### Acceptance-criteria mapping (issue #226)

- folder path, message UID, account provider id — these live in **MailTriage**'s wrapper; SwiftIMAP doesn't have them and shouldn't. No SwiftIMAP change needed.
- **server response line** — needs the change above (`IMAPServerResponse.line`).
- "verified via a deliberate failure (move to non-existent folder against GreenMail)" — add a SwiftIMAP integration test asserting the thrown `commandFailed` carries `status == .no` and a `[TRYCREATE]`/`[NONEXISTENT]` code, so the contract MailTriage relies on is locked in.

## Combined change for v2.0

These all touch the public error surface, so doing them together as one breaking release (rather than fragmenting) is the right call. Ordered by dependency:

1. **Sanitised command label** — add an argument-free `label`/`commandName` to `IMAPCommand.Command` (`"LOGIN"`, `"UID MOVE"`, `"APPEND"`, ...). This is the foundation for the rest and closes the credential/payload leak (gaps 4, 8). Add a test that a failed `LOGIN` error contains neither username nor password.
2. **`IMAPServerResponse`** — new struct carrying status (`NO`/`BAD`/`BYE`), `ResponseCode?`, text, and the sanitised command label, with a computed `.line` for logging. Carry it on `commandFailed` and fold the `BYE` greeting into it (gaps 1, 2, 9). Add a GreenMail test for a rejected `MOVE` asserting `status == .no` and a `[TRYCREATE]`/`[NONEXISTENT]` code — this locks the contract MailTriage depends on.
3. **Preserve underlying errors** — give `connectionFailed` and `tlsError` an `underlying: Error` associated value instead of `error.localizedDescription` (gap 7).
4. **Context on `timeout`** — attach the command label and elapsed seconds; fix the greeting timeout to honour `configuration.connectionTimeout` (gap 8).
5. **Retry consistency** — unify `connectionFailed`/`connectionError` (or add `connectionFailed` to the retryable set) so `connect()` actually retries (gap 6); branch `isRetryableError` on the typed status/code (`[INUSE]`, `[UNAVAILABLE]`) instead of substring-matching free text (gap 5).
6. **Dead cases** — either populate `mailboxNotFound`/`messageNotFound`/`quotaExceeded`/`permissionDenied` by mapping response codes (`[NONEXISTENT]`/`[TRYCREATE]`, `[OVERQUOTA]`, `[NOPERM]`), or remove them as dead API (gap 3).
7. **Parser-input privacy** — truncate or tag the raw input embedded in `parsingError` so consumers can avoid forwarding message content to crash reporters (gap 10).

Items 1–2 directly satisfy MailTriage #226's server-response-line requirement; 3–7 are the rest of the library's error surface caught in the same sweep. The credential-leak fix (item 1) is reason enough for the major bump on its own.
