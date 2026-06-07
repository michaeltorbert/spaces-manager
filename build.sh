#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

NAME="SpacesManager"
BUILD_DIR="build"
APP="$BUILD_DIR/$NAME.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
APP_FRAMEWORKS="$APP/Contents/Frameworks"

SPARKLE_VERSION="2.9.2"
VENDOR_DIR="Frameworks"
VENDORED_SPARKLE="$VENDOR_DIR/Sparkle.framework"
SPARKLE_TARBALL_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

# --- Vendor Sparkle on first build ------------------------------------------
if [ ! -d "$VENDORED_SPARKLE" ]; then
  echo "Downloading Sparkle ${SPARKLE_VERSION}…"
  mkdir -p "$VENDOR_DIR"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL "$SPARKLE_TARBALL_URL" -o "$TMP/sparkle.tar.xz"
  tar -xJf "$TMP/sparkle.tar.xz" -C "$TMP"
  ditto "$TMP/Sparkle.framework" "$VENDORED_SPARKLE"
  ditto "$TMP/bin" "$VENDOR_DIR/bin"
  rm -rf "$TMP"
  trap - EXIT
fi

# --- Build ------------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$APP_FRAMEWORKS"

swiftc -O \
  -target arm64-apple-macos13 \
  -framework AppKit \
  -F /System/Library/PrivateFrameworks \
  -framework SkyLight \
  -F "$VENDOR_DIR" \
  -framework Sparkle \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -o "$MACOS/$NAME" \
  Sources/*.swift

cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$RESOURCES/AppIcon.icns"

# Local dev builds use a low CFBundleVersion so Sparkle can switch them back
# to the latest signed release on an explicit user check. AppDelegate blocks
# background Sparkle checks for these dev builds, so they are not silently
# replaced mid-test. The release workflow sets its own version from
# `git rev-list --count HEAD` and runs with $CI set, so it's unaffected.
if [ -z "${CI:-}" ]; then
  build_identifier="$(git rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
  if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
    build_identifier="${build_identifier}-dirty"
  fi
  build_identifier="${build_identifier} ($(date '+%Y-%m-%d %H:%M:%S %z'))"

  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion 0" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SMDevelopmentBuild bool true" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :SMDevelopmentBuild true" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SMBuildIdentifier string $build_identifier" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :SMBuildIdentifier $build_identifier" "$APP/Contents/Info.plist"
fi

# Copy Sparkle.framework into the bundle, preserving symlinks.
ditto "$VENDORED_SPARKLE" "$APP_FRAMEWORKS/Sparkle.framework"

# Strip extended attributes that can poison codesigning.
xattr -cr "$APP"

# --- Sign -------------------------------------------------------------------
# Ad-hoc sign nested Sparkle pieces deepest-first, then the framework, then
# the outer app. Do NOT pass --options runtime: Sparkle's docs warn that the
# hardened runtime's library-validation can prevent an ad-hoc-signed host app
# from loading Sparkle.framework.
SPARKLE_INNER="$APP_FRAMEWORKS/Sparkle.framework/Versions/B"
codesign --force --sign - "$SPARKLE_INNER/XPCServices/Downloader.xpc"
codesign --force --sign - "$SPARKLE_INNER/XPCServices/Installer.xpc"
codesign --force --sign - "$SPARKLE_INNER/Updater.app"
codesign --force --sign - "$SPARKLE_INNER/Autoupdate"
codesign --force --sign - "$APP_FRAMEWORKS/Sparkle.framework"
codesign --force --sign - "$APP"

codesign --verify --deep --strict "$APP"

echo "Built:    $APP"
echo "Signed:   ad-hoc (Sparkle ${SPARKLE_VERSION} bundled)"
echo "Verified: deep + strict"
echo "Run:      open '$APP'"
echo "Quit:     menu bar → Quit SpacesManager"
