#!/usr/bin/env python3
"""Select the Swift test classes a pull request can affect.

A diff confined to documentation, the website, CI configuration or tooling cannot
change compiled code, but Swift tests that read repository files can still fail on it.
Such a diff runs only the classes whose sources read the checkout; any other
diff, or anything this policy cannot read, runs the complete suite.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TESTS = ("Tests/PortavozKitTests", "Tests/PortavozAppTests")
CONTRACT_ONLY_PREFIXES = ("docs/", "site/", "Tests/Tooling/", ".github/", "scripts/")
CONTRACT_ONLY_FILES = frozenset({"LICENSE", "Makefile"})
# These decide how the Swift suite builds or runs, so changing one needs the whole suite.
RUNS_THE_SUITE = frozenset({
    ".github/workflows/ci.yml",
    "scripts/apuntador_web_fixture.py",
    "scripts/ci_swift_cache_key.py",
    "scripts/ci_swift_source_stamps.py",
    "scripts/run-swift-tests.sh",
    "scripts/run_xctest_pool.py",
    "scripts/swift_test_scope.py",
    "scripts/verify-ci-toolchain.sh",
    "scripts/xctest_class_seconds.json",
    "scripts/xctest_nightly_only.txt",
})
# A source that locates the checkout can read any tracked file.
READS_CHECKOUT = re.compile(r"#filePath|\brepoRoot\b|\brepositoryRoot\b")
DECLARATION = re.compile(r"^\s*(?:@\w+\s+)*(?:final\s+)?(?:class|struct|extension)\s+(\w+)\b", re.MULTILINE)
MODULE = "Portavoz(Kit|App)Tests"


def contract_only(path: str) -> bool:
    if path in RUNS_THE_SUITE:
        return False
    if path in CONTRACT_ONLY_FILES or path.startswith(CONTRACT_ONLY_PREFIXES):
        return True
    return "/" not in path and path.endswith(".md")


def reading_classes(root: Path) -> list[str]:
    names: set[str] = set()
    for source in sorted(source for tests in TESTS for source in (root / tests).rglob("*.swift")):
        text = source.read_text(encoding="utf-8")
        if READS_CHECKOUT.search(text):
            names.update(name for name in DECLARATION.findall(text) if name.endswith("Tests"))
    if not names:
        raise ValueError("No Swift test reads the checkout; the scan is broken")
    return sorted(names)


def selection(root: Path, changed: list[str]) -> str:
    """An anchored class filter, or an empty string for the complete suite."""
    if not changed or not all(contract_only(path) for path in changed):
        return ""
    alternatives = "|".join(re.escape(name) for name in reading_classes(root))
    return f"^{MODULE}\\.({alternatives})/"


def changed_files(root: Path, base: str, head: str) -> list[str]:
    output = subprocess.check_output(["git", "diff", "--name-only", "--no-renames", "-z", f"{base}...{head}"],
                                     cwd=root, timeout=60)
    return [name.decode() for name in output.split(b"\0") if name]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    arguments = parser.parse_args(argv)
    try:
        selected = selection(ROOT, changed_files(ROOT, arguments.base, arguments.head))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Swift test scope failed closed: {error}", file=sys.stderr)
        selected = ""
    print(f"filter={selected}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
