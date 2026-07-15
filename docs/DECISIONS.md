# Decision log

Lightweight ADR format: each entry is a decision made, its context, and its rationale. The decisions here are binding until a later entry explicitly supersedes them.

## D1 — 100% Swift rewrite, without reusing Meetily's Rust core

**Context:** Meetily (~44K LOC Rust + ~30K TS on Tauri) is the conceptual reference. Its core is mostly FFI into Apple APIs (`cidre` crate → Core Audio) and models that the community has already ported to CoreML.
**Decision:** Swift 6 + native SwiftUI; no Rust FFI.
**Rationale:** WhisperKit/FluidAudio/GRDB cover everything Rust provided, better and without an intermediate layer; a single language maximizes maintainability; the ANE (CoreML) consumes ~10x less energy than GPU. Accepted cost: Windows/Linux support is lost — Portavoz is Apple-only by design.

## D2 — Name: Portavoz

**Decision:** The project is called **Portavoz** ("the one who carries your voice"). Domain `portavoz.app` purchased; repo `johnny4young/portavoz`; consider org `portavoz-app` (available as of 2026-07-06) before public launch.
**Rationale:** It names the present (spokesperson for what was said in the meeting) and the roadmap's future (the app that will one day speak for the user). History: Timbral was the tentative frontrunner (concept: the timbral signature of each voice; timbral.app/.dev + GitHub were available). Eliminated due to collisions: Acta (acta.ai), Minuta (minuta.app), Timbre (editor with transcription), Tertulia (book startup), Dixo (≈Dixa), Batuta (cybersecurity $20.5M), Quorum, Relata, Rimay (≈RemyAI), Sonar (SonarQube), Coro (cybersecurity). Known and accepted Portavoz collision: Chilean rapper of the same name (non-software).

## D3 — MIT license + GPL hygiene

**Decision:** All code is MIT. **Porting code from GPL projects is prohibited** — MacParakeet (GPL-3) in particular, which validates our stack but is look-don't-touch. Humla (MIT) and FluidAudio/WhisperKit (MIT/Apache) do allow reuse with attribution.
**Rationale:** maximum adoption, compatible with the PRO model and App Store IAP; direct precedent: Humla.

## D4 — Persistence: GRDB (SQLite) + schema contract frozen from v1

