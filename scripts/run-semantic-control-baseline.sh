#!/usr/bin/env bash
# Collect three alternating clean semantic matrices for the canonical current
# control and the separate three-query-variant diagnostic, then retain only
# their validated content-free aggregate receipts.
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ROOT="${PORTAVOZ_SEMANTIC_SOURCE_ROOT:-$TOOL_ROOT}"
if ! ROOT="$(cd "$SOURCE_ROOT" 2>/dev/null && pwd)"; then
    echo "error: PORTAVOZ_SEMANTIC_SOURCE_ROOT must be a readable directory" >&2
    exit 64
fi
RUNNER="$TOOL_ROOT/scripts/run-semantic-scale-baseline.sh"
MANIFEST_TOOL="$TOOL_ROOT/scripts/semantic_scale_manifest.py"
TEMP_ROOT_CANDIDATE="${TMPDIR:-/tmp}"
if ! TEMP_ROOT="$(cd "$TEMP_ROOT_CANDIDATE" 2>/dev/null && pwd)" ||
    [[ ! -w "$TEMP_ROOT" ]]; then
    echo "error: TMPDIR must be a writable directory" >&2
    exit 64
fi
CANONICAL_OUTPUT="${1:-$TEMP_ROOT/portavoz-semantic-current-control.json}"
DIAGNOSTIC_OUTPUT="${2:-$TEMP_ROOT/portavoz-semantic-three-variant.json}"

python3 - "$CANONICAL_OUTPUT" "$DIAGNOSTIC_OUTPUT" <<'PY'
import sys
from pathlib import Path

if Path(sys.argv[1]).resolve() == Path(sys.argv[2]).resolve():
    print("error: semantic control outputs must be different paths", file=sys.stderr)
    raise SystemExit(64)
PY

if ! PARTS="$(mktemp -d "$TEMP_ROOT/portavoz-semantic-control.XXXXXX")"; then
    echo "error: unable to allocate semantic control workspace" >&2
    exit 73
fi
trap 'rm -rf "$PARTS"' EXIT

cd "$ROOT"
python3 "$MANIFEST_TOOL" source \
    --root "$ROOT" \
    --output "$PARTS/source-before.json"
python3 - "$PARTS/source-before.json" <<'PY'
import json
import sys
from pathlib import Path

source = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if not source.get("worktreeClean"):
    print("error: repeated semantic control requires a clean worktree", file=sys.stderr)
    raise SystemExit(64)
PY

for observation in 1 2 3; do
    PORTAVOZ_SEMANTIC_SCALE_SIZES=1000,10000,50000,100000 \
        PORTAVOZ_SEMANTIC_SCALE_RUNS=20 \
        PORTAVOZ_SEMANTIC_SCALE_VARIANTS=1 \
        PORTAVOZ_SEMANTIC_SOURCE_ROOT="$ROOT" \
        "$RUNNER" "$PARTS/canonical-$observation.json"
    PORTAVOZ_SEMANTIC_SCALE_SIZES=1000,10000,50000,100000 \
        PORTAVOZ_SEMANTIC_SCALE_RUNS=20 \
        PORTAVOZ_SEMANTIC_SCALE_VARIANTS=3 \
        PORTAVOZ_SEMANTIC_SOURCE_ROOT="$ROOT" \
        "$RUNNER" "$PARTS/three-variant-$observation.json"
done

python3 "$MANIFEST_TOOL" baseline \
    "$PARTS"/canonical-{1,2,3}.json \
    --output "$PARTS/canonical-aggregate.json"
python3 "$MANIFEST_TOOL" baseline \
    "$PARTS"/three-variant-{1,2,3}.json \
    --output "$PARTS/three-variant-aggregate.json"

python3 "$MANIFEST_TOOL" source \
    --root "$ROOT" \
    --output "$PARTS/source-after.json"
if ! cmp -s "$PARTS/source-before.json" "$PARTS/source-after.json"; then
    echo "error: worktree changed during repeated semantic control collection" >&2
    exit 64
fi

# Validate both receipts before publishing either one. The helper's atomic
# owner-only writer keeps a failed or interrupted publication from truncating
# an existing receipt.
python3 - \
    "$MANIFEST_TOOL" \
    "$PARTS/canonical-aggregate.json" "$CANONICAL_OUTPUT" \
    "$PARTS/three-variant-aggregate.json" "$DIAGNOSTIC_OUTPUT" <<'PY'
import importlib.util
import sys
from pathlib import Path

tool_path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("semantic_scale_manifest", tool_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)

pairs = ((Path(sys.argv[2]), Path(sys.argv[3])), (Path(sys.argv[4]), Path(sys.argv[5])))
validated = []
for index, (source, destination) in enumerate(pairs):
    document = module.read_json(source, f"control receipt {index}")
    module.validate_control_baseline(document, f"control receipt {index}")
    validated.append((destination, document))
for destination, document in validated:
    module.write_json(destination, document)
PY

echo "Semantic current-control receipt verified: $CANONICAL_OUTPUT"
echo "Semantic three-variant diagnostic verified: $DIAGNOSTIC_OUTPUT"
