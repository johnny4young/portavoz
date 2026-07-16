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
**Current migration:** the paragraph above records the original M5 app shell. D43 now hands Stop to durable process-scoped diarization/summary, and D44 begins the incremental `ApplicationKit` extraction; the SPM/script packaging decision remains in force.
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

## D28 — Co-authored notes: Granola's loop over timestamped context

**Context:** the category's most validated pattern is Granola's ($1.5B valuation, Mar 2026): the user writes raw notes during the meeting and AI weaves them together with the transcript — "notes carry intent, the transcript carries facts." That principle had been written LITERALLY in the doc for our Core `ContextItem` since M0, while the type was still orphaned: no storage, no UI, no summary integration. Roadmap v2.0 did not schedule it — error corrected here.
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

The first 1D-b2b control-plane unit adds two worker primitives without changing
app execution yet. Optional or superseded work may transition from an owned,
unexpired lease to terminal `cancelled` with a stable reason; cancellation does
not claim an artifact exists and does not make the aggregate fail. A
capability-filtered query returns the earliest future `notBefore` among live,
non-exhausted jobs so a process worker can schedule one wake instead of polling.
Both operations exclude deleted meeting roots, and idempotent enqueue never
resurrects a cancellation.

All jobs enqueued for a meeting participate in aggregate completion: active
work keeps `processing`; after active work ends, any failed job yields
`needsAttention` with its stable error code; otherwise terminal work yields
`ready`. Producers therefore enqueue only operations whose requested outcome
should participate in the meeting lifecycle. Slice 1D-a implements this Core
and StorageKit contract while retaining the released synchronous
`RecordingController` path. Slice 1D-b1 owns launch reconciliation of meetings,
leases, and staging files; slice 1D-b2a owns atomic artifact completion and the
first 1D-b2b units own the worker control plane and concrete execution. D43
completes adoption by making normal Stop atomically install captured state and
the initial exact job before kicking that executor.

**Rationale:** immutable operation identity makes retries idempotent, leases
fence stale workers, and deriving aggregate state in StorageKit prevents UI or
workflow callers from inventing conflicting lifecycle truth. Separating queue
correctness from app adoption preserves a small, independently reversible
Strangler slice.

## D40 — Launch recovery prefers persisted evidence over guesses (Jul 2026)

**Context:** SQLite and captured audio cannot share one transaction. A process
or machine can stop after a staging CAF was closed, after it was published, or
after only some channel rows were finalized. On the next launch, both the
configured recordings root and the default fallback may contain evidence, and
the peak/RMS values held in memory during capture no longer exist. Treating one
path as authoritative without inspecting every candidate risks overwriting or
deleting the only usable copy.

**Decision:** `RecordingRecoveryCoordinator` runs from app composition at
process launch, never from a view. It skips benchmark launches and defers while
`RecordingController` is preparing, recording, or processing so it cannot race
an active writer. The pass first recovers expired job leases, then scans every
non-ready meeting and pending asset across the configured and default roots.

Evidence precedence is conservative and repeat-safe:

- staging only: reopen the CAF, reread persisted PCM, reconstruct media,
  duration, size, SHA-256, finite peak/RMS dBFS, and health, then publish by the
  same no-overwrite rename used by normal Stop;
- final only: perform the same full validation without renaming;
- no candidate: install an explicit missing asset state;
- staging plus final, or duplicate candidates across roots: preserve every file
  and mark `capture.recovery.ambiguous`; never overwrite, delete, or choose one.

File inspection and hashing run off the main actor. One StorageKit Unit of Work
installs the complete recovered asset set, preserves immutable asset identity
and ownership, accepts an interrupted `capture.*` shell, and is an exact-repeat
no-op. It may not downgrade or mutate an already-ready meeting. A usable
interrupted recording without transcript becomes `needsAttention` with
`transcription.empty`; a publication-only error may return to `ready` when the
aggregate already has transcript content and no active jobs. Slice 1D-b1 runs
no transcription, diarization, or summary engine. Slice 1D-b2a subsequently
establishes the atomic artifact completion boundary, and D42 starts the worker
only after this recovery pass. D43 makes normal Stop its initial producer.

**Rationale:** recovery has incomplete intent but durable evidence. Explicit
precedence, off-main remeasurement, and conservative ambiguity handling make
the filesystem/SQLite Saga safe after arbitrary termination while preserving
audio and keeping launch responsive. Separating reconciliation from ML worker
adoption keeps the Strangler step independently testable and reversible.

## D41 — Generated artifacts commit with their leased job outcome (Jul 2026)

**Context:** an owner-bound job lease prevents an expired worker from mutating
the queue row, but separate artifact and success transactions still leave two
crash gaps: a committed artifact with a retryable job, or a succeeded job with
no artifact. A transcript may also change while a worker is computing. The
existing `SummaryDraft.fingerprint` cannot be the full job key because D25
deliberately excludes output language for cache/pivot reuse.

**Decision:** generated-content jobs complete only through domain-specific
StorageKit Units of Work. `DiarizationArtifact` and `SummaryArtifact` carry the
full operation fingerprint and source `transcriptRevision`; summary drafts keep
their separate material-cache fingerprint. Completion requires a live meeting,
an owned unexpired lease, matching kind/meeting/fingerprint, and the unchanged
source revision. Diarization additionally enforces meeting-owned speaker and
segment identities before atomically replacing the cast, updating homogeneous
language, incrementing the revision, succeeding the job, and enqueuing optional
dependent work. Summary completion validates immutable snapshot content and
current action-item speaker ownership before inserting the summary/items,
succeeding the job, and enqueuing optional dependents in one transaction.

The generic completion primitive rejects `refine`, `diarization`, and `summary`
jobs. Any validation, constraint, lease, or job-write failure rolls back the
artifact. Aggregate reconciliation also treats a pending capture asset as
`capture.publication.failed`; historical succeeded jobs do not block later
asset recovery. Slice 1D-b2a establishes these boundaries without changing the
released synchronous Stop path. D42 adopts them in a process-scoped executor;
D43 adopts the producer and atomic handoff, while `generationRun` provenance
remains Band 3.

**Rationale:** idempotency requires the operation outcome and its durable
artifact to share one commit boundary. Separating operation identity from cache
identity preserves D25, revision fencing prevents stale overwrite, and typed
completion APIs make an artifact-free success unrepresentable for generated
work.

## D42 — Post-capture execution is process-scoped, exact, and non-polling (Jul 2026)

**Context:** D39 and D41 make durable work claimable and artifact publication
atomic, but they do not define the concrete app executor. A view-owned task can
disappear during navigation, a fixed timer wastes energy, and a broad
"meeting changed" key can either reuse stale work or duplicate an expensive
local model operation. The existing synchronous Stop path must remain intact
until the replacement executor has independent runtime evidence.

**Decision:** `PostCaptureProcessingSupervisor` is process-scoped under
`AppServices`. Process launch first completes D40 capture/lease recovery, then
kicks one serial drain for the explicitly supported diarization and summary
kinds. Repeated kicks coalesce. Each attempt holds a 120-second lease,
heartbeats every 30 seconds, drains due work, and schedules at most one future
wake from StorageKit's earliest supported `notBefore`; it never polls.

