#!/usr/bin/env bash
# Shows a PR's synthetic pr-* screenshots. After looking at each one, --publish
# pushes them to the orphan pr-evidence branch and prints the description markdown.
set -euo pipefail

publish=false
if [[ "${1:-}" == --publish ]]; then
  publish=true
  shift
fi
pr="${1:-}"
run="${2:-}"
if [[ ! "$pr" =~ ^[0-9]+$ || ! "$run" =~ ^[0-9]+$ ]]; then
  echo "usage: scripts/pr-evidence.sh [--publish] <pull-request> <run-id>" >&2
  exit 64
fi

repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
images_dir="$(git rev-parse --show-toplevel)/dist/pr-evidence/$run"
rm -rf "$images_dir"
gh run download "$run" --repo "$repository" --name "pr-screenshots-$run" --dir "$images_dir"
images=("$images_dir"/pr-*.png)
if [[ ! -f "${images[0]}" ]]; then
  echo "Run $run has no pr-* screenshots." >&2
  exit 66
fi

if [[ "$publish" != true ]]; then
  printf '%s\n' "${images[@]}"
  echo "Look at each image, then run this again with --publish." >&2
  exit 0
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/portavoz-pr-evidence.XXXXXX")"
worktree="$scratch/branch"
cleanup() {
  git worktree remove --force "$worktree" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT

git worktree add --quiet --detach "$worktree"
if git ls-remote --exit-code --heads origin pr-evidence >/dev/null; then
  git -C "$worktree" fetch --quiet origin pr-evidence
  git -C "$worktree" checkout --quiet -B pr-evidence FETCH_HEAD
else
  git -C "$worktree" switch --quiet --orphan pr-evidence
fi

mkdir -p "$worktree/pr-$pr"
cp "${images[@]}" "$worktree/pr-$pr/"
git -C "$worktree" add "pr-$pr"
if ! git -C "$worktree" diff --cached --quiet; then
  git -C "$worktree" commit --quiet -m "evidence: screenshots for pull request $pr from run $run"
  git -C "$worktree" push --quiet origin pr-evidence
fi

for image in "${images[@]}"; do
  name="$(basename "$image")"
  printf '![%s](https://raw.githubusercontent.com/%s/pr-evidence/pr-%s/%s)\n' "${name%.png}" "$repository" "$pr" "$name"
done
