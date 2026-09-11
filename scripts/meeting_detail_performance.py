#!/usr/bin/env python3
"""Build a deterministic Meeting Detail UI performance evidence document."""

from __future__ import annotations

import argparse
import datetime
import json
import math
import pathlib
import platform
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from typing import Any


PROFILES = (
    ("five-thousand", 5_000, "Meeting Detail Playback Seek"),
    ("twenty-thousand", 20_000, "Meeting Detail Transcript Scroll"),
)
APPLICATION_KINDS = (
    "installed-dev-bundle",
    "development-bundle-override",
)


class EvidenceError(ValueError):
    """The captured Instruments evidence is incomplete or malformed."""


@dataclass(frozen=True)
class XMLTable:
    root: ET.Element
    ids: dict[str, ET.Element]

    @classmethod
    def read(cls, path: pathlib.Path) -> "XMLTable":
        try:
            root = ET.parse(path).getroot()
        except (OSError, ET.ParseError) as error:
            raise EvidenceError(f"cannot read trace export: {path}") from error
        return cls(
            root=root,
            ids={
                element_id: element
                for element in root.iter()
                if (element_id := element.attrib.get("id")) is not None
            },
        )

    @property
    def rows(self) -> list[ET.Element]:
        return self.root.findall(".//row")

    def element(self, row: ET.Element, tag: str) -> ET.Element:
        element = row.find(tag)
        if element is None:
            raise EvidenceError(f"trace row is missing {tag}")
        seen: set[str] = set()
        while (reference := element.attrib.get("ref")) is not None:
            if reference in seen or reference not in self.ids:
                raise EvidenceError(f"trace row has invalid {tag} reference")
            seen.add(reference)
            element = self.ids[reference]
        return element

    def text(self, row: ET.Element, tag: str) -> str:
        value = "".join(self.element(row, tag).itertext()).strip()
        if not value:
            raise EvidenceError(f"trace row has empty {tag}")
        return value

    def nanoseconds(self, row: ET.Element, tag: str) -> int:
        raw = self.text(row, tag)
        try:
            value = int(raw)
        except ValueError as error:
            raise EvidenceError(f"trace row has invalid {tag}: {raw}") from error
        if value < 0:
            raise EvidenceError(f"trace row has negative {tag}")
        return value


def percentile(samples: list[float], fraction: float) -> float:
    if not samples:
        raise EvidenceError("cannot calculate a percentile without samples")
    ordered = sorted(samples)
    index = max(0, math.ceil(len(ordered) * fraction) - 1)
    return ordered[index]


def interval_rows(table: XMLTable, name: str) -> list[ET.Element]:
    matches = []
    for row in table.rows:
        for tag in ("string", "name"):
            try:
                observed_name = table.text(row, tag)
            except EvidenceError:
                continue
            if observed_name == name:
                matches.append(row)
                break
    return matches


def interval_measurement(
    table: XMLTable,
    name: str,
    minimum_samples: int,
    maximum_samples: int | None = None,
) -> dict[str, Any]:
    rows = interval_rows(table, name)
    samples = [table.nanoseconds(row, "duration") / 1_000_000 for row in rows]
    if len(samples) < minimum_samples or any(sample <= 0 for sample in samples):
        raise EvidenceError(
            f"{name} needs at least {minimum_samples} positive samples; got {len(samples)}"
        )
    if maximum_samples is not None and len(samples) > maximum_samples:
        raise EvidenceError(
            f"{name} permits at most {maximum_samples} samples; got {len(samples)}"
        )
    return {
        "name": name,
        "sampleCount": len(samples),
        "p50Milliseconds": percentile(samples, 0.50),
        "p95Milliseconds": percentile(samples, 0.95),
        "maximumMilliseconds": max(samples),
        "samplesMilliseconds": samples,
    }


def app_rows(table: XMLTable) -> list[ET.Element]:
    accepted = []
    for row in table.rows:
        try:
            process = table.text(row, "process").lower()
        except EvidenceError:
            process = ""
        if "portavoz" in process:
            accepted.append(row)
    return accepted


def event_measurement(table: XMLTable, duration_tag: str) -> dict[str, Any]:
    samples = [
        table.nanoseconds(row, duration_tag) / 1_000_000
        for row in app_rows(table)
    ]
    return {
        "count": len(samples),
        "maximumMilliseconds": max(samples, default=0),
        "samplesMilliseconds": samples,
    }


