# Contributing to Portavoz

Thanks for your interest! Portavoz is early — the most valuable contributions right now are issues: use cases, platform quirks, and model recommendations.

By participating, you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Report
security problems privately through GitHub's vulnerability-reporting form or
the process in [SECURITY.md](SECURITY.md), never through a public issue.

## Ground rules

- **Privacy is non-negotiable.** No feature may send audio or transcripts off-device without explicit, visible user opt-in. Telemetry is opt-in only.
- **Swift 6 strict concurrency.** No `@unchecked Sendable` without a comment justifying it.
- **Every PR keeps `swift test` green.**
- **UI evidence follows impact.** Give every interactive control an
  `accessibilityIdentifier`; use `make test-ui-changed UI_BASE=origin/main` to
  run the feature-level XCUITest selectors chosen from the diff. Localization
  and shared-harness changes expand to bilingual evidence automatically.
- **Domain types live in `PortavozCore`**; Kits depend on Core, never on each other (except `IntegrationsKit`, the cross-cutting layer: it may depend on `IntelligenceKit` and `StorageKit` — D31).
- **License hygiene:** we are MIT. Do not port code from GPL projects (e.g. MacParakeet) — patterns and ideas are fine, code is not. MIT/Apache sources are fine with attribution.
- **Explain the code, not the ticket.** Do not put private tracker keys,
  sprint names, or agent-session names in identifiers and comments. Public
  architecture decisions such as D116 are durable project references, not
  ticket IDs.
- **Keep local work local.** Agent state, scratch plans, tickets, reports,
  generated projects, result bundles, and ad-hoc screenshots are ignored.
  Durable as-built behavior and accepted decisions belong in the relevant
  reviewed document under `docs/`.

## Workflow

1. Open an issue describing the change before large PRs.
2. Branch from `main`, use [Conventional Commits](https://www.conventionalcommits.org) (`feat:`, `fix:`, `docs:`...).
3. Run `swift build && swift test` before pushing.
4. Run `swiftlint lint --strict --no-cache` and
   `scripts/check-repository-hygiene.sh`.
5. For presentation changes, run the selected evidence:

   ```sh
   make test-ui-changed UI_BASE=origin/main UI_HEAD=HEAD
   ```

   Use `make test-ui-bilingual` only for an intentional full bilingual gate.
   The selector falls back to the complete English suite for an unknown
   production path rather than incorrectly skipping UI validation.
