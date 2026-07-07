#!/bin/bash
# Builds the distributable DMG (D10): release app bundle → Portavoz-<v>.dmg
# with an /Applications symlink.
#
#   scripts/make-dmg.sh                # ad-hoc signed (local testing)
#   PORTAVOZ_SIGN_IDENTITY="Developer ID Application: …" scripts/make-dmg.sh
#
# Notarization (needs the Developer ID + a notarytool keychain profile):
#   PORTAVOZ_NOTARY_PROFILE=<profile> scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Portavoz.app/Contents/Info.plist 2>/dev/null || echo 0.1.0)"

scripts/make-app.sh --release

DMG="dist/Portavoz-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -a dist/Portavoz.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Portavoz" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"

if [[ -n "${PORTAVOZ_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$PORTAVOZ_SIGN_IDENTITY" "$DMG"
fi

if [[ -n "${PORTAVOZ_NOTARY_PROFILE:-}" ]]; then
  echo "Notarizando (perfil: $PORTAVOZ_NOTARY_PROFILE)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$PORTAVOZ_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
elif [[ -z "${PORTAVOZ_SIGN_IDENTITY:-}" ]]; then
  echo "⚠️  DMG con firma ad-hoc: sirve para probar en esta máquina."
  echo "   Para distribuir: PORTAVOZ_SIGN_IDENTITY + PORTAVOZ_NOTARY_PROFILE."
fi

shasum -a 256 "$DMG"
echo "OK → $DMG"
