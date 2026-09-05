#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
    echo "long-capture baseline error: $*" >&2
    exit 64
}

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    fail "the worktree must be clean so the receipt matches one exact commit"
fi

COMMIT="$(git rev-parse HEAD)"
SHORT_COMMIT="$(git rev-parse --short=12 HEAD)"
OUTPUT="${1:-$ROOT/dist/long-capture/$SHORT_COMMIT.json}"
case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$ROOT/$OUTPUT" ;;
esac
if [[ -e "$OUTPUT" ]]; then
    fail "output already exists: $OUTPUT"
fi
umask 077
mkdir -p "$(dirname "$OUTPUT")"
TEMP_OUTPUT="$(mktemp "$OUTPUT.partial.XXXXXX")"
trap 'rm -f "$TEMP_OUTPUT"' EXIT

swift build -c release --product portavoz-cli
"$ROOT/.build/release/portavoz-cli" bench-capture \
    --duration-seconds 10800 \
    --chunk-frames 4800 \
    --source-commit "$COMMIT" \
    --output "$TEMP_OUTPUT"

python3 scripts/long_capture_evidence.py \
    --report "$TEMP_OUTPUT" \
    --commit "$COMMIT"
if [[ "$(git rev-parse HEAD)" != "$COMMIT" ]] \
    || [[ -n "$(git status --porcelain --untracked-files=all)" ]]
then
    fail "the source commit or worktree changed during collection"
fi
mv "$TEMP_OUTPUT" "$OUTPUT"
chmod 600 "$OUTPUT"
trap - EXIT
echo "Long-capture baseline: $OUTPUT"
