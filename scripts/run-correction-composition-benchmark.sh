#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-correction-composition-benchmark.sh [--runs 20]

Runs the content-free 20,000-segment correction composition benchmark in
Release mode. Build and test logs go to stderr; one schema-v1 JSON observation
goes to stdout. The runner never reads a user library or persists a report.
EOF
}

runs=20
while (($# > 0)); do
  case "$1" in
    --runs)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      runs="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

[[ "$runs" =~ ^[0-9]+$ ]] && ((runs >= 3 && runs <= 20)) || {
  echo "--runs must be between 3 and 20" >&2
  exit 64
}

log="$(mktemp "${TMPDIR:-/tmp}/portavoz-correction-composition.XXXXXX")"
trap 'rm -f "$log"' EXIT
if ! PORTAVOZ_CORRECTION_COMPOSITION_BENCHMARK=1 \
  PORTAVOZ_CORRECTION_COMPOSITION_RUNS="$runs" \
  swift test -c release \
    --filter TranscriptCorrectionScaleBenchmarkTests.testCanonicalTwentyThousandSegmentBenchmarkFromEnvironment \
    >"$log" 2>&1; then
  cat "$log" >&2
  exit 1
fi
cat "$log" >&2
report="$(grep '^PORTAVOZ_CORRECTION_COMPOSITION_REPORT ' "$log" | tail -1 || true)"
[[ -n "$report" ]] || {
  echo "benchmark completed without a schema-v1 correction observation" >&2
  exit 1
}
printf '%s\n' "${report#PORTAVOZ_CORRECTION_COMPOSITION_REPORT }"
