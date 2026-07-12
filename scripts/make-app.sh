#!/bin/bash
# Wraps the portavoz-app SPM executable into a proper macOS app bundle
# (dist/Portavoz.app) with the Info.plist TCC needs (microphone + system
# audio) and a local/distribution signature. D20 keeps shipping script-built;
# D30 adds project.yml only for XCUITest verification.
#
#   scripts/make-app.sh                              # debug build
#   scripts/make-app.sh --release                    # release build
#   scripts/make-app.sh --version 0.1.0 --build 123  # stamp Info.plist
#   open dist/Portavoz.app
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
VERSION="${PORTAVOZ_VERSION:-0.1.0}"
BUILD="${PORTAVOZ_BUILD:-1}"

usage() {
  echo "usage: scripts/make-app.sh [--release] [--version <version>] [--build <build>]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      CONFIG=release
      shift
      ;;
    --version)
      if [[ $# -lt 2 || -z "$2" ]]; then usage; exit 64; fi
      VERSION="$2"
      shift 2
      ;;
    --build)
      if [[ $# -lt 2 || -z "$2" ]]; then usage; exit 64; fi
      BUILD="$2"
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

echo "Building portavoz-app ($CONFIG, version $VERSION build $BUILD)…"
swift build --product portavoz-app -c "$CONFIG"
BIN_DIR="$(swift build --show-bin-path -c "$CONFIG")"
BIN="$BIN_DIR/portavoz-app"

# Ad-hoc by default; export PORTAVOZ_SIGN_IDENTITY="Developer ID Application: …"
# for a real distribution signature.
SIGN_ID="${PORTAVOZ_SIGN_IDENTITY:--}"

APP=dist/Portavoz.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# Sparkle ships as a dynamic framework; embed it and make sure the
# binary can find it relative to itself.
cp -a "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"

# MLX Metal kernels (D32): SwiftPM cannot compile Metal shaders, so the
# compiled metallib comes from a cached one-time xcodebuild pass. Without
# the bundle inside Resources the embedded summarizer cannot initialize
# Metal at runtime. If the cache cannot be built (no Metal Toolchain) the
# app still ships — only the Built-in engine is unavailable.
if scripts/build-mlx-metallib.sh; then
  cp -R .build/mlx/mlx-swift_Cmlx.bundle "$APP/Contents/Resources/"
else
  echo "warning: shipping without the MLX metallib — Built-in engine disabled." >&2
fi

# Icon (regenerate with: swift scripts/make-icon.swift)
if [[ -f assets/AppIcon.icns ]]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# App accent color (design system: indigo is THE accent — resolves the
# system-accent debt): compile the asset catalog so NSAccentColorName
# resolves. Users who picked a specific system accent still win, per macOS.
if [[ -d assets/Assets.xcassets ]]; then
  xcrun actool assets/Assets.xcassets --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.4 \
    --output-format human-readable-text > /dev/null
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
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>es</string>
    </array>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSAccentColorName</key>
    <string>AccentColor</string>
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
    <string>Portavoz records your microphone to transcribe your side of the meeting. Audio never leaves your Mac.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Portavoz captures system audio to transcribe other meeting participants. Audio never leaves your Mac.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Portavoz reads calendar attendees only to suggest meeting speaker names. Nothing leaves your Mac.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Portavoz stores meeting audio in the folder you choose.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Portavoz stores meeting audio in the folder you choose.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Portavoz stores meeting audio in the folder you choose.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Portavoz stores meeting audio in the folder you choose, including external drives.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Portavoz can use the macOS speech engine as an on-device transcription fallback.</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
    <key>NSUserActivityTypes</key>
    <array>
        <!-- CSSearchableItemActionType: without this, a Spotlight hit only
             activates the app and the continuation never reaches SwiftUI. -->
        <string>com.apple.corespotlightitem</string>
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
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Portavoz meeting</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>app.portavoz.meeting-bundle</string>
            </array>
        </dict>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>app.portavoz.mac</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>portavoz</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
python3 scripts/export-localizations.py "$APP/Contents/Resources"

# Sparkle update feed + signing key. Without assets/sparkle-public-key
# the app just never finds updates (fine in dev).
plutil -insert SUFeedURL -string "https://github.com/johnny4young/portavoz/releases/latest/download/appcast.xml" "$APP/Contents/Info.plist"
plutil -insert SUEnableAutomaticChecks -bool true "$APP/Contents/Info.plist"
if [[ -f assets/sparkle-public-key ]]; then
  plutil -insert SUPublicEDKey -string "$(cat assets/sparkle-public-key)" "$APP/Contents/Info.plist"
fi

cp "$BIN" "$APP/Contents/MacOS/portavoz-app"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/portavoz-app" 2>/dev/null || true

# Notarization demands the hardened runtime + secure timestamp; the
# timestamp needs a real certificate, so it's skipped when ad-hoc.
SIGN_FLAGS=(--force --options runtime)
if [[ "$SIGN_ID" != "-" ]]; then
  SIGN_FLAGS+=(--timestamp)
fi

codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_ID" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_ID" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_ID" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_ID" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_ID" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_ID" \
  --entitlements packaging/portavoz.entitlements "$APP"

echo "OK → $APP (signature: $SIGN_ID)"
echo "Run it with: open $APP"