def profile_document(root: pathlib.Path, slug: str, segment_count: int, interaction: str) -> dict[str, Any]:
    signposts = XMLTable.read(root / f"{slug}-os-signpost-interval.xml")
    first_content = interval_measurement(
        signposts,
        "Meeting Detail First Content",
        minimum_samples=1,
    )
    measured_interaction = interval_measurement(
        signposts,
        interaction,
        minimum_samples=5,
        maximum_samples=5,
    )
    swiftui = XMLTable.read(root / f"{slug}-swiftui-updates.xml")
    hitches = event_measurement(
        XMLTable.read(root / f"{slug}-hitches.xml"),
        "duration",
    )
    hangs = event_measurement(
        XMLTable.read(root / f"{slug}-potential-hangs.xml"),
        "duration",
    )
    profiler_path = root / f"{slug}-time-profile.xml"
    try:
        profiler = profiler_path.read_text(encoding="utf-8")
    except OSError as error:
        raise EvidenceError(f"cannot read trace export: {profiler_path}") from error
    swiftui_log_path = root / f"{slug}-swiftui.log"
    try:
        swiftui_log = swiftui_log_path.read_text(encoding="utf-8")
    except OSError as error:
        raise EvidenceError(f"cannot read trace log: {swiftui_log_path}") from error
    swiftui_rows = swiftui.rows
    swiftui_status = "captured" if swiftui_rows else "unavailable-toolchain"

    return {
        "name": slug,
        "fixture": {
            "durationMinutes": 120,
            "segmentCount": segment_count,
            "speakerCount": 4,
            "storage": "disposable-temp-store",
            "audio": "synthetic-six-second-two-channel"
            if interaction == "Meeting Detail Playback Seek"
            else "none",
            "summaryMutation": {
                "afterSeconds": 3,
                "capturedBy": ["SwiftUI", "Animation Hitches"],
                "excludedFromInteractionTrace": True,
            },
        },
        "firstContent": first_content,
        "bodyInvalidations": {
            "status": swiftui_status,
            "updateRowCount": len(swiftui_rows),
            "xctraceWarningPresent": "Trace file had no SwiftUI data" in swiftui_log,
        },
        "interaction": measured_interaction,
        "animationHitches": hitches,
        "responsiveness": {
            "potentialHangThresholdMilliseconds": 250,
            "potentialHangCount": hangs["count"],
            "maximumPotentialHangMilliseconds": hangs["maximumMilliseconds"],
            "potentialHangsMilliseconds": hangs["samplesMilliseconds"],
        },
        "timeProfiler": {
            "meetingDetailViewSymbolsPresent": "MeetingDetailView.body.getter" in profiler,
            "transcriptSegmentsViewSymbolsPresent": "TranscriptSegmentsView" in profiler,
        },
    }


def build_document(
    root: pathlib.Path,
    trace_duration_seconds: int,
    application_kind: str = "installed-dev-bundle",
) -> dict[str, Any]:
    if application_kind not in APPLICATION_KINDS:
        raise EvidenceError(f"unsupported application kind: {application_kind}")
    profiles = [
        profile_document(root, slug, segment_count, interaction)
        for slug, segment_count, interaction in PROFILES
    ]
    try:
        xcode_lines = (root / "xcode-version.txt").read_text(encoding="utf-8").splitlines()
        xctrace = (root / "xctrace-version.txt").read_text(encoding="utf-8").strip()
        operating_system_lines = (root / "sw-vers.txt").read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise EvidenceError("cannot read host/toolchain metadata") from error
    if len(xcode_lines) < 2:
        raise EvidenceError("xcode-version.txt is incomplete")
    operating_system = dict(
        line.split(":", 1) for line in operating_system_lines if ":" in line
    )
    try:
        version = operating_system["ProductVersion"].strip()
        build = operating_system["BuildVersion"].strip()
    except KeyError as error:
        raise EvidenceError("sw-vers.txt is incomplete") from error

    unavailable = [
        profile["fixture"]["segmentCount"]
        for profile in profiles
        if profile["bodyInvalidations"]["status"] == "unavailable-toolchain"
    ]
    limitations = []
    if unavailable:
        limitations.append(
            "Xcode emitted no SwiftUI update rows for segment counts "
            + ", ".join(str(value) for value in unavailable)
            + "; the baseline records tool unavailability and does not represent body "
            "invalidations as zero."
        )
    return {
        "schemaVersion": 2,
        "generatedAt": datetime.datetime.now(datetime.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
        "host": {
            "operatingSystem": version,
            "operatingSystemBuild": build,
            "architecture": platform.machine(),
        },
        "toolchain": {
            "xcode": xcode_lines[0],
            "xcodeBuild": xcode_lines[1].removeprefix("Build version "),
            "xctrace": xctrace,
            "traceDurationSeconds": trace_duration_seconds,
        },
        "profiles": profiles,
        "limitations": limitations,
        "reproduction": {
            "script": "scripts/run-detail-ui-baseline.sh",
            "applicationKind": application_kind,
            "releaseApplicationProtected": True,
            "userLibraryAccess": "none",
        },
    }


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--input", required=True, type=pathlib.Path)
    result.add_argument("--output", required=True, type=pathlib.Path)
    result.add_argument("--trace-duration", required=True, type=int)
    result.add_argument(
        "--application-kind",
        choices=APPLICATION_KINDS,
        default="installed-dev-bundle",
    )
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        if arguments.trace_duration < 1:
            raise EvidenceError("trace duration must be positive")
        document = build_document(
            arguments.input,
            arguments.trace_duration,
            arguments.application_kind,
        )
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(
            json.dumps(document, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(f"Meeting Detail performance baseline verified: {arguments.output}")
        return 0
    except EvidenceError as error:
        print(f"meeting-detail-performance: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
