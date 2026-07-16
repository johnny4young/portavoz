# Portavoz — dev shortcuts.
#
# The shipping build is scripts/make-app.sh (SPM + ad-hoc/notarized bundle,
# D20). This Makefile adds the XCUITest path (XcodeGen-generated project) so
# UI is verified by automation instead of driving the screen by hand.

XCODE := DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# The local signing identity — a REAL Developer ID (not ad-hoc) so macOS
# keeps the app's TCC permissions across reinstalls instead of re-prompting.
# There are two Developer ID certs with the same name on this machine; this
# SHA-1 disambiguates the Portavoz one. Override with the env var.
PORTAVOZ_SIGN_IDENTITY ?= 8C8B5B1453BB7E3CC48D78FE2D4A47AC6EBB9D17

.PHONY: build test test-ui test-ui-en test-ui-es test-ui-preflight project app install

## Unit tests (the package suite).
test:
	$(XCODE) swift test

build:
	swift build

## (Re)generate Portavoz.xcodeproj from project.yml. The project is
## git-ignored — project.yml is the source of truth.
project:
	xcodegen generate

## UI smoke tests: launch the real app under XCUITest against a throwaway
## store (`-use-temp-store`) with a deterministic seed (`-seed-demo`).
test-ui: project
	@$(MAKE) --no-print-directory test-ui-preflight
	$(XCODE) xcodebuild test \
		-project Portavoz.xcodeproj -scheme Portavoz \
		-destination 'platform=macOS,arch=arm64' -configuration Debug \
		-skipPackagePluginValidation -skipMacroValidation

## UI smoke with the process launched in English.
test-ui-en: project
	@$(MAKE) --no-print-directory test-ui-preflight
	$(XCODE) xcodebuild test \
		-project Portavoz.xcodeproj -scheme Portavoz \
		-destination 'platform=macOS,arch=arm64' -configuration Debug \
		-testLanguage en -testRegion US \
		-skipPackagePluginValidation -skipMacroValidation

## UI smoke with the process launched in Spanish.
test-ui-es: project
	@$(MAKE) --no-print-directory test-ui-preflight
	$(XCODE) xcodebuild test \
		-project Portavoz.xcodeproj -scheme Portavoz \
		-destination 'platform=macOS,arch=arm64' -configuration Debug \
		-testLanguage es -testRegion ES \
		-skipPackagePluginValidation -skipMacroValidation

## XCUITest on macOS is sensitive to stale app instances and interrupting
## windows. Quit Portavoz before the runner tries to enable automation mode;
## warn about known interruptors without killing unrelated user apps.
test-ui-preflight:
	-osascript -e 'tell application "Portavoz Dev" to quit' >/dev/null 2>&1
	@if pgrep -x Gancho >/dev/null || pgrep -x gancho >/dev/null; then \
		echo "⚠️  Gancho is running; if XCUITest fails because of interrupting windows, close it and retry."; \
	fi
	@sleep 1

## Build the release app bundle only (see scripts/make-app.sh).
app:
	PORTAVOZ_SIGN_IDENTITY=$(PORTAVOZ_SIGN_IDENTITY) scripts/make-app.sh --release

## Build the dev app and install it as "Portavoz Dev" — NEVER touching
## /Applications/Portavoz.app, which is the user's notarized release copy
## (it updates via Sparkle/Homebrew only). Same bundle id, so TCC grants
## and Keychain items keep working; different name and path so both
## coexist. Need real recordings/data for a test? COPY them — never
## operate on the release app's live folders.
install:
	-osascript -e 'tell application "Portavoz Dev" to quit' 2>/dev/null; sleep 1
	PORTAVOZ_SIGN_IDENTITY=$(PORTAVOZ_SIGN_IDENTITY) scripts/make-app.sh --release
	plutil -replace CFBundleDisplayName -string "Portavoz Dev" dist/Portavoz.app/Contents/Info.plist
	plutil -replace CFBundleName -string "Portavoz Dev" dist/Portavoz.app/Contents/Info.plist
	# Editing Info.plist invalidates the signature; re-sign or TCC grants
	# (mic, screen recording) will not stick to the dev app.
	codesign --force --options runtime --sign "$(PORTAVOZ_SIGN_IDENTITY)" \
		--entitlements packaging/portavoz.entitlements dist/Portavoz.app
	rm -rf "/Applications/Portavoz Dev.app"
	cp -R dist/Portavoz.app "/Applications/Portavoz Dev.app"
	open "/Applications/Portavoz Dev.app"
	@echo "✅ Portavoz Dev reinstalled (release copy untouched)."
