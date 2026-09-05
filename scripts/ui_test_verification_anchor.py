#!/usr/bin/env python3
"""Create one content-free exact-head XCUITest verification anchor."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Sequence


SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
SELECTOR_PATTERN = re.compile(r"^PortavozUITests/[A-Za-z0-9_]+UITests/test[A-Za-z0-9_]+$")
SUPPORTED_LOCALES = frozenset({"en", "es"})


class AnchorError(ValueError):
    """The workflow attempted to create an invalid verification anchor."""


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--commit", required=True)
    value.add_argument("--required", choices=("true", "false"), required=True)
    value.add_argument("--tests", default="")
    value.add_argument("--locales", default="")
    value.add_argument("--output", type=Path, required=True)
    return value


def write_new(path: Path, payload: bytes) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        dir=path.parent,
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        if path.exists():
            raise AnchorError("verification anchor already exists")
        os.link(temporary, path)
        os.chmod(path, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        if SHA_PATTERN.fullmatch(arguments.commit) is None:
            raise AnchorError("commit must be a full lowercase SHA")
        required = arguments.required == "true"
        tests = tuple(arguments.tests.split())
        locales = tuple(arguments.locales.split())
        if len(set(tests)) != len(tests) or any(
            SELECTOR_PATTERN.fullmatch(test) is None for test in tests
        ):
            raise AnchorError("test selectors are invalid or duplicated")
        if (
            len(set(locales)) != len(locales)
            or any(locale not in SUPPORTED_LOCALES for locale in locales)
        ):
            raise AnchorError("locales are invalid or duplicated")
        if required != bool(tests) or required != bool(locales):
            raise AnchorError("required, selectors, and locales disagree")
        selector_material = "\n".join(tests).encode("utf-8")
        document = {
            "commit": arguments.commit,
            "kind": "ui-functional-verification",
            "locales": list(locales),
            "schemaVersion": 1,
            "selectorCount": len(tests),
            "selectorSHA256": hashlib.sha256(selector_material).hexdigest(),
        }
        payload = json.dumps(
            document,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8") + b"\n"
        write_new(arguments.output, payload)
    except AnchorError as error:
        print(f"UI verification anchor failed: {error}", file=sys.stderr)
        return 2
    print(
        f"Created content-free UI verification anchor for {arguments.commit} "
        f"({len(tests)} selectors)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
