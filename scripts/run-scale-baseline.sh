#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-/private/tmp/portavoz-scale-baseline.json}"

cd "$ROOT"
swift build -c release --product portavoz-cli
"$ROOT/.build/release/portavoz-cli" bench-scale \
    --library-sizes "${PORTAVOZ_SCALE_LIBRARY_SIZES:-1000,10000,50000,100000}" \
    --meeting-minutes "${PORTAVOZ_SCALE_MEETING_MINUTES:-30,120,480}" \
    --runs "${PORTAVOZ_SCALE_RUNS:-20}" \
    --output "$OUTPUT"

python3 - "$OUTPUT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
report = json.loads(path.read_text(encoding="utf-8"))
if report.get("schemaVersion") != 1:
    raise SystemExit("error: unexpected scale benchmark schema")
if report.get("buildConfiguration") != "release":
    raise SystemExit("error: tracked scale evidence must come from a release build")
if not report.get("library") or not report.get("longMeetings"):
    raise SystemExit("error: incomplete scale benchmark matrix")
print(f"Scale baseline verified: {path}")
PY
