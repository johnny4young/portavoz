#!/bin/bash
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${PORTAVOZ_SEMANTIC_SOURCE_ROOT:-$TOOL_ROOT}"
if ! ROOT="$(cd "$SOURCE_ROOT" 2>/dev/null && pwd)"; then
    echo "error: PORTAVOZ_SEMANTIC_SOURCE_ROOT must be a readable directory" >&2
    exit 64
fi
MANIFEST_TOOL="$TOOL_ROOT/scripts/semantic_scale_manifest.py"
OUTPUT="${1:-}"
SIZES="${PORTAVOZ_SEMANTIC_SCALE_SIZES:-1000,10000,50000,100000}"
RUNS="${PORTAVOZ_SEMANTIC_SCALE_RUNS:-20}"
VARIANTS="${PORTAVOZ_SEMANTIC_SCALE_VARIANTS:-1}"

cd "$ROOT"
if [[ ! "$RUNS" =~ ^[0-9]+$ ]] || ((RUNS < 3 || RUNS > 100)); then
    echo "error: PORTAVOZ_SEMANTIC_SCALE_RUNS must be between 3 and 100" >&2
    exit 64
fi
if [[ ! "$VARIANTS" =~ ^[0-9]+$ ]] || ((VARIANTS < 1 || VARIANTS > 8)); then
    echo "error: PORTAVOZ_SEMANTIC_SCALE_VARIANTS must be between 1 and 8" >&2
    exit 64
fi

IFS=',' read -r -a checkpoints <<<"$SIZES"
seen=","
for raw_size in "${checkpoints[@]}"; do
    size="${raw_size//[[:space:]]/}"
    if [[ ! "$size" =~ ^[0-9]+$ ]] || ((size < 1 || size > 1000000)); then
        echo "error: invalid semantic checkpoint size: $raw_size" >&2
        exit 64
    fi
    if [[ "$seen" == *",$size,"* ]]; then
        echo "error: duplicate semantic checkpoint size: $size" >&2
        exit 64
    fi
    seen+="$size,"
done

TEMP_ROOT_CANDIDATE="${TMPDIR:-/tmp}"
if ! TEMP_ROOT="$(cd "$TEMP_ROOT_CANDIDATE" 2>/dev/null && pwd)" ||
    [[ ! -w "$TEMP_ROOT" ]]; then
    echo "error: TMPDIR must be a writable directory" >&2
    exit 64
fi
OUTPUT="${OUTPUT:-$TEMP_ROOT/portavoz-semantic-scale-baseline.json}"
if ! PARTS="$(mktemp -d "$TEMP_ROOT/portavoz-semantic-scale.XXXXXX")"; then
    echo "error: unable to allocate semantic scale workspace" >&2
    exit 73
fi
trap 'rm -rf "$PARTS"' EXIT

python3 "$MANIFEST_TOOL" source \
    --root "$ROOT" \
    --output "$PARTS/source.snapshot"
build_start="$(python3 -c 'import time; print(time.monotonic_ns())')"
swift build -c release --product portavoz-cli
build_end="$(python3 -c 'import time; print(time.monotonic_ns())')"
build_wall_ms="$(
    python3 - "$build_start" "$build_end" <<'PY'
import sys
start, end = map(int, sys.argv[1:])
if end < start:
    raise SystemExit("error: non-monotonic Release build clock")
print((end - start) / 1_000_000)
PY
)"

python3 "$MANIFEST_TOOL" snapshot \
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
        --variants "$VARIANTS" \
        --output "$PARTS/$size.json"
done

python3 "$MANIFEST_TOOL" assemble \
    --root "$ROOT" \
    --binary "$ROOT/.build/release/portavoz-cli" \
    --snapshot "$PARTS/run.snapshot" \
    --parts "$PARTS" \
    --output "$OUTPUT"
echo "Semantic scale manifest verified: $OUTPUT"
