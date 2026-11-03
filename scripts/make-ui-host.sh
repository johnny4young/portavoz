#!/usr/bin/env bash
# Wraps an existing SwiftPM debug build into the disposable XCUITest host. It never
# compiles the app and never inherits the shipping updater, CLI link or document claim.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077

app="${1:?usage: make-ui-host.sh <output.app> [swift build flags...]}"
shift
bin_dir="$(swift build --show-bin-path "$@")"
executable="$bin_dir/portavoz-app"
[[ -x "$executable" ]] || { echo "Build portavoz-app before wrapping it: $executable" >&2; exit 66; }

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$executable" "$app/Contents/MacOS/Portavoz"
cp -a "$bin_dir/Sparkle.framework" "$app/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Portavoz"
cp -R "$bin_dir/Portavoz_IntelligenceKit.bundle" "$app/Contents/Resources/"
python3 scripts/export-localizations.py "$app/Contents/Resources"
scripts/build-appintents-metadata.sh "$app/Contents/Resources" debug
python3 scripts/ui_host.py info-plist "$app/Contents/Info.plist"

chmod -R u+rwX,go+rX,go-w "$app"
codesign --force --deep --sign - "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --entitlements packaging/portavoz-local.entitlements "$app"
codesign --verify --deep --strict "$app"
echo "UI host ready: $app"
