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

.PHONY: build test test-ask-quality ask-quality-pair \
	test-commitment-quality commitment-quality-deterministic \
	commitment-quality-model commitment-quality-compare \
	test-correction-composition correction-composition-benchmark \
	test-commitment-radar-scale commitment-radar-benchmark \
	test-exact-path-matrix exact-path-matrix \
	exact-path-mutation-matrix test-exact-path-mutation-host exact-path-mutation-host \
	test-exact-path-mutation-cross-host exact-path-mutation-cross-host \
	test-exact-path-mutation-baseline exact-path-mutation-baseline \
	test-exact-path-cross-host exact-path-cross-host test-exact-path-baseline exact-path-baseline \
	test-meeting-detail-baseline meeting-detail-baseline \
	test-recording-stress test-ui test-ui-en test-ui-es \
	test-ui-bilingual test-ui-scoped test-ui-changed test-ui-preflight project app install \
	perf-ledger resource-baseline resource-recording-baseline public-screenshots release-reliability-deterministic \
	release-reliability long-capture-baseline

## Unit tests (the package suite).
test:
	$(XCODE) swift test

## Verify the content-free correction benchmark contract without running the
## canonical 20,000-segment Release measurement.
test-correction-composition:
	$(XCODE) swift test --filter TranscriptCorrectionScaleBenchmarkTests

## Emit one content-free Release observation for correction composition over
## 20,000 mixed-language transcript segments.
PORTAVOZ_CORRECTION_COMPOSITION_RUNS ?= 5
correction-composition-benchmark:
	scripts/run-correction-composition-benchmark.sh \
		--runs "$(PORTAVOZ_CORRECTION_COMPOSITION_RUNS)"

## Verify the bounded, content-free Commitment Radar scale contract without
## running the canonical 1,000/10,000-confirmed-commitment Release measurement.
test-commitment-radar-scale:
	$(XCODE) swift test --filter CommitmentRadarScaleBenchmarkTests

## Emit one content-free Release observation for the bounded Commitment Radar
## read over 1,000 and 10,000 synthetic confirmed commitments.
PORTAVOZ_COMMITMENT_RADAR_RUNS ?= 5
commitment-radar-benchmark:
	scripts/run-commitment-radar-benchmark.sh \
		--runs "$(PORTAVOZ_COMMITMENT_RADAR_RUNS)"

## Validate the adapter-neutral Ask quality contract and its canonical public
## 240-query multilingual fixture without loading models or user data.
test-ask-quality:
	python3 -m unittest Tests.Tooling.test_ask_quality
	python3 -m unittest Tests.Tooling.test_ask_quality_pair
	python3 scripts/ask_quality.py verify-public \
		--fixture Fixtures/AskQuality/public-synthetic-v1.json
	python3 scripts/ask_quality.py verify-public \
		--fixture Fixtures/AskQuality/public-synthetic-v2.json

## Validate the public bilingual commitment-candidate benchmark and its
## deterministic research control without loading a model or user data.
test-commitment-quality:
	python3 -m unittest Tests.Tooling.test_commitment_quality
	python3 scripts/commitment_quality.py validate \
		--fixture Fixtures/CommitmentQuality/public-synthetic-v1.json

## Emit the research-only deterministic control scorecard. It is a comparison
## anchor, not a product policy or an engine decision.
commitment-quality-deterministic:
	@python3 scripts/commitment_quality.py run \
		--fixture Fixtures/CommitmentQuality/public-synthetic-v1.json \
		--adapter deterministic

## Score one explicitly local OpenAI-compatible model over the same public
## fixture. The endpoint is loopback-only and no meeting library is read.
PORTAVOZ_COMMITMENT_MODEL_ENDPOINT ?= http://127.0.0.1:11434/v1/chat/completions
PORTAVOZ_COMMITMENT_MODEL ?=
PORTAVOZ_COMMITMENT_MODEL_DETAILS ?=
commitment-quality-model:
	@test -n "$(PORTAVOZ_COMMITMENT_MODEL)" || \
		(echo "PORTAVOZ_COMMITMENT_MODEL is required" >&2; exit 64)
	@python3 scripts/commitment_quality.py run \
		--fixture Fixtures/CommitmentQuality/public-synthetic-v1.json \
		--adapter openai-compatible \
		--endpoint "$(PORTAVOZ_COMMITMENT_MODEL_ENDPOINT)" \
		--model "$(PORTAVOZ_COMMITMENT_MODEL)" \
		$(if $(PORTAVOZ_COMMITMENT_MODEL_DETAILS),--details-output "$(PORTAVOZ_COMMITMENT_MODEL_DETAILS)")

