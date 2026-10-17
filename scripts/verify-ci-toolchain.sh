#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <macOS-major> <Xcode-version> [standalone-Swift-version]" >&2
  exit 64
fi

expected_os_major="$1"
expected_xcode="$2"
expected_swift="${3:-}"
if [[ -n "$expected_swift" && "$1:$2:$expected_swift" != "15:26.3:6.3.3" ]]; then
  echo "Standalone Swift is pinned exclusively to Sequoia/Xcode 26.3/Swift 6.3.3." >&2
  exit 64
fi

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
if [[ -n "$expected_swift" ]]; then
  identifier="org.swift.633202606251a"
  toolchain="$HOME/Library/Developer/Toolchains/swift-$expected_swift-RELEASE.xctoolchain"
  if [[ "${TOOLCHAINS:-}" != "$identifier" \
        || "$(plutil -extract CFBundleIdentifier raw "$toolchain/Info.plist")" != "$identifier" \
        || "$swift_path" != "$toolchain/usr/bin/swift" \
        || "$(command -v swift)" != "$swift_path" ]]; then
    echo "Standalone Swift selector, bundle, xcrun, and shell must identify the same pinned toolchain." >&2
    exit 2
  fi
  if [[ "$(swift --version)" != *"Swift version $expected_swift "* ]]; then
    echo "Standalone Swift version is not the pinned release." >&2
    exit 2
  fi
elif [[ "$swift_path" != "$developer_dir"/* ]]; then
  echo "xcrun resolved Swift outside the deterministic toolchain." >&2
  echo "DEVELOPER_DIR=$developer_dir" >&2
  echo "swift=$swift_path" >&2
  exit 2
fi

echo "Toolchain contract: macOS $actual_os, Xcode $actual_xcode, $developer_dir"
swift --version
xcrun --show-sdk-version
