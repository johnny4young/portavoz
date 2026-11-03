#!/usr/bin/env bash
# One compiler for a pull request's UI lane: SwiftPM builds the app with the flags of
# its cached seed, and a package-free project builds only the XCUITest runner.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077

products="${UI_TEST_PRODUCTS_PATH:?UI_TEST_PRODUCTS_PATH must name the xctestproducts bundle}"
receipt="${UI_TEST_BUILD_RECEIPT:?UI_TEST_BUILD_RECEIPT must name the build receipt}"
flags=(-Xswiftc -warnings-as-errors)
started=$SECONDS

python3 scripts/ui_host.py verify
mkdir -p "$(dirname "$products")" "$(dirname "$receipt")"
rm -rf "$products"
rm -f "$receipt"
swift build --product portavoz-app "${flags[@]}"
xcodegen generate --spec project-ui-runner.yml --project . --quiet
runner_args=(
  -project PortavozUIRunner.xcodeproj
  -scheme Portavoz
  -destination "platform=macOS,arch=$(uname -m)"
  -configuration Debug
  -testProductsPath "$products"
)
# Nothing reads a hosted index, as in run-ui-tests.sh.
[[ -z "${CI:-}" ]] || runner_args+=(COMPILER_INDEX_STORE_ENABLE=NO)
xcodebuild build-for-testing "${runner_args[@]}"
scripts/make-ui-host.sh "$(python3 scripts/ui_host.py host-path "$products")" "${flags[@]}"
python3 scripts/ui_host.py inject "$products"
printf '%s\n' "$((SECONDS - started))" > "$receipt"
