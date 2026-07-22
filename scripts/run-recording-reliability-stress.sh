#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_FILTER='AudioCaptureTests|StartRecordingUseCaseTests|StopRecordingUseCaseTests|RecoverInterruptedMeetingsUseCaseTests|LiveTranscriptionAttacherTests|RecordingPersistenceTests|ProcessingJobPersistenceTests|ProcessPostCaptureJobsUseCaseTests|InitialTranscriptionOperationFingerprintTests|CaptionCoalescerTests'

iterations="${PORTAVOZ_STRESS_ITERATIONS:-25}"
minimum_tests="${PORTAVOZ_STRESS_MINIMUM_TESTS:-90}"
test_filter="${PORTAVOZ_STRESS_FILTER:-$DEFAULT_FILTER}"

usage() {
  cat <<'EOF'
Usage: scripts/run-recording-reliability-stress.sh [options]

Options:
  --iterations N       Number of independent test executions (default: 25)
  --minimum-tests N    Fail if the filter executes fewer tests (default: 90)
  --filter REGEX       Override the focused XCTest filter
  -h, --help           Show this help
EOF
}

while (($#)); do
  case "$1" in
    --iterations)
      [[ $# -ge 2 ]] || { echo "error: --iterations requires a value" >&2; exit 2; }
      iterations="$2"
      shift 2
      ;;
    --minimum-tests)
      [[ $# -ge 2 ]] || { echo "error: --minimum-tests requires a value" >&2; exit 2; }
      minimum_tests="$2"
      shift 2
      ;;
    --filter)
      [[ $# -ge 2 ]] || { echo "error: --filter requires a value" >&2; exit 2; }
      test_filter="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$iterations" =~ ^[1-9][0-9]*$ ]] || {
  echo "error: iterations must be a positive integer" >&2
  exit 2
}
[[ "$minimum_tests" =~ ^[1-9][0-9]*$ ]] || {
  echo "error: minimum-tests must be a positive integer" >&2
  exit 2
}
[[ -n "$test_filter" ]] || {
  echo "error: filter must not be empty" >&2
  exit 2
}

if [[ -n "${PORTAVOZ_STRESS_LOG_DIR:-}" ]]; then
  log_dir="$PORTAVOZ_STRESS_LOG_DIR"
  mkdir -p "$log_dir"
  remove_logs=false
else
  log_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/portavoz-recording-stress.XXXXXX")"
  remove_logs=true
fi

cd "$ROOT"
echo "Recording reliability stress: $iterations iterations"

for ((iteration = 1; iteration <= iterations; iteration++)); do
  log="$log_dir/iteration-$iteration.log"
  command=(swift test --filter "$test_filter")
  if ((iteration > 1)); then
    command=(swift test --skip-build --filter "$test_filter")
  fi

  if ! "${command[@]}" >"$log" 2>&1; then
    echo "error: recording reliability iteration $iteration failed" >&2
    cat "$log" >&2
    echo "Failure logs preserved at: $log_dir" >&2
    exit 1
  fi

  executed="$({ sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p' "$log" || true; } | sort -nr | head -n 1)"
  if [[ -z "$executed" || "$executed" -lt "$minimum_tests" ]]; then
    echo "error: iteration $iteration executed ${executed:-0} tests; expected at least $minimum_tests" >&2
    cat "$log" >&2
    echo "Failure logs preserved at: $log_dir" >&2
    exit 1
  fi

  printf '  ✓ iteration %d (%d tests)\n' "$iteration" "$executed"
done

if [[ "$remove_logs" == true ]]; then
  rm -rf "$log_dir"
else
  echo "Logs retained at: $log_dir"
fi

echo "Recording reliability stress passed: $iterations/$iterations iterations."
