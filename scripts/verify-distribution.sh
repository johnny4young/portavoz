#!/bin/bash
# Verifies the exact direct-download/Homebrew boundary: the outer disk image
# and the independently extracted app must both be signed, notarized, and
# stapled. This catches a DMG that opens directly but leaves package-manager
# installs dependent on an online Gatekeeper ticket lookup.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: scripts/verify-distribution.sh <Portavoz.dmg> [--receipt <path>]

Verifies the signed, notarized, stapled DMG and its independently extracted
app. When --receipt is provided, writes a content-free distribution receipt
only after every verification succeeds.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 1 && $# -ne 3 ]]; then
  usage >&2
  exit 64
fi

DMG="$1"
RECEIPT=""
if [[ $# -eq 3 ]]; then
  if [[ "$2" != "--receipt" || -z "$3" ]]; then
    usage >&2
    exit 64
  fi
  RECEIPT="$3"
fi
if [[ ! -f "$DMG" ]]; then
  echo "distribution image not found: $DMG" >&2
  exit 66
fi

MOUNT="$(mktemp -d)"
APP_COPY="$(mktemp -d)/Portavoz.app"
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then
    hdiutil detach "$MOUNT" -quiet || true
  fi
  rm -rf "$MOUNT" "$(dirname "$APP_COPY")"
}
trap cleanup EXIT

codesign --verify --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vvv -t install "$DMG"

hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" -quiet
mounted=true
if [[ ! -d "$MOUNT/Portavoz.app" ]]; then
  echo "Portavoz.app is missing from the disk image." >&2
  exit 65
fi

# Copying out of the image mirrors Homebrew Cask's package-manager boundary.
cp -a "$MOUNT/Portavoz.app" "$APP_COPY"
hdiutil detach "$MOUNT" -quiet
mounted=false

codesign --verify --deep --strict --verbose=2 "$APP_COPY"
xcrun stapler validate "$APP_COPY"
spctl -a -vvv -t exec "$APP_COPY"
scripts/verify-cloudkit-capabilities.sh "$APP_COPY"

if [[ -n "$RECEIPT" ]]; then
  VERSION="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :CFBundleShortVersionString' \
      "$APP_COPY/Contents/Info.plist"
  )"
  BUILD="$(
    /usr/libexec/PlistBuddy \
      -c 'Print :CFBundleVersion' \
      "$APP_COPY/Contents/Info.plist"
  )"
  DIGEST="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  python3 scripts/release_reliability.py record-distribution \
    --version "$VERSION" \
    --build "$BUILD" \
    --sha256 "$DIGEST" \
    --output "$RECEIPT"
fi

echo "OK → $DMG and extracted Portavoz.app are self-contained for Gatekeeper and CloudKit."
