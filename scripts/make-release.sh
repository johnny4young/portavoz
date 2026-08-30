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
#   PORTAVOZ_PROVISIONING_PROFILE=<Developer ID .provisionprofile with CloudKit + APNs>
#
# Publishing checklist afterwards:
#   1. git tag v<version> && push (repo + tag)
#   2. gh release create v<version> dist/release/Portavoz-<version>.dmg dist/release/appcast.xml
#   3. gh workflow run update-cask.yml -f tag=v<version>  (bumps johnny4young/homebrew-tap)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/make-release.sh <version>}"
BUILD="${PORTAVOZ_BUILD:-$(date +%Y%m%d%H%M)}"
GENERATE_APPCAST="${GENERATE_APPCAST:-$HOME/.local/bin/generate_appcast}"
SOURCE_COMMIT="${PORTAVOZ_RELEASE_COMMIT:?A release requires PORTAVOZ_RELEASE_COMMIT}"

if [[ ! "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "PORTAVOZ_RELEASE_COMMIT must be one full lowercase Git SHA." >&2
  exit 64
fi
require_exact_source_checkout() {
  local phase="$1"
  if [[ "$(git rev-parse HEAD)" != "$SOURCE_COMMIT" ]]; then
    echo "PORTAVOZ_RELEASE_COMMIT does not match HEAD at $phase." >&2
    exit 64
  fi
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "A release requires a clean tracked worktree at $phase." >&2
    exit 64
  fi
}

require_exact_source_checkout "preflight"

: "${PORTAVOZ_PROVISIONING_PROFILE:?A release requires the Developer ID CloudKit provisioning profile}"
: "${PORTAVOZ_SIGN_IDENTITY:?A release requires a Developer ID Application identity}"
: "${PORTAVOZ_NOTARY_PROFILE:?A release requires a notarytool keychain profile}"
if [[ "$PORTAVOZ_SIGN_IDENTITY" == "-" ]]; then
  echo "A release cannot use an ad-hoc signing identity." >&2
  exit 64
fi
if [[ ! -x "$GENERATE_APPCAST" ]]; then
  echo "A release requires an executable generate_appcast at $GENERATE_APPCAST." >&2
  exit 64
fi

PORTAVOZ_RELEASE_COMMIT="$SOURCE_COMMIT" PORTAVOZ_REQUIRE_CLOUDKIT_PROFILE=1 \
  scripts/make-app.sh --release --version "$VERSION" --build "$BUILD"
# Refuse notarization if the long app build observed or ended beside a changed
# tracked checkout. Otherwise the stamped commit could name adjacent source.
require_exact_source_checkout "post-build verification"
scripts/make-dmg.sh --skip-build

RELEASE_DIR=dist/release
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
mv "dist/Portavoz-$VERSION.dmg" "$RELEASE_DIR/"

# Sparkle appcast (EdDSA-signed with the 'portavoz' Keychain key).
"$GENERATE_APPCAST" --account portavoz "$RELEASE_DIR"
scripts/verify_release_appcast.py \
  --appcast "$RELEASE_DIR/appcast.xml" \
  --version "$VERSION" \
  --build "$BUILD" \
  --dmg "$RELEASE_DIR/Portavoz-$VERSION.dmg"

# Homebrew cask with real version + sha256.
SHA256="$(shasum -a 256 "$RELEASE_DIR/Portavoz-$VERSION.dmg" | cut -d' ' -f1)"
sed -e "s/__VERSION__/$VERSION/" -e "s/__SHA256__/$SHA256/" \
  packaging/Casks/portavoz.rb > "$RELEASE_DIR/portavoz.rb"

echo ""
echo "Release $VERSION ready in $RELEASE_DIR/:"
ls -la "$RELEASE_DIR"
