#!/usr/bin/env bash
# App Intents metadata for the SPM-built app (FEATURE-001/D139).
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
# The extraction must actually carry our intents — an empty actions map
# would ship a bundle that silently offers nothing to Shortcuts.
python3 - "$WORK/out/Metadata.appintents/extract.actionsdata" <<'PY'
import json, sys
actions = json.load(open(sys.argv[1])).get("actions") or {}
if not actions:
    raise SystemExit("error: extracted App Intents metadata declares no actions")
print(f"App Intents metadata: {', '.join(sorted(actions))}")
PY

rm -rf "$RESOURCES_DIR/Metadata.appintents"
cp -R "$WORK/out/Metadata.appintents" "$RESOURCES_DIR/"
