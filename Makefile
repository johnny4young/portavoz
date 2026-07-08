# Portavoz — dev shortcuts.
#
# The shipping build is scripts/make-app.sh (SPM + ad-hoc/notarized bundle,
# D20). This Makefile adds the XCUITest path (XcodeGen-generated project) so
# UI is verified by automation instead of driving the screen by hand.

XCODE := DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

.PHONY: build test test-ui project app

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

## Build + install the release app bundle (see scripts/make-app.sh).
app:
	scripts/make-app.sh --release
