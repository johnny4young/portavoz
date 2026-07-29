#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE=""
VERSION=""
BUILD=""
RUNS=3
DURATION=60
IDLE_DURATION=30
MODEL_TIMEOUT=900
OUTPUT=""

usage() {
    cat >&2 <<'EOF'
usage: scripts/run-resource-baseline.sh \
  --profile <memory-8gb|memory-16gb|reference> \
  --version <version> --build <build> \
  [--runs <count>] [--duration <seconds>] [--idle-duration <seconds>] \
  [--model-timeout <seconds>] \
  [--output <directory>]
EOF
}

fail() {
    echo "resource baseline error: $*" >&2
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
        --model-timeout)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            MODEL_TIMEOUT="$2"
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
require_unsigned_integer "$MODEL_TIMEOUT" "--model-timeout"
(( RUNS >= 3 )) || fail "--runs must be at least 3"
(( RUNS <= 100 )) || fail "--runs must be at most 100"
(( DURATION >= 30 )) || fail "--duration must be at least 30 seconds"
(( IDLE_DURATION >= 10 )) || fail "--idle-duration must be at least 10 seconds"
(( IDLE_DURATION <= 600 )) || fail "--idle-duration must be at most 600 seconds"
(( MODEL_TIMEOUT >= 60 )) || fail "--model-timeout must be at least 60 seconds"
(( MODEL_TIMEOUT <= 3600 )) || fail "--model-timeout must be at most 3600 seconds"

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

fixture_text="$RUN_ROOT/refine-fixture.txt"
fixture_audio="$RUN_ROOT/refine-fixture.aiff"
if ! say -v '?' | grep -Eq '^Samantha[[:space:]]'; then
    fail "the Samantha system voice is required for the fixed Refine fixture"
fi
cat > "$fixture_text" <<'EOF'
Welcome to the Portavoz resource benchmark. This synthetic meeting contains
only public, repeatable text and never reads a user recording. The team reviews
a small product launch and confirms the plan for the next release. Jordan will
verify the installer on an eight gigabyte Mac. Casey will measure startup time
and memory on a sixteen gigabyte Mac. Morgan will repeat the same checks on the
reference machine. The group agrees that recording must remain responsive while
background work waits safely. They also decide that transcripts must preserve
the language spoken by each participant. Before publishing, the team will
compare three stable runs, inspect unexpected thermal changes, and confirm that
no private content appears in the evidence. The final action is to document any
blocked scenario rather than invent a passing result. This concludes the
synthetic meeting used to exercise quality transcription and speaker
diarization.
EOF
say -v Samantha -r 170 -o "$fixture_audio" -f "$fixture_text"
fixture_audio_bytes="$(
    afinfo "$fixture_audio" |
        awk -F: '/audio bytes/ && !found {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            print $2
            found = 1
        }'
)"
require_unsigned_integer "$fixture_audio_bytes" "Refine fixture audio bytes"
(( fixture_audio_bytes > 0 )) ||
    fail "the generated Refine fixture contains no audio bytes"

