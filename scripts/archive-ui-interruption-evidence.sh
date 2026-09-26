#!/usr/bin/env bash
set -euo pipefail
umask 077

if (( $# != 2 )) || [[ ! -d "$1" ]] || [[ "$2" != /* ]] || [[ -e "$2" ]] || [[ -L "$2" ]]; then
  echo "Expected an existing interruption-evidence directory and a new archive path." >&2
  exit 2
fi

source_directory="$(cd "$1" && pwd -P)"
archive="$2"
cd "$source_directory"
shopt -s nullglob
evidence=( *.log *.exit *.json *.xcresult )
if (( ${#evidence[@]} == 0 )); then
  echo "No interruption-control evidence to archive." >&2
  exit 2
fi

# Retain every case log, result bundle and qualification receipt, but not the
# disposable fixture's DerivedData or generated project. Upload one archive
# instead of tens of thousands of tiny build files.
partial="${archive}.partial-$$"
trap 'rm -f "$partial"' EXIT
COPYFILE_DISABLE=1 tar -czf "$partial" -- "${evidence[@]}"
ln "$partial" "$archive"
rm -f "$partial"
