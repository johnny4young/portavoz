#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/run-exact-path-shadow-benchmark.sh --scale 1000 [--runs 5]
  scripts/run-exact-path-shadow-benchmark.sh --matrix [--runs 5]

Runs the test-only Accelerate/sqlite-vec exact-path harness in Release mode.
Each corpus size gets a fresh XCTest process. Test/build logs go to stderr and
one content-free schema-v1 JSON observation per size goes to stdout. The script
does not accept an output path and does not persist benchmark results.
EOF
}

scale=""
matrix=0
runs=5
while (($# > 0)); do
  case "$1" in
    --scale)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      scale="$2"
      shift 2
      ;;
    --matrix)
      matrix=1
      shift
      ;;
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

[[ "$runs" =~ ^[0-9]+$ ]] && ((runs >= 3 && runs <= 50)) || {
  echo "--runs must be between 3 and 50" >&2
  exit 64
}
if ((matrix == 1)) && [[ -n "$scale" ]]; then
  echo "choose either --scale or --matrix" >&2
  exit 64
fi
if ((matrix == 0)) && [[ -z "$scale" ]]; then
  usage >&2
  exit 64
fi

canonical_scale() {
  case "$1" in
    1000|10000|50000|100000) return 0 ;;
    *) return 1 ;;
  esac
}

run_scale() {
  local current_scale="$1"
  local log
  canonical_scale "$current_scale" || {
    echo "--scale must be one of 1000, 10000, 50000, or 100000" >&2
    exit 64
  }
  log="$(mktemp "${TMPDIR:-/tmp}/portavoz-exact-path.XXXXXX")"
  if ! PORTAVOZ_EXACT_PATH_BENCHMARK=1 \
    PORTAVOZ_EXACT_PATH_SCALE="$current_scale" \
    PORTAVOZ_EXACT_PATH_RUNS="$runs" \
    swift test -c release \
      --filter ExactPathScaleBenchmarkTests.testCanonicalExactPathBenchmarkFromEnvironment \
      >"$log" 2>&1; then
    cat "$log" >&2
    rm -f "$log"
    return 1
  fi
  cat "$log" >&2
  local report
  report="$(grep '^PORTAVOZ_EXACT_PATH_REPORT ' "$log" | tail -1 || true)"
  rm -f "$log"
  [[ -n "$report" ]] || {
    echo "benchmark completed without a schema-v1 observation" >&2
    return 1
  }
  printf '%s\n' "${report#PORTAVOZ_EXACT_PATH_REPORT }"
}

if ((matrix == 1)); then
  for current_scale in 1000 10000 50000 100000; do
    run_scale "$current_scale"
  done
else
  run_scale "$scale"
fi
