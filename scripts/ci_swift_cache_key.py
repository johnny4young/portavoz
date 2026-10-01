#!/usr/bin/env python3
"""Identify compatible CI SwiftPM build state; never identify passing tests."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess


ROOT = Path(__file__).resolve().parents[1]
LANES = ("build-and-test", "sequoia-compatibility")
# These owners define the dependency graph, compiler arguments and cache policy.
INPUTS = (
    "Package.swift",
    "Package.resolved",
    ".github/workflows/ci.yml",
    "scripts/run-swift-tests.sh",
    "scripts/verify-ci-toolchain.sh",
    "scripts/ci_swift_cache_key.py",
    "scripts/ci_swift_source_stamps.py",
)
COMMANDS = (
    ("sw_vers", "-productVersion"),
    ("sw_vers", "-buildVersion"),
    ("xcodebuild", "-version"),
    ("xcrun", "swift", "--version"),
    ("xcrun", "--sdk", "macosx", "--show-sdk-path"),
    ("xcrun", "--sdk", "macosx", "--show-sdk-build-version"),
)


def command_output(command: tuple[str, ...]) -> str:
    result = subprocess.run(command, check=True, text=True, capture_output=True, timeout=30)
    value = result.stdout.strip()
    if not value:
        raise ValueError(f"Empty cache identity from {command[0]}")
    return value


def cache_key(root: Path, lane: str) -> str:
    if lane not in LANES:
        raise ValueError("Unknown Swift test lane")
    developer = os.environ.get("DEVELOPER_DIR", "")
    if not developer or not Path(developer).is_dir():
        raise ValueError("DEVELOPER_DIR must identify an installed Xcode")
    identity = {
        "schema": 1,
        "lane": lane,
        # SwiftPM and module caches contain absolute paths. Do not transplant
        # them across workspaces, architectures, SDKs or runner image revisions.
        "workspace": str(root.resolve()),
        "developer": str(Path(developer).resolve()),
        "architecture": platform.machine(),
        "runnerImage": os.environ.get("ImageOS", ""),
        "runnerImageVersion": os.environ.get("ImageVersion", ""),
        "tools": [command_output(command) for command in COMMANDS],
        "inputs": {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                   for name in INPUTS},
    }
    digest = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    # No broad restore prefix and no SHA suffix: one immutable seed per
    # compatible graph instead of one multi-GB cache per push. Source freshness
    # is restored separately, only after checking bytes and mode.
    return f"swift-build-v1-{lane}-{digest}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lane", choices=LANES, required=True)
    args = parser.parse_args()
    try:
        print(f"key={cache_key(ROOT, args.lane)}")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Cannot identify Swift build cache: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
