#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-/private/tmp/portavoz-semantic-scale-baseline.json}"
SIZES="${PORTAVOZ_SEMANTIC_SCALE_SIZES:-1000,10000,50000,100000}"
RUNS="${PORTAVOZ_SEMANTIC_SCALE_RUNS:-20}"
PARTS="$(mktemp -d /private/tmp/portavoz-semantic-scale.XXXXXX)"
trap 'rm -rf "$PARTS"' EXIT

cd "$ROOT"
swift build -c release --product portavoz-cli

IFS=',' read -r -a checkpoints <<< "$SIZES"
for raw_size in "${checkpoints[@]}"; do
    size="${raw_size//[[:space:]]/}"
    if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size < 1 || size > 1000000 )); then
        echo "error: invalid semantic checkpoint size: $raw_size" >&2
        exit 64
    fi
    "$ROOT/.build/release/portavoz-cli" bench-semantic \
        --segments "$size" \
        --runs "$RUNS" \
        --output "$PARTS/$size.json"
done

python3 - "$OUTPUT" "$PARTS" <<'PY'
import datetime
import json
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
parts = pathlib.Path(sys.argv[2])
reports = [json.loads(path.read_text(encoding="utf-8")) for path in parts.glob("*.json")]
if not reports:
    raise SystemExit("error: semantic benchmark produced no checkpoints")
reports.sort(key=lambda report: report["checkpoint"]["totalSegments"])
first = reports[0]
for report in reports:
    if report.get("schemaVersion") != 1:
        raise SystemExit("error: unexpected semantic checkpoint schema")
    if report.get("buildConfiguration") != "release":
        raise SystemExit("error: tracked semantic evidence must come from a release build")
    if report.get("host") != first.get("host"):
        raise SystemExit("error: semantic checkpoints came from different hosts")
    if report.get("configuration") != first.get("configuration"):
        raise SystemExit("error: semantic checkpoints used different configurations")
    checkpoint = report["checkpoint"]
    expected_count = min(checkpoint["totalSegments"], first["configuration"]["resultLimit"])
    if checkpoint["resultCount"] != expected_count:
        raise SystemExit("error: semantic search returned an incomplete top-k")

matrix = {
    "schemaVersion": 1,
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "buildConfiguration": "release",
    "host": first["host"],
    "configuration": first["configuration"],
    "checkpoints": [report["checkpoint"] for report in reports],
}
output.parent.mkdir(parents=True, exist_ok=True)
temporary = output.with_name(output.name + ".tmp")
temporary.write_text(json.dumps(matrix, indent=2, sort_keys=True) + "\n", encoding="utf-8")
temporary.replace(output)
print(f"Semantic scale baseline verified: {output}")
PY
