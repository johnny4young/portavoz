#!/usr/bin/env python3
"""Shared fail-closed publication primitives for private research baselines."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Callable


COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
CommandRunner = Callable[[list[str], Path], subprocess.CompletedProcess[str]]


class BaselineError(ValueError):
    """The requested baseline operation violated its closed contract."""


class BaselineNotAdmissible(BaselineError):
    """The evidence is valid but cannot become a retained research baseline."""


def run_command(command: list[str], root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
    )


def read_bounded_bytes(path: Path, label: str, maximum_bytes: int) -> bytes:
    try:
        if not path.is_file():
            raise BaselineError(f"{label} was not found")
        with path.open("rb") as handle:
            data = handle.read(maximum_bytes + 1)
    except OSError as error:
        raise BaselineError(f"cannot read {label}") from error
    if len(data) > maximum_bytes:
        raise BaselineError(f"{label} exceeds its size limit")
    return data


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def validate_sha256(value: str, label: str) -> str:
    if not isinstance(value, str) or SHA256.fullmatch(value) is None:
        raise BaselineError(f"{label} must be one lowercase SHA-256 digest")
    return value


def validate_commit(value: str, label: str) -> str:
    if not isinstance(value, str) or COMMIT.fullmatch(value) is None:
        raise BaselineError(f"{label} must be one full lowercase commit SHA")
    return value


def require_source_checkout(
    root: Path,
    expected_commit: str,
    runner: CommandRunner = run_command,
) -> None:
    expected_commit = validate_commit(expected_commit, "accepted source commit")
    status = runner(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        root,
    )
    if status.returncode != 0:
        raise BaselineError("source worktree could not be inspected")
    if status.stdout.strip():
        raise BaselineError("source worktree must be clean for baseline retention")
    head = runner(["git", "rev-parse", "HEAD"], root)
    if head.returncode != 0:
        raise BaselineError("source commit could not be inspected")
    actual = head.stdout.strip()
    if COMMIT.fullmatch(actual) is None or actual != expected_commit:
        raise BaselineError("source checkout does not match the accepted commit")


def is_within(path: Path, directory: Path) -> bool:
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def validate_output_destination(
    output: Path,
    inputs: tuple[Path, ...],
    root: Path,
    runner: CommandRunner = run_command,
) -> Path:
    output = output.expanduser().resolve()
    if output in {path.expanduser().resolve() for path in inputs}:
        raise BaselineError("baseline output must not replace its evidence inputs")
    if output.exists():
        raise BaselineError("baseline output already exists")
    root = root.resolve()
    if is_within(output, root):
        ignored = runner(
            ["git", "check-ignore", "--quiet", str(output)],
            root,
        )
        if ignored.returncode != 0:
            raise BaselineError("repository-local baseline output must be ignored")
    return output


def write_owner_only(
    path: Path,
    document: dict[str, Any],
    maximum_bytes: int,
) -> None:
    missing_directories = []
    cursor = path.parent
    while not cursor.exists():
        missing_directories.append(cursor)
        cursor = cursor.parent
    try:
        if not cursor.is_dir():
            raise BaselineError("baseline directory parent is not a directory")
        for directory in reversed(missing_directories):
            directory.mkdir(mode=0o700)
            os.chmod(directory, 0o700)
        if not path.parent.is_dir():
            raise BaselineError("baseline directory parent is not a directory")
    except BaselineError:
        raise
    except OSError as error:
        raise BaselineError("baseline directory could not be prepared") from error
    data = (
        json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    if len(data) > maximum_bytes:
        raise BaselineError("baseline exceeds its publication size limit")
    descriptor = None
    temporary = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
        )
        temporary = Path(temporary_name)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = None
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.link(temporary, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except FileExistsError as error:
        raise BaselineError("baseline output already exists") from error
    except OSError as error:
        raise BaselineError("baseline could not be published") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def withdraw_output(path: Path) -> None:
    try:
        path.unlink(missing_ok=True)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except OSError as error:
        raise BaselineError(
            "source changed after publication and baseline withdrawal failed"
        ) from error
