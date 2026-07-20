#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-/private/tmp/portavoz-spotlight-scale.json}"
SIZES="${PORTAVOZ_SPOTLIGHT_SCALE_SIZES:-1000,10000,100000}"
RUNS="${PORTAVOZ_SPOTLIGHT_SCALE_RUNS:-3}"
DELIVERY_ITEMS="${PORTAVOZ_SPOTLIGHT_DELIVERY_ITEMS:-1000}"
PARTS="$(mktemp -d /private/tmp/portavoz-spotlight-scale.XXXXXX)"
trap 'rm -rf "$PARTS"' EXIT

cd "$ROOT"
swift build -c release --product portavoz-cli

IFS=',' read -r -a checkpoints <<< "$SIZES"
last_index=$((${#checkpoints[@]} - 1))
for mode in legacy snapshot; do
    for position in "${!checkpoints[@]}"; do
        raw_size="${checkpoints[$position]}"
        size="${raw_size//[[:space:]]/}"
        if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size < 1 || size > 100000 )); then
            echo "error: invalid Spotlight checkpoint size: $raw_size" >&2
            exit 64
        fi
        delivery=0
        if [[ "$mode" == "snapshot" && "$position" -eq "$last_index" ]]; then
            delivery="$DELIVERY_ITEMS"
        fi
        "$ROOT/.build/release/portavoz-cli" bench-spotlight \
            --mode "$mode" \
            --meetings "$size" \
            --runs "$RUNS" \
            --delivery-items "$delivery" \
            --output "$PARTS/$mode-$size.json"
    done
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
    raise SystemExit("error: Spotlight benchmark produced no checkpoints")

groups = {"legacy": [], "snapshot": []}
for report in reports:
    if report.get("schemaVersion") != 1:
        raise SystemExit("error: unexpected Spotlight checkpoint schema")
    if report.get("buildConfiguration") != "release":
        raise SystemExit("error: tracked Spotlight evidence must come from a release build")
    mode = report["configuration"]["mode"]
    groups[mode].append(report)

for mode in groups:
    groups[mode].sort(key=lambda report: report["checkpoint"]["meetingCount"])
if [r["checkpoint"]["meetingCount"] for r in groups["legacy"]] != [
    r["checkpoint"]["meetingCount"] for r in groups["snapshot"]
]:
    raise SystemExit("error: Spotlight modes used different checkpoints")

first = groups["legacy"][0]
host = first["host"]
for report in reports:
    if report["host"] != host:
        raise SystemExit("error: Spotlight checkpoints came from different hosts")
    checkpoint = report["checkpoint"]
    if checkpoint["documentCount"] != checkpoint["meetingCount"]:
        raise SystemExit("error: Spotlight projection lost meeting documents")

equivalence = []
for legacy, snapshot in zip(groups["legacy"], groups["snapshot"]):
    size = legacy["checkpoint"]["meetingCount"]
    equivalent = legacy["checkpoint"]["resultFingerprint"] == snapshot["checkpoint"]["resultFingerprint"]
    equivalence.append({"meetingCount": size, "resultFingerprintEquivalent": equivalent})
    if not equivalent:
        raise SystemExit(f"error: Spotlight projection drift at {size} meetings")

delivery = groups["snapshot"][-1]["checkpoint"].get("delivery")
if delivery and delivery.get("status") == "completed" and not delivery.get("cleanupSucceeded"):
    raise SystemExit("error: synthetic Spotlight delivery was not cleaned up")

configuration = dict(first["configuration"])
configuration.pop("mode", None)
matrix = {
    "schemaVersion": 1,
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "buildConfiguration": "release",
    "host": host,
    "configuration": configuration,
    "legacyCheckpoints": [report["checkpoint"] for report in groups["legacy"]],
    "snapshotCheckpoints": [report["checkpoint"] for report in groups["snapshot"]],
    "equivalence": equivalence,
    "syntheticDelivery": delivery,
}
output.parent.mkdir(parents=True, exist_ok=True)
temporary = output.with_name(output.name + ".tmp")
temporary.write_text(json.dumps(matrix, indent=2, sort_keys=True) + "\n", encoding="utf-8")
temporary.replace(output)
print(f"Spotlight scale evidence verified: {output}")
PY
