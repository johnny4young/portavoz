#!/usr/bin/env python3
"""Identify compatible CI SwiftPM build state; never identify passing tests."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
LANES = ("build-and-test",)
# Compiled state depends on these, not on how a workflow is written. Tooling tests
# tie the flags to the workflows; bump the version when what a seed holds changes.
BUILD_CONTRACT = {
    "version": 2,
    "flags": ("--disable-default-traits", "--only-use-versions-from-resolved-file", "-Xswiftc", "-warnings-as-errors"),
}
# A moved dependency restores within the same toolchain and recompiles what moved.
GRAPH_INPUTS = ("Package.swift", "Package.resolved")
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


def cache_prefix(root: Path, lane: str) -> str:
    if lane not in LANES:
        raise ValueError("Unknown Swift test lane")
    developer = os.environ.get("DEVELOPER_DIR", "")
    if not developer or not Path(developer).is_dir():
        raise ValueError("DEVELOPER_DIR must identify an installed Xcode")
    identity = {
        "schema": 2,
        "coldProbe": "20261111",
        "lane": lane,
        "contract": BUILD_CONTRACT,
        # SwiftPM and module caches contain absolute paths. Do not transplant
        # them across workspaces, architectures, SDKs or runner image revisions.
        "workspace": str(root.resolve()),
        "developer": str(Path(developer).resolve()),
        "architecture": platform.machine(),
        "runnerImage": os.environ.get("ImageOS", ""),
        "runnerImageVersion": os.environ.get("ImageVersion", ""),
        "tools": [command_output(command) for command in COMMANDS],
    }
    digest = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    return f"swift-build-v3-{lane}-{digest}-"


def graph_digest(root: Path) -> str:
    graph = hashlib.sha256()
    for name in GRAPH_INPUTS:
        graph.update(name.encode() + b"\0" + (root / name).read_bytes() + b"\0")
    return graph.hexdigest()[:16]


def graph_prefix(root: Path, lane: str) -> str:
    return f"{cache_prefix(root, lane)}{graph_digest(root)}-"


def checked_commit(commit: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("The cache commit must be a full lowercase SHA-1")
    return commit


def cache_key(root: Path, lane: str, commit: str) -> str:
    # One seed per main commit keeps first-party state current. A restore prefers
    # the newest seed of its graph, then any seed of its toolchain and flags.
    return graph_prefix(root, lane) + checked_commit(commit)


def clean_cache_key(root: Path, lane: str, commit: str) -> str:
    # Seeds are immutable, so the clean seed cannot replace the same commit's main seed.
    return f"{graph_prefix(root, lane)}clean-{checked_commit(commit)}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lane", choices=LANES, required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    try:
        # The tool commands behind the prefix take seconds on a hosted runner.
        prefix = cache_prefix(ROOT, args.lane)
        graph = f"{prefix}{graph_digest(ROOT)}-"
        commit = checked_commit(args.commit)
        print(f"prefix={prefix}\ngraph_prefix={graph}\nkey={graph}{commit}\nclean_key={graph}clean-{commit}")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Cannot identify Swift build cache: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
