# AGENTS.md

Portavoz: a privacy-first meeting assistant for Apple platforms, built with Swift 6 + SwiftUI. This file is only the minimal operating guide — **project knowledge lives in `docs/`, not here**.

## At the start of every session

Durable public knowledge lives in `docs/`; the repository roadmap and completed
migration execution ledger are explicit local-only exceptions.

1. **Current architecture and engineering rules**: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) describes only the implemented system and migration status.
2. **As-built technical knowledge**: [docs/specs/](docs/specs/README.md) — 8 domain specs (capture, transcription, diarization, intelligence, storage, app, interfaces, quality) written from the real code. Read the spec for the area you will touch BEFORE editing it.
3. **Outstanding product truth**: [docs/GAPS.md](docs/GAPS.md) records unresolved limitations and field validation; [docs/IOS.md](docs/IOS.md) owns the deferred iOS phase.
4. As needed: [docs/DECISIONS.md](docs/DECISIONS.md) (binding decisions D1–D119), [docs/PRODUCT.md](docs/PRODUCT.md) (vision, competitive map, FREE/PRO), and [docs/RELEASING.md](docs/RELEASING.md) (the full release recipe — build/notarize/publish steps, commands, gotchas, title format).

## At the end of a significant session

New knowledge goes to its durable home: implemented structure -> **ARCHITECTURE.md**, runtime behavior -> the matching **spec**, weighty decisions -> **DECISIONS.md**, and unresolved limitations or field validation -> **GAPS.md**. Repository delivery status and completed migration sequencing stay in the two ignored local files. Nothing important about the shipped system should live only in the conversation.

All explanatory tracked documentation under `docs/` is written in **English**. Literal localized UI copy and bilingual transcript fixtures may remain quoted as evidence. Every architecture change updates `docs/ARCHITECTURE.md` and every other tracked document whose truth changed in that commit.

## Commands

```sh
swift build
swift build -Xswiftc -warnings-as-errors # current-SDK first-party diagnostics
swift test    # if it fails with "no such module": DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
make test-ui-changed UI_BASE=origin/main  # feature-level XCUITest selected from the diff
make test-ui-bilingual                    # explicit full EN + ES release gate
```

## Verifying UI changes — XCUITest first, computer-use last

Validate UI with **XCUITest** (`make test-ui`), not by driving the screen. It is
deterministic, catches crashes/regressions, and runs headless. `Tests/PortavozUITests`
launches the real app with `-use-temp-store -seed-demo` (never touches the real
library) and asserts against `accessibilityIdentifier`s.

- **Every new interactive control gets an `accessibilityIdentifier`** in the same
  change, and a matching assertion in the relevant `*UITests.swift`. Naming: `area-thing`
  (e.g. `settings-category-intelligence`, `summary-tab-1`, `chapter-200`, `player-only-my-voice`).
- Prefer identifiers over localized text; assert seed *content* (Spanish) for data, and
  a nav category / pane title for live-localization.
- Structural UI changes (a control moving panes, a section going behind a tab) will break
  existing UI tests — that is the point; fix the test in the same commit.
- Prefer `make test-ui-changed UI_BASE=origin/main`: known presentation files
  map to feature-level selectors, localization/shared-harness changes expand to
  bilingual evidence, and unknown production Swift paths fail safe to the full
  English suite. `make test-ui-en`, `test-ui-es`, and `test-ui-bilingual` remain
  explicit full-suite gates.
- Reach for **computer-use only as a last resort**, when XCUITest genuinely can't reach
  what you need to see (menu-bar-extra panels, a visual-only regression). Note why.
- The seed-demo meeting deliberately carries a later turn (200 s) so the detail has a
  second chapter and mic-only audio to exercise chapters + "only my voice".

## Rules for every change

- Respect the engineering rules in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): local-first privacy, MIT/no-GPL, strict Swift 6, live scheduler != batch scheduler, sha256-pinned models.
- Preserve every released feature through refactor work. Use incremental Strangler slices with characterization tests; a commit that introduces a feature-parity gap is not complete.
- Keep `swift test` green before closing any task.
- **After any UI change, reinstall the dev app with `make install`** — it installs to `/Applications/Portavoz Dev.app`. **NEVER touch `/Applications/Portavoz.app`**: that is the user's notarized release copy (it updates only via Sparkle/Homebrew). Need real recordings or the real DB for a test? COPY them to a scratch location — never operate on the release app's live data.
- **Every user-visible feature or fix adds one entry to [CHANGELOG.md](CHANGELOG.md)** — English, short and catchy for end users (**emoji + feature name** — what it gives you), newest first under today's date. Internal plumbing (refactors, CI, docs) gets NO entry.
- Use Conventional Commits.
- Keep private tracker IDs, sprint/agent names, local plans, tickets, reports,
  generated projects, result bundles, and ad-hoc screenshots out of tracked
  files. `scripts/check-repository-hygiene.sh` enforces this. Durable accepted
  project truth under `docs/` is tracked; `docs/ROADMAP.md`,
  `docs/refactor-20260714.md`, and `docs/STRATEGY-20260716.md` are explicit
  local-only planning files.
