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