**Decision:** GRDB + FTS5 + sqlite-vec (arrives in M1/M5; M0 without dependencies). NO SwiftData.
**Immutable contract:** (1) UUID PKs everywhere, never autoincrement; (2) `updated_at` + `deleted_at` (tombstones) in syncable tables; (3) summaries as **versioned immutable snapshots**; (4) zero absolute paths in the DB; (5) API keys never in SQLite or UserDefaults → Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`); (6) `visibility` field reserved from v1.
**Rationale:** validated in production by MacParakeet and Humla; SwiftData does not provide FTS or a vector index; the contract makes the schema "sharing-ready" without a painful migration. Reference anti-pattern: Meetily stores API keys in plain SQLite.

## D5 — Dual-channel capture: never mix before diarization

**Decision:** Microphone and system audio are captured and persisted as **separate channels** (`microphone.wav` / `system.wav`). Everything entering through the mic belongs to the user by hardware definition ("structural who-said-what"); ML diarization runs only on the remote/room channel.
**Rationale:** identifies the user's contributions with ~100% accuracy without ML. Meetily mixes the channels and destroys that information. Validated by Humla (dual-stream with Swift sidecars).

## D6 — System audio: per-app process taps (no BlackHole, no global tap by default)

**Decision:** Core Audio process taps (macOS 14.4+) targeting specific PIDs (Zoom/Meet/Teams). The global tap exists only as an explicit option.
**Rationale:** no virtual drivers or extra installation; capturing only the meeting app avoids contaminating the transcript with music/notifications and provides a better privacy story. Sets the minimum target: **macOS 14.4** (iOS 17 for WhisperKit).

## D7 — Multiple models: routing by task, never one global model

**Decision:** `TranscriptionEngine`/`SummaryProvider` protocols + curated registry (JSON with id, task, pinned sha256, upstream revision, minimum RAM, license) + router by `ModelTask`.
**Default recommendations:** live STT = Parakeet v3 (FluidAudio/ANE) or SpeechAnalyzer (macOS 26+); final re-pass = Whisper large-v3-turbo (WhisperKit); diarization = pyannote community-1 (Sortformer alternative); local summary = Foundation Models, scaling to Qwen3 4B (MLX); titles/embeddings = small models; translation = OS Translation framework. Overrides by language (Humla pattern) and by hardware.
**Scheduler rule:** live work never waits for batch work (separate slots, MacParakeet pattern).
**Rationale:** each task has a different optimum; sha256 verification is mandatory (a model is code you execute). Feature requested in Meetily issues: custom HF models — supported by the registry.

## D8 — Privacy: local by default, explicit BYOK, opt-in telemetry

**Decision:** local summary/transcription/diarization by default; sending a transcript to a cloud LLM requires visible and labeled opt-in, never a silent default. **Opt-in** telemetry (Meetily ships PostHog opt-out). Voiceprints = biometric data: on-device only, encrypted, never synced, deletable with one action. Recording disclosure with jurisdiction presets (two-party consent).
**Rationale:** this is the positioning of the entire product; public criticism of Meetily ("sending to Claude/Groq reintroduces the cloud") confirms it.

## D9 — Business model: unlimited local FREE + one-time-payment PRO

**Decision:** FREE never limits minutes/meetings/history (the user's local compute is free). PRO = one-time license (~US$69, $49 launch; non-consumable IAP on iOS): multi-device CloudKit sync, developer integrations (GitHub/Linear/Jira), RAG chat over history, MCP server, exportable clips, advanced Recipes, voice enrollment + automatic names, meeting-health. Paid upgrades only for major versions (MacWhisper model).
**OSS strategy:** all code open source; PRO as an "honor-system key" — anyone who builds from source gets everything; anyone who downloads the signed binary pays.
**Rationale:** Fathom proved that unlimited free drives growth; Otter proved that stingy free kills it; MacWhisper (€59) and superwhisper ($249 lifetime) proved one-time payment in this exact category on Mac.

## D10 — Distribution

**Decision:** macOS: notarized DMG + Sparkle 2 + Homebrew cask + direct sales (Paddle/Lemon Squeezy). iOS/visionOS: App Store with IAP. Public CLI as a developer acquisition channel.
**Rationale:** complete pattern validated by MacParakeet; direct sales avoid the 30% on Mac.

## D11 — iOS strategy: in-person recorder + companion (hard constraint)

**Decision:** iOS/iPadOS **cannot capture system audio from other apps** (sandbox; no process taps; no API records third-party calls — iOS 18.1+ call recording is exclusive to the Phone app). The iOS product is: (1) first-class in-person recorder (AirPods studio-quality via `bluetoothHighQualityRecording`, iOS 26); (2) speakerphone calls (mic captures both sides); (3) ReplayKit broadcast only as an experimental importer (hard 50 MB limit in the extension → write to App Group, process in the app); (4) universal importer (share extension); (5) Mac companion (CKSyncEngine, Live Activities, remote control); (6) overnight processing (BGProcessingTask with `requiresExternalPower`).
**Rationale:** promising call capture on iOS would be a lie; the repositioning covers real use cases that the Mac does not.

## D12 — Sharing: 3-level ladder, schema ready from v1

**Decision:** L0 (M5): share sheet + MD/PDF export + **GitHub Gist** with one click. L1 (M7, PRO): native CKShare between Apple IDs. L2 (phase 5): self-hostable PocketBase-style relay (Humla pattern) with a read-only snapshot web viewer. No custom backend is built before L2, but the schema (D4) already supports it.
**Rationale:** each level is useful on its own; zero servers until there is proven demand.

## D13 — Testing: XCTest (not Swift Testing) and build without full Xcode

**Decision:** XCTest for the entire suite; CI with `swift build && swift test` on `macos-latest`.
**Rationale:** the development machine had CommandLineTools selected (without Testing/XCTest modules); XCTest + `DEVELOPER_DIR` is the common denominator. Migrating to Swift Testing is acceptable when it stops hurting.

## D14 — Concurrency: strict Swift 6

**Decision:** actors + `AsyncStream` end-to-end; `@unchecked Sendable` only with a comment justifying confinement; no manual locks.
**Rationale:** eliminates by construction the class of bugs that live in 83 `unsafe` blocks and 266 `unwrap()` calls in Meetily.

## D15 — M2 STT: FluidAudio pinned by minor + Parakeet v3 pinned by multi-artifact sha256

**Context:** M2 needs on-device live and batch STT (D7). CoreML models are distributed as `.mlmodelc` bundles (directories of N files) in Hugging Face repos — a single `sha256` per model is insufficient.
**Decision:** (1) FluidAudio as an SPM dependency with `.upToNextMinor(from: "0.15.4")` — it renames public APIs between minors. (2) The registry (`ModelDescriptor`) lists **every file** as `ModelArtifact {path, sha256, sizeBytes}` with `resolveBase` fixed to an exact commit (`…/resolve/<sha>`); `ModelStore` verifies size + sha256 of each download before the atomic move, and `verify()` re-hashes everything before loading. (3) Only the subset used by the v3 int8 loader is downloaded (Preprocessor/Encoder/Decoder/JointDecisionv3 + vocab = 483 MB, not the repo's 3 GB). The sha256 values come from the HF tree API (LFS provides sha256; small files are hashed manually when pinning).
**Critical rule discovered:** the descriptor's `folderName` MUST be the name FluidAudio resolves (repo without `-coreml`, e.g. `parakeet-tdt-0.6b-v3`); with any other name FluidAudio **re-downloads the repo without verification** into a sibling directory, bypassing the registry. Protected by a test.
**Rationale:** satisfies the "models = code" rule (mandatory verification) without giving up FluidAudio's loader; pinning by commit makes an irreproducible download impossible. Licenses: FluidAudio Apache-2.0, model CC-BY-4.0 — compatible with MIT + attribution (D3).

## D16 — Live captions: short sliding window over TDT v3 + custom delta filter

**Context:** FluidAudio's `.streaming` config emits one update per 11 s chunk (its `hypothesisChunkSeconds` is not used in the 0.15.4 pipeline) — unusable for the M2 criterion of < 2 s. The true-streaming alternatives (Parakeet EOU 120M, Nemotron) use smaller models/other repos and would duplicate registry work for worse quality.
**Decision:** stay on TDT v3 with a custom `SlidingWindowAsrConfig`: left 11 s / chunk 1.0 s / right 0.4 s (= 12.4 s, fits within the model's fixed 15 s). The long left context preserves quality; structural latency is chunk + right + inference. Because upstream dedup fails with small chunks (each update re-emits the re-decoded left context), `ParakeetSegmentMapper` trims the overlap on our side: `tokenTimings` arrive in absolute stream time → only tokens with `startTime` after the last emitted boundary are retained, and the delta text is reconstructed from those tokens.
**Measured (M4 Max, with batch at ~100x in parallel):** transcript lag p50 0.24 s / p95 0.53 s. Accepted cost: deltas can split subwords at seams ("ally, on your device") — the quality transcript comes from the final re-pass (D7); captions prioritize freshness.
**Rationale:** one model for live+batch in M2 (less RAM, one registry), meeting the criterion with a 4x margin.

## D17 — M3 diarization: online pyannote+WeSpeaker, calibrated 0.45 threshold, structural attribution with multi-turn slicing

**Context:** M3 needs who-said-what on the system channel. FluidAudio provides the pyannote community-1 (segmentation) + WeSpeaker v2 (embeddings) pair in a ~14 MB CoreML repo, with an online pipeline (`DiarizerManager`) whose `SpeakerManager` maintains stable identities across windows — suitable for streaming with `atTime`.
**Decision:** (1) pyannote+WeSpeaker pair pinned by sha256 (10 artifacts, commit `1ed7a662…`) in the same `ModelStore` (D15); loaded through explicit paths (`DiarizerModels.load(localSegmentationModel:…)`), which never downloads. (2) **`clusteringThreshold = 0.45`**, not FluidAudio's 0.7 default: its internal wiring multiplies ×1.2 (→ 0.84 cosine assignment distance) and merges real speakers — verified with pyannote's AMI sample (reference RTTM), where 0.7 and 0.55 collapse to 1 speaker and 0.45 reproduces it almost exactly. (3) Structural attribution in `SpeakerAttributor` (pure functions): mic → "Me" by hardware (D5, no ML); system → turn with the greatest overlap; segments spanning multiple turns are **split at turn boundaries**, distributing words proportionally by time; no turn → unattributed (better than misattributed). (4) Batch segments split on sentence punctuation in addition to pauses, because TDT timings have no gaps (token end = next token start) and pause splitting almost never triggers.
**Measured (2026-07-07):** AMI sample with 2 speakers ≈ reference RTTM; 2-voice TTS conversations alternate correctly (known artifact: a spurious speaker in the last zero-padded window, quality ~0.2). One diarizer = one session (the `SpeakerManager` accumulates the voice database).
**Rationale:** same stack and same registry as M2; the threshold is the only deviation from the upstream default and is anchored to reproducible public ground truth. Formal criterion pending: DER < 15% in a real 4-person meeting.

## D18 — M4 summaries: on-device Foundation Models with convergent map-reduce; explicit OpenAI-compatible BYOK

**Context:** M4 requires structured summaries in < 30 s, bilingual ES/EN with the glossary intact. Apple's on-device model (Foundation Models, macOS 26+) has a window of **4096 tokens including instructions, guided-generation schema, and output**.
**Decision:** (1) Absolute default: on-device `FoundationModelSummaryProvider` with guided generation (`@Generable`) into a neutral `StructuredSummary` shared by all providers (markdown + action-item owners are derived from it). (2) Long transcripts go through **recursive map-reduce**: 4500-character chunks → notes with a hard cap of 250 tokens (compression ≥4x per level — the cap is what guarantees convergence; without it the notes do not shrink and recursion does not terminate); the final structured pass requires material ≤ 3000 characters because its window also loads the schema and output. (3) **Greedy** decoding in every pass: with sampling, the 3B model invented action items. (4) The language directive uses a human-readable name ("Spanish (español)", not "es") and is REPEATED at the end of the user prompt — the model ignored it when it appeared only in instructions. Headings are translated; the glossary remains verbatim. (5) Action items exist only in the dedicated field (never as a section), and the guidance requires explicit commitments, with an empty array if there were none. (6) BYOK: `OpenAICompatibleSummaryProvider` (`/chat/completions`, JSON into `StructuredSummary`), always visibly opted in and labeled (D8); in the CLI, the key arrives through `PORTAVOZ_BYOK_API_KEY` (Keychain storage arrives with the app).
**Measured (M4 Max, 2026-07-07):** ES summary of an EN meeting with glossary intact in 3.8 s; 3-window transcript through the incremental path in ~11 s. < 30 s criterion with margin.
**Rationale:** genuine privacy by default (nothing leaves the device), and the four prompting/budget lessons are locked in by tests (unit + gated integration).

## D19 — M5 StorageKit: the D4 contract implemented in GRDB 7 + FTS5

**Context:** first real persistence code; D4 established the contract in M0.
**Decision:** GRDB 7 (`upToNextMajor(from: 7.11.1)`). Singular camelCase tables (`meeting`, `speaker`, `segment`, `summary`, `actionItem`) aligned 1:1 with Codable records. Implementing D4: UUID string PKs everywhere; `updatedAt` on every write (with `createdAt` preserved in upserts) + `deletedAt` tombstone (never hard delete — `delete()` marks, queries filter); summaries are **insert-only** with an autoincrementing `version` per (meeting, recipe) and unique key — **action items are the deliberate mutable exception** (the user marks them done) and live in their own table referencing the snapshot; relative `audioDirectory`, rejecting absolute paths and `..` when saving; `visibility` reserved with default "private". FTS5 in an external table (`segmentSearch`) synchronized by GRDB triggers; user MATCH is sanitized by quoting each token (hostile input covered by tests). `AudioRetentionPolicy` is persisted as JSON, and **`enforceAudioRetention` closes the M1 debt**: it deletes expired audio under the root (with an anti-path-traversal guard), clears the reference, and never touches the transcript. Domain types moved to Core to avoid Kit↔Kit deps: `Meeting` (new), `AudioRetentionPolicy` (from AudioCaptureKit, compatibility typealias), `Recipe`/`SummaryDraft`/`ActionItem` (from IntelligenceKit).
**Explicitly deferred:** sqlite-vec waits until M8 (C extension; nothing before RAG reads vectors).
**Rationale:** validated in production by MacParakeet/Humla (D4); the schema remains sharing-ready without a painful migration, and the CLI already persists/searches real meetings (`summarize --save`, `meetings list|show|search`).

## D20 — macOS app shell: SPM target + bundle script, no Xcode project (for now)

**Context:** M5 needs the first UI target. A `.app` with TCC permissions (microphone + system audio recording) normally pushes toward an Xcode project.
**Decision:** `portavoz-app` is a normal SPM `executableTarget` (SwiftUI + Observation, all heavy work in the Kits), and `scripts/make-app.sh` wraps it in `dist/Portavoz.app`: Info.plist with `NSMicrophoneUsageDescription` + `NSAudioCaptureUsageDescription`, bundle id `app.portavoz.mac`, minimum macOS 14.4, ad-hoc signature. No `.xcodeproj` or XcodeGen until something forces it — known candidates are iOS (M7), Sparkle/notarization (final M5 packaging), and complex assets/entitlements. Migrating later is cheap: the SwiftUI files move unchanged into an Xcode app target.
**App structure:** `AppServices` (composition root on MainActor: `MeetingStore` + engines loaded once) → `NavigationSplitView` with `LibraryView` (list + FTS search), `MeetingDetailView` (transcript with **editable speaker pills** — closes the M3 pending item —, summary snapshot, checkable action items), and `RecordingView`/`RecordingController` (state machine: prepare models → live captions per channel → on stop: diarize system.wav → attribute → persist → FM summary if Apple Intelligence is available). `MarkdownLite` renders summaries until the polish pass.
**Verified (2026-07-07):** the bundle builds, signs, launches, and renders; a meeting saved by the CLI appears in the app library (same SQLite). The in-app recording flow remains pending interactive testing (TCC requests permissions the first time).
**Rationale:** keeps `swift build`/`swift test` as the only workflow (D13), the repo 100% text, and allows the development harness (human or agent) to build and verify the app headlessly.

## D21 — M6 identity: encrypted voiceprint with cross-channel "Me" + names only with verified evidence

**Context:** M6 requires recognizing the user beyond the mic channel (hybrid meetings where their voice arrives through room/system) and 1-tap mapping of speakers to names.
**Decision (voiceprint):** enrollment extracts a 256-dim WeSpeaker embedding (`extractSpeakerEmbedding`) from ~12 s of isolated speech — the source audio is not retained. `VoiceprintStore` encrypts it with AES-GCM using a 256-bit key that lives ONLY in the Keychain (`WhenUnlockedThisDeviceOnly`): file without key = unreadable by construction; `delete()` destroys the file and key in one action (D8: biometric, on-device, never synced, deletable). The diarizer registers it through `initializeKnownSpeakers` with reserved id `me`/`isPermanent` → its turns receive the label "Me", and `SpeakerAttributor` merges them with the mic's structural "Me" into a single `Speaker`.
**Decision (names):** `SpeakerNamer` (FM, greedy) proposes label→name ONLY with transcript evidence (self-introduction or being named around their turn), with the golden rule **never trust, verify**: every suggestion whose name does not appear literally in the transcript is discarded in code — the integration test caught the 3B inventing "John" with fabricated evidence despite the prompt. Nothing is auto-applied: chips "S1 → ¿Carolina?" with evidence in a tooltip, one tap to accept (M6 criterion).
**Verified (2026-07-07, TTS + real models):** Samantha enrolled from an isolated clip → her turns in a 2-voice conversation return 100% as "Me" (CLI and gated test); the namer finds a self-introduced "Carolina" and, after filtering, no longer invents names for anyone who was never named.
**Rationale:** structural identity where hardware reaches (D5) + opt-in biometrics where it does not; and with small models, the validity of a claim is verified outside the model rather than asking it nicely.

## D22 — M8 local RAG: cross-lingual NLContextualEmbedding, BLOB + cosine, retrieval tuned against real failures

**Context:** M8 requires an agent to answer "what did I agree to yesterday?" over a bilingual ES/EN library, 100% locally.
**Decision (index):** embeddings per segment with **`NLContextualEmbedding` (Latin script)** — a single OS model, a single vector space for Spanish AND English (verified: the cross-lingual paraphrase is closer than unrelated text). Mean pooling + L2 normalization. Persistence: BLOB column in `segment` (schema v2) + brute-force cosine in memory — at meeting scale it takes milliseconds; sqlite-vec enters when the numbers demand it (D19). Embeddings survive unchanged re-saves, are invalidated when text is edited, and tombstoned meetings leave the index.
**Decision (retrieval, every rule arises from an observed failure):** (1) the lexical query for a QUESTION uses OR over content words (≥4 chars) — token-by-token AND never matches a transcript, and OR with stopwords matches everything in the same language; (2) **multi-query with FM**: the question is paraphrased into both library languages (cross-lingual recall; without FM, degrades to the question alone); (3) **micro-segments (< 20 chars) are excluded from the semantic index** (empty marker) — same-language noise drowned out the cross-lingual signal; (4) reciprocal rank fusion (k=60). Answer: on-device `RAGAnswerer`, greedy, complete sentences with [n] citations, context-only-or-say-so.
**Verified (2026-07-07):** `portavoz-cli ask` and the MCP `ask` tool answer with correct sources in both language directions; **M8 acceptance criterion met** through a real MCP session.
**Rationale:** zero third-party dependencies for the index, bilingual from birth, and every heuristic has a failure case that justifies it — they are not RAG superstitions.

## D23 — M5 packaging: Sparkle 2 embedded by script, DMG + appcast + cask with one command

**Context:** D10 established the channel: notarized DMG + Sparkle + Homebrew cask. The app is an SPM executable packaged by script (D20), so packaging is also 100% scripted.
**Decision:** (1) **Sparkle 2.9+** as an SPM dependency of the app target (`SPUStandardUpdaterController` + "Buscar actualizaciones…" menu); `make-app.sh` embeds `Sparkle.framework` in `Contents/Frameworks`, adds the `@executable_path/../Frameworks` rpath, signs the internal XPC/Autoupdate components, and writes `SUFeedURL` (appcast in the GitHub release) + `SUPublicEDKey`. (2) **Dedicated EdDSA key** in the Keychain under account `portavoz` (NOT the default — this machine already had one from another project); the public key lives in `assets/sparkle-public-key`; `generate_appcast --account portavoz` signs each release. (3) `make-dmg.sh`: release bundle → UDZO DMG with symlink to /Applications; ad-hoc signature by default, `PORTAVOZ_SIGN_IDENTITY` and `PORTAVOZ_NOTARY_PROFILE` (notarytool + staple) for real distribution. (4) `make-release.sh <version>`: stamps version, DMG, signed appcast, and cask (`packaging/portavoz.rb` with placeholders) → `dist/release/` ready for `gh release create`; publication checklist in the script header.
**Verified (2026-07-07, ad-hoc E2E):** app with embedded Sparkle launches (rpath ✓); `make-release.sh 0.1.0` produced a mountable 7.9 MB DMG (models download on demand — lightweight installer), appcast with `edSignature`, and cask with real version+sha256.
**Completed (10 Jul 2026):** Developer ID + notarization (`portavoz-notary`), public repo, and cask in the centralized `johnny4young/homebrew-tap` tap.
**Rationale:** the entire release pipeline is one reproducible command without Xcode; the Apple credentials are the only part that cannot be automated.

## D24 — Echo cancellation (AEC) by default on the mic channel

**Context:** in a real meeting played through speakers, the mic captured system audio through the air: ~100% of the "Me" channel was echo from the other participants, duplicating the transcript and breaking the mic→Me premise (D5). Suppressing it by text alone detects only ~57% (the echo arrives degraded and is transcribed differently). The user explicitly rejects being forced to use headphones (Meetily handles this well).
**Decision:** `MicrophoneSource` enables **Apple voice processing** (`setVoiceProcessingEnabled(true)`, system AEC against the default output) **by default**, with `voiceProcessingOtherAudioDuckingConfiguration` set to `.min` to avoid attenuating meeting audio. Opt-out: "Cancelación de eco" toggle in Settings (`aecEnabled`) and `record --no-aec`. If the device rejects voice processing, it degrades to raw capture without failing. In the same layer: resilience to `AVAudioEngineConfigurationChange` (mid-recording device change) by reinstalling the tap, linearly resampling to the stream's original rate, and filling the gap with silence — the channel never silently dies or misaligns the timeline.
**Verified (2026-07-07):** CLI smoke test (engine starts with VPIO, WAV written). Field test pending: real meeting with speakers ("Me" must not duplicate others) and switching headphones mid-recording.
**Rationale:** the physical fix (the mic stops containing everyone else) simultaneously fixes phantom "Me", transcript duplication, and summary bias — without imposing hardware on the user.

## D25 — Multiple engines per role with hardware-based recommendation (operationalizes D7)

**Context:** task routing (D7) currently has one engine per role: Parakeet (live), Whisper large-v3-turbo (quality), Foundation Models (summaries, requires macOS 26 + Apple Intelligence) + BYOK. Three market pressures: (1) Apple released `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26) — faster than Whisper in public benchmarks, zero download, and the engine behind the sherlocking (Notes); (2) Meetily/humla/MacParakeet offer model selection as a central feature (humla even routes by language); (3) the #1 criticism of Meetily is the hardware barrier — a Mac without Apple Intelligence currently gets no local summary.
**Decision:** each role accepts multiple engines with a **hardware-based recommender** (chip/RAM/macOS version) and a visible automatic default ("Recomendado para tu Mac"):
- **Live ASR**: Parakeet TDT v3 | **SpeechAnalyzer streaming** (verified 2026: `AsyncSequence` with `volatileResults`, finalization ~2.1 s, es_MX/es_US supported) — real competition in the LIVE role; benchmark both.
- **Quality ASR (refine)**: Whisper large-v3-turbo leads — **SpeechAnalyzer verified NOT to be quality-class**: 14.0% WER in conversation (earnings22, Argmax) ≈ Whisper base/small, no custom vocabulary, no diarization, ~22 languages. It remains a "rápido y suficiente" refine option on iOS/Macs with limited storage, never the default. Quantized variants verified in argmaxinc/whisperkit-coreml: `large-v3-v20240930_547MB` and `_626MB` (the latter recommended by Argmax for multilingual accuracy — candidate for es/en with little disk). Verified bonus: Argmax OSS SDK v1.0 (May 2026) includes **SpeakerKit** (diarization) in the same package we already use — alternative/benchmark versus FluidAudio.
- **LLM (summary/notes/names/companion)**: chain with explicit and visible fallback — on-device Foundation Models → **embedded MLX** (decided after 2026 verification: `mlx-swift-lm` is MIT, native SPM, 1.4–1.8× faster than llama.cpp on 3–4B with Metal, ~2–2.5 GB RAM at q4; llama.cpp has no first-party SPM) → OpenAI-compatible BYOK (already covers Ollama/LM Studio/Groq/OpenRouter — document it in the UI; it is a hidden feature). Incremental path: first-class Ollama integration BEFORE embedded (the BYOK plumbing already exists; embed MLX later if there is demand for zero dependencies).
- Overrides **per meeting and per language** (humla pattern), never a global model (D7 remains in force).
- Every downloadable engine goes through the sha256 registry (D15); engines conform to the existing protocols (`SummaryProvider`, transcription by role).
- **Reference parameters (measured by Meetily, validate in M10)**: local qwen-class LLM 2b (<14 GB RAM) / 4b (≥14 GB); Whisper catalog with quantized q5 variants (turbo q5_0 ≈ 547 MB — key for Macs with little disk and for iOS); summary cache by fingerprint (transcript+recipe+model+params) to avoid regenerating for free; **cached EN pivot summary + on-demand retranslation** — our bilingual case benefits twice as much.
**Rationale:** model choice is the feature the user perceives as "control"; automatic recommendation prevents it from becoming friction. SpeechAnalyzer turns Apple's threat into a free provider.

