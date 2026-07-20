#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/private/tmp}/portavoz-sandbox-spike.XXXXXX")"
LEGACY_DIRECTORY="$(mktemp -d "$HOME/Library/Application Support/PortavozSandboxSpikeLegacy.XXXXXX")"
SERVER_PID=""

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK" "$LEGACY_DIRECTORY"
}
trap cleanup EXIT

APP="$WORK/Portavoz Sandbox Capability Probe.app"
CONTROL_APP="$WORK/Portavoz Non-Sandbox Control.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
EXECUTABLE="$MACOS/SandboxCapabilityProbe"
IDENTITY="${PORTAVOZ_SIGN_IDENTITY:--}"
OUTPUT="${1:-/private/tmp/portavoz-sandbox-capability-spike.json}"
SANDBOX_OUTPUT="$WORK/sandboxed.json"
CONTROL_OUTPUT="$WORK/non-sandboxed-control.json"
PORT="${PORTAVOZ_SANDBOX_SPIKE_PORT:-48761}"

mkdir -p "$MACOS" "$RESOURCES" "$(dirname "$OUTPUT")"
printf 'portavoz-sandbox-probe\n' > "$WORK/health"
printf 'outside-container-sentinel\n' > "$LEGACY_DIRECTORY/sentinel.txt"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>SandboxCapabilityProbe</string>
    <key>CFBundleIdentifier</key>
    <string>app.portavoz.sandbox-capability-probe</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Portavoz Sandbox Capability Probe</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Measures Core Audio process-tap compatibility for Portavoz.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Measures EventKit compatibility for Portavoz.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Measures microphone entitlement compatibility for Portavoz.</string>
</dict>
</plist>
PLIST

xcrun swiftc \
    -parse-as-library \
    -swift-version 6 \
    -target "$(uname -m)-apple-macos14.4" \
    "$ROOT/scripts/sandbox-spike/SandboxCapabilityProbe.swift" \
    -framework ApplicationServices \
    -framework AVFAudio \
    -framework Carbon \
    -framework CoreAudio \
    -framework EventKit \
    -framework Security \
    -o "$EXECUTABLE"

cp -a "$APP" "$CONTROL_APP"
codesign --force --sign "$IDENTITY" --options runtime \
    --entitlements "$ROOT/scripts/sandbox-spike/probe.entitlements" \
    "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --force --sign "$IDENTITY" --options runtime \
    --entitlements "$ROOT/packaging/portavoz.entitlements" \
    "$CONTROL_APP"
codesign --verify --deep --strict --verbose=2 "$CONTROL_APP"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK" \
    > "$WORK/http-server.log" 2>&1 &
SERVER_PID=$!
for _ in {1..40}; do
    if curl --fail --silent "http://127.0.0.1:$PORT/health" >/dev/null; then
        break
    fi
    sleep 0.05
done
curl --fail --silent "http://127.0.0.1:$PORT/health" >/dev/null

"$EXECUTABLE" \
    --legacy-directory "$LEGACY_DIRECTORY" \
    --network-url "http://127.0.0.1:$PORT/health" \
    > "$SANDBOX_OUTPUT"

set +e
"$CONTROL_APP/Contents/MacOS/SandboxCapabilityProbe" \
    --legacy-directory "$LEGACY_DIRECTORY" \
    --network-url "http://127.0.0.1:$PORT/health" \
    > "$CONTROL_OUTPUT"
CONTROL_STATUS=$?
set -e
if [[ "$CONTROL_STATUS" -ne 1 ]]; then
    echo "error: the non-sandboxed control returned unexpected status $CONTROL_STATUS" >&2
    exit 1
fi

python3 - "$SANDBOX_OUTPUT" "$CONTROL_OUTPUT" "$OUTPUT" "$IDENTITY" <<'PY'
import json
import pathlib
import sys

sandboxed = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
control = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
if sandboxed.get("sandboxEnforcementObserved") is not True:
    raise SystemExit("error: the probe did not observe an enforced App Sandbox profile")
if control.get("sandboxEnforcementObserved") is not False:
    raise SystemExit("error: the non-sandboxed control unexpectedly observed App Sandbox")
report = {
    "schemaVersion": 1,
    "signingMode": "ad-hoc" if sys.argv[4] == "-" else "developer-id",
    "sandboxed": sandboxed,
    "nonSandboxedControl": control,
}
pathlib.Path(sys.argv[3]).write_text(
    json.dumps(report, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

echo "Sandbox capability evidence: $OUTPUT"
