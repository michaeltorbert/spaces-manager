#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

NAME="SpacesHUD"
BUILD_DIR="build"
APP="$BUILD_DIR/$NAME.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"

swiftc -O \
  -target arm64-apple-macos13 \
  -framework AppKit \
  -o "$MACOS/$NAME" \
  Sources/main.swift

cp Info.plist "$APP/Contents/Info.plist"

# Strip extended attributes that can poison codesigning
xattr -cr "$APP"

# Ad-hoc sign (single dash = ad-hoc identity)
codesign --force --sign - "$APP"

# Verify the signature passes deep + strict checks
codesign --verify --deep --strict "$APP"

echo "Built:    $APP"
echo "Signed:   ad-hoc"
echo "Verified: deep + strict"
echo "Run:      open '$APP'"
echo "Quit:     menu bar → Quit SpacesHUD"
