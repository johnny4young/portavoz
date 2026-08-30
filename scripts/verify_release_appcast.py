#!/usr/bin/env python3
"""Validate the exact signed Sparkle feed produced for one Portavoz release."""

from __future__ import annotations

import argparse
import base64
import binascii
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MAXIMUM_APPCAST_BYTES = 1_048_576


class AppcastValidationError(RuntimeError):
    """Raised when a release appcast cannot prove the exact signed artifact."""


def require_regular_file(path: Path, label: str) -> os.stat_result:
    if path.is_symlink():
        raise AppcastValidationError(f"{label} must not be a symbolic link")
    try:
        stat = path.stat()
    except FileNotFoundError as error:
        raise AppcastValidationError(f"{label} not found: {path}") from error
    if not path.is_file():
        raise AppcastValidationError(f"{label} must be a regular file: {path}")
    return stat


def validate_appcast(appcast: Path, version: str, build: str, dmg: Path) -> None:
    appcast_stat = require_regular_file(appcast, "release appcast")
    dmg_stat = require_regular_file(dmg, "release DMG")
    if appcast_stat.st_size <= 0 or appcast_stat.st_size > MAXIMUM_APPCAST_BYTES:
        raise AppcastValidationError("release appcast has an invalid byte size")
    if dmg_stat.st_size <= 0:
        raise AppcastValidationError("release DMG is empty")

    try:
        root = ET.fromstring(appcast.read_bytes())
    except (ET.ParseError, OSError) as error:
        raise AppcastValidationError("release appcast is not valid XML") from error

    namespace = {"sparkle": SPARKLE_NAMESPACE}
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise AppcastValidationError("release appcast must contain exactly one item")

    item = items[0]
    actual_version = item.findtext("sparkle:shortVersionString", namespaces=namespace)
    actual_build = item.findtext("sparkle:version", namespaces=namespace)
    if actual_version != version or actual_build != build:
        raise AppcastValidationError(
            "release appcast version/build does not match the requested release"
        )

    enclosures = item.findall("enclosure")
    if len(enclosures) != 1:
        raise AppcastValidationError(
            "release appcast item must contain exactly one enclosure"
        )
    enclosure = enclosures[0]
    expected_url = (
        "https://github.com/johnny4young/portavoz/releases/latest/download/"
        f"{dmg.name}"
    )
    if enclosure.get("url") != expected_url:
        raise AppcastValidationError(
            "release appcast enclosure URL does not match the requested DMG"
        )
    if enclosure.get("length") != str(dmg_stat.st_size):
        raise AppcastValidationError(
            "release appcast enclosure length does not match the requested DMG"
        )

    signature = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature")
    if not signature:
        raise AppcastValidationError("release appcast enclosure is not signed")
    try:
        decoded_signature = base64.b64decode(signature, validate=True)
    except (binascii.Error, ValueError) as error:
        raise AppcastValidationError(
            "release appcast enclosure has a malformed EdDSA signature"
        ) from error
    if len(decoded_signature) != 64:
        raise AppcastValidationError(
            "release appcast enclosure has a malformed EdDSA signature"
        )


def parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--appcast", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--dmg", required=True, type=Path)
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    options = parse_args(sys.argv[1:] if arguments is None else arguments)
    try:
        validate_appcast(
            options.appcast,
            options.version,
            options.build,
            options.dmg,
        )
    except AppcastValidationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 64
    print(
        f"Verified signed release appcast for {options.version} "
        f"({options.build})."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
