#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/run-graph-scale-benchmark.sh

Measures the meeting memory graph queries in Release mode over 1,000 and 10,000
synthetic meetings, and fails when a p95 reaches the 250 ms interactive budget.
Build and test logs go to stderr; one content-free JSON report per scale goes to
stdout. The runner never reads a user library or persists a report.
USAGE
}

case "${1:-}" in
  "") ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 64
    ;;
esac

log="$(mktemp "${TMPDIR:-/tmp}/portavoz-graph-scale.XXXXXX")"
trap 'rm -f "$log"' EXIT
for meetings in 1000 10000; do
  if ! PORTAVOZ_GRAPH_SCALE_BENCHMARK=1 \
    PORTAVOZ_GRAPH_SCALE_MEETINGS="$meetings" \
    swift test -c release \
      --filter MeetingMemoryGraphScaleTests.testCanonicalGraphScaleFromEnvironment \
      >"$log" 2>&1; then
    cat "$log" >&2
    exit 1
  fi
  cat "$log" >&2
  report="$(grep '^PORTAVOZ_GRAPH_SCALE_REPORT ' "$log" | tail -1 || true)"
  [[ "$report" == *"\"meetingCount\":$meetings,"* ]] || {
    echo "benchmark completed without a report for $meetings meetings" >&2
    exit 1
  }
  printf '%s\n' "${report#PORTAVOZ_GRAPH_SCALE_REPORT }"
done
