#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE=""
VERSION=""
BUILD=""
RUNS=3
DURATION=60
IDLE_DURATION=30
OUTPUT=""

usage() {
    cat >&2 <<'EOF'
usage: scripts/run-resource-recording-baseline.sh \
  --profile <memory-8gb|memory-16gb|reference> \
  --version <version> --build <build> \
  [--runs <count>] [--duration <seconds>] [--idle-duration <seconds>] \
  [--output <directory>]
EOF
}

fail() {
    echo "resource recording baseline error: $*" >&2
    exit 64
}

require_unsigned_integer() {
    local value="$1"
    local label="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || fail "$label must be an integer"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            PROFILE="$2"
            shift 2
            ;;
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
        --duration)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            DURATION="$2"
            shift 2
            ;;
        --idle-duration)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            IDLE_DURATION="$2"
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

[[ -n "$PROFILE" ]] || fail "--profile is required"
[[ -n "$VERSION" ]] || fail "--version is required"
[[ -n "$BUILD" ]] || fail "--build is required"
require_unsigned_integer "$RUNS" "--runs"
require_unsigned_integer "$DURATION" "--duration"
require_unsigned_integer "$IDLE_DURATION" "--idle-duration"
(( RUNS >= 3 )) || fail "--runs must be at least 3"
(( RUNS <= 100 )) || fail "--runs must be at most 100"
(( DURATION >= 30 )) || fail "--duration must be at least 30 seconds"
(( IDLE_DURATION >= 10 )) || fail "--idle-duration must be at least 10 seconds"
(( IDLE_DURATION <= 600 )) || fail "--idle-duration must be at most 600 seconds"

cd "$ROOT"
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    fail "the worktree must be clean so the receipt matches one exact commit"
fi
COMMIT="$(git rev-parse HEAD)"
SHORT_COMMIT="${COMMIT:0:12}"
OUTPUT="${OUTPUT:-$ROOT/dist/resource-baseline/$PROFILE-$SHORT_COMMIT}"
if [[ -e "$OUTPUT" ]]; then
    fail "output already exists: $OUTPUT"
fi

umask 077
mkdir -p "$(dirname "$OUTPUT")"
COLLECTION="$(mktemp -d "$OUTPUT.partial.XXXXXX")"
mkdir -p "$COLLECTION/fragments"
RUN_ROOT="$(mktemp -d /private/tmp/portavoz-resource-baseline.XXXXXX)"
APP="$RUN_ROOT/Portavoz Resource Bench.app"
SIGN_ID="${PORTAVOZ_SIGN_IDENTITY:--}"

cleanup() {
    if [[ -n "${COLLECTION:-}" && -d "$COLLECTION" ]]; then
        rm -rf "$COLLECTION"
    fi
    if [[ "${PORTAVOZ_KEEP_RESOURCE_BENCH:-0}" != "1" ]]; then
        rm -rf "$RUN_ROOT"
    else
        echo "Resource benchmark scratch retained at: $RUN_ROOT"
    fi
}
trap cleanup EXIT

PORTAVOZ_SIGN_IDENTITY="$SIGN_ID" \
    scripts/make-app.sh --release --version "$VERSION" --build "$BUILD"
cp -R "$ROOT/dist/Portavoz.app" "$APP"
plutil -replace CFBundleDisplayName -string "Portavoz Resource Bench" \
    "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "Portavoz Resource Bench" \
    "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "app.portavoz.mac.resource-bench" \
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

fragments="$COLLECTION/fragments"
sample_arguments=()
for ((run = 1; run <= RUNS; run++)); do
    audio_root="$RUN_ROOT/audio-$run"
    log="$RUN_ROOT/run-$run.log"
    mkdir -p "$audio_root"
    export PORTAVOZ_AUDIO_ROOT="$audio_root"

    echo "Collecting idle/recording/Stop resource sample $run of $RUNS…"
    open -W -n "$APP" --args \
        -ApplePersistenceIgnoreState YES \
        -use-temp-store \
        --bench-record "$DURATION" \
        --bench-resource-output "$fragments" \
        --bench-resource-run "$run" \
        --bench-resource-idle-duration "$IDLE_DURATION" \
        --bench-log "$log"

    idle_sample="$fragments/idle-$run.json"
    recording_sample="$fragments/recording-$run.json"
    stop_sample="$fragments/stop-$run.json"
    if [[ ! -f "$idle_sample" || ! -f "$recording_sample" || ! -f "$stop_sample" ]]; then
        [[ -f "$log" ]] && cat "$log" >&2
        fail "run $run did not produce all three exact-shaped samples"
    fi
    sample_arguments+=(--sample "idle=$idle_sample")
    sample_arguments+=(--sample "recording=$recording_sample")
    sample_arguments+=(--sample "stop=$stop_sample")
done

python3 scripts/resource_baseline.py assemble \
    --version "$VERSION" \
    --build "$BUILD" \
    --commit "$COMMIT" \
    --profile "$PROFILE" \
    "${sample_arguments[@]}" \
    --output "$COLLECTION/receipt.json"

mv "$COLLECTION" "$OUTPUT"
COLLECTION=""
echo "Resource recording baseline verified: $OUTPUT/receipt.json"