Durable operation identities are exact and versioned. Diarization hashes
length-prefixed components containing meeting ID, transcript revision and full
segment identity, the pinned model ID/revision, clustering threshold,
finalized system-audio evidence, and enrolled voiceprint. Summary operation
identity adds provider, target output language, and transcript revision over
D25's language-independent material fingerprint. A changed identity cancels
as superseded. Successful diarization atomically installs attribution and
enqueues the exact dependent summary. Required diarization exhausts retries to
`needsAttention`; optional summary exhausts to non-failing cancellation, which
preserves the released "transcript without summary is valid" contract.

The deterministic `-seed-processing` characterization path is accepted only
with `-use-temp-store`. It uses a mic-only transcript and fake local summary
provider, and bypasses real audio, models, voiceprint files, and Keychain. D43
subsequently adopts this executor from normal Stop.

**Rationale:** process ownership survives window churn, exact identities make
retry and supersession honest, one durable wake minimizes idle cost, and
landing the executor before its producer keeps feature parity and rollback
small. Separating fixture adapters from biometric/Keychain state also makes the
end-to-end characterization safe rather than merely database-isolated.

## D43 — Stop atomically hands captured truth to durable processing (Jul 2026)

**Context:** D42 proved the replacement executor independently, but committing
the captured snapshot and enqueueing its first job in separate transactions
would leave a termination window: launch could find a real transcript and
finalized audio with no resumable operation. Loading the encrypted voiceprint
only after file publication would widen that window. Moving post-meeting work
off Stop must also preserve immediate navigation, transcript-only success when
summary is unavailable, and the user's configured Shortcut.

**Decision:** each recording starts one utility-priority voiceprint read after
its shell/assets are reserved. The value is shared by live diarization and the
exact initial operation request. On Stop, valid audio is published first;
`installCapturedSnapshot(..., enqueue:)` then installs finalized/missing assets,
provisional cast/transcript, notes, Companion cards, and the initial
diarization job in one SQLite transaction. Job-admission failure rolls the
whole snapshot back; the controller then makes one best-effort fallback commit
of the captured content as `needsAttention`, never deleting audio.

After that commit, `RecordingController` immediately enters `done` and kicks
the process supervisor. Diarization and optional summary continue through D42
and refresh the selected detail after atomic artifact commits. If no summary
provider exists, the Shortcut runs after diarization with transcript-only
Markdown; if summary succeeds or exhausts its optional retries, it runs after
that terminal outcome. Disposable `-use-temp-store` launches never invoke a
real host Shortcut. Shortcut execution remains best-effort and is not yet an
outbox event; durable exactly-once external delivery remains Band 3.

**Rationale:** one transaction closes the only database-side gap between
irreversible capture and retryable derivation. Sampling identity evidence
during capture keeps Stop responsive and gives live/batch paths the same
speaker-identity input. Immediate handoff improves UX without weakening
recovery, while terminal-aware Shortcut timing preserves released automation
and the valid transcript-without-summary contract.

## D44 — Application dependencies grow only with vertical use cases (Jul 2026)

**Context:** adding every capability Kit to a new `ApplicationKit` before any
workflow moves would create another broad composition target without proving a
boundary. Conversely, moving orchestration before app/CLI manifests and tests
recognize the layer would make dependency direction conventional rather than
enforceable. Core also still contains one known platform exception:
`SecretStore.swift` imports Security.

**Decision:** Band 2 begins with a separately shippable dependency shell.
`ApplicationKit` initially depends only on `PortavozCore` and exposes one
Sendable async `ApplicationUseCase<Request, Response>` contract. The app, CLI,
XcodeGen project, and package tests link the product, but no runtime workflow
moves in this slice. Each later vertical extraction adds only the capability
dependency required by that use case in the same commit; capability Kits must
never depend back on ApplicationKit.

Architecture tests parse the real SwiftPM target declarations and source
imports. They enforce the initial Core-only edge, app/CLI/test visibility,
reverse-dependency prohibition, and the approved import surface. Core's
existing Security import is an explicit one-file baseline, not an accepted
target state: no second forbidden import may appear, and the exception is
removed when SecretStore moves to its platform adapter.

**Rationale:** a ratchet makes architecture executable while keeping the first
commit behavior-neutral. Dependencies become evidence of a real workflow
instead of speculative permission, and the documented exception model lets
tests improve the graph immediately without pretending existing debt is gone.

**First ratchet (slice 2B):** `ApplicationKit` now admits StorageKit only for
`DeleteMeeting` and `RestoreMeeting`. Both depend on the minimal Sendable
`MeetingLifecycleStore` port, with `MeetingStore` as the production adapter.
Library, Meeting Detail, and Recently Deleted invoke those use cases through
the composition root; an architecture test forbids regression to direct app
`store.delete/restore` writes. The presentation layer retains its
existing best-effort error handling, navigation, and `libraryVersion` behavior,
so this is a feature-parity move rather than a UX change.

**Second vertical slice (slice 2C):** permanent deletion and 30-day cleanup now
enter through `PurgeMeeting` and `PurgeExpiredTrash`. The application layer
coordinates a narrow storage port with `MeetingAudioFiles`; the concrete
FileManager/RecordingsLocation adapter stays private to the macOS app. Audio
removal remains intentionally best-effort and cannot block the database purge.
Storage failure still propagates to the existing best-effort presentation
boundary. Expiry receives an explicit cutoff, keeps the released strict
`deletedAt < cutoff` rule, continues after one damaged entry, and returns its
attempt count so `libraryVersion` retains the previous net change.

**Third vertical slice (slice 2D):** `ApplicationKit` now admits
IntelligenceKit only with `RegenerateSummary`. The use case coordinates a
narrow summary store, app-owned glossary preferences, and a provider resolver;
MeetingStore plus private app adapters implement those ports. Meeting Detail
supplies one immutable request and maps a typed outcome rather than selecting
providers, loading notes, computing cache identity, translating pivots, or
persisting snapshots itself. The app retains platform preference storage,
model paths, provider construction, availability checks, and localized copy.

The Strangler move preserves the released asymmetries deliberately: configured
Ollama/MLX providers generate directly and report failure; Apple FM checks the
same-language fingerprint first, attempts a different-language translation
pivot, falls back to full generation, and leaves generation failure silent.
Unreadable notes remain an empty context, failed snapshot persistence is now
explicit in the result but presentation keeps its existing broad invalidation,
and a source rule prevents the old Meeting Detail bypass from returning.

## D45 — The active detail summary is the newest immutable snapshot (Jul 2026)

**Context:** summary versions increment independently per `(meeting, recipe)`.
Meeting Detail nevertheless loaded `summary(meetingID)`, whose default recipe
is `general`. Regenerating as Standup, Planning, 1:1, or a custom recipe saved
the correct immutable snapshot and then incremented `libraryVersion`; the
resulting reload could replace it on screen with an older General snapshot.
The regeneration cache port also omitted recipe identity even though the D25
fingerprint includes it, so a valid non-General hit or pivot could not be read.

