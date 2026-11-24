#!/usr/bin/env bash
# Draws the UI to PNG files with placeholder data, without opening a window or taking focus.
# Usage: scripts/render.sh [output-folder]    (default: build/renders)
#
# The render tool runs with activation policy `.prohibited` and never orders a window front,
# so it is safe to run while someone is using the Mac. See AGENTS.md.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

OUT="${1:-build/renders}"
swift build --product GitHubPRWatchRender
BIN="$(swift build --show-bin-path)/GitHubPRWatchRender"

# Stamp the real SDK version, as scripts/bundle.sh does for the app, so SwiftUI draws with
# the current look instead of the compatibility mode for older apps.
mkdir -p build
STAMPED=build/GitHubPRWatchRender
xcrun vtool -set-build-version macos 27.0 "$(xcrun --sdk macosx --show-sdk-version)" -replace \
  -output "$STAMPED" "$BIN"
codesign --force --sign - "$STAMPED" 2>/dev/null

"$STAMPED" "$OUT"
