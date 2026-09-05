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

INFO_PLIST="$APP/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "CloudKit release is missing Contents/Info.plist." >&2
  exit 65
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

# Exact app identity and entitlements matter: a profile for the production App
# ID cannot authorize a bundle that was later renamed to a development bundle
# identifier. Accepting an unrelated container or service would likewise make
# the tracked release contract differ from what was actually signed.
# Apple may authorize all iCloud services in a Developer ID direct profile with
# the wildcard value `*`; the app signature must still narrow that authorization
# to CloudKit. Python's plist parser also lets the gate reject an expired profile
# before notarization.
python3 - "$SIGNED" "$PROFILE_PLIST" "$INFO_PLIST" <<'PY'
from datetime import datetime, timezone
import plistlib
import sys

signed_path, profile_path, info_path = sys.argv[1:]

def load_dictionary(path, label):
    try:
        with open(path, "rb") as handle:
            value = plistlib.load(handle)
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise SystemExit(f"unable to decode {label} property list") from None
    if not isinstance(value, dict):
        raise SystemExit(f"{label} property list is not a dictionary")
    return value

signed = load_dictionary(signed_path, "signed entitlements")
profile = load_dictionary(profile_path, "provisioning profile")
info = load_dictionary(info_path, "app Info.plist")

expected_bundle_identifier = "app.portavoz.mac"
bundle_identifier = info.get("CFBundleIdentifier")
if bundle_identifier != expected_bundle_identifier:
    raise SystemExit(
        "signed app has CFBundleIdentifier "
        f"{bundle_identifier!r}; expected {expected_bundle_identifier!r}"
    )

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
profile_entitlements = profile.get("Entitlements")
if not isinstance(profile_entitlements, dict):
    raise SystemExit(
        "provisioning profile has no valid Entitlements dictionary"
    )
verify(
    "provisioning profile",
    profile_entitlements,
    allow_icloud_services_wildcard=True,
)

prefixes = profile.get("ApplicationIdentifierPrefix")
if (
    not isinstance(prefixes, list)
    or not prefixes
    or any(
        not isinstance(prefix, str)
        or not prefix
        or prefix != prefix.strip()
        or "." in prefix
        for prefix in prefixes
    )
):
    raise SystemExit(
        "provisioning profile has no valid ApplicationIdentifierPrefix"
    )

identifier_keys = (
    "application-identifier",
    "com.apple.application-identifier",
)

def alias_value(container, keys, label):
    values = []
    for key in keys:
        if key not in container:
            continue
        value = container[key]
        if not isinstance(value, str) or not value:
            raise SystemExit(f"{label} has invalid {key}")
        values.append(value)
    if not values:
        raise SystemExit(f"{label} has no application identifier entitlement")
    if len(set(values)) != 1:
        raise SystemExit(f"{label} has conflicting application identifiers")
    return values[0]

application_identifier = alias_value(
    profile_entitlements,
    identifier_keys,
    "provisioning profile",
)
expected_application_identifiers = {
    f"{prefix}.{expected_bundle_identifier}" for prefix in prefixes
}
if application_identifier not in expected_application_identifiers:
    raise SystemExit(
        "provisioning profile application identifier does not authorize "
        f"{expected_bundle_identifier!r}"
    )

signed_application_identifier = signed.get("com.apple.application-identifier")
if signed_application_identifier != application_identifier:
    raise SystemExit(
        "signed app application identifier does not match the provisioning profile"
    )
if "application-identifier" in signed:
    alias_value(signed, identifier_keys, "signed app")

profile_team_identifier = profile_entitlements.get(
    "com.apple.developer.team-identifier"
)
if not isinstance(profile_team_identifier, str) or not profile_team_identifier:
    raise SystemExit(
        "provisioning profile has no valid developer team identifier"
    )
team_identifiers = profile.get("TeamIdentifier")
if (
    not isinstance(team_identifiers, list)
    or not team_identifiers
    or any(
        not isinstance(identifier, str) or not identifier
        for identifier in team_identifiers
    )
    or profile_team_identifier not in team_identifiers
):
    raise SystemExit("provisioning profile team identifier is inconsistent")
if signed.get("com.apple.developer.team-identifier") != profile_team_identifier:
    raise SystemExit(
        "signed app developer team identifier does not match the provisioning profile"
    )

expiration = profile.get("ExpirationDate")
if not isinstance(expiration, datetime):
    raise SystemExit("provisioning profile has no valid ExpirationDate")
if expiration.tzinfo is not None:
    expiration = expiration.astimezone(timezone.utc).replace(tzinfo=None)
now = datetime.now(timezone.utc).replace(tzinfo=None)
if expiration <= now:
    raise SystemExit(f"provisioning profile expired at {expiration.isoformat()}Z")
PY

echo "OK → exact production app identity and Developer ID profile authorize CloudKit + APNs."
