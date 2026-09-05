#!/bin/bash
# Builds the exact production-identity app used only by the two-Mac CloudKit
# qualification workflow. The artifact remains under dist/ and must be invoked
# directly by the qualification runner: it is never installed, registered with
# LaunchServices, or opened beside the user's notarized Portavoz.app.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${PORTAVOZ_RELEASE_VERSION:?production-sync qualification requires PORTAVOZ_RELEASE_VERSION}"
BUILD="${PORTAVOZ_RELEASE_BUILD:?production-sync qualification requires PORTAVOZ_RELEASE_BUILD}"
SOURCE_COMMIT="${PORTAVOZ_RELEASE_COMMIT:?production-sync qualification requires PORTAVOZ_RELEASE_COMMIT}"
SIGN_ID="${PORTAVOZ_SIGN_IDENTITY:?production-sync qualification requires PORTAVOZ_SIGN_IDENTITY}"
PROVISIONING_PROFILE="${PORTAVOZ_PROVISIONING_PROFILE:?production-sync qualification requires PORTAVOZ_PROVISIONING_PROFILE}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "PORTAVOZ_RELEASE_VERSION must be a semantic version." >&2
  exit 64
fi
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "PORTAVOZ_RELEASE_BUILD must contain only decimal digits." >&2
  exit 64
fi
if [[ ! "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "PORTAVOZ_RELEASE_COMMIT must be one full lowercase Git SHA." >&2
  exit 64
fi
if [[ "$SIGN_ID" == "-" ]]; then
  echo "production-sync qualification cannot use an ad-hoc signature." >&2
  exit 64
fi
if [[ ! -f "$PROVISIONING_PROFILE" ]]; then
  echo "production-sync provisioning profile not found." >&2
  exit 66
fi

require_exact_source_checkout() {
  local phase="$1"
  if [[ "$(git rev-parse HEAD)" != "$SOURCE_COMMIT" ]]; then
    echo "PORTAVOZ_RELEASE_COMMIT does not match HEAD at $phase." >&2
    exit 64
  fi
  if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    echo "production-sync qualification requires a clean tracked worktree at $phase." >&2
    exit 64
  fi
}

OUTPUT="dist/Portavoz Sync Qualification.app"
STAGING="dist/.Portavoz-Sync-Qualification.$$.app"
cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT

require_exact_source_checkout "preflight"
rm -rf "$OUTPUT" "$STAGING"

PORTAVOZ_RELEASE_COMMIT="$SOURCE_COMMIT" \
PORTAVOZ_SIGN_IDENTITY="$SIGN_ID" \
PORTAVOZ_PROVISIONING_PROFILE="$PROVISIONING_PROFILE" \
PORTAVOZ_REQUIRE_CLOUDKIT_PROFILE=1 \
  scripts/make-app.sh --release --version "$VERSION" --build "$BUILD"

require_exact_source_checkout "post-build verification"
SIGN_ENTITLEMENTS="$(cat dist/.portavoz-sign-entitlements)"
if [[ "$SIGN_ENTITLEMENTS" != "dist/.portavoz-production.entitlements" ]]; then
  echo "production-sync qualification did not use the production entitlements." >&2
  exit 65
fi
mv dist/Portavoz.app "$STAGING"

INFO_PLIST="$STAGING/Contents/Info.plist"
QUALIFICATION_CONTRACT="docs/evidence/production-sync-qualification.json"
if [[ ! -f "$QUALIFICATION_CONTRACT" ]]; then
  echo "production-sync qualification contract not found." >&2
  exit 66
fi
cp "$QUALIFICATION_CONTRACT" \
  "$STAGING/Contents/Resources/production-sync-qualification.json"
plutil -replace CFBundleDisplayName -string "Portavoz Sync Qualification" "$INFO_PLIST"
plutil -replace CFBundleName -string "Portavoz Sync Qualification" "$INFO_PLIST"
for plist in "$STAGING"/Contents/Resources/*.lproj/InfoPlist.strings; do
  sed -i '' \
    -e 's/^"CFBundleDisplayName" = ".*";$/"CFBundleDisplayName" = "Portavoz Sync Qualification";/' \
    -e 's/^"CFBundleName" = ".*";$/"CFBundleName" = "Portavoz Sync Qualification";/' \
    "$plist"
  plutil -lint "$plist" >/dev/null
done

# Editing display metadata invalidates only the outer app signature. Preserve
# the production identifier and capabilities, then verify the final artifact
# rather than trusting the intermediate make-app.sh result.
codesign --force --options runtime --timestamp --sign "$SIGN_ID" \
  --entitlements "$SIGN_ENTITLEMENTS" "$STAGING"
codesign --verify --deep --strict --verbose=2 "$STAGING"
scripts/verify-cloudkit-capabilities.sh "$STAGING"

python3 - \
  "$INFO_PLIST" \
  "$STAGING/Contents/Resources/production-sync-qualification.json" \
  "$QUALIFICATION_CONTRACT" \
  "$VERSION" \
  "$BUILD" \
  "$SOURCE_COMMIT" <<'PY'
import plistlib
import sys

(
    info_path,
    bundled_contract,
    source_contract,
    expected_version,
    expected_build,
    expected_commit,
) = sys.argv[1:]
with open(info_path, "rb") as handle:
    info = plistlib.load(handle)

expected = {
    "CFBundleIdentifier": "app.portavoz.mac",
    "CFBundleDisplayName": "Portavoz Sync Qualification",
    "CFBundleName": "Portavoz Sync Qualification",
    "CFBundleShortVersionString": expected_version,
    "CFBundleVersion": expected_build,
    "PortavozSourceCommit": expected_commit,
}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(
            f"production-sync qualification has invalid {key}"
        )

with open(bundled_contract, "rb") as handle:
    bundled = handle.read()
with open(source_contract, "rb") as handle:
    source = handle.read()
if bundled != source:
    raise SystemExit("production-sync qualification contract drifted")
PY

require_exact_source_checkout "final verification"
mv "$STAGING" "$OUTPUT"
trap - EXIT

echo "OK → $OUTPUT"
echo "The bundle is exact-ID qualification evidence only; do not install, register, or open it."
