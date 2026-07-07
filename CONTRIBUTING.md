# Contributing to Portavoz

Thanks for your interest! Portavoz is early — the most valuable contributions right now are issues: use cases, platform quirks, and model recommendations.

## Ground rules

- **Privacy is non-negotiable.** No feature may send audio or transcripts off-device without explicit, visible user opt-in. Telemetry is opt-in only.
- **Swift 6 strict concurrency.** No `@unchecked Sendable` without a comment justifying it.
- **Every PR keeps `swift test` green.**
- **Domain types live in `PortavozCore`**; Kits depend on Core, never on each other (except `IntegrationsKit → IntelligenceKit`).
- **License hygiene:** we are MIT. Do not port code from GPL projects (e.g. MacParakeet) — patterns and ideas are fine, code is not. MIT/Apache sources are fine with attribution.

## Workflow

1. Open an issue describing the change before large PRs.
2. Branch from `main`, use [Conventional Commits](https://www.conventionalcommits.org) (`feat:`, `fix:`, `docs:`...).
3. `swift build && swift test` before pushing.
