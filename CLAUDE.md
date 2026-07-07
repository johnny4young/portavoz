# CLAUDE.md

Guidance for Claude Code when working in the Portavoz repository.

## What Portavoz is

A privacy-first, local-first meeting assistant for Apple platforms (macOS first; iOS/iPadOS later; visionOS eventually), written natively in Swift 6 + SwiftUI. Its core promise: **know who said what — including which interventions were the user's — without audio ever leaving the device.** It is the Swift-native successor to the ideas in Meetily (the reference repo lives at `../meetily`; study it, never port its code).

Flagship differentiators (in priority order): structural who-said-what via dual-channel capture, speaker diarization with user voice identity, bilingual ES/EN summaries and live translated captions, developer workflow integrations (GitHub/Linear/Jira export, local MCP server, App Intents automations), open Markdown+SQLite data format.

## Commands

```sh
swift build    # build all modules
swift test     # run tests (XCTest)
```

If tests fail with "no such module 'XCTest'": the machine has Command Line Tools selected. Run with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`, or fix permanently with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

## Architecture (SPM workspace, one package)

`PortavozCore` holds shared domain types; the 8 Kits depend on Core and never on each other (sole exception: `IntegrationsKit → IntelligenceKit`).

- `AudioCaptureKit` — mic (AVAudioEngine) + per-app Core Audio process taps (macOS 14.4+). Channels are captured SEPARATELY (`AudioChannel.microphone/.system/.room`) and never mixed before diarization: everything on the mic channel is the user by definition.
- `TranscriptionKit` — `TranscriptionEngine` protocol; planned engines: Parakeet via FluidAudio (ANE), WhisperKit, Apple SpeechAnalyzer (macOS 26+), remote OpenAI-compatible. Model routing is **per task** (`ModelTask`), never one global model. Model downloads verify pinned SHA-256 + upstream revision.
- `DiarizationKit` — pyannote community-1 via FluidAudio (Sortformer as alternative) on the system/room channels. `Voiceprint` is biometric-grade: on-device only, encrypted, never synced, deletable in one action.
- `IntelligenceKit` — `SummaryProvider`: Foundation Models (default), MLX local, BYOK cloud (explicit opt-in, never silent default). Recipes reshape output per meeting type. `SummaryRequest.targetLanguage` + `glossary` implement bilingual summaries that keep technical terms untranslated.
- `ContextFeedKit` — timestamped links/notes/snippets dropped during a meeting; interleaved with the transcript to enrich summaries ("notes carry intent, transcript carries facts").
- `StorageKit` — GRDB + FTS5 + sqlite-vec (arrives M1; zero deps at M0). Schema contract is FROZEN from v1: UUID PKs everywhere, `updated_at` + `deleted_at` tombstones on syncable tables, summaries as immutable versioned snapshots, no absolute paths in the DB.
- `SyncKit` — CloudKit via CKSyncEngine (M7). Sharing ladder: share-sheet/Gist export → CKShare → self-hostable relay.
- `IntegrationsKit` — exporters + Gist sharing + local MCP server (localhost-only + session token).

Roadmap with acceptance criteria: [docs/ROADMAP.md](docs/ROADMAP.md). Status: **M0 done; M1 (capture) is next.**

## Non-negotiable constraints

1. **Privacy:** no feature sends audio/transcripts off-device without explicit, visible opt-in. Telemetry is opt-in only. API keys go in the Keychain — never SQLite, never UserDefaults (Meetily stored keys in plaintext SQLite; that is the anti-pattern).
2. **License hygiene:** Portavoz is MIT. Never copy code from GPL projects — notably MacParakeet (GPL-3), which validates our stack but is look-don't-touch. Humla (MIT) and FluidAudio/WhisperKit (MIT/Apache) are fine with attribution.
3. **Swift 6 strict concurrency:** actors + `AsyncStream` end-to-end; no `@unchecked Sendable` without a justifying comment; no locks.
4. **The live path never starves:** batch work (file transcription, re-passes) runs in a separate scheduler slot from live transcription.
5. Conventional Commits (`feat:`, `fix:`, `docs:`…).

## Business model (context for product decisions)

Everything open source (MIT). FREE tier is never limited in minutes/meetings/history — local compute is free. PRO is a one-time license (convenience + power: sync, dev integrations, RAG chat, MCP server). Distribution: notarized DMG + Sparkle + Homebrew cask + direct sales; App Store for iOS.
