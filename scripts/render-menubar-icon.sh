#!/usr/bin/env bash
# Renders the menu bar icon in each state, on light and dark menu bars, into docs/:
# menubar-icon.png at 2×, and menubar-icon-1x.png with the pixels at 1× and 2×.
# Run it after changing how the menu bar icon looks, and show the result in the PR.
# It draws with the app's own icon code and launches nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -O -o "$WORK/render-menubar-icon" scripts/menubar-icon/main.swift \
  Sources/GitHubPRWatchUI/MenuBarIcon.swift Sources/GitHubPRWatchCore/PullRequestMark.swift
mkdir -p docs
"$WORK/render-menubar-icon" docs
