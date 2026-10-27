#!/usr/bin/env python3
"""Decide whether a change can affect the iOS portability compile."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
RUNNER = "scripts/check-ios-portability.sh"
# Policy owners: a change here can alter what the lane compiles or how.
ALWAYS = frozenset({
    "Package.swift",
    "Package.resolved",
    RUNNER,
    "scripts/ios_portability_scope.py",
    ".github/workflows/ci.yml",
})
DECLARATION = re.compile(r"\.(?:target|executableTarget|testTarget)\(")


def roots(root: Path) -> list[str]:
    match = re.search(r"^targets=\(([^)]*)\)$", (root / RUNNER).read_text(), re.MULTILINE)
    if not match:
        raise ValueError(f"{RUNNER} does not declare its targets")
    return match.group(1).split()


def targets(root: Path) -> dict[str, tuple[list[str], str]]:
    manifest = (root / "Package.swift").read_text()
    result = {}
    for chunk in DECLARATION.split(manifest)[1:]:
        name = re.match(r"\s*name:\s*\"([^\"]+)\"", chunk)
        if not name:
            raise ValueError("A Package.swift target has no leading literal name")
        # Product dependencies are external; their changes reach Package.resolved.
        local = re.sub(r"\.product\([^)]*\)", "", chunk)
        dependencies = re.search(r"dependencies:\s*\[(.*?)\]", local, re.DOTALL)
        path = re.search(r"path:\s*\"([^\"]+)\"", chunk)
        result[name.group(1)] = (re.findall(r"\"([^\"]+)\"", dependencies.group(1)) if dependencies else [],
                                 path.group(1) if path else f"Sources/{name.group(1)}")
    return result


def closure(root: Path) -> list[str]:
    graph = targets(root)
    pending, seen = list(roots(root)), set()
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        if name not in graph:
            raise ValueError(f"Package.swift does not declare target {name}")
        seen.add(name)
        pending.extend(graph[name][0])
    return sorted(graph[name][1] for name in seen)


def required(root: Path, changed: list[str]) -> bool:
    directories = tuple(path.rstrip("/") + "/" for path in closure(root))
    return any(path in ALWAYS or path.startswith(directories) for path in changed)


def changed_files(root: Path, base: str, head: str) -> list[str]:
    output = subprocess.check_output(["git", "diff", "--name-only", "-z", f"{base}...{head}"],
                                     cwd=root, timeout=60)
    return [name.decode() for name in output.split(b"\0") if name]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    args = parser.parse_args()
    try:
        needed = required(ROOT, changed_files(ROOT, args.base, args.head))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # An unreadable diff or manifest never skips the lane.
        print(f"iOS portability scope failed closed: {error}", file=sys.stderr)
        needed = True
    print(f"required={'true' if needed else 'false'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
