# Portavoz 🎙

**The meeting assistant that knows who said what — without your audio ever leaving your Mac.**

Portavoz records your meetings, transcribes them live, and tells apart every voice — including yours. Built natively in Swift for Apple platforms, running entirely on-device: Neural Engine transcription, local diarization, local summaries.

[![CI](https://github.com/johnny4young/portavoz/actions/workflows/ci.yml/badge.svg)](https://github.com/johnny4young/portavoz/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014.4%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-orange)

> *Portavoz* (Spanish): the one who carries the voice — a spokesperson.

## Why Portavoz

- **Who-said-what, structurally.** Microphone and system audio are captured as separate channels: everything on your mic is *you*, by hardware truth. Remote voices are separated on-device with speaker diarization, then mapped to real names automatically.
- **Local-first, for real.** Transcription, diarization, and summaries run on-device by default. Cloud LLMs — and local ones like Ollama — are an explicit, clearly-labeled opt-in with your own keys.
- **Bilingual by design.** Attend a meeting in English, get the summary in Spanish (or vice versa) — with technical terms kept intact.
- **Listen back, not just read.** A synchronized player scrolls the transcript like song lyrics, colors your turns apart from theirs on the waveform, and exports any span as an audio clip.
- **A companion while you talk.** Opt-in live cards answer a factual question the room just asked, or nudge you when someone addressed you by name — on-device by default.
- **Built for developers.** Action items that become GitHub/Linear issues, decision records, a local MCP server so your AI tools can ask "what did I agree to yesterday?", and Shortcuts automation on meeting end.
- **Open format.** Your meetings are Markdown + SQLite you own. No accounts, no lock-in.

## Status

**Private beta — used in real meetings, not yet publicly released.** Capture, live + refine transcription, diarization, bilingual summaries, audio playback, co-authoring notes, and the live companion are all built and measured (see below). The next milestone is the public 0.1 release — Homebrew cask + notarized DMG are built and waiting on publication ([docs/ROADMAP.md](docs/ROADMAP.md), M9). Every feature that ships lands in the [changelog](CHANGELOG.md).

## Benchmarks

Measured on a MacBook Pro **M4 Max, 36 GB, macOS 26** (July 2026). Everything below runs **on-device** — no network. Numbers are reproducible with the dev CLI; run them on your own machine and audio.

| Stage | Engine | Measured | Reproduce |
|---|---|---|---|
| **Live transcription** | Parakeet TDT 0.6B v3 (int8, ANE) | first partial **1.1 s**; finalization lag p50 **0.07 s** / p95 **0.68 s** | `portavoz-cli bench-live --file meeting.wav` |
| **Live under batch load** (M2 criterion) | Parakeet live + Whisper batch in parallel | end-to-end p95 **0.53 s** (target < 2 s) | `portavoz-cli bench-m2 --batch-file meeting.wav` |
| **Refine (quality pass)** | Whisper large-v3-turbo (WhisperKit) | **23–42× realtime** | `portavoz-cli transcribe --file meeting.wav` |
| **Diarization** | pyannote community-1 + WeSpeaker (FluidAudio) | **DER 7.6%** on an AMI sample | `portavoz-cli der --file meeting.wav --reference truth.rttm` |
| **Summary** | Foundation Models (on-device, 3B) | structured summary **3.8 s** after meeting end | `portavoz-cli summarize --file meeting.wav` |
| **Dual-channel drift** | AVAudioEngine + Core Audio tap | **4 ms** over 30 min (target < 50 ms) | 30-min `portavoz-cli record --system` |

An alternate live engine, Apple's **SpeechAnalyzer** (macOS 26), is benchmarked head-to-head against Parakeet in [docs/specs/02-transcription.md](docs/specs/02-transcription.md#spike-speechanalyzer-m12d25--estado-y-hallazgos-jul-2026): both stay under 1 s p95; Parakeet keeps the finalization-latency crown, SpeechAnalyzer wins on zero-download and rich volatile captions.

> Reproduce a live run yourself (`--engine speech` must run inside the app bundle — the Speech daemon won't answer an unbundled process):
> ```sh
> portavoz-cli bench-live --file your-meeting.wav --engine parakeet --seconds 60
> Portavoz.app/Contents/MacOS/portavoz-app --bench-live your-meeting.wav --seconds 60   # SpeechAnalyzer
> ```

### Models

Downloaded on first use and verified against pinned SHA-256 checksums (`portavoz-cli models download` / `verify`). None of them phone home after download.

| Model | Role | On-disk | Min RAM |
|---|---|---|---|
| Parakeet TDT 0.6B v3 (int8) | live transcription | ~483 MB | 4 GB |
| Whisper large-v3-turbo | refine (quality) | ~1.6 GB | 8 GB |
| Whisper large-v3 (626 MB variant) | refine on low disk | ~626 MB | 6 GB |
| pyannote + WeSpeaker | diarization | ~14 MB | 2 GB |

## Architecture

Swift 6 (strict concurrency), SwiftUI, modular SPM workspace. Kits depend on `PortavozCore`, never on each other (one documented exception). Full engineering rules in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); as-built specs per domain in [docs/specs/](docs/specs/README.md).

| Module | Responsibility |
|---|---|
| `PortavozCore` | Shared domain types (meetings, segments, speakers, audio), Keychain secret store |
| `ModelStoreKit` | Curated model registry; SHA-256-verified downloads pinned to exact commits |
| `AudioCaptureKit` | Mic capture (AEC) + per-app Core Audio process taps (macOS 14.4+), crash-safe CAF writer |
| `TranscriptionKit` | Engine protocol, task-based routing, Parakeet (live) + Whisper (refine), scheduler |
| `DiarizationKit` | Speaker separation (pyannote/CoreML), who-said-what attribution, voice enrollment |
| `IntelligenceKit` | Summaries (Foundation Models / Ollama / BYOK), recipes, action items, live companion |
| `AudioPlaybackKit` | Synchronized player, channel-colored waveform, clip export, AAC transcode |
| `ContextFeedKit` | Links, notes, and snippets dropped into a live meeting (co-authoring) |
| `StorageKit` | GRDB/SQLite, FTS5 search, versioned snapshots, local vector index |
| `IntegrationsKit` | GitHub/Linear export, Gist sharing, MCP server |
| `SyncKit` | CloudKit sync and sharing (later milestone) |

## Build from source

Requires **Xcode 16+ / Swift 6 on macOS 14.4+**.

```sh
swift build
swift test

# Build and run the app bundle (Info.plist with the mic + system-audio entitlements):
scripts/make-app.sh && open dist/Portavoz.app

# Fetch and verify the models:
swift run portavoz-cli models download
```

The public release will ship a notarized DMG and a Homebrew cask (`brew install --cask portavoz`) — tracked in M9.

## Privacy

Audio, transcripts, summaries, and voice embeddings stay on-device by default. API keys live in the Keychain, never in the database or preferences. Model downloads are checksum-verified. The MCP server binds to localhost only. See [SECURITY.md](SECURITY.md) for the full commitments and how to report a vulnerability.

## Contributing

Issues are the most valuable contribution right now — use cases, platform quirks, model recommendations. See [CONTRIBUTING.md](CONTRIBUTING.md). Privacy is non-negotiable and we are MIT-licensed (no GPL code ports).

## License

[MIT](LICENSE)

---

### Spanish-speaking users

Portavoz started from a real need: Spanish-speaking developers living in English-language meetings. Bilingual summaries, a technical glossary that respects real-world Spanglish (`deploy`, `PR`, `rollback`), and live translated captions are core roadmap items, not side quests.
