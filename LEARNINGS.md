# Learnings

Lessons captured from past work to inform future development. Updated when merging PRs.

---

## SwiftPM dependencies

- **Never pin dependencies by `branch:`**: SwiftPM rejects any graph where a stable-version consumer depends on a branch-pinned transitive dep ("required using a stable-version but ... depends on an unstable-version package"). Use `version:`, `from:`, `exact:`, or `revision:` for any dep we expect downstream apps to pin against. Branch pins break `exactVersion`, `upToNextMajor`, and every other stable constraint.
- **Prefer `revision:` over `from:` when upstream master is ahead of the latest tag**: For dormant deps, `from: "<tag>"` silently regresses past any unreleased fixes on master. Check `gh api repos/<owner>/<repo>/compare/<latest-tag>...master --jq '{ahead_by, commits}'` before choosing. If commits are real bug fixes (not just CI plumbing), pin to a SHA on master.
- **`Package.resolved` is gitignored for libraries in this repo**: Only apps commit `Package.resolved` (they dictate the resolved graph for the whole tree). Don't include it in PR diffs.
- **`swift package resolve` is a no-op if the SHA already matches**: After flipping a manifest from `branch: "master"` to `revision: "<sha>"`, `Package.resolved` may retain the stale `"branch": "master"` hint alongside the revision. To force a clean rewrite: `swift package reset && rm -rf .build .swiftpm Package.resolved && swift package resolve`.
- **Use precise SwiftPM terminology in docs and comments**: API spellings are `.exact("...")`, `.upToNextMajor(from:)`, etc. Xcode's UI labels are "Exact Version", "Up to Next Major". Avoid camel-cased pseudo-names like `exactVersion` or `upToNextMajor` — they imply a SwiftPM API that doesn't exist.

## Evaluating dormant dependencies

- **Audit fork health via the GitHub compare API, not the forks page**: `gh api repos/<owner>/<repo>/forks` lists 20+ forks for any modestly popular repo, almost all stale clones. To find a fork that has actually diverged: `gh api repos/<fork>/<repo>/compare/<upstream>:master...<fork>:master --jq '{ahead_by, behind_by}'`. Anything with `ahead_by: 0` is just a clone.
- **Inventory open issues before forking**: A fork inherits responsibility for upstream's open issues. List them with `gh api 'repos/<owner>/<repo>/issues?state=open'` and the open PRs with `pulls?state=open` so the cost of ownership is explicit before committing.

## Cross-platform Foundation

- **`CFString*` IANA-registry APIs are Apple-only**: `CFStringConvertIANACharSetNameToEncoding`, `CFStringConvertEncodingToNSStringEncoding`, `CFString`, `kCFStringEncodingInvalidId` are not in swift-corelibs-foundation. Anything that imports them needs a `#if canImport(Darwin)` guard with a sensible non-Apple fallback (UTF-8 is usually fine for charset-resolution paths). Linux compile failures here can sit hidden if the only Linux CI job runs against external services that fail for unrelated reasons (see `CI workflow design` below).
- **`String.Encoding` coverage on Linux is uneven**: Named constants like `.shiftJIS`, `.iso2022JP`, `.japaneseEUC`, `.utf16LittleEndian`, `.utf16BigEndian` *compile* on Linux (constants exist in swift-corelibs-foundation), but `String(data:encoding:)` only successfully decodes some of them — coverage depends on the platform's ICU build. In `swift:5.10` Docker, Shift-JIS / ISO-2022-JP / UTF-16LE/BE work; EUC-JP returns nil. Don't assume "compiles on Linux" means "works on Linux" for these encodings.
- **For tests that exercise platform-divergent behaviour, prefer conditional asserts over skipping**: `#if canImport(Darwin) ... #else ... #endif` inside a single test documents what the platform actually does (e.g. EUC-JP decodes to `あ` on Apple, passes through verbatim on Linux). Skipping hides the contract; conditional asserts pin both behaviours so a regression in either platform fails CI.

## CI workflow design

- **A separate `swift build` / unit-test job for each platform is non-negotiable**: A single integration job that depends on Docker services (e.g. GreenMail) can hide compile failures behind unrelated service problems. PR #18 / v1.2.2 / v1.2.3 shipped a Linux compile bug because `greenmail-integration` was the only Linux job and its red status looked like flake. The fix (PR #20): add a plain `test-linux` job (no services) that just builds and runs the unit suite. Apply the same pattern for any new platform-target.
- **A red CI run can still be merged**: branch protection has to explicitly require each check by name. Adding a job to `release.needs:` in the workflow only gates the *release* step, not the merge button. PR #18 merged red because `greenmail-integration` wasn't a required check at the repo level. Worth verifying required-check settings periodically.
- **PR review for substantive changes**: `code-reviewer` agent on the diff before opening the PR catches issues that would otherwise come back via Copilot. Cheap insurance.

## `gh` CLI tricks

- **Per-job logs are available while the run is still in progress**: `gh run view --log-failed` waits for the whole workflow to complete. `gh api repos/<owner>/<repo>/actions/jobs/<job-id>/logs` returns immediately for any completed job, even while sibling jobs are still running. Find the job id via `gh api repos/<owner>/<repo>/actions/runs/<run-id>/jobs --jq '.jobs[] | select(.name=="<job>") | .id'`.
- **`gh run rerun <id> --failed`** re-runs only the failed jobs of a completed run, not the whole workflow. Won't work while the run is still `in_progress` (you'll get "cannot be rerun; This workflow is already running") — wait for the run to finish first.
- **`gh release edit --notes-file <path>`** retrofits release notes on an existing tag without retagging. Useful for adding ⚠️ notes to releases that shipped with platform-specific bugs (we did this for v1.2.2 and v1.2.3 rather than yanking). Tags, CHANGELOG.md, and downstream consumers stay untouched.

## Test infrastructure

- **`MockIMAPServer` has a known data race** (issues #19, #21): `responses: [String: String]` is mutated from the test task via `setResponse` and read from the NIO event-loop thread via `MockIMAPHandler.channelActive`. On macOS this is intermittent flake (`testMessageOperationsWithMockServer`, `testStartTLSUnsupportedCapabilityThrows`). On Linux it's deterministic for `testFetchMessageBodyFindsCorrectBodyAmongMultipleResponses`. The fix is to actor-wrap (or lock) `responses`, `receivedCommands`, `receivedContinuations`, `pendingAuthTag`, `pendingAuthChallenges` — anything mutated outside the event loop. Until that lands, the affected test is skipped on Linux via `XCTSkipIf` referencing #21.
- **A 5.005-second test runtime is a smoking gun**: it matches the `waitForGreeting` timeout at `Sources/SwiftIMAP/Networking/ConnectionActor.swift:456`. If a test fails with `connectionFailed("Operation timed out")` and runs for ~5s, the TCP connect almost certainly succeeded — the IMAP greeting just never arrived. Look at the mock server's `channelActive`, not the network layer.

## Reviewing Copilot suggestions

- **Always evaluate against actual evidence**: Copilot suggested removing `--skip GreenMailIntegrationTests` because "swift test option support varies across SwiftPM versions" — but we'd just observed `--skip` succeed twice on `swift:5.10` in this exact CI job. The test-coverage suggestion was a real gap (5 new charset cases with no tests); the `--skip` suggestion had a flawed premise. Reply on PR with the rationale for any skipped suggestion so the next reader sees why.