## D26 — Live Companion: question detection + suggested answer

> **Name (Jul 2026):** the feature is called **Companion**. It was renamed from "Copiloto" — "Copilot" carries GitHub/Microsoft baggage, and "Facilitator" will be the name of Teams' equivalent feature (~Aug–Sep 2026). Symbols, UI, and docs use "Companion".

**Context:** founder request — if someone asks something in the meeting ("¿cuál es la diferencia entre `var` y `let`?"), the system must offer the answer in real time. Jamie validates the pattern (live Q&A sidebar); no one does it on-device.
**Decision:** 3-stage pipeline over closed captions (the coalescer already defines "closed"):
1. **Detection** (every tick, cheap): heuristic (ends in "?", contains interrogatives, text prosody?) as a pre-filter → greedy FM with schema `{esPregunta, pregunta, dirigidaAMí, tipo: conocimiento|contexto|logística}` over the recent window. The "someone asked you something" detector (mention of your name) shares this stage.
2. **Answer by type**: `context` (for example, “¿qué dijimos del budget?”) → existing local RAG (D22) over the current meeting + history; `knowledge` (for example, “var vs let”) → on-device FM first; if the user configured BYOK **and enabled “Companion con BYOK”**, the external provider is used — with permanent disclosure on the card (“respondido por <proveedor>”). Only the question text + minimal context leave the device, never audio (D8).
3. **UI**: discreet card in the recording's right panel ("❓ Preguntaron: … → 💡 Respuesta sugerida"), with copy/dismiss/pin actions. It never auto-answers or auto-speaks; opt-in per meeting (toggle next to translation). Budget: detection <1 s per tick, answer <5 s.
**Rationale:** it is the live "wow" moment using the architecture that already exists (closed captions + FM + RAG); the type stage avoids the classic failure (answering logistical trivialities).
**Market context (verified 2026-07)**: NO ONE in meeting notes has passive question detection — Cluely sells it and fails (real 5–10 s measured by reviewers, "cheating tool" stigma, $20–75/month); Otter is explicit voice invocation; Granola/Jamie are manual pull. **Microsoft launches "Facilitator" in Teams (proactive question detection) around Aug–Sep 2026** — validation and a ticking clock at once. Our framing wins by design: local (on-device latency can meet <5 s where Cluely cannot), transparent (it helps YOU with your data, no "undetectable" mode), and the `contexto` type answers from YOUR history — something no one without a local library can do.

