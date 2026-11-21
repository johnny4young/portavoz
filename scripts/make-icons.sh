#!/bin/bash
# Renders every brand asset from Sources/portavoz-app/PortavozMark.swift:
# the Icon Composer document, AppIcon.icns, PNG masters, SVGs and social card.
set -euo pipefail
cd "$(dirname "$0")/.."

ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ictool" ]] || { echo "ictool not found: select a full Xcode 26+." >&2; exit 69; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -parse-as-library -O -o "$work/render-brand" \
  scripts/render-brand.swift Sources/portavoz-app/PortavozMark.swift
"$work/render-brand" vectors

for pair in Default:pv-icon Dark:pv-icon-dark; do
  rendition=${pair%%:*}
  out=assets/icon/${pair#*:}-1024.png
  # The macOS grid: an 824 squircle centred on the 1024 canvas.
  "$ictool" assets/AppIcon.icon --export-image --output-file "$work/$rendition.png" \
    --platform macOS --rendition "$rendition" --width 824 --height 824 --scale 1 >/dev/null
  [[ -s "$work/$rendition.png" ]] || { echo "ictool exported no $rendition rendition" >&2; exit 1; }
  sips --padToHeightWidth 1024 1024 "$work/$rendition.png" --out "$out" >/dev/null
  echo "→ $out"
done

"$work/render-brand" social assets/icon/pv-icon-dark-1024.png
cp assets/social-preview.png site/assets/og.png

# The legacy icns (Finder fallback, same name for Sparkle and Homebrew).
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" assets/icon/pv-icon-1024.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" assets/icon/pv-icon-1024.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o assets/AppIcon.icns
echo "→ assets/AppIcon.icns"
