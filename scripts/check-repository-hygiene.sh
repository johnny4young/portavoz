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

# Ticket keys and local execution-band identifiers belong in private planning,
# not tracked repository files. Durable public architecture references such as
# D116 and Band 6 are intentionally not ticket keys and remain valid project
# documentation.
private_ref_pattern='(^|[^[:alnum:]_])(ENG|JIRA|TICKET|TASK|STORY|EPIC|SPIKE|PORTAVOZ|PV|APT|APUN)-[0-9]{1,6}([^[:alnum:]_]|$)'
if ! printf 'APT-%s\nAPUN-%s\n' 7 5 | grep -Eq "$private_ref_pattern"; then
  echo "Internal-reference pattern does not recognize local execution bands." >&2
  failures=1
fi
ticket_refs="$(
  git grep -nEI "$private_ref_pattern" -- \
    . 2>/dev/null || true
)"
if [[ -n "$ticket_refs" ]]; then
  echo "Internal ticket references found in tracked repository files:" >&2
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
  private-evidence/commitment-link/private-pack.json
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
python3 -m unittest Tests.Tooling.test_collect_field_evidence
python3 -m unittest Tests.Tooling.test_release_reliability
python3 -m unittest Tests.Tooling.test_candidate_automation
bash -n scripts/run-resource-baseline.sh
bash -n scripts/run-resource-recording-baseline.sh
bash -n scripts/run-exact-path-mutation-benchmark.sh
bash -n scripts/run-exact-path-mutation-host-matrix.sh
bash -n scripts/run-correction-composition-benchmark.sh
bash -n scripts/run-commitment-radar-benchmark.sh
python3 -m unittest Tests.Tooling.test_commitment_quality
python3 scripts/commitment_quality.py validate \
  --fixture Fixtures/CommitmentQuality/public-synthetic-v1.json
python3 -m unittest Tests.Tooling.test_meeting_memory_graph_quality
python3 -m unittest Tests.Tooling.test_meeting_memory_graph_query_receipt
python3 scripts/meeting_memory_graph_quality.py verify-public \
  --fixture Fixtures/MeetingMemoryGraph/public-synthetic-v1.json
python3 -m unittest Tests.Tooling.test_commitment_link_quality
python3 -m unittest Tests.Tooling.test_commitment_link_policy_review
python3 scripts/commitment_link_quality.py validate \
  --fixture Fixtures/CommitmentLinkQuality/public-synthetic-v1.json
python3 -m unittest Tests.Tooling.test_resource_baseline
python3 -m unittest Tests.Tooling.test_exact_path_matrix
python3 -m unittest Tests.Tooling.test_exact_path_mutation_matrix
python3 -m unittest Tests.Tooling.test_exact_path_mutation_cross_host
python3 -m unittest Tests.Tooling.test_exact_path_mutation_baseline
python3 -m unittest Tests.Tooling.test_exact_path_cross_host
python3 -m unittest Tests.Tooling.test_exact_path_baseline
python3 -m unittest Tests.Tooling.test_ask_quality
python3 -m unittest Tests.Tooling.test_ask_quality_pair
python3 -m unittest Tests.Tooling.test_retrieval_chunk_resource_fixture
python3 -m unittest Tests.Tooling.test_retrieval_chunk_evidence
python3 -m unittest Tests.Tooling.test_semantic_scale_manifest
python3 scripts/ask_quality.py verify-public \
  --fixture Fixtures/AskQuality/public-synthetic-v1.json
python3 scripts/ask_quality.py verify-public \
  --fixture Fixtures/AskQuality/public-synthetic-v2.json
python3 scripts/retrieval_chunk_resource_fixture.py verify-public \
  --fixture Fixtures/RetrievalChunkResource/public-bilingual-homogeneous-v1.json
python3 -m unittest Tests.Tooling.test_apuntador_validation
python3 -m unittest Tests.Tooling.test_apuntador_web_fixture
python3 scripts/apuntador_validation.py verify-public \
  --fixture Fixtures/ApuntadorValidation/public-bilingual-v1.json \
  --budget docs/evidence/apuntador-validation-budget.json
python3 scripts/apuntador_web_fixture.py verify-public \
  --fixture Fixtures/ApuntadorWeb/public-local-v1.json
python3 -m unittest Tests.Tooling.test_ui_test_scope
python3 -m unittest Tests.Tooling.test_ui_test_runtime
python3 -m unittest Tests.Tooling.test_run_ui_tests
python3 -m unittest Tests.Tooling.test_ui_test_host_preflight
python3 -m unittest Tests.Tooling.test_meeting_detail_contract
python3 -m unittest Tests.Tooling.test_meeting_detail_performance

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

echo "Repository hygiene passed: no tracked local state or ticket-key leakage."
