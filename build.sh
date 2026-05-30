#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

NAME="SpacesManager"
BUILD_DIR="build"
APP="$BUILD_DIR/$NAME.app"
MACOS="$APP/Contents/MacOS"
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
mkdir -p "$MACOS" "$APP_FRAMEWORKS"

swiftc -O \
  -target arm64-apple-macos13 \
  -framework AppKit \
  -F "$VENDOR_DIR" \
  -framework Sparkle \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -o "$MACOS/$NAME" \
  Sources/main.swift

cp Info.plist "$APP/Contents/Info.plist"

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
