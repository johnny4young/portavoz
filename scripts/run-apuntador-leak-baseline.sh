#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=""
BUILD=""
OUTPUT=""
ITERATIONS=5
TIMEOUT_SECONDS="${PORTAVOZ_LEAK_TIMEOUT_SECONDS:-1200}"

usage() {
    cat >&2 <<'EOF'
usage: scripts/run-apuntador-leak-baseline.sh \
  --version <version> --build <build> \
  [--live-assist-iterations 5] [--output <directory>]
EOF
}

fail() {
    echo "apuntador leak baseline error: $*" >&2
    exit 64
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
        --live-assist-iterations)
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

[[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,95}$ ]] || \
    fail "--version must be a safe release identity"
[[ "$BUILD" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,95}$ ]] || \
    fail "--build must be a safe release identity"
[[ "$ITERATIONS" == "5" ]] || \
    fail "--live-assist-iterations must match the fixed value 5"
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || \
    fail "PORTAVOZ_LEAK_TIMEOUT_SECONDS must be an integer"
(( TIMEOUT_SECONDS >= 60 && TIMEOUT_SECONDS <= 7200 )) || \
    fail "PORTAVOZ_LEAK_TIMEOUT_SECONDS must be between 60 and 7200"

cd "$ROOT"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || \
    fail "the worktree must be clean so leak evidence binds one exact source"