**Decision:** `RegenerateSummary` always passes `request.recipe.id` into exact
and pivot storage lookups. Meeting Detail reads `mostRecentSummary`, defined as
the latest live snapshot across recipes by `createdAt`, with SQLite `rowid` as
the deterministic insertion-order tie-breaker. The existing recipe-specific
`summary` API and per-recipe version sequence remain unchanged; no row is
updated, deleted, or migrated.

**Rationale:** the user's last successful structure choice should be the active
detail representation, while immutable history and consumers that explicitly
expect General remain stable. A read policy plus explicit recipe key closes
the gap without schema churn, global mutable "selected recipe" state, or a
cross-recipe version number.

## D46 — Imported audio is staged until its aggregate commits (Jul 2026)

**Context:** audio import was a single MainActor method that synchronously
copied a potentially large file, loaded shared models, transcribed, diarized,
saved the meeting/speakers/segments through three independent transactions,
attempted a summary, and mutated global invalidation. A failure after the copy
could leave invisible audio without a meeting, while a child storage failure
could expose a partial aggregate. The method also mixed platform preferences,
localized progress, concrete engines, filesystem policy, and business failure
semantics.

**Decision:** `ApplicationKit.ImportMeeting` coordinates narrow file,
preference, processor, store, and summarizer ports. The app adapter copies on a
utility task and owns all platform/model/localization details. The copied
system-channel file remains staged until `MeetingStore.saveImportedMeeting`
atomically inserts the meeting, speakers, and segments. Any required failure
before that commit triggers best-effort deletion of the staged directory; a
child insert failure rolls back the SQLite transaction. Whisper and initial
recording-engine preparation plus transcription remain required. The second
diarizer reload and diarization remain degradable to honest unattributed
segments. Summary generation and immutable snapshot persistence remain
best-effort after the aggregate commits. Idle release is scheduled after every
path that successfully prepared Whisper, and transcript/summary policies are
sampled independently once per import.

**Rationale:** this is the smallest Strangler slice that makes file and
database ownership explicit, prevents partial imported meetings, and keeps the
Library responsive without redesigning import as a durable background job.
The Library still shows the same localized phases, invalidates once on success,
and navigates only after the optional summary attempt, preserving v0.6.0 UX.

## D47 — Accepted refine drafts are revision-fenced aggregate replacements (Jul 2026)

**Context:** the in-app quality pass already protected users with a review
sheet, but the draft did not identify the transcript revision it was derived
from. Apply saved `Meeting.language` and then replaced the cast/transcript in a
second transaction. A child failure could therefore leave partially updated
metadata, and a draft left open while another workflow changed the transcript
could overwrite newer truth. The generic `replaceCast` transaction also did
not advance `transcriptRevision`. Refine additionally combined filesystem,
preferences, concrete engines, storage, Companion, localization, and long-lived
task state inside the app layer.

**Decision:** `ApplicationKit.RefineMeeting` creates a reviewable `RefineDraft`
through narrow audio, preference, processor, and progress ports. The draft
carries its source `transcriptRevision`; automatic policy keeps mixed-language
recognition unhinted, digitally silent channels are skipped, mic noise and
bleed filters remain in force, diarization is degradable, cancellation always
propagates, and every model-owning exit schedules the existing idle release.
`ApplyRefinedMeeting` rejects an empty draft and calls
`MeetingStore.applyRefinedCast`, which validates ownership and atomically
tombstones the old cast, inserts the accepted cast/transcript, replaces the
aggregate language (including `nil`), and increments the revision only when the
stored revision still matches the draft. Existing summary snapshots are not
mutated. The CLI uses the same StorageKit Unit of Work.

Companion remains an optional post-commit derivation. An unavailable or
incomplete refresh preserves the existing card snapshot; a complete refresh
replaces it, including with an empty set. Companion persistence failure is a
typed degradable outcome and can never turn the already committed transcript
into a failed apply. Meeting Detail then invokes the existing
`RegenerateSummary` application workflow, which creates a new immutable
summary snapshot under its independent output-language policy. `RefineService`
retains only keyed presentation/task state: explicit cancel is exposed through
the existing control, and per-run identity prevents an older completion from
overwriting state or a replacement model run from starting before cancellation
has unwound.

**Rationale:** revision fencing turns the review sheet into optimistic
concurrency control rather than a best-effort warning, while one aggregate
transaction eliminates partial accepted transcripts. Keeping Companion and
summary after the transcript boundary preserves the product's valid
transcript-without-derived-content contract. The split is a Strangler move:
the same language, filtering, comparison, draft approval, navigation, and
summary UX remain, but business failure policy is now testable without SwiftUI,
real models, or platform storage.

## D48 — Durable Stop policy belongs to ApplicationKit, not capture presentation (Jul 2026)

**Context:** D43 made normal Stop an atomic producer for durable post-capture
processing, but `RecordingController` still combined two different concerns:
flushing a concrete `RecordingSession` and tearing down live feeds, then
deciding how finalized media, provisional transcript truth, no-audio recovery,
job admission, worker launch, and engine release should behave. That second
half is business workflow policy. Leaving it in an `@MainActor` presentation
controller made failure order difficult to characterize and allowed a future
UI edit to bypass the atomic handoff.

**Decision:** `ApplicationKit.StopRecording` receives immutable published-file
evidence plus the reserved aggregate projection. It owns finalized/missing
asset reconciliation, provisional structural attribution, homogeneous
meeting-language derivation while preserving every segment's recognized
language, transcript-empty and no-audio recovery, exact initial diarization
request construction, atomic captured-snapshot/job admission, the
`needsAttention` fallback, process-worker kick, and recording-engine release.
Filesystem existence, storage, and process lifecycle cross narrow async ports;
`MeetingStore` and private app adapters implement them. The use case never
receives `RecordingSession`, file handles, absolute paths, SwiftUI state, or
localized copy.

`RecordingController` remains responsible for stopping the actual platform
session, finishing consumers and live diarization feeds, sampling the existing
recording-scoped voiceprint, and mapping typed outcomes to the released phases
and localized guidance. The process-scoped worker remains the sole owner of
durable diarization/summary execution and terminal-aware Shortcut delivery;
Stop only admits the first exact job and kicks that worker after commit.

**Rationale:** this is the narrowest Strangler boundary that preserves D43's
audio-first durability and immediate navigation without pulling platform
capture into ApplicationKit. One application owner makes success, rollback,
recovery, release, and ordering independently testable. Keeping live teardown
above the boundary avoids a reverse dependency on AudioCaptureKit and keeps
the application layer free of platform sessions and filesystem APIs.

## D49 — Recording Start owns reservation policy, not platform capture objects (Jul 2026)

**Context:** D36/D37 require the meeting shell and pending channel assets to
exist before any source writes, but `RecordingController` still combined that
durability policy with model warm-up, preference sampling, microphone fallback,
process-tap selection, direct live Parakeet setup, concrete session ownership,
voiceprint acquisition, UI state, and localized errors. A source-start failure
can also leave either staging evidence or a file already published while
stopping a partially started `RecordingSession`. Keeping these decisions in a
presentation controller made ordering and evidence preservation difficult to
prove independently.

