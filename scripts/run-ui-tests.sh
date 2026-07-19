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
for test in $tests; do
  case "$test" in
    PortavozUITests/*) only_testing+=("-only-testing:$test") ;;
    *) echo "Invalid UI-test selector: $test" >&2; exit 2 ;;
  esac
done

mkdir -p "$results_root"

# Compile the app and UI bundle once. English and Spanish then reuse the same
# products through test-without-building instead of paying the build cost twice.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild build-for-testing "${common[@]}"

for locale in $locales; do
  language=()
  case "$locale" in
    default) ;;
    en) language=(-testLanguage en -testRegion US) ;;
    es) language=(-testLanguage es -testRegion ES) ;;
    *) echo "Unsupported UI-test locale: $locale" >&2; exit 2 ;;
  esac

  result_bundle="$results_root/$locale.xcresult"
  rm -rf "$result_bundle"
  echo "Running ${#only_testing[@]} scoped selectors in locale: $locale"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild test-without-building \
      "${common[@]}" \
      "${language[@]}" \
      "${only_testing[@]}" \
      -resultBundlePath "$result_bundle"
done
