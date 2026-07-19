# Portavoz 🎙

**The meeting assistant that knows who said what — without your audio ever leaving your Mac.**

Portavoz records your meetings, transcribes them live, and tells apart every voice — including yours. Built natively in Swift for Apple platforms, running entirely on-device: Neural Engine transcription, local diarization, local summaries.

**[portavoz.app](https://portavoz.app)** · `brew install --cask johnny4young/tap/portavoz`

[![CI](https://github.com/johnny4young/portavoz/actions/workflows/ci.yml/badge.svg)](https://github.com/johnny4young/portavoz/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014.4%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-orange)

![A meeting in Portavoz: colored speaker pills with one-click name suggestions, a tabbed summary (decisions, open questions, to-dos), a who-said-what transcript, a docked player with waveform, and a right rail with per-speaker meeting health and ✦ chapters](assets/screenshots/meeting-detail.png)

<table>
<tr>
<td width="50%"><img alt="Live recording: lyrics-style captions with your voice glowing amber, and the Companion answering a factual question the room just asked — entirely on-device" src="assets/screenshots/recording-companion.png"></td>
<td width="50%"><img alt="Insights: meetings, talk time, decisions and questions with month-over-month deltas; a two-tone bar per person for who you talk with; ✦ findings; and a 12-week rhythm heatmap" src="assets/screenshots/insights.png"></td>
</tr>
<tr>
<td align="center"><sub><b>Live recording</b> — lyrics captions + the on-device Companion</sub></td>
<td align="center"><sub><b>Insights</b> — your meeting life, computed on your Mac</sub></td>
</tr>
</table>

<sub>Representative data, English UI. Everything shown is computed and rendered on-device.</sub>

> *Portavoz* (Spanish): the one who carries the voice — a spokesperson.

## Why Portavoz

- **Who-said-what, structurally.** Microphone and system audio are captured as separate channels: everything on your mic is *you*, by hardware truth. Remote voices are separated on-device with speaker diarization, then named from transcript, calendar, or encrypted voice evidence only after you confirm the suggestion. A separately confirmed, private person link can remember that human across meetings without silently merging people who share a name.
- **Local-first, with receipts.** Transcription, diarization, and summaries run on-device by default. Remote providers require explicit configuration or confirmation, and each meeting shows a content-free privacy receipt for tracked on-device processing and remote-transfer attempts. Local Ollama remains visibly local.
- **Private when support is needed.** Export a redacted local support file without meeting text, generated output, prompts, secrets, full URLs, or paths. Stalled background work is visible in Meeting Detail and can be retried without replacing its durable safety evidence.
- **Failures tell you what to do.** Recording Start/Stop failures keep a stable support reference and route you to retry, your preserved Library audio, or private local diagnostics instead of exposing a dependency error or ending at a generic alert.
- **Bilingual by design.** Every speaker keeps the language they actually used, while summaries can independently follow the meeting or always use English or Spanish — with technical terms kept intact.
- **Listen back, not just read.** A synchronized player scrolls the transcript like song lyrics, colors your turns apart from theirs on the waveform, exports any span as an audio clip, and compresses every channel without removing an original until all outputs verify.
- **A companion while you talk.** Opt-in live cards answer a factual question the room just asked, or nudge you when someone addressed you by name — on-device by default.
- **Built for developers.** Action items that become GitHub/Linear issues, decision records, a local MCP server so your AI tools can ask "what did I agree to yesterday?", and Shortcuts automation on meeting end.
- **Open format.** Your meetings are Markdown + SQLite you own. No accounts, no lock-in.

## Status

**Shipping and self-updating on macOS Sequoia and later.** Install with Homebrew or grab the notarized DMG from [Releases](https://github.com/johnny4young/portavoz/releases); updates arrive automatically via Sparkle:

```sh
brew install --cask johnny4young/tap/portavoz
```

Both the app bundle and its disk image are independently signed, notarized,
and stapled, so Homebrew extraction and direct DMG installation cross the same
Gatekeeper boundary on Sequoia and later.

Capture, live + refine transcription, on-device diarization, bilingual summaries (three local engines), audio playback, co-authoring notes, pre-meeting briefs, and the live companion are all built and measured (see below). Every feature that ships lands in the [changelog](CHANGELOG.md).

## What you get

Everything below runs on your Mac. Grouped by what you're doing:

**Capture & transcribe**
- **Dual-channel recording** — your mic and the call are captured as separate channels, so *you* are known by hardware truth, not by guesswork. Echo cancellation, device-change resilience, a low-mic nudge, and a heads-up when the incoming channel goes silent. A channel that captured nothing stays empty — never filled with invented text.
- **Durable before the first byte** — the meeting and its channel reservations exist before capture starts. A fresh install records immediately instead of waiting for local speech-model downloads; verified models prepare in the background, and Stop admits an exact durable recovery job when live captions were unavailable or a lane failed. Each channel records behind a recovery filename, verifies its CAF metadata, checksum, and signal health, then publishes atomically for playback. On launch, staging-only or final-only files are revalidated and restored; ambiguous copies are preserved rather than guessed at.
- **Recording failures stay actionable** — Start and Stop retain exact typed outcomes instead of forwarding raw system text. Recoverable cases offer retry or the Library; uncertain local state opens private support diagnostics and includes a stable reference you can copy.
- **Every voice stays itself** — auto-detect preserves each speaker's real language, including mixed Spanish/English meetings. Pin one transcript language only as a recovery tool for quiet or noisy audio.
- **Live captions, lyrics-style** — sub-second partials on the Neural Engine; the newest line reads big, your voice glows amber, older lines fade away. Optional **live translation** of captions as they arrive — and the one-time language download never interrupts your meeting.
- **Whisper refine** — prepare Turbo or Compact proactively in Settings; the verified download continues after Settings closes and Refine/Import reuse it. The cancellable maximum-quality re-pass becomes a draft you approve (never a silent overwrite), at 23–42× realtime. Accepted drafts install language, speakers, and transcript atomically and are rejected if the meeting changed while you reviewed them. Force a language per meeting only to recover one that came out wrong.
- **Import any audio** — drag in a recording or a `.portavoz` bundle. Recordings are transcribed, diarized, and summarized like a live capture; bundles restore the remapped transcript, summary, notes, Companion, and validated optional audio as one all-or-nothing meeting. Large files stay off the UI thread, and failed imports clean up their staged audio instead of leaving invisible files behind.

**Understand the meeting**
- **Every voice, told apart** — on-device diarization gives each meeting speaker a stable color. Name suggestions use transcript, calendar, or encrypted voice evidence but are never applied automatically. After naming someone, an explicit second action can remember the person locally; exact-name collisions open a chooser instead of merging identities.
- **Three local summary engines** — Apple Intelligence on macOS 26, Ollama, or a built-in model. A clean install recommends a path that can run on that Mac; a running Ollama process counts only when it exposes a chat-capable model. Portavoz never silently substitutes a different provider when setup is incomplete. Generate Summary opens the exact setup pane when a model still needs attention. A separate Summary language setting follows the meeting or consistently writes English/Spanish, without changing the transcript. **Tabbed** so a long summary is skimmable.
- **Summaries you can inspect and correct** — an overview can link to the exact transcript/audio moments that support it. Add a private correction or mark it unsupported without rewriting the generated text; clear erases the correction, and it travels only when you explicitly export the `.portavoz` meeting.
- **Custom structures** — beyond the five built-in shapes (standup, 1:1, planning…), author your own — a Hangout, a Retro — with the sections you want. They appear in every meeting's Structure menu.
- **✦ Chapters** — Portavoz finds the turning points (a long pause, a stretch that ran long) and lets you jump to them, each labeled with the line that opens it.
- **Meeting health** — talk-time, interruptions and questions per speaker, computed locally.
- **Co-authoring notes** — jot raw notes while recording; the summary weaves them in and marks the co-authored lines (▸).

**Listen back**
- **Synced player** — the transcript scrolls like song lyrics, per-channel colored waveform, **"only my voice"** to replay just your turns, skip-silence, and any span exported as an audio clip or compressed to AAC in one click. Compression verifies every channel before removing raw audio and never replaces an existing AAC file.

**Reflect & review**
- **Insights** — scope your meeting life to this week/month/year, see **who you talk with and how much** (amber = you, violet = them), your talk balance, a 12-week rhythm heatmap, and open commitments — all local.
- **🪞 Post-meeting mirror** (opt-in) — a private card at the end of a real meeting: your numbers next to your usual average, measured, never judged.
- **Actionable recovery** — Meeting Detail tells you when local processing is active or exhausted, preserves the audio/transcript already saved, and offers one safe retry. Settings can save a redacted diagnostics JSON locally; Portavoz never uploads it.
- **⌘K — ask your week** — a Spotlight-style palette over any view: instant results as you type, a full on-device answer with citation chips that jump to the exact moment.

**Fits your workflow**
- **Companion while you talk** (opt-in, macOS 26 + Apple Intelligence) — live cards answer a factual question the room just asked, or flag when someone addressed you by name. In review, each saved card separates the exact question moment from the transcript passages cited by a context answer. Settings makes the requirement and activation path explicit; BYOK can replace the answer provider, but not the current on-device question detector.
- **Dictate anywhere** — a global hotkey (⌥⌘D) transcribes straight into any app, tap-to-toggle or hold-to-talk.
- **Menu-bar resident** — recording state, one-click record/dictate/ask, and your next calendar meeting, with the window closed.
- **Pre-meeting briefs** from your calendar, with verifiable citations, and recordings born with the real event name.
- **Review suggestions that wait for you** — optional titles, summary structures, and chapter labels are admitted against one meeting revision, stay inert until you accept them, and never make a failed rename look saved.
- **Developer glue** — action items → GitHub/Linear issues, a local **MCP server** so your AI tools can ask "what did I agree to yesterday?", and Shortcuts automation on meeting end.

**Own your data**
- **Open format** — Markdown + a SQLite file you own. Full-library backup reads one consistent snapshot, shows partial progress honestly, and publishes portable Markdown without replacing existing files; per-meeting `.portavoz` bundles optionally include audio, and **trash** restores meetings before automatic purge after 30 days. No accounts, no lock-in.
- **iCloud sync that asks first** *(next release; production field validation pending)* — optionally sync encrypted meeting text and portable metadata through your private iCloud database. Future changes and the existing library are separate choices; Settings always shows this Mac's real state. Audio, local paths, voiceprints, secrets, and embeddings never sync, and Pause/Remove never delete your local meetings or remote records. Public enablement waits for the documented production-container and two-Mac release matrix.
- **Privacy receipt** — every meeting explains whether tracked processing stayed on your Mac, a remote transfer was attempted, or iCloud acknowledged an encrypted private copy. It shows purpose, destination host, and time but no copied transcript, prompt, notes, summary, or action-item text. Upgraded libraries state the exact date tracking began instead of guessing about older activity.

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
| **Library search at 100k segments** | SQLite FTS5 + term-level RRF | exact p95 **30.99 ms**; lexical Ask p95 **66.89 ms**, down from 111.19 ms | `scripts/run-scale-baseline.sh` |
| **Semantic retrieval at 100k segments** | streamed exact 512-d BLOB cosine + Accelerate | wall/CPU p95 **90.22/91.26 ms**, down from 325.41/328.43 ms; **8.42 MiB** incremental footprint | `scripts/run-semantic-scale-baseline.sh` |
| **Waveform, 56-minute dual-channel recording** | stateless bucket spans + Accelerate | first wall/CPU **109.25/94.81 ms**; repeat p95 **70.11/71.33 ms**, down from 747.53/754.79 ms | `portavoz-cli bench-waveform --mic microphone.caf --system system.caf` |
| **Meeting Detail at 5k segments** | scoped GRDB read + SwiftUI | core read p95 **16.27 ms**; health p95 **9.94 ms**; first content **91.87 ms** with no measured hang | `make install && scripts/run-detail-ui-baseline.sh` |

An alternate live engine, Apple's **SpeechAnalyzer** (macOS 26), is benchmarked head-to-head against Parakeet in [docs/specs/02-transcription.md](docs/specs/02-transcription.md#speechanalyzer-spike-m12d25--status-and-findings-jul-2026): both stay under 1 s p95; Parakeet keeps the finalization-latency crown, SpeechAnalyzer wins on zero-download and rich volatile captions.

> Reproduce a live run yourself (`--engine speech` must run inside the app bundle — the Speech daemon won't answer an unbundled process):
> ```sh
> portavoz-cli bench-live --file your-meeting.wav --engine parakeet --seconds 60
> Portavoz.app/Contents/MacOS/portavoz-app --bench-live your-meeting.wav --seconds 60   # SpeechAnalyzer
> ```

### Models

Downloaded on first use and verified against pinned SHA-256 checksums (`portavoz-cli models download` / `verify`). Recording never waits for that first download: audio starts immediately and a complete transcript is recovered from the finalized channels when the model becomes ready. Readiness is role-specific: durable first-pass transcription and dictation load Parakeet only; Refine prepares Whisper only and acquires pyannote later as degradable speaker attribution; external-audio Import also never loads Parakeet as a side effect. Whisper Turbo and Compact can also be prepared explicitly in Settings before the first Refine; one app-scoped lifecycle keeps integrity checks and install/delete operations coherent, continues preparation after Settings closes, and lets Refine/Import join or reuse verified results. None of the models phone home after download.

| Model | Role | On-disk | Min RAM |
|---|---|---|---|
| Parakeet TDT 0.6B v3 (int8) | live transcription | ~483 MB | 4 GB |
| Whisper large-v3-turbo | refine (quality) | ~1.6 GB | 8 GB |
| Whisper large-v3 (626 MB variant) | refine on low disk | ~626 MB | 6 GB |
| pyannote + WeSpeaker | diarization | ~14 MB | 2 GB |
| Qwen3.5 4B (MLX, 4-bit) | optional embedded summaries | ~3 GB | 8 GB |

## Architecture

Swift 6 (strict concurrency), SwiftUI, modular SPM workspace. Most Kits depend
on `PortavozCore`; the few verified cross-Kit dependencies are documented in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). As-built behavior lives in
[docs/specs/](docs/specs/README.md). The approved, feature-parity-preserving
architecture migration is tracked in
[docs/refactor-20260714.md](docs/refactor-20260714.md). The package exposes ten
implemented Kit libraries; speculative package targets are added only with a
real vertical use case.

| Module | Responsibility |
|---|---|
| `PortavozCore` | Shared domain types (meetings, segments, meeting-local speakers, explicitly confirmed canonical people and aliases, audio, calendar-neutral upcoming events, durable processing jobs, bounded failure categories, privacy-safe generation provenance, content-free data-egress policy, per-meeting privacy receipts, and stable secret identifiers) plus platform-neutral capability ports |
| `ApplicationKit` | Characterized workflows for lifecycle/trash, explicit canonical-person lookup/linking, provenance-linked summary, refined-transcript, and Companion generation, standalone file transcription/diarization/summarization, persisted quality refinement, `.portavoz` aggregate import/export, coherent meeting-document preparation and explicit document/action publication, Meeting Detail playback/waveform/filter preparation plus failure-safe compression and clip export, verified calendar-backed speaker-name suggestions, local voice capture/enrollment/status/deletion, participant voice-memory suggestion/admission/persistence and privacy-safe management, local summary-provider discovery and clean-install selection, microphone discovery, resumable recording-root changes, whole-library Markdown backup with typed partial results, one shared Ask search/evidence/answer boundary with storage-independent citations, bounded command-library reads, async secret/pinned-model management, first-run eligibility, exact local-data receipts, source-grounded pre-meeting preparation, redacted support diagnostics, durable recording Start/Stop/launch-recovery handoffs and post-capture transcription/diarization/summary execution with stable coded failures, storage-independent Library/Insights/Meeting Detail/menu-bar read contracts, and deterministic product policies over narrow capability ports |
| `PlatformKit` | Concrete Apple platform/security adapters: device-only Keychain storage and microphone authorization, injected at the app and CLI composition roots |
| `ModelStoreKit` | Curated model registry; exact-revision SHA-256 downloads, atomic repair, verified-installation evidence, and a serialized shared process lifecycle |
| `AudioCaptureKit` | Mic capture (AEC) + per-app Core Audio process taps (macOS 14.4+), crash-safe CAF writer |
| `TranscriptionKit` | Engine protocol, task-based routing, Parakeet (live + durable first-pass recovery) + Whisper (refine), exact privacy-safe initial/Refine operation fingerprints, scheduler |
| `DiarizationKit` | Speaker separation (pyannote/CoreML), who-said-what attribution, voice enrollment |
| `IntelligenceKit` | Summaries (Foundation Models / Ollama / embedded MLX / BYOK), recipes, action items, live Companion, exact content-free generation fingerprints, provider/egress traces, and gateway-only OpenAI-compatible summary and Companion clients |
| `AudioPlaybackKit` | Synchronized player, stateless Accelerate-vectorized channel waveform, clip export, AAC transcode |
| `StorageKit` | GRDB/SQLite schema v14, FTS5 search, additive canonical people/aliases, typed source-revision-fenced overview, decision, action-item, and role-separated Companion evidence with separate reversible overview feedback, a content-free generation-fenced per-meeting mutation journal plus exact-generation text-first aggregate projection/atomic remote replay (the separate CloudKit adapter cannot redefine these rules), scoped Library/Insights/Meeting Detail observations, one-read Spotlight and whole-library backup projections, versioned snapshots, atomic recovered/accepted transcripts, summary and Companion-card provenance, immutable content-free egress attempts and receipt-coverage boundary, atomic support-safe snapshots, durable leased job queue with bounded manual retry, local vector index |
| `IntegrationsKit` | Gateway-only GitHub/Linear/Gist publishers, EventKit calendar, bundle/export formats, MCP protocol handling, deterministic meeting-sync envelopes, and the private-zone CloudKit boundary: encrypted inline/protected-asset records, atomically published complete-protected account/consent/seed and exact delivery/replay state, a thin injected CKSyncEngine delegate, and a manually driven engine with automatic sync disabled. A platform-neutral lifecycle owns explicit enable/seed/retry/pause/remove-device semantics and truthful content-free status. One fail-closed macOS adapter creates the named private container only after explicit consent and signed-capability admission; local/XCUITest builds remain no-cloud. Also owns the policy-checked, receipt-before-transport outbound network adapter |

The macOS app owns per-window `LibraryModel`, `InsightsModel`, and `AskModel`
state owners plus process-scoped command-palette, first-run, and local-data
receipt owners.
SwiftUI views render and present native controls; app composition adapters map
independent GRDB observations to storage-independent ApplicationKit updates.
Library observes meeting rows/voice mix, open items, trash, and active FTS;
Insights observes meeting chronology, participant/commitment facts, talk
balance, and scope-bounded finding evidence; Meeting Detail observes its
transcript/cast, newest immutable summary, Companion cards, privacy receipt,
and durable processing independently. Whole-library backup uses a process-scoped
model and private document/filesystem adapters, so closing Settings does not
cancel it and SwiftUI never coordinates Store or export-format work. Full Ask,
⌘K, CLI, MCP, and briefs share one ApplicationKit search/evidence/answer
workflow; stale palette work is cancelled and exact citations retain their
meeting timestamp. Meeting preparation uses the same evidence, one batched
current-summary projection, independently loaded open commitments, and only
source-indexed optional synthesis.
CLI list/detail/search/open-item and MCP library reads also enter through one
bounded ApplicationKit query boundary; detail and its latest General summary
come from one read-consistent SQLite snapshot. Transcription, diarization,
summarization, persisted Refine, Markdown/PDF/Gist export, GitHub/Linear action
publication, local voice identity, and pinned-model commands enter matching
ApplicationKit workflows; command files retain parsing and terminal output,
while CLI composition adapters own concrete files, models, Store, providers,
integrations, and streaming fingerprints. Keychain and microphone access
live in PlatformKit rather than Core or SwiftUI, and secret consumers receive
an injected Core port or already-resolved credentials.
Durable post-capture work follows the same boundary: one ApplicationKit
workflow owns serial claims, leases, fingerprints, dependencies, retries,
cancellations, and terminal action timing. The macOS process supervisor only
coalesces kicks and schedules the next persisted wake; its adapter retains
recording paths, concrete engines/providers, preferences, Shortcuts, and
content-free telemetry.
Meeting Detail Markdown/PDF preparation and secret-Gist publication also load
one coherent snapshot through ApplicationKit. The macOS adapter owns canonical
rendering, post-admission credentials, and gateway-backed publication while
SwiftUI retains the explicit confirmation, native save panel, and localized
result.
Participant voice-memory suggestions and explicit persistence enter a separate
ApplicationKit workflow; the macOS adapter owns encrypted gallery access,
recording paths, transient embedding extraction, and model construction while
the route-owned `MeetingDetailModel` owns one-shot suggestion state and typed
actions/effects. SwiftUI owns only chips, confirmation, native panels, and
localized outcomes.
Transcript/calendar name suggestions also enter ApplicationKit. The workflow
loads one coherent meeting snapshot, excludes `Me` and already named speakers,
combines optional calendar candidates with an injected on-device proposer, and
rejects every proposal whose normalized name does not occur as complete tokens
in a real transcript line or calendar candidate. It derives typed evidence from
that local source rather than trusting model-authored prose. The route-owned
model keeps loading and suggestion state, removes a chip only after persistence
succeeds, and preserves transcript-versus-calendar provenance; SwiftUI never
requests EventKit access, constructs the proposer, or applies a name by itself.
The user's own voice enrollment also enters ApplicationKit. Settings requests
its fresh echo-cancelled sample and Onboarding either reuses the first-listen
sample or requests a fresh raw sample; app composition owns microphone lifetime,
verified diarizer loading, transient extraction, encrypted storage, and cache
invalidation. SwiftUI never constructs those capabilities, and disposable UI
tests never inspect the host voice identity. Unusable samples are rejected
before persistence, and a failed destructive request does not falsely clear the
enrolled state.
Local summary-provider discovery follows the same boundary. ApplicationKit
receives capability-neutral RAM, disk, Apple-model, and Ollama-model facts,
returns typed recommendation reasons, and configures a clean install only when
no explicit selection exists. The macOS adapter owns Foundation Models,
localhost probing, and UserDefaults; Settings and Onboarding render the result
without importing provider DTOs or recomputing policy.
Settings device operations follow that boundary too. ApplicationKit exposes
capability-neutral microphone choices, recording-root inspection and resumable
updates, and remembered-voice summaries that contain no embedding. The macOS
adapter owns Core Audio, the recording-root marker and filesystem migration,
and the encrypted gallery. SwiftUI retains native folder selection and
localized progress, and destructive gallery failures remain visible.
Pre-meeting reminders also enter ApplicationKit. The workflow selects the
earliest due meeting from one sampled time and returns a typed notice; disabled
reminders do not query the calendar. The macOS adapter retains preferences,
clock, and EventKit access while the process controller owns only its timer,
floating banner, session deduplication, and one-click recording route.
Meeting Detail audio follows the same boundary. The route model owns one-shot
preparation in an audio-directory-scoped task, playback invalidation,
compression state, and clip-export effects; independent review revisions cannot
consume the player load;
ApplicationKit coordinates current channel resolution, synchronized playback,
bounded waveform/filter derivation, and failure-safe all-channel compression.
The macOS adapter owns recording-root lookup and the concrete codec, while
SwiftUI keeps transport controls, drawing, and the native save panel. A failed
conversion removes only generated work and keeps every original channel.
Meeting Detail writes enter its route-owned model through explicit actions and
a narrow app adapter instead of reaching persistence from SwiftUI. These three
features no longer consume a global invalidation counter for reads. Spotlight
uses a process-scoped actor, one consistent StorageKit snapshot, a named
file-protected local index, bounded batches, compact client state, and retries.
At 100,000 meetings the exact projection measures 426 ms instead of 22 seconds;
no cloud service or transcript translation is involved.

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

Distributed as a notarized DMG with Sparkle auto-updates, plus the Homebrew cask above (tap: [johnny4young/homebrew-tap](https://github.com/johnny4young/homebrew-tap)).

## Privacy

Audio, transcripts, summaries, and voice embeddings stay on-device by default. API keys live in the Keychain, never in the database or preferences. Companion BYOK sends only an explicitly enabled knowledge question; OpenAI-compatible summaries send their declared transcript/notes/glossary material only after the user selects that provider. Both cross one policy-checked gateway that distinguishes provable loopback from remote destinations. Explicit Gist, GitHub Issue, and Linear Issue publishing cross the same boundary with separate document/action-item classifications and consent. The gateway validates metadata, persists an immutable content-free attempt, blocks redirects, and only then hands bytes to URLSession; if the receipt cannot be stored, the transfer does not start. Meeting Detail renders those attempts beside generation provenance and marks pre-v7 history as only partially covered. Model downloads are checksum-verified. The MCP server binds to localhost only. See [SECURITY.md](SECURITY.md) for the full commitments and how to report a vulnerability.

The current Developer ID distribution uses Hardened Runtime and notarization,
but **does not claim App Sandbox**. A signed sandbox/control probe showed that a
one-line entitlement change would split today's app/CLI/MCP data and custom
recording-folder behavior. D78 keeps the accurate boundary until a reversible
feature-parity migration also proves capture, updates, and automation.

## Contributing

Issues are the most valuable contribution right now — use cases, platform quirks, model recommendations. See [CONTRIBUTING.md](CONTRIBUTING.md). Privacy is non-negotiable and we are MIT-licensed (no GPL code ports).

## License

[MIT](LICENSE)

---

### Spanish-speaking users

Portavoz started from a real need: Spanish-speaking developers living in English-language meetings. Bilingual summaries, a technical glossary that respects real-world Spanglish (`deploy`, `PR`, `rollback`), and live translated captions are core roadmap items, not side quests.
