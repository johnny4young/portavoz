#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failures=0

forbidden_tracked='^(\.agents|\.claude|\.codex|\.design-sync|\.planning|\.tickets|plans|tickets|docs/plans|docs/tickets|artifacts|screenshots|test-results)/|^docs/(ROADMAP\.md|refactor-20260714\.md|STRATEGY-20260716\.md)$|(^|/)(DerivedData|xcuserdata)/|\.xcodeproj/|\.xcresult/|\.profraw$|\.profdata$|\.xcactivitylog$'
tracked_forbidden="$(git ls-files | grep -E "$forbidden_tracked" || true)"
if [[ -n "$tracked_forbidden" ]]; then
  echo "Ephemeral/generated files must not be tracked:" >&2
  echo "$tracked_forbidden" >&2
  failures=1
fi

tracked_ignored="$(git ls-files -ci --exclude-standard || true)"
if [[ -n "$tracked_ignored" ]]; then
  echo "Tracked files also match .gitignore:" >&2
  echo "$tracked_ignored" >&2
  failures=1
fi

# Ticket keys belong in GitHub, not production/test/tooling identifiers or
# comments. Durable public architecture references such as D116 and Band 6 are
# intentionally not ticket keys and remain valid project documentation.
ticket_refs="$(
  git grep -nEI '\b(ENG|JIRA|TICKET|TASK|STORY|EPIC|SPIKE|PORTAVOZ|PV)-[0-9]{1,6}\b' -- \
    Sources Tests scripts .github Makefile project.yml 2>/dev/null || true
)"
if [[ -n "$ticket_refs" ]]; then
  echo "Internal ticket references found in tracked implementation files:" >&2
  echo "$ticket_refs" >&2
  failures=1
fi

mutable_actions="$(
  grep -nE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]+[^[:space:]]+@' \
    .github/workflows/*.yml | \
    grep -Ev '@[0-9a-f]{40}([[:space:]]|#|$)' || true
)"
if [[ -n "$mutable_actions" ]]; then
  echo "GitHub Actions must use immutable full-length commit SHAs:" >&2
  echo "$mutable_actions" >&2
  failures=1
fi

ignore_probes=(
  .agents/session.md
  .codex/plan.md
  .design-sync/config.json
  .planning/next-slice.md
  .tickets/LOCAL-123.md
  plans/local-plan.md
  tickets/LOCAL-123.md
  docs/plans/local-plan.md
  docs/tickets/LOCAL-123.md
  docs/ROADMAP.md
  docs/refactor-20260714.md
  docs/STRATEGY-20260716.md
  PLAN.md
  TODO.md
  HANDOFF.md
  reports/local-audit.md
  scratch/notes.md
  artifacts/ui/result.txt
  screenshots/local-smoke.png
  test-results/run.json
  local-ui.xcresult/Info.plist
)

for probe in "${ignore_probes[@]}"; do
  if ! git check-ignore --quiet "$probe"; then
    echo "Expected local artifact is not ignored: $probe" >&2
    failures=1
  fi
done

python3 scripts/ui_test_scope.py --validate-catalog
python3 -m unittest Tests.Tooling.test_ui_test_scope

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

echo "Repository hygiene passed: no tracked local state or ticket-key leakage."
