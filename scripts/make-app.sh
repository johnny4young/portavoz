#!/bin/bash
# Wraps the portavoz-app SPM executable into a proper macOS app bundle
# (dist/Portavoz.app) with the Info.plist TCC needs (microphone + system
# audio) and an ad-hoc signature. D20: no Xcode project until iOS (M7) or
# notarization forces one.
#
#   scripts/make-app.sh            # debug build
#   scripts/make-app.sh --release  # release build
#   open dist/Portavoz.app
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
if [[ "${1:-}" == "--release" ]]; then
  CONFIG=release
fi

echo "Building portavoz-app ($CONFIG)…"
swift build --product portavoz-app -c "$CONFIG"
BIN="$(swift build --show-bin-path -c "$CONFIG")/portavoz-app"

APP=dist/Portavoz.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Icon (regenerate with: swift scripts/make-icon.swift)
if [[ -f assets/AppIcon.icns ]]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleName</key>
    <string>Portavoz</string>
    <key>CFBundleDisplayName</key>
    <string>Portavoz</string>
    <key>CFBundleIdentifier</key>
    <string>app.portavoz.mac</string>
    <key>CFBundleExecutable</key>
    <string>portavoz-app</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Portavoz graba tu micrófono para transcribir tus intervenciones en la reunión. El audio nunca sale de tu Mac.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Portavoz captura el audio del sistema para transcribir a los demás participantes de la reunión. El audio nunca sale de tu Mac.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Portavoz lee los asistentes de tus eventos de calendario solo para sugerir nombres de los hablantes de la reunión. Nada sale de tu Mac.</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/portavoz-app"
codesign --force --sign - "$APP"

echo "OK → $APP"
echo "Run it with: open $APP"
