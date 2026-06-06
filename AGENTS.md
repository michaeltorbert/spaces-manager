# Agent instructions

For AI coding agents (Codex, Claude Code, Cursor, etc.) working on SpacesManager. `CLAUDE.md` is a symlink to this file.

## What it is

macOS menu-bar utility for naming Mission Control spaces. Swift, AppKit, ad-hoc signed, ships outside the App Store. User-facing description in [README.md](README.md); release runbook in [RELEASING.md](RELEASING.md).

Before making code, build, signing, or release changes, read the "Hard rules"
section below.

## GitHub identity

Before any GitHub write, verify the target repo is
`michaeltorbert/spaces-manager`.

Use the appropriate GitHub App identity rather than the personal
`michaeltorbert` account:

| Agent | Visible actor | Write path |
| --- | --- | --- |
| Codex | `codex-bot-mt[bot]` | `github-app-curl` |
| Claude | `claude-bot-mt[bot]` | `github-app-curl --profile claude` |

Do not use connector-backed GitHub writes when bot attribution matters, because
those may appear as the personal account.

## Git freshness and push safety

Stale worktrees are a known hazard in this repo. Treat `origin/main`, not any
local `main`, as the source of truth.

Before making code, build, signing, release, branch, PR, or issue changes:

1. Verify the remote is `michaeltorbert/spaces-manager`:
   `git remote get-url origin`.
2. Check the live source of truth:
   `git ls-remote --heads origin main`.
3. Do not work directly on `main` or on a detached `HEAD`. Start from the
   refreshed remote tip, for example:
   `git switch -c codex/<topic> origin/main`.
4. Run `scripts/git-safety-check.sh` before committing, pushing, opening a PR,
   or creating a release tag.

Hard stop conditions:

- If the current branch is `main`, stop. Create a feature branch from
  `origin/main` and move the changes there.
- If the current branch does not contain current live `origin/main`, stop.
  Rebase or merge the live main tip before any commit, push, or PR.
- Never use `git push --force`, `git push --force-with-lease`, or
  `git push --no-verify` in this repo.
- Never push directly to `main`; `main` advances only by GitHub PR merge or the
  documented release workflow.
- If GitHub reports `main` is unprotected, do not perform a ref-changing GitHub
  write until branch protection is fixed or the user explicitly accepts the
  risk. Required protection: PRs required for `main`, admins enforced, force
  pushes disabled, branch deletion disabled.

Install the local guard hooks in every clone/worktree before agent work:

```sh
scripts/install-git-guards.sh
```

## Default agent workflow

Unless the user explicitly asks for a different flow:

1. Codex leads: verify the target issue/PR/repo, scope the change, write the
   implementation, run the relevant build or smoke checks, and open or update
   the pull request using the Codex GitHub App identity. For code changes,
   `./build.sh` is the standard verification and includes strict codesign
   verification.
2. Codex asks Claude for a bounded independent pass when useful: issue
   planning, implementation sanity check, or formal PR review. For issue
   planning and local sanity checks, keep Claude's feedback in the conversation
   unless Codex explicitly asks Claude to draft or post a GitHub comment.
3. Claude uses the Claude GitHub App identity for any Claude-attributed GitHub
   write, including issue comments, PR comments, and formal reviews.
4. Codex addresses actionable Claude feedback, reruns the relevant checks, and
   sends the updated work back to Claude until the latest current-run evidence
   from both agents says there are no material unresolved issues, or until a
   concrete blocker is reported.
5. Escalate instead of spinning: if Codex and Claude still disagree after two
   substantive review rounds, or if a change touches a Hard Rule and either
   agent is uncertain, summarize the disagreement or risk for the user.

### Role boundaries

- Keep implementation and review roles separate. The reviewing agent should not
  push fixes to the implementing agent's PR unless the user explicitly asks for
  that role change.
- If there is a concrete reason for Claude to implement and Codex to review
  instead, Codex should say why, use the AI consensus/review skills to
  coordinate that inversion, and still preserve the GitHub identity rules above.
- Do not create competing Codex-authored and Claude-authored PRs by default.
  Parallel PRs are only worth it when genuinely different high-risk approaches
  need to be compared in code.

### PR review comments

When either agent reviews a pull request:

- Submit the formal GitHub PR review using that agent's bot identity.
- Also leave a short top-level PR conversation comment summarizing the review
  result for human visibility.
- Link the top-level comment to the formal review and any key inline
  discussion.

When a PR exists, include the PR number and issue number in subsequent status
messages when available, for example `PR #36 for issue #29`. If the agent tool
supports renaming the active conversation or thread, include the PR number
there too.

## Build & smoke test

```sh
./scripts/preflight.sh        # checks repo guardrails before build/release
./build.sh                    # produces build/SpacesManager.app
open build/SpacesManager.app  # click the menu icon, confirm "Switch to Released Version…" appears
```

First build downloads Sparkle into `Frameworks/`. No test suite exists — verification is: `codesign --verify --deep --strict` passes (build.sh runs this), app launches, menu shows, "Switch to Released Version…" pops Sparkle UI from a dev build. Release builds show "Check for Updates…".

When an agent needs to verify the menu-bar UI, use the Codex Computer Use
plugin to launch `build/SpacesManager.app`, click the status item, and inspect
the native menu. Browser tooling is not applicable to this app.

## Hard rules — do not violate

- **`CLAUDE.md` is a symlink to `AGENTS.md`.** Edit `AGENTS.md`; do not replace
  the symlink or create a divergent Claude-only copy.
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
- `scripts/preflight.sh` — fast guardrails for Sparkle/version/signing rules.
- `Package.swift` — IDE indexing only.
- `.github/workflows/ci.yml` — pull-request build and preflight guardrails.
- `.github/workflows/release.yml` — tag-triggered release pipeline.
- `Frameworks/`, `build/`, `.build/`, `Package.resolved` — gitignored.

## Private API usage

Uses CoreGraphics Services / SkyLight private symbols via `@_silgen_name` for space enumeration and switching. There is no public alternative — see the "Tahoe private API findings" section of [README.md](README.md) for what works and what's been removed in macOS 26.

## Releases

Don't try to cut a release manually. The workflow handles everything when a `v*` tag is pushed. See [RELEASING.md](RELEASING.md).
