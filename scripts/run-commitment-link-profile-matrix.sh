#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run-commitment-link-profile-matrix.sh \
  --private-fixture FILE --output DIRECTORY --build BUILD

From one clean committed checkout, builds the Release CLI once, captures the
canonical public and owner-reviewed private commitment-link similarity
evidence with downloads disabled, replays both authorities, and atomically
publishes one owner-only comparison bundle. The bundle selects no candidate
and cannot enable serving behavior.
EOF
}

private_fixture=""
output=""
build=""
while (($# > 0)); do
  case "$1" in
    --private-fixture)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      private_fixture="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      output="$2"
      shift 2
      ;;
    --build)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      build="$2"
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

[[ -n "$private_fixture" ]] || {
  echo "--private-fixture is required" >&2
  exit 64
}
[[ -n "$output" ]] || {
  echo "--output is required" >&2
  exit 64
}
[[ -n "$build" ]] || {
  echo "--build is required" >&2
  exit 64
}

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

python3 scripts/commitment_link_quality.py validate-private \
  --fixture "$private_fixture" >/dev/null
python3 scripts/commitment_link_quality.py validate-profile-matrix-destination \
  --output "$output" >/dev/null

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  echo "commitment-link profile matrix requires a clean committed checkout" >&2
  exit 2
fi
commit="$(git rev-parse HEAD)"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "could not resolve the source commit" >&2
  exit 2
}

parent="$(dirname "$output")"
name="$(basename "$output")"
[[ "$name" != "." && "$name" != ".." ]] || {
  echo "invalid output directory" >&2
  exit 64
}
parent="$(cd "$parent" && pwd)"
output="$parent/$name"
lock="$output.lock"
stage="$output.stage.$$"
if ! mkdir -m 700 "$lock" 2>/dev/null; then
  echo "another commitment-link profile matrix owns this destination" >&2
  exit 2
fi
cleanup() {
  rm -rf "$stage"
  rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT
mkdir -m 700 "$stage"

public_fixture="$root/Fixtures/CommitmentLinkQuality/public-synthetic-v1.json"
public_observations="$stage/public-similarity.json"
public_replay="$stage/public-policy-replay.json"
private_observations="$stage/private-similarity.json"
private_replay="$stage/private-policy-replay.json"
matrix="$stage/profile-matrix.json"

swift build -c release --product portavoz-cli
bin_path="$(swift build -c release --show-bin-path)"
cli="$bin_path/portavoz-cli"
[[ -x "$cli" ]] || {
  echo "Release CLI was not produced" >&2
  exit 2
}

"$cli" bench-commitment-link-similarity \
  --fixture "$public_fixture" \
  --output "$public_observations" \
  --build "$build" \
  --commit "$commit" \
  --asset-download never
python3 scripts/commitment_link_quality.py validate-similarity \
  --fixture "$public_fixture" \
  --observations "$public_observations" >/dev/null
python3 scripts/commitment_link_quality.py replay-similarity \
  --fixture "$public_fixture" \
  --observations "$public_observations" \
  --output "$public_replay" >/dev/null

"$cli" bench-private-commitment-link-similarity \
  --fixture "$private_fixture" \
  --output "$private_observations" \
  --build "$build" \
  --commit "$commit" \
  --asset-download never
python3 scripts/commitment_link_quality.py validate-private-similarity \
  --fixture "$private_fixture" \
  --observations "$private_observations" >/dev/null
python3 scripts/commitment_link_quality.py replay-private-similarity \
  --fixture "$private_fixture" \
  --observations "$private_observations" \
  --output "$private_replay" >/dev/null

python3 scripts/commitment_link_quality.py compare-profile-matrix \
  --public-fixture "$public_fixture" \
  --public-observations "$public_observations" \
  --public-replay "$public_replay" \
  --private-fixture "$private_fixture" \
  --private-observations "$private_observations" \
  --private-replay "$private_replay" \
  --expected-build "$build" \
  --expected-commit "$commit" \
  --output "$matrix" >/dev/null
python3 scripts/commitment_link_quality.py validate-profile-matrix \
  --public-fixture "$public_fixture" \
  --public-observations "$public_observations" \
  --public-replay "$public_replay" \
  --private-fixture "$private_fixture" \
  --private-observations "$private_observations" \
  --private-replay "$private_replay" \
  --expected-build "$build" \
  --expected-commit "$commit" \
  --matrix "$matrix" >/dev/null

for artifact in \
  "$public_observations" "$public_replay" \
  "$private_observations" "$private_replay" "$matrix"; do
  [[ -f "$artifact" && ! -L "$artifact" ]] || {
    echo "matrix artifact is missing or unsafe: $artifact" >&2
    exit 2
  }
  [[ "$(stat -f '%Lp' "$artifact")" == "600" ]] || {
    echo "matrix artifact is not owner-only: $artifact" >&2
    exit 2
  }
done

if [[ "$(git rev-parse HEAD)" != "$commit" ]] || \
   [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  echo "source checkout changed during commitment-link profile collection" >&2
  exit 2
fi
[[ ! -e "$output" && ! -L "$output" ]] || {
  echo "profile matrix destination appeared during collection" >&2
  exit 2
}
mv "$stage" "$output"
rmdir "$lock"
trap - EXIT
printf 'Commitment-link profile matrix: %s\n' "$output"
