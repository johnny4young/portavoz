# Portavoz 🎙

**The meeting assistant that knows who said what — without your audio ever leaving your Mac.**

Portavoz records your meetings, transcribes them live, and tells apart every voice — including yours. Built natively in Swift for Apple platforms, running entirely on-device: Neural Engine transcription, local diarization, local summaries.

> *Portavoz* (Spanish): the one who carries the voice — a spokesperson.

## Why Portavoz

- **Who-said-what, structurally.** Microphone and system audio are captured as separate channels: everything on your mic is *you*, by hardware truth. Remote voices are separated on-device with speaker diarization, then mapped to real names automatically.
- **Local-first, for real.** Transcription, diarization, and summaries run on-device by default. Cloud LLMs are an explicit, clearly-labeled opt-in with your own keys.
- **Bilingual by design.** Attend a meeting in English, get the summary in Spanish (or vice versa) — with technical terms kept intact.
- **Built for developers.** Action items that become GitHub/Linear issues, decision records, a local MCP server so your AI tools can ask "what did I agree to yesterday?", and Shortcuts automation on meeting end.
- **Open format.** Your meetings are Markdown + SQLite you own. No accounts, no lock-in.

## Status

**Pre-alpha (M0).** The module skeleton and domain contracts are in place; capture and transcription land next. Follow the milestones in [docs/ROADMAP.md](docs/ROADMAP.md).

## Architecture

Swift 6 (strict concurrency), SwiftUI, modular SPM workspace:

| Module | Responsibility |
|---|---|
| `PortavozCore` | Shared domain types (meetings, segments, speakers, audio) |
| `AudioCaptureKit` | Mic capture + per-app Core Audio process taps (macOS 14.4+) |
| `TranscriptionKit` | Engine protocol, task-based model routing, model registry |
| `DiarizationKit` | Speaker separation (pyannote/CoreML), voice enrollment |
| `IntelligenceKit` | Summaries (Foundation Models / MLX / BYOK), recipes, action items |
| `ContextFeedKit` | Links, notes, and snippets dropped into a live meeting |
| `StorageKit` | GRDB/SQLite, FTS5 search, local vector index |
| `SyncKit` | CloudKit sync and sharing (later milestone) |
| `IntegrationsKit` | GitHub/Linear/Jira export, Gist sharing, MCP server |

## Development

Requires Xcode 16+ / Swift 6 on macOS 14+.

```sh
swift build
swift test
```

## License

[MIT](LICENSE)

---

### ¿Hablas español?

Portavoz nace de una necesidad real: desarrolladores hispanohablantes viviendo reuniones en inglés. Resúmenes bilingües, glosario técnico que respeta el spanglish de verdad (`deploy`, `PR`, `rollback`), y subtítulos traducidos en vivo están en el corazón del roadmap, no en la periferia.
