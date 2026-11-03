<!-- Keep PRs focused. Open an issue first for large changes (see CONTRIBUTING.md). -->

## Summary

<!-- What changes, in plain words. Why now. -->

## Screenshots

<!-- Before and after, seed data only: `scripts/pr-evidence.sh <PR> <run-id>`. "None: no visible change" if so. -->

## Gates

| Gate | Result |
|---|---|
| Strict tests | |
| Lint and hygiene | |
| UI | <!-- run, and deferred to nightly --> |
| Review | |
| Hosted CI | |

## How to test

<!-- Step by step: disposable launch, the real flow, edge cases, language switch, exact commands. -->

## Risk and rollback

<!-- What can break, and the revert or flag. -->

## Stack

<!-- Base and next, or "Base: main". -->

## Checklist

- [ ] `scripts/run-swift-tests.sh -Xswiftc -warnings-as-errors` passes locally.
- [ ] `swiftlint lint --strict --no-cache` and `scripts/check-repository-hygiene.sh` pass.
- [ ] Conventional Commit title (`feat:`, `fix:`, `docs:`…).
- [ ] No audio/transcripts/summaries leave the device without an explicit, visible opt-in.
- [ ] No code ported from GPL projects (patterns are fine, code is not).
- [ ] Tracked docs updated where behavior changed (`docs/` — architecture, spec, GAPS, or DECISIONS as applicable).
- [ ] `CHANGELOG.md` entry added if this is user-visible (short, catchy, end-user language).
- [ ] `make install` run if this changes the app UI (so local install matches the change).
- [ ] UI changes include stable accessibility identifiers and the selectors from
      `make test-ui-changed UI_BASE=origin/main`; the full English UI suite was run
      only when the change needs the release gate.
- [ ] No local plans, ticket files, result bundles, generated projects, ad-hoc
      screenshots, private tracker keys, or agent-session names are tracked.
