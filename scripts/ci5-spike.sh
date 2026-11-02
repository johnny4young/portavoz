#!/usr/bin/env bash
# Spike only: one lane of the host-from-SwiftPM experiment.
set -euo pipefail
cd "$(dirname "$0")/.."

FLAGS=(-Xswiftc -warnings-as-errors)
HOST=/private/tmp/portavoz-ui-tests/host/Portavoz.app
PRODUCTS="$RUNNER_TEMP/ui-products/portavoz-ui.xctestproducts"
RECEIPT="$RUNNER_TEMP/ui-products/build-duration-seconds.txt"
TIMINGS="dist/spike/timings.txt"
SMOKE="PortavozUITests/LibraryUITests/testLibraryRendersRecordButtonAndActionChips PortavozUITests/LibraryUITests/testDatabaseLaunchFailureOffersSafeRecovery PortavozUITests/LibraryUITests/testCaptureFailureSurvivesStopAndRelaunchWithPlayablePrefix PortavozUITests/LibraryUITests/testOwnedTokenPreviewRetiresWithoutEnteringCanonicalCaption PortavozUITests/LibraryUITests/testCommandPaletteSearchAnswerAndCitationSurviveNoStaleState PortavozUITests/MeetingDetailUITests/testMeetingReviewSurfacesRemainCompleteAndActionable PortavozUITests/SettingsUITests/testLanguageToggleSwitchesVisibleTextWithoutRelaunch PortavozUITests/SettingsUITests/testSyncPaneKeepsOptInAndExistingLibrarySeparate PortavozUITests/MenuBarUITests/testPreMeetingBriefMovesFromExactProposalToDurableReceipt"

mkdir -p dist/spike "$(dirname "$PRODUCTS")"

timed() {
  local label="$1" started=$SECONDS status=0
  shift
  "$@" || status=$?
  echo "$label $((SECONDS - started))s exit=$status" | tee -a "$TIMINGS"
  return "$status"
}

manifest() {
  local app="$1" name="$2"
  ( cd "$app" && find . | LC_ALL=C sort ) > "dist/spike/manifest-$name.txt"
  plutil -convert json -o "dist/spike/info-$name.json" "$app/Contents/Info.plist"
  codesign -d --entitlements - --xml "$app" > "dist/spike/entitlements-$name.xml" 2>/dev/null || true
  otool -L "$app/Contents/MacOS/"* > "dist/spike/otool-$name.txt" || true
  cp "$app/Contents/Resources/Metadata.appintents/extract.actionsdata" "dist/spike/intents-$name.json" 2>/dev/null || true
  du -sk "$app" > "dist/spike/size-$name.txt"
}

catalog() {
  ( eval "$(python3 scripts/ui_test_scope.py --all --format shell)"; printf '%s' "$UI_TESTS" )
}

apply_change() {
  case "$1" in
    view) printf '\nprivate let ci5SpikeMarker = "view"\n' >> Sources/portavoz-app/MeetingDetailNotesSection.swift ;;
    core) printf '\nprivate let ci5SpikeMarker = "core"\n' >> Sources/PortavozCore/MeetingTypes.swift ;;
    none) ;;
    *) echo "unknown change $1" >&2; exit 2 ;;
  esac
}

build_new() {
  apply_change "$1"
  timed swift-build-product swift build --product portavoz-app "${FLAGS[@]}"
  mkdir -p "$(dirname "$HOST")"
  chmod 700 /private/tmp/portavoz-ui-tests
  timed make-ui-host scripts/make-ui-host.sh "$HOST" "${FLAGS[@]}"
  manifest "$HOST" new
  timed xcodegen xcodegen generate --spec project-ui-runner.yml --project .
  started=$SECONDS
  timed runner-build xcodebuild build-for-testing -project PortavozUIRunner.xcodeproj -scheme Portavoz \
    -destination "platform=macOS,arch=$(uname -m)" -configuration Debug -testProductsPath "$PRODUCTS"
  echo "$((SECONDS - started))" > "$RECEIPT"
  plutil -convert json -o dist/spike/xctestrun.json "$(find "$PRODUCTS" -name '*.xctestrun' | head -1)" || true
}

run_new() {
  local tests="$1" label="$2"
  export TEST_RUNNER_PORTAVOZ_UI_HOST_PATH="$HOST"
  timed "tests-$label" env UI_TESTS="$tests" UI_TEST_LOCALES=en UI_TEST_RESULTS_DIR="$PWD/dist/ui-test-results/$label" \
    UI_TEST_PRODUCTS_PATH="$PRODUCTS" UI_TEST_BUILD_RECEIPT="$RECEIPT" UI_TEST_ENFORCE_RUNTIME_BUDGET=false \
    make test-ui-run
}

case "${1:?mode}" in
  smoke)
    build_new "$2"
    status=0
    for round in $(seq 1 "$3"); do
      run_new "$SMOKE" "smoke-$2-$round" || status=1
    done
    exit "$status"
    ;;
  crash)
    build_new none
    if run_new PortavozUITests/SpikeHostCrashUITests/testForcedHostCrashFailsTheRun crash; then
      echo "A crashed host did not fail the run." >&2
      exit 1
    fi
    mkdir -p dist/spike/reports
    cp "$HOME"/Library/Logs/DiagnosticReports/Portavoz-*.ips dist/spike/reports/ 2>/dev/null || true
    ls -l dist/spike/reports
    compgen -G "dist/spike/reports/Portavoz-*.ips" >/dev/null || { echo "No crash report for the host." >&2; exit 1; }
    ;;
  full-new)
    build_new none
    run_new "$(catalog)" full
    ;;
  full-old)
    tests="$(catalog)"
    timed old-build env UI_TESTS="$tests" UI_TEST_PRODUCTS_PATH="$PRODUCTS" UI_TEST_BUILD_RECEIPT="$RECEIPT" make test-ui-build
    old_host="$(find "$PRODUCTS" -type d -name Portavoz.app -prune | head -1)"
    [[ -n "$old_host" ]] && manifest "$old_host" old
    timed tests-full-old env UI_TESTS="$tests" UI_TEST_LOCALES=en UI_TEST_RESULTS_DIR="$PWD/dist/ui-test-results/full" \
      UI_TEST_PRODUCTS_PATH="$PRODUCTS" UI_TEST_BUILD_RECEIPT="$RECEIPT" UI_TEST_ENFORCE_RUNTIME_BUDGET=false \
      make test-ui-run
    ;;
  *) echo "unknown mode $1" >&2; exit 2 ;;
esac
