#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-/private/tmp/portavoz-semantic-scale-baseline.json}"
SIZES="${PORTAVOZ_SEMANTIC_SCALE_SIZES:-1000,10000,50000,100000}"
RUNS="${PORTAVOZ_SEMANTIC_SCALE_RUNS:-20}"
PARTS="$(mktemp -d /private/tmp/portavoz-semantic-scale.XXXXXX)"
trap 'rm -rf "$PARTS"' EXIT

cd "$ROOT"
if [[ ! "$RUNS" =~ ^[0-9]+$ ]] || (( RUNS < 3 || RUNS > 100 )); then
    echo "error: PORTAVOZ_SEMANTIC_SCALE_RUNS must be between 3 and 100" >&2
    exit 64
fi

IFS=',' read -r -a checkpoints <<< "$SIZES"
seen=","
for raw_size in "${checkpoints[@]}"; do
    size="${raw_size//[[:space:]]/}"
    if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size < 1 || size > 1000000 )); then
        echo "error: invalid semantic checkpoint size: $raw_size" >&2
        exit 64
    fi
    if [[ "$seen" == *",$size,"* ]]; then
        echo "error: duplicate semantic checkpoint size: $size" >&2
        exit 64
    fi
    seen+="$size,"
done

python3 scripts/semantic_scale_manifest.py source \
    --root "$ROOT" \
    --output "$PARTS/source.snapshot"
build_start="$(python3 -c 'import time; print(time.monotonic_ns())')"
swift build -c release --product portavoz-cli
build_end="$(python3 -c 'import time; print(time.monotonic_ns())')"
build_wall_ms="$(python3 - "$build_start" "$build_end" <<'PY'
import sys
start, end = map(int, sys.argv[1:])
if end < start:
    raise SystemExit("error: non-monotonic Release build clock")
print((end - start) / 1_000_000)
PY
)"

python3 scripts/semantic_scale_manifest.py snapshot \
    --root "$ROOT" \
    --binary "$ROOT/.build/release/portavoz-cli" \
    --build-wall-ms "$build_wall_ms" \
    --expected-source "$PARTS/source.snapshot" \
    --output "$PARTS/run.snapshot"

for raw_size in "${checkpoints[@]}"; do
    size="${raw_size//[[:space:]]/}"
    "$ROOT/.build/release/portavoz-cli" bench-semantic \
        --segments "$size" \
        --runs "$RUNS" \
        --output "$PARTS/$size.json"
done

python3 scripts/semantic_scale_manifest.py assemble \
    --root "$ROOT" \
    --binary "$ROOT/.build/release/portavoz-cli" \
    --snapshot "$PARTS/run.snapshot" \
    --parts "$PARTS" \
    --output "$OUTPUT"
echo "Semantic scale manifest verified: $OUTPUT"
