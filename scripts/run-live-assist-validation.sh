#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADAPTER="released-prefilter"
ITERATIONS=5
OUTPUT=""
REQUIRE_TARGETS=0
TIMEOUT_SECONDS="${PORTAVOZ_LIVE_ASSIST_TIMEOUT_SECONDS:-1800}"

usage() {
    cat >&2 <<'EOF'
usage: scripts/run-live-assist-validation.sh \
  [--adapter released-prefilter|foundation-models] \
  [--iterations 5...100] [--output <directory>] [--require-targets]
EOF
}

fail() {
    echo "live-assist validation error: $*" >&2
    exit 64
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --adapter)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            ADAPTER="$2"
            shift 2
            ;;
        --iterations)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            ITERATIONS="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            OUTPUT="$2"
            shift 2
            ;;
        --require-targets)
            REQUIRE_TARGETS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

[[ "$ADAPTER" == "released-prefilter" || "$ADAPTER" == "foundation-models" ]] || \
    fail "--adapter must name one explicit supported lane"
[[ "$ITERATIONS" =~ ^[0-9]+$ ]] || fail "--iterations must be an integer"
(( ITERATIONS >= 5 && ITERATIONS <= 100 )) || \
    fail "--iterations must be between 5 and 100"
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || \
    fail "PORTAVOZ_LIVE_ASSIST_TIMEOUT_SECONDS must be an integer"
(( TIMEOUT_SECONDS >= 60 && TIMEOUT_SECONDS <= 7200 )) || \
    fail "PORTAVOZ_LIVE_ASSIST_TIMEOUT_SECONDS must be between 60 and 7200"

cd "$ROOT"
FIXTURE="$ROOT/Fixtures/LiveAssistValidation/public-bilingual-v1.json"
BUDGET="$ROOT/docs/evidence/live-assist-validation-budget.json"
python3 scripts/live_assist_validation.py verify-public \
    --fixture "$FIXTURE" \
    --budget "$BUDGET"

COMMIT="$(git rev-parse HEAD)"
SHORT_COMMIT="${COMMIT:0:12}"
BUILD="live-$SHORT_COMMIT"
SOURCE_STATE="clean"
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    SOURCE_STATE="dirty"
fi
OUTPUT="${OUTPUT:-$ROOT/dist/live-assist/$SHORT_COMMIT/$ADAPTER}"
if [[ "$OUTPUT" != /* ]]; then
    OUTPUT="$ROOT/$OUTPUT"
fi
[[ ! -e "$OUTPUT" ]] || fail "output already exists: $OUTPUT"

umask 077
mkdir -p "$(dirname "$OUTPUT")"
COLLECTION="$(mktemp -d "${OUTPUT}.partial.XXXXXX")"
ACTIVE_PID=""
GUARD_PID=""

cleanup() {
    if [[ -n "$ACTIVE_PID" ]]; then
        kill -TERM "$ACTIVE_PID" 2>/dev/null || true
    fi
    if [[ -n "$GUARD_PID" ]]; then
        kill -TERM "$GUARD_PID" 2>/dev/null || true
    fi
    if [[ -n "${COLLECTION:-}" && -d "$COLLECTION" ]]; then
        rm -rf "$COLLECTION"
    fi
}
trap cleanup EXIT

PORTAVOZ_SIGN_IDENTITY="${PORTAVOZ_SIGN_IDENTITY:--}" \
    scripts/make-app.sh --release
APP_EXECUTABLE="$ROOT/dist/Portavoz.app/Contents/MacOS/portavoz-app"
[[ -x "$APP_EXECUTABLE" ]] || fail "the Release app executable is missing"

OBSERVATIONS="$COLLECTION/observations.json"
"$APP_EXECUTABLE" \
    --bench-live-assist \
    --live-assist-fixture "$FIXTURE" \
    --live-assist-output "$OBSERVATIONS" \
    --live-assist-adapter "$ADAPTER" \
    --live-assist-commit "$COMMIT" \
    --live-assist-build "$BUILD" \
    --live-assist-source-state "$SOURCE_STATE" \
    --live-assist-iterations "$ITERATIONS" &
ACTIVE_PID=$!
(
    sleep "$TIMEOUT_SECONDS"
    kill -TERM "$ACTIVE_PID" 2>/dev/null || exit 0
    sleep 5
    kill -KILL "$ACTIVE_PID" 2>/dev/null || true
) &
GUARD_PID=$!

set +e
wait "$ACTIVE_PID"
RUN_STATUS=$?
set -e
ACTIVE_PID=""
kill -TERM "$GUARD_PID" 2>/dev/null || true
wait "$GUARD_PID" 2>/dev/null || true
GUARD_PID=""
[[ "$RUN_STATUS" -eq 0 ]] || fail "the Release app lane exited with status $RUN_STATUS"
[[ -f "$OBSERVATIONS" ]] || fail "the Release app emitted no observations"

SCORE_ARGUMENTS=(
    score
    --fixture "$FIXTURE"
    --budget "$BUDGET"
    --observations "$OBSERVATIONS"
    --output "$COLLECTION/scorecard.json"
)
if [[ "$REQUIRE_TARGETS" -eq 1 ]]; then
    SCORE_ARGUMENTS+=(--require-targets)
fi
set +e
python3 scripts/live_assist_validation.py "${SCORE_ARGUMENTS[@]}"
SCORE_STATUS=$?
set -e
[[ "$SCORE_STATUS" -le 1 ]] || fail "the scorecard contract rejected the observations"

mv "$COLLECTION" "$OUTPUT"
COLLECTION=""
trap - EXIT
echo "LIVE-0 evidence: $OUTPUT"
exit "$SCORE_STATUS"