## Compare two scorecards from the exact same fixture. The output reports
## metric deltas and deliberately never declares a winner.
PORTAVOZ_COMMITMENT_LEFT ?=
PORTAVOZ_COMMITMENT_RIGHT ?=
commitment-quality-compare:
	@test -n "$(PORTAVOZ_COMMITMENT_LEFT)" || \
		(echo "PORTAVOZ_COMMITMENT_LEFT is required" >&2; exit 64)
	@test -n "$(PORTAVOZ_COMMITMENT_RIGHT)" || \
		(echo "PORTAVOZ_COMMITMENT_RIGHT is required" >&2; exit 64)
	@python3 scripts/commitment_quality.py compare \
		--left "$(PORTAVOZ_COMMITMENT_LEFT)" \
		--right "$(PORTAVOZ_COMMITMENT_RIGHT)"

## Validate the exact-shaped, content-free host receipt boundary without
## running the expensive Release scale harness.
test-exact-path-matrix:
	python3 -m unittest Tests.Tooling.test_exact_path_matrix

## Collect three clean Release observations at every canonical exact-path
## scale and emit one aggregate host receipt to stdout.
PORTAVOZ_EXACT_PATH_PROFILE ?=
exact-path-matrix:
	@test -n "$(PORTAVOZ_EXACT_PATH_PROFILE)" || \
		(echo "PORTAVOZ_EXACT_PATH_PROFILE is required" >&2; exit 64)
	scripts/run-exact-path-shadow-matrix.sh \
		--profile "$(PORTAVOZ_EXACT_PATH_PROFILE)"

## Emit one content-free Release mutation observation at every canonical exact
## corpus scale. Results remain stdout-only research evidence.
exact-path-mutation-matrix:
	scripts/run-exact-path-mutation-benchmark.sh --matrix --runs 5

## Validate the threshold-free mutation host-receipt contract with synthetic
## observations.
test-exact-path-mutation-host:
	python3 -m unittest Tests.Tooling.test_exact_path_mutation_matrix

## Collect three clean mutation observations per canonical scale and emit one
## content-free receipt for explicit human review.
exact-path-mutation-host:
	scripts/run-exact-path-mutation-host-matrix.sh \
		--profile "$(PORTAVOZ_EXACT_PATH_PROFILE)"

## Validate the threshold-free cross-host mutation review with synthetic
## aggregate receipts.
test-exact-path-mutation-cross-host:
	python3 -m unittest Tests.Tooling.test_exact_path_mutation_cross_host

## Compare one mutation receipt per required host profile without retaining a
## baseline, deriving timing ratios, or selecting an engine.
PORTAVOZ_EXACT_PATH_MUTATION_RECEIPTS ?=
exact-path-mutation-cross-host:
	@test -n "$(PORTAVOZ_EXACT_PATH_MUTATION_RECEIPTS)" || \
		(echo "PORTAVOZ_EXACT_PATH_MUTATION_RECEIPTS is required" >&2; exit 64)
	python3 scripts/exact_path_mutation_cross_host.py \
		--input "$(PORTAVOZ_EXACT_PATH_MUTATION_RECEIPTS)"

## Validate private mutation-baseline admission with synthetic aggregate-only
## evidence. This never runs the expensive Release benchmark.
test-exact-path-mutation-baseline:
	python3 -m unittest Tests.Tooling.test_exact_path_mutation_baseline

