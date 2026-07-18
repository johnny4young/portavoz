# Technical specs — how to read this folder

Portavoz **as-built** documentation: it describes what the code does TODAY, verifiable against `Sources/` and `Tests/`. Written so that any agent or human can work on the project without context from previous conversations.

## Conventions (unambiguous)

- Everything described in the regular sections **is implemented and tested** (`swift test`, 962 tests, 13 gated by `PORTAVOZ_MODEL_TESTS=1` or other integration variables).
- Anything NOT implemented appears only in subsections titled **"Planned (not implemented)"**, with a reference to the decision (Dxx) or milestone (Mxx) that defines it.
- Every performance figure cited was **measured** on the reference machine (MacBook Pro M4 Max, 36 GB, macOS 26) — the date and conditions accompany the figure.
- "Known limitations" are actual observed failures or risks, not hypotheses.

## Index

| Spec | Covers | Kits |
|---|---|---|
| [01-audio-capture.md](01-audio-capture.md) | Dual-channel capture, AEC, resilience, formats, configurable folder | AudioCaptureKit |
| [02-transcription.md](02-transcription.md) | Live STT (Parakeet), refine (Whisper), coalescer, vocabulary, model registry | TranscriptionKit, ModelStoreKit |
| [03-diarization-identity.md](03-diarization-identity.md) | Diarization, attribution, voiceprint, names | DiarizationKit, IntelligenceKit (naming) |
| [04-intelligence.md](04-intelligence.md) | FM/BYOK summaries, rolling summary, local RAG, embeddings | IntelligenceKit |
| [05-storage.md](05-storage.md) | SQLite schema, data contract, FTS, retention, recordings folder | StorageKit, PortavozCore |
| [06-app-macos.md](06-app-macos.md) | SwiftUI app, views, flows, packaging, signing, updates | portavoz-app, scripts/ |
| [07-interfaces.md](07-interfaces.md) | Complete CLI, MCP server, exporters | portavoz-cli, IntegrationsKit |
| [08-quality.md](08-quality.md) | Test suite, harnesses, measured figures, bugs found | Tests/, scripts/ |

## Related documents (outside specs/)

- [../DECISIONS.md](../DECISIONS.md) — binding decisions D1–D113 and their rationale. The specs cite them by number.
- [../ARCHITECTURE.md](../ARCHITECTURE.md) — high-level engineering and design rules.
- [../refactor-20260714.md](../refactor-20260714.md) — approved target architecture, migration bands, commit protocol, and acceptance criteria. It is a plan; this folder remains as-built truth.
- [../ROADMAP.md](../ROADMAP.md) — phases and milestones with acceptance criteria.
- [../PRODUCT.md](../PRODUCT.md) — vision, competitive map, FREE/PRO.
- [../IOS.md](../IOS.md) — technical breakdown of the iOS phase.
- [../GAPS.md](../GAPS.md) — gap analysis + pending field verification.
- [../ROADMAP.md](../ROADMAP.md) opens with **"Current state and next step"** — project state is read there (there is no session handoff file).

## Repository rules (for agents)

- Strict Swift 6; the implemented dependency graph and its enforced exceptions are documented exactly in `ARCHITECTURE.md`.
- MIT; never port GPL code (Meetily in `../meetily` and MacParakeet are ONLY pattern references).
- Keep `swift test` green before closing any task (if it fails with "no such module": `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`).
- Conventional Commits. Models are always pinned by sha256 (D15).
- All explanatory project documentation under `docs/` is English (D34). Literal localized UI copy and bilingual language-quality fixtures may remain quoted as evidence.