**Decision:** `ApplicationKit.StartRecording` samples an immutable preference
snapshot once, asks an injected runtime to prepare capture, derives the title
and same-day sequence, atomically reserves the `recording` shell and one pending
asset per selected channel, and only then invokes source start. If source start
fails, the use case checks both staging and published paths, preserves any
evidence as `needsAttention`, and hard-deletes only an untouched empty shell
through D37's guarded operation. Preparation, reservation, and source failures
all schedule the existing idle release; successful capture transfers ownership
to an opaque `StartRecordingSession` instead.

The private macOS runtime owns `MicrophoneSource`, app/global
`ProcessTapSource` selection, AEC warm-up, preferred-input fallback,
`RecordingSession`, direct per-channel Parakeet streams, their teardown, and
one recording-scoped voiceprint future shared by live diarization and durable
Stop. Direct live streams preserve the released D7 live lane; the serial batch
scheduler remains for file work and is not inserted into this path.
`RecordingController` retains visual state, caption filtering/coalescing,
streaming diarization, rolling summary, and exact localized result mapping.
Mic mute remains a synchronous opaque-session command because it must affect
the next audio buffer before an immediately following Stop can overtake it.

**Rationale:** this is the narrowest Strangler slice that gives pre-source
reservation and start-failure recovery one testable application owner without
introducing an `ApplicationKit → AudioCaptureKit` dependency. Platform capture
objects and real-time feed mechanics remain replaceable adapters, while the
business invariants from D36/D37 become independent of SwiftUI and model or
hardware availability. The split preserves every released live feature and
leaves launch recovery as the next bounded workflow.

## D50 — Launch recovery owns reconciliation before worker adoption (Jul 2026)

**Context:** D40 already fixed the evidence precedence and repeat-safe storage
transactions, but the macOS `RecordingRecoveryCoordinator` still combined
expired-lease policy, candidate selection, live-capture exclusion, lifecycle
decisions, filesystem scanning/publication, persistence, OSLog, UI fixtures,
and broad Library invalidation. That made the most failure-sensitive launch
workflow an app-target static function and left its ordering and per-meeting
fallbacks difficult to characterize without launching the application.

**Decision:** `ApplicationKit.RecoverInterruptedMeetings` samples one timestamp,
recovers expired leases first, loads only non-ready candidates, rechecks an
injected live-recording gate before every aggregate, and owns the D40
evidence-to-lifecycle policy. It requests one recovered value per pending asset
from a filesystem port, installs a recovered snapshot only into an untouched
shell, otherwise uses the repeat-safe asset transaction, hard-deletes only a
guard-approved empty recording shell, preserves typed capture failures under
canonical error codes, and reconciles jobless `captured`/`processing` states.
It returns a typed launch report for the released OSLog and single broad
invalidation timing.

The private macOS filesystem adapter still owns `RecordingsLocation`, scans the
configured and default roots together, performs meeting-length CAF validation,
hashing, signal measurement, and no-overwrite publication on a detached utility
task, and maps ambiguity/invalid evidence to typed application errors. The app
coordinator retains only benchmark exclusion, the temp-store-only XCUITest
fixture, OSLog mapping, and `libraryVersion` projection. `PortavozApp` continues
to await the complete recovery pass before starting the process worker. The use
case never loads transcription, diarization, summary, or other ML engines.

**Rationale:** recovery intent is application policy, while file handles,
recordings-root discovery, and CAF mechanics are platform capabilities. This
split gives expired-lease ordering, live-writer exclusion, ready protection,
failure preservation, and invalidation parity one independently testable owner
without adding `AudioCaptureKit` or OSLog to ApplicationKit. Keeping worker
adoption after the awaited boundary preserves D42 and prevents derived work
from racing incomplete audio truth.

## D51 — Bundle import is one aggregate transaction with a local file Saga (Jul 2026)

**Context:** `.portavoz` import decoded and remapped the document, materialized
optional audio, then wrote the meeting, cast, transcript, summary, notes, and
Companion cards through up to six independent Store transactions. A failure in
a late child could expose a partial meeting. The external attachment's decoded
`name` and `fileExtension` were also interpolated into its destination path,
so a hand-authored bundle could introduce path separators, duplicate channels,
or an unsupported file type. JSON and meeting-length data reads ran in an app
service rather than behind an application workflow.

**Decision:** `ApplicationKit.ImportMeetingBundle` receives a format-neutral,
already identity-remapped document from a private IntegrationsKit app adapter.
That adapter reads, decodes, and remaps on a utility task; ApplicationKit does
not add an IntegrationsKit dependency. The boundary clears every incoming
machine-local audio path and accepts only one canonical `system` and/or
`microphone` attachment with a normalized `m4a`, `caf`, or `wav` extension.
An app filesystem adapter stages those attachments only as
`Audio/<fresh-meeting-id>/<channel>.<extension>` and removes a partial
directory if writing fails.

`MeetingStore.saveImportedMeetingBundle` validates ownership and uniqueness,
then installs the meeting, speakers, transcript, optional immutable summary
version 1 and action items, notes, and Companion cards in one GRDB transaction.
If persistence fails after audio staging, the use case attempts a compensating
directory delete without masking the original failure. `AppServices` increments
the released Library invalidation exactly once only after success; callers
retain the existing navigation timing, including double-click routing.

**Rationale:** SQLite can make the relational aggregate atomic, but SQLite and
the filesystem cannot share a real transaction. A bounded local Saga—stage,
commit, compensate—makes that limitation explicit and testable. Keeping
external-format details in a private adapter preserves the dependency ratchet,
while canonical attachment types turn untrusted metadata into a closed domain
before any path is constructed. Fresh identity, open-format compatibility,
optional audio, and the released UX remain unchanged, but partial meetings and
path-shaped attachment metadata no longer cross the boundary.

## D52 — Bundle export owns one read-consistent aggregate outside presentation (Jul 2026)

**Context:** Meeting Detail assembled `.portavoz` documents directly from its
loaded detail and summary state plus separate Store reads for notes and
Companion cards. Export-with-audio then resolved and synchronously loaded each
complete channel with `Data(contentsOf:)` and encoded the base64 JSON from the
MainActor before opening SwiftUI's native save panel. A long recording could
therefore stall the interface, and independently timed reads could mix rows
from different database moments. The view also depended directly on the
external bundle format.

**Decision:** `ApplicationKit.ExportMeetingBundle` loads one format-neutral
aggregate through an `ExportMeetingBundleStore` port. `MeetingStore` implements
that port with one GRDB read of the live meeting, cast, ordered transcript,
newest immutable summary across recipes, notes, and Companion cards. The use
case captures the relative audio directory, clears it before document
assembly, optionally requests only unique validated system/microphone m4a/caf/wav
attachments, and sends the result to an external-document port. It does not
import IntegrationsKit or receive SwiftUI, AppKit, absolute paths, or localized
copy.

