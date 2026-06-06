#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

EXPECTED_INFO_SHORT_VERSION="1.0"
EXPECTED_INFO_BUILD_VERSION="1"
EXPECTED_SPARKLE_PUBLIC_KEY="9YFJoOH5ibbzJhSMIvst8QkiTOYUyHc0JR9feaEp3+s="

fail() {
  printf 'preflight: %s\n' "$*" >&2
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" Info.plist 2>/dev/null \
    || fail "missing Info.plist key: $1"
}

line_number_for() {
  local pattern="$1"
  local line
  line=$(grep -nF -- "$pattern" build.sh | head -n 1 | cut -d: -f1 || true)
  [ -n "$line" ] || fail "missing build.sh signing step: $pattern"
  printf '%s' "$line"
}

require_before() {
  local earlier_name="$1"
  local earlier_line="$2"
  local later_name="$3"
  local later_line="$4"
  if [ "$earlier_line" -ge "$later_line" ]; then
    fail "build.sh signing order changed: $earlier_name must be before $later_name"
  fi
}

plutil -lint Info.plist >/dev/null

codesign_commands=$(sed -E '/^[[:space:]]*#/d' build.sh | perl -0pe 's/\\\R/ /g')
if printf '%s\n' "$codesign_commands" \
    | grep -E '^[[:space:]]*codesign[[:space:]].*--options([[:space:]]+|=)[^[:space:]]*runtime' >/dev/null; then
  fail "build.sh must not use --options runtime with ad-hoc Sparkle signing"
fi

build_sparkle_version=$(sed -nE 's/^SPARKLE_VERSION="([^"]+)".*/\1/p' build.sh)
package_sparkle_version=$(sed -nE 's/.*exact: "([^"]+)".*/\1/p' Package.swift | head -n 1)

[ -n "$build_sparkle_version" ] || fail "could not read SPARKLE_VERSION from build.sh"
[ -n "$package_sparkle_version" ] || fail "could not read Sparkle exact version from Package.swift"

if [ "$build_sparkle_version" != "$package_sparkle_version" ]; then
  fail "Sparkle version mismatch: build.sh has $build_sparkle_version, Package.swift has $package_sparkle_version"
fi

info_short_version=$(plist_value CFBundleShortVersionString)
info_build_version=$(plist_value CFBundleVersion)
sparkle_public_key=$(plist_value SUPublicEDKey)

if [ "$info_short_version" != "$EXPECTED_INFO_SHORT_VERSION" ]; then
  fail "source Info.plist CFBundleShortVersionString must stay at placeholder $EXPECTED_INFO_SHORT_VERSION"
fi

if [ "$info_build_version" != "$EXPECTED_INFO_BUILD_VERSION" ]; then
  fail "source Info.plist CFBundleVersion must stay at placeholder $EXPECTED_INFO_BUILD_VERSION"
fi

if [ "$sparkle_public_key" != "$EXPECTED_SPARKLE_PUBLIC_KEY" ]; then
  fail "SUPublicEDKey changed; rotating it would strand existing Sparkle installs"
fi

downloader_line=$(line_number_for 'codesign --force --sign - "$SPARKLE_INNER/XPCServices/Downloader.xpc"')
installer_line=$(line_number_for 'codesign --force --sign - "$SPARKLE_INNER/XPCServices/Installer.xpc"')
updater_line=$(line_number_for 'codesign --force --sign - "$SPARKLE_INNER/Updater.app"')
autoupdate_line=$(line_number_for 'codesign --force --sign - "$SPARKLE_INNER/Autoupdate"')
framework_line=$(line_number_for 'codesign --force --sign - "$APP_FRAMEWORKS/Sparkle.framework"')
app_line=$(line_number_for 'codesign --force --sign - "$APP"')

require_before "Downloader.xpc" "$downloader_line" "Updater.app" "$updater_line"
require_before "Installer.xpc" "$installer_line" "Updater.app" "$updater_line"
require_before "Updater.app" "$updater_line" "Autoupdate" "$autoupdate_line"
require_before "Autoupdate" "$autoupdate_line" "Sparkle.framework" "$framework_line"
require_before "Sparkle.framework" "$framework_line" "SpacesManager.app" "$app_line"

printf 'preflight: guardrails passed\n'
