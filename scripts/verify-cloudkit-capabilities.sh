#!/bin/bash
# Verifies the restricted signing boundary required by CKSyncEngine for the
# direct-download Developer ID app. Entitlements and the embedded provisioning
# profile must independently authorize the exact production capabilities.
set -euo pipefail

APP="${1:?usage: scripts/verify-cloudkit-capabilities.sh <Portavoz.app>}"
if [[ ! -d "$APP" ]]; then
  echo "app bundle not found: $APP" >&2
  exit 66
fi

PROFILE="$APP/Contents/embedded.provisionprofile"
if [[ ! -f "$PROFILE" ]]; then
  echo "CloudKit release is missing Contents/embedded.provisionprofile." >&2
  exit 65
fi

WORK="$(mktemp -d)"
SIGNED="$WORK/signed-entitlements.plist"
PROFILE_PLIST="$WORK/profile.plist"
trap 'rm -rf "$WORK"' EXIT

codesign -d --entitlements :- "$APP" > "$SIGNED"
security cms -D -i "$PROFILE" > "$PROFILE_PLIST"

# Exact app entitlements matter: accepting an unrelated container or service
# would make the tracked release contract differ from what was actually signed.
# Apple may authorize all iCloud services in a Developer ID direct profile with
# the wildcard value `*`; the app signature must still narrow that authorization
# to CloudKit. Python's plist parser also lets the gate reject an expired profile
# before notarization.
python3 - "$SIGNED" "$PROFILE_PLIST" <<'PY'
from datetime import datetime, timezone
import plistlib
import sys

signed_path, profile_path = sys.argv[1:]
with open(signed_path, "rb") as handle:
    signed = plistlib.load(handle)
with open(profile_path, "rb") as handle:
    profile = plistlib.load(handle)

expected = {
    "com.apple.developer.icloud-container-identifiers": ["iCloud.app.portavoz.mac"],
    "com.apple.developer.icloud-services": ["CloudKit"],
    "com.apple.developer.icloud-container-environment": "Production",
    "com.apple.developer.aps-environment": "production",
}

def verify(label, actual, allow_icloud_services_wildcard=False):
    for key, value in expected.items():
        if (
            allow_icloud_services_wildcard
            and key == "com.apple.developer.icloud-services"
            and actual.get(key) in ("*", ["*"])
        ):
            continue
        if actual.get(key) != value:
            observed = actual.get(key, "<missing>")
            raise SystemExit(f"{label} has {key} = {observed!r}; expected {value!r}")

verify("signed app", signed)
verify(
    "provisioning profile",
    profile.get("Entitlements", {}),
    allow_icloud_services_wildcard=True,
)
expiration = profile.get("ExpirationDate")
if not isinstance(expiration, datetime):
    raise SystemExit("provisioning profile has no valid ExpirationDate")
now = datetime.now(timezone.utc).replace(tzinfo=None)
if expiration <= now:
    raise SystemExit(f"provisioning profile expired at {expiration.isoformat()}Z")
PY

echo "OK → signed app and Developer ID profile authorize production CloudKit + APNs."
