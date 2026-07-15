# AGENTS.md

Portavoz: a privacy-first meeting assistant for Apple platforms, built with Swift 6 + SwiftUI. This file is only the minimal operating guide — **project knowledge lives in `docs/`, not here**.

## At the start of every session

Durable knowledge lives in `docs/` — there is no session handoff file anymore (the HANDOFF was removed in July 2026; its contents moved into the docs below).

1. **Current state and next step**: [docs/ROADMAP.md](docs/ROADMAP.md) opens with the current project state, remaining work, and the next concrete step.
2. **As-built technical knowledge**: [docs/specs/](docs/specs/README.md) — 8 domain specs (capture, transcription, diarization, intelligence, storage, app, interfaces, quality) written from the real code, with implemented behavior separated from planned behavior. Read the spec for the area you will touch BEFORE editing it.
3. **Architecture refactor work**: [docs/refactor-20260714.md](docs/refactor-20260714.md) is the executable target architecture, band plan, feature-parity contract, commit protocol, and acceptance matrix. Read it before any refactor slice; it is a plan, while specs remain as-built truth.
4. As needed: [docs/DECISIONS.md](docs/DECISIONS.md) (binding decisions D1-D34), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (current architecture, clearly labeled target, engineering rules, and migration status), [docs/PRODUCT.md](docs/PRODUCT.md) (vision, competitive map, FREE/PRO), [docs/GAPS.md](docs/GAPS.md) (known gaps + pending field validation), [docs/RELEASING.md](docs/RELEASING.md) (the full release recipe — build/notarize/publish steps, commands, gotchas, title format), [docs/IOS.md](docs/IOS.md) (iOS phase).

## At the end of a significant session

New knowledge goes to its durable home: state/progress -> **ROADMAP**, as-built technical behavior -> the matching **spec**, weighty decisions -> **DECISIONS.md**, gaps/pending work -> **GAPS.md**. Nothing important should live only in the conversation.

All explanatory documentation under `docs/` is written in **English**. Literal localized UI copy and bilingual transcript fixtures may remain quoted as evidence. During the architecture program, **every refactor commit updates `docs/ARCHITECTURE.md`** and every other document whose truth changed in that commit; never defer documentation until the end of a band.

## Commands

```sh
swift build
swift test    # if it fails with "no such module": DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
make test-ui  # XCUITest smoke suite (Library/Insights/MeetingDetail/Settings); test-ui-en / test-ui-es for locales
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
