# Agent instructions

For AI coding agents (Codex, Claude Code, Cursor, etc.) working on SpacesManager. `CLAUDE.md` is a symlink to this file.

## What it is

macOS menu-bar utility for naming Mission Control spaces. Swift, AppKit, ad-hoc signed, ships outside the App Store. User-facing description in [README.md](README.md); release runbook in [RELEASING.md](RELEASING.md).

## GitHub identity

Before any GitHub write, verify the target repo is
`michaeltorbert/spaces-manager`.

Use the appropriate GitHub App identity rather than the personal
`michaeltorbert` account.

Codex identity:
- Visible actor: `codex-bot-mt[bot]`
- Use the local GitHub App token path, such as `github-app-curl`, for writes.

Claude identity:
- GitHub App profile: `claude`
- Visible actor: `claude-bot-mt[bot]`
- Use `github-app-curl --profile claude` for Claude-attributed writes.

Do not use connector-backed GitHub writes when bot attribution matters, because
those may appear as the personal account.

## Default agent workflow

Unless the user explicitly asks for a different flow, use paired implementation
and review:

1. The agent currently assigned to write the implementation owns the code
   changes and any follow-up revisions.
2. The other agent reviews the implementation before the work is considered
   complete.
3. If Claude writes the implementation or opens the pull request, Codex reviews
   using the Codex GitHub App identity.
4. If Codex writes the implementation or opens the pull request, Claude reviews
   using the Claude GitHub App identity.

Keep implementation and review roles separate. The reviewing agent should not
push fixes to the writing agent's branch or PR unless the user explicitly asks
the reviewer to take over the implementation work.

When Codex writes implementation code, Codex should automatically request a
Claude review before declaring the work complete. Codex should respond to
Claude's actionable review feedback, revise its own code when appropriate, and
repeat the review loop until Codex and Claude agree there are no remaining
material issues, or until Codex identifies a concrete blocker that requires user
input.

For PR-based work, prefer GitHub as the review handoff surface. The reviewing
agent should post its review to the pull request using its GitHub App identity,
and the writing agent should read the review, inline comments, and top-level
conversation comments from GitHub before deciding what to revise. Direct CLI or
chat output is acceptable for local pre-PR review, but it should not replace the
GitHub review when a PR exists.

When Codex needs Claude to review a PR, use the repo-local helper:

```sh
scripts/claude-pr-review.sh <pr-number-or-url>
```

The helper verifies the workspace remote is `michaeltorbert/spaces-manager`,
asks Claude for a structured review, posts the formal review with
`github-app-curl --profile claude`, posts a top-level PR summary comment, and
verifies both GitHub URLs before exiting successfully.

When an agent creates a pull request, rename that agent's active conversation
or thread after the PR number is known. Include the PR number and issue number
when available, for example `PR #36 for issue #29`.

When Claude reviews a pull request:
- Submit the formal GitHub PR review using `claude-bot-mt[bot]`.
- Also leave a short top-level PR conversation comment summarizing the review
  result for human visibility.
- Link the top-level comment to the formal review and any key inline
  discussion.

When Codex reviews a pull request:
- Submit the formal GitHub PR review using `codex-bot-mt[bot]`.
- Also leave a short top-level PR conversation comment summarizing the review
  result for human visibility.
- Link the top-level comment to the formal review and any key inline
  discussion.

## Build & smoke test

```sh
./build.sh                    # produces build/SpacesManager.app
open build/SpacesManager.app  # click the menu icon, confirm "Check for Updates…" appears
```

First build downloads Sparkle into `Frameworks/`. No test suite exists — verification is: `codesign --verify --deep --strict` passes (build.sh runs this), app launches, menu shows, "Check for Updates…" pops Sparkle UI.

## Hard rules — do not violate

- **Ad-hoc signing only.** Never add `--options runtime` to any `codesign` call. Hardened runtime + library validation prevents an ad-hoc-signed host from loading `Sparkle.framework`.
- **Sparkle signing order is deepest-first**: `XPCServices/*.xpc` → `Updater.app` → `Autoupdate` → `Sparkle.framework` → outer app. Reordering breaks `codesign --verify --deep --strict`.
- **`Package.swift` is for IDE indexing only.** Do not migrate the build to `swift build`; the real build is `build.sh` with the vendored framework under `Frameworks/`. Sparkle is declared in both places — keep versions in lockstep when bumping.
- **Don't bump the version in `Info.plist`.** The `1.0` / `1` values are placeholders. `.github/workflows/release.yml` rewrites `CFBundleShortVersionString` from the tag and `CFBundleVersion` from `git rev-list --count HEAD` per release. Bumping in source creates merge friction with no benefit.
- **Don't touch the EdDSA keys.** `SUPublicEDKey` in `Info.plist` and the `SPARKLE_ED_PRIVATE_KEY` GitHub secret are a matched pair. Rotating either strands every existing install — Sparkle can't migrate trust without a Developer ID code-signing chain.

## Project shape

- `Sources/` — Swift source split into per-concern files, with `main.swift` kept as the minimal entry point.
- `Assets/` — app icon source, generator script, and compiled `.icns`.
- `Info.plist` — bundle metadata + Sparkle keys (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`).
- `build.sh` — vendors Sparkle, runs `swiftc`, signs the nested chain.
- `Package.swift` — IDE indexing only.
- `.github/workflows/release.yml` — tag-triggered release pipeline.
- `Frameworks/`, `build/`, `.build/`, `Package.resolved` — gitignored.

## Private API usage

Uses CoreGraphics Services / SkyLight private symbols via `@_silgen_name` for space enumeration and switching. There is no public alternative — see the "Tahoe private API findings" section of [README.md](README.md) for what works and what's been removed in macOS 26.

## Releases

Don't try to cut a release manually. The workflow handles everything when a `v*` tag is pushed. See [RELEASING.md](RELEASING.md).
