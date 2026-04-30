# AGENTS.md

Project context for AI coding agents working in this repository.

## Project Overview

SwiftIMAP is a modern, pure-Swift IMAP client framework providing a lightweight, async/await-first API for common mail operations, with no C/Objective-C dependencies.

## Project Structure

- `Sources/SwiftIMAP/` holds the library code (protocol parsing/encoding, networking, models, configuration).
- `Sources/IMAPCLITool/` contains the command-line tester.
- `Tests/SwiftIMAPTests/` includes XCTest unit and integration tests.
- `Examples/` provides sample usage; root `debug_*.swift` scripts are ad-hoc helpers.
- `Package.swift` defines the library product `SwiftIMAP` and CLI product `swift-imap-tester`.

## Build, Test, and Development Commands

```bash
swift build                                         # build library and CLI
swift build --product swift-imap-tester             # build the CLI only
swift test                                          # run the full test suite
swift test --filter IMAPParserTests                 # focused test class
swift test --enable-code-coverage                   # with coverage data
scripts/run-greenmail-tests.sh                      # GreenMail integration tests (Docker)
swift package generate-documentation                # DocC output
.build/debug/swift-imap-tester --help               # run the CLI locally
```

## Architecture

```
┌─────────┐     ┌─────────────┐     ┌───────────────────┐
│ TLS I/O │ ◄──► │  IMAPCodec  │ ◄──► │ Async High-Level  │
│(SwiftNIO)│    │  (parser)   │     │     API Layer     │
└─────────┘     └─────────────┘     └───────────────────┘
```

- **Network layer**: SwiftNIO + NIOSSL for non-blocking I/O.
- **IMAPCodec**: bidirectional parser/encoder for the IMAP wire format.
- **API layer**: developer-facing async/await APIs.

## Key Components

1. `Sources/SwiftIMAP/IMAPClient.swift` — main client API.
2. `Sources/SwiftIMAP/Protocol/IMAPParser.swift` — parses server responses.
3. `Sources/SwiftIMAP/Protocol/IMAPEncoder.swift` — encodes commands.
4. `Sources/SwiftIMAP/Networking/ConnectionActor.swift` — manages connection state.
5. `Sources/SwiftIMAP/Models/` — data models for mailboxes, messages, etc.

## Coding Style and Conventions

- Swift 5.10+, async/await-first APIs; keep public APIs `async throws`.
- Follow `.swiftlint.yml` (run `swiftlint` if installed); no `print` in library code, use `Logger`.
- 4-space indentation. Swift standard naming: `PascalCase` types, `camelCase` methods/vars.
- Extension files use `Type+Feature.swift` (e.g., `MessageSummary+MIME.swift`).
- All public APIs must be `async throws`; use actors for thread-safe state.
- Use `IMAPError` for all errors; include raw server messages where useful.

## Testing Guidelines

- Tests use XCTest under `Tests/SwiftIMAPTests/`; test methods start with `test...`.
- Integration tests use a mock IMAP server and skip when `CI` is set.
- Add or extend tests for any protocol parser/encoder change or new IMAP command.
- Unit tests cover parser codecs, model mapping, and error handling.
- Integration tests can run against Dockerized GreenMail.
- Use the CLI tool for manual checks against real servers.

## Commit and Pull Request Guidelines

- Commit subjects are short, imperative, and sentence case (e.g. "Fix build errors").
- PRs include a concise summary, testing results (commands run), and notes on any user-facing changes.
- Link related issues and update `README.md` / `Examples/` for API changes.

## Security and Configuration Notes

- TLS 1.2+ is the default; never log credentials or raw auth tokens.
- Configure TLS/auth via `IMAPConfiguration` rather than ad-hoc options.

## Debugging Tips

1. Use `--verbose` with the CLI tool to see detailed logs.
2. Set log level to `.trace` for maximum detail.
3. Parser errors include the problematic input line.
4. Network errors include connection state information.

## Common Issues

1. **Modified UTF-7 encoding**: mailbox names use a special encoding — see `IMAPEncoder.encodeModifiedUTF7`.
2. **Response parsing**: some servers send non-standard responses — the parser is intentionally lenient.
3. **TLS**: some servers require specific TLS versions or cipher suites.
4. **Authentication**: different servers support different mechanisms — check the `CAPABILITY` response.

## Release Management

### Versioning

[Semantic versioning](https://semver.org/). Version tags follow `vMAJOR.MINOR.PATCH`.

Consumers reference SwiftIMAP via:

```swift
.package(url: "https://github.com/HokuNZ/SwiftIMAP.git", from: "1.0.0")
```

- Tags (e.g. `v1.0`, `v1.1`) are immutable release points.
- `main` is the development branch for the next release.
- Existing apps build against tagged versions while new work proceeds on `main`.

### CHANGELOG.md

- Every merge to `main` must include a CHANGELOG.md update.
- Add entries under `[Unreleased]`.
- Use categories: Added, Changed, Deprecated, Removed, Fixed, Security.
- Link related PRs/issues with `(#N)` syntax.
- When releasing, move `Unreleased` items to a dated version section.

### GitHub Milestones

- Create a milestone for each upcoming release (e.g. `v1.1`).
- Assign related PRs and issues to the milestone.
- Close the milestone on release.

### Releasing a Version

**Pre-release checklist:**
- [ ] All milestone PRs merged.
- [ ] `swift test` passes.
- [ ] CHANGELOG.md has entries for all changes.

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
- Close the GitHub milestone.
- Notify dependent projects (e.g. MailTriage) that they can update their version reference.
