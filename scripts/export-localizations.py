#!/usr/bin/env python3
"""Export Portavoz String Catalogs to runtime .lproj/*.strings files.

The shipping app bundle is still produced by scripts/make-app.sh rather than
Xcode. This bridge keeps the modern source-of-truth catalogs while producing
classic runtime resources that Bundle/SwiftUI can load from dist/Portavoz.app.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

CATALOG_DIR = Path("Resources/Localization/Portavoz")
CATALOGS = {
    "Localizable": CATALOG_DIR / "Localizable.xcstrings",
    "InfoPlist": CATALOG_DIR / "InfoPlist.xcstrings",
}
LOCALES = ("en", "es")
INFO_PLIST_KEYS_BY_SOURCE = {
    "MIT License": ["NSHumanReadableCopyright"],
    "Portavoz": ["CFBundleName", "CFBundleDisplayName"],
    "Portavoz can use the macOS speech engine as an on-device transcription fallback.": [
        "NSSpeechRecognitionUsageDescription",
    ],
    "Portavoz captures system audio to transcribe other meeting participants. Audio never leaves your Mac.": [
        "NSAudioCaptureUsageDescription",
    ],
    "Portavoz reads calendar attendees only to suggest meeting speaker names. Nothing leaves your Mac.": [
        "NSCalendarsFullAccessUsageDescription",
    ],
    "Portavoz records your microphone to transcribe your side of the meeting. Audio never leaves your Mac.": [
        "NSMicrophoneUsageDescription",
    ],
    "Portavoz stores meeting audio in the folder you choose, including external drives.": [
        "NSRemovableVolumesUsageDescription",
    ],
    "Portavoz stores meeting audio in the folder you choose.": [
        "NSDesktopFolderUsageDescription",
        "NSDocumentsFolderUsageDescription",
        "NSDownloadsFolderUsageDescription",
    ],
}


def escape_strings_value(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )


def localized_value(entry: dict, locale: str, key: str) -> str:
    if locale == "en":
        unit = (
            entry.get("localizations", {})
            .get("en", {})
            .get("stringUnit", {})
            .get("value")
        )
        return unit or key
    unit = (
        entry.get("localizations", {})
        .get(locale, {})
        .get("stringUnit", {})
        .get("value")
    )
    return unit or key


def write_table(table: str, catalog_path: Path, destination: Path) -> None:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    strings = catalog.get("strings", {})
    if table == "InfoPlist":
        missing = sorted(set(INFO_PLIST_KEYS_BY_SOURCE) - set(strings))
        if missing:
            raise KeyError(
                "InfoPlist catalog missing mapped source string(s): " + ", ".join(missing)
            )
    for locale in LOCALES:
        lproj = destination / f"{locale}.lproj"
        lproj.mkdir(parents=True, exist_ok=True)
        out = lproj / f"{table}.strings"
        lines = [f"/* Generated from {catalog_path.as_posix()}. Do not edit. */\n"]
        items = []
        for key in sorted(strings):
            value = localized_value(strings[key], locale, key)
            if table == "InfoPlist":
                for plist_key in INFO_PLIST_KEYS_BY_SOURCE.get(key, []):
                    items.append((plist_key, value))
            else:
                items.append((key, value))
        for key, value in sorted(items):
            lines.append(
                f'"{escape_strings_value(key)}" = "{escape_strings_value(value)}";\n'
            )
        out.write_text("".join(lines), encoding="utf-8")


def main() -> int:
    destination = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("dist/Portavoz.app/Contents/Resources")
    missing = [str(path) for path in CATALOGS.values() if not path.exists()]
    if missing:
        print("missing localization catalog(s): " + ", ".join(missing), file=sys.stderr)
        return 66
    for table, catalog_path in CATALOGS.items():
        write_table(table, catalog_path, destination)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
