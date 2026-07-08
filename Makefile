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

.PHONY: build test test-ui project app install

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
	$(XCODE) xcodebuild test \
		-project Portavoz.xcodeproj -scheme Portavoz \
		-destination 'platform=macOS' -configuration Debug

## Build the release app bundle only (see scripts/make-app.sh).
app:
	PORTAVOZ_SIGN_IDENTITY=$(PORTAVOZ_SIGN_IDENTITY) scripts/make-app.sh --release

## Build the release app, install it to /Applications, and relaunch it.
## Run this after any change you want to try in the real app so what's
## installed always matches the latest work.
install:
	-osascript -e 'tell application "Portavoz" to quit' 2>/dev/null; sleep 1
	PORTAVOZ_SIGN_IDENTITY=$(PORTAVOZ_SIGN_IDENTITY) scripts/make-app.sh --release
	rm -rf /Applications/Portavoz.app
	cp -R dist/Portavoz.app /Applications/
	open /Applications/Portavoz.app
	@echo "✅ Portavoz reinstalada en /Applications con los últimos cambios."
