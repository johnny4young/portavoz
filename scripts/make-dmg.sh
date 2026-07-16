#!/bin/bash
# Builds the distributable DMG (D10): release app bundle → Portavoz-<v>.dmg
# with an /Applications symlink.
#
#   scripts/make-dmg.sh                         # ad-hoc signed (local testing)
#   scripts/make-dmg.sh --skip-build            # package existing dist/Portavoz.app
#   PORTAVOZ_SIGN_IDENTITY="Developer ID Application: …" scripts/make-dmg.sh
#
# Notarization (needs the Developer ID + a notarytool keychain profile):
#   PORTAVOZ_NOTARY_PROFILE=<profile> scripts/make-dmg.sh
#
# Package managers extract Portavoz.app from the DMG and assess that bundle
# independently. A distribution build therefore notarizes + staples the app
# BEFORE creating the DMG, then notarizes + staples the outer DMG as well.
set -euo pipefail
cd "$(dirname "$0")/.."

SKIP_BUILD=false

usage() {
  echo "usage: scripts/make-dmg.sh [--skip-build]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

if [[ "$SKIP_BUILD" == false ]]; then
  args=(--release)
  if [[ -n "${PORTAVOZ_VERSION:-}" ]]; then
    args+=(--version "$PORTAVOZ_VERSION")
  fi
  if [[ -n "${PORTAVOZ_BUILD:-}" ]]; then
    args+=(--build "$PORTAVOZ_BUILD")
  fi
  scripts/make-app.sh "${args[@]}"
elif [[ ! -d dist/Portavoz.app ]]; then
  echo "dist/Portavoz.app does not exist; omit --skip-build or run scripts/make-app.sh first." >&2
  exit 66
fi

if [[ -n "${PORTAVOZ_NOTARY_PROFILE:-}" \
  && ( -z "${PORTAVOZ_SIGN_IDENTITY:-}" || "${PORTAVOZ_SIGN_IDENTITY:-}" == "-" ) ]]; then
  echo "PORTAVOZ_NOTARY_PROFILE requires PORTAVOZ_SIGN_IDENTITY." >&2
  exit 64
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Portavoz.app/Contents/Info.plist)"

DMG="dist/Portavoz-$VERSION.dmg"
WORK="$(mktemp -d)"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
trap 'rm -rf "$WORK"' EXIT

if [[ -n "${PORTAVOZ_NOTARY_PROFILE:-}" ]]; then
  APP_ARCHIVE="$WORK/Portavoz.zip"
  echo "Notarizing app bundle (profile: $PORTAVOZ_NOTARY_PROFILE)…"
  ditto -c -k --sequesterRsrc --keepParent dist/Portavoz.app "$APP_ARCHIVE"
  xcrun notarytool submit "$APP_ARCHIVE" \
    --keychain-profile "$PORTAVOZ_NOTARY_PROFILE" --wait
  xcrun stapler staple dist/Portavoz.app
  xcrun stapler validate dist/Portavoz.app
  codesign --verify --deep --strict --verbose=2 dist/Portavoz.app
fi

cp -a dist/Portavoz.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Portavoz" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"

if [[ -n "${PORTAVOZ_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$PORTAVOZ_SIGN_IDENTITY" "$DMG"
fi

if [[ -n "${PORTAVOZ_NOTARY_PROFILE:-}" ]]; then
  echo "Notarizing disk image (profile: $PORTAVOZ_NOTARY_PROFILE)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$PORTAVOZ_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  scripts/verify-distribution.sh "$DMG"
elif [[ -z "${PORTAVOZ_SIGN_IDENTITY:-}" ]]; then
  echo "⚠️  DMG uses ad-hoc signing: suitable only for testing on this machine."
  echo "   For distribution: PORTAVOZ_SIGN_IDENTITY + PORTAVOZ_NOTARY_PROFILE."
fi

shasum -a 256 "$DMG"
echo "OK → $DMG"
