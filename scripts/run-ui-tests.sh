#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

locales="${UI_TEST_LOCALES:-default}"
tests="${UI_TESTS:-}"
results_root="${UI_TEST_RESULTS_DIR:-$ROOT/dist/ui-test-results}"
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
xcodebuild build-for-testing "${common[@]}"

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
  xcodebuild test-without-building \
    "${test_args[@]}" \
    -resultBundlePath "$result_bundle"
done
