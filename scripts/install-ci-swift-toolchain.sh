#!/usr/bin/env bash
# CI-only compiler selection; Xcode remains the SDK/XCTest/Metal owner.
set -euo pipefail

if [[ $# -ne 0 || "${GITHUB_ACTIONS:-}" != true \
      || -z "${GITHUB_ENV:-}" || -z "${GITHUB_PATH:-}" \
      || -z "${RUNNER_TEMP:-}" ]]; then
  echo "This installer requires the GitHub Actions runner environment and no arguments." >&2
  exit 64
fi
if [[ "$(sw_vers -productVersion)" != 15.* ]]; then
  echo "The standalone Swift toolchain is restricted to the Sequoia CI lane." >&2
  exit 64
fi

readonly version="6.3.3"
readonly identifier="org.swift.633202606251a"
readonly archive_sha256="ee82e57774d6650f94aa06302435d6f44a055b9411698db8ecb85d9a3bcc91d0"
readonly archive_url="https://download.swift.org/swift-${version}-release/xcode/swift-${version}-RELEASE/swift-${version}-RELEASE-osx.pkg"
readonly toolchain="$HOME/Library/Developer/Toolchains/swift-${version}-RELEASE.xctoolchain"
umask 077
scratch="$(mktemp -d "$RUNNER_TEMP/portavoz-ci-swift.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM
archive="$scratch/swift.pkg"
curl --fail --location --silent --show-error --retry 2 --retry-max-time 300 \
  --connect-timeout 30 --max-time 120 "$archive_url" --output "$archive"
printf '%s  %s\n' "$archive_sha256" "$archive" | shasum -a 256 --check --status
signature="$(pkgutil --check-signature "$archive")"
if [[ "$signature" != *"Developer ID Installer: Swift Open Source (V9AUD2URP3)"* \
      || "$signature" != *"Status: signed by a developer certificate issued by Apple for distribution"* ]]; then
  echo "Pinned Swift package did not have the expected trusted Swift Open Source signature." >&2
  exit 2
fi
# No sudo, global Xcode selection, or latest-version lookup. This affects only
# the disposable runner's home and only after checksum/signature verification.
installer -target CurrentUserHomeDirectory -pkg "$archive"
if [[ "$(plutil -extract CFBundleIdentifier raw "$toolchain/Info.plist")" != "$identifier" \
      || ! -x "$toolchain/usr/bin/swift" ]]; then
  echo "Installed Swift toolchain identity is not the pinned release." >&2
  exit 2
fi
if [[ "$("$toolchain/usr/bin/swift" --version)" != *"Swift version $version "* ]]; then
  echo "Installed Swift compiler did not report the pinned version." >&2
  exit 2
fi
printf 'TOOLCHAINS=%s\n' "$identifier" >> "$GITHUB_ENV"
printf '%s\n' "$toolchain/usr/bin" >> "$GITHUB_PATH"
echo "Installed checksum/signature-pinned Swift $version for Sequoia CI."
