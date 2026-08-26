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

keyboard_ui_mode_should_restore=false
keyboard_ui_mode_was_set=false
keyboard_ui_mode=""
web_fixture_pid=""
web_fixture_ready=""

restore_keyboard_ui_mode() {
  [[ "$keyboard_ui_mode_should_restore" == true ]] || return 0
  if [[ "$keyboard_ui_mode_was_set" == true ]]; then
    defaults write -g AppleKeyboardUIMode -int "$keyboard_ui_mode" >/dev/null
  else
    defaults delete -g AppleKeyboardUIMode >/dev/null 2>&1 || true
  fi
}

stop_web_fixture() {
  [[ -n "$web_fixture_pid" ]] || return 0
  if kill -0 "$web_fixture_pid" 2>/dev/null; then
    kill -TERM "$web_fixture_pid" 2>/dev/null || true
    for _attempt in {1..250}; do
      kill -0 "$web_fixture_pid" 2>/dev/null || break
      sleep 0.02
    done
    if kill -0 "$web_fixture_pid" 2>/dev/null; then
      kill -INT "$web_fixture_pid" 2>/dev/null || true
    fi
  fi
  wait "$web_fixture_pid" 2>/dev/null || true
  [[ -z "$web_fixture_ready" ]] || rm -f "$web_fixture_ready"
}

cleanup_ui_test_runner() {
  stop_web_fixture
  restore_keyboard_ui_mode
}
trap cleanup_ui_test_runner EXIT HUP INT TERM

keyboard_navigation_selector="PortavozUITests/SkillsSettingsUITests/testSkillReceiptRestoresKeyboardFocusAndPassesAccessibilityAudit"
if [[ -z "$tests" || " $tests " == *" $keyboard_navigation_selector "* ]]; then
  # Keyboard Navigation is a system preference, not an app launch argument.
  # Snapshot it before mutation and restore it even when xcodebuild is
  # interrupted. Unrelated scoped suites never touch the preference.
  keyboard_ui_mode_should_restore=true
  if keyboard_ui_mode="$(defaults read -g AppleKeyboardUIMode 2>/dev/null)"; then
    keyboard_ui_mode_was_set=true
  fi
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

# XCUITest runners are App Sandbox processes, so they cannot launch the Xcode
# Python shim themselves. Own the deterministic loopback fixture here, outside
# the runner, and forward only its atomic content-free descriptor. One process
# is reused by every requested locale and is terminated by the runner trap.
web_fixture_selector="PortavozUITests/LibraryUITests/testAskConversationAnswersAndSeeksToExactCitation"
needs_web_fixture=false
if [[ -z "$tests" ]]; then
  needs_web_fixture=true
else
  for test in $tests; do
    if [[ "$web_fixture_selector" == "$test"* ]]; then
      needs_web_fixture=true
      break
    fi
  done
fi

if [[ "$needs_web_fixture" == true ]]; then
  web_fixture_ready="$results_root/apuntador-web-fixture.json"
  web_fixture_log="$results_root/apuntador-web-fixture.log"
  rm -f "$web_fixture_ready" "$web_fixture_log"
  python3 scripts/apuntador_web_fixture.py serve \
    --fixture Fixtures/ApuntadorWeb/public-local-v1.json \
    --ready-file "$web_fixture_ready" \
    >"$web_fixture_log" 2>&1 &
  web_fixture_pid=$!
  # Normal startup is immediate. The bounded 30-second ceiling exists only for
  # heavily contended hosted runners and does not delay the success path.
  for _attempt in {1..1500}; do
    [[ -f "$web_fixture_ready" ]] && break
    kill -0 "$web_fixture_pid" 2>/dev/null || break
    sleep 0.02
  done
  if [[ ! -f "$web_fixture_ready" ]] \
      || ! kill -0 "$web_fixture_pid" 2>/dev/null; then
    echo "Deterministic Apuntador Web fixture did not start." >&2
    cat "$web_fixture_log" >&2 || true
    exit 2
  fi
  export PORTAVOZ_UI_WEB_FIXTURE_DESCRIPTOR="$web_fixture_ready"
  export TEST_RUNNER_PORTAVOZ_UI_WEB_FIXTURE_DESCRIPTOR="$web_fixture_ready"
fi

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