## Retain one explicitly reviewed mutation scorecard and its three validated
## aggregate receipts. Review acknowledgement is intentionally required rather
## than defaulted, and grants no engine or performance decision authority.
PORTAVOZ_EXACT_PATH_MUTATION_SCORECARD ?=
PORTAVOZ_EXACT_PATH_MUTATION_BASELINE_OUTPUT ?=
PORTAVOZ_EXACT_PATH_MUTATION_ACCEPTED_SCORECARD_SHA256 ?=
PORTAVOZ_EXACT_PATH_MUTATION_ACCEPTED_SOURCE_COMMIT ?=
PORTAVOZ_EXACT_PATH_MUTATION_REVIEW_ACKNOWLEDGEMENT ?=
exact-path-mutation-baseline:
	@test -n "$(PORTAVOZ_EXACT_PATH_MUTATION_RECEIPTS)" || \
		(echo "PORTAVOZ_EXACT_PATH_MUTATION_RECEIPTS is required" >&2; exit 64)
	@test -n "$(PORTAVOZ_EXACT_PATH_MUTATION_SCORECARD)" || \
		(echo "PORTAVOZ_EXACT_PATH_MUTATION_SCORECARD is required" >&2; exit 64)
	@test -n "$(PORTAVOZ_EXACT_PATH_MUTATION_BASELINE_OUTPUT)" || \
		(echo "PORTAVOZ_EXACT_PATH_MUTATION_BASELINE_OUTPUT is required" >&2; exit 64)
	@test -n "$(PORTAVOZ_EXACT_PATH_MUTATION_ACCEPTED_SCORECARD_SHA256)" || \
		(echo "PORTAVOZ_EXACT_PATH_MUTATION_ACCEPTED_SCORECARD_SHA256 is required" >&2; exit 64)
	@test -n "$(PORTAVOZ_EXACT_PATH_MUTATION_ACCEPTED_SOURCE_COMMIT)" || \
		(echo "PORTAVOZ_EXACT_PATH_MUTATION_ACCEPTED_SOURCE_COMMIT is required" >&2; exit 64)
	@test -n "$(PORTAVOZ_EXACT_PATH_MUTATION_REVIEW_ACKNOWLEDGEMENT)" || \
		(echo "PORTAVOZ_EXACT_PATH_MUTATION_REVIEW_ACKNOWLEDGEMENT is required" >&2; exit 64)
	python3 scripts/exact_path_mutation_baseline.py \
		--receipts "$(PORTAVOZ_EXACT_PATH_MUTATION_RECEIPTS)" \
		--scorecard "$(PORTAVOZ_EXACT_PATH_MUTATION_SCORECARD)" \
		--output "$(PORTAVOZ_EXACT_PATH_MUTATION_BASELINE_OUTPUT)" \
		--accept-scorecard-sha256 "$(PORTAVOZ_EXACT_PATH_MUTATION_ACCEPTED_SCORECARD_SHA256)" \
		--accept-source-commit "$(PORTAVOZ_EXACT_PATH_MUTATION_ACCEPTED_SOURCE_COMMIT)" \
		--accept-review-acknowledgement "$(PORTAVOZ_EXACT_PATH_MUTATION_REVIEW_ACKNOWLEDGEMENT)"

## Validate the cross-host scorecard boundary with synthetic host receipts.
test-exact-path-cross-host:
	python3 -m unittest Tests.Tooling.test_exact_path_cross_host

## Compare accepted host receipts without retaining a baseline or selecting an
## engine. The input is JSONL with one receipt per measured host profile.
PORTAVOZ_EXACT_PATH_RECEIPTS ?=
exact-path-cross-host:
	@test -n "$(PORTAVOZ_EXACT_PATH_RECEIPTS)" || \
		(echo "PORTAVOZ_EXACT_PATH_RECEIPTS is required" >&2; exit 64)
	python3 scripts/exact_path_cross_host.py \
		--input "$(PORTAVOZ_EXACT_PATH_RECEIPTS)"

## Validate the explicit private research-baseline admission boundary with
## synthetic aggregate-only evidence.
test-exact-path-baseline:
	python3 -m unittest Tests.Tooling.test_exact_path_baseline

## Retain one reviewed passing scorecard and its validated aggregate receipts.
## The digest must be the lowercase `shasum -a 256` value of the canonical
## scorecard file; the source checkout must be clean at the accepted commit.
PORTAVOZ_EXACT_PATH_SCORECARD ?=
PORTAVOZ_EXACT_PATH_BASELINE_OUTPUT ?=
PORTAVOZ_EXACT_PATH_ACCEPTED_SCORECARD_SHA256 ?=
PORTAVOZ_EXACT_PATH_ACCEPTED_SOURCE_COMMIT ?=
exact-path-baseline:
	@test -n "$(PORTAVOZ_EXACT_PATH_RECEIPTS)" || \
		(echo "PORTAVOZ_EXACT_PATH_RECEIPTS is required" >&2; exit 64)
	@test -n "$(PORTAVOZ_EXACT_PATH_SCORECARD)" || \
		(echo "PORTAVOZ_EXACT_PATH_SCORECARD is required" >&2; exit 64)
	@test -n "$(PORTAVOZ_EXACT_PATH_BASELINE_OUTPUT)" || \
		(echo "PORTAVOZ_EXACT_PATH_BASELINE_OUTPUT is required" >&2; exit 64)
	@test -n "$(PORTAVOZ_EXACT_PATH_ACCEPTED_SCORECARD_SHA256)" || \
		(echo "PORTAVOZ_EXACT_PATH_ACCEPTED_SCORECARD_SHA256 is required" >&2; exit 64)
	@test -n "$(PORTAVOZ_EXACT_PATH_ACCEPTED_SOURCE_COMMIT)" || \
		(echo "PORTAVOZ_EXACT_PATH_ACCEPTED_SOURCE_COMMIT is required" >&2; exit 64)
	python3 scripts/exact_path_baseline.py \
		--receipts "$(PORTAVOZ_EXACT_PATH_RECEIPTS)" \
		--scorecard "$(PORTAVOZ_EXACT_PATH_SCORECARD)" \
		--output "$(PORTAVOZ_EXACT_PATH_BASELINE_OUTPUT)" \
		--accept-scorecard-sha256 "$(PORTAVOZ_EXACT_PATH_ACCEPTED_SCORECARD_SHA256)" \
		--accept-source-commit "$(PORTAVOZ_EXACT_PATH_ACCEPTED_SOURCE_COMMIT)"

