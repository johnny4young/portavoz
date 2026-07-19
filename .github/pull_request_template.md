<!-- Keep PRs focused. Open an issue first for large changes (see CONTRIBUTING.md). -->

## Summary

<!-- What does this change and why? -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Refactor / internal
- [ ] Docs
- [ ] Build / CI / tooling

## Checklist

- [ ] `swift build && swift test` pass locally.
- [ ] `swiftlint lint --strict --no-cache` and `scripts/check-repository-hygiene.sh` pass.
- [ ] Conventional Commit title (`feat:`, `fix:`, `docs:`…).
- [ ] No audio/transcripts/summaries leave the device without an explicit, visible opt-in.
- [ ] No code ported from GPL projects (patterns are fine, code is not).
- [ ] Docs updated where behavior changed (`docs/` — spec, ROADMAP, GAPS, or DECISIONS as applicable).
- [ ] `CHANGELOG.md` entry added if this is user-visible (short, catchy, end-user language).
- [ ] `make install` run if this changes the app UI (so local install matches the change).
- [ ] UI changes include stable accessibility identifiers and the selectors from
      `make test-ui-changed UI_BASE=origin/main`; full bilingual UI was run only
      when localization/shared impact selected it or the change needs the release gate.
- [ ] No local plans, ticket files, result bundles, generated projects, ad-hoc
      screenshots, private tracker keys, or agent-session names are tracked.

## Notes for reviewers

<!-- Anything worth calling out: trade-offs, follow-ups, field verification still pending. -->
