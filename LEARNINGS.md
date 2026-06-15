# Learnings

Lessons from past work, to inform future development. Updated when merging PRs.

## SwiftPM & forked dependencies

- **Only a semver *tag* is a stable pin.** SwiftPM rejects a graph where a version-resolved consumer depends on a `branch:`- or `revision:`-pinned transitive dep (a SHA is an audit point, not a version) — which is why MimeParser is forked and tagged (#12/#13/#14). If downstream apps pin us by version, every transitive dep needs a tagged release.
- **Verify resolution from the consumer side.** `swift build`/`test` and `Package.resolved` inside the package never apply downstream constraints (#14 passed all three while #12 stayed broken). Reproduce with a throwaway consumer that pins via `.exact(...)` against a `file://` clone with local tags, including a negative control (the old tag must fail) so green isn't a false positive.
- When a dormant upstream's tag lags master, audit the gap before re-pinning: `gh api .../compare/<tag>...master --jq '{ahead_by,commits}'`. A fork inherits upstream's open issues.

## Cross-platform (Linux) Foundation

- **`CFString*` IANA-charset APIs are Apple-only** (absent from swift-corelibs-foundation) — guard with `#if canImport(Darwin)` and a UTF-8 fallback.
- **"Compiles on Linux" ≠ "works on Linux"** for `String.Encoding`: the named constants exist, but `String(data:encoding:)` decodes only some (Shift-JIS / ISO-2022-JP / UTF-16 work on `swift:5.10`; EUC-JP returns nil). For platform-divergent behaviour, prefer `#if canImport(Darwin)` *conditional asserts* over skipping, so both contracts are pinned against regressions.

## CI & GitHub Actions

- **One plain `build` + unit-test job per platform is non-negotiable.** A single integration job behind Docker services (GreenMail) hides compile failures behind unrelated service flake — a Linux compile bug shipped in v1.2.2/3 this way. Add a services-free `test-linux`.
- **A long-lived release branch needs its own PR trigger.** `pull_request: branches: [main]` ran zero CI on PRs into `version/v2.0` ("no checks reported" reads as pending, not never-ran). Use `branches: [ main, 'version/**' ]` when making a `version/*` branch.
- **A red run can still merge** unless each check is a *required* status at the repo level — a job in `release.needs:` only gates the release step, not the merge button.
- **A wildly-long or `CANCELLED` job is infra, not your code** (GreenMail hung 45 min with zero test output; `test-macos` cancelled mid-step). Prove the code with a local run, then `gh run rerun <id> --failed`; a `timeout-minutes` makes a hang fail fast.
- **Re-trigger via an empty commit, not close/reopen** — close/reopen fires `synchronize` unreliably; `git commit --allow-empty` always does.
- **Pushing a tag auto-creates the GitHub Release here** (the `release` job runs `action-gh-release` with `generate_release_notes`), so `gh release create` can race it (HTTP 422, tag exists). Prefer `gh release edit <tag> --notes-file …` to replace the auto-notes.

## `gh` CLI

- **Per-job logs while the run is still going:** `gh api repos/<o>/<r>/actions/jobs/<job-id>/logs` (id via `…/runs/<run-id>/jobs`). `gh run view --log-failed` waits for the whole run and truncates around the annotation; for full output, `… /runs/<run-id>/logs > logs.zip`.
- **`gh pr checks` exit codes:** 0 all-pass, 1 failed, 8 pending — script on these, not the text. `--watch` blocks until done.
- **`mergeStateStatus` is stale right after a force-push** (can wrongly say CONFLICTING) — verify locally with `git merge-base --is-ancestor origin/main <branch>`.
- **Stacked-PR base-branch hazards:** FF-merging a PR's commits into its base auto-marks it MERGED (can't then `gh pr close`); deleting a merged base branch auto-CLOSES a stacked child PR, which can't be reopened or retargeted. Retarget the child to the grandparent base *before* deleting, or recreate it from its surviving branch. (`gh issue develop --base <feature>` also doesn't reliably branch from that feature — `git log -1` after checkout and `reset --hard` while empty.)

## Test infrastructure