fragments="$COLLECTION/fragments"
sample_arguments=()
for ((run = 1; run <= RUNS; run++)); do
    audio_root="$RUN_ROOT/audio-$run"
    recording_indexing_audio_root="$RUN_ROOT/audio-recording-indexing-$run"
    recording_batch_audio_root="$RUN_ROOT/audio-recording-batch-$run"
    recording_log="$RUN_ROOT/recording-$run.log"
    recording_indexing_log="$RUN_ROOT/recording-indexing-$run.log"
    recording_batch_log="$RUN_ROOT/recording-batch-$run.log"
    refine_log="$RUN_ROOT/refine-$run.log"
    summary_log="$RUN_ROOT/summary-$run.log"
    ask_log="$RUN_ROOT/ask-$run.log"
    indexing_log="$RUN_ROOT/indexing-$run.log"
    mkdir -p "$audio_root"
    export PORTAVOZ_AUDIO_ROOT="$audio_root"

    echo "Collecting idle/recording/Stop resource sample $run of ${RUNS}…"
    if ! open -W -n "$APP" --args \
            -ApplePersistenceIgnoreState YES \
            -use-temp-store \
            --bench-record "$DURATION" \
            --bench-resource-output "$fragments" \
            --bench-resource-run "$run" \
            --bench-resource-idle-duration "$IDLE_DURATION" \
            --bench-log "$recording_log"
    then
        [[ -f "$recording_log" ]] && cat "$recording_log" >&2
        fail "idle/recording/Stop run $run failed"
    fi

    idle_sample="$fragments/idle-$run.json"
    recording_sample="$fragments/recording-$run.json"
    stop_sample="$fragments/stop-$run.json"
    if [[ ! -f "$idle_sample" || ! -f "$recording_sample" || ! -f "$stop_sample" ]]; then
        [[ -f "$recording_log" ]] && cat "$recording_log" >&2
        fail "run $run did not produce all three exact-shaped samples"
    fi

    echo "Collecting recording plus indexing resource sample $run of ${RUNS}…"
    mkdir -p "$recording_indexing_audio_root"
    export PORTAVOZ_AUDIO_ROOT="$recording_indexing_audio_root"
    if ! open -W -n "$APP" --args \
            -ApplePersistenceIgnoreState YES \
            -use-temp-store \
            --bench-record "$DURATION" \
            --bench-resource-recording-indexing \
            --bench-resource-output "$fragments" \
            --bench-resource-run "$run" \
            --bench-resource-timeout "$MODEL_TIMEOUT" \
            --bench-log "$recording_indexing_log"
    then
        [[ -f "$recording_indexing_log" ]] &&
            cat "$recording_indexing_log" >&2
        fail "recording plus indexing run $run failed"
    fi

    recording_indexing_sample="$fragments/recording-indexing-$run.json"
    if [[ ! -f "$recording_indexing_sample" ]]; then
        [[ -f "$recording_indexing_log" ]] &&
            cat "$recording_indexing_log" >&2
        fail "run $run did not produce the recording plus indexing sample"
    fi

    echo "Collecting recording plus batch resource sample $run of ${RUNS}…"
    mkdir -p "$recording_batch_audio_root"
    export PORTAVOZ_AUDIO_ROOT="$recording_batch_audio_root"
    if ! open -W -n "$APP" --args \
            -ApplePersistenceIgnoreState YES \
            -use-temp-store \
            --bench-record "$DURATION" \
            --bench-resource-recording-batch "$fixture_audio" \
            --bench-resource-output "$fragments" \
            --bench-resource-run "$run" \
            --bench-resource-timeout "$MODEL_TIMEOUT" \
            --bench-log "$recording_batch_log"
    then
        [[ -f "$recording_batch_log" ]] &&
            cat "$recording_batch_log" >&2
        fail "recording plus batch run $run failed"
    fi

    recording_batch_sample="$fragments/recording-batch-$run.json"
    if [[ ! -f "$recording_batch_sample" ]]; then
        [[ -f "$recording_batch_log" ]] &&
            cat "$recording_batch_log" >&2
        fail "run $run did not produce the recording plus batch sample"
    fi

    echo "Collecting Refine resource sample $run of ${RUNS}…"
    if ! "$APP/Contents/MacOS/portavoz-app" \
        -ApplePersistenceIgnoreState YES \
        -use-temp-store \
        --bench-resource-refine "$fixture_audio" \
        --bench-resource-output "$fragments" \
        --bench-resource-run "$run" \
        --bench-resource-timeout "$MODEL_TIMEOUT" \
        --bench-log "$refine_log"
    then
        [[ -f "$refine_log" ]] && cat "$refine_log" >&2
        fail "Refine run $run failed"
    fi

    refine_sample="$fragments/refine-$run.json"
    if [[ ! -f "$refine_sample" ]]; then
        [[ -f "$refine_log" ]] && cat "$refine_log" >&2
        fail "run $run did not produce the exact-shaped Refine sample"
    fi

    echo "Collecting Summary resource sample $run of ${RUNS}…"
    if ! "$APP/Contents/MacOS/portavoz-app" \
        -ApplePersistenceIgnoreState YES \
        -use-temp-store \
        --bench-resource-summary \
        --bench-resource-output "$fragments" \
        --bench-resource-run "$run" \
        --bench-resource-timeout "$MODEL_TIMEOUT" \
        --bench-log "$summary_log"
    then
        [[ -f "$summary_log" ]] && cat "$summary_log" >&2
        fail "Summary run $run failed"
    fi

    summary_sample="$fragments/summary-$run.json"
    if [[ ! -f "$summary_sample" ]]; then
        [[ -f "$summary_log" ]] && cat "$summary_log" >&2
        fail "run $run did not produce the exact-shaped Summary sample"
    fi

    echo "Collecting Ask resource sample $run of ${RUNS}…"
    if ! "$APP/Contents/MacOS/portavoz-app" \
        -ApplePersistenceIgnoreState YES \
        -use-temp-store \
        --bench-resource-ask \
        --bench-resource-output "$fragments" \
        --bench-resource-run "$run" \
        --bench-resource-timeout "$MODEL_TIMEOUT" \
        --bench-log "$ask_log"
    then
        [[ -f "$ask_log" ]] && cat "$ask_log" >&2
        fail "Ask run $run failed"
    fi

    ask_sample="$fragments/ask-$run.json"
    if [[ ! -f "$ask_sample" ]]; then
        [[ -f "$ask_log" ]] && cat "$ask_log" >&2
        fail "run $run did not produce the exact-shaped Ask sample"
    fi

    echo "Collecting semantic indexing resource sample $run of ${RUNS}…"
    if ! "$APP/Contents/MacOS/portavoz-app" \
        -ApplePersistenceIgnoreState YES \
        -use-temp-store \
        --bench-resource-indexing \
        --bench-resource-output "$fragments" \
        --bench-resource-run "$run" \
        --bench-resource-timeout "$MODEL_TIMEOUT" \
        --bench-log "$indexing_log"
    then
        [[ -f "$indexing_log" ]] && cat "$indexing_log" >&2
        fail "indexing run $run failed"
    fi

    indexing_sample="$fragments/indexing-$run.json"
    if [[ ! -f "$indexing_sample" ]]; then
        [[ -f "$indexing_log" ]] && cat "$indexing_log" >&2
        fail "run $run did not produce the exact-shaped indexing sample"
    fi
    sample_arguments+=(--sample "ask=$ask_sample")
    sample_arguments+=(--sample "idle=$idle_sample")
    sample_arguments+=(--sample "indexing=$indexing_sample")
    sample_arguments+=(--sample "recording=$recording_sample")
    sample_arguments+=(
        --sample "recording-indexing=$recording_indexing_sample"
    )
    sample_arguments+=(
        --sample "recording-batch=$recording_batch_sample"
    )
    sample_arguments+=(--sample "refine=$refine_sample")
    sample_arguments+=(--sample "summary=$summary_sample")
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
echo "Resource baseline verified: $OUTPUT/receipt.json"