## Verify the reviewed Meeting Detail interaction inventory and the fail-closed
## Instruments report parser without launching the app or reading user data.
test-meeting-detail-baseline:
	python3 -m unittest \
		Tests.Tooling.test_meeting_detail_contract \
		Tests.Tooling.test_meeting_detail_performance
	python3 scripts/meeting_detail_contract.py verify

## Capture the disposable 5k playback-seek and 20k transcript-scroll profiles.
## The runner refuses the notarized app and never reads the user's library.
PORTAVOZ_MEETING_DETAIL_BASELINE_OUTPUT ?= /private/tmp/portavoz-detail-ui-baseline.json
meeting-detail-baseline:
	scripts/run-detail-ui-baseline.sh "$(PORTAVOZ_MEETING_DETAIL_BASELINE_OUTPUT)"

## Build one Release CLI and compare segment control with speaker-turn retrieval
## from the same clean commit. Output is private, non-overwriting local evidence.
ask-quality-pair:
	@test -n "$(PORTAVOZ_ASK_QUALITY_BUILD)" || \
		(echo "PORTAVOZ_ASK_QUALITY_BUILD is required" >&2; exit 64)
	@test -n "$(PORTAVOZ_ASK_QUALITY_OUTPUT)" || \
		(echo "PORTAVOZ_ASK_QUALITY_OUTPUT is required" >&2; exit 64)
	python3 scripts/ask_quality_pair.py \
		--fixture Fixtures/AskQuality/public-synthetic-v2.json \
		--build "$(PORTAVOZ_ASK_QUALITY_BUILD)" \
		--output "$(PORTAVOZ_ASK_QUALITY_OUTPUT)"

## Release performance ledger (PERF-001/PERF-008): run the unattended
## benchmark harnesses, evaluate every journey against its declared budget and
## the committed baseline, and write one scorecard. Fails on a budget miss.
## PORTAVOZ_PERF_STRICT=1 also fails on regression candidates.
perf-ledger:
	scripts/run-perf-ledger.sh

## Collect three Release idle, recording, Stop, and Refine resource samples on
## this Mac and assemble an exact-shaped host receipt. The worktree must be
## clean and the profile/version/build must describe this machine and source
## exactly. Models required by Refine must already be verified locally.
PORTAVOZ_RESOURCE_RUNS ?= 3
PORTAVOZ_RESOURCE_DURATION ?= 60
PORTAVOZ_RESOURCE_IDLE_DURATION ?= 30
PORTAVOZ_RESOURCE_MODEL_TIMEOUT ?= 900
PORTAVOZ_RESOURCE_OUTPUT ?=
resource-baseline:
	@test -n "$(PORTAVOZ_RESOURCE_PROFILE)" || \
		(echo "PORTAVOZ_RESOURCE_PROFILE is required" >&2; exit 64)
	@test -n "$(PORTAVOZ_RELEASE_VERSION)" || \
		(echo "PORTAVOZ_RELEASE_VERSION is required" >&2; exit 64)
	@test -n "$(PORTAVOZ_RELEASE_BUILD)" || \
		(echo "PORTAVOZ_RELEASE_BUILD is required" >&2; exit 64)
	PORTAVOZ_SIGN_IDENTITY=$(PORTAVOZ_SIGN_IDENTITY) \
		scripts/run-resource-baseline.sh \
			--profile "$(PORTAVOZ_RESOURCE_PROFILE)" \
			--version "$(PORTAVOZ_RELEASE_VERSION)" \
			--build "$(PORTAVOZ_RELEASE_BUILD)" \
			--runs "$(PORTAVOZ_RESOURCE_RUNS)" \
			--duration "$(PORTAVOZ_RESOURCE_DURATION)" \
			--idle-duration "$(PORTAVOZ_RESOURCE_IDLE_DURATION)" \
			--model-timeout "$(PORTAVOZ_RESOURCE_MODEL_TIMEOUT)" \
			$(if $(PORTAVOZ_RESOURCE_OUTPUT),--output "$(PORTAVOZ_RESOURCE_OUTPUT)")

