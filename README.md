# SpacesManager

A small Swift menu-bar utility for macOS that lets you give Mission Control spaces custom names, switch between them from the menu bar, and see the current space's name in a brief HUD when you switch.

**Non-goal:** this does **not** rename the "Desktop 1 / Desktop 2 / …" labels inside Apple's Mission Control UI. Doing that requires injecting code into the Dock process, which requires disabling System Integrity Protection. SpacesManager deliberately avoids that route — it's a parallel UI, not a Mission Control patch.

Built and tested on **macOS Tahoe 26.3.1, Apple Silicon (M4)**. Older macOS versions probably work too — see [Compatibility](#compatibility).

---

## What it does

- **Menu bar item** shows the current space's custom name (falls back to "Desktop N").
- **Click the menu bar item** to see all spaces grouped by display name, with the active one marked.
- **Visited spaces show cached thumbnails** in the menu. A thumbnail is captured
  shortly after you switch to a space, stored locally, and shown with its capture
  age. If Screen Recording permission is unavailable, SpacesManager falls back
  to the existing app/display icons and shows **Enable Space Thumbnails…** in
  the menu.
- **Click a space row** to switch to it. The first switch prompts for Accessibility permission so SpacesManager can send the same Dock swipe event as a trackpad space switch. Full-screen app spaces appear in the menu and can be targeted too.
- **Hover a normal desktop space row** for quick buttons to rename or delete the space. Delete asks for confirmation first.
- **Brief HUD** fades in at the top of the screen on every space switch, showing the name.
- **Rename Current Space…** quick action in the menu.
- **Rename All Spaces…** opens a window for bulk editing.
- **Names persist** in `UserDefaults` under bundle id `local.spacesmanager`, keyed by each space's UUID (or a stable per-display fallback key when macOS returns an empty UUID).
- **Self-updates** via Sparkle: a daily background check + a "Check for Updates…" menu item in release builds. Local dev builds show "Switch to Released Version…" and use Sparkle to install the latest signed release. Updates are verified with an EdDSA signature embedded in the app; only releases signed with the matching private key will install.
- **Hold Option while the menu is open** to swap "Quit SpacesManager" to "Relaunch SpacesManager."

---

## Requirements

- macOS 13 or later (built with `-target arm64-apple-macos13`)
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc` and `codesign`

No Apple Developer account, no entitlements, no SIP changes. Click-to-switch
requires Accessibility permission. If you launch a development build from
Terminal, turn on Terminal in Accessibility; an installed build may appear as
SpacesManager instead.

Space thumbnails require Screen Recording permission; without it, the menu still
works and falls back to app/display icons. Choose **Enable Space Thumbnails…**
from the menu to request access. After granting Screen Recording in System
Settings, quit and reopen SpacesManager so macOS applies the permission before
testing thumbnails again. If you launch a development build from Terminal, turn
on Terminal in the Screen Recording list; an installed build may appear as
SpacesManager instead.

Because SpacesManager is a menu-bar agent (`LSUIElement=true`), its app icon appears in Finder, Get Info, Spotlight, and release artifacts, not in the Dock or app switcher.

## Build

```sh
./build.sh
```

On the first run this downloads Sparkle 2.9.2 (~15 MB) into `Frameworks/` and caches it for subsequent builds. The script then compiles `Sources/*.swift`, copies `Sparkle.framework` into the app bundle, strips xattrs, ad-hoc signs the nested XPC services + framework + outer app in that order, and verifies the chain passes `codesign --verify --deep --strict`.

## Install

Download the latest `SpacesManager-<version>.zip` from [Releases](https://github.com/michaeltorbert/spaces-manager/releases), unzip, and:

```sh
xattr -dr com.apple.quarantine ~/Downloads/SpacesManager.app
mv ~/Downloads/SpacesManager.app /Applications/
open /Applications/SpacesManager.app
```

The `xattr` line strips Gatekeeper's quarantine flag. Without it macOS refuses to launch the ad-hoc-signed app and offers no override path. (Right-click → Open → Open Anyway sometimes works too, but Tahoe is grumpier and `xattr` is the reliable path.) Future updates flow through Sparkle and don't trip this — only the first install does.

To start at login: **System Settings → General → Login Items & Extensions → +** under "Open at Login" → pick `/Applications/SpacesManager.app`.

## Releasing a new version

```sh
git tag v1.0.1
git push origin v1.0.1
```

CI builds, signs, publishes the appcast, attaches the zip to the GitHub Release. Installed copies auto-update on the next daily check. See [RELEASING.md](RELEASING.md) for the full runbook (what each workflow step does, version conventions, rollback, the one-time setup that's already been done).

---

## Project layout

```
Sources/                       Swift source split by concern
Assets/                        app icon source, generator script, and compiled .icns
Info.plist                      bundle metadata + Sparkle keys (SUFeedURL, SUPublicEDKey)
build.sh                        vendors Sparkle, runs swiftc, codesigns the nested chain, verifies
Package.swift                   IDE indexing only; the real build is build.sh
.github/workflows/release.yml   tag-triggered: build, sign, regenerate appcast, publish
Frameworks/                     gitignored; populated by build.sh on first run
LICENSE                         MIT
README.md                       this file
RELEASING.md                    release runbook (cut a release, rollback, key-management notes)
```

Small raw-`swiftc` Swift app. No Xcode project; `Package.swift` is for IDE indexing only. Sparkle is vendored as a prebuilt framework copied into `Contents/Frameworks/`. Edit the source, run `./build.sh`, and (during development) drag the new `build/SpacesManager.app` over the installed copy. If the app icon changes, regenerate `Assets/AppIcon.svg` and `Assets/AppIcon.icns` with `Assets/build-icon.sh`. Local dev builds mark themselves and use a low internal build number so **Switch to Released Version…** can hand off to Sparkle's normal update flow; background Sparkle checks are blocked for dev builds so they are not silently replaced while testing. For real releases, push a tag.

---

## Tahoe private API findings

SpacesManager uses Apple's private CoreGraphics Services (CGS) / SkyLight APIs because there is no public macOS API for enumerating or manipulating Mission Control spaces. This makes it un-shippable on the Mac App Store but works fine for personal use.

Probed against macOS 26.3.1 (Tahoe) on Apple Silicon, here's what I found:

### Still works

| Symbol | Use |
|---|---|
| `CGSMainConnectionID` | get the default WindowServer connection |
| `CGSGetActiveSpace` | current space ID |
| `CGSCopyManagedDisplaySpaces` | full topology of displays → spaces, with `uuid`, `id64`, `ManagedSpaceID`, `Current Space` |
| `CGSSpaceDestroy` | delete a space |
| `CGSCopyActiveMenuBarDisplayIdentifier` | which display has the menu bar |
| `SLSManagedDisplayGetCurrentSpace` | per-display current space |
| `SLSSpaceDestroy` | (alias of CGSSpaceDestroy) |
| `SLSCopySpacesForWindows` | map regular app windows from `CGWindowListCopyWindowInfo` back to their Mission Control spaces for menu counts and dominant-app metadata |
| `SLSHWCaptureWindowList`, `SLSCaptureWindowsContentsToRectWithOptions` | window-image capture (not yet used) |
| `SLSSpaceSetType`, `SLSSpaceGetType` | space type |

### Broken / not viable on Tahoe

| Symbol | Was used for | Workaround |
|---|---|---|
| `CGSManagedDisplaySetCurrentSpace` / `SLSManagedDisplaySetCurrentSpace` | direct row-click switching | symbol still exists, but on Tahoe it only changes WindowServer bookkeeping and surfaces target-space windows over the current desktop. SpacesManager uses Accessibility-gated synthetic Dock swipe gestures instead. |
| `SLSMoveWindowsToManagedSpace`, `SLSAddWindowsToSpaces` / `SLSRemoveWindowsFromSpaces`, `SLSSpaceSetCompatID` + `SLSSetWindowListWorkspace` | green-arrow "move frontmost window here" row action | symbols resolve and diagnostics can move caller-owned windows, but macOS 26.5 silently no-ops when SpacesManager tries to move another app's window. SpacesManager therefore removes this user-facing action instead of presenting a broken control. |

### Removed / missing on Tahoe

| Symbol | Was used for | Workaround |
|---|---|---|
| `SLSAddSpacesToManagedDisplay` / `CGSAddSpacesToManagedDisplay` | attaching a created space to a display | gone — `SLSSpaceCreate` still works but the created space can't be made visible, so the programmatic-add path is effectively dead. To create a new space, open Mission Control yourself (F3 / gesture / Spotlight) and click `+`. |
| `CoreDockSendNotification` in `Dock.framework` | opening Mission Control / Expose without keypress | the `Dock.framework` private bundle no longer exists at the old path. Use `NSWorkspace.openApplication(at: "/System/Applications/Mission Control.app")` instead. |

These results are from a runtime `dlsym` probe; if you're on a different macOS version, results may differ.

---

## Why not the Mac App Store?

Apple's App Store Review:

1. Statically scans the binary for private API symbol references — all CGS/SLS symbols are flagged and rejected.
2. Requires sandboxing — and the sandbox blocks the WindowServer connection that CGS calls depend on at runtime anyway.

The App Store apps that *do* offer space-naming work around this by avoiding CGS entirely: they listen to the public `NSWorkspace.activeSpaceDidChangeNotification`, assign sequential counter IDs (not UUIDs), and use Accessibility to synthesize space-switch keypresses. The tradeoff: names break when spaces are reordered or deleted, and most cap at ~10 spaces.

SpacesManager takes the opposite tradeoff: stable UUID-keyed naming and an unlimited number of spaces, at the cost of being unshippable.

---

## Compatibility

| macOS | Status |
|---|---|
| 26 (Tahoe) | ✓ developed and tested here |
| 13–15 (Ventura → Sequoia) | should work; identical APIs except programmatic space creation may use the now-missing attach symbol if you patch it back in for older systems |
| 12 (Monterey) and earlier | `LSMinimumSystemVersion` is set to 13; build target can be lowered |

If you try it on another version, PRs with findings are welcome.

---

## License

MIT — see [LICENSE](LICENSE).
