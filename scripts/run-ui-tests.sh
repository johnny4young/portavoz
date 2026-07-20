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

# Respect an already-selected toolchain (CI pins the newest Xcode via
# xcode-select); the hardcoded path is only the local-dev default.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Compile the app and UI bundle once. English and Spanish then reuse the same
# products through test-without-building instead of paying the build cost twice.
xcodebuild build-for-testing "${common[@]}"

for locale in $locales; do
  test_args=("${common[@]}")
  case "$locale" in
    default) ;;
    en) test_args+=(-testLanguage en -testRegion US) ;;
    es) test_args+=(-testLanguage es -testRegion ES) ;;
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