Private app adapters retain `RecordingsLocation` fallback resolution,
`MeetingAudioLayout` preference order, best-effort omission of missing or
unreadable individual channels, and the actual IntegrationsKit `MeetingBundle`
mapping. Full channel reads and format-v1 JSON/base64 encoding run in detached
utility tasks. Corrupt optional summary/note/card projections retain the
released degradable fallback, while core aggregate or encoding failures map to
the existing visible export error. Meeting Detail still owns the title-derived
filename, exported UTI, native save panel, and dismissal state.

**Rationale:** export policy is an application workflow; file discovery and
JSON are replaceable capabilities, and the save panel is presentation. One
read transaction provides a coherent shareable snapshot without inventing a
new database or format version. Keeping IntegrationsKit in a private adapter
preserves D44's dependency ratchet, while off-main meeting-length work removes
the largest responsiveness risk without changing the open format, optional
audio semantics, or user flow.

## D53 — Each Library window owns one explicit feature state machine (Jul 2026)

**Context:** `LibraryView` directly owned meetings, voice-mix projections,
cross-meeting actions, trash, search debounce/results, rename, import progress,
calendar agenda, and brief presentation while also coordinating Store,
lifecycle, import, and platform calls. Most refreshes arrived through the same
global `libraryVersion` integer used by Meeting Detail, Insights, and
Spotlight. This made the view the state owner and workflow coordinator, allowed
unrelated writes to reload the whole sidebar, and made its failure and stale-
result behavior difficult to test without launching SwiftUI.

**Decision:** every `ContentView` creates and retains one `@MainActor`
`@Observable` `LibraryModel`. The model exposes one private-write value `State`
snapshot plus enum `Action` and navigation `Effect` contracts. It owns complete
reload/search phases, version and query fences, meetings and their current
voice-mix/open-item/trash projections, rename and mutation outcomes, import
progress/errors, calendar agenda, and on-demand briefs. `LibraryView` and
`TrashSection` render that snapshot, send actions, preserve native panels and
bindings, and map effects to the existing route only.

An app-owned `LibraryModelClient` keeps `AppServices` as composition root and
adapts the already characterized Store, ApplicationKit lifecycle/import use
cases, and EventKit-backed services. This first Strangler slice deliberately
retains the broad `libraryVersion` value as the Library reload request and
retains StorageKit projection types at the temporary client boundary. Reloads
publish only a complete latest-version snapshot; search ignores cancellation
and stale-query results. One model belongs to one window, so transient Library
state cannot leak between `WindowGroup` instances.

**Rationale:** feature state and transition policy become deterministic and
directly unit-testable without adding a state framework or rewriting the UI.
The per-window lifetime matches SwiftUI navigation ownership, while the narrow
client preserves all released controls, accessibility identifiers, agenda,
trash/import behavior, failure degradation, and cross-feature invalidation.
Keeping observation migration separate makes the next slice a replaceable
read-side adapter change: introduce query-specific ApplicationKit/StorageKit
read models and scoped GRDB observations, then retire only the Library's broad
trigger after parity. Other `libraryVersion` consumers remain independent
characterized slices.

## D54 — Library observations follow query ownership, not screen ownership (Jul 2026)

**Context:** after D53, `LibraryModel` owned feature state but still rebuilt one
complete snapshot whenever the process-wide `libraryVersion` changed. Meeting
rows, voice mix, open action items, trash, and active FTS have different source
tables and failure modes. A single observation over their union would remove
the integer trigger but would still recompute unrelated projections—for
example, changing one action item would unnecessarily reload meeting rows and
voice mix. Exposing StorageKit projection types to the app model would also
make the presentation boundary depend on GRDB-shaped contracts.

**Decision:** ApplicationKit owns storage-independent `LibraryMeetingRow`,
`LibraryVoiceMixSlice`, `LibraryOpenItem`, `LibraryTrashItem`,
`LibrarySearchHit`, `LibrarySection`, and `LibraryUpdate` contracts. StorageKit
owns four `ValueObservation` streams with explicit regions:

- meeting rows and voice mix: `meeting`, `speaker`, `segment`;
- open action items: `meeting`, `summary`, `actionItem`;
- trash: `meeting`;
- active FTS: `meeting`, `segment`.

Each StorageKit stream buffers only its newest unread value. The app composition
adapter maps the three persistent sidebar streams to ApplicationKit and merges
them without dropping section identity; search remains a query-scoped stream.
`LibraryModel` waits for every persistent section to report or fail, publishes
complete/empty/degraded/failed phases, and preserves the last healthy data when
one observation later fails. One-shot Store APIs and observed reads share the
same query helpers so their ordering, tombstone scope, and degradable voice-mix
fallback cannot drift. Library no longer reads `libraryVersion`; mutation
adapters continue incrementing it only because Meeting Detail, Insights, and
Spotlight still consume that independent compatibility seam.

**Rationale:** query ownership gives each write the smallest correct
recomputation boundary and isolates failure without a second UI architecture.
ApplicationKit contracts keep the feature model independent from GRDB and
StorageKit, while the composition edge remains responsible for concrete
mapping and cancellation. Explicit base-table regions avoid coupling active
search to FTS5 shadow-table internals. This is a read-path refactor only:
schema v6, `DatabaseQueue`, user-visible behavior, and every existing Library
control remain unchanged. `DatabasePool` still requires measured contention
evidence before adoption.

## D55 — Meeting-review product policy belongs inward, not with adapters (Jul 2026)

**Context:** `IntegrationsKit` mixed external-system and serialization adapters
with four deterministic policies used directly by app presentation:
`ChapterExtractor`, `PlaybackRanges`, `SummarySections`, and `VoiceHue`. None
performs I/O, depends on GRDB, calls an external service, or translates an
external format. Their placement made the integration layer appear necessary
for chaptering, only-my-voice playback, summary tabs, and speaker colors even
though those behaviors are local product decisions.

**Decision:** ApplicationKit owns the four policies as separate source files.
Meeting Detail, Insights, recording captions, and the app design system import
ApplicationKit for them; their unit tests target the same inward boundary. An
architecture rule requires all four files to exist under ApplicationKit, be
absent from IntegrationsKit, and have each direct app consumer import
ApplicationKit. PortavozCore does not absorb them because they are
cross-feature product/read policy rather than portable entity invariants.
At slice 2O, IntegrationsKit retained external adapters plus Insights, brief,
reminder, and mirror policy debt; D56 moves the Insights cluster in its own
characterization slice.

**Rationale:** source ownership now follows semantics instead of historical
convenience, reducing adapter-layer fan-in without creating a new target or
dependency edge. The existing 18 tests preserve exact chapter boundaries,
duration-clamped playback complements, language-agnostic section parsing, and
stable normalized-name hues. Moving the files changes no schema, UI control,
localized copy, or runtime result, and the rule prevents gradual boundary
regression while the rest of IntegrationsKit narrows incrementally.

## D56 — Insights read policy belongs to the application boundary (Jul 2026)

**Context:** `InsightsScope`, `LibraryStats`, and `InsightsFindings` remained in
`IntegrationsKit` even though they only transform local `PortavozCore` values.
They define feature semantics: current/previous period windows, duration and
streak aggregates, zero-filled heatmaps, no-decision findings, and recurring
topic ranking. None performs I/O, knows GRDB, calls an external service, or
translates an external format. `InsightsView` was their only production
consumer and imported the broad outbound layer solely for those local rules.

