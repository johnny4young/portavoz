#!/bin/bash
# Cuts a release: version-stamps the bundle, builds the DMG, generates the
# Sparkle appcast, and fills in the Homebrew cask. Everything lands in
# dist/release/ ready to attach to the GitHub release.
#
#   scripts/make-release.sh 0.1.0
#
# For a real (distributable) release also export:
#   PORTAVOZ_SIGN_IDENTITY="Developer ID Application: …"
#   PORTAVOZ_NOTARY_PROFILE=<notarytool keychain profile>
#
# Publishing checklist afterwards:
#   1. git tag v<version> && push (repo + tag)
#   2. gh release create v<version> dist/release/Portavoz-<version>.dmg dist/release/appcast.xml
#   3. Copy dist/release/portavoz.rb into the johnny4young/homebrew-portavoz tap
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/make-release.sh <version>}"
BUILD="${PORTAVOZ_BUILD:-$(date +%Y%m%d%H%M)}"
GENERATE_APPCAST="${GENERATE_APPCAST:-$HOME/.local/bin/generate_appcast}"

scripts/make-app.sh --release --version "$VERSION" --build "$BUILD"
scripts/make-dmg.sh --skip-build

RELEASE_DIR=dist/release
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
mv "dist/Portavoz-$VERSION.dmg" "$RELEASE_DIR/"

# Sparkle appcast (EdDSA-signed with the 'portavoz' Keychain key).
if [[ -x "$GENERATE_APPCAST" ]]; then
  "$GENERATE_APPCAST" --account portavoz "$RELEASE_DIR"
else
  echo "⚠️  generate_appcast not found ($GENERATE_APPCAST)."
  echo "   Download it from the Sparkle release and export it in GENERATE_APPCAST."
fi

# Homebrew cask with real version + sha256.
SHA256="$(shasum -a 256 "$RELEASE_DIR/Portavoz-$VERSION.dmg" | cut -d' ' -f1)"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA256/" \
  packaging/portavoz.rb > "$RELEASE_DIR/portavoz.rb"

echo ""
echo "Release $VERSION ready in $RELEASE_DIR/:"
ls -la "$RELEASE_DIR"
