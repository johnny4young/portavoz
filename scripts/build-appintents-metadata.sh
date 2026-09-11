#!/usr/bin/env bash
# App Intents metadata for the SPM-built app (D139).
#
# Xcode extracts App Intents metadata during its own build; SwiftPM has no
# equivalent step, which is why GAPS #10 believed intents required "the
# future Xcode app target". They do not: appintentsmetadataprocessor only
# needs per-file .swiftconstvalues plus a source list, and both can be
# produced out of band as long as the intents file compiles standalone.
#
# The contract this rests on (enforced by ArchitectureDependencyTests):
# Sources/portavoz-app/PortavozAppIntents.swift imports ONLY SDK frameworks,
# so one `swiftc -c` with the SHIPPING module name (portavoz_app) can emit
# the const values without reproducing the whole SwiftPM build graph.
#
# Usage: scripts/build-appintents-metadata.sh <resources-dir> [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RESOURCES_DIR="${1:?usage: build-appintents-metadata.sh <resources-dir> [config]}"
INTENTS_SOURCE="Sources/portavoz-app/PortavozAppIntents.swift"
DEPLOYMENT_TARGET="14.4"

# Follow the active toolchain (DEVELOPER_DIR, else xcode-select) so the
# script works with Xcode-beta or nonstandard installs; the existence check
# below catches a Command Line Tools-only selection with a clear message.
DEVELOPER="${DEVELOPER_DIR:-$(xcode-select -p)}"
TOOLCHAIN="$DEVELOPER/Toolchains/XcodeDefault.xctoolchain"
PROCESSOR="$TOOLCHAIN/usr/bin/appintentsmetadataprocessor"
PROTOCOLS_SOURCE="$TOOLCHAIN/usr/share/swift/SwiftConstantValues/AppIntents.json"
if [[ ! -x "$PROCESSOR" || ! -f "$PROTOCOLS_SOURCE" ]]; then
  echo "error: the selected developer dir ($DEVELOPER) has no appintentsmetadataprocessor or protocol list; select a full Xcode (xcode-select or DEVELOPER_DIR)." >&2
  exit 69
fi

SDK="$(xcrun --show-sdk-path --sdk macosx)"
XCODE_BUILD="$(xcodebuild -version | tail -1 | awk '{print $3}')"
WORK="$(mktemp -d /tmp/portavoz-appintents.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# The frontend wants a flat protocol array; the toolchain file wraps it.
python3 - "$PROTOCOLS_SOURCE" "$WORK/protocols.json" <<'PY'
import json, sys
declared = json.load(open(sys.argv[1]))
json.dump(declared["constValueProtocols"], open(sys.argv[2], "w"))
PY

# One standalone compile of the SDK-only intents file, under the SHIPPING
# module name so the metadata matches the SwiftPM binary's mangled names.
xcrun swiftc -c "$INTENTS_SOURCE" \
  -sdk "$SDK" -target "arm64-apple-macos$DEPLOYMENT_TARGET" \
  -module-name portavoz_app \
  -o "$WORK/intents.o" \
  -emit-const-values-path "$WORK/intents.swiftconstvalues" \
  -Xfrontend -const-gather-protocols-file \
  -Xfrontend "$WORK/protocols.json"

printf '%s\n' "$ROOT/$INTENTS_SOURCE" > "$WORK/sources.txt"
printf '%s\n' "$WORK/intents.swiftconstvalues" > "$WORK/constvals.txt"

"$PROCESSOR" \
  --output "$WORK/out" \
  --toolchain-dir "$TOOLCHAIN" \
  --module-name portavoz_app \
  --sdk-root "$SDK" \
  --xcode-version "$XCODE_BUILD" \
  --platform-family macOS \
  --deployment-target "$DEPLOYMENT_TARGET" \
  --target-triple "arm64-apple-macos$DEPLOYMENT_TARGET" \
  --source-file-list "$WORK/sources.txt" \
  --swift-const-vals-list "$WORK/constvals.txt" \
  --force --quiet-warnings > /dev/null

if [[ ! -f "$WORK/out/Metadata.appintents/extract.actionsdata" ]]; then
  echo "error: appintentsmetadataprocessor produced no actionsdata." >&2
  exit 70
fi
# The extraction must carry exactly the native action and entity surface needed on macOS.
# App Shortcuts are not a supported macOS product surface; emitting one beside
# the raw action produces two identically titled rows in the action picker.
python3 - "$WORK/out/Metadata.appintents/extract.actionsdata" <<'PY'
import json, sys
metadata = json.load(open(sys.argv[1]))
actions = metadata.get("actions") or {}
expected_actions = {
    "OpenCommitmentIntent",
    "OpenMeetingIntent",
    "ShowPersonCommitmentsIntent",
    "StartRecordingIntent",
    "StopRecordingIntent",
}
actual_actions = set(actions)
if actual_actions != expected_actions:
    raise SystemExit(
        "error: extracted App Intents metadata actions differ: "
        f"expected {sorted(expected_actions)}, got {sorted(actual_actions)}")
expected_entities = {
    "PortavozCommitmentEntity",
    "PortavozMeetingEntity",
    "PortavozPersonEntity",
}
actual_entities = set(metadata.get("entities") or {})
if actual_entities != expected_entities:
    raise SystemExit(
        "error: extracted App Intents metadata entities differ: "
        f"expected {sorted(expected_entities)}, got {sorted(actual_entities)}")
expected_queries = {
    "PortavozCommitmentEntityQuery",
    "PortavozMeetingEntityQuery",
    "PortavozPersonEntityQuery",
}
actual_queries = set(metadata.get("queries") or {})
if actual_queries != expected_queries:
    raise SystemExit(
        "error: extracted App Intents metadata queries differ: "
        f"expected {sorted(expected_queries)}, got {sorted(actual_queries)}")
if metadata.get("autoShortcuts"):
    raise SystemExit(
        "error: macOS metadata must not publish unsupported App Shortcuts")
print(
    "App Intents metadata: "
    f"{len(actual_actions)} actions, "
    f"{len(actual_entities)} entities, "
    f"{len(actual_queries)} queries")
PY

rm -rf "$RESOURCES_DIR/Metadata.appintents"
cp -R "$WORK/out/Metadata.appintents" "$RESOURCES_DIR/"
