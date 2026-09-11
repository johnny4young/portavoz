#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-/private/tmp/portavoz-detail-ui-baseline.json}"
APP="${PORTAVOZ_DEV_APP:-/Applications/Portavoz Dev.app}"
DURATION="${PORTAVOZ_DETAIL_TRACE_SECONDS:-10}"
RUN_ROOT="$(mktemp -d /private/tmp/portavoz-detail-ui-baseline.XXXXXX)"

if [[ "$APP" == "/Applications/Portavoz.app" ]]; then
    echo "error: the performance harness must never launch the notarized release copy" >&2
    exit 64
fi

APPLICATION_KIND="installed-dev-bundle"
if [[ "$APP" != "/Applications/Portavoz Dev.app" ]]; then
    APPLICATION_KIND="development-bundle-override"
fi

EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw "$APP/Contents/Info.plist")"
EXECUTABLE="$APP/Contents/MacOS/$EXECUTABLE_NAME"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "error: install the current dev bundle first with make install" >&2
    exit 66
fi

cleanup() {
    osascript -e 'tell application "Portavoz Dev" to quit' >/dev/null 2>&1 || true
    if [[ "${PORTAVOZ_KEEP_DETAIL_TRACES:-0}" != "1" ]]; then
        rm -rf "$RUN_ROOT"
    else
        echo "Detail traces retained at: $RUN_ROOT"
    fi
}
trap cleanup EXIT

record_trace() {
    local template="$1"
    local name="$2"
    local segment_count="$3"
    local interaction_flag="$4"
    local trace="$RUN_ROOT/$name.trace"
    local audio="$RUN_ROOT/$name-audio"
    local log="$RUN_ROOT/$name.log"
    local launch_arguments=(
        -ApplePersistenceIgnoreState YES
        -use-temp-store
        -seed-scale
        -scale-segments "$segment_count"
        -detail-performance-profile
        "$interaction_flag"
        -reset-app-language
    )
    # SwiftUI and hitch traces include the deterministic summary mutation so
    # they characterize invalidation work. The Logging trace isolates the
    # requested scroll/seek loop; otherwise the summary refresh cancels that
    # view task after its first sample and produces misleading evidence.
    if [[ "$template" != "Logging" ]]; then
        launch_arguments+=(-scale-auto-summary-update)
    fi
    if [[ "$interaction_flag" == "-scale-profile-seek" ]]; then
        launch_arguments+=(-scale-profile-audio)
    fi
    mkdir -p "$audio"
    osascript -e 'tell application "Portavoz Dev" to quit' >/dev/null 2>&1 || true
    sleep 1

    set +e
    xcrun xctrace record \
        --template "$template" \
        --time-limit "${DURATION}s" \
        --output "$trace" \
        --env "PORTAVOZ_AUDIO_ROOT=$audio" \
        --launch -- "$EXECUTABLE" "${launch_arguments[@]}" >"$log" 2>&1
    local status=$?
    set -e
    # xctrace returns 54 when the requested time limit terminates the app.
    if [[ $status -ne 0 && $status -ne 54 ]]; then
        cat "$log" >&2
        return "$status"
    fi
}

export_table() {
    local trace="$1"
    local schema="$2"
    local output="$3"
    xcrun xctrace export \
        --input "$trace" \
        --xpath "/trace-toc/run[@number='1']/data/table[@schema='$schema']" \
        --output "$output" >/dev/null
}

capture_profile() {
    local slug="$1"
    local segments="$2"
    local interaction="$3"

    record_trace SwiftUI "$slug-swiftui" "$segments" "$interaction"
    record_trace "Animation Hitches" "$slug-hitches" "$segments" "$interaction"
    record_trace Logging "$slug-logging" "$segments" "$interaction"

    export_table \
        "$RUN_ROOT/$slug-swiftui.trace" swiftui-updates \
        "$RUN_ROOT/$slug-swiftui-updates.xml"
    export_table \
        "$RUN_ROOT/$slug-swiftui.trace" time-profile \
        "$RUN_ROOT/$slug-time-profile.xml"
    export_table \
        "$RUN_ROOT/$slug-hitches.trace" hitches \
        "$RUN_ROOT/$slug-hitches.xml"
    export_table \
        "$RUN_ROOT/$slug-hitches.trace" potential-hangs \
        "$RUN_ROOT/$slug-potential-hangs.xml"
    export_table \
        "$RUN_ROOT/$slug-logging.trace" os-signpost-interval \
        "$RUN_ROOT/$slug-os-signpost-interval.xml"
}

capture_profile five-thousand 5000 -scale-profile-seek
capture_profile twenty-thousand 20000 -scale-profile-scroll

xcodebuild -version >"$RUN_ROOT/xcode-version.txt"
xcrun xctrace version >"$RUN_ROOT/xctrace-version.txt"
sw_vers >"$RUN_ROOT/sw-vers.txt"

mkdir -p "$(dirname "$OUTPUT")"
python3 "$ROOT/scripts/meeting_detail_performance.py" \
    --input "$RUN_ROOT" \
    --output "$OUTPUT" \
    --trace-duration "$DURATION" \
    --application-kind "$APPLICATION_KIND"
