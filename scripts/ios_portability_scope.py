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
    "scripts/verify-ci-toolchain.sh",
    ".github/workflows/ci.yml",
})
DECLARATION = re.compile(r"\.(?:target|executableTarget|testTarget|binaryTarget|macro|plugin)\(")
PRODUCT = re.compile(r"\.product\(\s*name:\s*\"[^\"]+\"\s*,\s*package:\s*\"[^\"]+\"\s*\)")
LITERAL = re.compile(r"\"([^\"\\]+)\"")


def roots(root: Path) -> list[str]:
    match = re.search(r"^targets=\(([^)]*)\)$", (root / RUNNER).read_text(), re.MULTILINE)
    if not match:
        raise ValueError(f"{RUNNER} does not declare its targets")
    return match.group(1).split()


def without_comments(source: str) -> str:
    result, quoted, index = [], False, 0
    while index < len(source):
        character = source[index]
        if quoted:
            result.append(character)
            if character == "\\":
                result.append(source[index + 1])
                index += 1
            elif character == "\"":
                quoted = False
        elif source.startswith("//", index):
            index = source.find("\n", index)
            if index < 0:
                break
            continue
        else:
            quoted = character == "\""
            result.append(character)
        index += 1
    return "".join(result)


def items(source: str) -> list[str]:
    """Split a bracketed or parenthesized list at its own top-level commas."""
    closing = {"(": ")", "[": "]"}
    depth, quoted, start, parts = [], False, 1, []
    for index, character in enumerate(source):
        if quoted:
            quoted = character != "\""
        elif character == "\"":
            quoted = True
        elif character in closing:
            depth.append(closing[character])
        elif character in ")]":
            if not depth or depth.pop() != character:
                raise ValueError("Package.swift has unbalanced brackets")
            if not depth:
                parts.append(source[start:index])
                if source[index + 1:].strip():
                    raise ValueError("Package.swift list has trailing content")
                return [part.strip() for part in parts if part.strip()]
        elif character == "," and len(depth) == 1:
            parts.append(source[start:index])
            start = index + 1
    raise ValueError("Package.swift has unbalanced brackets")


def balanced(source: str, start: int) -> str:
    closing = {"(": ")", "[": "]"}
    depth, quoted = [], False
    for index in range(start, len(source)):
        character = source[index]
        if quoted:
            quoted = character != "\""
        elif character == "\"":
            quoted = True
        elif character in closing:
            depth.append(closing[character])
        elif character in ")]":
            if not depth or depth.pop() != character:
                raise ValueError("Package.swift has unbalanced brackets")
            if not depth:
                return source[start:index + 1]
    raise ValueError("Package.swift has unbalanced brackets")


def targets(root: Path) -> dict[str, tuple[list[str], str]]:
    """Read target edges from the manifest, failing on any form it cannot prove."""
    manifest = without_comments((root / "Package.swift").read_text())
    package = re.search(r"\bPackage\(", manifest)
    if not package:
        raise ValueError("Package.swift declares no Package")
    declared = [value for label, value in (argument.partition(":")[::2]
                for argument in items(balanced(manifest, package.end() - 1))) if label.strip() == "targets"]
    if len(declared) != 1:
        raise ValueError("Package.swift must declare one literal target list")
    result = {}
    for declaration in items(declared[0].strip()):
        call = DECLARATION.match(declaration)
        if not call:
            raise ValueError(f"Unsupported Package.swift target form: {declaration[:40]}")
        arguments = {}
        for argument in items(declaration[call.end() - 1:]):
            label, _, value = argument.partition(":")
            arguments[label.strip()] = value.strip()
        name = LITERAL.fullmatch(arguments.get("name", ""))
        if not name:
            raise ValueError("A Package.swift target has no literal name")
        dependencies = []
        for dependency in items(arguments["dependencies"]) if "dependencies" in arguments else []:
            if literal := LITERAL.fullmatch(dependency):
                dependencies.append(literal.group(1))
            elif not PRODUCT.fullmatch(dependency):
                # A conditional or .target/.byName edge could hide a local target.
                raise ValueError(f"Unsupported dependency form in {name.group(1)}: {dependency[:40]}")
        path = LITERAL.fullmatch(arguments.get("path", "")) if "path" in arguments else None
        result[name.group(1)] = (dependencies, path.group(1) if path else f"Sources/{name.group(1)}")
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
    output = subprocess.check_output(["git", "diff", "--name-only", "--no-renames", "-z", f"{base}...{head}"],
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
