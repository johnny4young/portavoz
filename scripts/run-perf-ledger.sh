#!/usr/bin/env bash
# Release performance ledger (PERF-001/PERF-008).
#
# Runs the unattended benchmark harnesses, evaluates every measurement against
# the declared contract in docs/evidence/perf-thresholds.json, and writes one
# scorecard.
#
# Exit 0: every measured journey is inside its budget.
# Exit 1: a budget miss, an unresolved metric, or a harness that could not run.
# Exit 2: regression candidates only — PERF-008 wants three stable runs before
#         one counts. PORTAVOZ_PERF_STRICT=1 makes those exit 1 instead.
#
# The harnesses that need a microphone, a real call, a real recording, or
# Instruments stay out of this run on purpose. They are still declared in the
# contract, so the scorecard names them as not measured instead of quietly
# shipping a partial answer as a green one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUTPUT_DIR="${1:-dist/perf-ledger}"
EVIDENCE="docs/evidence"
CONTRACT="$EVIDENCE/perf-thresholds.json"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Optional inputs. Waveform needs a long dual-channel recording; the detail-UI
# trace needs Instruments and an installed Portavoz Dev.
WAVEFORM_MIC="${PORTAVOZ_PERF_WAVEFORM_MIC:-}"
WAVEFORM_SYSTEM="${PORTAVOZ_PERF_WAVEFORM_SYSTEM:-}"
INCLUDE_DETAIL_UI="${PORTAVOZ_PERF_INCLUDE_DETAIL_UI:-0}"
STRICT="${PORTAVOZ_PERF_STRICT:-0}"

mkdir -p "$OUTPUT_DIR"
reports=()

# A harness that cannot measure must not look like a harness that measured
# nothing: name the stage that failed and say plainly that no scorecard exists.
run_stage() {
  local label="$1"
  shift
  echo "==> $label"
  if ! "$@" >/dev/null; then
    echo "error: $label failed — no scorecard was written." >&2
    exit 1
  fi
}

run_stage "Library and detail scale matrix" \
  scripts/run-scale-baseline.sh "$OUTPUT_DIR/scale.json"
reports+=(--report "scale=$OUTPUT_DIR/scale.json")

run_stage "Semantic retrieval matrix" \
  scripts/run-semantic-scale-baseline.sh "$OUTPUT_DIR/semantic.json"
reports+=(--report "semantic=$OUTPUT_DIR/semantic.json")

run_stage "Spotlight projection matrix" \
  scripts/run-spotlight-scale-baseline.sh "$OUTPUT_DIR/spotlight.json"
reports+=(--report "spotlight=$OUTPUT_DIR/spotlight.json")

if [[ -n "$WAVEFORM_MIC" && -n "$WAVEFORM_SYSTEM" ]]; then
  run_stage "Waveform generation over the supplied recording" \
    swift run -c release portavoz-cli bench-waveform \
    --mic "$WAVEFORM_MIC" --system "$WAVEFORM_SYSTEM" \
    --output "$OUTPUT_DIR/waveform.json"
  reports+=(--report "waveform=$OUTPUT_DIR/waveform.json")
else
  echo "==> Waveform skipped (set PORTAVOZ_PERF_WAVEFORM_MIC/SYSTEM to include it)"
fi

if [[ "$INCLUDE_DETAIL_UI" == "1" ]]; then
  run_stage "Meeting Detail first-content trace" \
    scripts/run-detail-ui-baseline.sh "$OUTPUT_DIR/detail-ui.json"
  reports+=(--report "detail-ui=$OUTPUT_DIR/detail-ui.json")
else
  echo "==> Detail-UI trace skipped (set PORTAVOZ_PERF_INCLUDE_DETAIL_UI=1 after make install)"
fi

# Record the toolchain that built these binaries. Without it, a shift in the
# numbers cannot be told apart from a codegen change, which is exactly the
# question a comparison against an older baseline raises.
swift --version > "$OUTPUT_DIR/.toolchain-swift.txt" 2>/dev/null || true
xcodebuild -version > "$OUTPUT_DIR/.toolchain-xcode.txt" 2>/dev/null || true
python3 - "$OUTPUT_DIR" <<'STAMP'
import json
import re
import sys
from pathlib import Path

directory = Path(sys.argv[1])


def read(name: str) -> list[str]:
    path = directory / name
    if not path.is_file():
        return []
    return path.read_text(encoding="utf-8").splitlines()


swift_lines = read(".toolchain-swift.txt")
xcode_lines = read(".toolchain-xcode.txt")
toolchain: dict[str, str] = {}
for line in swift_lines:
    if match := re.search(r"Swift version (.+)", line):
        toolchain["swift"] = match.group(1).strip()
    elif line.startswith("Target:"):
        toolchain["target"] = line.removeprefix("Target:").strip()
if xcode_lines:
    toolchain["xcode"] = xcode_lines[0].strip()
    if len(xcode_lines) > 1:
        toolchain["xcodeBuild"] = (
            xcode_lines[1].removeprefix("Build version ").strip())

if toolchain:
    for report in sorted(directory.glob("*.json")):
        if report.name == "ledger.json":
            continue
        payload = json.loads(report.read_text())
        # Merge, never replace: the detail-UI harness records its own
        # Instruments toolchain and must keep it.
        existing = payload.get("toolchain")
        payload["toolchain"] = {
            **(existing if isinstance(existing, dict) else {}), **toolchain}
        report.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
STAMP
rm -f "$OUTPUT_DIR/.toolchain-swift.txt" "$OUTPUT_DIR/.toolchain-xcode.txt"

# The contract names its own baselines, so moving one forward stays a
# reviewable edit of a tracked file rather than a flag someone remembers.
baselines=()
while IFS=$'\t' read -r harness file; do
  [[ -f "$EVIDENCE/$file" ]] || continue
  baselines+=(--baseline "$harness=$EVIDENCE/$file")
done < <(python3 -c "
import json, sys
declared = json.load(open('$CONTRACT')).get('baselines', {})
for harness, path in declared.items():
    if harness != 'note':
        print(f'{harness}\t{path}')
")

# `[[ … ]] && assign` returns non-zero when the condition is false, which
# under `set -e` would kill the run one line before the scorecard is written.
strict_flag=()
if [[ "$STRICT" == "1" ]]; then
  strict_flag=(--strict)
fi

set +e
python3 scripts/perf_ledger.py \
  --thresholds "$CONTRACT" \
  "${reports[@]}" \
  ${baselines[@]+"${baselines[@]}"} \
  ${strict_flag[@]+"${strict_flag[@]}"} \
  --generated-at "$GENERATED_AT" \
  --json-output "$OUTPUT_DIR/ledger.json" \
  --markdown-output "$OUTPUT_DIR/ledger.md"
status=$?
set -e

echo
echo "Scorecard: $OUTPUT_DIR/ledger.md"
case "$status" in
  0) echo "Performance ledger: every measured journey is inside its budget." ;;
  2) echo "Performance ledger: regression candidates recorded — re-run to confirm (PERF-008 wants three stable runs)." ;;
  *) echo "Performance ledger: FAILED." >&2 ;;
esac
exit "$status"
