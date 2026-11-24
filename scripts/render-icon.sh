#!/usr/bin/env bash
# Redraws the app icon, Resources/AppIcon.icon, from Sources/GitHubPRWatchCore/AppIconDrawing.swift
# and PullRequestMark.swift, and the pictures of it in docs/. Run it after changing the drawing,
# and commit what it writes. bundle.sh compiles the icon itself. It launches nothing.
#
#   scripts/render-icon.sh      # the shipped design, AppIconDrawing.shipped
#   scripts/render-icon.sh 2    # design 2 of the three instead
#
# docs/icon.png              the compiled icon, for the README
# docs/icon-appearances.png  default, dark, clear and tinted, as macOS draws them
# docs/icon-sizes.png        16 to 256 points, at 2×
# docs/icon-candidates.png   every design side by side
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -O -o "$WORK/render-icon" scripts/icon/main.swift \
  Sources/GitHubPRWatchCore/AppIconDrawing.swift Sources/GitHubPRWatchCore/PullRequestMark.swift
"$WORK/render-icon" Resources/AppIcon.icon "$@"

# The pictures, drawn by Icon Composer's own renderer with the system's glass.
ICTOOL="$DEVELOPER_DIR/../Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ ! -x "$ICTOOL" ]]; then
  echo "warning: Icon Composer's ictool is not in this Xcode, so docs/icon*.png are unchanged" >&2
  exit 0
fi
export_icon() { # <icon> <out.png> <rendition> <points>
  "$ICTOOL" "$1" --export-image --output-file "$2" --platform macOS --rendition "$3" \
    --width "$4" --height "$4" --scale 2 >/dev/null
}
mkdir -p docs

export_icon Resources/AppIcon.icon docs/icon.png Default 256

SHEET=()
for rendition in Default Dark ClearLight ClearDark TintedLight TintedDark; do
  export_icon Resources/AppIcon.icon "$WORK/$rendition.png" "$rendition" 128
  backdrop=light; [[ "$rendition" == *Dark ]] && backdrop=dark
  SHEET+=("$WORK/$rendition.png" "$rendition" "$backdrop")
done
"$WORK/render-icon" --sheet docs/icon-appearances.png "App icon in each appearance, 128 pt at 2×" "${SHEET[@]}"

SHEET=()
for points in 256 128 64 32 16; do
  export_icon Resources/AppIcon.icon "$WORK/size-$points.png" Default "$points"
  SHEET+=("$WORK/size-$points.png" "$points pt" light)
done
"$WORK/render-icon" --sheet docs/icon-sizes.png "App icon at Dock, Finder and list sizes, at 2×" "${SHEET[@]}"

SHEET=()
for design in 1 2 3; do
  mkdir -p "$WORK/candidate-$design.icon"
  title="$("$WORK/render-icon" "$WORK/candidate-$design.icon" "$design" | sed -E 's/^Drew design [0-9]+, (.*), into .*/\1/')"
  for rendition in Default Dark; do
    export_icon "$WORK/candidate-$design.icon" "$WORK/candidate-$design-$rendition.png" "$rendition" 128
  done
  SHEET+=("$WORK/candidate-$design-Default.png" "$design. $title" light)
  SHEET+=("$WORK/candidate-$design-Dark.png" "$design. $title, dark" dark)
done
"$WORK/render-icon" --sheet docs/icon-candidates.png "Icon candidates, 128 pt at 2×" "${SHEET[@]}"
