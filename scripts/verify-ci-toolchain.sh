#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <macOS-major> <Xcode-version>" >&2
  exit 64
fi

expected_os_major="$1"
expected_xcode="$2"

case "$expected_os_major" in
  15|26) ;;
  *) echo "Unsupported CI macOS major: $expected_os_major" >&2; exit 64 ;;
esac
if [[ ! "$expected_xcode" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Invalid expected Xcode version: $expected_xcode" >&2
  exit 64
fi

actual_os="$(sw_vers -productVersion)"
actual_xcode="$(xcodebuild -version | sed -n '1s/^Xcode //p')"
if [[ -z "${DEVELOPER_DIR:-}" || ! -d "$DEVELOPER_DIR" ]]; then
  echo "DEVELOPER_DIR does not identify an installed Xcode toolchain." >&2
  exit 2
fi
developer_dir="$(cd "$DEVELOPER_DIR" && pwd -P)"
swift_path="$(xcrun --find swift)"

if [[ "$actual_os" != "$expected_os_major".* ]]; then
  echo "Expected macOS $expected_os_major.x, found $actual_os." >&2
  exit 2
fi
if [[ "$actual_xcode" != "$expected_xcode" ]]; then
  echo "Expected Xcode $expected_xcode, found ${actual_xcode:-unknown}." >&2
  exit 2
fi
if [[ "$swift_path" != "$developer_dir"/* ]]; then
  echo "xcrun resolved Swift outside the deterministic toolchain." >&2
  echo "DEVELOPER_DIR=$developer_dir" >&2
  echo "swift=$swift_path" >&2
  exit 2
fi

echo "Toolchain contract: macOS $actual_os, Xcode $actual_xcode, $developer_dir"
swift --version
xcrun --show-sdk-version
