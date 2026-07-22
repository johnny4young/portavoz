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

.PHONY: build test test-recording-stress test-ui test-ui-en test-ui-es \
	test-ui-bilingual test-ui-scoped test-ui-changed test-ui-preflight project app install

## Unit tests (the package suite).
test:
	$(XCODE) swift test

## Repeat the focused recording/recovery corpus without rebuilding between
## iterations. Override the default with PORTAVOZ_STRESS_ITERATIONS=N.
test-recording-stress:
	$(XCODE) scripts/run-recording-reliability-stress.sh

build:
	swift build

## (Re)generate Portavoz.xcodeproj from project.yml. The project is
## git-ignored — project.yml is the source of truth.
project:
	xcodegen generate

## UI smoke tests launch the real app against disposable state. The runner
## builds once and reuses those products for every requested locale.
test-ui: UI_TEST_LOCALES = default
test-ui: test-ui-scoped

test-ui-en: UI_TEST_LOCALES = en
test-ui-en: test-ui-scoped

test-ui-es: UI_TEST_LOCALES = es
test-ui-es: test-ui-scoped

test-ui-bilingual: UI_TEST_LOCALES = en es
test-ui-bilingual: test-ui-scoped

## Run explicit Xcode selectors, for example:
##   make test-ui-scoped UI_TESTS='PortavozUITests/SettingsUITests/testCategoryNavigationRevealsEachPane'
test-ui-scoped: project
	@$(MAKE) --no-print-directory test-ui-preflight
	UI_TESTS="$(UI_TESTS)" UI_TEST_LOCALES="$(UI_TEST_LOCALES)" scripts/run-ui-tests.sh

## Select UI evidence from committed, staged, unstaged, and untracked changes
## against UI_BASE. Known views map to feature-level tests;
## shared/localization changes expand conservatively; docs-only changes skip
## XCUITest. Set UI_HEAD explicitly to inspect a committed Git range instead.
UI_BASE ?= origin/main
UI_HEAD ?=
test-ui-changed:
	@set -e; \
	if [ -n "$(UI_HEAD)" ]; then \
		SELECTOR_OUTPUT="$$(python3 scripts/ui_test_scope.py \
			--base "$(UI_BASE)" --head "$(UI_HEAD)" --format shell)"; \
	else \
		SELECTOR_OUTPUT="$$(python3 scripts/ui_test_scope.py \
			--base "$(UI_BASE)" --working-tree --format shell)"; \
	fi; \
	eval "$$SELECTOR_OUTPUT"; \
	echo "$$UI_TEST_SCOPE_SUMMARY"; \
	if [ "$$UI_TEST_REQUIRED" = true ]; then \
		$(MAKE) --no-print-directory test-ui-scoped \
			UI_TESTS="$$UI_TESTS" UI_TEST_LOCALES="$$UI_TEST_LOCALES"; \
	else \
		echo "No UI tests required for the selected change set."; \
	fi

## XCUITest on macOS is sensitive to stale app instances and interrupting
## windows. Quit Portavoz before the runner tries to enable automation mode;
## warn about known interruptors without killing unrelated user apps.
test-ui-preflight:
	-osascript -e 'tell application "Portavoz Dev" to quit' >/dev/null 2>&1
	-killall testmanagerd >/dev/null 2>&1
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
	codesign --force --options runtime --timestamp --sign "$(PORTAVOZ_SIGN_IDENTITY)" \
		--entitlements "$$(cat dist/.portavoz-sign-entitlements)" dist/Portavoz.app
	# Verify before copying. Besides failing closed on a bad nested signature,
	# this provides a read-after-write barrier for the freshly signed bundle.
	codesign --verify --deep --strict --verbose=2 dist/Portavoz.app
	rm -rf "/Applications/Portavoz Dev.app"
	cp -R dist/Portavoz.app "/Applications/Portavoz Dev.app"
	codesign --verify --deep --strict --verbose=2 "/Applications/Portavoz Dev.app"
	open "/Applications/Portavoz Dev.app"
	@echo "✅ Portavoz Dev reinstalled (release copy untouched)."
