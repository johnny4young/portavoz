#!/bin/bash
# Compiles the MLX Metal kernels and caches the Cmlx resource bundle
# (mlx-swift_Cmlx.bundle, which carries default.metallib) under .build/mlx/.
#
# Why this exists (D32): SwiftPM cannot compile Metal shaders from the CLI —
# only xcodebuild can (mlx-swift README) — so `swift build` products never
# contain the metallib and the embedded summarizer would fail at runtime with
# "Failed to load the default metallib". make-app.sh sources the bundle from
# this cache instead of the swift-build bin dir.
#
# The cache is keyed by the resolved mlx-swift version, so the one-time
# xcodebuild pass (~3 min) only re-runs when the dependency pin moves.
# Requires the Metal Toolchain: xcodebuild -downloadComponent MetalToolchain
set -euo pipefail
cd "$(dirname "$0")/.."

CACHE=.build/mlx
BUNDLE_NAME=mlx-swift_Cmlx.bundle

WANT=$(python3 -c "import json; print(next(p['state']['version'] for p in json.load(open('Package.resolved'))['pins'] if p['identity'] == 'mlx-swift'))")

if [[ -d "$CACHE/$BUNDLE_NAME" && -f "$CACHE/version" && "$(cat "$CACHE/version")" == "$WANT" ]]; then
  exit 0
fi

if ! xcrun -sdk macosx metal --version > /dev/null 2>&1; then
  echo "warning: Metal Toolchain not installed — the embedded MLX engine will be unavailable." >&2
  echo "         Install it with: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

echo "Compiling MLX Metal kernels (one-time per mlx-swift $WANT)…"
make project > /dev/null
# Plugin/macro validation is interactive-Xcode machinery; in this scripted
# one-shot build it only blocks (mlx-swift ships a CudaBuild plugin and
# MLXHuggingFace ships macros).
xcodebuild build -project Portavoz.xcodeproj -scheme Portavoz -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode-mlx -quiet \
  -skipPackagePluginValidation -skipMacroValidation

PRODUCT=".build/xcode-mlx/Build/Products/Debug/Portavoz.app/Contents/Resources/$BUNDLE_NAME"
if [[ ! -d "$PRODUCT" ]]; then
  echo "error: xcodebuild finished but $PRODUCT is missing" >&2
  exit 1
fi

mkdir -p "$CACHE"
rm -rf "${CACHE:?}/$BUNDLE_NAME"
cp -R "$PRODUCT" "$CACHE/"
echo "$WANT" > "$CACHE/version"
echo "OK → $CACHE/$BUNDLE_NAME (mlx-swift $WANT)"
