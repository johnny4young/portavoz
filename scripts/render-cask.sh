#!/usr/bin/env bash
# Fills the cask template for the tap and drops its template-only header.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <version> <sha256>" >&2
  exit 64
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sed -e '1,/^cask /{/^#/d;}' -e "s/__VERSION__/$1/" -e "s/__SHA256__/$2/" \
  "$root/packaging/Casks/portavoz.rb"
