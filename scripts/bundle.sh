#!/usr/bin/env bash
# Builds build/github-pr-watch-menubar.app. Builds only; it never installs or launches the app.
#
# Environment, all optional:
#   PRWATCH_VERSION           The version to show, such as 1.2.0. Defaults to the latest v* tag,
#                             or 0.1 without one.
#   PRWATCH_FEED_URL          The Sparkle feed. Set by scripts/release.sh, together with
#   PRWATCH_PUBLIC_KEY        the public key that updates are signed with. A build without
#                             these two never updates itself.
#   PRWATCH_SIGNING_IDENTITY  The signing identity. See "Sign" below for the default.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=github-pr-watch-menubar

# Use full Xcode for SwiftUI macros and actool without changing the global xcode-select setting.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release --arch arm64 --product "$NAME"
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$NAME"

APP="build/$NAME.app"
EXE="$APP/Contents/MacOS/$NAME"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$EXE"

# Sparkle, the updater. SwiftPM builds it next to the binary but does not know about app
# bundles, so copy it in and tell the binary where to find it.
ditto "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$EXE"

# Record the SDK the app was compiled against. SwiftPM's default build engine writes the
# deployment target into the binary's SDK field instead. macOS reads that field to
# choose between current behavior and a compatibility mode for older apps; in that mode
# the menu bar panel draws as a flat rectangle and doesn't resize with its content.
# This is why `swift run` must not be used to try the app. AI-menubar-meter's
# scripts/bundle.sh has the full investigation.
#
# To check a build:  xcrun vtool -show-build <binary>
# `sdk` must match `xcrun --sdk macosx --show-sdk-version`.
MIN_OS=27.0
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
xcrun vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace -output "$EXE" "$EXE" 2>/dev/null
STAMPED="$(xcrun vtool -show-build "$EXE" | awk '$1 == "sdk" { print $2 }')"
if [[ "$STAMPED" != "$SDK_VERSION" ]]; then
  echo "error: the binary is stamped with SDK '$STAMPED', expected '$SDK_VERSION'" >&2
  exit 1
fi

# The app icon. actool compiles the Icon Composer file into Assets.car, which macOS draws
# with the system's glass, and AppIcon.icns, a flat copy for places that read only that.
# Info.plist names both below. This runs before signing, so the signature covers the icon.
# scripts/render-icon.sh redraws the icon's artwork. The paths are absolute because actool
# hands the work to a shared helper process, which reads relative paths against its own
# working directory, possibly another project's.
ICON_PLIST_DIR="$(mktemp -d)"
ICON_LOG="$(mktemp)"
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target "$MIN_OS" --app-icon AppIcon \
  --output-partial-info-plist "$ICON_PLIST_DIR/icon.plist" --errors --warnings \
  --output-format human-readable-text >"$ICON_LOG" 2>&1 || { cat "$ICON_LOG" >&2; exit 1; }
rm -rf "$ICON_PLIST_DIR" "$ICON_LOG"
for f in Assets.car AppIcon.icns; do
  if [[ ! -f "$APP/Contents/Resources/$f" ]]; then
    echo "error: actool did not produce $f from Resources/AppIcon.icon" >&2
    exit 1
  fi
done

GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  GIT_COMMIT="$GIT_COMMIT-dirty"
fi
# The version comes from the latest release tag. The build number is the number of commits,
# which only grows on main. Sparkle compares build numbers to find a newer build.
LATEST_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
VERSION="${PRWATCH_VERSION:-${LATEST_TAG#v}}"
VERSION="${VERSION:-0.1}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

UPDATER_KEYS=""
if [[ -n "${PRWATCH_FEED_URL:-}" && -n "${PRWATCH_PUBLIC_KEY:-}" ]]; then
  UPDATER_KEYS="<key>SUFeedURL</key><string>$PRWATCH_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$PRWATCH_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>"
fi

# The bundle, executable, and identifier are named after the repo. People see the display
# name, "GitHub PR Watch", in the menu bar, the app menu, and notifications.
# LSUIElement: a menu bar app with no Dock icon. The main window turns the Dock icon on
# while it is open (see DockPresence.swift).
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GitHub PR Watch</string>
  <key>CFBundleDisplayName</key><string>GitHub PR Watch</string>
  <key>CFBundleIdentifier</key><string>dev.lubelski.$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>PRWatchGitCommit</key><string>$GIT_COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  $UPDATER_KEYS
</dict>
</plist>
PLIST

# Sign. The identity is the first of these that exists:
#   1. PRWATCH_SIGNING_IDENTITY, when it is set.
#   2. A Developer ID Application certificate in the keychain, so macOS on another Mac opens
#      the app and notarization accepts it.
#   3. This Mac's self-signed "github-pr-watch-menubar development" certificate, if the owner
#      made one, so every build has the same identity and the Keychain keeps "Always Allow".
#   4. Ad hoc.
DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
if [[ -n "${PRWATCH_SIGNING_IDENTITY:-}" ]]; then
  IDENTITY="$PRWATCH_SIGNING_IDENTITY"
elif [[ -n "$DEVELOPER_ID" ]]; then
  IDENTITY="$DEVELOPER_ID"
elif security find-certificate -c "$NAME development" >/dev/null 2>&1; then
  IDENTITY="$NAME development"
else
  IDENTITY="-"
fi
SIGN=(codesign --force --sign "$IDENTITY")
if [[ "$IDENTITY" == *"Developer ID Application"* ]]; then
  # Notarization needs the hardened runtime and a secure timestamp.
  SIGN+=(--options runtime --timestamp)
fi

# Sparkle's helpers are signed one at a time, innermost first, as its documentation says.
# Never --deep.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE"
# The app needs no entitlements: it is not sandboxed, and network access, notifications, the
# Keychain, and running gh need none under the hardened runtime.
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
if [[ "$IDENTITY" == "-" ]]; then
  echo "Signed ad hoc."
else
  echo "Signed with \"$IDENTITY\""
fi
echo "Built $APP, version $VERSION ($BUILD_NUMBER), commit $GIT_COMMIT"
