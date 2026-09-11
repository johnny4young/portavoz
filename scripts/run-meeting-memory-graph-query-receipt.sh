#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=""
BUILD=""
RUNS=3
ITERATIONS=31
OUTPUT=""

usage() {
    cat >&2 <<'EOF'
usage: scripts/run-meeting-memory-graph-query-receipt.sh \
  --version <version> --build <build> \
  [--runs <3...100>] [--iterations <5...1000>] \
  [--output <directory>]
EOF
}

fail() {
    echo "graph query receipt error: $*" >&2
    exit 64
}

require_unsigned_integer() {
    local value="$1"
    local label="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || fail "$label must be an integer"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            VERSION="$2"
            shift 2
            ;;
        --build)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            BUILD="$2"
            shift 2
            ;;
        --runs)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            RUNS="$2"
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

[[ -n "$VERSION" ]] || fail "--version is required"
[[ -n "$BUILD" ]] || fail "--build is required"
require_unsigned_integer "$RUNS" "--runs"
require_unsigned_integer "$ITERATIONS" "--iterations"
(( RUNS >= 3 && RUNS <= 100 )) || fail "--runs must be between 3 and 100"
(( ITERATIONS >= 5 && ITERATIONS <= 1000 )) || \
    fail "--iterations must be between 5 and 1000"
SIGN_ID="${PORTAVOZ_SIGN_IDENTITY:-}"
[[ -n "$SIGN_ID" && "$SIGN_ID" != "-" ]] || \
    fail "PORTAVOZ_SIGN_IDENTITY must select a real Developer ID identity;" \
        "ad-hoc signing cannot satisfy hardened-runtime library validation"

cd "$ROOT"
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    fail "the worktree must be clean so the receipt matches one exact commit"
fi
COMMIT="$(git rev-parse HEAD)"
SHORT_COMMIT="${COMMIT:0:12}"
OUTPUT="${OUTPUT:-$ROOT/dist/meeting-memory-graph-query/$SHORT_COMMIT}"
if [[ "$OUTPUT" != /* ]]; then
    OUTPUT="$ROOT/$OUTPUT"
fi
[[ ! -e "$OUTPUT" ]] || fail "output already exists: $OUTPUT"

umask 077
mkdir -p "$(dirname "$OUTPUT")"
COLLECTION="$(mktemp -d "$OUTPUT.partial.XXXXXX")"
FRAGMENTS="$COLLECTION/fragments"
mkdir -p "$FRAGMENTS"
RUN_ROOT="$(mktemp -d /private/tmp/portavoz-graph-query.XXXXXX)"
APP="$RUN_ROOT/Portavoz Graph Query Bench.app"

cleanup() {
    if [[ -n "${COLLECTION:-}" && -d "$COLLECTION" ]]; then
        rm -rf "$COLLECTION"
    fi
    if [[ "${PORTAVOZ_KEEP_GRAPH_QUERY_BENCH:-0}" != "1" ]]; then
        rm -rf "$RUN_ROOT"
    else
        echo "Graph query benchmark scratch retained at: $RUN_ROOT"
    fi
}
trap cleanup EXIT

PORTAVOZ_SIGN_IDENTITY="$SIGN_ID" \
    scripts/make-app.sh --release --version "$VERSION" --build "$BUILD"
cp -R "$ROOT/dist/Portavoz.app" "$APP"
plutil -replace CFBundleDisplayName -string "Portavoz Graph Query Bench" \
    "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "Portavoz Graph Query Bench" \
    "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier \
    -string "app.portavoz.mac.graph-query-bench" \
    "$APP/Contents/Info.plist"

ENTITLEMENTS="$(cat "$ROOT/dist/.portavoz-sign-entitlements")"
sign_arguments=(
    --force
    --options runtime
    --sign "$SIGN_ID"
    --entitlements "$ROOT/$ENTITLEMENTS"
)
if [[ "$SIGN_ID" != "-" ]]; then
    sign_arguments+=(--timestamp)
fi
codesign "${sign_arguments[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

fragment_arguments=()
for ((run = 1; run <= RUNS; run++)); do
    fragment="$FRAGMENTS/run-$run.json"
    echo "Collecting graph query product timing run $run of ${RUNS}…"
    if ! open -W -n "$APP" --args \
            -ApplePersistenceIgnoreState YES \
            -use-temp-store \
            -seed-demo \
            -seed-ask-memory \
            -seed-ask-topic-memory \
            --bench-graph-queries \
            --bench-graph-output "$fragment" \
            --bench-graph-run "$run" \
            --bench-graph-iterations "$ITERATIONS"
    then
        fail "graph query product timing run $run failed"
    fi
    [[ -f "$fragment" ]] || fail "run $run did not produce a fragment"
    fragment_arguments+=(--fragment "$fragment")
done

python3 scripts/meeting_memory_graph_query_receipt.py \
    "${fragment_arguments[@]}" \
    --version "$VERSION" \
    --build "$BUILD" \
    --commit "$COMMIT" \
    --output "$COLLECTION/meeting-memory-graph-query-receipt.json"
rm -rf "$FRAGMENTS"
mv "$COLLECTION" "$OUTPUT"
COLLECTION=""
trap - EXIT
rm -rf "$RUN_ROOT"

echo "Graph query product timing receipt: $OUTPUT"
