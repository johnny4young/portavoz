# Roadmap

Each milestone is independently shippable and has a measurable acceptance criterion.

| Milestone | Scope | Acceptance criterion |
|---|---|---|
| **M0 — Skeleton** | SPM workspace, domain contracts, CI, docs | `swift test` green in CI; `brew`-ready layout |
| **M1 — Capture** | Mic + per-app process taps, dual-channel recording, retention policies | 30-min Zoom recording produces two synced WAVs, drift < 50 ms |
| **M2 — Transcription** | Parakeet streaming (FluidAudio), slot scheduler, model registry with verified downloads | Live transcript < 2 s latency while a batch file transcribes without degrading it |
| **M3 — Diarization** | pyannote on system channel, "Me" via mic channel, editable speaker pills | 4-person meeting: DER < 15%, user's turns 100% attributed |
| **M4 — Intelligence** | Incremental summaries (Foundation Models + BYOK), Recipes v1, bilingual EN/ES output | Structured summary < 30 s after meeting end; Spanish summary of an English meeting with glossary intact |
| **M5 — Public 0.1** | StorageKit (FTS5, versioned snapshots), export MD/PDF/Gist, polished UI | Public release: "knows who said what, locally" |
| **M6 — Identity & language** | Auto speaker naming (LLM + EventKit), voice enrollment, live translated captions | 1-tap speaker→name mapping; live ES↔EN captions |
| **M7 — iOS + PRO** | In-person recorder, Live Activities, CloudKit sync, share extension | Record on iPhone, read on Mac; one-time PRO launch |
| **M8 — Dev moat** | MCP server, GitHub/Linear export, App Intents automations, local RAG chat | An MCP agent answers "what did I agree to yesterday?" |

Later: visionOS review room, collaborative notes (CloudKit shared zones), synthesized voice research.
