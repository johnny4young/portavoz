#!/bin/bash
# Rebuilds assets/AppIcon.icns from assets/icon/pv-icon-1024.png.
# The master PNG comes from scripts/icon-p.html («La P que habla», needs
# Fraunces from Google Fonts, so it renders in a browser): open the page,
# wait for "ready", export each canvas with toDataURL and save as
# assets/icon/pv-icon-1024.png + pv-menubar-16/32.png. Then run this.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=assets/icon/pv-icon-1024.png
[[ -f "$SRC" ]] || { echo "missing $SRC (render scripts/icon-p.html first)"; exit 1; }

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
cp "$SRC" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o assets/AppIcon.icns
echo "✅ assets/AppIcon.icns"
