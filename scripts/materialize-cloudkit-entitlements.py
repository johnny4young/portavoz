#!/usr/bin/env python3
"""Materialize profile-owned macOS identity into production entitlements."""

import os
import plistlib
import sys
import tempfile
from pathlib import Path


APPLICATION_IDENTIFIER_KEYS = (
    "com.apple.application-identifier",
    "application-identifier",
)


def load_dictionary(path: Path, label: str) -> dict:
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise SystemExit(f"unable to decode {label} property list") from None
    if not isinstance(value, dict):
        raise SystemExit(f"{label} property list is not a dictionary")
    return value


def require_alias_value(container: dict, keys: tuple[str, ...], label: str) -> str:
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


def normalized_prefixes(profile: dict) -> list[str]:
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
    return prefixes


def materialize(base: dict, profile: dict, bundle_identifier: str) -> dict:
    profile_entitlements = profile.get("Entitlements")
    if not isinstance(profile_entitlements, dict):
        raise SystemExit(
            "provisioning profile has no valid Entitlements dictionary"
        )

    application_identifier = require_alias_value(
        profile_entitlements,
        APPLICATION_IDENTIFIER_KEYS,
        "provisioning profile",
    )
    expected_application_identifiers = {
        f"{prefix}.{bundle_identifier}"
        for prefix in normalized_prefixes(profile)
    }
    if application_identifier not in expected_application_identifiers:
        raise SystemExit(
            "provisioning profile application identifier does not authorize "
            f"{bundle_identifier!r}"
        )

    team_identifier = profile_entitlements.get(
        "com.apple.developer.team-identifier"
    )
    if not isinstance(team_identifier, str) or not team_identifier:
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
        or team_identifier not in team_identifiers
    ):
        raise SystemExit(
            "provisioning profile team identifier is inconsistent"
        )

    for key in (*APPLICATION_IDENTIFIER_KEYS, "com.apple.developer.team-identifier"):
        if key in base:
            raise SystemExit(
                f"base production entitlements must not hard-code {key}"
            )

    result = dict(base)
    result["com.apple.application-identifier"] = application_identifier
    result["com.apple.developer.team-identifier"] = team_identifier
    return result


def write_atomic(destination: Path, value: dict) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.",
        dir=destination.parent,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            plistlib.dump(value, handle, fmt=plistlib.FMT_XML, sort_keys=True)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: materialize-cloudkit-entitlements.py "
            "<base.plist> <profile.plist> <output.plist> <bundle-id>"
        )
    base_path, profile_path, output_path = map(Path, sys.argv[1:4])
    bundle_identifier = sys.argv[4]
    if not bundle_identifier or "*" in bundle_identifier:
        raise SystemExit("bundle identifier must be explicit")

    base = load_dictionary(base_path, "base entitlements")
    profile = load_dictionary(profile_path, "provisioning profile")
    write_atomic(
        output_path,
        materialize(base, profile, bundle_identifier),
    )


if __name__ == "__main__":
    main()
