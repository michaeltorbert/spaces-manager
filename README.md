# SpacesHUD

A small Swift menu-bar utility for macOS that lets you give Mission Control spaces custom names, switch between them from the menu bar, and see the current space's name in a brief HUD when you switch.

**Non-goal:** this does **not** rename the "Desktop 1 / Desktop 2 / …" labels inside Apple's Mission Control UI. Doing that requires injecting code into the Dock process, which requires disabling System Integrity Protection. SpacesHUD deliberately avoids that route — it's a parallel UI, not a Mission Control patch.

Built and tested on **macOS Tahoe 26.3.1, Apple Silicon (M4)**. Older macOS versions probably work too — see [Compatibility](#compatibility).

---

## What it does

- **Menu bar item** shows the current space's custom name (falls back to "Desktop N").
- **Click the menu bar item** to see all spaces grouped by display, with the active one marked.
- **Click a space row** to switch to it.
- **Right-click a space row** for a context menu: Rename, Delete Space (with confirm).
- **Brief HUD** fades in at the top of the screen on every space switch, showing the name.
- **Rename Current Space…** quick action in the menu.
- **Rename All Spaces…** opens a window for bulk editing.
- **Add New Space** opens Mission Control so you can click `+` (Apple removed the programmatic-add private API on Tahoe — see [Tahoe findings](#tahoe-private-api-findings)).
- **Names persist** in `UserDefaults` under bundle id `local.spaceshud`, keyed by each space's UUID (or a stable per-display fallback key when macOS returns an empty UUID).

---

## Requirements

- macOS 13 or later (built with `-target arm64-apple-macos13`)
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc` and `codesign`

No Apple Developer account, no entitlements, no Accessibility permission, no SIP changes.

## Build

```sh
./build.sh
```

This compiles `Sources/main.swift`, assembles `build/SpacesHUD.app`, strips xattrs, ad-hoc signs, and verifies the signature passes `codesign --verify --deep --strict`.

## Install

```sh
cp -R build/SpacesHUD.app /Applications/
open /Applications/SpacesHUD.app
```

To start at login: **System Settings → General → Login Items & Extensions → +** under "Open at Login" → pick `/Applications/SpacesHUD.app`.

---

## Project layout

```
Sources/main.swift   ~525 lines, the entire app
Info.plist           bundle metadata (LSUIElement = true, bundle id, etc.)
build.sh             swiftc + xattr -cr + codesign + verify
LICENSE              MIT
README.md            this file
```

Single-file Swift app, no Xcode project, no Swift Package Manager. Edit the source, run `./build.sh`, drag the new `build/SpacesHUD.app` over the installed copy.

---

## Tahoe private API findings

SpacesHUD uses Apple's private CoreGraphics Services (CGS) / SkyLight APIs because there is no public macOS API for enumerating or manipulating Mission Control spaces. This makes it un-shippable on the Mac App Store but works fine for personal use.

Probed against macOS 26.3.1 (Tahoe) on Apple Silicon, here's what I found:

### Still works

| Symbol | Use |
|---|---|
| `CGSMainConnectionID` | get the default WindowServer connection |
| `CGSGetActiveSpace` | current space ID |
| `CGSCopyManagedDisplaySpaces` | full topology of displays → spaces, with `uuid`, `id64`, `ManagedSpaceID`, `Current Space` |
| `CGSManagedDisplaySetCurrentSpace` | switch the active space on a display |
| `CGSSpaceDestroy` | delete a space |
| `CGSCopyActiveMenuBarDisplayIdentifier` | which display has the menu bar |
| `SLSManagedDisplayGetCurrentSpace` | per-display current space |
| `SLSSpaceDestroy` | (alias of CGSSpaceDestroy) |
| `SLSCopyWindowsWithOptionsAndTags`, `SLSCopySpacesForWindows`, `SLSMoveWindowsToManagedSpace`, `SLSAddWindowsToSpaces`, `SLSRemoveWindowsFromSpaces` | window↔space membership (not yet used in this app) |
| `SLSHWCaptureWindowList`, `SLSCaptureWindowsContentsToRectWithOptions` | window-image capture (not yet used) |
| `SLSSpaceSetType`, `SLSSpaceGetType` | space type |

### Removed / missing on Tahoe

| Symbol | Was used for | Workaround |
|---|---|---|
| `SLSAddSpacesToManagedDisplay` / `CGSAddSpacesToManagedDisplay` | attaching a created space to a display | gone — `SLSSpaceCreate` still works but the created space can't be made visible, so the programmatic-add path is effectively dead. SpacesHUD opens Mission Control via `NSWorkspace.openApplication` so the user can click `+`. |
| `CoreDockSendNotification` in `Dock.framework` | opening Mission Control / Expose without keypress | the `Dock.framework` private bundle no longer exists at the old path. Use `NSWorkspace.openApplication(at: "/System/Applications/Mission Control.app")` instead. |

These results are from a runtime `dlsym` probe; if you're on a different macOS version, results may differ.

---

## Why not the Mac App Store?

Apple's App Store Review:

1. Statically scans the binary for private API symbol references — all CGS/SLS symbols are flagged and rejected.
2. Requires sandboxing — and the sandbox blocks the WindowServer connection that CGS calls depend on at runtime anyway.

The App Store apps that *do* offer space-naming work around this by avoiding CGS entirely: they listen to the public `NSWorkspace.activeSpaceDidChangeNotification`, assign sequential counter IDs (not UUIDs), and use Accessibility to synthesize space-switch keypresses. The tradeoff: names break when spaces are reordered or deleted, and most cap at ~10 spaces.

SpacesHUD takes the opposite tradeoff: stable UUID-keyed naming and an unlimited number of spaces, at the cost of being unshippable.

---

## Compatibility

| macOS | Status |
|---|---|
| 26 (Tahoe) | ✓ developed and tested here |
| 13–15 (Ventura → Sequoia) | should work; identical APIs except `Add New Space` may use the now-missing attach symbol if you patch it back in for older systems |
| 12 (Monterey) and earlier | `LSMinimumSystemVersion` is set to 13; build target can be lowered |

If you try it on another version, PRs with findings are welcome.

---

## License

MIT — see [LICENSE](LICENSE).
