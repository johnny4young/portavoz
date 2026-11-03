#!/usr/bin/env bash
# Admits a Swift build seed only within the size limit, and says so when it does not.
set -euo pipefail

limit_kib=6291456
size_kib="$(du -sk .build | awk '{print $1}')"
echo "Swift build cache: $size_kib KiB (limit $limit_kib KiB)"
if (( size_kib <= limit_kib )); then
  echo "save=true" >> "$GITHUB_OUTPUT"
else
  echo "::warning title=Swift cache too large::.build is $size_kib KiB, over the $limit_kib KiB limit, so no seed was saved and later runs restore an older one."
fi