COMMIT="$(git rev-parse HEAD)"
SHORT_COMMIT="${COMMIT:0:12}"
OUTPUT="${OUTPUT:-$ROOT/dist/apuntador-leaks/$SHORT_COMMIT}"
if [[ "$OUTPUT" != /* ]]; then
    OUTPUT="$ROOT/$OUTPUT"
fi
[[ ! -e "$OUTPUT" ]] || fail "output already exists: $OUTPUT"

xcrun --find leaks >/dev/null || fail "the Xcode leaks tool is unavailable"

umask 077
mkdir -p "$(dirname "$OUTPUT")"
COLLECTION="$(mktemp -d "$OUTPUT.partial.XXXXXX")"
RUN_ROOT="$(mktemp -d /private/tmp/portavoz-apuntador-leaks.XXXXXX)"
APP="$RUN_ROOT/Portavoz Leak Bench.app"
APP_EXECUTABLE="$APP/Contents/MacOS/portavoz-app"
ACTIVE_PID=""
GUARD_PID=""
TIMED_OUT_MARKER=""
LEAK_LOG=""

terminate_probe_processes() {
    local process_id
    while IFS= read -r process_id; do
        if [[ "$process_id" =~ ^[0-9]+$ ]]; then
            kill -TERM "$process_id" 2>/dev/null || true
        fi
    done < <(pgrep -f -- "$APP_EXECUTABLE" || true)
}

cleanup() {
    if [[ -n "$GUARD_PID" ]]; then
        kill -TERM "$GUARD_PID" 2>/dev/null || true
    fi
    # Match the private executable path as well as the owned wrapper PID so an
    # interrupted parent cannot leave the disposable app behind.
    terminate_probe_processes
    if [[ -n "$ACTIVE_PID" ]]; then
        kill -TERM "$ACTIVE_PID" 2>/dev/null || true
    fi
    if [[ -n "${COLLECTION:-}" && -d "$COLLECTION" ]]; then
        rm -rf "$COLLECTION"
    fi
    if [[ "${PORTAVOZ_KEEP_LEAK_BENCH:-0}" != "1" ]]; then
        rm -rf "$RUN_ROOT"
    else
        echo "Leak benchmark scratch retained at: $RUN_ROOT" >&2
    fi
}
trap cleanup EXIT

PORTAVOZ_SIGN_IDENTITY="-" \
    scripts/make-app.sh --release --version "$VERSION" --build "$BUILD"
cp -R "$ROOT/dist/Portavoz.app" "$APP"
plutil -replace CFBundleDisplayName -string "Portavoz Leak Bench" \
    "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "Portavoz Leak Bench" \
    "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "app.portavoz.mac.leak-bench" \
    "$APP/Contents/Info.plist"
codesign --force --options runtime --sign - \
    --entitlements "$ROOT/packaging/portavoz-resource-bench.entitlements" \
    "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

SIGNED_ENTITLEMENTS="$RUN_ROOT/signed-entitlements.plist"
codesign -d --entitlements :- "$APP" >"$SIGNED_ENTITLEMENTS" 2>/dev/null
python3 - "$SIGNED_ENTITLEMENTS" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    entitlements = plistlib.load(handle)
if entitlements.get("com.apple.security.cs.disable-library-validation") is not True:
    raise SystemExit("the disposable leak app lacks its benchmark-only entitlement")
PY

run_under_leaks() {
    local scenario="$1"
    shift
    local log="$RUN_ROOT/$scenario.leaks.log"
    local guard_timeout=$((TIMEOUT_SECONDS + 5))
    local run_status
    TIMED_OUT_MARKER="$RUN_ROOT/$scenario.timed-out"

    xcrun leaks -q --noContent --nostacks --atExit -- \
        "$APP_EXECUTABLE" "$@" >"$log" 2>&1 &
    ACTIVE_PID=$!
    (
        sleep "$guard_timeout"
        if kill -0 "$ACTIVE_PID" 2>/dev/null; then
            printf 'timed-out\n' >"$TIMED_OUT_MARKER"
            terminate_probe_processes
            kill -TERM "$ACTIVE_PID" 2>/dev/null || true
            sleep 5
            terminate_probe_processes
            kill -KILL "$ACTIVE_PID" 2>/dev/null || true
        fi
    ) &
    GUARD_PID=$!
    set +e
    wait "$ACTIVE_PID"
    run_status=$?
    set -e
    ACTIVE_PID=""
    kill -TERM "$GUARD_PID" 2>/dev/null || true
    wait "$GUARD_PID" 2>/dev/null || true
    GUARD_PID=""
    [[ ! -f "$TIMED_OUT_MARKER" ]] || fail "scenario $scenario timed out"
    [[ "$run_status" -eq 0 ]] || \
        fail "scenario $scenario reported leaks or a tool/process failure"
    LEAK_LOG="$log"
}

FRAGMENTS="$COLLECTION/fragments"
mkdir -p "$FRAGMENTS"

live_released="$RUN_ROOT/live-released"
mkdir -p "$live_released"
run_under_leaks live-assist-released \
    --bench-live-assist \
    --live-assist-fixture \
    "$ROOT/Fixtures/LiveAssistValidation/public-bilingual-v1.json" \
    --live-assist-output "$live_released/observations.json" \
    --live-assist-adapter released-prefilter \
    --live-assist-commit "$COMMIT" \
    --live-assist-build "$BUILD" \
    --live-assist-source-state clean \
    --live-assist-iterations "$ITERATIONS"
live_released_log="$LEAK_LOG"
python3 scripts/apuntador_leak_baseline.py observe \
    --scenario live-assist-released \
    --log "$live_released_log" \
    --evidence "observations=$live_released/observations.json" \
    --exit-code 0 --commit "$COMMIT" --build "$BUILD" \
    --output "$FRAGMENTS/1-live-assist-released.json"

live_bundled="$RUN_ROOT/live-bundled"
mkdir -p "$live_bundled"
run_under_leaks live-assist-bundled-question \
    --bench-live-assist \
    --live-assist-fixture \
    "$ROOT/Fixtures/LiveAssistValidation/public-bilingual-v1.json" \
    --live-assist-output "$live_bundled/observations.json" \
    --live-assist-adapter bundled-question \
    --live-assist-commit "$COMMIT" \
    --live-assist-build "$BUILD" \
    --live-assist-source-state clean \
    --live-assist-iterations "$ITERATIONS"
live_bundled_log="$LEAK_LOG"
python3 scripts/apuntador_leak_baseline.py observe \
    --scenario live-assist-bundled-question \
    --log "$live_bundled_log" \
    --evidence "observations=$live_bundled/observations.json" \
    --exit-code 0 --commit "$COMMIT" --build "$BUILD" \
    --output "$FRAGMENTS/2-live-assist-bundled-question.json"

ask_root="$RUN_ROOT/ask"
mkdir -p "$ask_root"
run_under_leaks ask \
    -ApplePersistenceIgnoreState YES \
    -use-temp-store \
    --bench-resource-ask \
    --bench-resource-output "$ask_root" \
    --bench-resource-run 1 \
    --bench-resource-timeout 900 \
    --bench-resource-process-timeout "$TIMEOUT_SECONDS"
ask_log="$LEAK_LOG"
python3 scripts/apuntador_leak_baseline.py observe \
    --scenario ask \
    --log "$ask_log" \
    --evidence "pipeline=$ask_root/ask-pipeline-1.json" \
    --evidence "resource=$ask_root/ask-1.json" \
    --exit-code 0 --commit "$COMMIT" --build "$BUILD" \
    --output "$FRAGMENTS/3-ask.json"

indexing_root="$RUN_ROOT/indexing"
mkdir -p "$indexing_root"
run_under_leaks semantic-indexing \
    -ApplePersistenceIgnoreState YES \
    -use-temp-store \
    --bench-resource-indexing \
    --bench-resource-output "$indexing_root" \
    --bench-resource-run 1 \
    --bench-resource-timeout 900 \
    --bench-resource-process-timeout "$TIMEOUT_SECONDS"
indexing_log="$LEAK_LOG"
python3 scripts/apuntador_leak_baseline.py observe \
    --scenario semantic-indexing \
    --log "$indexing_log" \
    --evidence "resource=$indexing_root/indexing-1.json" \
    --exit-code 0 --commit "$COMMIT" --build "$BUILD" \
    --output "$FRAGMENTS/4-semantic-indexing.json"

python3 scripts/apuntador_leak_baseline.py assemble \
    --version "$VERSION" --build "$BUILD" --commit "$COMMIT" \
    --fragment "$FRAGMENTS/1-live-assist-released.json" \
    --fragment "$FRAGMENTS/2-live-assist-bundled-question.json" \
    --fragment "$FRAGMENTS/3-ask.json" \
    --fragment "$FRAGMENTS/4-semantic-indexing.json" \
    --output "$COLLECTION/receipt.json"

[[ "$(git rev-parse HEAD)" == "$COMMIT" ]] || \
    fail "source HEAD changed during leak qualification"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || \
    fail "the worktree changed during leak qualification"

mv "$COLLECTION" "$OUTPUT"
COLLECTION=""
trap - EXIT
rm -rf "$RUN_ROOT"
echo "Apuntador leak baseline verified: $OUTPUT/receipt.json"
