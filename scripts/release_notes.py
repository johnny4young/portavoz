#!/usr/bin/env python3
"""Render one release's section of CHANGELOG.md as the HTML fragment Sparkle embeds."""

from __future__ import annotations

import argparse
import html
from pathlib import Path
import re
import sys


class ReleaseNotesError(Exception):
    pass


def section(changelog: str, version: str) -> list[str]:
    """The lines under `## <version> — <date>`, up to the next heading of that level."""
    heading = re.compile(rf"^## {re.escape(version)} — \S")
    lines = changelog.splitlines()
    start = next((index for index, line in enumerate(lines) if heading.match(line)), None)
    if start is None:
        raise ReleaseNotesError(f"CHANGELOG.md has no section for {version}")
    body: list[str] = []
    for line in lines[start + 1:]:
        if line.startswith("## "):
            break
        body.append(line)
    return body


def inline(text: str) -> str:
    escaped = html.escape(text, quote=False)
    escaped = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", escaped)
    return re.sub(r"`(.+?)`", r"<code>\1</code>", escaped)


def render(changelog: str, version: str) -> str:
    output: list[str] = []
    in_list = False
    for line in section(changelog, version):
        stripped = line.strip()
        if stripped.startswith("- "):
            if not in_list:
                output.append("<ul>")
                in_list = True
            output.append(f"<li>{inline(stripped[2:])}</li>")
            continue
        if in_list:
            output.append("</ul>")
            in_list = False
        if stripped:
            output.append(f"<p>{inline(stripped)}</p>")
    if in_list:
        output.append("</ul>")
    if not output:
        raise ReleaseNotesError(f"CHANGELOG.md has an empty section for {version}")
    return "\n".join(output) + "\n"


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--changelog", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", required=True, type=Path)
    options = parser.parse_args(arguments)
    try:
        notes = render(options.changelog.read_text(encoding="utf-8"), options.version)
    except (OSError, ReleaseNotesError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 64
    options.output.write_text(notes, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
