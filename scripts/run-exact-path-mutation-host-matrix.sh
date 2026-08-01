#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-exact-path-mutation-host-matrix.sh --profile PROFILE

Runs three complete D218 mutation matrices from one clean committed checkout
and emits one threshold-free, content-free host receipt to stdout. PROFILE is
memory-8gb, memory-16gb, or reference. A review-required receipt is complete
evidence for human review, not a performance pass or engine decision. No raw
observation or aggregate output path is accepted.
EOF
}

profile=""
while (($# > 0)); do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      profile="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

case "$profile" in
  memory-8gb|memory-16gb|reference) ;;
  *) echo "--profile must be memory-8gb, memory-16gb, or reference" >&2; exit 64 ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  echo "exact-path mutation matrix requires a clean committed checkout" >&2
  exit 2
fi
commit="$(git rev-parse HEAD)"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "could not resolve the source commit" >&2
  exit 2
}
toolchain_output="$(swift --version)"
if [[ "$toolchain_output" != *"Apple Swift version "* ]]; then
  echo "could not resolve the Apple Swift toolchain" >&2
  exit 2
fi
toolchain="Apple Swift version ${toolchain_output#*Apple Swift version }"
toolchain="${toolchain%%$'\n'*}"

observations="$(mktemp "${TMPDIR:-/tmp}/portavoz-exact-path-mutations.XXXXXX")"
receipt="$(mktemp "${TMPDIR:-/tmp}/portavoz-exact-path-mutation-receipt.XXXXXX")"
chmod 600 "$observations" "$receipt"
trap 'rm -f "$observations" "$receipt"' EXIT

for _ in 1 2 3; do
  scripts/run-exact-path-mutation-benchmark.sh --matrix --runs 5 >>"$observations"
done

status=0
python3 scripts/exact_path_mutation_matrix.py \
  --input "$observations" \
  --profile "$profile" \
  --commit "$commit" \
  --toolchain "$toolchain" >"$receipt" || status=$?

if [[ "$(git rev-parse HEAD)" != "$commit" ]] || \
   [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  echo "source checkout changed during exact-path mutation collection" >&2
  exit 2
fi

if ((status <= 1)); then
  cat "$receipt"
fi
exit "$status"