## D27 — Audio is a first-class actor

**Context:** audio is currently captured, transcribed, and left dead on disk: the app does not play it. Humla has playback with word-by-word highlighting; Otter/Granola treat audio as the canonical record. Without playback there is no human verification of the transcript ("¿de verdad dijo eso?") or clips.
**Decision:** AudioPlaybackKit (new Kit, depends only on PortavozCore):
- **Synchronized player**: AVAudioEngine playerNode over the existing WAV files; clicking a segment jumps to the timestamp (`startTime` already exists); during playback, the current segment is highlighted (and the word, when the engine provides word timings). 1–2x speed and skip-silence (gaps between segments are known).
- **Waveform** per meeting: RMS downsampled to ~2000 buckets, colored by speaker (diarization turns), cached in `Audio/<id>/waveform.bin` — computed once on save.
- **Clips**: mark a range in the waveform/transcript → export `.m4a` (AVAssetExportSession) + attributed MD snippet; "mark" is FREE, "export" is PRO (already in the matrix).
- **Master + economics**: WAV remains the master (the pipeline requires it); optional AAC transcode after refine as an additional retention policy (D4 already models retention).
- **Signal conditioning** (Meetily pattern): normalization to −23 LUFS (voice broadcast standard) as the pipeline target — our `normalizePeak` is the first step; evaluate RNNoise-style denoise (Apple already provides AEC+NS through voice processing, D24) and ~80 Hz high-pass for voice.
- **Import external audio as a meeting** (drag an .m4a/.wav into the library → transcribe+diarize+summarize): the refine pipeline already does everything; only the UI entry point is missing.
- **Recording crash safety** (MacParakeet pattern, verified in its spec): its M4A files fragmented at 1 s survive `kill -9`. Our WAV files through AVAudioFile probably DO NOT (incomplete RIFF header on crash) — verify and migrate the container to **CAF** (append-safe by design, same AVAudioFile) or fragmented M4A. A 1 h recording cannot die with the app.
- **Storage economics**: 22 min = 126 MB/channel in WAV; MacParakeet stores 64 kbps AAC (~10 MB). Keeping PCM until refine and transcoding afterward is the balance (refine wants the intact signal).
- **⚠️ Verified risk to monitor**: MacParakeet DISCARDED process taps because they "do not coexist reliably with VPIO in-process" — exactly our D6+D24 combination. Our evidence (1 real meeting with both active) is insufficient. Documented Plan B: OFFLINE post-recording echo cancellation (derive mic-cleaned with delay estimation), which is what they do.
**Rationale:** audio is the product's source of truth; treating it as a dead file gives the differentiated experience away to Otter. Everything is pure AVFoundation — zero new dependencies.

