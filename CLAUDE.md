# CLAUDE.md

Portavoz: a privacy-first meeting assistant for Apple platforms, built with Swift 6 + SwiftUI. This file is only the minimal operating guide — **project knowledge lives in `docs/`, not here**.

## At the start of every session

Durable knowledge lives in `docs/` — there is no session handoff file anymore (the HANDOFF was removed in July 2026; its contents moved into the docs below).

1. **Current state and next step**: [docs/ROADMAP.md](docs/ROADMAP.md) opens with the current project state, remaining work, and the next concrete step.
2. **As-built technical knowledge**: [docs/specs/](docs/specs/README.md) — 8 domain specs (capture, transcription, diarization, intelligence, storage, app, interfaces, quality) written from the real code, with implemented behavior separated from planned behavior. Read the spec for the area you will touch BEFORE editing it.
3. As needed: [docs/DECISIONS.md](docs/DECISIONS.md) (binding decisions D1-D30), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (engineering rules + environment quirks), [docs/PRODUCT.md](docs/PRODUCT.md) (vision, competitive map, FREE/PRO), [docs/GAPS.md](docs/GAPS.md) (known gaps + pending field validation), [docs/IOS.md](docs/IOS.md) (iOS phase).

## At the end of a significant session

New knowledge goes to its durable home: state/progress -> **ROADMAP**, as-built technical behavior -> the matching **spec**, weighty decisions -> **DECISIONS.md**, gaps/pending work -> **GAPS.md**. Nothing important should live only in the conversation.

## Commands

```sh
swift build
swift test    # if it fails with "no such module": DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Rules for every change

- Respect the engineering rules in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): local-first privacy, MIT/no-GPL, strict Swift 6, live scheduler != batch scheduler, sha256-pinned models.
- Keep `swift test` green before closing any task.
- **After any UI change, reinstall the app with `make install`** — the user tests locally, so the installed app must match the latest work.
- Use Conventional Commits.
