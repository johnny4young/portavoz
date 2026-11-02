#!/usr/bin/env bash
# Wraps an existing SwiftPM debug build into the disposable XCUITest host.
# It never compiles the app and never inherits the shipping bundle's updater,
# CLI link, document claim or hardened runtime.
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

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Portavoz</string>
    <key>CFBundleIdentifier</key>
    <string>app.portavoz.mac.uitest-host</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Portavoz</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>es</string>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>app.portavoz.mac.uitest-host</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>portavoz</string>
            </array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>app.portavoz.meeting-bundle</string>
            <key>UTTypeDescription</key>
            <string>Portavoz meeting</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.json</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>portavoz</string>
                </array>
            </dict>
        </dict>
    </array>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Portavoz records your microphone to transcribe your side of the meeting. Audio never leaves your Mac.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Portavoz captures system audio to transcribe other meeting participants. Audio never leaves your Mac.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>Portavoz creates a reminder only after you preview and confirm it. It is saved to the Reminders list you choose, which may sync through that account.</string>
</dict>
</plist>
PLIST

chmod -R u+rwX,go+rX,go-w "$app"
codesign --force --deep --sign - "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --entitlements packaging/portavoz-local.entitlements "$app"
codesign --verify --deep --strict "$app"
echo "UI host ready: $app"
