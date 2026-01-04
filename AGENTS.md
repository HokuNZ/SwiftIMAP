# Repository Guidelines

## Project Structure & Module Organization
- `Sources/SwiftIMAP/` holds the library code (protocol parsing/encoding, networking, models, configuration).
- `Sources/IMAPCLITool/` contains the command-line tester.
- `Tests/SwiftIMAPTests/` includes XCTest unit and integration tests.
- `Examples/` provides sample usage; root `debug_*.swift` scripts are ad-hoc helpers.
- `Package.swift` defines the library product `SwiftIMAP` and CLI product `swift-imap-tester`.

## Build, Test, and Development Commands
- `swift build` builds the library and CLI targets.
- `swift build --product swift-imap-tester` builds only the CLI tool.
- `swift test` runs the full test suite.
- `swift test --filter IMAPParserTests` runs a focused test case/class.
- `swift test --enable-code-coverage` produces coverage data.
- `scripts/run-greenmail-tests.sh` runs GreenMail integration tests (requires Docker).
- `swift package generate-documentation` generates DocC output (if needed).
- `.build/debug/swift-imap-tester --help` runs the CLI locally.

## Coding Style & Naming Conventions
- Swift 5.10+, async/await-first APIs; keep public APIs `async throws`.
- Follow `.swiftlint.yml` (run `swiftlint` if installed); no `print` in library code, use `Logger`.
- 4-space indentation and Swift standard naming: `PascalCase` types, `camelCase` methods/vars.
- Extension files use `Type+Feature.swift` (e.g., `MessageSummary+MIME.swift`).

## Testing Guidelines
- Tests use XCTest under `Tests/SwiftIMAPTests/`; test methods start with `test...`.
- Integration tests use a mock IMAP server and skip when `CI` is set.
- Add/extend tests for protocol parser/encoder changes and new IMAP commands.

## Commit & Pull Request Guidelines
- Commit subjects are short, imperative, and sentence case (e.g., "Fix build errors").
- PRs should include a concise summary, testing results (commands run), and note any user-facing changes.
- Link related issues when applicable and update `README.md`/`Examples/` for API changes.

## Security & Configuration Notes
- TLS 1.2+ is the default; avoid logging credentials or raw auth tokens.
- Prefer configuring TLS/auth via `IMAPConfiguration` instead of ad-hoc options.

## Agent-Specific Notes
- See `CLAUDE.md` for architecture context, detailed workflows, and project constraints.