- **`MockIMAPServer` shared state is serialised behind a `NIOLock`** (#21/#24); `channel` is test-task-only and stays outside it. Return a fresh snapshot inside the lock (`Array(_x)`): a COW-shared array iterated outside the lock is UB on a later append. It lives in its own file because `file_length` is an *error*-severity lint (1200 lines).
- **A ~5.005 s timeout failure is a smoking gun** for the `waitForGreeting` timeout — TCP connected, the IMAP greeting never arrived; look at the mock's `channelActive`, not the network layer.
- **"100% on platform X, ~1% on Y" is one race, not platform-specificity.** Fix the race; don't reach for `#if os(...)`.
- **Write the end-to-end test the spec asks for, first.** #35's classification tests passed while the feature had never worked; a second hidden defect only surfaced when the end-to-end test was written. The mock has hooks for this — a one-shot hang-up (`closeOnceAfterResponse`) for reconnect tests, and `setResponseSequence` to serve different pre/post-auth data so a count assertion can't masquerade as a semantic one.

## Reviewing changes & agent feedback

- **Every reviewer finding (Copilot or agent) is a lead, not a verdict — verify against source, the build, or a probe before acting.** Real catches: guard *ordering* (the UIDPLUS guard ran after STORE/SELECT — assert the *absence* of each side effect, not just the outcome), memory doubling, capability case-sensitivity. False positives that cost time if applied blindly: optional-pattern "won't match" (matching a non-optional case against an `Optional` is valid Swift), a stale PREAUTH cache (CAPABILITY after PREAUTH already runs authenticated), and `Task.value` cancellation — each refuted by a ten-line probe or by reading the call order.
- **Audit the real consumer (MailTriage) before classifying breaking changes** — reading its source turned "limit breaking changes" into a *measured* cost (the two files it already had to touch) and surfaced the workaround list that drove the highest-value fixes.
- **Copilot reviews a specific `commit.oid` and goes stale after a push** (no auto-re-review). Compare its oid to the PR head; re-request with `gh pr edit <n> --add-reviewer copilot-pull-request-reviewer` (the pending request only shows via GraphQL as a `Bot`).
- **Background agents must diff refs, never check out branches.** A bare `git checkout` can detach or steal the main worktree and leave the shell cwd in a stray `.claude/worktrees/agent-*` (contradictory file states). Prompt `git diff ref...ref` / `--detach`; after agents finish, verify `git rev-parse --show-toplevel` and `git worktree remove --force` leftovers.

## Error & API design (security)

- **Never put a secret-carrying command/enum into human-facing text.** `String(describing:)` of `commandFailed`'s command leaked the cleartext `LOGIN` password (and `APPEND` body) into the error, its `localizedDescription`, the command debug log, and validator messages (#27). Use an argument-free label (the bare verb). Synthesised reflection leaks the same way in logs — audit every `\(someEnum)` that can carry `Data`/credentials (a trace log dumped full FETCH payloads, #29). Truncate untrusted server input before interpolating it into a parser error (`truncatedForDiagnostics`).
- **Prefer one structured error + accessors over many bespoke cases, and grep for producers.** 7 of 17 `IMAPError` cases had zero `throw` sites (#27/#35) — consumers were exhaustively handling impossible errors. Replaced with `commandFailed(IMAPServerResponse)` + semantic accessors keyed on the RFC 5530 code.
- **Two classifiers over one error space drift apart.** `isRetryableError` vs `requiresReconnection` left abrupt drops neither retryable nor reconnectable. Diff one's case list against the other when touching either.
- **Wrap foreign errors into the typed error at the boundary.** Raw NIO/SSL errors dispatched to pending commands bypassed every `as? IMAPError` (no retry/reconnect). Convert at the boundary, preserving the original as `underlying`.

## Swift & NIO concurrency

- **`NIOLock` is non-reentrant** — a handler running under `withLock` must not call back into the locked accessor. Clear a one-shot handler by mutating the ivar directly, not via `setResponseHandler(nil)`.
- **`Task.value` is not responsive to the *awaiting* task's cancellation** (verified, Swift 5.10): a cancelled waiter still suspends until the task completes and gets its result. This makes "store the in-flight `Task`, late callers await `.value`" a sound coalescing pattern on an actor (the `ConnectCoordinator`).

## IMAP protocol

- **Never fall back from `UID EXPUNGE` to bare `EXPUNGE`** — the bare form expunges *every* `\Deleted` message, not the named UIDs: silent data loss dressed as graceful degradation. Without UIDPLUS, the only safe targeted expunge is to throw.
- **Capability tokens are case-insensitive (RFC 3501 §7.2.1)** — normalise to upper case at the cache-write boundary so every gate (MOVE/UIDPLUS/LITERAL+/…) compares against upper-case literals. The set can differ pre- and post-auth: refresh once post-auth in `connect()` (a PREAUTH greeting needs no extra refresh).
- **A `* BYE` before a LOGOUT's tagged `OK` is normal.** Capture an unsolicited mid-session BYE's code/text in `pendingBye` and only convert pending commands to `connectionClosed(...)` at teardown (`channelInactive`) — applying it when the BYE arrives wrongly fails a legitimate LOGOUT.

## Git: long-lived branches

- **Rebasing a long-lived branch onto `main` re-conflicts on `CHANGELOG.md`** at every commit that touched `[Unreleased]` — prefer `git merge main` (resolves the section once). `GIT_EDITOR=true git rebase --continue` skips the editor prompt this harness can't drive.
