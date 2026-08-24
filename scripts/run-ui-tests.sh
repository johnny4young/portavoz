#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

locales="${UI_TEST_LOCALES:-default}"
tests="${UI_TESTS:-}"
results_root="${UI_TEST_RESULTS_DIR:-$ROOT/dist/ui-test-results}"
runtime_budget="${UI_TEST_RUNTIME_BUDGET:-$ROOT/docs/evidence/ui-test-runtime-budget.json}"
require_runtime_receipt="${UI_TEST_REQUIRE_RUNTIME_RECEIPT:-true}"
enforce_runtime_budget="${UI_TEST_ENFORCE_RUNTIME_BUDGET:-true}"
arch="$(uname -m)"

common=(
  -project Portavoz.xcodeproj
  -scheme Portavoz
  -destination "platform=macOS,arch=$arch"
  -configuration Debug
  -skipPackagePluginValidation
  -skipMacroValidation
)

only_testing=()
selector_count=0
for test in $tests; do
  case "$test" in
    PortavozUITests/*)
      only_testing+=("-only-testing:$test")
      selector_count=$((selector_count + 1))
      ;;
    *) echo "Invalid UI-test selector: $test" >&2; exit 2 ;;
  esac
done

mkdir -p "$results_root"

keyboard_navigation_selector="PortavozUITests/SkillsSettingsUITests/testSkillReceiptRestoresKeyboardFocusAndPassesAccessibilityAudit"
if [[ -z "$tests" || " $tests " == *" $keyboard_navigation_selector "* ]]; then
  # Keyboard Navigation is a system preference, not an app launch argument.
  # Snapshot it before mutation and restore it even when xcodebuild is
  # interrupted. Unrelated scoped suites never touch the preference.
  keyboard_ui_mode_was_set=false
  keyboard_ui_mode=""
  if keyboard_ui_mode="$(defaults read -g AppleKeyboardUIMode 2>/dev/null)"; then
    keyboard_ui_mode_was_set=true
  fi
  restore_keyboard_ui_mode() {
    if [[ "$keyboard_ui_mode_was_set" == true ]]; then
      defaults write -g AppleKeyboardUIMode -int "$keyboard_ui_mode" >/dev/null
    else
      defaults delete -g AppleKeyboardUIMode >/dev/null 2>&1 || true
    fi
  }
  trap restore_keyboard_ui_mode EXIT HUP INT TERM
  defaults write -g AppleKeyboardUIMode -int 3 >/dev/null
fi

# An explicit DEVELOPER_DIR wins. Otherwise xcodebuild follows the active
# xcode-select toolchain (CI selects its newest Xcode before invoking us).
# Only a Command Line Tools selection needs the conventional local fallback.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  selected_developer_dir="$(xcode-select -p)"
  if [[ "$selected_developer_dir" == */CommandLineTools ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

# Real-recording lane (T30/D316 era): tests read PORTAVOZ_TEST_AUDIO_ROOT from
# the RUNNER process, and xcodebuild only forwards TEST_RUNNER_-prefixed
# variables there — export both spellings so the override reaches the tests
# regardless of how the runner is spawned.
if [[ -n "${PORTAVOZ_TEST_AUDIO_ROOT:-}" ]]; then
  export TEST_RUNNER_PORTAVOZ_TEST_AUDIO_ROOT="$PORTAVOZ_TEST_AUDIO_ROOT"
fi

# Compile the app and UI bundle once. English and Spanish then reuse the same
# products through test-without-building instead of paying the build cost twice.
build_started=$SECONDS
xcodebuild build-for-testing "${common[@]}"
build_duration=$((SECONDS - build_started))

for locale in $locales; do
  test_args=("${common[@]}")
  case "$locale" in
    default)
      unset PORTAVOZ_UI_TEST_LOCALE TEST_RUNNER_PORTAVOZ_UI_TEST_LOCALE
      ;;
    en)
      export PORTAVOZ_UI_TEST_LOCALE=en
      export TEST_RUNNER_PORTAVOZ_UI_TEST_LOCALE=en
      test_args+=(-testLanguage en -testRegion US)
      ;;
    es)
      export PORTAVOZ_UI_TEST_LOCALE=es
      export TEST_RUNNER_PORTAVOZ_UI_TEST_LOCALE=es
      test_args+=(-testLanguage es -testRegion ES)
      ;;
    *) echo "Unsupported UI-test locale: $locale" >&2; exit 2 ;;
  esac

  result_bundle="$results_root/$locale.xcresult"
  rm -rf "$result_bundle"
  selector_label="$selector_count scoped selectors"
  if [[ -z "$tests" ]]; then
    selector_label="all tests"
  else
    test_args+=("${only_testing[@]}")
  fi
  echo "Running $selector_label in locale: $locale"
  test_started=$SECONDS
  set +e
  xcodebuild test-without-building \
    "${test_args[@]}" \
    -resultBundlePath "$result_bundle"
  test_status=$?
  set -e
  test_wall_duration=$((SECONDS - test_started))

  receipt_status=0
  if [[ "$require_runtime_receipt" == true ]]; then
    if [[ ! -d "$result_bundle" ]]; then
      echo "Missing XCUITest result bundle for runtime receipt: $result_bundle" >&2
      receipt_status=2
    else
      runtime_args=(
        --result "$result_bundle"
        --budget "$runtime_budget"
        --output "$results_root/$locale-runtime.json"
        --locale "$locale"
        --selector-count "$selector_count"
        --build-duration "$build_duration"
        --wall-duration "$test_wall_duration"
      )
      if [[ "$enforce_runtime_budget" == true ]]; then
        runtime_args+=(--enforce)
      fi
      set +e
      scripts/ui_test_runtime.py "${runtime_args[@]}"
      receipt_status=$?
      set -e
    fi
  fi

  # Preserve the real XCTest failure as the primary signal while still
  # attempting a content-free receipt for diagnosis and trend evidence.
  if (( test_status != 0 )); then
    exit "$test_status"
  fi
  if (( receipt_status != 0 )); then
    exit "$receipt_status"
  fi
done
