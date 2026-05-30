# Releasing a new version

## TL;DR

```sh
git tag v1.0.1
git push origin v1.0.1
```

CI does the rest. Installed copies pick up the new release on their next daily check, or immediately via **Check for Updates…** in the status menu.

## What the release workflow does

Triggered by any `v*` tag push. See [.github/workflows/release.yml](.github/workflows/release.yml).

1. Derives the version: `CFBundleShortVersionString` from the tag (`v1.0.1` → `1.0.1`); `CFBundleVersion` from `git rev-list --count HEAD` (monotonically increasing build number — this is what Sparkle uses for "is this newer").
2. Builds `SpacesManager.app` via `build.sh` (downloads Sparkle on the runner, links, signs the nested chain).
3. Packages as `SpacesManager-<version>.zip`. Just the `.app`, no parent folder (Sparkle translocation guidance).
4. Signs the zip with the EdDSA private key from the `SPARKLE_ED_PRIVATE_KEY` repo secret (matches the `SUPublicEDKey` in `Info.plist`).
5. Updates `appcast.xml` via `generate_appcast`, preserving prior entries.
6. Creates the GitHub Release (or appends to it if it already exists) and uploads the zip.
7. Publishes `appcast.xml` to the `gh-pages` branch → served at <https://michaeltorbert.github.io/spaces-manager/appcast.xml>.

## Version conventions

| Field | Source | Example |
|---|---|---|
| Tag | manual | `v1.0.1` (leading `v` required for the workflow trigger) |
| `CFBundleShortVersionString` | tag, minus `v` | `1.0.1` |
| `CFBundleVersion` | `git rev-list --count HEAD` | `7` |

The values in the source `Info.plist` (`1.0` / `1`) are placeholders — the workflow rewrites them per release. There's no need to bump them in source.

## After tagging

Watch the run at <https://github.com/michaeltorbert/spaces-manager/actions>. When it completes:

- The [release page](https://github.com/michaeltorbert/spaces-manager/releases) should have `SpacesManager-<version>.zip` attached.
- The [appcast URL](https://michaeltorbert.github.io/spaces-manager/appcast.xml) should return updated XML within ~30s of the run completing (allow time for the GitHub Pages rebuild).

## Rolling back a bad release

If a tag was pushed and the release came out broken:

```sh
gh release delete v1.0.1 --yes       # remove the GitHub Release
git push origin :refs/tags/v1.0.1    # remove the remote tag
git tag -d v1.0.1                    # remove the local tag
```

Then fix the issue on `main`, re-tag, and push the new tag. The next successful workflow run pushes a corrected `appcast.xml` to `gh-pages` and installed clients pick up the next valid release.

## One-time setup (already done)

These were done during initial repo bootstrapping; no need to repeat:

- `./Frameworks/bin/generate_keys` generated an EdDSA keypair in the macOS Keychain.
- The public key (`9YFJoOH5ibbzJhSMIvst8QkiTOYUyHc0JR9feaEp3+s=`) lives in `Info.plist` under `SUPublicEDKey`.
- The private key was exported via `generate_keys -x` and stored as the `SPARKLE_ED_PRIVATE_KEY` repo secret (then deleted locally).
- GitHub Pages is enabled with source = `gh-pages` branch, root path.

If the EdDSA keypair is ever lost, existing installs **cannot** be migrated to a new key — Sparkle requires updates to be signed with the same key the installed app already trusts. Treat the private key in GH Secrets as the long-lived authority for the app.
