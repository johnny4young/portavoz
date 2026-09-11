#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift_bin="$(xcrun --find swift)"
sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
scratch="${PORTAVOZ_IOS_PORTABILITY_SCRATCH:-$ROOT/.build/ios-portability}"
triple="arm64-apple-ios17.0-simulator"
targets=(PortavozCore StorageKit ApplicationKit IntegrationsKit)

if [[ ! -x "$swift_bin" ]]; then
  echo "xcrun did not resolve an executable Swift compiler: $swift_bin" >&2
  exit 2
fi
if [[ ! -d "$sdk_path" ]]; then
  echo "xcrun did not resolve an installed iPhone Simulator SDK: $sdk_path" >&2
  exit 2
fi
if [[ ! "$sdk_version" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
  echo "Invalid iPhone Simulator SDK version: $sdk_version" >&2
  exit 2
fi
if (( ${sdk_version%%.*} < 26 )); then
  echo "IOS-READY requires an iPhone Simulator 26+ SDK; found $sdk_version." >&2
  exit 2
fi

printf 'iOS portability contract: sdk=%s triple=%s targets=%s\n' \
  "$sdk_version" "$triple" "${targets[*]}"

# Keep one sequential scratch graph for every target. This avoids four package
# resolutions and avoids naive concurrent Swift/Clang jobs contending for the
# same dependency build state.
for target in "${targets[@]}"; do
  echo "==> iOS compile: $target"
  "$swift_bin" build \
    --scratch-path "$scratch" \
    --triple "$triple" \
    --sdk "$sdk_path" \
    --target "$target"
done

echo "iOS portability passed: ${#targets[@]} targets compiled against SDK $sdk_version."