**Decision:** ApplicationKit owns all three policies with their existing public
APIs and algorithms. Their 21 direct tests target ApplicationKit. A seventeenth
architecture rule requires each source file to remain in ApplicationKit and
absent from IntegrationsKit; it also requires `InsightsView` to import
ApplicationKit without regaining an IntegrationsKit dependency. Store-backed
facts, participant/voice-balance projections, and the feature's existing
`libraryVersion` refresh remain unchanged for later read-model and scoped-
observation slices. IntegrationsKit retained outbound adapters plus the brief,
reminder, and mirror policies at that slice; D57 subsequently moves those final
local policies inward while leaving the adapters in place.

**Rationale:** Insights calculations are product/read decisions, not outbound
integration concerns or reusable entity invariants. Moving them inward reduces
presentation fan-in and narrows IntegrationsKit without adding a capability
dependency, schema migration, state owner, or alternate execution path. The
existing characterization suite preserves calendar cutoffs, open-ended meeting
handling, deterministic ordering, heatmap shape, participant exclusions, and
topic heuristics; the UI smoke and retained app-window screenshot preserve the
real dashboard surface.

## D57 — Meeting-preparation policy is inward; calendar adapters stay outbound (Jul 2026)

**Context:** `BriefRelevance`, `ReminderPolicy`, and `MirrorStats` remained in
`IntegrationsKit` after the adapter layer had relinquished every other local
product/read policy. They encode deterministic feature decisions: explainable
ranking of retrieved passages, reminder lead-window and session deduplication,
and factual post-meeting qualification/comparison copy. `UpcomingEvent` was
declared beside the EventKit adapter even though Library state, recording
routes, reminders, and meeting preparation use only its title, time, and
attendees. Moving that neutral value to ApplicationKit would force a capability
Kit to depend back on the application layer, violating D44.

**Decision:** ApplicationKit owns the three feature policies with their existing
public APIs and exact algorithms. PortavozCore owns `UpcomingEvent` as a
platform-neutral domain value. IntegrationsKit retains `CalendarAttendeeSource`,
EventKit authorization/query/mapping, RAG retrieval, external formats, egress,
and MCP. An eighteenth architecture rule requires the policy files to remain in
ApplicationKit, the event value to remain in Core, and the EventKit adapter to
construct that value without redeclaring it. Direct brief, reminder, and mirror
views import ApplicationKit. The existing 14 policy tests target the inward
modules; a temp-store-only fresh-recording fixture now verifies and captures the
real opted-in mirror sheet.

**Rationale:** feature semantics, reusable domain values, and platform adapters
now have separate owners without adding a package dependency edge or alternate
runtime path. The split removes the last local policy from IntegrationsKit while
preserving brief reasons, reminder timing, bilingual mirror wording, schema,
settings, and localized UI. The UI fixture exercises production qualification
with deterministic seeded facts and no capture hardware or user data.

## D58 — Insights recomputes by query ownership, not global invalidation (Jul 2026)

**Context:** `InsightsView` loaded meeting chronology, library facts, voice
balance, and finding inputs directly from `MeetingStore`, then restarted two
tasks whenever the process-wide `libraryVersion` changed. Those projections
depend on different tables and failure domains, while findings are also scoped
by the selected calendar window. A title-only mutation could therefore rerun
speaker and summary aggregates, and independently launched meeting/finding
loads could briefly describe different source moments.

**Decision:** ApplicationKit owns the storage-independent
`InsightsReadModel`, raw fact/balance/finding contracts, section identities,
and update stream. Each `ContentView` owns one `@MainActor @Observable`
`InsightsModel`; it samples one reference date per scope observation, merges
the four query families, preserves healthy sections after a partial failure,
rejects stale observation updates, and publishes one complete projection.
StorageKit exposes four explicit GRDB observations: live meetings observe
`meeting`; participant and commitment facts observe `meeting`, `speaker`,
`summary`, and `actionItem`; voice balance observes `meeting`, `speaker`, and
`segment`; finding evidence observes `meeting`, `segment`, `summary`, and
`actionItem`, bounded to the 60 newest live meetings in the active scope.
One-shot and observed facts, voice balance, and finding reads share query
helpers. A nineteenth architecture rule forbids `InsightsView` from importing
StorageKit, reaching `services.store`, or consuming `libraryVersion`. Meeting
Detail and Spotlight retain that compatibility seam for independent slices.

**Rationale:** this is a small CQRS-style read boundary, not a second database,
state framework, schema migration, or `DatabasePool` adoption. Writes wake the
smallest correct projection: action-item changes refresh facts/findings, while
segment changes refresh voice balance/findings. The single per-window model
keeps scope, loading, partial failure, and stale-result policy outside SwiftUI,
while preserving the exact local calculations, visible dashboard, schema v6,
and `DatabaseQueue` execution model.

## D59 — Meeting Detail observes one aggregate through independent sections (Jul 2026)

**Context:** Meeting Detail loaded its live meeting/cast/transcript, persisted
Companion cards, and newest immutable summary through three sequential Store
reads whenever the process-wide `libraryVersion` changed. Those sections have
different tables and failure domains. An action-item toggle could rebuild the
transcript-side view task, while a speaker rename could reload summaries and
Companion. The view also owned the timing of those reads, so a broad
invalidation could briefly combine values from different database moments.

**Decision:** ApplicationKit owns storage-independent `MeetingReviewCore`,
`MeetingReviewSummary`, `MeetingReviewReadModel`, section, and update contracts.
Each detail route owns one `@MainActor @Observable MeetingDetailModel` that
merges three streams, distinguishes an absent/tombstoned meeting from a failed
read, preserves healthy section values after a partial failure, rejects stale
observation instances, and publishes one review projection. StorageKit exposes
three explicit observations: core tracks `meeting`, `speaker`, and `segment`;
the newest cross-recipe summary tracks `meeting`, `summary`, and `actionItem`;
Companion tracks `meeting` and `companionCard`. The core and Companion fetch
helpers are shared with their one-shot APIs; newest-summary selection continues
to use the existing immutable helper. A twentieth architecture rule prevents
the old `libraryVersion`-keyed reload and sequential detail/summary/Companion
reads from returning. Direct title/speaker/action-item/Companion mutations and
the Spotlight compatibility increment remain for slice 2T.

Accepted Refine no longer waits for an unrelated reload before regeneration:
it submits the accepted draft's speakers and segments directly to the existing
`RegenerateSummary` use case, which is the exact material just committed.

**Rationale:** this is a meeting-scoped CQRS-style read boundary, not a new
state framework, schema, database, or cache. Independent table regions avoid
conceptually unrelated projection work and isolate degradable failures, while
one model owns loading and consistency policy outside SwiftUI. The visible
two-column review surface, player lifecycle, chapters, newest summary across
recipes, action items, Companion, exports, refine outcomes, local-first
privacy, schema v6, and `DatabaseQueue` remain unchanged.

## D60 — Meeting Detail mutations enter through its route model (Jul 2026)

