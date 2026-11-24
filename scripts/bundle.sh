#!/usr/bin/env bash
# Builds "GitHub PR Watch.app" into ./build. Builds only; it never launches the app.
#
# Environment, all optional:
#   PRWATCH_VERSION     The version to show, such as 1.2.0. Defaults to the latest v* tag, or 0.1.
#   CODESIGN_IDENTITY   The signing identity. Defaults to a Developer ID Application
#                       certificate in the Keychain, or an ad-hoc signature without one.
set -euo pipefail
cd "$(dirname "$0")/.."

# Use full Xcode for SwiftUI macros without changing the global xcode-select setting.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release --arch arm64 --product GitHubPRWatch
BIN="$(swift build -c release --arch arm64 --show-bin-path)/GitHubPRWatch"

APP="build/GitHub PR Watch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GitHubPRWatch"

# Record the SDK the app was compiled against. SwiftPM's default build engine writes the
# deployment target (15.0) into the binary's SDK field instead. macOS reads that field to
# choose between current behavior and a compatibility mode for older apps; in that mode
# the menu bar panel draws as a flat rectangle and doesn't resize with its content.
# This is why `swift run` must not be used to try the app. AI-menubar-meter's
# scripts/bundle.sh has the full investigation.
#
# To check a build:  xcrun vtool -show-build <binary>
# `sdk` must match `xcrun --sdk macosx --show-sdk-version` and differ from `minos`.
MIN_OS=15.0
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/GitHubPRWatch" "$APP/Contents/MacOS/GitHubPRWatch" 2>/dev/null
STAMPED="$(xcrun vtool -show-build "$APP/Contents/MacOS/GitHubPRWatch" | awk '$1 == "sdk" { print $2 }')"
if [[ "$STAMPED" != "$SDK_VERSION" ]]; then
  echo "error: the binary is stamped with SDK '$STAMPED', expected '$SDK_VERSION'" >&2
  exit 1
fi

GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  GIT_COMMIT="$GIT_COMMIT-dirty"
fi
LATEST_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
VERSION="${PRWATCH_VERSION:-${LATEST_TAG#v}}"
VERSION="${VERSION:-0.1}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# LSUIElement: a menu bar app with no Dock icon. The main window turns the Dock icon on
# while it is open (see DockPresence.swift).
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GitHub PR Watch</string>
  <key>CFBundleDisplayName</key><string>GitHub PR Watch</string>
  <key>CFBundleIdentifier</key><string>dev.lubelski.GitHubPRWatch</string>
  <key>CFBundleExecutable</key><string>GitHubPRWatch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>PRWatchGitCommit</key><string>$GIT_COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"
SIGN=(codesign --force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
  SIGN+=(--options runtime --timestamp)
fi
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP, version $VERSION ($BUILD_NUMBER), signed with: $IDENTITY"
