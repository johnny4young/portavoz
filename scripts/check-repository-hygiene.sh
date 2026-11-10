#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

node --test scripts/ci_time_*.test.mjs scripts/repository_hygiene.test.mjs

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

conflict_markers="$(git grep -nEI '^(<{7}|\|{7}|>{7})( |$)' -- . 2>/dev/null || true)"
if [[ -n "$conflict_markers" ]]; then
  echo "Unresolved merge-conflict markers in tracked files:" >&2
  echo "$conflict_markers" >&2
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

# A UI run started from prebuilt products does not give the XCTest process the
# app's language: `-testLanguage` reaches the app, `Locale.current` in the test
# does not follow. Locale-aware expectations must read the locale the run declared
# (`UITestLocale.environmentLocale`), which the runner forwards explicitly.
ambient_locale_reads="$(
  grep -rn 'Locale\.current' Tests/PortavozUITests \
    | grep -v 'UITestSupport.swift:.*///' || true
)"
if [[ -n "$ambient_locale_reads" ]]; then
  echo "UI tests must read UITestLocale.environmentLocale, not Locale.current:" >&2
  echo "$ambient_locale_reads" >&2
  failures=1
fi

# SwiftLint only covers `Sources`, so a test file has no size ceiling of its own.
# The architecture ratchets grew to a single 13.5k-line class before they were
# split by family; this keeps any test file from becoming that again.
oversized_tests="$(
  find Tests -name '*.swift' -print0 \
    | xargs -0 wc -l \
    | awk '$2 != "total" && $1 > 2400 { print $1 " " $2 }' || true
)"
if [[ -n "$oversized_tests" ]]; then
  echo "Test files must stay under 2400 lines; split them by family:" >&2
  echo "$oversized_tests" >&2
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

bash -n scripts/make-app.sh
bash -n scripts/make-release.sh
bash -n scripts/make-production-sync-qualification-app.sh
bash -n scripts/verify-cloudkit-capabilities.sh
bash -n scripts/run-release-reliability-gates.sh
bash -n scripts/run-ui-tests.sh
bash -n scripts/make-ui-host.sh
bash -n scripts/build-ui-host-products.sh
bash -n scripts/pr-evidence.sh
bash -n scripts/check-swift-cache-size.sh
bash -n scripts/run-ci-swiftlint.sh
bash -n scripts/install-ci-xcodegen.sh
bash -n scripts/verify-ci-toolchain.sh
bash -n scripts/check-ios-portability.sh
bash -n scripts/run-resource-baseline.sh
bash -n scripts/perf-binary.sh
bash -n scripts/run-perf-ledger.sh
bash -n scripts/run-scale-baseline.sh
bash -n scripts/run-semantic-scale-baseline.sh
bash -n scripts/run-spotlight-scale-baseline.sh
bash -n scripts/run-resource-recording-baseline.sh
bash -n scripts/run-live-assist-validation.sh
bash -n scripts/run-apuntador-leak-baseline.sh
bash -n scripts/run-exact-path-mutation-benchmark.sh
bash -n scripts/run-exact-path-mutation-host-matrix.sh
bash -n scripts/run-correction-composition-benchmark.sh
bash -n scripts/run-commitment-radar-benchmark.sh
bash -n scripts/run-graph-scale-benchmark.sh
bash -n scripts/check-legacy-tooling.sh

if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

echo "Repository hygiene passed: no tracked local state or ticket-key leakage."