**Context:** after D59, Meeting Detail reads belonged to one route-owned model,
but the SwiftUI view still saved meeting titles and speakers, toggled action
items, deleted Companion cards, invoked meeting deletion, and incremented the
Spotlight compatibility counter itself. These paths intentionally had
different released failure policies: title/name suggestions, action toggles,
and meeting deletion were best effort; manual speaker rename exposed the
underlying error; Companion deletion exposed a fixed safe message. Moving only
the calls without preserving those distinctions would change behavior.

**Decision:** `MeetingDetailModel` owns explicit mutation actions and navigation
effects for meeting rename, name/voice suggestion acceptance, manual speaker
rename, action-item completion, Companion removal, searchable-content change,
and meeting deletion. Its narrow client exposes only the required persistence
operations and a search-reindex request. `AppServices+MeetingDetail` implements
that client with `MeetingStore`, the existing ApplicationKit lifecycle use
case, and the temporary `libraryVersion` projection used solely to trigger
Spotlight's full local reindex. The model preserves each released error and
effect policy exactly; scoped observations remain the source of post-write UI
truth rather than optimistic duplicate state.

The app adapter also maps StorageKit's stale-refine error into an app-owned
error before presentation. `MeetingDetailView` no longer reaches
`services.store`, `services.meetingLifecycle`, or `services.libraryVersion`.
It still imports StorageKit for `RecordingsLocation` and `MeetingAudioLayout`
while resolving local audio for playback/voiceprints; that separate file-path
seam belongs to the measured Band 4 detail decomposition. Summary regeneration
and reviewed refine remain existing ApplicationKit workflows, not raw
persistence mutations.

**Rationale:** feature mutation policy now has the same single owner as feature
read state, SwiftUI renders/presents instead of coordinating persistence, and
the composition root retains concrete storage and indexing knowledge. The
two-column review, explicit remember-voice consent, best-effort operations,
visible errors, delete navigation, summary/refine outcomes, schema v6, local
privacy, and Spotlight behavior remain unchanged. The seeded action-item UI
case proves a model-routed write returns through the scoped summary observation.

## D61 — Package boundaries require implemented behavior (Jul 2026)

**Context:** `ContextFeedKit` and `SyncKit` were public SwiftPM products but did
not define usable capabilities. The former was only a type alias to Core's
`ContextItem`; the latter contained only an unused `Visibility` enum. No app,
CLI, test, project, script, or visible public GitHub code imported either
module. Portavoz ships as an app rather than a package SDK, and remains on a
pre-1.0 product line, so retaining these targets created a false compatibility
promise without preserving released behavior.

**Decision:** remove both library products, targets, test dependencies, and
placeholder source files. `ContextItem` remains in PortavozCore and the
co-authored-notes behavior remains part of the product and roadmap. A future
sync boundary must land vertically with its conflict semantics, schema,
use-case contract, platform adapter, privacy rules, and tests; it must not begin
as a speculative target. An architecture test rejects either placeholder name
in the package manifest until such a vertical decision deliberately replaces
this rule.

**Rationale:** the package now communicates nine real capability boundaries,
reduces build-graph and public-API surface, and avoids premature abstractions.
The compatibility audit found no consumer to break, while every released
capture, transcript, note, export, and review feature remains available through
its existing Core, ApplicationKit, capability, storage, integration, and app
owners.

## D62 — Generated summaries and provenance commit as one fact (Jul 2026)

**Context:** schema v6 already provided a `generationRun` envelope and nullable
artifact links, but no producer populated them. Manual regeneration could
complete, fail, cancel, reuse an exact snapshot, or translate an Apple
Foundation Models pivot before falling back to full generation. Writing a run
and summary independently could leave an orphaned success or an artifact with
missing provenance; logging prompts or outputs would also duplicate private
meeting content without improving reproducibility.

**Decision:** PortavozCore defines typed generation-run identity, summary kind,
and terminal outcomes. Every concrete manual-regeneration provider reports its
provider, model, and optional pinned revision. ApplicationKit creates one
privacy-safe envelope per actual generation or translation attempt using the
existing material fingerprint, recipe/reuse operation, requested output
language, timing, and aggregate output byte/action counts. It stores no
transcript, note, prompt, summary, or action text. Exact cache hits create no
run because no model operation occurred. Failed and cancelled attempts persist
as best-effort terminal records; a failed translation pivot remains visible as
one failed run before the released full-generation fallback creates its own
run.

StorageKit installs a successful run, immutable summary snapshot, and action
items in one transaction and links the summary's `generationRunID`. It rejects
standalone successful summary runs, blank output language, malformed JSON,
nonterminal timing, cross-meeting links, language mismatches, and non-summary
or unsuccessful artifact links. Failed/cancelled provenance persistence and
successful artifact persistence retain the released best-effort presentation:
storage diagnostics never replace the provider result shown to the user.
Accepted Refine uses the same regeneration path and therefore receives the
same summary provenance; durable post-capture, import, transcript/refine, and
Companion producers remain later vertical slices.

**Rationale:** one transaction makes provenance and artifact truth
non-contradictory, while a typed, content-free envelope supports future local
diagnostics without creating a second sensitive corpus. Attempt-level records
make pivot fallback and cancellation explainable, and the no-run cache rule
keeps provenance semantically honest. The provider order, cache behavior,
failure asymmetry, immutable history, visible summary, schema version, and
local-first privacy remain unchanged.

## D63 — Durable summary provenance shares the processing fence (Jul 2026)

**Context:** the post-capture summary worker already claimed an owner-bound
lease, recomputed an exact operation fingerprint, rejected stale transcript
revisions, and atomically published a summary with job success. Adding
provenance outside that boundary could record a successful model run whose
artifact lost its lease or became stale, or publish an artifact without the
run that explains it. Retries also need attempt-level history without copying
private meeting material into diagnostics.

**Decision:** `SummaryArtifact` requires a typed successful `GenerationRun`.
The durable worker creates its immutable attempt only after the meeting,
request, provider, and exact operation fingerprint have passed preflight, and
immediately before invoking the provider. Its content-free configuration names
the durable job and attempt, `generate` operation, recipe, source transcript
revision, and `post-capture` workflow. Provider and model identity follow the
actual selection: configured Ollama model, pinned MLX catalog ID/revision,
Apple's system language model, or the deterministic UI fixture. Metrics contain
only output UTF-8 bytes and action-item count.

StorageKit inserts that successful run, immutable summary, action items, job
success, and lifecycle reconciliation inside the existing
owner-lease/source-revision transaction. Run and artifact fingerprints must
match. A late transaction failure rolls all of them back. Once a model attempt
has begun, provider or publish failure records a standalone best-effort failed
run; task cancellation, lease loss, or superseded input records a cancelled
run. Provider unavailability or input supersession before model start records
nothing because no attempt occurred. Retry, optional-summary degradation,
provider fallback, immediate Meeting Detail availability, and post-meeting
Shortcut timing keep their released behavior.

**Rationale:** the processing fence is the only authority that can truthfully
declare both a durable job and its generated artifact successful. Requiring the
run at the artifact type boundary makes missing provenance unrepresentable,
while separate terminal attempts explain wasted or cancelled model work without
weakening retry semantics or creating a second private corpus. The schema,
visible summary, and local-first behavior remain unchanged.

