#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <empty-destination-directory>" >&2
  exit 64
fi
if [[ -z "${GITHUB_PATH:-}" ]]; then
  echo "GITHUB_PATH is required." >&2
  exit 64
fi

version="2.46.0"
archive_sha256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
archive_url="https://github.com/yonaskolb/XcodeGen/releases/download/${version}/xcodegen.zip"
destination="$1"
if [[ -e "$destination" ]]; then
  echo "XcodeGen destination already exists: $destination" >&2
  exit 2
fi

umask 077
mkdir -p "$destination"
archive="$destination/xcodegen.zip"
curl --fail --location --silent --show-error "$archive_url" --output "$archive"
printf '%s  %s\n' "$archive_sha256" "$archive" | shasum -a 256 --check --status
unzip -q "$archive" -d "$destination/unpacked"

executables=()
while IFS= read -r executable; do
  executables+=("$executable")
done < <(find "$destination/unpacked" -type f -name xcodegen -perm -u+x -print)
if [[ ${#executables[@]} -ne 1 ]]; then
  echo "Pinned XcodeGen archive did not contain exactly one executable." >&2
  exit 2
fi
xcodegen="${executables[0]}"
if [[ "$($xcodegen --version)" != "Version: $version" ]]; then
  echo "Pinned XcodeGen executable reported an unexpected version." >&2
  exit 2
fi

printf '%s\n' "$(dirname "$xcodegen")" >> "$GITHUB_PATH"
echo "Installed pinned XcodeGen $version."