## D28 — Co-authored notes: Granola's loop over ContextFeedKit

**Context:** the category's most validated pattern is Granola's ($1.5B valuation, Mar 2026): the user writes raw notes during the meeting and AI weaves them together with the transcript — "notes carry intent, the transcript carries facts." That principle has been written LITERALLY in the doc for our `ContextItem` (ContextFeedKit) since M0… and the type remains orphaned: no storage, no UI, no summary integration. Roadmap v2.0 did not schedule it — error corrected here.
**Decision:** its own early milestone in phase 2:
1. **Notes editor in RecordingView** (third panel/tab next to captions and summary — MacParakeet's Notes/Transcript/Ask panel pattern): plain text with automatic per-line timestamps (`ContextItem.timestamp` = seconds since start, already modeled). Pasted links and snippets are typed automatically (`kind`).
2. **Persistence**: `contextItem` table (additive, D4-compatible) + export in markdown.
3. **Notes-guided summary**: `SummaryRequest` gains `contextItems`; PromptFactory injects them as user intent ("estas notas marcan lo que importa — expándelas con hechos del transcript, no las contradigas"). The mid-meeting "¿qué me perdí?" and rolling summary also see them.
4. **Visual distinction for co-authorship** (the detail that makes Granola trustworthy): in the final summary, what came from your notes is marked differently from what AI added, and additions link to the transcript segment (timestamp citations already exist in the schema).
**Rationale:** turns a generic summary into YOUR note — the differentiator cited in every Granola review — with a type we already designed and a prompt pattern the pipeline already masters (glossary/language). Market bonus: the #1 criticisms of Granola (no speaker ID, playback, consent) are exactly D21+D27+D8 — its loop plus our identity is a combination no one has.

## D29 — Single flight to the on-device model: priority scheduler

**Context:** the 3B FM is ONE shared resource — rolling summary, Companion (D26), names, `ask`, and refine re-summaries all want it at once, and the ANE serializes generation anyway: concurrent requests only bury the queue inside the daemon, where it cannot be managed. Without a policy, the Companion's <5 s budget is a lottery (GAPS T3).
**Decision:** `IntelligenceScheduler` (actor in IntelligenceKit, no FM dependency — testable on any platform): single-flight priority queue with three classes — `interactive` (a human is waiting: Companion answers, names, ask) > `live` (question-detection ticks: frequent, cheap, discardable) > `background` (rolling-summary notes, re-summaries). Rules: (1) **granularity = ONE model call** — map-reduce chains release the slot BETWEEN calls, so interactive work interleaves and its wait is bounded by the in-flight call (~1–4 s); (2) FIFO within the same class; (3) **latest-wins by `key`**: an enqueued job with the same key is replaced with `CancellationError` (detection ticks never pile up) — IN-FLIGHT work is never interrupted; (4) caller cancellation dequeues. Wiring: all 6 FM call sites go through the scheduler; the provider's public methods gain `priority:` (default `.interactive`; rolling summary passes `.background`). Swift 6 note: FM's `Response<T>` is not Sendable — closures return the payload (String/custom types) built INSIDE the slot.
**Rationale:** turns Companion latency from unpredictable into bounded by design, with 7 pure tests locking in the properties (single-flight, priority, FIFO, latest-wins, cancellation, release on throw, interleaving between chain steps).

## D30 — XcodeGen + XCUITest for UI verification (qualifies D20)

**Context:** D20 keeps the macOS shell as an SPM target + `make-app.sh`, without an Xcode project. But verifying the UI manually (or worse, with computer-use-style screen control) is slow and fragile; XCUITest needs an Xcode project with a `bundle.ui-testing` target. The sibling Gancho project already solved this with **XcodeGen** (`project.yml` as the source of truth, generated and gitignored `.xcodeproj`).
**Decision:** adopt the same pattern ONLY for verification tooling. `project.yml` generates `Portavoz.xcodeproj` (gitignored) with two targets: `Portavoz` (app, recompiles `Sources/portavoz-app` against the package's library products) and `PortavozUITests` (`bundle.ui-testing`, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`, `GENERATE_INFOPLIST_FILE: YES` so Xcode signs the runner — Gatekeeper blocks unsigned runners). The app honors testing launch args: **`-use-temp-store`** (disposable DB, never touches the real library) and **`-seed-demo`** (seeds a deterministic meeting with transcript, summary, co-authorship bullet "▸", **and audio** — `AppServices.seedDemoIfRequested()`). Audio is isolated through the **`PORTAVOZ_AUDIO_ROOT`** env var (relocatable audio root, without touching your folder): the seed synthesizes a two-tone clip (mic 220 Hz / system 440 Hz, half and half → the waveform shows both colors) or **adopts a real recording** if one already exists in the root — a UITest points `PORTAVOZ_TEST_AUDIO_ROOT` to a real copy to exercise the player with real audio (verified: 8 real min, player + waveform OK). `make test-ui` runs `xcodebuild test`. Ad-hoc signing (`CODE_SIGN_IDENTITY: "-"`, no team, hardened runtime off) — local tooling, not distribution.
**Rationale:** reproducible, automated UI verification without driving the screen. **Shipping remains `make-app.sh`** (signed + notarized, D20/D23 intact); this project is only for `make test-ui` and is not the release path. XCTest in the UI target coexists with the XCTest package suite (D13). Verified: `LibraryUITests` (library renders) and `MeetingDetailUITests` (transcript + summary + D28 co-authorship mark ▸) are green.

## D31 — IntegrationsKit is the only cross-Kit layer (Jul 2026)

**Context:** the RAG pipeline (`AskPipeline`) needs StorageKit (store/FTS/vectors) and IntelligenceKit (embedder, query expansion) at the same time; it was duplicated in the CLI and app because no Kit could depend on both.

**Decision:** IntegrationsKit is the only Kit authorized to depend on non-foundational capability sibling Kits (`IntelligenceKit` + `StorageKit`). It is the cross-cutting integration layer over stored meetings (export, RAG retrieval, calendar). `TranscriptionKit` and `DiarizationKit` additionally depend on the foundational `ModelStoreKit`; all other capability Kits depend only on Core. `AskPipeline` lives in IntegrationsKit once; the CLI and app consume it.

## D32 — Embedded MLX lives in IntelligenceKit (Jul 2026)

**Context:** D25 called for a 100% local summary engine for Macs with neither Apple Intelligence NOR Ollama. The embedded provider needs the prompt/parsing stack (`PromptFactory`, `StructuredSummary`, `SummaryFingerprint`) that lives in IntelligenceKit; a separate Kit would have forced all of that into Core.

**Decision:** `mlx-swift-lm` (MIT, pinned exactly to 3.31.4 — official successor to `mlx-swift-examples`, which was frozen in Oct 2025; the migration was made in Jul 2026 to support `qwen3_5`) is a direct IntelligenceKit dependency, together with `swift-transformers` (the new package decoupled the tokenizer: the app provides it through the `MLXHuggingFace` macros), and `MLXSummaryProvider` lives there, reusing the OpenAI-compatible provider's prompt/JSON contract (changing engines never changes the summary's shape). The shipped default is **Qwen3.5-4B MLX 4-bit** (Apache-2.0, ungated, ~3 GB), sha256-pinned as `ModelCatalog.mlxQwen35`; Qwen3-4B-Instruct-2507 remains in the catalog as the explicit A/B alternative. Generation runs on GPU through `ModelContainer.perform` (serialized, one summary at a time) and does NOT pass through `IntelligenceScheduler` (that lane exists because of ANE contention). Accepted cost: mlx compiles C++/Metal on the first build (~10 min) and increases the binary size; the model downloads only if the user selects the "Built-in (MLX)" engine.

**Shipping and verification:** the SwiftPM CLI cannot compile Metal shaders (limitation documented in the mlx-swift README): `swift build` never produces `default.metallib`, so no test under `swift test` can exercise generation. The metallib comes from a one-time xcodebuild pass that `scripts/build-mlx-metallib.sh` caches in `.build/mlx/` (cache keyed by the resolved mlx-swift version; requires the Xcode 26 Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain`); `make-app.sh` copies `mlx-swift_Cmlx.bundle` to `Contents/Resources`, where the mlx loader resolves it through NSBundle. E2E verification is in-app — `Portavoz.app/Contents/MacOS/portavoz-app --mlx-smoke` (same pattern as `--bench-live`): synthetic ES meeting → structured summary with correct decision and action item in ~5 s (M-series, model already downloaded).

## D33 — Evolve through a durable application layer, not a rewrite (Jul 2026)

**Context:** Portavoz has a strong modular SwiftPM base and a complete released
feature set, but application orchestration has accumulated in `AppServices`,
`RecordingController`, and large SwiftUI views. Capture, filesystem state,
SQLite writes, derived AI work, navigation, and external side effects do not
yet share a durable workflow boundary. A rewrite would create an unacceptable
feature-parity gap; adding a server or a large state framework would not solve
capture durability.

**Decision:** keep Portavoz as a modular local monolith and migrate through
small Strangler slices. Add `ApplicationKit` for use cases, durable state
machines, and read-model coordination; make `AppServices` a composition root;
keep capability Kits behind role-oriented protocols; use a persisted meeting
shell, Unit of Work, Saga/process manager, idempotent processing jobs, and a
transactional outbox for the recording lifecycle. Use feature-scoped
`@Observable` models and GRDB observations rather than a new state-management
or database framework. Every slice must preserve all released features and be
independently shippable. The full plan and decision gates are recorded in
`refactor-20260714.md`.

**Status:** accepted target under incremental adoption. Band 0 established its
truth boundaries; Band 1 slices 1A–1C installed schema v6, durable pre-capture
state, validated atomic file publication, and the captured Unit of Work.
`ApplicationKit`, jobs, recovery, outbox,
and scoped observations remain targets. `ARCHITECTURE.md` must always
distinguish current behavior from this target.

## D34 — English, commit-synchronized project documentation (Jul 2026)

**Context:** durable project knowledge is distributed across architecture,
decisions, roadmap, gaps, specs, product, release, and public documents.
Several claims had drifted from the code, and updating documentation only at
the end of a multi-commit refactor would make intermediate commits ambiguous
and unsafe for the next contributor.

**Decision:** all explanatory documentation under `docs/` is written in
English. Intentionally localized UI strings, bilingual transcript examples,
and language-quality fixtures may remain quoted as literals. Every architecture
refactor commit updates `ARCHITECTURE.md` and every other document whose truth
changed in that commit: as-built specs for behavior, ROADMAP for status,
GAPS for remaining work, DECISIONS for binding choices, README for public
behavior, and RELEASING for shipping changes. CHANGELOG remains reserved for
user-visible features and fixes; internal refactors or documentation-only
changes do not receive a misleading product entry. Documentation accuracy and
feature parity are part of the commit's definition of done.

## D35 — Transcript truth and generated-output language are independent (Jul 2026)

**Context:** the transcription language pin was also choosing recording
summary language, while audio import used the system locale and regeneration
reused a snapshot or the system locale. That coupling produced different
results for the same meeting and made a recognition recovery control look like
a translation preference. It also risked forcing one language across a mixed
Spanish/English meeting.

**Decision:** `PortavozCore` owns canonical `LanguageCode`,
`TranscriptLanguagePolicy`, and `SummaryLanguagePolicy` values.
`TranscriptLanguagePolicy.automatic` is the default and leaves mixed meetings
unhinted so recognition preserves the language of each segment; `.fixed` is an
explicit recovery choice for weak or noisy audio. `SummaryLanguagePolicy`
either follows homogeneous spoken language or fixes generated output to one
language. Mixed or unknown meetings in follow-spoken mode use the selected app
locale, then English as the final deterministic fallback. The persisted global
defaults remain separate UserDefaults keys, and one app adapter resolves them
for recording, rolling summary, import, and regeneration. An explicit
per-meeting regeneration language is persisted in its immutable summary
snapshot and does not mutate transcript text. Refine recomputes
`Meeting.language` from the resulting attributed segments, including clearing
stale aggregate language when the result is mixed or unknown.

Schema v5 remained unchanged in Band 0. Band 1 slice 1A subsequently installed
the schema-v6 `meetingPreference` row shape; app flows do not create or read it
yet. Until a later adoption slice, a transcript recovery override remains an
explicit refine operation rather than a hidden sticky preference.

**Rationale:** recognition truth and generated presentation have different
jobs. Separating them preserves source evidence, makes all entry paths
consistent, supports multilingual actors, and permits output-language choices
without translating or overwriting the source transcript.

## D36 — One additive schema v6 contract before workflow adoption (Jul 2026)

**Context:** Band 1 needs meeting lifecycle state, first-class audio assets,
idempotent work, generation provenance, external-side-effect delivery, and
durable per-meeting policy. Splitting those mutually related foreign keys
across provisional migration identifiers would create several intermediate
database contracts while the released runtime still uses none of them.

**Decision:** ship the complete durability surface atomically as migration
`v6`: meeting lifecycle/revision/error columns; `audioAsset`, `processingJob`,
`generationRun`, `outboxEvent`, and `meetingPreference`; and nullable
generation-run links on generated artifacts. Behavioral adoption remains
incremental. Migration v6 must not inspect the filesystem or infer assets from
legacy directories. Existing meetings default to `ready` at transcript
revision zero, new tables begin empty, and `Meeting.audioDirectory` remains the
runtime source of truth until a later Strangler slice proves the replacement
read path.

There is no destructive downgrade migration. Before behavioral adoption, an
older v1-v5 GRDB migrator ignores the unknown applied `v6` identifier and the
additive columns/tables do not invalidate its existing reads. A rollback must
never delete v6 structures or copy data back automatically. Once new workflow
states or rows become authoritative, binary rollback requires an explicit
compatibility assessment and a scratch copy of the database; schema rollback
is not the recovery mechanism.

Slice 1B crosses that behavioral-adoption boundary for recordings created by
the new binary: their pre-capture lifecycle and `audioAsset` reservations are
authoritative. An older binary may still open the additive schema, but it does
not understand or reconcile those rows and must not be treated as an automatic
safe rollback. Roll back only after inspecting a copied database and preserving
the new recording directories; never remove v6 tables to make the old binary
appear compatible.

**Rationale:** one durable contract gives every later Band 1 slice stable
foreign keys and invariants while keeping runtime risk small. Deferring
filesystem backfill avoids fabricating metadata, blocking launch on media I/O,
or changing the released audio path before parity tests exist.

## D37 — Only an unstarted provisional recording may be hard-deleted (Jul 2026)

**Context:** D4 requires tombstones for user meetings, while Band 1 creates a
meeting shell before any capture source starts. A source-start failure that
writes no bytes should not leave an empty ghost meeting or a sync tombstone;
conversely, cleanup must never delete a shell that owns audio or persisted
meeting content.

**Decision:** the sole recording-time hard-delete exception is a provisional
shell still in `recording` state for which the controller found no reserved
channel file and StorageKit found no speaker, segment, summary, context item,
or Companion card. `MeetingStore.discardUnstartedRecording` enforces the
database half of that invariant and asset rows cascade with the shell. If any
channel file exists, startup failure preserves the meeting as
`needsAttention`. Once capture has produced a file or persisted content, normal
tombstone and recovery rules apply; error cleanup never deletes the audio.

Slice 1B initially reserved the as-built final `channel.caf` paths. Slice 1C
now reserves `<channel>.partial.caf`, publishes only validated files, and
checks both staging and final names before allowing this rollback.

**Rationale:** this keeps the library free of attempts that never became user
data while making the conservative choice whenever potentially useful audio
exists. The narrow two-sided guard prevents a convenience rollback from
becoming a data-loss path.

## D38 — Publish validated audio before installing one captured snapshot (Jul 2026)

**Context:** SQLite cannot atomically commit an audio-file rename, but readers
must never discover a half-written channel and the database must not expose a
captured meeting without its matching assets and live content. Overwriting an
existing final path during error recovery would be worse than surfacing the
collision.

**Decision:** capture writes `<channel>.partial.caf`; CAF remains the terminal
extension because `AVAudioFile` selects the container from it. Stop releases
the writer, verifies a readable non-empty mono CAF, streams SHA-256, records
actual format/duration/size plus finite peak/RMS dBFS from successfully written,
signed-PCM-clamped samples and signal health, and publishes through a
same-directory rename to `<channel>.caf`. An existing final file is never
replaced. The app then calls one
`MeetingStore.installCapturedSnapshot` Unit of Work that advances the untouched
shell to `captured`, finalizes every asset, and inserts the provisional live
cast/transcript, notes, and Companion cards. A changed shell, preexisting
content or summary, and incomplete finalized evidence are rejected before any
write. Batch diarization replaces that provisional cast atomically; optional
summary work follows.

A missing channel is explicit and metadata-free. A staging file whose
publication failed remains pending for launch recovery. If no channel was
published but either staging or final data exists, the meeting becomes
`needsAttention` and D37 hard rollback is forbidden. The filesystem/SQLite gap
is a deliberate Saga boundary; slice 1D owns idempotent launch reconciliation.

**Rationale:** readers observe only validated final names, checksum and health
evidence become durable truth, and one SQLite transaction prevents partial
aggregate installation. Conservative collision handling and retained staging
files prefer recoverability over silent data loss.

## D39 — Durable jobs use immutable idempotency keys and owner-bound leases (Jul 2026)

**Context:** schema v6 reserves a durable `processingJob` row, but SQL
constraints alone do not define who may claim work, how retries survive a
crash, or how job state drives the meeting aggregate. Re-running an operation
must not duplicate derived artifacts, and a worker that wakes after its lease
expires must not overwrite a newer attempt.

**Decision:** `(meetingID, kind, inputFingerprint)` is the immutable logical
operation key. Enqueue is one transaction: it returns an existing row without
changing its execution policy or resurrecting terminal work, inserts new rows
once, and derives `meeting.lifecycleState = processing` whenever active work
exists. A `recording` meeting cannot enqueue derived work. Job kinds are open
typed values so adding a local worker does not force a schema migration.

Workers claim only explicitly supported kinds. A claim atomically selects the
highest-priority due job of a live meeting, increments one attempt, and records
an owner plus absolute expiry. Heartbeat, success, and failure require that
same owner and an unexpired lease; progress cannot move backwards. A failed
attempt becomes pending at `notBefore` only while attempts remain, otherwise it
is terminal. Repeat-safe expired-lease recovery performs the same retry-or-
exhaust decision and can run on every launch. Deleted meetings expose no jobs
and cannot be claimed.

All jobs enqueued for a meeting participate in aggregate completion: active
work keeps `processing`; after active work ends, any failed job yields
`needsAttention` with its stable error code; otherwise terminal work yields
`ready`. Producers therefore enqueue only operations whose requested outcome
should participate in the meeting lifecycle. Slice 1D-a implements this Core
and StorageKit contract while retaining the released synchronous
`RecordingController` path. Slice 1D-b owns concrete app enqueue/execution and
launch reconciliation of meetings, leases, and staging files.

**Rationale:** immutable operation identity makes retries idempotent, leases
fence stale workers, and deriving aggregate state in StorageKit prevents UI or
workflow callers from inventing conflicting lifecycle truth. Separating queue
correctness from app adoption preserves a small, independently reversible
Strangler slice.