## D64 — Import summary provenance cannot weaken the imported aggregate (Jul 2026)

**Context:** external-audio import intentionally commits the copied audio,
meeting, cast, and transcript before attempting its optional summary. The
released workflow returns that usable aggregate even when no summary provider
exists, generation fails or is cancelled, or summary persistence fails. Adding
provenance must not make optional intelligence capable of rolling back captured
user value, and a provider-unavailable path must not claim a model attempt that
never occurred.

**Decision:** `ImportMeeting` resolves a metadata-bearing summary provider only
after the required aggregate commits. When no provider is available it creates
no run. Immediately before each real provider call, the use case snapshots one
attempt ID, provider/model and optional revision, the existing material
`SummaryFingerprint`, General recipe, requested output language, start time,
and the `audio-import`/`generate` operation. Its configuration and metrics are
content-free; metrics contain only output UTF-8 bytes and action-item count.

A successful run, immutable summary, and action items publish atomically through
StorageKit's generated-summary transaction. If provider execution is cancelled
or fails, the attempt is stored separately as cancelled or failed. If summary
publication fails after the model returns, the success transaction rolls back
and the same attempt ID is persisted best effort as failed with aggregate output
metrics. Provenance persistence itself remains degradable, so diagnostics never
replace the import result. Required aggregate installation, staged-audio
compensation before that commit, typed progress, navigation, language policy,
and engine idle-release timing retain their released semantics.

**Rationale:** the imported meeting transaction and generated-summary
transaction have different business criticality. Keeping their boundaries
separate preserves audio-first durability while the shared run envelope makes
every actual optional model call explainable. Reusing the attempt identity
after a publish rollback records one truthful operation rather than inventing a
second call, and the no-provider/no-run rule keeps diagnostics semantically
honest without changing schema or visible behavior.

## D65 — Refine transcript provenance follows the user's acceptance boundary (Jul 2026)

**Context:** one quality Refine can invoke Whisper once for retained system
audio and once for microphone audio, then filter/attribute the combined result
into a single reviewable draft. The current transcript remains authoritative
until the user accepts that draft, and Apply already rejects a draft generated
from a stale transcript revision. Persisting each low-level channel call as an
independent success would not describe the coherent artifact the user reviews;
persisting success before Apply would create durable provenance for output the
user discarded or that lost its revision fence.

**Decision:** one Refine execution creates one composite transcript
`GenerationRun` immediately before its first real Whisper call, covering every
non-silent system/microphone channel in that draft. Its exact operation
fingerprint length-frames and hashes meeting/source revision, the actual
WhisperKit provider and selected pinned model/revision, automatic versus fixed
language hint, ordered vocabulary material, and channel/content digests. The
app reuses finalized v6 capture SHA-256 evidence only after the current byte
count matches; legacy audio is streamed through local SHA-256. Paths,
vocabulary, transcript text, and draft text never enter persisted provenance.
Configuration stores only workflow/operation, channel names, policy mode,
source revision, and vocabulary count; metrics store only segment count,
output UTF-8 byte count, and aggregate speech milliseconds.

Successful provenance remains an ephemeral member of `RefineDraft`. On Apply,
StorageKit validates terminal transcript kind/outcome, meeting, output
language, workflow, and source revision, then inserts the run, links every new
segment, replaces the accepted cast/transcript/language, and increments
`transcriptRevision` in the existing transaction. Any stale draft, invalid
provenance, duplicate run, or child write failure rolls back every new row.
Discarded and empty drafts create no success record. Once an attempt begins,
transcription failure or cancellation writes one standalone failed/cancelled
run best effort; silent channels create no run. Later generic segment saves
retain the established link. CLI refinement remains compatible through the
optional run parameter, and best-effort diarization/Companion plus follow-up
summary behavior remain unchanged.

**Rationale:** the accepted transcript — not an individual decoder call or an
ephemeral comparison — is the durable business artifact. Aligning provenance
with that boundary preserves human review and optimistic concurrency while
making accepted model output reproducible and failures diagnosable. One
content-free composite attempt accurately describes multi-channel Refine
without adding schema, duplicating private content, or weakening local-first
behavior.

## D66 — Companion provenance records the durable card and actual egress path (Jul 2026)

**Context:** Companion has two generation contexts with different consistency
boundaries. During recording it classifies closed live turns and may answer
through Foundation Models, local meeting-context RAG, or explicitly enabled
OpenAI-compatible BYOK before Stop persists retained cards. After Refine it
replays accepted participant turns and replaces the prior snapshot only when
the complete pass succeeds. A remote knowledge failure may fall back on-device;
a directed logistics/context question may produce a ping without an answer.
Persisting model inputs or outputs again would create a second sensitive corpus,
while writing runs separately from cards could leave orphaned success. Recording
every normal classifier rejection would also turn expected negative screening
into noisy durable history.

**Decision:** `GenerationRunKind.companion` represents one durable Companion
card, not every classifier invocation. `ProvenanceCompanion` creates an
ephemeral attempt after the deterministic question/name gate and model
availability check. Its exact length-framed SHA-256 identity binds the meeting,
source transcript revision, live-recording/post-refine workflow, candidate,
ordered context passages, optional owner and language, asked-at bit pattern,
and optional external destination/provider/model. The destination may include a
base path but appears only inside the hash; only the disclosure-safe provider
label and model enter configuration. Configuration
records Foundation Models classifier identity, actual answer provider/model,
context count, source revision/workflow, and whether external transfer was
configured, attempted, and successful. Metrics contain only question/answer
UTF-8 byte counts, card kind, and directed status.

BYOK is marked as the active provider before network transfer. Explicit or task
cancellation stops the pipeline and remains cancelled; it cannot silently invoke
the local fallback. An ordinary remote provider failure retains the released
on-device fallback and records both the attempted transfer and final local
provider. Successful live artifacts and terminal attempts completed before the
Stop request join the captured snapshot transaction. Successful post-Refine
artifacts replace cards and insert run links atomically only when their source
revision still equals the current meeting; current failed/cancelled attempts are
best-effort standalone records, while an incomplete pass preserves the prior
cards. Storage rejects duplicate card/run identities, stale or wrong-workflow
runs, standalone success, success without aggregate metrics, and card insertion
failure rolls the replacement and its runs back together. Later generic card
saves preserve an existing `generationRunID`.

Deterministic-gate rejection, model unavailability before an attempt, classifier
negative/logistics drop, unusable answer, deduplication, or dismissal produces
no orphaned successful run. Imported legacy/bundle cards remain valid with a
null link because they were not generated by this local operation.

**Rationale:** the linked card is the user-reviewable generated artifact, so its
run is the smallest durable provenance fact with product meaning. Exact hashed
material and aggregate-only JSON make the operation reproducible without
copying meeting content. Recording the real external attempt and final provider
makes fallback honest, while cancellation and transcript-revision fences prevent
work from crossing a user's Stop or accepted-Refine boundary. The schema,
visible cards, opt-in, question-only BYOK disclosure, fallback, deduplication,
dismissal, and degradable Refine behavior remain unchanged.