## Backward-compatible alias for the original recording-only command name.
resource-recording-baseline: resource-baseline

## Accelerate three logical hours of bounded dual-channel PCM through the
## production RecordingSession, then require exact frame and publication
## conservation from a clean Release build. Output is local evidence only.
PORTAVOZ_LONG_CAPTURE_OUTPUT ?=
long-capture-baseline:
	scripts/run-long-capture-baseline.sh "$(PORTAVOZ_LONG_CAPTURE_OUTPUT)"

## Run the deterministic release gates and write a receipt bound to the exact
## version, build, and current commit. Both release variables are required.
release-reliability-deterministic:
	scripts/run-release-reliability-gates.sh

## Evaluate deterministic, signed-distribution, real-hardware, and user-field
## evidence. Pass field packages as repeated arguments, for example:
##   make release-reliability PORTAVOZ_RELEASE_VERSION=0.8.0 \
##     PORTAVOZ_RELEASE_BUILD=800 PORTAVOZ_FIELD_EVIDENCE_ARGS='\
##       --field-evidence evidence/built-in-15 \
##       --field-evidence evidence/built-in-26'
PORTAVOZ_RELIABILITY_ROOT ?= dist/release-readiness
PORTAVOZ_RELEASE_COMMIT ?= $(shell git rev-parse HEAD)
PORTAVOZ_FIELD_EVIDENCE_ARGS ?=
release-reliability:
	@test -n "$(PORTAVOZ_RELEASE_VERSION)" || \
		(echo "PORTAVOZ_RELEASE_VERSION is required" >&2; exit 64)
	@test -n "$(PORTAVOZ_RELEASE_BUILD)" || \
		(echo "PORTAVOZ_RELEASE_BUILD is required" >&2; exit 64)
	python3 scripts/release_reliability.py evaluate \
		--version "$(PORTAVOZ_RELEASE_VERSION)" \
		--build "$(PORTAVOZ_RELEASE_BUILD)" \
		--commit "$(PORTAVOZ_RELEASE_COMMIT)" \
		--deterministic-receipt "$(PORTAVOZ_RELIABILITY_ROOT)/deterministic.json" \
		--distribution-receipt "$(PORTAVOZ_RELIABILITY_ROOT)/distribution.json" \
		$(PORTAVOZ_FIELD_EVIDENCE_ARGS) --output "$(PORTAVOZ_RELIABILITY_ROOT)/scorecard"

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

## Regenerate the three public README/website screenshots from a fictional,
## disposable XCUITest library. The exporter captures only the Portavoz window.
public-screenshots:
	scripts/update-public-screenshots.sh

## Build the release app bundle only (see scripts/make-app.sh).
app:
	PORTAVOZ_SIGN_IDENTITY=$(PORTAVOZ_SIGN_IDENTITY) scripts/make-app.sh --release

## Build the dev app and install it as "Portavoz Dev" — NEVER touching
## /Applications/Portavoz.app, which is the user's notarized release copy
## (it updates via Sparkle/Homebrew only). Dev has a separate bundle identity
## so LaunchServices, Shortcuts, Spotlight, and Siri never confuse it with the
## stable app. A fresh dev identity needs its own one-time TCC grants. Need real
## recordings/data for a test? COPY them — never operate on the release app's
## live folders.
install:
	-osascript -e 'tell application "Portavoz Dev" to quit' 2>/dev/null; sleep 1
	PORTAVOZ_SIGN_IDENTITY=$(PORTAVOZ_SIGN_IDENTITY) scripts/make-app.sh --release
	plutil -replace CFBundleDisplayName -string "Portavoz Dev" dist/Portavoz.app/Contents/Info.plist
	plutil -replace CFBundleName -string "Portavoz Dev" dist/Portavoz.app/Contents/Info.plist
	plutil -replace CFBundleIdentifier -string "app.portavoz.mac.dev" dist/Portavoz.app/Contents/Info.plist
	@for plist in dist/Portavoz.app/Contents/Resources/*.lproj/InfoPlist.strings; do \
		sed -i '' \
			-e 's/^"CFBundleDisplayName" = ".*";$$/"CFBundleDisplayName" = "Portavoz Dev";/' \
			-e 's/^"CFBundleName" = ".*";$$/"CFBundleName" = "Portavoz Dev";/' \
			"$$plist"; \
		plutil -lint "$$plist"; \
	done
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
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f "/Applications/Portavoz Dev.app"
	open "/Applications/Portavoz Dev.app"
	@echo "✅ Portavoz Dev reinstalled (release copy untouched)."
