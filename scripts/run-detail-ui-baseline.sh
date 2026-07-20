#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-/private/tmp/portavoz-detail-ui-baseline.json}"
APP="${PORTAVOZ_DEV_APP:-/Applications/Portavoz Dev.app}"
DURATION="${PORTAVOZ_DETAIL_TRACE_SECONDS:-10}"
RUN_ROOT="$(mktemp -d /private/tmp/portavoz-detail-ui-baseline.XXXXXX)"

if [[ "$APP" == "/Applications/Portavoz.app" ]]; then
    echo "error: the performance harness must never launch the notarized release copy" >&2
    exit 64
fi

EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")"
EXECUTABLE="$APP/Contents/MacOS/$EXECUTABLE_NAME"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "error: install the current dev bundle first with make install" >&2
    exit 66
fi

cleanup() {
    osascript -e 'tell application "Portavoz Dev" to quit' >/dev/null 2>&1 || true
    if [[ "${PORTAVOZ_KEEP_DETAIL_TRACES:-0}" != "1" ]]; then
        rm -rf "$RUN_ROOT"
    else
        echo "Detail traces retained at: $RUN_ROOT"
    fi
}
trap cleanup EXIT

launch_arguments=(
    -ApplePersistenceIgnoreState YES
    -use-temp-store
    -seed-scale
    -scale-auto-summary-update
    -reset-app-language
)

record_trace() {
    local template="$1"
    local name="$2"
    local trace="$RUN_ROOT/$name.trace"
    local audio="$RUN_ROOT/$name-audio"
    local log="$RUN_ROOT/$name.log"
    mkdir -p "$audio"
    osascript -e 'tell application "Portavoz Dev" to quit' >/dev/null 2>&1 || true
    sleep 1

    set +e
    xcrun xctrace record \
        --template "$template" \
        --time-limit "${DURATION}s" \
        --output "$trace" \
        --env "PORTAVOZ_AUDIO_ROOT=$audio" \
        --launch -- "$EXECUTABLE" "${launch_arguments[@]}" >"$log" 2>&1
    local status=$?
    set -e
    # xctrace returns 54 when the requested time limit terminates the app.
    if [[ $status -ne 0 && $status -ne 54 ]]; then
        cat "$log" >&2
        return "$status"
    fi
}

export_table() {
    local trace="$1"
    local schema="$2"
    local output="$3"
    xcrun xctrace export \
        --input "$trace" \
        --xpath "/trace-toc/run[@number='1']/data/table[@schema='$schema']" \
        --output "$output" >/dev/null
}

record_trace SwiftUI swiftui
record_trace Logging logging

export_table "$RUN_ROOT/swiftui.trace" swiftui-updates "$RUN_ROOT/swiftui-updates.xml"
export_table "$RUN_ROOT/swiftui.trace" potential-hangs "$RUN_ROOT/potential-hangs.xml"
export_table "$RUN_ROOT/swiftui.trace" time-profile "$RUN_ROOT/time-profile.xml"
export_table \
    "$RUN_ROOT/logging.trace" \
    os-signpost-interval \
    "$RUN_ROOT/os-signpost-interval.xml"

xcodebuild -version >"$RUN_ROOT/xcode-version.txt"
xcrun xctrace version >"$RUN_ROOT/xctrace-version.txt"
sw_vers >"$RUN_ROOT/sw-vers.txt"

mkdir -p "$(dirname "$OUTPUT")"
python3 - "$RUN_ROOT" "$OUTPUT" "$DURATION" <<'PY'
import datetime
import json
import pathlib
import platform
import sys
import xml.etree.ElementTree as ET

root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
duration_seconds = int(sys.argv[3])


def rows(name):
    return ET.parse(root / name).getroot().findall(".//row")


def first_child(row, tag):
    child = row.find(tag)
    if child is None or child.text is None:
        raise SystemExit(f"error: missing {tag} in trace row")
    return child


intervals = rows("os-signpost-interval.xml")
first_content = next(
    (row for row in intervals if "Meeting Detail First Content" in "".join(row.itertext())),
    None,
)
if first_content is None:
    raise SystemExit("error: Meeting Detail First Content signpost was not captured")

swiftui_rows = rows("swiftui-updates.xml")
hang_rows = rows("potential-hangs.xml")
hangs = []
for row in hang_rows:
    start = first_child(row, "start-time")
    duration = first_child(row, "duration")
    hangs.append({
        "startMilliseconds": int(start.text) / 1_000_000,
        "durationMilliseconds": int(duration.text) / 1_000_000,
        "classification": first_child(row, "hang-type").text,
    })

time_profile_text = (root / "time-profile.xml").read_text(encoding="utf-8")
swiftui_log = (root / "swiftui.log").read_text(encoding="utf-8")
first_content_duration = first_child(first_content, "duration")
xcode_lines = (root / "xcode-version.txt").read_text(encoding="utf-8").splitlines()
sw_vers = dict(
    line.split(":", 1) for line in (root / "sw-vers.txt").read_text(encoding="utf-8").splitlines()
)

status = "captured" if swiftui_rows else "unavailable-toolchain"
limitations = []
if not swiftui_rows:
    limitations.append(
        "xctrace emitted 'Trace file had no SwiftUI data'; the baseline does not claim "
        "view-body invalidation counts on this toolchain."
    )

report = {
    "schemaVersion": 1,
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "fixture": {
        "durationMinutes": 120,
        "segmentCount": 5000,
        "speakerCount": 4,
        "storage": "disposable-temp-store",
        "audio": "none",
        "summaryMutationAfterSeconds": 3,
    },
    "host": {
        "operatingSystem": sw_vers["ProductVersion"].strip(),
        "operatingSystemBuild": sw_vers["BuildVersion"].strip(),
        "architecture": platform.machine(),
    },
    "toolchain": {
        "xcode": xcode_lines[0],
        "xcodeBuild": xcode_lines[1].removeprefix("Build version "),
        "xctrace": (root / "xctrace-version.txt").read_text(encoding="utf-8").strip(),
        "traceDurationSeconds": duration_seconds,
    },
    "firstContent": {
        "name": "Meeting Detail First Content",
        "durationMilliseconds": int(first_content_duration.text) / 1_000_000,
        "subsystem": "app.portavoz.mac",
        "category": "meeting-detail",
    },
    "swiftUI": {
        "status": status,
        "updateRowCount": len(swiftui_rows),
        "xctraceWarningPresent": "Trace file had no SwiftUI data" in swiftui_log,
    },
    "timeProfiler": {
        "sampleRowCount": len(rows("time-profile.xml")),
        "meetingDetailViewSymbolsPresent": "MeetingDetailView.body.getter" in time_profile_text,
        "transcriptSegmentsViewSymbolsPresent": "TranscriptSegmentsView" in time_profile_text,
    },
    "responsiveness": {
        "potentialHangThresholdMilliseconds": 250,
        "potentialHangCount": len(hangs),
        "maximumPotentialHangMilliseconds": max(
            (item["durationMilliseconds"] for item in hangs), default=0
        ),
        "potentialHangs": hangs,
    },
    "limitations": limitations,
    "reproduction": {
        "script": "scripts/run-detail-ui-baseline.sh",
        "application": "/Applications/Portavoz Dev.app",
        "releaseApplicationProtected": True,
    },
}
output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"Detail UI baseline verified: {output}")
PY
