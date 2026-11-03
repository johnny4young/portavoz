#!/usr/bin/env python3
"""Copy a UI run's `pr-*` screenshots out of its result bundle for the PR artifact.

Evidence only: a run with no bundle or no such screenshot still succeeds, so this
step can never change a lane's outcome.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Sequence

PREFIX = "pr-"
MAX_SCREENSHOTS = 6
NAME = re.compile(r"pr-[a-z0-9-]+")


def selected_attachments(manifest: Sequence[dict[str, Any]]) -> dict[str, str]:
    """Exported file by screenshot name; only well-formed `pr-*` PNGs, at most the limit."""
    found: dict[str, str] = {}
    for test in manifest:
        for attachment in test.get("attachments", []):
            suggested = attachment.get("suggestedHumanReadableName", "")
            exported = attachment.get("exportedFileName", "")
            name = suggested.split("_", 1)[0]
            if NAME.fullmatch(name) and exported.endswith(".png"):
                found.setdefault(name, exported)
    return dict(sorted(found.items())[:MAX_SCREENSHOTS])


def export(result: Path, output: Path) -> int:
    if not result.is_dir():
        print(f"No result bundle at {result}.")
        return 0
    with tempfile.TemporaryDirectory() as scratch:
        directory = Path(scratch)
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                        "--output-path", str(directory)], check=True, capture_output=True, timeout=300)
        manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
        selected = selected_attachments(manifest)
        output.mkdir(parents=True, exist_ok=True)
        for name, exported in selected.items():
            shutil.copyfile(directory / exported, output / f"{name}.png")
    print(f"Recorded {len(selected)} PR screenshots.")
    return len(selected)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args(argv)
    try:
        export(arguments.result, arguments.output)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"::warning title=PR screenshots::{error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
