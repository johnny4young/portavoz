#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
umask 077

version="0.65.0"
archive_sha256="79306a34e5c7cc55a220cd108cbb861dcad5f10138dcdf261e2624ae8b0a486b"
archive_url="https://github.com/realm/SwiftLint/releases/download/${version}/swiftlint_linux_amd64.zip"
scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/portavoz-swiftlint.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM

archive="$scratch/swiftlint.zip"
curl --fail --location --silent --show-error "$archive_url" --output "$archive"
printf '%s  %s\n' "$archive_sha256" "$archive" | sha256sum --check --status
unzip -q "$archive" -d "$scratch/unpacked"

mapfile -t executables < <(
  find "$scratch/unpacked" -type f -name swiftlint -perm -u+x -print
)
if [[ ${#executables[@]} -ne 1 ]]; then
  echo "Pinned SwiftLint archive did not contain exactly one executable." >&2
  exit 2
fi
swiftlint="${executables[0]}"
if [[ "$($swiftlint version)" != "$version" ]]; then
  echo "Pinned SwiftLint executable reported an unexpected version." >&2
  exit 2
fi

"$swiftlint" lint --strict --no-cache --reporter github-actions-logging
