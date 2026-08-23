# Decision log

Lightweight ADR format: each entry is a decision made, its context, and its rationale. The decisions here are binding until a later entry explicitly supersedes them.

## D1 — 100% Swift rewrite, without reusing the reference Rust core

**Context:** the conceptual reference implementation (~44K LOC Rust + ~30K TS on Tauri; see the competitive map in PRODUCT.md) informs the scope. Its core is mostly FFI into Apple APIs (`cidre` crate → Core Audio) and models that the community has already ported to CoreML.
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
**Rationale:** validated in production by MacParakeet and Humla; SwiftData does not provide FTS or a vector index; the contract makes the schema "sharing-ready" without a painful migration. Reference anti-pattern: the reference Rust app stores API keys in plain SQLite.

## D5 — Dual-channel capture: never mix before diarization

**Decision:** Microphone and system audio are captured and persisted as **separate channels** (`microphone.wav` / `system.wav`). Everything entering through the mic belongs to the user by hardware definition ("structural who-said-what"); ML diarization runs only on the remote/room channel.
**Rationale:** identifies the user's contributions with ~100% accuracy without ML. The reference Rust app mixes the channels and destroys that information. Validated by Humla (dual-stream with Swift sidecars).

## D6 — System audio: per-app process taps (no BlackHole, no global tap by default)

**Decision:** Core Audio process taps (macOS 14.4+) targeting specific PIDs (Zoom/Meet/Teams). The global tap exists only as an explicit option.
**Rationale:** no virtual drivers or extra installation; capturing only the meeting app avoids contaminating the transcript with music/notifications and provides a better privacy story. Sets the minimum target: **macOS 14.4** (iOS 17 for WhisperKit).

## D7 — Multiple models: routing by task, never one global model

**Decision:** `TranscriptionEngine`/`SummaryProvider` protocols + curated registry (JSON with id, task, pinned sha256, upstream revision, minimum RAM, license) + router by `ModelTask`.
**Default recommendations:** live STT = Parakeet v3 (FluidAudio/ANE) or SpeechAnalyzer (macOS 26+); final re-pass = Whisper large-v3-turbo (WhisperKit); diarization = pyannote community-1 (Sortformer alternative); local summary = Foundation Models, scaling to Qwen3 4B (MLX); titles/embeddings = small models; translation = OS Translation framework. Overrides by language (Humla pattern) and by hardware.
**Scheduler rule:** live work never waits for batch work (separate slots, MacParakeet pattern).
**Rationale:** each task has a different optimum; sha256 verification is mandatory (a model is code you execute). Feature requested in the reference app's issue tracker: custom HF models — supported by the registry.

## D8 — Privacy: local by default, explicit BYOK, opt-in telemetry

**Decision:** local summary/transcription/diarization by default; sending a transcript to a cloud LLM requires visible and labeled opt-in, never a silent default. **Opt-in** telemetry (the reference Rust app ships PostHog opt-out). Voiceprints = biometric data: on-device only, encrypted, never synced, deletable with one action. Recording disclosure with jurisdiction presets (two-party consent).
**Rationale:** this is the positioning of the entire product; public criticism of the reference app ("sending to Claude/Groq reintroduces the cloud") confirms it.

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
**Rationale:** eliminates by construction the class of bugs that live in 83 `unsafe` blocks and 266 `unwrap()` calls in the reference Rust core.

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
**Amendment (D107):** calendar attendees later widened the reviewable candidate
set. Candidate membership is explicitly labeled as calendar evidence, never
identity proof. The application verifier now requires complete normalized name
tokens in a real transcript line or calendar candidate, derives typed evidence
from that source, and ignores model-authored evidence prose. The user still
confirms every suggestion.
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
**Decision:** (1) **Sparkle 2.9+** as an SPM dependency of the app target (`SPUStandardUpdaterController` + "Buscar actualizaciones…" menu); `make-app.sh` embeds `Sparkle.framework` in `Contents/Frameworks`, adds the `@executable_path/../Frameworks` rpath, signs the internal XPC/Autoupdate components, and writes `SUFeedURL` (appcast in the GitHub release) + `SUPublicEDKey`. (2) **Dedicated EdDSA key** in the Keychain under account `portavoz` (NOT the default — this machine already had one from another project); the public key lives in `assets/sparkle-public-key`; `generate_appcast --account portavoz` signs each release. (3) `make-dmg.sh`: release bundle → UDZO DMG with symlink to /Applications; ad-hoc signature by default, `PORTAVOZ_SIGN_IDENTITY` and `PORTAVOZ_NOTARY_PROFILE` for real distribution. D74 strengthens that path by notarizing/stapling the inner app before separately notarizing/stapling the outer DMG. (4) `make-release.sh <version>`: stamps version, DMG, signed appcast, and cask (`packaging/portavoz.rb` with placeholders) → `dist/release/` ready for `gh release create`; publication checklist in the script header.
**Verified (2026-07-07, ad-hoc E2E):** app with embedded Sparkle launches (rpath ✓); `make-release.sh 0.1.0` produced a mountable 7.9 MB DMG (models download on demand — lightweight installer), appcast with `edSignature`, and cask with real version+sha256.
**Completed (10 Jul 2026):** Developer ID + notarization (`portavoz-notary`), public repo, and cask in the centralized `johnny4young/homebrew-tap` tap.
**Rationale:** the entire release pipeline is one reproducible command without Xcode; the Apple credentials are the only part that cannot be automated.

## D24 — Echo cancellation (AEC) by default on the mic channel

> **Superseded by D125 (23 Jul 2026).** The original implementation passed its
> CLI smoke but failed the more important call-coexistence invariant in real
> Sequoia and Tahoe meetings.

**Context:** in a real meeting played through speakers, the mic captured system audio through the air: ~100% of the "Me" channel was echo from the other participants, duplicating the transcript and breaking the mic→Me premise (D5). Suppressing it by text alone detects only ~57% (the echo arrives degraded and is transcribed differently). The user explicitly rejects being forced to use headphones (the reference Rust app handles this well).
**Decision:** `MicrophoneSource` enables **Apple voice processing** (`setVoiceProcessingEnabled(true)`, system AEC against the default output) **by default**, with `voiceProcessingOtherAudioDuckingConfiguration` set to `.min` to avoid attenuating meeting audio. Opt-out: "Cancelación de eco" toggle in Settings (`aecEnabled`) and `record --no-aec`. If the device rejects voice processing, it degrades to raw capture without failing. In the same layer: resilience to `AVAudioEngineConfigurationChange` (mid-recording device change) by reinstalling the tap, linearly resampling to the stream's original rate, and filling the gap with silence — the channel never silently dies or misaligns the timeline.
**Verified (2026-07-07):** CLI smoke test (engine starts with VPIO, WAV written). Field test pending: real meeting with speakers ("Me" must not duplicate others) and switching headphones mid-recording.
**Rationale:** the physical fix (the mic stops containing everyone else) simultaneously fixes phantom "Me", transcript duplication, and summary bias — without imposing hardware on the user.

## D25 — Multiple engines per role with hardware-based recommendation (operationalizes D7)

**Context:** task routing (D7) currently has one engine per role: Parakeet (live), Whisper large-v3-turbo (quality), Foundation Models (summaries, requires macOS 26 + Apple Intelligence) + BYOK. Three market pressures: (1) Apple released `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26) — faster than Whisper in public benchmarks, zero download, and the engine behind the sherlocking (Notes); (2) competing local apps (see PRODUCT.md) offer model selection as a central feature, one even routing by language; (3) the #1 criticism of the reference Rust app is the hardware barrier — a Mac without Apple Intelligence currently gets no local summary.
**Decision:** each role accepts multiple engines with a **hardware-based recommender** (chip/RAM/macOS version) and a visible automatic default ("Recomendado para tu Mac"):
- **Live ASR**: Parakeet TDT v3 | **SpeechAnalyzer streaming** (verified 2026: `AsyncSequence` with `volatileResults`, finalization ~2.1 s, es_MX/es_US supported) — real competition in the LIVE role; benchmark both.
- **Quality ASR (refine)**: Whisper large-v3-turbo leads — **SpeechAnalyzer verified NOT to be quality-class**: 14.0% WER in conversation (earnings22, Argmax) ≈ Whisper base/small, no custom vocabulary, no diarization, ~22 languages. It remains a "rápido y suficiente" refine option on iOS/Macs with limited storage, never the default. Quantized variants verified in argmaxinc/whisperkit-coreml: `large-v3-v20240930_547MB` and `_626MB` (the latter recommended by Argmax for multilingual accuracy — candidate for es/en with little disk). Verified bonus: Argmax OSS SDK v1.0 (May 2026) includes **SpeakerKit** (diarization) in the same package we already use — alternative/benchmark versus FluidAudio.
- **LLM (summary/notes/names/companion)**: chain with explicit and visible fallback — on-device Foundation Models → **embedded MLX** (decided after 2026 verification: `mlx-swift-lm` is MIT, native SPM, 1.4–1.8× faster than llama.cpp on 3–4B with Metal, ~2–2.5 GB RAM at q4; llama.cpp has no first-party SPM) → OpenAI-compatible BYOK (already covers Ollama/LM Studio/Groq/OpenRouter — document it in the UI; it is a hidden feature). Incremental path: first-class Ollama integration BEFORE embedded (the BYOK plumbing already exists; embed MLX later if there is demand for zero dependencies).
- Overrides **per meeting and per language** (humla pattern), never a global model (D7 remains in force).
- Every downloadable engine goes through the sha256 registry (D15); engines conform to the existing protocols (`SummaryProvider`, transcription by role).
- **Reference parameters (measured by the reference Rust app, validate in M10)**: local qwen-class LLM 2b (<14 GB RAM) / 4b (≥14 GB); Whisper catalog with quantized q5 variants (turbo q5_0 ≈ 547 MB — key for Macs with little disk and for iOS); summary cache by fingerprint (transcript+recipe+model+params) to avoid regenerating for free; **cached EN pivot summary + on-demand retranslation** — our bilingual case benefits twice as much.
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
- **Waveform** per meeting: channel peak envelope downsampled to the requested bucket count and colored by source. The original persisted `waveform.bin` proposal is superseded by D84: measured stateless vectorized generation is fast enough and cannot become stale.
- **Clips**: mark a range in the waveform/transcript → export `.m4a` (AVAssetExportSession) + attributed MD snippet; "mark" is FREE, "export" is PRO (already in the matrix).
- **Master + economics**: WAV remains the master (the pipeline requires it); optional AAC transcode after refine as an additional retention policy (D4 already models retention).
- **Signal conditioning** (reference-app pattern): normalization to −23 LUFS (voice broadcast standard) as the pipeline target — our `normalizePeak` is the first step; evaluate offline denoise/echo cancellation and ~80 Hz high-pass for voice without changing the live call graph (D125).
- **Import external audio as a meeting** (drag an .m4a/.wav into the library → transcribe+diarize+summarize): the refine pipeline already does everything; only the UI entry point is missing.
- **Recording crash safety** (MacParakeet pattern, verified in its spec): its M4A files fragmented at 1 s survive `kill -9`. Our WAV files through AVAudioFile probably DO NOT (incomplete RIFF header on crash) — verify and migrate the container to **CAF** (append-safe by design, same AVAudioFile) or fragmented M4A. A 1 h recording cannot die with the app.
- **Storage economics**: 22 min = 126 MB/channel in WAV; MacParakeet stores 64 kbps AAC (~10 MB). Keeping PCM until refine and transcoding afterward is the balance (refine wants the intact signal).
- **Resolved live-graph risk**: MacParakeet discarded process taps because they
  do not coexist reliably with VPIO in-process. Real Sequoia and Tahoe calls
  later showed call ducking and microphone degradation with that exact
  combination. D125 removes VPIO from meeting and dictation capture; echo
  cleanup stays after capture.
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
**Decision:** adopt the same pattern ONLY for verification tooling. `project.yml` generates `Portavoz.xcodeproj` (gitignored) with two targets: `Portavoz` (app, recompiles `Sources/portavoz-app` against the package's library products) and `PortavozUITests` (`bundle.ui-testing`, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`, `GENERATE_INFOPLIST_FILE: YES` so Xcode signs the runner — Gatekeeper blocks unsigned runners). The app honors testing launch args: **`-use-temp-store`** (disposable DB, never touches the real library, and treats the encrypted participant-voice gallery as empty so automation cannot inspect the host gallery or Keychain) and **`-seed-demo`** (seeds a deterministic meeting with transcript, summary, co-authorship bullet "▸", **and audio** — `AppServices.seedDemoIfRequested()`). Audio is isolated through the **`PORTAVOZ_AUDIO_ROOT`** env var (relocatable audio root, without touching your folder): the seed synthesizes a two-tone clip (mic 220 Hz / system 440 Hz, half and half → the waveform shows both colors) or **adopts a real recording** if one already exists in the root — a UITest points `PORTAVOZ_TEST_AUDIO_ROOT` to a real copy to exercise the player with real audio (verified: 8 real min, player + waveform OK). `make test-ui` runs `xcodebuild test`. Ad-hoc signing (`CODE_SIGN_IDENTITY: "-"`, no team, hardened runtime off) — local tooling, not distribution.
**Rationale:** reproducible, automated UI verification without driving the screen. **Shipping remains `make-app.sh`** (signed + notarized, D20/D23 intact); this project is only for `make test-ui` and is not the release path. XCTest in the UI target coexists with the XCTest package suite (D13). Verified: `LibraryUITests` (library renders) and `MeetingDetailUITests` (transcript + summary + D28 co-authorship mark ▸) are green.

## D31 — IntegrationsKit is the only cross-Kit layer (Jul 2026)

**Context:** the RAG pipeline (`AskPipeline`) needs StorageKit (store/FTS/vectors) and IntelligenceKit (embedder, query expansion) at the same time; it was duplicated in the CLI and app because no Kit could depend on both.

**Decision:** IntegrationsKit is the only Kit authorized to depend on non-foundational capability sibling Kits (`IntelligenceKit` + `StorageKit`). It is the cross-cutting integration layer over stored meetings (export, RAG retrieval, calendar). `TranscriptionKit` and `DiarizationKit` additionally depend on the foundational `ModelStoreKit`; all other capability Kits depend only on Core. `AskPipeline` lives in IntegrationsKit once; the CLI and app consume it.

**Current qualification:** D33 later introduced ApplicationKit as the authorized application-orchestration fan-in. D100 moves Ask coordination and local retrieval there. IntegrationsKit remains the only *capability* module that depends on sibling capabilities, but it no longer owns the Ask application workflow.

## D32 — Embedded MLX lives in IntelligenceKit (Jul 2026)

**Context:** D25 called for a 100% local summary engine for Macs with neither Apple Intelligence NOR Ollama. The embedded provider needs the prompt/parsing stack (`PromptFactory`, `StructuredSummary`, `SummaryFingerprint`) that lives in IntelligenceKit; a separate Kit would have forced all of that into Core.

**Decision:** `mlx-swift-lm` (MIT, pinned exactly to 3.31.4 — official successor to `mlx-swift-examples`, which was frozen in Oct 2025; the migration was made in Jul 2026 to support `qwen3_5`) is a direct IntelligenceKit dependency, together with `swift-transformers` (the new package decoupled the tokenizer: the app provides it through the `MLXHuggingFace` macros), and `MLXSummaryProvider` lives there, reusing the OpenAI-compatible provider's prompt/JSON contract (changing engines never changes the summary's shape). The shipped default is **Qwen3.5-4B MLX 4-bit** (Apache-2.0, ungated, ~3 GB), sha256-pinned as `ModelCatalog.mlxQwen35`; Qwen3-4B-Instruct-2507 remains in the catalog as the explicit A/B alternative. Generation runs on GPU through `ModelContainer.perform`; D151 later makes its single-flight policy explicit through an independent MLX scheduler lane rather than treating the async cache actor as that policy. Accepted cost: mlx compiles C++/Metal on the first build (~10 min) and increases the binary size; the model downloads only if the user selects the "Built-in (MLX)" engine.

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
independently shippable. Binding migration choices are recorded in this
decision log, while `ARCHITECTURE.md` and the as-built specs describe only the
implemented result.

**Status:** implemented for macOS. `ApplicationKit`, durable capture and
processing jobs, recovery, atomic publication, and scoped observations are
current architecture with executable dependency and presentation ratchets.
Future boundaries still require a concrete vertical use case.

## D34 — English, commit-synchronized project documentation (Jul 2026)

**Context:** durable project knowledge is distributed across architecture,
decisions, roadmap, gaps, specs, product, release, and public documents.
Several claims had drifted from the code, and updating documentation only at
the end of a multi-commit refactor would make intermediate commits ambiguous
and unsafe for the next contributor.

**Decision:** all explanatory documentation under `docs/` is written in
English. Intentionally localized UI strings, bilingual transcript examples,
and language-quality fixtures may remain quoted as literals. Every architecture
change updates `ARCHITECTURE.md` and every other document whose truth changed
in that commit: as-built specs for behavior, GAPS for remaining limitations and
field validation, DECISIONS for binding choices, README for public
behavior, and RELEASING for shipping changes. CHANGELOG remains reserved for
user-visible features and fixes; internal refactors or documentation-only
changes do not receive a misleading product entry. Documentation accuracy and
feature parity are part of the commit's definition of done. D119 later makes
the repository roadmap and completed migration ledger explicitly local-only.

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
D43 adopts the producer and atomic handoff; D62–D66 later adopt
`generationRun` provenance in Band 3.

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
real host Shortcut. Shortcut execution remains best-effort and is not an outbox
event. Completed Band 3 deliberately leaves durable exactly-once local
automation delivery as future work.

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
`ProcessTapSource` selection, raw input warm-up (D125), preferred-input fallback,
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

## D67 — Meeting-derived network egress crosses one policy port (Jul 2026)

**Context:** D66 can record whether Companion attempted an external answer and
which provider ultimately produced a retained card, but the released Companion
path still invoked `URLSession` through the general OpenAI-compatible client.
That made its question-only disclosure a caller convention rather than an
enforceable transport boundary. It also treated a provider host as a disclosure
label without a typed distinction between a provably loopback service and a
destination that may leave the Mac. Moving every integration at once would
create a broad rewrite and weaken the Strangler/feature-parity discipline.

**Decision:** PortavozCore owns content-free `DataEgressRequest` policy values
and the `DataEgressGateway` capability port. Metadata carries operation,
destination and conservative scope, data classification, optional meeting
identity, consent source, and disclosure-safe provider/model identity. The
payload remains a separate `URLRequest`; policy, future receipts, and
diagnostics must not make another copy of meeting material. Only `localhost`,
its subdomains, valid `127/8` IPv4 addresses, and `::1` are classified as
`local-device`; private-LAN, `.local`, malformed, and unknown hosts are
conservatively `remote`.

IntegrationsKit owns `URLSessionDataEgressGateway`. Before transport it verifies
that the declared destination is HTTP(S) with a host and exactly matches the
request, provider host/model are non-empty and consistent, and Companion
knowledge egress is a non-empty POST classified as `meeting-question-only`.
The persisted Settings consent
path also requires the source `MeetingID`. IntelligenceKit's
`CompanionBYOKClient` cannot execute transport without an injected gateway;
the macOS app composes the concrete adapter for live and post-Refine Companion.
Only the static system instruction and classified knowledge-question text enter
the request — recent meeting passages remain on-device. Ordinary provider or
policy failure retains the released Foundation Models fallback, while explicit
cancellation still cannot fall through. Companion provenance records the
actual `local-device`/`remote` destination scope without storing content.

This is the first vertical adoption, not a false claim of universal coverage.
At this slice, the general OpenAI-compatible summary client and explicit
GitHub, Linear, Gist, Shortcut, and other outbound adapters retain their
characterized paths. D68/D69 later migrate every meeting-content HTTP adapter;
the user-configured Shortcut remains an explicit local process surface rather
than a network adapter.

**Rationale:** a narrow inward policy port makes the privacy promise testable
before bytes reach `URLSession`, preserves provider-specific request building,
and gives future receipts and diagnostics one content-free vocabulary. The
conservative scope prevents a private-network hostname from being mislabeled as
strictly on-device. Vertical migration preserves every released feature and
fallback while architecture tests can reject a direct Companion network bypass.

## D68 — OpenAI-compatible summaries cannot bypass data-egress policy (Jul 2026)

**Context:** D67 enforced the first meeting-derived network vertical for
Companion, but `OpenAICompatibleSummaryProvider` still delegated transport to a
general client that owned `URLSession`. That path serves app-selected local
Ollama and explicit CLI BYOK. Its request contains substantially more material
than Companion: formatted transcript and speaker labels, user notes, glossary,
recipe/output instructions, and the requested language. Treating that transfer
as an untyped implementation detail would make future privacy receipts
incomplete and leave a second network bypass in IntelligenceKit.

**Decision:** Core adds `summary-generation`, `meeting-summary-material`,
`summary-engine-settings`, and `explicit-summary-provider` to the content-free
egress vocabulary. The provider/model disclosure allows an optional model so
later non-model integrations can reuse the same envelope, while model-backed
operations still require a non-empty model during adapter validation.

IntelligenceKit's OpenAI-compatible request/response codec is pure and owns no
transport. `OpenAICompatibleSummaryClient` requires an injected
`DataEgressGateway`; `OpenAICompatibleSummaryProvider` and
`OllamaService.summaryProvider` therefore cannot create a meeting-content
network path without that capability. The request supplies the source
`MeetingID`, exact destination and conservative scope, complete-summary
classification, consent source, and provider/model separately from the body.
IntegrationsKit rejects a missing meeting, non-summary consent, wrong
classification, empty/non-POST request, missing model, or destination/provider
mismatch before invoking URLSession. Consent cases are whitelisted by operation
so a Companion marker cannot authorize a summary or vice versa.

The macOS app composes the concrete gateway for Ollama regeneration,
external-audio import, and durable post-capture summary selection with the
existing Settings-selected engine marker. The CLI composes it only after the
existing explicit `--byok` warning. Prompt/body shape, structured parsing,
fingerprints, local/remote provider labels, retry/fallback behavior, and visible
errors remain unchanged. Ollama version/model discovery remains direct because
those requests carry no meeting content. Gist, GitHub Issue, and Linear Issue
publishing remain accurately direct until slice 3G-b.

**Rationale:** capability-specific clients make forbidden transport
unrepresentable in production composition while retaining provider request
building in IntelligenceKit and concrete I/O in IntegrationsKit. The explicit
full-material classification is more honest than reusing Companion's
question-only label. A separate 3G-a commit keeps rollback narrow and lets an
architecture test reject future direct summary transport before publishing
adapters move in 3G-b.

## D69 — Explicit publishers use separate egress capabilities (Jul 2026)

**Context:** after D67/D68, the remaining direct meeting-content URLSession
owners were `GistPublisher`, `GitHubIssuesExporter`, and `LinearExporter`.
Their payloads and user intent differ: a Gist contains a rendered meeting
document, while tracker operations contain one action item plus meeting-title
and owner context. A generic "external publish" marker would be too broad for
future privacy receipts and could authorize one service with consent intended
for another.

**Decision:** Core adds three operations (`publish-github-gist`,
`create-github-issue`, `create-linear-issue`), two classifications
(`meeting-export-document`, `meeting-action-item`), and three matching explicit
consent sources. All three operations require a source `MeetingID`, non-empty
POST body, remote provider disclosure with no model, exact operation-specific
classification/consent, and a canonical service URL before transport. Gist and
Linear use fixed endpoints; GitHub Issues admits only
`/repos/{owner}/{repository}/issues` on `https://api.github.com` without query,
fragment, custom port, or path traversal.

The three publishers require an injected `DataEgressGateway` and cannot own a
URLSession. Meeting Detail composes the gateway after its existing secret-Gist
confirmation; CLI export and issue commands compose it after their existing
explicit flags and warnings. Request bodies, headers, public/secret behavior,
response parsing, success URLs, and visible provider failures are unchanged.
The app and CLI pass the actual source meeting rather than letting an adapter
invent provenance. Content-free model downloads and Ollama discovery remain
outside the meeting-content boundary. The configured Shortcut hook remains an
explicit local process automation surface; it is not falsely labeled as a
network destination.

**Rationale:** separate capabilities make cross-service consent reuse fail
closed while preserving the released sharing and developer workflows. Exact
endpoint validation prevents a forged path from hiding behind a correct host,
and centralized transport gives the later privacy receipt one complete,
content-free vocabulary without duplicating exported meeting data.

## D70 — Audio capture never waits for transcription models (Jul 2026)

**Context:** on a clean Sequoia installation, starting the first recording
awaited verified Parakeet and diarization downloads plus Core ML preparation.
The interface stayed on a model-download screen and made a derivation
capability appear to be a prerequisite for saving the meeting. A live engine
or one channel can also fail after capture begins; preserving only partial
captions would make the later transcript look complete when it is not.

**Decision:** `ApplicationKit.StartRecording` prepares only the microphone and
structural capture channels before reserving and starting audio. The app runtime
may attach direct live Parakeet streams only when a verified engine is already
resident. Otherwise it starts or joins one process-wide verified engine task
after audio is active and exposes a visible deferred-transcript state. D73
later splits that preparation into independently deduplicated Parakeet and
pyannote tasks so recovery joins only Parakeet. Any
missing or failed live lane marks the recording as requiring complete recovery;
it never stops audio or its peer lane.

At Stop, empty captions or that recovery evidence admit a `.transcription`
job in the same captured-snapshot Unit of Work. Its content-free exact
fingerprint binds the meeting/source revision, pinned Parakeet identity,
automatic multilingual/no-vocabulary policy, and finalized channel identity,
health, checksum, duration, and bytes. Pending evidence, missing-only evidence,
and purely silent audio cannot run. The process worker revalidates the identity,
joins verified loading, transcribes each usable channel through the serial
batch lane, preserves its real `AudioChannel`, applies microphone noise/bleed
hygiene, and atomically replaces cast/transcript, advances the revision,
completes the owned job, and enqueues exact diarization. Generic job completion
cannot claim transcription success without that artifact transaction. Whisper
Refine remains a separate explicit, reviewable quality pass.

**Rationale:** audio is Portavoz's primary recoverable fact; model readiness is
derived capability state. Separating them makes clean-install recording fast
and honest without weakening verified downloads, mixed-language preservation,
the live-vs-batch scheduling rule, or the existing lease/revision fences. A
single durable recovery path also handles no-live-model, failed-lane, Stop, and
relaunch cases instead of creating UI-only retries.

## D71 — Whisper preparation is app-scoped, proactive, and verified (Jul 2026)

**Context:** Settings exposed the Turbo/Compact quality choice but not an
explicit preparation action. A clean installation discovered the 626 MB or
1.6 GB transfer only after the user pressed Refine, making a long verified
download look like a failed meeting operation. A download owned by the
Settings view would be equally misleading because closing the window could
cancel it. Discarding successful verification evidence would also force the
first Refine to hash the full model again after Settings reported it ready.

**Decision:** the app composition root owns one serialized Whisper preparation
task across Settings, Refine, and external-audio Import. Settings exposes
separate proactive Download/Try again/Delete actions and observable progress
for Turbo and Compact. Closing or navigating away from Settings never cancels
the transfer. Refine and Import join the matching active task; a request for
the other variant waits for the current preparation to finish before starting
its own. The UI considers a persisted variant complete only when every pinned
model and tokenizer artifact exists at its exact catalog size, while the
preparation path always delegates integrity verification and repair to
`ModelStore`.

`TranscriptionKit` separates preparation from runtime allocation. Only it can
construct the opaque `WhisperEngine.PreparedModel` after the selected model and
shared tokenizer pass the pinned store boundary. `AppServices` retains that
token after background completion so later Refine/Import can load without a
second full verification pass; the heavyweight Whisper runtime still follows
the existing two-minute idle-release policy. Deleting the matching variant
invalidates both the token and any loaded runtime. XCUITest temp stores force a
deterministic missing-model state without reading or modifying the user's real
model directory.

**Rationale:** model transfer is product readiness, not incidental progress
inside a meeting action. App-scoped ownership makes progress truthful across
window lifetimes, one task prevents duplicate multi-gigabyte transfers, and an
opaque verified token makes an unverified runtime load unrepresentable without
keeping 1.6 GB resident. Refine remains explicit and reviewable; this decision
changes readiness UX, not transcript language or acceptance semantics.

## D72 — Summary and Companion follow explicit device capabilities (Jul 2026)

**Context:** Portavoz retains its macOS 14.4 deployment target and must work on
Sequoia and later, but a clean installation stored Apple on-device summaries as
the implicit default even though Foundation Models requires macOS 26 plus an
available Apple Intelligence model. Pressing Generate Summary therefore ended
in a generic dead-end alert.
Selected Ollama or MLX configurations could also fall through silently to Apple,
so the generated provider did not necessarily match the user's setting.
Companion exposed configuration without explaining that its question classifier
still depends on Foundation Models and cannot be unlocked by a BYOK answer
provider on Sequoia.

**Decision:** the app owns one `FoundationModelsCapability` adapter and samples
it for initial preference selection, provider composition, Settings guidance,
recording controls, and Companion refresh. Only a truly absent summary
preference is initialized: Apple is selected when Foundation Models is usable;
otherwise the hardware recommendation may select an installed non-OCR Ollama
chat model or the explicit-download MLX path. Existing preferences are never
silently migrated.

Every summary workflow honors the selected engine exactly. Missing Ollama model,
missing MLX download, pre-macOS-26 Apple selection, and unavailable Apple model
return typed setup states rather than changing provider. Meeting Detail maps
those states to an actionable alert that opens the native Settings scene at the
Intelligence pane. Settings explains the selected engine's unavailable state and
makes its recommendation action prominent. Companion controls are offered only
when the Apple classifier can run; the Voice pane states the macOS 26 and Apple
Intelligence requirement and explains that BYOK currently replaces only the
answer provider, not question detection. A deterministic Sequoia launch fixture
characterizes the complete setup recovery path without depending on the test
host OS.

**Rationale:** platform availability is a product capability, not an incidental
runtime error or permission to substitute a different provider. One capability
adapter keeps Sequoia and macOS 26 behavior consistent, exact provider selection
makes provenance and user intent trustworthy, and setup failures become a clear
next action instead of a dead end. The design preserves all three local summary
engines while honestly limiting only the Foundation-Models-dependent Companion.

## D73 — Speech-model readiness follows the workflow role (Jul 2026)

**Context:** a real Refine request failed after Whisper had downloaded but
before any transcript generation attempt was persisted. The meeting retained
two healthy audio channels and zero segments. Replaying copies of the same
audio and installed Whisper/pyannote models through the CLI succeeded. The app
adapter nevertheless called the broad live-engine loader during Refine
preparation, making unrelated Parakeet plus pyannote readiness a prerequisite
for the Whisper quality pass. The durable first-pass worker similarly loaded
pyannote before it could publish a Parakeet transcript, so optional attribution
could block recording recovery.

**Decision:** `AppServices` owns independently serialized Parakeet and pyannote
load tasks in addition to the existing Whisper preparation task. Concurrent
callers join the exact capability task. Broad `loadEnginesIfNeeded()` remains
only as explicit composition for workflows that intentionally require both.

Refine preparation requires only its selected verified Whisper runtime. It
requests pyannote only after required channel transcription succeeds, and the
existing ApplicationKit contract degrades that stage to honest unattributed
segments. Refine never loads Parakeet. External-audio Import requests pyannote
directly; durable first-pass recovery and Dictation request Parakeet directly;
voice enrollment requests pyannote directly. Recording background preparation,
onboarding's explicit model setup, and the recording benchmark may still
request both. Idle release waits for both independent load tasks and preserves
the existing hot-window policy.

**Rationale:** a model is a capability, not an all-or-nothing application
phase. Role-specific readiness prevents unrelated downloads, compilation, or
optional failures from blocking valid work, while per-capability task sharing
still prevents duplicate model loads. The change preserves Refine review,
language, attribution degradation, Import, Dictation, recording recovery, and
memory-release behavior without introducing a second scheduler or model owner.

## D74 — App and disk image carry independent notarization evidence (Jul 2026)

**Context:** the published v0.6.0 Homebrew cask and direct download reference
the same signed DMG. Reproducing the cask in an isolated app directory proved
that the outer DMG was notarized, stapled, and Gatekeeper-accepted, while the
`Portavoz.app` copied out by Homebrew had no stapled ticket. Apple had issued a
nested-app ticket — stapling a scratch copy succeeded — but the release script
never attached it. Opening the stapled DMG could therefore succeed while a
package-manager extraction depended on Gatekeeper reaching Apple's ticket
service. The original field report did not preserve the exact Homebrew error,
so that network-dependent boundary is the proven defect rather than a claim
about one specific alert string.

**Decision:** a distributable build has two ordered trust boundaries. First,
`make-dmg.sh` archives the Developer-ID-signed app, submits it to notarytool,
staples and validates `dist/Portavoz.app`, and strictly verifies its nested code
signatures. Only then may it copy the app into a new DMG. Second, it signs,
submits, and staples that final DMG.

`verify-distribution.sh` is a mandatory post-notarization gate. It verifies the
DMG signature, ticket, and Gatekeeper assessment; mounts it read-only; copies
the app to a scratch directory to mirror Homebrew Cask; and independently
requires deep/strict codesign, a stapled app ticket, and Gatekeeper acceptance.
The packaging architecture test locks that order. CI additionally runs the full
package suite on GitHub's `macos-15` runner, the oldest supported release lane,
while the normal latest-macOS lane remains.

**Rationale:** package managers erase the outer container as a runtime trust
boundary. Trust evidence must travel with the artifact that Gatekeeper will
actually assess, and release verification must reproduce that extraction
instead of checking only the convenient direct-download path. Dual notarization
costs one additional Apple submission per release but makes Homebrew and DMG
behavior deterministic, offline-friendlier, and independently auditable.

## D75 — Privacy receipts record validated attempts before transport (Jul 2026)

**Context:** D67–D69 centralized every current meeting-content HTTP path behind
one metadata policy, while D62–D66 preserved content-free generation
provenance. Neither fact alone could answer a user's practical question:
whether a particular meeting stayed on the Mac. Generation provenance does not
prove that no network transfer occurred, and an upgraded database has no
historical events from before tracking existed. Recording only successful HTTP
responses would also be false assurance because a failed request may already
have transmitted its body.

**Decision:** schema v7 adds immutable `dataEgressEvent` rows and a singleton
`privacyReceiptCoverage` boundary. An event stores only its ID, source meeting,
operation, conservative destination scope and host, data classification,
consent source, provider/model identity, and attempted time. It never stores a
full URL, path, query, request body, transcript, prompt, notes, summary, action
item, response, fingerprint, or generation configuration. Storage rejects a
missing/unknown meeting, blank destination/provider, host/provider mismatch,
or a claimed local/remote scope that contradicts Core's conservative host
classification.

`URLSessionDataEgressGateway` validates the complete operation-specific policy,
persists the event, and only then hands bytes to URLSession. Receipt persistence
failure fails closed. Transport failure keeps the attempt because bytes may
have left the process. The adapter rejects every HTTP redirect so a canonical
validated endpoint cannot forward meeting content to an unclassified host.
Invalid metadata creates neither a receipt nor a transport attempt.

Meeting Detail independently observes a purpose-built `PrivacyReceipt` that
combines generation provenance with local/remote egress events. A meeting
created after tracking began may state that all tracked processing stayed on
this Mac when no remote event exists. An older meeting may only state that no
remote transfer has been recorded since the persisted coverage date. Any
remote attempt is shown conservatively as content that may have left the Mac,
with purpose, host, and time. Saved CLI summary/export/issue operations use the
same store-backed recorder; transient no-save CLI work cannot claim a durable
per-meeting receipt.

**Rationale:** a privacy claim is useful only when its evidence boundary is
explicit. Recording before transport is conservative and auditable;
fail-closed persistence prevents invisible egress; redirect denial preserves
the destination policy after validation; and a migration timestamp avoids
rewriting unknown history as proof. Purpose-built, content-free projection
keeps diagnostics useful without creating a second sensitive-data store.

## D76 — Support evidence is local and redact-by-construction (Jul 2026)

**Context:** D75 made per-meeting network evidence trustworthy, but support for
a stalled recording still depended on screenshots or raw developer logs. Raw
database exports, localized error strings, generation config/metrics, and
OSLog messages can contain meeting text, prompts, endpoints, paths, or secrets.
Durable jobs were observable by the worker but not independently actionable in
Meeting Detail. Adding diagnostics by serializing existing records directly
would create a second sensitive-data product and undermine the privacy receipt.

**Decision:** ApplicationKit owns one `ExportSupportDiagnostics` use case over
a single atomic StorageKit support snapshot. The versioned JSON may contain
sanitized app/build/OS identity, model readiness, pseudonymous meeting
references, lifecycle and transcript revision, stable error codes, durable job
state, content-free generation provenance, and D75 privacy coverage/events.
Meeting UUIDs and stored fingerprints are one-way rehashed for the report.
Titles, transcript/summary/action/card text, prompts, raw error messages,
secrets, configuration and metrics JSON, full URLs, local paths, stable
database identities, and reusable fingerprints are excluded. The app exposes
only an explicit native save action and performs no upload; the privacy receipt
remains the sole user-facing network-egress claim.

Meeting Detail observes `processingJob` as a fifth independent section. Active
and failed jobs and `needsAttention` shells receive exact local explanations
and one bounded recovery action. Manual retry resets only failed jobs, preserves
job identity, idempotency key, kind, input fingerprint, and source revision,
and returns lifecycle to processing before the normal owner-leased worker
revalidates the fence. It does not invent a replacement operation or bypass
retry validation. `OSSignposter` points-of-interest intervals may record only
job kind, attempt, and terminal outcome; no meeting/job ID, path, provider
secret, endpoint, or content is allowed.

**Rationale:** a small allowlisted report is easier to audit and regression-test
than a blacklist over raw records. One read snapshot makes support evidence
internally consistent without N+1 reads, pseudonyms allow correlations inside
one report without exposing durable identity, and preserving job evidence keeps
manual recovery inside the existing lease/revision architecture. Independent
observations make stalled work visible without reloading healthy transcript,
summary, Companion, or privacy sections. Content-free signposts improve local
performance diagnosis without turning unified logging into transcript storage.

## D77 — Recording failures are coded before presentation (Jul 2026)

**Context:** Start and Stop already preserved subtle audio-first outcomes, but
their ApplicationKit results still transported dependency-localized strings.
That coupled workflow contracts to platform wording, made EN/ES recovery
inconsistent, and risked raw paths or provider details leaking into presentation
or diagnostics. Replacing every error in one migration would be broad and could
erase the durable distinctions that protect captured audio.

**Decision:** Core owns five product-level `FailureCategory` values —
`critical`, `recoverable`, `degradable`, `external`, and `destructive` — plus a
minimal `CodedFailure` contract. ApplicationKit's adopted recording Start and
Stop verticals map dependency failures to workflow-specific enums with stable
codes and categories. They transport no dependency `localizedDescription`, raw
path, endpoint, or provider prose. Their result enums retain the exact existing
reservation, reconciliation, preserved-audio, fallback-commit, no-audio, and
cleanup outcomes rather than collapsing them into a generic error.

The macOS app is the only owner of localized failure copy and explicit recovery
routes. Recoverable failures offer retry or the Library; uncertain critical or
destructive state routes to the existing local support-diagnostics surface and
asks the user to keep the app open when evidence may still be recoverable. The
failed recording view exposes the stable code as a selectable support reference.
Support JSON may include allowlisted stable codes/categories but never raw
messages. New workflows adopt this taxonomy only as bounded vertical slices
with characterization tests.

**Rationale:** stable machine-readable identity makes failures testable,
localizable, and supportable without widening the privacy surface. Keeping
workflow enums preserves business meaning that a global `AppError` would erase;
keeping presentation in the app prevents capability and persistence layers from
depending on UI language. Incremental adoption avoids a risky error-system
rewrite while establishing a ratchet against raw error transport.

## D78 — Production App Sandbox waits for a feature-parity migration (Jul 2026)

**Context:** Portavoz ships outside the Mac App Store with Developer ID,
Hardened Runtime, notarization, and narrowly declared microphone/calendar
entitlements, but without `com.apple.security.app-sandbox`. D33 required
measured capability evidence before either enabling App Sandbox or retaining an
accurately documented non-sandboxed threat model. A static entitlement change
would be especially risky because the app and CLI intentionally share the
database, model cache, recording-root marker, and voice data under
`~/Library/Application Support/Portavoz`; custom recording folders persist as
plain paths; Sparkle uses the non-sandboxed integration; and local automation
includes cross-app dictation plus `/usr/bin/shortcuts`.

**Decision:** production remains non-sandboxed for now. The decision is based
on the repeatable signed probe in `scripts/run-sandbox-capability-spike.sh`, not
on assumption. On macOS 26.5.2, the sandboxed variant proves its profile is
active by writing inside its container while both direct access to a dedicated
legacy Application Support fixture and the same access through a spawned
`/bin/cat` fail. The otherwise identical non-sandboxed control can access that
fixture. The sandboxed probe successfully starts/stops an AVAudioEngine input
tap, queries the Core Audio process catalog, registers a Carbon global hotkey,
round-trips a unique Keychain item, and reaches a loopback HTTP fixture. A
spawned system executable can launch, but inherits the parent's sandbox.

The result does **not** claim more than it measures. Both variants create the
private process tap and aggregate, create its IOProc, and start/stop the graph;
this proves structural graph setup compatibility, not a complete real meeting
capture under LaunchServices/TCC. The harmless nonexistent-Shortcut invocation
and non-prompting Accessibility/Calendar state checks are observational, not
feature-parity proof. User-selected panels and persistent bookmarks, an actual
configured Shortcut, cross-app paste, model reuse/download, CLI/MCP shared
storage, and a real Sparkle install remain product-level gates. The tracked
JSON evidence lives in
`docs/evidence/app-sandbox-capability-spike-20260716.json`.

Reconsider App Sandbox only through a reversible vertical migration that:

1. migrates existing app data and models into a container or signed App Group
   without splitting the app, CLI, and local MCP view of the same library;
2. replaces plain custom-folder paths with stale-aware security-scoped
   bookmarks and balanced access lifetimes;
3. configures and release-tests Sparkle's sandbox installer/XPC requirements;
4. proves real microphone/process-tap buffers through the product capture
   graph, cross-app dictation, a configured post-meeting Shortcut, Calendar,
   import/export, model preparation, and update installation in a separately
   signed product build;
5. preserves rollback, existing data visibility, and every released feature.

The capability harness remains separate from
`packaging/portavoz.entitlements`, and an architecture test requires the
production defer decision and the experimental sandbox entitlement to remain
explicit. A future adoption commit must update D78 and that test together.

**Rationale:** enabling the entitlement today could hide the existing library
and model cache from the app, split CLI/MCP behavior, invalidate persistent
recording-folder access, and ship unproven capture/update/automation paths.
Deferral protects users from those regressions without rejecting App Sandbox
permanently. Until the migration gates pass, Portavoz's accurate boundary is a
notarized Hardened Runtime app with least-privilege TCC entitlements, Keychain
secrets, checksum-pinned models, policy-gated meeting-content egress, local
receipts, and redacted diagnostics — not a sandboxed app.

## D79 — Scale changes follow measured bottlenecks (Jul 2026)

**Context:** Band 4 proposes Meeting Detail decomposition, content-addressable
caches, incremental Spotlight delivery, a possible `DatabasePool`, and possible
vector-storage changes. Applying those ideas together would create a broad
rewrite without identifying which work actually misses the published budgets.
The existing scoped observations already isolate transcript/cast, summary,
Companion, privacy, and processing database updates, but the detail still
projects derived chapter and meeting-health data in the presentation process.

**Decision:** Band 4 starts with two reproducible, disposable Release baselines.
`portavoz-cli bench-scale` measures the production schema and read paths at
1k/10k/50k/100k library segments and at 30-minute/2-hour/8-hour meetings.
`scripts/run-detail-ui-baseline.sh` launches only `/Applications/Portavoz
Dev.app` with a temp store, 5,000 synthetic segments, no audio or models, a
content-free first-content signpost, a delayed summary mutation, Time Profiler,
Hangs, and the SwiftUI template. The tracked reports are
`docs/evidence/scale-baseline-20260716.json` and
`docs/evidence/detail-ui-baseline-20260716.json`.

The measured order of work is binding until a later baseline disproves it:

1. Optimize `MeetingHealth` first. It is the dominant derived-detail cost:
   p95 24.25 ms at 1,250 segments, 347.58 ms at 5,000, and 5,385.76 ms at
   20,000. The 5,000-segment app reaches first content in 522.30 ms against the
   300 ms target and records one 515.86 ms initial hang.
2. Retain the current `DatabaseQueue` until contention is demonstrated. The
   scoped core detail read is p95 17.22 ms at 5,000 segments and 67.70 ms at
   20,000, so a concurrent pool is not justified by this baseline.
3. Do not add a chapter cache yet. Chapter extraction remains p95 0.85 ms at
   5,000 segments and 3.84 ms at 20,000. Waveform work still needs its own
   audio-backed hit/miss baseline before a cache design is selected.
4. Keep FTS5 for exact retrieval: p95 remains 44.35 ms at 100,000 segments,
   within the 50 ms budget. Broad OR question retrieval reaches 57.64 ms at
   50,000 and 121.64 ms at 100,000, so query/retrieval selectivity must be
   improved before adopting `sqlite-vec` or moving embedding columns.
5. Do not claim that broad SwiftUI invalidation is solved. Xcode 26.6's
   `xctrace` emitted `Trace file had no SwiftUI data` and zero SwiftUI update
   rows in repeated Debug and Release captures, although Time Profiler captured
   15,908 samples and the detail/transcript symbols. The 5,000-segment
   XCUITest proves scoped summary updates remain functional and retains a
   screenshot; exact view-body update causes remain an explicit measurement
   gap for a working Instruments toolchain.

Every performance change reruns the relevant matrix and preserves a before/
after report. No cache, pool, index, vector format, or model decomposition is
accepted on architectural taste alone.

**Rationale:** measurement keeps Band 4 incremental and reversible. The first
baseline identifies a specific algorithmic hotspot and a specific broad-query
miss while showing that several proposed infrastructure changes would add
complexity without evidence. Explicitly recording the Instruments limitation
is more trustworthy than converting an empty lane into a success claim.

## D80 — Bound interruption scans with prefix evidence (Jul 2026)

**Context:** D79 identified `MeetingHealth` as the dominant 5k/20k Meeting
Detail cost. Its interruption heuristic inspected every newer segment against
all prior segments in reverse. Ordinary non-overlapping transcripts therefore
paid quadratic work even though almost all prior speech had already ended. A
simple `break` on the nearest ended segment would be faster but wrong: an older
long turn may still overlap behind that newer short segment.

**Decision:** compute the maximum end time of every sorted transcript prefix.
For each new segment, reverse inspection may stop only when the maximum end of
the entire remaining prefix is less than or equal to the new start time. Ended
neighbors are still skipped individually, and the existing first qualifying
different-speaker overlap of at least 0.5 seconds remains the sole interruption
criterion. An adversarial test must retain the older-long-overlap case. No
schema, cache, feature model, UI, or persisted output changes.

The comparable tracked reports are
`docs/evidence/scale-baseline-20260716-after-health.json` and
`docs/evidence/detail-ui-baseline-20260716-after-health.json`. Release p95
changes from 24.25/347.58/5,385.76 ms to 2.55/9.94/41.39 ms at
1,250/5,000/20,000 segments, or 9.5×/35.0×/130.1× faster. The same native 5k
fixture reaches first content in 91.87 ms instead of 522.30 ms and reports zero
potential hangs instead of one 515.86 ms hang. The Xcode 26.6 SwiftUI update
lane remains explicitly unavailable; the first-content signpost, Hangs, and
Time Profiler lanes remain valid.

**Rationale:** a small data-structure index removes the measured bottleneck
without changing product semantics or adding architectural layers. Fully
overlapping pathological transcripts can still require quadratic inspection,
but ordinary sequential meetings become near-linear and now pass the 300 ms
first-content target. Because that target passes, Meeting Detail decomposition,
a `DatabasePool`, and chapter caching are not justified next; broad OR
retrieval selectivity remains the next measured Band 4 miss.

## D81 — Bound broad retrieval before vector storage (Jul 2026)

**Context:** after D80 removed Meeting Health from the critical path, the only
measured Band 4 budget miss was lexical question retrieval. The comparable
Release report recorded p95 111.19 ms at 100,000 segments. StorageKit built one
large FTS5 OR expression and invoked `bm25()` across the matching union before
`LIMIT`; a rank-only experiment retained ordering but varied between 99 ms and
124 ms p95 and therefore did not provide a trustworthy budget margin. Moving
embeddings to sqlite-vec would not fix this lexical candidate stage and would
add a schema, extension, packaging, and migration burden without evidence.

**Decision:** keep the FTS5 schema and make retrieval ownership explicit.
StorageKit's exact top-k query orders by FTS5's hidden `rank` column, which uses
the same default BM25 score; a characterization compares its selected IDs with
an explicit `bm25()` query. Search hits now carry both a bounded highlighted
snippet for UI surfaces and the complete segment text for downstream retrieval.
Hostile quoted input, tombstone exclusion, and exact AND behavior remain
unchanged.

ApplicationKit's `LocalAskMeetingRetrieval` owns lexical RAG selection; D100 moved the unchanged policy inward from the former IntegrationsKit `AskPipeline`. It extracts words
of at least four characters exactly as before, normalizes and deduplicates
them, retrieves a bounded top-k list per term, and fuses those lists with
reciprocal-rank scoring (`k = 60`). A segment supported by multiple question
terms therefore climbs instead of requiring FTS5 to score the entire OR union.
The normal selective path is limited to eight unique terms; a longer pasted
question retains the released complete broad-OR path rather than multiplying
unbounded scans. Query expansion, semantic retrieval, final lexical/semantic
fusion, citations, tombstones, and multilingual terms remain intact. Answers
receive the complete chosen segment instead of a twelve-token UI snippet.

The Release harness calls this exact production lexical policy without loading
embedding assets. In the tracked after report, p95 at 100,000 segments changes
from 38.38 ms to 30.99 ms for exact FTS and from 111.19 ms to 66.89 ms for
lexical Ask; the latter is 39.8% faster and below the 100 ms target. At
1k/10k/50k segments lexical p95 is 1.89/5.80/25.12 ms. No schema, index,
database concurrency model, persisted vector, model, or UI hierarchy changes.

**Rationale:** bounded per-term top-k selection directly removes the measured
lexical amplification and improves relevance for multi-term evidence while an
explicit fallback protects unusual long questions. Keeping that policy at the
application edge preserves StorageKit as a safe exact-search capability and
avoids treating a RAG ranking rule as persistence. Since lexical retrieval now
passes, Band 4D must measure brute-force semantic cosine latency, CPU, and
memory at the same scale before sqlite-vec or a segment-layout migration can be
selected.

## D82 — Measure semantic cost before changing storage (Jul 2026)

**Context:** D81 brought exact and lexical retrieval inside their 100k-segment
budgets, but the production semantic path remained unmeasured. It reads every
live embedding BLOB, decodes each 512-dimensional Float32 vector, computes a
dot product, materializes every scored hit, and sorts the complete corpus before
returning twelve passages. A synthetic two-dimensional unit fixture could not
justify either retaining that design or adding sqlite-vec, a new extension,
schema migration, packaging work, and persisted-vector compatibility risk.

**Decision:** measure the exact `MeetingStore.searchSemantic` path before any
storage change. `portavoz-cli bench-semantic` creates a production-schema
throwaway corpus with deterministic normalized vectors whose dimension comes
from `NLContextualEmbedding(script: .latin)` (512 on the reference host). It
validates that the exact fixture vector ranks first, then records 20 Release
runs of wall time, process CPU time, baseline/peak/ending physical footprint,
incremental peak, database size, and raw vector bytes. CPU ticks from
`proc_pid_rusage` are converted with the Mach timebase. The wrapper launches
one process per 1k/10k/50k/100k checkpoint so allocator and SQLite state cannot
leak between sizes.

The tracked baseline records semantic wall/CPU p95 of 2.62/2.66 ms at 1k,
29.72/30.26 ms at 10k, 159.07/161.98 ms at 50k, and 325.41/328.43 ms at 100k.
The 100k path therefore misses the 100 ms interactive target by more than 3x.
Its incremental physical-footprint p95 is only 8.50 MiB and absolute peak p95
50.05 MiB, so memory is not the blocking resource. Persisted 512-dimensional
vectors contribute 195.31 MiB of raw payload while the complete SQLite
directory is 416.54 MiB.

**Rationale:** the evidence selects CPU/latency work, not a cache, database
pool, view decomposition, or memory workaround. Before accepting sqlite-vec's
distribution and migration cost, Band 4E removes the current adapter's obvious
algorithmic amplification: stream rows instead of `fetchAll`, score BLOB bytes
without allocating a Float array per segment, use Accelerate for the dot
product, and retain only the bounded top-k instead of sorting every hit. The
same isolated matrix decides the result. If 100k semantic p95 still exceeds
100 ms, the next slice may select sqlite-vec and the additive
`segmentEmbedding` layout with measured before/after and compatibility tests.

## D83 — Keep exact vectors after the adapter passes (Jul 2026)

**Context:** D82 measured the production 512-dimensional semantic path at
100,000 segments: wall/CPU p95 was 325.41/328.43 ms against a 100 ms target,
while incremental footprint p95 was only 8.50 MiB. The miss justified removing
adapter amplification before accepting sqlite-vec, an additive embedding
table, extension packaging, migration compatibility, and approximate-index
maintenance. The released path fetched all rows, copied each BLOB into a new
Float array, materialized every full `SearchHit`, and sorted every score.

**Decision:** retain schema-v7 Float32 BLOBs and exact cosine ranking. The
StorageKit adapter streams a cursor containing only SQLite-owned embedding
bytes and rowids, scores each production-width vector directly with
Accelerate, keeps a deterministic bounded top-k, and fetches complete passage
content only for those winners. Non-positive limits and empty queries return
no results; wrong-width or non-finite vectors are excluded; ties retain
ascending rowid traversal order. Deleted meetings remain excluded through one
tombstone subquery rather than an indexed meeting lookup for every segment.

The comparable 20-run Release matrix records wall/CPU p95 of 0.51/0.55 ms at
1k, 9.86/9.95 ms at 10k, 45.18/45.86 ms at 50k, and 90.22/91.26 ms at 100k.
The 100k path is 72.3%/72.2% below baseline and passes both 100 ms gates.
Incremental footprint p95 remains 8.42 MiB while absolute peak p95 falls from
50.05 to 15.66 MiB. Production-width scalar-oracle, malformed-vector,
tombstone, full-text, top-k, tie, and limit characterizations preserve exact
behavior.

**Rationale:** the existing local-first format now meets the published scale
budget without a new dependency, C extension, schema migration, approximate
index, database pool, or cache invalidation protocol. sqlite-vec and an
additive `segmentEmbedding` table are therefore rejected until a future
measured corpus, vector width, or latency budget proves this exact adapter no
longer sufficient. Band 4 proceeds to the independent waveform evidence gate;
semantic storage is no longer the current bottleneck.

## D84 — Vectorize waveform envelopes before caching (Jul 2026)

**Context:** Band 4's target architecture proposed a content-addressable
waveform cache without first measuring the released generator. A Release
`bench-waveform` run copied a real 55.9-minute, dual-channel 48 kHz PCM16 CAF
capture into a throwaway directory and generated 600 buckets. The scalar
per-frame loop took 761.75 ms wall / 767.43 ms CPU on its first generation;
20 same-process runs recorded wall/CPU p95 of 747.53/754.79 ms. Incremental
physical-footprint p95 was only 0.36 MiB, so the miss was CPU work rather than
memory pressure or retained state.

**Decision:** keep waveform derivation stateless and preserve its exact bucket
contract. `Waveform.generate` divides the audio timeline into the same
range-aligned spans, computes each channel's maximum magnitude with
Accelerate `vDSP_maxmgv`, and lets the final bucket consume the remainder.
The CLI harness records the first generation separately from 20 repeated
generations, publishes format/size/duration but no source path or content, and
replaces its scratch input with a newly written valid audio file to
characterize invalidation.

The comparable after report preserves the exact 600-bucket fingerprint. First
generation is 109.25 ms wall / 94.81 ms CPU, 7.0×/8.1× faster. Repeat wall/CPU
p95 is 70.11/71.33 ms, 10.7×/10.6× faster and below the 100 ms derived-audio
budget. Incremental physical-footprint p95 remains 0.33 MiB and absolute peak
p95 is 5.03 MiB. Replacing the scratch audio changes the result fingerprint,
so regeneration already has exact invalidation semantics.

**Rationale:** a durable or content-addressable cache, sidecar file, audio-
asset read model, schema change, and invalidation lifecycle are rejected at
the measured 55.9-minute scale. The vectorized stateless adapter is simpler,
has no stale-artifact failure mode, and meets both first and repeat budgets.
Reconsider caching only if a future longer real-audio matrix misses an explicit
budget after this adapter, and require comparable latency, memory, storage,
replacement, migration, and deletion evidence before selecting it. Band 4
proceeds to Spotlight delivery/backlog measurement rather than cache design.

## D85 — Reconcile Spotlight through a protected measured snapshot (Jul 2026)

**Context:** the released Spotlight adapter rebuilt the default prototype
index from a window-owned `libraryVersion` task. Preparing one rebuild used a
meeting-list read followed by up to two reads per meeting, loaded complete
details, selected only the General summary, swallowed delivery errors, and had
no durable comparison state. A disposable Release matrix measured projection
wall/CPU p95 at 216.84/224.22 ms for 1,000 meetings,
2,166.39/2,231.34 ms for 10,000, and 22,085.35/22,720.40 ms for 100,000.
The existing v6 `outboxEvent` foundation could make each mutation incremental,
but that would add producer coverage, delivery-state lifecycle, compaction,
and support semantics before proving that a bounded full reconciliation was
insufficient.

**Decision:** keep Spotlight local and reconcile it from one consistent
StorageKit snapshot. One SQL projection selects every live meeting, its newest
live summary across recipes, and its first 40 live segments in deterministic
order, with the released 4,000-character description cap. A process-scoped
actor coalesces requests for 250 ms, computes a compact SHA-256 client state,
skips unchanged publication, and retries failures after one and five seconds.
It replaces the domain through a named `app.portavoz.meetings.v2` index with
complete file protection and 500-item Core Spotlight batches. Launch always
requests reconciliation, so a crash or missed mutation heals without a
window. The released default-index domain is removed only after the protected
index is ready. Search-hit identity and app-delegate navigation remain
unchanged. Synthetic delivery evidence uses a unique named index and domain,
contains no real meeting content, and is deleted after the run.

The comparable snapshot projection preserves exact result fingerprints at
1,000, 10,000, and 100,000 meetings. Wall/CPU p95 is 4.05/4.26 ms,
38.06/39.96 ms, and 425.64/423.58 ms respectively; the 100,000-meeting path is
51.9x faster and passes the 500 ms gate. At that extreme checkpoint absolute
and incremental physical-footprint p95 are 141.14 MiB and 76.03 MiB. A
1,000-item protected named-index delivery completes in 21.19 ms and its
synthetic cleanup succeeds. `outboxEvent` remains unconsumed by Spotlight.

**Rationale:** the measured snapshot is deterministic, self-healing, much
simpler than a second durable delivery state machine, and already meets the
published scale budget while preserving exact searchable content. Reconsider a
Spotlight outbox only if field evidence shows stale results after the bounded
retries or requires user-visible per-mutation delivery status. Reconsider the
snapshot memory shape if a future comparable 100,000-meeting run exceeds
160 MiB absolute or 96 MiB incremental physical footprint. Any replacement
must retain protected local storage, crash reconciliation, deletion parity,
content equivalence, and isolated before/after evidence.

## D86 — Remember people only through explicit, ambiguity-preserving links (Jul 2026)

**Context:** Portavoz already had three different kinds of speaker evidence:
meeting-local names proposed from transcript/calendar context, encrypted
cross-meeting voice suggestions, and the structural `Me` attribution. None is
a durable human identity. Treating an equal name, calendar attendee, diarizer
label, or biometric match as authority would silently merge different people;
the same display name can legitimately belong to several humans, and Refine
creates fresh diarization speaker IDs whose labels are not stable identity.

**Decision:** add an additive schema-v8 canonical-person boundary. Core owns
`PersonID`, `Person`, `PersonAlias`, and the normalized-alias contract. Storage
adds `person`, `personAlias`, and nullable indexed `speaker.personID` with
`ON DELETE SET NULL`. Alias normalization trims and collapses whitespace, then
folds case, diacritics, and width under the POSIX locale. The same normalized
alias may belong to several people; only one copy per person is allowed.

Candidate lookup and mutation remain separate ApplicationKit use cases.
Meeting Detail offers an explicit Remember action only after the user has
accepted a non-user speaker name. No match can create a distinct person only
after that action; one or more exact matches open a chooser that also permits
creating a separate person. A selected create/link writes the person, alias,
and observed-speaker link atomically and canonicalizes that speaker's display
name. Transcript, calendar, and voice suggestions retain their source label
but can never call the link mutation automatically. `isMe` is excluded from
this first other-participant vertical.

Canonical person IDs are private device state: `.portavoz` export/import strips
them while preserving meeting-local names. Encrypted `VoiceGallery` files stay
outside SQLite and do not gain a person link or sync behavior in this slice.
Refine replaces observed speakers with new IDs and deliberately does not carry
the old `personID` by label, alias, or voice; the user confirms continuity
again. Deleting a meeting therefore does not delete the person, while deleting
a future person record will null its speaker links through the foreign key.

**Rationale:** this is the smallest useful human-memory vertical that improves
cross-meeting continuity without turning probabilistic evidence into identity.
It keeps ambiguity representable, makes every durable merge reversible by
future person-management UI, avoids biometric coupling, preserves bundle
privacy, and leaves typed claim evidence as an independent next slice rather
than hiding it in a generic identity graph.

## D87 — Admit generated evidence as typed, revision-fenced claims (Jul 2026)

**Context:** immutable summaries knew which provider and material fingerprint
produced them, but not which transcript statements supported a visible claim.
Adding generic artifact/edge/value tables would make every generated sentence
look equally trustworthy before deletion, Refine, import, model-output, and UI
navigation semantics were proven. UUIDs in prompts are also expensive and easy
for small models to alter.

**Decision:** implement one narrow overview-claim vertical. Core owns
`SummaryClaimID`, `SummaryClaimKind.overview`, the ordered evidence segment
IDs, source transcript revision, unavailable-link count, and current/stale/
unavailable resolution. Summary drafts remain backward compatible when claims
are absent. Providers receive a separate transcript representation tagged
`E1`, `E2`, and so on. Foundation Models guided generation and the shared
Ollama/BYOK/MLX JSON contract may return at most four exact overview tags;
unknown, altered, duplicate, or excess tags are discarded. No valid tag or no
overview means no claim, never a fabricated citation. Rolling note summaries
do not admit evidence because their compressed windows do not retain one
stable tag map. Tag-shaped literals inside transcript text, speaker names, or
user notes are escaped before prompting so content cannot masquerade as the
provider-owned source namespace.

Schema v9 adds `summaryClaim` and `summaryClaimSegment`, not a generic EAV
store. A summary transaction accepts only one overview claim with nonempty,
unique, live segments belonging to that meeting, rejects a mismatched incoming
revision, and stamps the meeting's current revision. Link order is durable;
the segment foreign key uses `ON DELETE SET NULL` so physical deletion remains
distinguishable from a claim that never had evidence. A revision mismatch is
stale. At the current revision, any null, missing, or tombstoned segment makes
the entire claim unavailable; partial navigation is prohibited.

Translation pivots preserve evidence with fresh claim IDs. `.portavoz` format
v1 carries claims additively, remaps claim and segment IDs on import, clears the
foreign source revision, and lets the atomic imported summary stamp its local
revision. Canonical person IDs remain stripped independently. Meeting Detail
shows localized source timestamps only for a complete current claim; selecting
one focuses the exact transcript row and seeks retained audio without starting
playback. Stale and
unavailable states explain why navigation is disabled.

**Rationale:** this is the smallest honest user-visible provenance slice. It
makes generated output inspectable without pretending model-selected evidence
is ground truth, fails closed across transcript evolution and deletion, stays
portable, and proves the domain/storage/UI pattern before decisions, action
items, Companion cards, or correction feedback adopt it. Generic evidence
tables and broader artifact claims remain rejected until those typed semantics
are implemented and characterized.

## D88 — Keep claim feedback explicit, current, and outside generated output (Jul 2026)

**Context:** D87 made one generated overview claim inspectable, but users still
needed a safe way to say that it was wrong or unsupported. Rewriting the
provider-owned Markdown would destroy the distinction between model output and
human correction. An append-only feedback history would quietly accumulate
sensitive free-form text, while sending corrections back into prompts,
telemetry, or support diagnostics would violate the local review boundary.

**Decision:** one immutable overview claim may have at most one mutable current
`SummaryClaimFeedback`. Its kind is either `correction`, with trimmed nonblank
text bounded to 2,000 Unicode scalars, or `unsupported`, with no text. The UI
offers visible Add/Edit correction, Mark unsupported, and Clear actions. None
changes generated Markdown, evidence, summaries, or generation history; no
feedback enters provider prompts, telemetry, privacy receipts, or support
diagnostics, and regeneration/translation does not inherit it.

Schema v10 adds `summaryClaimFeedback`, keyed by claim ID with timestamps and a
tombstone. Writes are transactionally fenced to the overview claim of the
newest live summary across recipes, so a completion racing a newer generation
fails instead of annotating hidden history. Replacing feedback updates that one
row. Clearing physically removes `correctionText` before setting `deletedAt`,
retaining only nonsensitive metadata for a future sync protocol. Normal
generated-summary persistence rejects provider-supplied feedback; the validated
bundle-import path is the sole insertion exception.

`.portavoz` format v1 carries the current feedback additively inside its claim.
Import remaps claim and segment identities while preserving the typed
assessment. Older readers ignore it and old bundles remain valid. Canonical
people remain device-local under D86; feedback portability does not weaken that
separate identity boundary.

**Rationale:** this is the smallest honest correction loop. It preserves the
original generated artifact, makes human judgment visible and reversible,
prevents private text from becoming hidden history, keeps remote/model behavior
unchanged, and proves export semantics before evidence expands to decisions,
action items, or Companion cards.

## D89 — Address decision evidence by rendered position, not heading text (Jul 2026)

**Context:** D87 proved provenance for one overview, while decisions remained
untyped Markdown bullets. A generic evidence graph would erase the business
meaning of a decision and weaken the schema-v9 one-overview invariant. Matching
translated headings such as `Decisions` or `Decisiones` would also be brittle,
and custom structures do not yet declare semantic section kinds.

**Decision:** add `SummaryDecisionEvidence` as a separate typed aggregate. It
addresses one rendered nonempty `##` section ordinal plus one bullet ordinal,
owns a fresh ID, source transcript revision, ordered segment IDs, and an
unavailable-link count. General and Planning classify recipe section index 1;
1:1 classifies index 2. Standup, Interview, and custom recipes classify none.
Provider output is admitted only when its section count exactly matches the
recipe and its optional `bulletEvidence` array exactly matches each section's
bullet count. Only exact request-local E-tags resolve; unknown, altered,
duplicate, empty, or shape-mismatched references fail closed.

Schema v11 adds `summaryDecisionEvidence` and
`summaryDecisionEvidenceSegment`. Summary persistence validates each coordinate
against the canonical Markdown outline, requires unique IDs and positions,
reuses the live same-meeting evidence and revision fence from D87, and commits
the complete immutable aggregate transactionally. Nullable segment links retain
unavailable provenance after physical deletion. Translation preserves valid
rendered coordinates with fresh decision IDs. Format-v1 `.portavoz` bundles
additively carry and remap both decision and segment identities, clear the
foreign revision, and let local Storage stamp it.

Meeting Detail renders source timestamps directly beneath the addressed
decision bullet. A current source focuses the exact transcript row and seeks
retained audio without autoplay; stale or unavailable states expose no partial
jump. Decision evidence does not gain correction feedback in this slice and
does not enter support diagnostics, telemetry, or privacy receipts.

**Rationale:** rendered coordinates bind provenance to the exact text users see
without duplicating generated content, depending on one language, or pretending
every summary section has decision semantics. Dedicated tables keep the domain
explicit and let action items or Companion cards earn their own typed evidence
contracts instead of inheriting a generic EAV model.

## D90 — Key action-item evidence to task identity, not Markdown (Jul 2026)

**Context:** D89 made decisions inspectable by rendered bullet position, but
action items already live outside Markdown as durable rows whose completion
state changes independently. Reusing decision coordinates would detach a
commitment from its checkbox identity. Adding evidence fields directly to
`ActionItem` would also mix mutable task state with immutable generated
provenance and weaken backward bundle decoding.

**Decision:** add `SummaryActionItemEvidence` as a separate typed aggregate
keyed by exactly one `ActionItem.id`. It owns a fresh evidence ID, source
transcript revision, ordered segment IDs, and unavailable-link count. Provider
action-item shapes gain an optional additive evidence-tag array. Shared,
OpenAI-compatible, and Foundation Models instructions require only exact
request-local E-tags; unknown, altered, duplicate, or empty references produce
no evidence. Older provider responses remain valid.

Schema v12 adds `summaryActionItemEvidence` and
`summaryActionItemEvidenceSegment`. Summary persistence requires unique
evidence and target IDs, a target action item in the same draft, and the D87
live same-meeting segment/revision contract. The evidence commits with the
immutable summary and action rows. Toggling `isDone` changes only the task;
the evidence identity remains stable. Nullable links retain unavailable
provenance after physical segment deletion.

Translation creates fresh action-item and evidence IDs, then carries evidence
by corresponding task position. Format-v1 `.portavoz` import remaps action,
evidence, and segment IDs, clears the foreign revision, and lets local Storage
stamp it. Meeting Detail renders sources beneath the matching checkbox; a
current source focuses transcript/audio without autoplay, while stale or
unavailable evidence cannot navigate. Companion cards, support diagnostics,
telemetry, privacy receipts, and overview feedback remain outside this slice.

**Rationale:** task identity is the smallest stable business key for a
commitment. A dedicated aggregate keeps completion mutable, generated
provenance immutable, portability explicit, and future Companion evidence free
to adopt its own semantics rather than a generic evidence graph.

## D91 — Separate Companion question evidence from answer evidence (Jul 2026)

**Context:** a Companion card has two different relationships to the
transcript. One closed or coalesced participant turn triggered the card, while
a context answer may rely on earlier RAG passages. Treating both as one source
list would hide that distinction. Reusing summary/action-item evidence would
also couple a card to the wrong business identity, and using `askedAt` alone
cannot prove which coalesced rows or answer passages were involved.

**Decision:** add `CompanionCardEvidence` as a separate immutable aggregate
keyed to exactly one `CompanionCard.id`. It owns a fresh evidence ID, source
transcript revision, ordered question segment IDs, ordered answer segment IDs,
and unavailable counts for each role. Live generation carries the exact closed
row as question evidence; post-Refine generation carries every segment in the
coalesced triggering turn. The operation fingerprint includes those identities
and optional passage segment IDs.

Only a context answer's exact, in-range `[N]` RAG citations may become answer
evidence, in first-use order with duplicates removed. Knowledge answers and
directed pings have question evidence but no answer evidence. Missing segment
identity or an uncited answer never gains synthetic support. Generation-run
configuration and metrics remain content-free and do not serialize evidence.

Schema v13 adds `companionCardEvidence` and
`companionCardEvidenceSegment`. The link role is constrained to `question` or
`answer`; ordinals and live segment identities are unique within each role.
Persistence requires the evidence to target its card, requires nonempty unique
question sources, validates every source as live and owned by the same meeting,
and stamps the current transcript revision in the card transaction. Nullable
segment foreign keys use `ON DELETE SET NULL`, so physical deletion remains an
unavailable source rather than disappearing. Evidence-only writes invalidate
the Companion observation, not summary or support projections.

`CompanionCard` carries optional nested evidence only as an additive read and
format-v1 transport convenience; durable tables remain separate. Bundle import
validates the source card relationship before minting fresh card/evidence/
segment identities, clears the foreign revision, and drops malformed evidence
without losing the card. Meeting Detail keeps the existing `askedAt` playback
button for feature parity and adds separate Question source and Answer sources
controls. A current source focuses transcript/audio without autoplay; stale,
missing, deleted, or partial roles cannot navigate. Companion evidence never
enters summary tables, claim feedback, privacy receipts, or support diagnostics.

**Rationale:** the role split tells users what caused the intervention and what
actually supported its answer without overstating either. Card identity is the
stable business key, exact citations are the narrowest honest answer contract,
and dedicated tables preserve portability and fail-closed behavior without a
generic evidence graph.

## D92 — Detect portable meeting changes before choosing a sync transport (Jul 2026)

**Context:** Band 6 needs one durable answer to “what changed?” before an iOS
target or CloudKit adapter can safely send anything. The schema-v6
`outboxEvent` is a delivery envelope, not an aggregate revision: replacing its
pending row would let an acknowledgement for an older send hide a newer local
edit. Migrating an offline-only library must also never opt it into sync, and a
physical purge must not erase the only remaining evidence that another device
should delete a meeting.

**Decision:** schema v14 adds one content-free `meetingSyncState` row per dirty
meeting aggregate. `localGeneration` increases monotonically for every
portable mutation; `acknowledgedGeneration` advances only to the generation
actually sent. Acknowledging generation N therefore cannot hide N+1. The row
stores only meeting identity, both generations, change time, and deletion
state. It has no foreign key to `meeting`, so a user-confirmed physical purge
leaves a durable deletion tombstone. Pending reads are bounded and stable;
invalid limits, future acknowledgements, and unknown meeting identities fail
closed.

Storage-owned SQLite triggers update that row in the same transaction as the
meeting, speaker, segment, summary, action item, context note, Companion card,
claim feedback, or typed evidence mutation. Null-safe `OLD`/`NEW` predicates
prevent whole-row saves from queuing unchanged values. Device-local paths,
embeddings, generation-run links, canonical-person links, jobs, model
configuration/provenance, receipts, audio, secrets, and voiceprints never
participate. Evidence relations are included because their content may change
without changing the owning generated text. Migration itself backfills
nothing; including an existing library must explicitly enter the bounded
`markMeetingsForInitialSync(after:limit:)` boundary.

This slice deliberately adds no CloudKit import, CKSyncEngine state, network
request, account UI, iOS target, conflict resolver, or audio transfer. A later
IntegrationsKit adapter will encode the portable aggregate and persist its
transport state while StorageKit remains the mutation authority. The generic
schema-v6 outbox remains unused rather than being misrepresented as this
generation fence.

**Rationale:** durable detection is independently shippable and testable, has
no privacy or network side effect, survives crashes and purges, and removes the
lost-update race before transport complexity arrives. A specialized aggregate
journal is simpler and safer than forcing sync semantics into an unused generic
delivery table.

## D93 — Freeze portable aggregate replay before CloudKit transport (Jul 2026)

**Context:** a content-free dirty journal proves that a meeting changed, but it
does not define which rows may leave the device, how one exact generation is
encoded, or what happens when a remote mutation meets unsent local work. Putting
those rules directly inside `CKSyncEngineDelegate` would make the Apple callback
lifecycle the owner of domain conflict policy and would make deterministic
tests require an iCloud account.

**Decision:** StorageKit owns a versioned, text-first `MeetingSyncAggregate` and
`MeetingSyncEnvelope`. The aggregate contains the live meeting root, observed
speakers, transcript segments, every immutable summary version with action
items and typed evidence/current claim feedback, context notes, and Companion
cards with role-separated evidence. Every row carries original ordering/update
timestamps. The envelope joins that aggregate, or a deletion mutation, to one
exact local journal generation and one source-device identity. A stale caller
cannot label newer content with an older generation.

The projection clears `Meeting.audioDirectory` and `Speaker.personID`; it has
no audio asset, embedding, generation-run, canonical-person, job, receipt,
model-state, secret, or voiceprint shape. IntegrationsKit provides a stable
sorted-key, millisecond-date JSON codec, but this slice imports no CloudKit and
performs no network request.

Remote replay validates the complete aggregate before writing and executes in
one StorageKit transaction. With no unsent local generation, the remote live
snapshot replaces the portable aggregate while preserving matching local audio
paths, canonical-person links, segment embeddings/provenance, summary
provenance, and Companion provenance. Its trigger noise is acknowledged in the
same transaction, preventing an echo. A live remote update waits behind unsent
local work rather than overwriting it. A remote deletion wins that race for
privacy, soft-deletes the meeting so it remains recoverable, and records the
discarded local generation. Reusing an immutable summary identity with
different content, foreign relations, partial evidence, invalid format, or a
non-current outgoing generation fails closed before replacement.

This is the first 6B sub-slice, not functioning sync. Encrypted CKRecord
construction, large-payload asset staging, persisted CKSyncEngine state,
account/consent, retry/replay cursors, entitlement/runtime composition, status
UI, and iOS remain unimplemented.

**Rationale:** transport-independent projection and replay can be exhaustively
characterized with two in-memory stores. CloudKit can then remain a replaceable
adapter over an already fixed privacy boundary instead of becoming the place
where Portavoz decides data ownership and conflict semantics.

## D94 — Save one encrypted tombstone record per meeting (Jul 2026)

**Context:** D93 fixes the portable bytes but not their CloudKit shape. A large
meeting may exceed a conservative inline-record budget, encrypted fields cannot
contain `CKAsset`, and deleting a CKRecord would remove the comparable
tombstone that concurrent devices need for privacy-dominant conflict handling.
The record codec must also preserve downloaded CKRecord system fields so the
later sender can use CloudKit's change-tag conflict detection.

**Decision:** IntegrationsKit owns one `MeetingReplica` record per meeting in a
private custom `PortavozMeetings` zone. Its deterministic record name contains
only the meeting UUID. Payloads up to the codec's conservative 512 KiB policy
use `CKRecord.encryptedValues`; larger payloads use one `CKAsset`, which
CloudKit encrypts by default. Asset staging uses a unique owner-only local file
and, under D116, applies complete protection and backup exclusion when the
destination filesystem supports them. Bytes enter an empty private sibling,
are synchronized, and publish through one same-volume atomic rename; the final
path therefore never contains partial meeting content. The
payload SHA-256 is also an encrypted
field. Only format version, payload-storage selector, record type/identity, and
the asset field itself remain outside `encryptedValues`; no transcript,
summary, title, speaker, source-device, generation, or digest value is exposed
as a regular queryable field.

D116 refines only the local staging guarantee on filesystems that reject one of
those metadata keys: complete protection and backup exclusion remain mandatory
when supported, while owner-only durable atomic publication remains mandatory
everywhere.

The codec accepts an existing record only when its type, zone, and deterministic
identity match, so later sends can retain CloudKit system fields/change tags.
It validates format, storage, checksum, and meeting identity before decoding.
A meeting deletion remains an encrypted `.delete` envelope saved to that same
record ID; the adapter must never translate it into a CKRecord delete. Audio is
not part of either inline or asset payload.

This 6B2A slice is deliberately dormant. It creates no `CKContainer`, requests
no account, initializes no `CKSyncEngine`, adds no entitlement, performs no
network call, and exposes no sync UI. Persisted engine/system fields, exact
in-flight generations, retry/replay state, account transitions, and the thin
delegate boundary arrive separately under D95; they are not codec behavior.

**Rationale:** one record preserves CloudKit's native optimistic-concurrency
boundary without splitting a meeting into partially visible chunks. The asset
fallback scales independently of transcript length, while encrypted placement
and protected staging keep content out of indexes, logs, and ordinary local
files. Tombstone saves preserve deletion evidence for deterministic conflict
resolution; runtime and consent remain independently reviewable.

## D95 — Persist CloudKit delivery state outside meeting storage (Jul 2026)

**Context:** D94 fixes the record shape but not crash recovery. CKSyncEngine may
checkpoint fetched work before Portavoz can apply it, save callbacks can arrive
after a newer local generation exists, and account/system-field state is unsafe
to reuse after an iCloud-account switch. Putting those concerns in schema v14
would mix replaceable Apple transport metadata with the portable mutation
authority and risk storing transcript content in ordinary JSON.

**Decision:** IntegrationsKit owns a separate `CloudMeetingSyncStateStore`.
Its owner-only, capability-protected JSON snapshot contains only hashed
account scope/consent, explicit initial-seed state, Apple's opaque
`CKSyncEngine.State.Serialization`, CKRecord system fields, exact outgoing
generation/digest/file metadata, retry clocks/categories, deferred-replay
metadata, and replay cursors keyed by meeting plus source device. Exact outgoing
and deferred envelope bytes live in separately protected `0600` files and are
validated against identity, byte count, digest, and deterministic filename on
open. Snapshot mutations roll back if persistence fails; orphaned payload files
are removed on restart.

D116 applies the same destination-capability rule to this transport state;
unsupported metadata never weakens its `0600`, synchronization, integrity, or
atomic-publication requirements.

Consent is explicit and bound to a SHA-256 fingerprint of the current-user
record name. Sign-out and temporary account loss pause delivery without erasing
device-owned outgoing attempts. A real account switch clears old account-scoped
engine state, system fields, replay cursors, deferred payloads, and seed state,
then requires consent for the new account. Initial seeding is requested and
completed explicitly; this adapter never opts an upgraded library in by itself.
The coordinator's explicit request invokes StorageKit's bounded
`markMeetingsForInitialSync(after:limit:)` boundary and marks the seed complete
only after preparation, the journal, and protected attempts drain.

Each outgoing attempt is exact-generation and idempotent. A late success may
update system fields but can remove only its matching attempt; it cannot erase a
newer generation or deferred remote work. Because CKSyncEngine pending changes
are record-ID keyed, the delegate re-admits that record ID whenever a save
callback leaves a newer exact attempt behind. Retry is deterministic exponential
backoff with CloudKit retry-after support and a six-hour cap; partial record
results remain independent. Pending preparation reconciles both the journal and
protected outstanding attempts, so a crash between local acknowledgement and
transport cleanup cannot strand a payload; callback persistence failures re-add
the exact engine change. Fetched work crosses the StorageKit replay boundary
through `CloudMeetingSyncCoordinator`. If StorageKit defers a live remote
envelope behind unsent local work, its exact bytes are staged before the fetch
checkpoint can be lost. Only a saved encrypted tombstone may delete domain
content; a physical CKRecord deletion carries no authenticated payload and only
invalidates stored system fields.

`CloudMeetingSyncEngineDelegate` is a thin, explicitly injected callback
adapter: it persists state updates, maps account transitions, prepares pending
zone/record changes, builds batches, and forwards independent fetch/save
results. `CloudMeetingSyncRuntime` may construct a manually driven engine only
from an injected `CKDatabase`, restored state, and that delegate; automatic sync
is disabled at construction. Conflict and ownership rules remain in
StorageKit/coordinator. This slice creates no `CKContainer`, adds no entitlement,
performs no network work from the app, and exposes no consent/status UI or iOS
target.

**Rationale:** separating durable delivery metadata from schema-v14 business
state keeps CloudKit replaceable, makes restart/account boundaries auditable,
and lets exact encrypted meeting bytes receive stronger filesystem protection
without leaking them into logs or the metadata snapshot. A dormant delegate can
be characterized thoroughly before any user opt-in or network side effect is
composed.

## D96 — Keep sync lifecycle policy independent of CloudKit composition (Jul 2026)

**Context:** D95 makes transport delivery restart-safe, but the app still needs
one truthful definition of enabled, pending, synchronized, paused, retrying,
and failed. If SwiftUI or `CKContainer` owned that policy, a clean local-only
launch could touch iCloud before consent, account changes could silently retain
the wrong opt-in, and pause/remove/retry actions could lose their data contract.

**Decision:** IntegrationsKit owns a platform-neutral
`CloudMeetingSyncLifecycle` above D95. Account discovery and manual engine
driving enter through injected protocols; constructing or resuming the
lifecycle performs zero platform work unless this device already has an
account-scoped consent. Explicit enable binds consent to the available account
fingerprint and starts one manual cycle. Uploading the existing library remains
a separate explicit action. Temporary account loss pauses with consent and the
exact queue intact; a real account switch clears the old account-scoped consent
and requires another explicit enable.

The lifecycle derives one content-free `CloudMeetingSyncStatus` from the
StorageKit generation journal, protected attempts, account/seed state, and
typed transport failures. StorageKit exposes only an observable pending count
and newest-change timestamp. Pause revokes this Mac's consent but preserves
local meetings, remote records, and queued attempts. Remove-this-device clears
only local transport metadata and protected payload files; it never deletes
meeting rows or CloudKit records. Explicit retry makes delayed or blocked exact
attempts ready without replacing their generation, payload, or historical
attempt count. A missing account identity or unavailable capability fails
closed.

This 6C1 slice deliberately imports no CloudKit in the lifecycle, creates no
container, adds no entitlement, performs no network request from the app, and
exposes no UI. The macOS platform adapter and status surface arrive in 6C2.

**Rationale:** one deterministic policy actor makes privacy and destructive
semantics independently testable, keeps views declarative, and leaves the real
CloudKit composition thin enough to fail closed without changing business
behavior.

## D97 — Compose CloudKit only through a provisioned opt-in macOS boundary (Jul 2026)

**Context:** D96 fixes lifecycle semantics but deliberately has no Apple
runtime, signing capability, process owner, push wake, or user surface. A naïve
composition could create `CKContainer.default()` at launch, ship an entitlement
that its Developer ID profile does not authorize, let SwiftUI own observers, or
imply that audio and every existing meeting upload automatically.

**Decision:** IntegrationsKit owns the sole production
`CloudKitMeetingSyncPlatform`. Its initializer is inert. Only a previously
consented lifecycle resume or explicit Enable action may ask it for an account.
Before constructing the named `iCloud.app.portavoz.mac` container, it reads the
running signature and bundle and fails closed unless the CloudKit service,
exact container, container environment, macOS push environment, and embedded
Developer ID provisioning profile are present. It checks account status before
requesting the current-user record identity, and it gives the D95 runtime only
the private database. One bounded manual cycle prepares and sends staged work,
fetches remote work, then prepares and sends deterministic replay output.

`AppServices` owns one process-scoped `MeetingSyncModel`; SwiftUI owns no
container, lifecycle, journal observer, account observer, APNs registration, or
retry timer. The model serializes lifecycle operations, coalesces content-free
journal/account/push wakeups, and preserves explicit user actions in FIFO order
while work is in flight. `CKAccountChanged` and silent pushes carry no meeting
payload and only request that same manual cycle. The throwaway XCUITest
composition injects a deterministic in-memory client and never probes signing,
iCloud, APNs, or the host transport directory.

Settings exposes local-only, pending, synchronized, paused, retrying, and
failed states plus separate Enable, Sync now, Retry, Include existing library,
Pause, and Remove this Mac actions in English and Spanish. Opt-in covers future
portable text/metadata changes only; importing the existing library remains a
second confirmation. The surface names the exclusions: audio, local paths,
voiceprints, secrets, and embeddings never sync. Pause revokes this Mac's
consent without deleting a queue; Remove clears only this Mac's protected
transport state and consent. Neither action deletes local meetings or remote
records.

Developer and XCUITest bundles use `portavoz-local.entitlements` and therefore
remain launchable and local-only without a profile. A distributable build uses
the exact production CloudKit/APNs entitlements only when it embeds a supplied
Developer ID provisioning profile. Release creation requires a real Developer
ID identity, notary profile, and CloudKit profile; a fail-closed gate decodes
the profile, rejects expiration, and compares the exact container, service,
production environment, and push values against the signed app before
notarization and again after DMG extraction.

**Rationale:** separating local development from restricted distribution
capabilities preserves the zero-cloud default and avoids an app that builds but
cannot launch. A single process owner and one already-characterized lifecycle
keep Apple callbacks as wakeups rather than business policy. Exact signing
verification makes the public artifact—not an Xcode checkbox—the release
contract.

## D98 — Give resident macOS surfaces scoped read ownership (Jul 2026)

**Context:** the main Library, Insights, and Meeting Detail routes already
consume storage-independent feature models, but the resident menu-bar panel
still issued one-shot `MeetingStore` and EventKit calls from SwiftUI and stored
their results in local `@State`. The panel could therefore retain stale recent
meetings or pending counts, swallowed both query failures, and made a platform
view responsible for persistence coordination.

**Decision:** the menu-bar scene owns one `@MainActor @Observable MenuBarModel`.
ApplicationKit defines its bounded recent-meeting, pending-count, section, and
update contracts without importing StorageKit. StorageKit owns a three-row,
newest-first, live-meeting observation over the `meeting` table only; the
existing latest-summary open-item observation remains independent. A private
app adapter maps and merges both streams and performs the no-prompt EventKit
lookup. The model distinguishes loading, loaded, empty, degraded, and failed
state and preserves a section's last healthy value when the other source fails.
SwiftUI retains only presentation, recording/navigation commands, relative-date
formatting, and the native launch-at-login control.

**Rationale:** a resident surface must converge to current local truth whenever
it mounts without depending on a window-owned invalidation counter. Narrow
query regions avoid transcript/speaker churn, partial-failure isolation keeps
useful controls available, and keeping EventKit at composition preserves the
same no-prompt privacy rule while continuing the target's presentation-only
SwiftUI direction.

## D99 — Make whole-library backup one restart-independent application workflow (Jul 2026)

**Context:** Settings previously loaded the live meeting list, then issued a
separate detail and summary read for every row, rendered IntegrationsKit
Markdown, and wrote files directly from a SwiftUI-owned task. Closing Settings
could discard visible state; every read observed a different database moment;
existing files on disk were not part of name allocation and could be replaced;
and swallowed per-meeting failures made a partial backup look complete.

**Decision:** `ApplicationKit.ExportLibraryMarkdownBackup` owns the complete
workflow behind injected source, Markdown-document, and filesystem ports.
StorageKit supplies one newest-first SQLite snapshot of all live meetings,
their cast, ordered transcript, and latest General-recipe summary, preserving
the released export selection. Strict meeting/cast/transcript corruption is
isolated as a content-free per-meeting source failure; optional summary decode
failure degrades to no summary. The workflow allocates portable filenames
against existing and newly claimed Markdown names using canonical Unicode,
case, and width collision keys; unsafe/empty/hidden/device names receive a
readable fallback. It reports typed source/document/publication failures while
continuing healthy meetings and reserves thrown errors for a library or
destination that cannot be opened.

The macOS filesystem adapter writes a UUID temporary file atomically in the
chosen directory, then publishes it with a same-directory non-replacing move;
a destination collision is returned to the allocator for the next suffix. It
must not combine Foundation's `.atomic` and `.withoutOverwriting` options,
which trap rather than throw on the supported Swift/Foundation runtime.
`AppServices` owns one process-scoped `LibraryMarkdownBackupModel`, so closing
or reopening Settings cannot cancel publication or create a competing export.
SwiftUI retains the native `NSOpenPanel`, visible progress, localized terminal
state, and no Store, StorageKit, or IntegrationsKit reach-through.

**Rationale:** an open-format escape hatch is a product integrity boundary, not
a convenience loop in presentation. One read moment makes the exported set
coherent, per-item results preserve useful work without lying, same-directory
publication prevents partial files from becoming visible, and process ownership
keeps a long backup independent of a transient Settings window while preserving
the released General-summary and one-file-per-meeting behavior.

## D100 — Give every Ask surface one evidence-preserving application workflow (Jul 2026)

**Context:** the full Ask route, resident command palette, CLI command, local
MCP tool, and upcoming-meeting brief all needed the same local retrieval
behavior, but coordinated Store, embedding, query expansion, answer generation,
and fallback in different executable paths. The macOS views also owned
unstructured tasks; closing and reopening the palette could allow work from the
previous invocation to publish into the new panel. Presentation received
StorageKit hits or IntelligenceKit passages, so moving or testing a surface
required concrete persistence and model dependencies.

**Decision:** `ApplicationKit.AskMeetings` is the single workflow for trimmed
instant search, hybrid evidence retrieval, and optional local answer generation.
Its request and result values carry only meeting/segment identity, title,
timestamp, snippet or complete evidence, and optional generated text.
`LocalAskMeetingRetrieval` owns indexing, bounded lexical candidates, semantic
retrieval, multi-query expansion, and rank fusion; the on-device intelligence
adapter owns expansion and final generation. Ordinary generation failure or
unavailability returns the successful citations rather than failing retrieval;
`CancellationError` remains control flow and propagates unchanged.

The full Ask route owns one per-window `AskModel`; the command palette owns one
process-scoped `CommandPaletteModel`. Both own and cancel their tasks and fence
publication by generation. The palette uses a key-capable borderless panel so
its visible query field remains a reliable keyboard destination; AppKit owns
only panel lifetime, clipboard behavior, route selection, and exact evidence
seeking. CLI and MCP
construct the workflow and format its storage-independent response. Disposable
UI composition uses real temporary FTS with deterministic answer generation,
and retained visual evidence captures only the app window or identified panel.

**Rationale:** one workflow keeps search ranking, evidence completeness,
fallback, and navigation semantics consistent across every interface without
making presentation depend on persistence or model records. Evidence-first
degradation preserves useful local truth when generation is unavailable, while cancellation remains honest control flow and
explicit task ownership prevents stale asynchronous state from crossing window
or panel lifetimes.

## D101 — Keep launch guidance, local receipts, and meeting preparation behind application contracts (Jul 2026)

**Context:** the main Library state was already feature-owned, but three
supporting flows still assembled persistence and capability facts at the macOS
presentation edge. First-run setup inspected the database and preferences from
the root view, the Settings privacy ledger counted records and files from the
view, and meeting preparation combined Store summaries, commitments, Ask
evidence, and optional generation in app presentation code. This made restored
windows compete for setup, conflated unavailable metrics with zero, serialized
summary reads per related meeting, and made the brief difficult to validate
without concrete storage and models.

**Decision:** `ApplicationKit.ResolveFirstRunExperience` owns deterministic
first-run eligibility over one content-free library fact. Forced developer
presentation wins; disposable automation and a remembered completion suppress
setup; an existing live library suppresses and records completion. A failed
eligibility read keeps guidance available, cancellation propagates, and neither
speech-model readiness nor permissions participate in the decision. One
process-scoped `FirstRunModel` owns resolution and assigns presentation to one
restored window. Active main windows register with that owner; if the assigned
window closes while guidance is visible, ownership moves to another active
window instead of losing the process-wide decision or opening duplicate sheets.

`ApplicationKit.LoadLocalDataLedger` loads live meeting count, allocated audio
bytes, and local encrypted-voice count through independent ports. The metrics
run concurrently, ordinary failure makes only that value unavailable, and
zero remains a measured zero. One process-scoped model survives Settings
windows. Network activity is not fabricated as a byte counter: the UI states
the implemented explicit-action/opt-in policy and points to local receipts.

`ApplicationKit.PrepareMeetingBrief` owns relevance, related-meeting admission,
open-commitment filtering, and source-index validation. It reuses the shared Ask
evidence workflow, loads the latest live General summaries for all bounded
candidates in one StorageKit projection while commitments load independently,
and treats synthesis as optional. The macOS adapter retains already-authorized
EventKit access and Foundation Models construction; SwiftUI receives only
storage-independent brief values with navigable meeting identity.

**Rationale:** these flows are product policy even when they are read-only.
Application ownership makes launch and window behavior deterministic, keeps
privacy claims exact under partial failure, removes the brief's N+1 storage
path, and lets presentation remain declarative without making setup dependent
on a large model download.

## D102 — Inject Apple security at executable composition boundaries (Jul 2026)

**Context:** the domain module imported Security and exposed a static Keychain
implementation. Diarization, intelligence, SwiftUI, and CLI commands reached
that global directly, while CLI library reads independently constructed Store
queries. This made Core platform-specific, hid blocking securityd work behind
presentation calls, encouraged repeated credential reads, and left terminal
and MCP behavior coupled to GRDB records.

**Decision:** `PortavozCore` owns only stable `SecretIdentifier` values and the
Sendable `SecretStoring` port. `PlatformKit` depends only on Core and contains
the this-device-only `KeychainSecretStore` plus the AVFoundation microphone
permission adapter. The app and CLI each construct one platform adapter set and
inject it into `ApplicationKit.ManageSecrets`, encrypted voice stores, and
resolved intelligence/integration clients. Asynchronous user-managed credential
operations run outside presentation actors; encrypted voice stores receive the
same Core port directly. Capability modules never construct Keychain and SQLite,
UserDefaults, sync, bundles, and diagnostics remain secret-free.

The CLI owns one process composition surface. `QueryMeetingLibrary` normalizes
and bounds list/detail/search/open-item inputs, and StorageKit returns detail
plus the latest live General summary from one SQLite read snapshot. Meeting,
Ask, and MCP read surfaces format only ApplicationKit values. Model-heavy and
mutation commands share the composition surface while their concrete pipelines
remain at the executable edge until equivalent application workflows exist;
benchmark harnesses remain independently constructible. A publishing command
resolves its Keychain/environment credential once per invocation, not once per
action item.

**Rationale:** Core remains portable and deterministic, Security and
AVFoundation have one visible outer owner, and credential failure can degrade
or surface without blocking SwiftUI. One bounded query contract keeps CLI and
MCP semantics consistent and makes the remaining executable migration
incremental without removing commands or changing their output contract.

## D103 — Route terminal product workflows through application contracts (Jul 2026)

**Context:** terminal commands for transcription, diarization, summarization,
refinement, document export, action-item publishing, voice enrollment, and model
management still assembled files, Store reads and writes, pinned model loading,
attribution, provider egress, and terminal output in the same command bodies.
That kept released behavior available, but duplicated application ordering and
made command tests require concrete models, filesystem state, Keychain, or
external adapters. Synchronous model-download callbacks also had no owned async
ordering boundary before a command printed its terminal result.

**Decision:** those commands retain only argument parsing, validation that is
specific to their syntax, warnings, and terminal formatting. ApplicationKit
owns narrow Sendable workflows for standalone file analysis, persisted quality
refinement, coherent meeting-document export/publication, pending action-item
publication, local voice identity management, and ordered pinned-model
lifecycle. Ports separate file admission/publication, processors, model
lifecycle, encrypted voice storage, rendering, and explicit publishers from
workflow policy. `CLIComposition` injects one process platform/database set;
`CLIProductAdapters` owns concrete model, StorageKit, filesystem, provider,
integration, voice, and streaming SHA-256 behavior.

Persisted refinement loads the current detail, accepts stored or explicit audio,
builds the same revision-fenced draft as the app, and applies it through the
existing atomic transaction. Saved BYOK summarization commits its meeting,
cast, and transcript before the gateway can record and perform egress, then
commits the immutable summary afterward. Export and issue publishing consume one
coherent current detail projection. Their publisher ports prepare lazily: local
meeting/document/pending-item admission happens before a credential read; a
successful preparation precedes the egress warning and transport. Missing
meetings and empty pending-item sets therefore preserve their released local
result without touching Keychain. Synchronous download callbacks enter one
ordered relay that is drained on success and failure before the workflow
returns. Capture diagnostics and benchmark harnesses keep direct construction
because they measure concrete capabilities rather than product policy.

**Rationale:** one application owner preserves operation order, language and
attribution policy, revision safety, receipt-before-transport semantics, and
output parity across app and terminal surfaces. Commands become deterministic
presentation adapters; concrete Apple/model/storage integrations stay visible
at composition; and focused workflow tests can characterize every branch
without downloading a model, reading a real biometric secret, or publishing
outside the device.

## D104 — Keep durable post-capture policy in one application workflow (Jul 2026)

**Context:** the persisted processing queue and atomic artifact transactions
already protected restart recovery, but the macOS coordinator still decided
which transcription, diarization, and summary job to claim; how to maintain its
lease; how to fingerprint and chain inputs; when to retry or cancel; and when
to run the post-meeting action. Those are product and lifecycle rules rather
than process supervision or model-adapter concerns. Keeping them beside
filesystem, UserDefaults, model construction, Shortcut, and signpost code made
the durable path difficult to reuse or test without the app executable.

**Decision:** `ApplicationKit.ProcessPostCaptureJobs` is the single owner of
serial supported-job execution, owner lease and heartbeat policy, exact
transcription/diarization/summary fingerprints, transcript cleanup and
attribution, dependent-job admission, summary attempt provenance, bounded
retry dates, supersession and optional-summary cancellation, terminal action
timing, engine-release timing, and the next persisted wake. It depends on
narrow storage and capability ports. `MeetingStore` adapts the storage port and
retains the atomic owner/revision-fenced artifact transactions.

The macOS executable retains one process-scoped supervisor that coalesces
kicks and schedules the returned wake without polling. Its concrete adapter
resolves recording files, prepares Parakeet/pyannote/provider implementations,
reads language and vocabulary preferences, invokes the user's Shortcut,
releases engines, admits safe temporary-store fixtures, and maps only
content-free workflow events to OSLog/signposts. Live capture and immediate
captioning remain separate from this batch workflow. Mixed-language speech is
preserved per segment; meeting-level language is stored only for a homogeneous
attributed transcript.

**Rationale:** the application layer now owns one deterministic durable state
machine while StorageKit remains the transaction authority and the app remains
the Apple/model composition boundary. Lease loss, superseded input, provider
unavailability, and optional-summary exhaustion can be characterized without
real media or models, and the released audio-first, degradable-attribution,
mixed-language, provenance, Shortcut, and no-poll behavior remains unchanged.

## D105 — Keep review documents and participant voice memory behind application contracts (Jul 2026)

**Context:** Meeting Detail already consumed a scoped read model, but two
cross-capability actions still assembled product policy in SwiftUI. Markdown,
PDF, and secret-Gist actions rendered the current view snapshot, read the
GitHub credential, and constructed the publisher beside save-panel state.
Participant voice suggestions and explicit memory read the encrypted gallery,
resolved recording files, loaded pyannote models, extracted embeddings, and
matched names beside chip presentation. These paths duplicated terminal
document admission and made biometric policy depend on a view lifetime.

**Decision:** `ApplicationKit.PrepareMeetingDocument` loads one coherent
meeting projection and returns canonical Markdown or PDF bytes with the
released title-based suggested filename. Secret-Gist publication enters the
existing `ExportMeetingDocument` workflow, so the coherent local document
exists before the app publisher resolves its credential and crosses the
data-egress gateway.
The route-owned `MeetingDetailModel` owns document actions and typed effects.
SwiftUI retains the explicit off-device confirmation, native save panel,
clipboard, localized errors, and exact released title-based default filename.

`ApplicationKit.ManageMeetingVoiceMemory` is the single owner of participant
voice suggestions, duplicate-offer admission, and explicit memory. It considers
only unnamed non-user speakers, loads the gallery before requesting transient
embeddings, applies the existing one-to-one match threshold, never mutates a
speaker, and accepts persistence only for an explicitly requested currently
named non-user speaker. Read or extraction failure degrades to no suggestion;
insufficient audio is typed; gallery write failure remains visible. App adapters
retain recording-path resolution, pyannote/ModelStore loading, Keychain-backed
gallery access, utility scheduling, and disposable-test isolation.
`MeetingDetailModel` owns one-shot suggestion state and every explicit
voice-memory action/effect, so the view never coordinates those adapters.

**Rationale:** coherent document and biometric policy now survive view
recreation, are independently characterizable without network, Keychain,
models, or real recordings, and cannot silently bypass local admission,
explicit consent, or one-to-one identity rules. The UI and concrete Apple/model
composition remain native while released export, secret-Gist, suggestion-chip,
and remember-voice behavior stays intact.

## D106 — Keep local voice enrollment behind one application contract (Jul 2026)

**Context:** the CLI already entered an application workflow for file-based
voice enrollment, but Settings and Onboarding still coordinated microphone
capture, diarization-model loading, embedding extraction, encrypted storage,
and model-cache invalidation in SwiftUI. The two app surfaces intentionally use
different capture behavior: Settings records a fresh echo-cancelled sample,
while Onboarding may reuse the first-listen sample or record a fresh raw sample.
Those released distinctions had to remain explicit without making view lifetime
responsible for a biometric workflow.

**Decision:** `ApplicationKit.ManageLocalVoiceIdentity` accepts an admitted
file, a supplied in-memory sample, or a bounded captured sample through narrow
ports. It bounds requested capture to 1...60 seconds, requires at least four
seconds of finite audio, owns typed capture/extraction/persistence progress,
and persists only after successful
extraction. Status and delete remain model-free. The macOS adapter owns
`MicrophoneSource`, the requested raw or echo-cancelled mode, guaranteed stop
on success/failure/cancellation, verified diarizer loading, transient embedding
extraction, the Keychain-backed encrypted store, and cached-diarizer
invalidation after successful mutation. Disposable UI composition returns an
empty identity and never accesses the host biometric file or key. Settings and
Onboarding submit requests and render localized outcomes only. A failed
destructive request leaves the enrolled state visible instead of reporting a
successful file-and-key deletion.

**Rationale:** one deterministic application contract preserves the exact
enrollment UX while making capture order, invalid-sample rejection, persistence,
and failure behavior testable without a microphone, model, filesystem, or
Keychain. Biometric storage remains explicit and device-local, source audio is
not retained, and SwiftUI cannot accidentally leak a capture or mutate model
state during view recreation.

## D107 — Treat generated speaker names as untrusted application input (Jul 2026)

**Context:** Meeting Detail requested EventKit attendee candidates, invoked the
Foundation Models speaker namer, verified the result, and retained loading and
suggestion state in SwiftUI. The visible chip was explicit and safe, but the
identity-admission rule depended on a view lifetime and one concrete generator.
The model has previously fabricated plausible names and prose evidence, so the
application boundary must not treat generator output as identity truth.

**Decision:** `ApplicationKit.SuggestMeetingSpeakerNames` loads one coherent
meeting projection, excludes the local and already named speakers before
optional work, obtains calendar candidates through a narrow port, and invokes
an untrusted proposer. It trims and deduplicates eligible labels, then admits a
proposal only when the normalized name occurs as complete tokens in a real
transcript line or calendar candidate. The resulting value carries typed
evidence derived from that source; model-authored evidence prose never crosses
the application boundary. A missing meeting is typed, proposer failure remains
visible, and an empty verified result states only that no verified suggestion
was found. No result mutates a speaker. The app adapter retains EventKit
authorization and the concrete Foundation Models proposer, whose shared
whole-token filter remains a defense-in-depth check. The route-owned
`MeetingDetailModel` owns loading and suggestion state, removes a chip only
after its explicit rename persists, and keeps failed confirmation visible.
SwiftUI retains the button, inert evidence chip, explicit acceptance gesture,
and localized presentation only. A confirmed calendar candidate carries
`calendarSuggestion` alias provenance instead of being mislabeled as transcript
evidence.

**Rationale:** calendar access, generation, and identity verification are now
characterizable without EventKit or Foundation Models, cannot diverge across
future interfaces, and survive view recreation. Complete-token matching avoids
short-name substring false positives, typed evidence keeps the UI honest, and
persistence-aware removal prevents a failed rename from looking accepted. The
released one-click UX, `Me` exclusion, calendar widening, manual fallback, and
never-auto-apply contract remain unchanged.

## D108 — Keep local summary-provider discovery behind one application contract (Jul 2026)

**Context:** Settings, Onboarding, and launch composition each needed the same
answer to a product question: which local summary provider is actually usable
on this Mac? The answer had been assembled beside SwiftUI from Apple
Foundation Models capability, Ollama process/model discovery, RAM, disk, and a
clean-install preference rule. Treating a running Ollama server as readiness
could recommend a blank, OCR, embedding, reranking, or Whisper model, and
duplicating the rule made an explicit user choice vulnerable to an asynchronous
startup probe.

**Decision:** `ApplicationKit.LocalSummaryProviderPolicy` evaluates one typed,
capability-neutral profile and returns a typed recommendation with stable
reasons. Available Apple Foundation Models wins. Ollama is admitted only when
its running service exposes a nonempty model whose normalized name is not
classified as OCR, embedding, reranking, or Whisper work. Embedded MLX is
recommended only when memory and disk meet its local requirements;
otherwise the result carries typed setup guidance rather than localized prose.
`DiscoverLocalSummaryProviders` provides the same result to Settings and
Onboarding. `ConfigureInitialSummaryProvider` initializes only an absent
preference, re-checks it after asynchronous discovery, and performs no write
when no compatible provider exists. Its selection port reports whether the
guarded write won instead of letting the workflow claim an unsaved selection.

The macOS adapter owns concrete Foundation Models capability, content-free
localhost health/model requests, RAM and disk facts, provider DTO mapping, and
main-actor UserDefaults persistence shared with SwiftUI's `@AppStorage`.
SwiftUI owns localization and explicit user actions only. Existing provider
choices remain authoritative and provider execution continues to use the exact
configured engine without fallback.

**Rationale:** one deterministic application policy prevents presentation
surfaces from disagreeing, distinguishes service availability from generation
readiness, and makes startup races and low-resource guidance testable without
Foundation Models, Ollama, UserDefaults, or real hardware. The change preserves
local-only behavior, Sequoia setup recovery, and every explicit provider choice.

## D109 — Keep Settings device resources behind application workflows (Jul 2026)

**Context:** three Settings sections still coordinated concrete capabilities
from SwiftUI. Audio settings enumerated Core Audio devices directly, recording
storage moved files and changed the shared root marker from the view, and
remembered-voice settings called the encrypted gallery while discarding delete
failures. These operations span hardware, durable filesystem state, and
third-party biometric data, so view recreation must not define their ordering
or success semantics.

**Decision:** ApplicationKit exposes three narrow workflows. Audio input
listing returns only stable UIDs and display names. Recording-storage
management returns current/default locations, performs an optional root change,
and forwards ordered progress through a capability-neutral port. Remembered-
voice management lists privacy-safe summaries containing no embedding and
performs explicit single/all deletion without suppressing errors. The macOS app
adapters retain `AudioDeviceCatalog`, `RecordingsLocation`, and `VoiceGallery`.
Recording migration is completed before the shared marker changes, and every
queued progress update is delivered before the terminal result. A destination
that resolves to the current root, including a symlink alias, is a no-op rather
than entering resumable cleanup against its own source. Encrypted
gallery work runs off the main actor; temporary UI-test composition returns an
empty gallery and never reads or mutates host biometric state. SwiftUI retains
preferences, the native folder picker, localized progress, and visible results.

**Rationale:** the application layer now owns observable operation order and
failure truth without absorbing Core Audio, filesystem, Keychain, or biometric
implementations. A failed migration cannot publish a new root, a failed voice
deletion cannot look successful, embeddings cannot leak into presentation, and
the same workflows remain characterizable without real devices or user data.

## D110 — Resolve pre-meeting reminders behind an application workflow (Jul 2026)

**Context:** the process-scoped reminder controller owned its timer and panel,
but also read UserDefaults and the clock, queried the EventKit-backed source,
and applied reminder policy. That made one presentation object responsible for
capability access, timing consistency, selection semantics, and UI lifecycle.
The policy also relied on the calendar adapter returning sorted events.

**Decision:** `ApplicationKit.ResolveMeetingReminder` receives one sampled time,
the configured lead window, the session's reminded identifiers, and an injected
upcoming-meeting source. A disabled lead window short-circuits before reading
the source. Due-event selection is independent of input order, chooses the
earliest start deterministically, and derives the displayed rounded-up minutes
from the same sampled time used for admission. The macOS adapter retains
UserDefaults, `Date`, and the EventKit-backed `CalendarAttendeeSource`, with the
calendar projection performed away from the main actor. The controller retains
only periodic scheduling, session deduplication, panel presentation, and route
selection. Calendar failures continue to degrade silently because reminders
are an optional nudge and the released surface has no error state.

**Rationale:** time and calendar behavior are now deterministic and directly
testable without EventKit, preferences, or AppKit. Disabling reminders performs
no unnecessary calendar work, unsorted sources cannot select the wrong event,
and the visible countdown cannot drift between policy admission and display.
The existing no-permission banner, once-per-session behavior, floating panel,
and one-click recording route remain unchanged.

## D111 — Coordinate Meeting Detail metadata suggestions in ApplicationKit (Jul 2026)

**Context:** Meeting Detail generated chapter labels, a content-based meeting
title, and a suggested summary structure directly from SwiftUI. The view owned
Foundation Models capability checks, concrete generators, one-shot flags,
chapter caches, and sequencing beside rendering. View-task cancellation or a
new read projection could therefore consume an optional suggestion or publish
output derived from older content. The title chip also disappeared before a
rename persisted, and rename failure was silently followed by search reindexing.

**Decision:** `ApplicationKit.SuggestMeetingReviewMetadata` receives one
storage-independent meeting-review projection, the chapter starts already
titled, and explicit title/structure admission flags. It independently admits
template-like titles, General summaries, and untitled chapters; bounds and
normalizes generated labels; maps recipe results back to the known catalog;
degrades ordinary capability failures per output; and preserves cancellation.
A private macOS adapter retains Foundation Models availability plus
`ChapterTitler`, `TitleSuggester`, and `MeetingTypeDetector`. The route-owned
`MeetingDetailModel` owns one-shot completion, chapter-label state, request-ID
fencing, cancellation retry, and explicit dismissal. Every incoming review
update invalidates older optional work. SwiftUI renders inert chips/labels and
sends explicit actions only. A suggested title is cleared and Spotlight is
reindexed only after the rename persists; failure keeps the chip and shows the
existing localized rename error. Summary regeneration dismisses the structure
chip before starting and remains an explicit user action.

**Rationale:** optional intelligence can no longer outlive the review snapshot
that admitted it, and presentation no longer constructs model capabilities or
owns asynchronous policy. Independent degradation preserves useful labels when
another generator fails, while bounded outputs and catalog mapping prevent
untrusted model values from becoming UI or recipe identity. The released
never-auto-apply contract, chapter excerpt fallback, scale-fixture bypass, and
on-device-only behavior remain unchanged.

## D112 — Coordinate Meeting Detail audio through an application workflow (Jul 2026)

**Context:** Meeting Detail resolved recording paths, selected channel files,
constructed the synchronized player, derived the waveform and playback ranges,
compressed channels, exported clips, and rebuilt playback directly from
SwiftUI. View lifecycle therefore controlled expensive preparation and
filesystem-sensitive operation order. Compression also processed channels
sequentially with per-file deletion, so a later failure could leave one raw
channel removed while another remained uncompressed.

**Decision:** `ApplicationKit` exposes typed requests and results for playback
preparation, all-channel compression, and clip export. A route-scoped,
explicitly observable playback facade exposes transport intents and values
without exposing `AudioPlaybackKit` types to SwiftUI. The app adapter owns the configured
recording root, canonical channel lookup, and concrete codec adapter.
`MeetingDetailModel` owns one-shot preparation per audio directory,
cancellation retry, playback invalidation, compression state, and export
effects. Playback preparation runs in a directory-scoped task rather than the
multi-section review-revision task, preventing unrelated initial observations
from canceling and consuming its only attempt. SwiftUI retains rendering,
transport controls, and the native save panel. `AudioTranscoder` refuses to
replace an existing canonical output,
keeps every original until all generated outputs have verified, removes all
generated outputs after failure or cancellation, and only then removes the raw
channels. Byte accounting queries current filesystem attributes rather than
reusing potentially cached URL resource values. The application compression
workflow depends on an injected codec capability so its transaction and disk-
savings semantics are deterministic without requiring a host encoder in unit
tests.

**Rationale:** playback and file mutation now have one feature owner and one
application ordering boundary while AVFoundation and filesystem details remain
in capability and composition layers. View reconstruction cannot duplicate
preparation, clip export re-resolves files after compression, optional audio
failure preserves a healthy text transcript, and a codec failure cannot strand
or overwrite user-owned recording data. The player, waveform, skip-silence,
microphone-only playback, clip marks, compression control, import behavior,
and native save experience remain unchanged.

## D113 — Treat complete catalog verification as the only model-readiness evidence (Jul 2026)

**Context:** the model loaders already downloaded exact pinned artifacts through
`ModelStore`, but several app surfaces separately inferred persisted readiness.
The embedded MLX path trusted the presence of `model.safetensors`, and Settings
treated Whisper artifact sizes as sufficient. A partial or same-sized corrupt
installation could therefore be displayed or supplied as ready even though the
catalog's complete SHA-256 contract had not passed. Creating independent
`ModelStore` instances also scattered process ownership, while re-hashing
multi-gigabyte installations for every presentation read would be needlessly
expensive.

**Decision:** `ModelStore` exposes a `VerifiedInstallation` value that only the
module can construct after every artifact in the exact descriptor passes a
streaming SHA-256 verification. `ModelStoreKit.VerifiedModelLifecycle` owns the
process-scoped store relationship, coalesces concurrent descriptor checks, and
caches only successful evidence by descriptor ID and revision. Missing or
corrupt results are not cached. Explicit install, remove, invalidate, and
forced-verification operations fence older in-flight evidence, and a superseded
waiter resolves current state instead of returning its obsolete result. Install
and remove operations for the same descriptor execute in invocation order;
installation may publish evidence directly because `ensureAvailable` performs
a final complete verification before returning. Cancellation stays effective
before publication but reports success once that irreversible verified install
has committed. Artifact repair stages and verifies a sibling on the destination
volume, then atomically renames or replaces it so failed publication cannot
create a missing-file window. The macOS composition root creates one store and
lifecycle and shares them with Settings, MLX summary resolution, Import,
post-capture processing, diagnostics, transcription, diarization, and
participant-voice extraction. Disposable automation receives a unique empty
model root. Settings performs checks asynchronously and renders an explicit
integrity-checking state until the result is known. Terminal product workflows
retain their existing catalog-verifying adapters; benchmark construction remains
an explicit isolated exception.

**Rationale:** one artifact, directory existence, and aggregate byte counts are
not executable-code integrity evidence. A typed module-owned value makes the
security claim unforgeable outside `ModelStoreKit`, while successful
process-local caching avoids repeated large hashes and explicit re-verification
remains available when an audit is required. Sharing one lifecycle also makes
download, deletion, provider availability, and diagnostics agree without
turning model preparation into a launch or recording prerequisite.

## D114 — Freeze the implemented macOS dependency and presentation boundaries (Jul 2026)

**Context:** the incremental macOS extraction had accumulated focused source
ratchets for individual workflows, but no single executable check compared the
complete SwiftPM production graph with the as-built architecture. The final
review also needed to distinguish legitimate executable composition and
nonvisual live capability ownership from accidental construction or persistence
coordination inside SwiftUI presentation.

**Decision:** package tests now assert the exact internal dependency set for
every production target. `PortavozCore` remains the inward root; capability
targets keep their documented Core and model/storage/intelligence edges;
`ApplicationKit` keeps only the capability dependencies used by implemented
workflows; capability targets cannot depend back on it; and the macOS app and
CLI remain the two concrete composition roots. A second repository-wide rule
identifies every SwiftUI `View` type and rejects concrete storage, model,
capture, playback, calendar, egress, or security construction; direct
`MeetingStore` calls; and database/platform-adapter framework imports there.
Concrete construction remains valid in executable composition, nonvisual live
capture and dictation owners, diagnostics, and disposable benchmark harnesses.
Any intentional graph or presentation-boundary change must update the as-built
architecture and the exact ratchet together.

**Rationale:** an exact graph turns the architecture diagram into executable
truth rather than an interpretation, while the presentation rule protects the
business boundary without forcing native panels, AppStorage, or live session
ownership into artificial modules. The audit found no additional production
boundary violation after the verified-model extraction, so closing the macOS
convergence work with broad guards is safer and simpler than adding speculative
packages or moving legitimate edge adapters inward.

## D115 — Make the privacy receipt account for private iCloud without overstating encryption (Jul 2026)

**Context:** the per-meeting receipt covered tracked model processing and HTTP
egress attempts, while the independently opted-in CloudKit transport could
already hold meeting text. Its content-free journal is populated on every local
portable mutation whether sync is enabled or not, so the existence of a row or
a pending generation is not proof that anything left the Mac. CloudKit
encrypted fields and assets are encrypted on-device and in iCloud, but Apple
guarantees end-to-end protection for third-party app data only when the user
enables Advanced Data Protection. Portavoz cannot inspect that account setting.

**Decision:** `PrivacyReceipt` carries an orthogonal, content-free private-sync
disclosure with exactly two durable states. `acknowledgedGeneration > 0` means
the user's private CloudKit database confirmed at least one text aggregate and
is disclosed permanently, including after sync is paused, disabled, or a later
local edit becomes pending. Missing or unacknowledged journal state records no
cloud copy because it cannot distinguish disabled sync from an upload in
flight. Meeting Detail replaces an otherwise unqualified all-local headline,
shows an identified encrypted private-iCloud line, and keeps processing claims
explicitly scoped. The redacted support report includes the same disclosure in
its existing read-consistent snapshot and changes an otherwise all-local status
to `all-tracked-processing-stayed-on-device`. Product copy says encrypted private
iCloud fields/assets and never claims unconditional end-to-end encryption.
Audio, paths, embeddings, canonical people, secrets, and voiceprints remain
outside sync.

**Rationale:** one meeting surface now answers whether tracked processing used
a remote provider and whether iCloud durably acknowledged a private text copy,
without treating an unconditional mutation journal as network evidence. The
two facts remain separate because HTTP egress attempts and private account sync
have different consent, transport, and failure semantics. Conservative
encryption wording preserves the local-first trust contract for both standard
iCloud protection and optional Advanced Data Protection.

## D116 — Probe filesystem metadata without weakening atomic publication (Jul 2026)

**Context:** the private CloudKit asset and transport-state writer originally
required Foundation's complete-protection and backup-exclusion metadata on
every destination. Supported macOS 15 and current GitHub runners can expose
temporary filesystems that reject either metadata operation with `EINVAL`, even
though private POSIX files, durable writes, and same-volume atomic rename work
normally. Treating this exact lack of filesystem capability as a total sync
failure made every CloudKit persistence path unusable on those hosts. Ignoring
arbitrary metadata errors would instead hide real permission, corruption, or
publication failures.

**Decision:** before writing content, `CloudSyncProtectedFile` creates separate
empty `0600` probes in the actual destination directory for complete protection
and backup exclusion. Each probe applies and reads back its metadata. Only a
direct or Foundation-wrapped POSIX `EINVAL` or `ENOTSUP` means that specific
metadata capability is unavailable; a successful write without matching
read-back and every other error fail closed. Probe files contain no meeting
bytes and are removed with POSIX `unlink`.

Every publication still creates one unique same-directory sibling with owner-
only `0600` permissions. Supported protection and backup metadata are applied
and verified while that sibling is empty. One POSIX descriptor then handles
partial writes and `EINTR`, calls `fsync`, closes, and verifies exact byte count
plus permissions before one same-volume atomic rename. An unsupported metadata
key omits only that key; it cannot disable private permissions, durability,
integrity verification, cleanup, or atomic publication. There is no CI, OS-
version, or environment-variable bypass.

**Rationale:** the destination filesystem, not the process label, is the source
of truth for metadata support. Narrow capability detection keeps Portavoz usable
across its supported macOS range while applying the strongest available
filesystem metadata and preserving a non-negotiable owner-only durable atomic
baseline. Fail-closed handling for every error outside `EINVAL`/`ENOTSUP`
prevents compatibility from becoming a general privacy exception. This decision
supersedes only D94/D95's unconditional metadata assumption; their encryption,
content boundary, integrity, consent, and transport semantics remain unchanged.

## D117 — Scope pull-request UI evidence without weakening release gates (Jul 2026)

**Context:** the real-app XCUITest suite reached 39 cases in each locale. Running
all 78 executions after documentation, CLI, or one isolated surface change adds
substantial build/launch time without stronger evidence, while path-only
workflow filters can silently skip required tests or leave required checks
pending. The public repository also still tracked local design-sync state and
had no executable guard against generated projects, result bundles, scratch
plans, ticket files, or private tracker keys leaking into implementation names
and comments.

**Decision:** one versioned selector catalogs every XCUITest and maps known
production paths to feature-level evidence. Localization and shared-harness
changes expand to bilingual canaries, an unknown production Swift path falls
back to the complete English suite, and non-product changes allocate no macOS
UI runner. The runner builds once and reuses the same test products for every
selected locale. The complete English and Spanish suites remain mandatory for
release and architecture closure. An empty selector is the explicit complete-
suite form, not a no-op, and the macOS Bash runner assembles optional selector
and locale arguments without touching empty arrays. CI validates the catalog
on every change and publishes scoped xcresult evidence when UI execution is
selected.

Local agent/design-sync state, scratch planning, tickets, reports, generated
projects, result bundles, and ad-hoc screenshots are ignored and rejected if
tracked. Implementation, tests, tooling, and workflows reject private tracker-
key patterns. Accepted architecture decisions, as-built specs, product
constraints, and explicit gaps under `docs/` remain intentionally tracked;
the repository roadmap and completed migration ledger are local-only under
D119.

**Rationale:** risk-based selection removes redundant launches while preserving
a conservative fallback and an explicit full bilingual gate. Keeping the scope
catalog executable prevents undocumented tests from becoming invisible.
Separating durable project truth from local work state leaves the public tree
clean without severing code from the decisions that explain it.

## D118 — Close SDK diagnostics at the narrowest framework boundary (Jul 2026)

**Context:** current Xcode diagnostics identified a generic named-coordinate
metatype crossing SwiftUI's concurrent visual-effect closure, deprecated MLX
cache configuration, and an AVAudioConverter `@Sendable` input callback that
captured a non-Sendable buffer plus mutable one-shot state. Smaller unused-value
and obsolete throwing-call patterns also obscured a clean diagnostic baseline.
Import-wide `@preconcurrency` or warning suppression would hide future framework
drift instead of proving that each boundary remains safe.

**Decision:** the focused transcript uses SwiftUI's built-in vertical
scroll-view coordinate space, preserving its viewport geometry without a
generic named key. Embedded MLX memory control uses `MLX.Memory.cacheLimit`.
SpeechAnalyzer conversion passes its fully initialized, immutable source buffer
through one private `AudioConverterInputBox`: a lock serializes its one-shot
delivery state, and `@unchecked Sendable` is confined to that documented SDK
bridge. Portavoz does not apply broad AVFoundation concurrency suppression.
Unused values, explicitly discarded optional results, and calls whose SDK
contracts are now nonthrowing follow their current signatures. The maintained
closure command is `swift build -Xswiftc -warnings-as-errors`, enforced by the
primary current-SDK CI build and backed by an architecture characterization
that rejects both the superseded patterns and removal of that CI gate.

The iOS sync description is also reconciled with D116: staging and transport
files always retain private owner-only `0600`, durable, same-directory atomic
publication, while complete protection and backup exclusion are independently
probed and verified when the destination filesystem supports them. This is a
documentation correction, not a weaker storage behavior.

**Rationale:** standard framework coordinate spaces and supported dependency
APIs remove avoidable compatibility debt. The single lock-protected callback
box gives the compiler and reviewers a local safety argument without weakening
concurrency checking across an entire framework. Treating diagnostics as errors
keeps SDK evolution visible, while the D116 wording prevents future mobile work
from implementing an obsolete unconditional metadata assumption.

## D119 — Keep the roadmap and migration ledger local (Jul 2026)

**Context:** `docs/ROADMAP.md` and `docs/refactor-20260714.md` mixed transient
delivery sequencing with durable public project truth. The migration plan also
grew into a large historical execution ledger after macOS convergence was
complete. Keeping those files tracked made the public repository appear to
require internal work-state documents even though implemented behavior,
binding decisions, and unresolved limitations already have dedicated sources.

**Decision:** these two files remain available to maintainers locally but are
gitignored and rejected if tracked. Public current truth is distributed by
responsibility: `ARCHITECTURE.md` for implemented structure and invariants,
`specs/` for runtime behavior, `DECISIONS.md` for binding trade-offs,
`GAPS.md` for unresolved limitations and field validation, `IOS.md` for the
deferred mobile phase, `PRODUCT.md` for product intent, and `RELEASING.md` for
shipping. Contributor guidance, public documentation, source comments, and PR
templates must not link to these local planning files. Removing them from Git
must preserve each developer's working copy.

**Rationale:** the public codebase should explain what exists, why it exists,
and what limitations remain without publishing transient sequencing state.
Explicit local paths preserve maintainer continuity while repository hygiene
prevents accidental recommit. Self-contained tracked sources avoid broken links
and keep architecture review reproducible for outside contributors.

## D120 — Treat system callback liveness as a recoverable capture capability (Jul 2026)

**Context:** a real dual-channel recording continued writing microphone audio
for more than two hours after the system-channel staging file stopped advancing
at 33:20. Peak or RMS health cannot identify this failure while recording, and
acoustic silence is not equivalent: a healthy Core Audio tap continues to emit
silent PCM callbacks. Stopping the complete recording would discard healthy
local speech, while checking through the `RecordingSession` actor for every
chunk would serialize the capture hot path and live consumers.

**Decision:** after the first persisted system frame, persisted microphone
frames act as the recording heartbeat. Eight seconds without another system
frame opens one content-free incident, emits stalled health, and requests the
optional `RecoverableAudioCaptureSource` capability. `ProcessTapSource`
implements that capability by rebuilding its tap, aggregate device, and IOProc
on the existing stream and timeline. Continued outages request at most one
additional recovery every eight seconds; the next system frame emits recovered
health. Monitoring never starts before a real system frame, ignores room
frames, and never interprets zero-valued samples as dead callbacks. Stream
failure remains a separate terminal channel event. Detection is a deterministic
lock-protected state machine on the writer path; only non-empty signals cross
the recording actor to find and invoke the recoverable source. Capture and the
microphone writer remain active throughout. ApplicationKit carries only the
typed, content-free events, and the app presents an undismissable reconnecting
warning plus a bounded recovery confirmation.

**Rationale:** frame cadence, not audio content, is the reliable distinction
between a silent meeting and a dead callback. Capability discovery keeps
ordinary/test/room sources valid, in-place rebuilding conserves the durable
timeline, and independent channel degradation preserves Portavoz's audio-first
parity rule. Keeping the per-frame transition off the actor avoids adding a
latency bottleneck to recording or live transcription. The policy and complete
session-to-source path are deterministic unit evidence; successful recovery of
a real Core Audio callback stall remains an explicit field gate.

## D121 — Hot-attach live transcription through bounded recording feeds (Jul 2026)

**Context:** audio-first start correctly allowed a clean or memory-released app
to record while Parakeet downloaded or compiled, but the active session sampled
only the engine that was resident at Start. The shared preparation could finish
successfully without ever connecting that engine to the current recording, so
captions, live translation, Companion, rolling intelligence, and speaker hints
remained absent until Stop. Buffering every callback until a multi-minute model
load completes would turn a degradable feature into unbounded memory growth and
stale inference work.

**Decision:** every recording creates one bounded `bufferingNewest` audio feed
per selected channel before capture begins. The producer yields synchronously
without suspension. A recording-scoped `LiveTranscriptionAttacher` connects a
resident Parakeet immediately or asynchronously joins the process-owned verified
Parakeet task after capture has started. A cold attachment consumes only recent
context and all future frames; finalized channel files remain the source for the
complete durable first pass, so the session keeps its recovery bit even after
live captions become available. Stop cancels only the recording waiter, never
the shared model task, closes the feeds, and drains attached consumers. Typed
preparing, available, and failed events cross ApplicationKit without concrete
engines or raw errors. Live diarization uses its own bounded feed and begins
only after captions are available and a real system frame exists. Translation
maintains explicit off/waiting/ready/download/translating/active/unsupported/
failed state, skips rows already in the target language, and clears target-
dependent cached output whenever the picker changes. Every asynchronous state
publication and cache write is fenced to the target captured by its task, so a
canceled framework request cannot publish old-language results after a switch.

**Rationale:** bounded future-oriented attachment restores live value during a
cold recording without gating the primary artifact, replaying minutes of stale
audio, or duplicating verified model ownership. Durable recovery preserves
feature parity for the pre-attachment interval. Finite content-free states make
degradation understandable and testable while keeping platform Translation and
speech engines in the executable adapter.

## D122 — Admit lexical transcript and grounded generated output before persistence (Jul 2026)

**Context:** field inspection found punctuation-only system rows in an accepted
Refine transcript. Those rows also entered summary material, and one generated
summary attached every claim to the same unrelated late segments while copying
decision bullets into action items. Exact request-local E-tags prove that a
provider selected a real row, but they do not prove that the row supports the
rendered statement. Channel-specific microphone confidence policy cannot guard
system output, legacy rows, or provider semantics.

**Decision:** `PortavozCore.TranscriptContentPolicy` defines one language-neutral
minimum: a transcript row must contain at least one Unicode letter or decimal
digit. Whisper mapping, ApplicationKit Refine for both channels, StorageKit's
accepted-Refine Unit of Work, and IntelligenceKit transcript formatting enforce
that contract independently. Microphone confidence and bleed filtering remain
additional narrower rules. Intelligence assigns evidence tags only after this
filter. `StructuredSummary.draft(for:)` then admits an overview, decision, or
action evidence link only when the rendered statement and cited row share at
least one distinctive case- and diacritic-folded token; unverifiable links fail
closed without deleting generated text. The same pre-persistence boundary
deduplicates tasks and rejects any normalized action copied verbatim from the
recipe's explicitly typed decision section. Translation carries only artifacts
that passed the original source-language gate.

**Rationale:** lexical integrity belongs to the domain and aggregate boundaries,
not to one ASR adapter or view. Defense in depth keeps old corrupt rows from
becoming new model facts while preventing future Refine transactions from
reintroducing them. Evidence authenticity and semantic support are separate
properties; a conservative false negative merely hides a source link, whereas a
false positive presents unrelated speech as proof. Exact decision-copy
rejection fixes the observed non-action without relying on provider obedience or
language-specific action-verb heuristics.

## D123 — Keep long-call finalization off actor executors and expose content-free capture shape (Jul 2026)

**Context:** a field recording continued for more than two hours after its
remote channel stopped advancing. Callback recovery now protects future audio,
but a prolonged outage could still leave an unattended microphone recording.
Closing a multi-hour PCM capture also performs header inspection, streamed
SHA-256, and atomic publication proportional to file size, and the existing
support report omitted the per-channel duration and transcript shape needed to
diagnose the incident without inspecting private audio or text.

**Decision:** `RecordingOutageNudgePolicy` makes the existing Stop action
prominent after 120 continuous seconds without remote callbacks, while recovery
and microphone capture continue and Portavoz never stops automatically.
`RecordingSession` closes every source, drains consumers, snapshots value
evidence, and releases writer handles before a dedicated serial utility
`DispatchQueue` inspects, hashes, and publishes channels sequentially. Stop
awaits the complete result and preserves per-channel isolation: one failed destination keeps its
staging file without blocking a healthy peer. The redacted support format moves
to version 2 and adds only current channel/role/container/codec, finite media
health/duration/size/signal values, and aggregate transcript channel/
attribution counts. SQL selects only those fields; paths, checksums, text,
speaker identity, timestamps, and reusable fingerprints remain absent.

**Rationale:** automatic silence-based Stop could destroy legitimate in-person
or paused meetings, so a conservative, actionable nudge is safer. Long-file
work remains bounded and durability-critical but should not occupy Swift's
cooperative executor. Content-free channel shape turns the exact field failure
into support evidence while preserving Portavoz's privacy boundary and avoiding
a second sensitive corpus.

## D124 — The live copilot's user-facing name is "Apuntador" in every locale

**Context:** the feature shipped as "Companion" (itself renamed from
"Copiloto" to avoid Microsoft Copilot collision). By mid-2026 the market moved
under it: Zoom retired its "AI Companion" brand (June 2026), the term "AI
companion" drifted toward parasocial chatbots, and the live-assistant category
split between collapsing "undetectable" tools and assistive coaches. Naming
research (2026-07-22, STRATEGY §16.4) found "Apuntador" — the theater prompter
who whispers lines from the concha — collision-free as an AI product name,
evocative and ownable, Spanish-first like "Portavoz" itself, and structurally
assistive in framing: a prompter helps the performer deliver their own
performance.

**Decision:** every user-facing surface says "Apuntador" in BOTH locales
(catalog keys, Settings, Meeting Detail, recording toolbar, docs prose,
accessibility identifiers `settings-apuntador-*`, `detail-apuntador`,
`apuntador-card-*`). Three identity classes deliberately keep the old name:
persisted storage identifiers (tables `companionCard`,
`companionCardEvidence`, `companionCardEvidenceSegment`; the
`companion-knowledge-answer` egress operation and related raw values),
UserDefaults keys (`companionEnabled`, `companionUserName`, the BYOK key), and
internal Swift symbols/files (`CompanionCard`, `LiveCompanion`,
`CompanionSessionCoordinator`, …). Storage and preference names are identity —
renaming them is a migration with zero user value and real risk. The symbol
rename is deferred as a mechanical follow-up for a quiet tree, because the
concurrent working tree actively edits those symbols today.

**Rationale:** the user-visible name is marketing surface and must move with
the market; persisted identity must not move at all; and a symbols-only rename
can wait without any user-facing inconsistency.

## D125 — Recording is observational: no live voice-processing takeover (Jul 2026)

**Context:** two real calls on macOS 15 Sequoia and macOS 26 Tahoe showed that
starting Portavoz reduced participant playback and made the user's microphone in
the meeting app mute or become extremely quiet. The shared field shape matched
the implementation: meeting capture enabled `AVAudioEngine` voice processing by
default. Apple voice-processing IO changes both the input and output nodes, and
its “minimum” other-audio ducking level is still ducking. It also competes with
the meeting application's own echo cancellation and microphone processing. The
before/after support snapshots retained healthy dual-channel files, but only 8
of 242 live segments and 3 of 175 refined segments came from the microphone,
which corroborates the weak local signal without exposing meeting content.

**Decision:** meeting recording and global dictation always construct
`MicrophoneSource` in raw mode. Raw is also the source's default and the CLI
default; `--aec` is an explicit diagnostic-only opt-in, while the former
`--no-aec` spelling remains a compatibility no-op. The application no longer
stores or exposes an AEC recording preference, so an old `aecEnabled=true`
default cannot reactivate VPIO. Settings presents the invariant as “Call-safe
capture — Always on.” The process tap remains unmuted and independent, and
post-capture `MicBleedFilter` continues removing remote speech duplicated
through speakers. Explicit short voice-enrollment capture may still request
voice processing because it is not a meeting recorder and already owns that
bounded action.

**Verification:** source-level architecture tests require raw production
composition and reject the retired preference; focused unit, localization, and
Audio Settings XCUITest cover the policy and its visible status. A real-call A/B
on Sequoia and Tahoe remains the final field gate: playback and uplink must sound
identical immediately before and after Portavoz starts, while both Portavoz
channels advance.

**Rationale:** a meeting assistant must never alter the meeting it observes.
Preventing call interference outranks live acoustic echo cancellation.
Transcript-level bleed rejection is degradable and reviewable; changing the
shared hardware graph is neither.

## D126 — Separate dictation input ownership from authoritative text delivery (Jul 2026)

**Context:** system-wide dictation now accepts both a Carbon hotkey and an
explicitly configured mouse button, then optionally removes bilingual
hesitation fillers and applies user spelling corrections. Treating the mouse
gesture as speech-engine behavior would reverse the input boundary. Applying
corrections sequentially also allowed one rule's output to become another
rule's input, contradicting the promise that the matched preferred spelling is
authoritative. A session event tap additionally cannot be created before
Accessibility is granted and macOS exposes no direct permission-granted
callback.

**Decision:** the app target owns Carbon, `CGEventTap`, Settings recorders,
permission prompts, and the pure `MousePTTGesture` ownership table. CGEvent
indices 0/1 are permanently ineligible; index 2 is vendor-facing Button 3
(middle click), and every higher index is an additional button. Stored invalid
values normalize to Off. Registration is idempotent, retries when the app
becomes active after System Settings, and cancels a mouse-owned capture before
rebinding can discard its consumed release. Local event monitors are removed
when their Settings rows disappear.

TranscriptionKit owns the content-only `DictationTextRules`. It canonicalizes
one rule snapshot, removes only the conservative bilingual filler set when
enabled, and matches every replacement against the original final dictation in
one longest-trigger-first pass. Replacement output is never re-matched. These
rules run only at dictation delivery; recording, live captions, durable
transcription, and Refine remain verbatim inputs to their existing hygiene
policies.

**Rationale:** hardware-event ownership and permission lifecycle are macOS app
concerns, while deterministic post-ASR text policy is reusable speech behavior.
One-pass matching makes exact spelling predictable, avoids rule-order cascades,
and is linear in the dictated text apart from the small user-managed rule
lookup. Keeping meeting transcripts outside this boundary preserves Portavoz's
source-of-truth contract.

## D127 — Let finalized audio outrank optional live payloads at Stop (Jul 2026)

**Context:** a real call finalized healthy microphone and system CAF files, but
the captured-snapshot transaction rejected its provisional payload and left the
meeting as a recording shell. The former fallback retried the same rejected
snapshot and could also persist an error code that StorageKit did not admit.
Launch recovery could reconcile published files only after the shell was
already content-free or marked `needsAttention`; a shell that already carried
recovered transcript content required another launch and remained alarming in
the meantime.

**Decision:** `ApplicationKit.StopRecording` first retries the exact full
snapshot once, because a transient Store failure must not discard a released
feature. If the same payload is structurally rejected, Stop follows one bounded
degradation ladder: retain transcript, cast, notes, and only valid Apuntador
cards; then retain finalized audio plus notes and enqueue exact complete
transcription; finally retain the strongest canonical `capture.*`
`needsAttention` projection that StorageKit accepts. Generated Apuntador cards
without their successful run provenance are omitted rather than relabeled as
manual or legacy content. Every accepted projection remains atomic and carries
the durable next action. Launch recovery may mark a stale content-bearing
recording shell `needsAttention` and install only validated published assets in
the same pass; StorageKit promotes it directly when the existing transcript and
asset evidence satisfy the ready invariant.

**Rationale:** healthy finalized audio is the irreplaceable primary artifact;
optional live and generated projections must not prevent its durable
publication. One exact retry preserves parity for transient failures, while a
finite ordered ladder avoids repeating an invalid transaction or inventing
provenance. Canonical lifecycle codes keep Store invariants and user recovery
copy aligned, and same-pass launch repair removes a restart-dependent recovery
gap without weakening aggregate validation.

## D128 — Route live translation through explicit per-turn language lanes (Jul 2026)

**Context:** Apple Translation configured with an unknown source may ask the
user to choose a language. In a mixed Spanish/English call, repeating that
framework auto-detection for successive turns produced recurrent modal pickers
and unstable output after the target changed. Meeting-level language cannot be
used because different participants may speak different languages.

**Decision:** live translation resolves every closed transcript row to an
explicit source-to-target pair. Persisted segment language is authoritative;
when it is absent, a conservative local recognizer may classify only lexical
text with sufficient length and confidence. Rows already spoken in the target
language and short or uncertain rows remain exactly as spoken. The app groups
work by one explicit language pair, configures `TranslationSession` with both
source and target, and never requests framework source auto-detection. Download
consent is scoped to the pair. Switching target clears translated rows, active
source, consent, unsupported-passthrough rows, and in-flight publication through
the existing target fence. If Apple reports one pair unsupported, every pending
row in that lane remains exactly as spoken but is marked handled, routing
continues to later supported lanes, and the UI retains a partial-support state
instead of presenting a terminal failure.

**Rationale:** the transcript is a multilingual sequence, not a monolingual
document. Explicit lanes remove a framework-owned language prompt from the live
meeting, prevent same-language rows from being needlessly rewritten, and make
download consent and cancellation deterministic without translating or
normalizing the source transcript. Treating unsupported work as passthrough
prevents one minority language from starving every translatable turn that
follows.

## D129 — Give the reader ownership of live-transcript position (Jul 2026)

**Context:** the lyrics-style live transcript automatically followed each new
row. A user who scrolled up to reread an earlier turn was immediately returned
to the latest caption, and the playback-oriented fade/blur cylinder made
rapidly moving live text lose readability before it left the center.

**Decision:** live transcript presentation has an explicit follow state.
Direct user scroll interaction pauses follow indefinitely; programmatic scrolls
do not. macOS 15+ uses SwiftUI scroll-phase events. On the minimum macOS 14.4
runtime, a zero-size AppKit bridge lives in the scroll document and observes
`NSScrollView.didLiveScrollNotification` only for its enclosing scroll view;
that user-only event includes legacy mouse-wheel scrolling without a start/end
pair, while `ScrollViewProxy.scrollTo` does not generate it.
While browsing history, every visible row is full-opacity, full-scale, and
unblurred, and incoming rows never change the reader's position. An
identified **Jump to live** control is the only action that resumes following.
While following, live captions use a wider sharp zone and tightly bounded
fade/scale/blur values than playback. Playback keeps its existing focused-lyrics
treatment. The visual policy and AppKit observer scope are unit tested; a
disposable XCUITest fixture proves new rows arrive while the reader remains in
history and that the explicit action restores the latest row.

**Rationale:** live captions are both an ambient display and a short-term
record. User interaction is stronger intent than animation, so no timer should
steal the scroll position. Separating live and playback visual policy preserves
the designed review experience while keeping active conversation readable and
accessible.

## D130 — Keep automatic Refine unhinted across the complete channel (Jul 2026)

**Context:** a Stop publication failure left an empty recording shell whose
stale meeting language was English. Refine reused that aggregate value as a
Whisper hint and translated Spanish speech into English. Even a homogeneous
provisional transcript cannot prove that every actor or a later turn uses the
same language.

**Decision:** automatic Refine never supplies a full-channel language hint.
WhisperKit language detection is explicitly enabled whenever that hint is nil;
nil by itself is not automatic because WhisperKit disables detection while
decoder prefill is enabled and otherwise falls back to English. VAD results
retain their detected language, and the decoder remains in `.transcribe` mode
so it never intentionally translates speech. Only the user's explicit
per-meeting fixed English or Spanish recovery choice may constrain recognition.
The meeting-level language remains derived metadata installed only when the
completed attributed transcript is homogeneous.

**Rationale:** a recording is a sequence of multilingual turns, not one
language slot. Avoiding an aggregate hint prevents stale metadata and one
speaker's language from translating another speaker's words. Explicit fixed
recovery remains available when acoustic ambiguity is more important than
mixed-language fidelity.

## D131 — Prefer direct system captions over matching microphone bleed (Jul 2026)

**Context:** speaker playback can re-enter the microphone during a live call.
Because microphone and system callbacks arrive independently, the same phrase
appeared as alternating `Me` and `Them` fragments before post-capture cleanup.
Callback order is not stable, and legitimate overlapping speech must remain.

**Decision:** a new lexical microphone row is compared only with the newest
twelve system/room rows and is dropped when it matches direct remote evidence.
A delayed matching system/room row may replace the microphone copy only while
that copy is the newest still-open row. Older rows are immutable once
translation and rolling-summary cursors can observe them. The existing
conservative bleed threshold remains authoritative, so short acknowledgements
and distinct overlapping text survive. Finalized audio and per-channel raw
transcription remain untouched; this policy changes only the live merged
projection.

**Rationale:** direct system capture is stronger evidence for remote speech than
acoustic microphone spill. A bounded deterministic admission window corrects
both adjacent callback orders without an unbounded transcript scan, changing
the call's audio graph, deleting genuine local participation, or invalidating
IDs and indexes already consumed downstream.

## D132 — Treat generated summary owners as untrusted cast claims (Jul 2026)

**Context:** a summary provider assigned actions to people whose names were
merely mentioned in the meeting. Typed action storage later cleared unknown
owners, but Markdown had already rendered the raw generated name, producing
visible invented assignments and duplicated forms such as
`Daniel: task — Daniel`.

**Decision:** structured summary drafting admits an action owner only when it
case-insensitively resolves to exactly one cast member. A unique exact speaker
label has priority; a display name is accepted only when it is unique in the
meeting cast. Drafting resolves once, carries that `SpeakerID` beside the
canonical rendered owner into typed projection, and never performs a second
ambiguous name lookup. Unknown and duplicate display names become unassigned. A
matching leading owner prefix is removed from the action text, and an empty
remainder is discarded. Prompts reinforce this rule but deterministic
post-generation admission remains authoritative.

**Rationale:** names inside speech are meeting content, not identity evidence.
One cast-grounded resolution keeps rendered and typed projections consistent,
prevents model obedience or array order from becoming a trust requirement, and
still preserves actions whose ownership is genuinely known.

## D133 — Preserve source identity through live diarization splits (Jul 2026)

**Context:** live diarization can split one closed caption after translation,
rolling summary, or Apuntador has already referenced its ID. Replacing every
piece with a fresh ID invalidated Apuntador evidence at Stop and made a valid
captured-snapshot transaction fail. The rolling summary also used an array
offset, so inserting a split piece before that offset could skip new speech or
replay the wrong window.

**Decision:** `SpeakerAttributor` preserves the source segment ID on the first
non-empty split child and assigns fresh IDs only to additional children.
Unsplit segments retain their existing identity as before. The rolling live
summary tracks the IDs of admitted closed captions rather than one mutable array
offset, so every additional split child remains eligible without destabilizing
already consumed turns. Stop still retains D127's bounded fallback for any
other optional provenance rejection.

**Rationale:** a split refines one observation; it does not erase its lineage.
Keeping one stable anchor preserves foreign-key evidence and translation state,
while fresh sibling IDs accurately represent newly visible turns. Identity-
based cursors are robust to insertion, splitting, and callback reordering and
therefore keep live intelligence independent from presentation-array shape.

## D134 — Live assist stays measured, conservative, and schema-free (Jul 2026)

**Context:** APUN-003/004 add pre-meeting objectives with live check-off, an
on-demand next-question suggestion, and a rolling talk-time cue. Each could
have justified new tables, new toggles, or an eager model loop; the live
surface's rules (D26 opt-in, D29 priorities, measured-not-judged mirror
philosophy) already answer most of those questions.

**Decision:** Objectives persist as `ContextItem` rows with the new
`objective` kind — no schema migration; the check-off state folds into the
content ("✓ " prefix) and the check-off moment into the timestamp, so the D28
notes block carries what was covered and what stayed open into every summary.
The automatic check-off rides the existing 40-second rolling tick at
`.background`, is gated by the same Apuntador opt-in (it is a model judgment
about the conversation), holds a deliberately high bar (announced topics are
NOT covered; doubt leaves an objective pending), and can only check — never
uncheck — from the offered pending list. The next-question suggestion clones
the catch-up concern exactly (pull-based, `.interactive`, capability-honest,
stale-fenced) and carries still-open objectives so suggestions can steer back
to them. The talk-time cue is pure channel math (microphone = the user) with
no model call, so it does NOT ride the Apuntador opt-in; it renders only once
closed captions exist and emphasizes only past 60 seconds of speech and a
two-thirds share — measured, not judged. Seeding objectives from the
pre-meeting brief is deferred: the brief dies at the recording route boundary
today, and widening that boundary belongs to its own change.
## D135 — Enhanced notes as a separate regenerable artifact (Jul 2026)

**Context:** the notes→summary weave (D28) expands the user's notes INSIDE the
general summary. Granola's core loop is different: your own notes become the
document, enhanced with transcript facts. Users wanted both — the summary and
"my notes, expanded" — without the model ever rewriting what they typed.

**Decision:** NOTES-001 adds `enhancedNote` (schema v15): ONE regenerable
document per meeting, generated by `ApplicationKit.EnhanceMeetingNotes` through
the shared summary provider resolver (FM/Ollama/MLX/BYOK) from an internal
`enhanced-notes` recipe that repeats each raw note verbatim in bold, expands it
with one to three transcript-grounded sentences, states contradictions plainly,
and never invents or reorders. The raw `contextItem` rows are never modified.
The artifact follows the D62–D78 provenance regime exactly: an exact
fingerprint + language hit performs no model operation and creates no
`GenerationRun`; a succeeded run commits atomically WITH the document;
failed/cancelled runs persist best-effort; replacement is an explicit in-place
update preserving `createdAt` — never `ON CONFLICT REPLACE`. The document is
meeting-owned portable content (D92 journal via v15-registered triggers);
`generationRunID` stays device-local. Meeting Detail shows the raw notes until
an enhanced document exists and observes both through an independent sixth
degradable read, so a notes failure can never blank the transcript.

**Rationale:** the user's words are testimony; the model is an annotator.
Keeping enhancement OUT of the summary artifact keeps both regenerable
independently, keeps the summary cache honest, and gives the "your notes,
expanded" loop its own provenance and sync story at the cost of one table.

## D136 — The shareable recap is summary-derived and never sent by us (Jul 2026)

**Context:** the meeting ends and the real job begins: telling people what
happened. Exporting Markdown or a PDF hands over a document; it does not
write the message. Competitors close this loop by generating a recap and
wiring an outbound integration (mail credentials, a Slack token, a share
link on their servers) — each one a standing key and a new place meeting
content can leak from.

**Decision:** FEATURE-003 adds a recap that Portavoz DRAFTS and the user
SENDS. Three properties are binding:

1. **Summary-derived.** `RecapComposer` (ApplicationKit, pure) receives the
   meeting, the cast, and the summary — never `TranscriptSegment`s. A recap
   therefore cannot leak raw speech even if the user forwards it widely, and
   the guarantee is structural rather than a filter that could regress.
2. **Reviewed before it moves.** The composed draft opens in an editable
   sheet. Changing audience or channel never overwrites text the user has
   already edited: the new choices are held and a `Redraft` action applies
   them explicitly. Nothing is transmitted from the sheet — the destinations
   are the clipboard and the system share sheet (D12's L0 share step), both
   chosen by the user, so no credential, no gateway, and no egress receipt
   is involved.
3. **It speaks the meeting's language.** Section labels come from a
   bilingual content table keyed on the summary's language, not from `L10n`:
   the recap is addressed to the people who were in the room, whatever
   language the reader's interface happens to be in.

Commitments are re-rendered from the library's real done state — open items
only, with owners resolved from the cast — so a stale action-items section
narrated inside the summary snapshot never contradicts the current truth.
An audience of one participant leads with that person's own commitments.
Channel shaping reuses `MeetingExporter.render(_:format:)`, the same
renderer as the summary copy, so no channel grows its own Slack dialect.

**Rationale:** the honest boundary for a local-first product is to make the
message excellent and stop at the user's own send button. Refusing outbound
integrations costs one click and removes an entire class of standing
credentials, silent background sends, and server-side copies. The provenance
line the recap carries claims only what is always true — that the transcript
is not included — and deliberately does NOT claim the material never left
the device, because a BYOK or remote engine may have produced the summary.
## D137 — Performance numbers are a contract, not a memory (Jul 2026)

**Context:** Portavoz measures itself well — eight harnesses cover search,
detail, semantic retrieval, waveform, Spotlight, drift, DER, and memory. What
it did not do is RETAIN. Every published number lived as prose in a spec, no
Makefile target invoked a benchmark, `RELEASING.md` never ran one, and the only
tracked evidence came from a single five-hour session. Nothing in the release
recipe would have noticed a ten-fold regression.

**Decision:** PERF-001 lands as a declared contract plus a gate.
`docs/evidence/perf-thresholds.json` states every release-relevant metric: its
journey, its budget, and the exact selector that pulls it out of a harness
report. Budgets are copied from the Target column of spec 08's measured-numbers
table — the contract records the promise the product already made, it does not
invent a new one. `make perf-ledger` runs the unattended harnesses, resolves
every metric, compares it against its budget and against the baseline the
contract names, and answers with one scorecard and one exit code.

Three rules make the answer trustworthy:

1. **Absolute misses fail; regressions are candidates.** PERF-008 fails a
   release on a budget miss, but only counts a p95 regression after three
   stable runs — so one run reports a candidate (exit 2) and `--strict` is how
   a release decides to treat candidates as blockers.
2. **A journey that was not measured says so.** Cold start, recording memory,
   live lag, drift, DER, refine, and summary need a microphone, a real
   recording, or Instruments. They stay declared in the contract and are
   printed as `not measured` with the exact command that produces them. A
   partial run can never read as a green one.
3. **Authority is earned by the machine.** The scorecard claims
   `authoritative` only when every report comes from one release build on one
   Apple Silicon Mac that matches the baseline machine; mixed hosts, a debug
   build, or another Mac make it `informational`. That is PERF-001's "a stable
   Apple Silicon machine is the release authority; noisy hosted CI is
   informational only", enforced rather than remembered. The macOS version is
   deliberately excluded from machine identity: upgrading the OS must surface
   as whatever it does to the numbers, not silently discard the baseline.

**Rationale:** the numbers were never the hard part; keeping them true across
releases is. Encoding them where a script can check them converts a claim that
decays into one that fails loudly, and it costs one tracked JSON file plus a
gate that reuses every harness already written. Moving a baseline forward stays
a reviewable edit of that file, so an accepted regression is always someone's
explicit decision.
## D138 — Silence is an endpoint: the deterministic stage-0 turn detector (Jul 2026)

**Context:** closing a caption row is delta-driven — a row closes only when
the NEXT Parakeet delta appends a new one. Silence therefore never closed a
row, and an Apuntador candidate only existed once a row closed. The
consequence went beyond latency: when a remote participant asked a question
and the room went quiet waiting for the user's answer, no card could be
produced during the meeting at all. The one moment the prompter is most
needed was the one moment it structurally could not act. (APUN-005's research
framing — "remove the 300–800 ms silence-endpointing tax" — understated the
problem: there was no endpointing to tax.)

**Decision:** a deterministic turn endpointer, not a model.
`TurnEndpointPolicy` (IntelligenceKit, pure) plus one deadline task in
`RecordingController`: every live delta re-arms a 2.0 s deadline; when it
fires, the still-open remote row is treated as a finished turn and runs the
SAME detection dispatch a real close runs — same channel/noise/question
gates, same scheduler key, same card admission. Recording activation first
drains rows that closed while Start was preparing and then arms the open tail;
enabling Apuntador mid-recording arms the already-open remote row, while
disabling it cancels the deadline. Three properties are binding:

1. **The caption model is untouched.** The coalescer keeps its delta-driven
   closing; the open row stays open for presentation, dictation, translation,
   and the summary. Only Apuntador detection consumes it early.
2. **Speculation can never out-detect the close.** The policy's gates mirror
   the real-close gates exactly because both paths share one dispatch method
   and that method is the only caller of the candidate gate.
3. **One detection per (row, text length).** A `SpeculativeTurnMark` makes
   the eventual real close free when the text did not change, and a late
   delta that grows the text is a genuinely new candidate that re-detects;
   the existing per-question card dedup absorbs the overlap.

The 2.0 s constant is derived from the pipeline's own numbers: the live
window's worst-case structural latency is 1.4 s (1.0 s chunk + 0.4 s right
context), so two seconds of delta silence implies the speaker stopped at
least 0.6 s ago — the same sentence pause that would have closed the row had
anyone kept talking.

**The model this stage was researched around stays out, with a revisit
trigger.** pipecat smart-turn v3 (8.7 MB int8, BSD-2, ~12 ms, 23 languages
incl. ES, sha256-pinnable from HF) is a real candidate for the cases a
transcript heuristic cannot see — intonation-only turn ends without
punctuation. But it ships ONNX-only: adopting it today means either an
onnxruntime dependency (a heavyweight binary xcframework to serve an 8 MB
model) or converting and self-hosting a CoreML artifact with weaker
provenance. Neither is worth it while the deterministic stage covers the
transcribable cases; GAPS records the trigger (an official CoreML artifact,
or an onnxruntime decision made for its own sake).

**Rationale:** the honest reading of APUN-005 was that the product gap was
structural, not statistical. A two-line policy and one timer close the
"question, then silence" hole entirely and cut several seconds in the common
case; a 360 MB (v2) or new-runtime (v3) dependency would have improved
recall on a minority of turns while leaving the same hole open on Sequoia
and non-FM Macs, where detection cannot run anyway.
## D139 — App Intents without an Xcode app target (Jul 2026)

**Context:** GAPS #10 recorded that "AppIntents/Siri metadata requires the
future Xcode app target": Xcode extracts the metadata bundle during its own
build, SwiftPM has no equivalent step, and D20 deliberately keeps the release
pipeline SPM + `make-app.sh` with no checked-in project. The premise went
untested — and it turned out to be wrong.

**Decision:** the metadata is extracted OUT OF BAND, and D20 stands.
`appintentsmetadataprocessor` (Xcode toolchain) needs only per-file
`.swiftconstvalues` plus a source list; it does not need an Xcode build. The
pipeline rests on one enforced contract: **the intents file is SDK-only**
(`PortavozAppIntents.swift` imports AppIntents, AppKit, Foundation and
nothing of the project), so `scripts/build-appintents-metadata.sh` can
compile that single file standalone — under the SHIPPING module name
`portavoz_app`, so the metadata's mangled type names match the SwiftPM
binary — emit the const values (`-emit-const-values-path` with the frontend
`-const-gather-protocols-file` fed the flattened toolchain protocol list),
run the processor, verify the extraction actually declares actions, and copy
`Metadata.appintents` into `Contents/Resources`. `make-app.sh` fails the
build if any step fails: shipping without intents silently would be a feature
regression. `ArchitectureDependencyTests` pins the SDK-only import diet —
the one way this pipeline can rot is someone importing ApplicationKit into
the intents file, and that must fail at test time, not at release time.

The intent carries no recording product logic. `openAppWhenRun` first
foregrounds the exact bundle that owns the action, then `perform()` publishes
one buffered process-local request. `PortavozAppDelegate` consumes that request
into the same pending-route channel used by other process-external navigation.
The public `portavoz://record` URL remains a separate adapter for generic
automation tools; the App Intent never asks LaunchServices to choose a URL
handler after the system already chose its app. The initial implementation also
published an English/Spanish `AppShortcutsProvider`; D141 supersedes that
macOS-specific part after field evidence showed the unsupported duplicate.

**Rationale:** the blocked-by-tooling claim deserved an experiment before a
binding-decision change. One afternoon of evidence preserved D20, unlocked
the native automation capability, and reduced GAPS #10 to its true remainder — Quick Look, which
genuinely needs an extension target and stays deferred.

**Limits recorded honestly:** the extraction targets arm64 only (matching
the shipped binary); intents must stay in the one SDK-only file; and Siri
phrase invocation on macOS remains untested field-side. The native action is
verified in the Shortcuts action picker. Portavoz does not rely on direct App
Shortcut surfacing on macOS: the reliable Spotlight/Siri path is a user-created
Shortcut containing the native action. Metadata extraction, the process-local
handoff, and the exact URL adapter are automated; custom Shortcut invocation
through Spotlight and Siri was later field-verified under D141.

## D140 — Installed build identities are a system boundary (Jul 2026)

**Context:** field validation found no Portavoz action in Shortcuts, Spotlight,
or Siri even though `/Applications/Portavoz Dev.app` contained nonempty
`Metadata.appintents`. The stable app, Dev app, and every DerivedData UI-test
host all claimed `app.portavoz.mac`; the stable app still lacked the new
metadata, and LaunchServices had many same-identifier candidates. App Intents
registration is bundle-identity based, so a correct metadata file inside an
ambiguous identity is not a discoverable feature.

**Decision:** each simultaneously installable build class has one identity:

- shipping `/Applications/Portavoz.app`: `app.portavoz.mac`;
- local `/Applications/Portavoz Dev.app`: `app.portavoz.mac.dev`;
- disposable XcodeGen host: `app.portavoz.mac.uitest-host`.

`make install` rewrites both base and localized Dev names before the final
Developer ID signature, verifies the copied bundle, force-registers only that
exact path, and then opens it. UI tests still target the public URL adapter by
exact application URL, but their DerivedData bundles can no longer shadow the
shipping identity. Dev's distinct identity intentionally requires its own
one-time TCC permissions, preferences, and Keychain context; silently sharing
those system grants with a stable installation is not worth corrupting system
discovery.

**Rationale:** path and display name are not application identity on macOS.
Running multiple builds with one identifier turned installation order and
version ranking into product behavior. Separate identities make registration,
permissions, and failures deterministic while preserving the rule that
development commands never mutate the notarized release app.

## D141 — macOS publishes an App Intent, not an App Shortcut (Jul 2026)

**Context:** the first real Shortcuts/Spotlight/Siri validation passed, but the
Shortcuts action picker displayed two identically titled **Start recording**
rows: the native `AppIntent` with the Portavoz icon and the automatic
`AppShortcut` from D139 with a generic icon. Apple supports App Intents as
macOS action-building blocks, but does not define automatic App Shortcuts as a
macOS product surface. The supported workflow already uses the native action
inside a user-created Shortcut, which Spotlight and Siri invoke by its saved
name.

**Decision:** the macOS metadata contains `StartRecordingIntent` and no
`AppShortcutsProvider`. The app no longer refreshes automatic shortcut
parameters at launch. Metadata packaging fails closed if it finds no action or
any `autoShortcuts` entry. The existing user-created Shortcut remains the
single Spotlight/Siri adapter and keeps referencing the same intent identifier.
A future iOS target may add its own App Shortcuts provider because that platform
supports the surface; it must not be extracted into the macOS metadata bundle.

**Rationale:** publishing one supported primitive gives users one clear choice,
preserves composability, and avoids two controls that perform the same
operation. It also aligns implementation with the already documented macOS
contract instead of asking users to understand an unsupported duplicate.

## D142 — Separate live bleed admission from readable paragraph projection (Jul 2026)

**Context:** field calls through Mac speakers still showed exact two-word and
rolling partial copies as alternating `Me`/`Them` rows. The earlier
three-word bag-of-words threshold intentionally preserved them. At the same
time, genuine consecutive rows from one person looked fragmented, but generic
`Them` may still represent two back-to-back people before live diarization
resolves their voices.

**Decision:** direct system/room audio may suppress an exact two-word
microphone copy only when both channel timelines truly overlap. A contiguous
three-word rolling edge may also suppress the longer noisy copy. One-word
speech, sequential acknowledgements, distinct overlap, finalized audio, and
raw per-channel transcription remain unchanged. Readable paragraph grouping is
a separate bounded view projection: it groups microphone rows or rows with the
same stable live voice, carries their translations, keeps the first ID for
diffing, and never groups generic `Them`.

**Rationale:** direct capture is stronger evidence than acoustic spill, but
short language alone is not enough to erase speech. Temporal evidence makes
the admission rule safer, while a presentation-only paragraph projection
improves readability without invalidating translation, Apuntador, rolling
summary, persistence, or speaker-lineage consumers.

## D143 — Expand Library search bilingually without an LLM or broad token OR (Jul 2026)

**Context:** a user searching `august` expected meetings that contain `agosto`,
and a selected Library hit opened the right meeting but not its exact transcript
moment. Semantic or generative expansion would add model readiness, latency,
non-determinism, and privacy surface to the instant sidebar path.

**Decision:** ApplicationKit expands a compact, explicit English/Spanish
meeting lexicon in both directions. StorageKit treats each complete expanded
query as one conjunctive FTS5 variant and ORs the variants; unknown product and
technical terms remain exact. Selecting a hit publishes its meeting ID and
timestamp through the existing one-shot seek channel before route navigation.

**Rationale:** deterministic local expansion covers high-value bilingual
calendar and meeting vocabulary on every supported Mac, keeps FTS ranking and
tests reproducible, and reuses the proven source-jump contract instead of
creating a second navigation mechanism.

## D144 — Clear playback is reversible channel admission, not destructive DSP (Jul 2026)

**Context:** dual-channel recordings made through Mac speakers contain a clean
remote copy in the system track and a delayed acoustic copy in the microphone
track. Flat full-gain playback makes that capture truth sound like echo or
double speech. Enabling voice processing during capture would modify the live
call, while destructive post-processing would remove the original evidence and
could erase speech when transcript attribution is incomplete.

**Decision:** when both system and microphone tracks load successfully,
AudioPlaybackKit keeps the direct system track unchanged and admits microphone
audio only around merged transcript-confirmed local turns, with short
click-free ramps. Meeting Detail enables this `Clear playback` mix by default,
exposes the original flat mix as a reversible toggle, and exports the currently
selected mix. Mic-only recordings never receive channel attenuation. The
stored recording is never rewritten.

**Rationale:** channel roles provide stronger evidence than generic echo
cancellation after capture. A non-destructive mix solves the common
loudspeaker-bleed case without touching the call, preserves forensic source
audio, and gives incomplete transcripts an immediate escape hatch.

## D145 — Instant Library search is exact-first and opportunistically semantic (Jul 2026)

**Context:** the D143 lexicon covers common meeting vocabulary but cannot
enumerate paraphrases or every English/Spanish equivalent. Portavoz already has
an Apple Latin contextual embedder and exact cosine storage for Ask. Adding a
second vector database would duplicate model/storage policy, while requesting
OS assets when a user types would turn an instant local control into a surprise
download.

**Decision:** Library search always publishes bounded FTS5 results first,
including `unicode61` case and Latin-diacritic folding plus D143 complete-query
variants. When the Apple Latin embedding assets are already installed and no
recording is active, one process-shared ApplicationKit actor incrementally
embeds at most 512 missing non-micro segments and appends unique exact-cosine
hits after lexical rank. Search-field typing never requests assets. Semantic
failure or cancellation becomes an empty augmentation and cannot fail exact
search. No sqlite-vec or other vector dependency is added.

**Rationale:** exact-first behavior keeps names, identifiers, ranking, startup,
and failure semantics deterministic on every supported Mac. Reusing the
existing device-local representation adds paraphrase and cross-language recall
with no new privacy boundary, dependency, or required setup.

## D146 — Field evidence has stable subsystem IDs outside support JSON (Jul 2026)

**Context:** the redacted format-2 support report already described durable
meeting, channel, transcript-shape, job, generation, and privacy state without
content. The first field collector, however, grouped checks around evolving
feature scenarios. A failed call could therefore require conversational context
to decide whether recording start, the capture route, callback recovery, Stop,
post-capture admission, translation, or Refine owned the failure. Refine
validation also had no first-class way to bind before/after reports to one
meeting while proving a new revision was accepted.

**Decision:** support JSON remains format 2. A separate protocol-2 field
manifest selects one of six canonical hardware/conversation fixtures and uses
seven stable evidence IDs, each with one fixed subsystem owner. The collector
requires one pseudonymous meeting reference, validates the application version
against the inspected Dev bundle, and rejects report-derived contradictions.
When Refine is evaluated, it packages independently validated before/after
reports, requires the same meeting reference, monotonic export time, and a
strictly newer transcript revision. Human-observed route, language, and UI
behavior are represented only as pass/fail/not-observed; no supporting words or
free-form notes enter the artifact.

Protocol-1 `--scenario` invocations retain their original manifest shape and
filename for one release. The tooling suite runs under the repository-hygiene
gate, and StorageKit proves that format-2 export remains decodable before and
after an accepted refined cast.

**Rationale:** stable subsystem IDs make one failed field run actionable without
opening meeting content. Keeping the fixture protocol outside support JSON
avoids coupling operator observations to the application storage contract.
Paired structural evidence proves that the same meeting changed without
pretending aggregate counts can judge linguistic quality, while one-release
compatibility preserves already collected evidence and automation.

## D147 — Release reliability is a fail-closed evidence ledger (Jul 2026)

**Context:** deterministic tests, signed-distribution verification, and
privacy-safe field packages existed as separate commands and documents. A
release decision still depended on a maintainer remembering which proofs had
run, whether they described the same version/build/commit, and which claims
required real hardware rather than a fixture. A green test suite could
therefore be mistaken for Sequoia, AirPods, durable-file, or real-conversation
proof that it cannot provide.

**Decision:** one tracked machine-readable contract declares every
release-blocking reliability proof and classifies it as deterministic
automation, signed-build verification, real-hardware validation, or user-field
validation. The deterministic runner writes a receipt only after its complete
gate set passes and binds that receipt to version, build, and Git commit. The
distribution verifier writes a receipt only after the DMG and an independently
extracted app pass signing, notarization, stapling, Gatekeeper, and production
CloudKit checks; its receipt binds the version/build and DMG SHA-256. Real
device and conversation claims enter only through canonical protocol-2 field
manifests.

The evaluator accepts only exact-shaped receipts and manifests for the
requested release. It writes an owner-only JSON/Markdown scorecard containing
proof identity and aggregate evidence metadata, never meeting references,
support reports, paths, audio, transcript, or generated content. A release
passes only when every contracted proof is `pass`. Missing, failed,
`incomplete`, and `not-observed` evidence block; prose, memory, prior-version
results, and a green adjacent proof never fill a missing cell.

**Rationale:** release confidence must be reproducible from durable evidence,
not operator memory. Separating proof classes prevents automation from
overclaiming hardware behavior, while exact artifact identity prevents stale
evidence from blessing a different build. A content-free projection preserves
Portavoz's local-first privacy boundary and still leaves every blocked gate
actionable.

## D148 — Measure resource workloads before governing them (Jul 2026)

**Context:** Portavoz already has independent live-transcription, batch-
transcription, intelligence, indexing, sync, durable-processing, and model-
lifecycle owners. Field reports of sluggish recording UI and competing local
model work cannot safely be addressed by adding one global queue: doing so
would collapse the intentional live/batch separation, and collecting meeting,
file, model, or error identities would create a new privacy surface. A resource
governor also cannot choose defensible memory or concurrency policy before the
current workload boundaries are observable.

**Decision:** `PortavozCore` owns one closed workload vocabulary: scheduling
class, resource kind, operation, and terminal outcome. It exposes synchronous,
Sendable, matched-span telemetry with no payload-bearing fields. Application
workflows and capability schedulers classify recording Start/Stop, live and
quality transcription, diarization, intelligence, model prepare/load/release,
indexing, sync, waveform generation, Meeting Detail first projection, media
export, and support export at their existing task or operation boundaries.
`portavoz-app` is the only production recorder and maps those enums to a generic
Points of Interest interval. It records no meeting, transcript, path, model,
span, or error identity.

The process-wide intelligence scheduler receives telemetry through a narrow
relay because providers are created ad hoc; other owners receive it through
normal composition. The existing exact `Meeting Detail First Content` interval
remains available for its established benchmark. No resource instrumentation
enters `AudioCaptureKit` callbacks. This slice observes current behavior only:
it does not add admission, deferral, priority, eviction, residency, or
concurrency policy, and it does not replace any existing scheduler.

**Rationale:** an allowlisted measurement contract makes before/after resource
evidence reproducible while preserving local-first privacy and scheduler
ownership. Measuring application transactions rather than realtime callbacks
keeps capture passive. Separating observation from policy allows later
governor decisions to be justified by field data instead of intuition and
prevents the measurement slice itself from changing product behavior.

## D149 — Resource baselines require a complete multi-host evidence matrix (Jul 2026)

**Context:** matched resource signposts make expensive work observable, but a
single developer-machine trace cannot justify policy for constrained Macs.
Ad-hoc Instruments exports also cannot prove that every scenario was measured
against one release build, that runs were repeated, or that a convenient green
scenario was not substituted for a missing recording-interference case.
Persisting raw intervals, process arguments, paths, or operator notes would
create a new content and identity surface.

**Decision:** one tracked schema declares three hardware profiles—8 GB, 16 GB,
and the reference-memory Mac—and nine required scenarios: idle, recording,
Stop, Refine, summary, Ask, indexing, recording plus indexing, and recording
plus batch work. Every profile receipt is exact-shaped, identifies one Release
version/build/commit, validates installed physical memory against its declared
tier, and contains only OS/hardware/toolchain identity, aggregate process
metrics, and bounded summaries of D148 workload enums. It contains no meeting,
transcript, file, model, span, process-argument, source-path, error, or
free-form operator field.

Each passing cell requires at least three stable runs and every required
workload descriptor. Stability reuses the existing measurement rule: wall or
CPU p95/p50 above 1.25 blocks the cell as unstable. The deterministic evaluator
uses nearest-rank p50/p95, retains peak footprint, minimum free disk, worst
thermal state, power source, and low-power observations, and writes owner-only
JSON and Markdown. Missing, failed, not-observed, under-sampled, and unstable
evidence produces a complete blocking matrix. Malformed existing receipts,
duplicate profiles/runs or JSON keys, build or memory-tier mismatches,
non-finite metrics, unknown enums, and extra fields fail closed. Matrix
completion is measurement evidence, not a resource budget: admission,
deferral, concurrency, eviction, and model-residency decisions remain absent
until the baseline is reviewed.

**Rationale:** policy for call-safe recording must be derived from comparable
evidence across the machines that users actually run. A bounded aggregate
contract keeps long-call artifacts small and private, while a complete blocked
scorecard makes missing hardware work visible without pretending it is a
parser failure. Keeping observation, baseline acceptance, and policy as three
separate steps prevents tooling from silently inventing product limits.

## D150 — Native resource receipts are collected by an isolated Release app (Jul 2026)

**Context:** Points of Interest preserve a useful Instruments view, but
toolchain-specific trace schemas are not a stable receipt format. The existing
recording benchmark also paired `-use-temp-store` with a fresh model directory,
so every repetition could perform model setup instead of measuring comparable
runtime work. Finally, its structured Stop race did not enforce the documented
timeout because task-group scope waits for cancelled children.

**Decision:** the macOS outer layer owns one benchmark-only
`ResourceRunProbe`. It observes the same closed D148 event stream and samples
only aggregate native process/resource state: `proc_pid_rusage` CPU,
physical-footprint, energy, and disk counters; current volume capacity;
`ProcessInfo` thermal and low-power state; and IOKit power source. The Stop
probe is armed first and atomically replays workload spans already active at
the phase boundary; the active-recording metric window then freezes before the
product Stop begins. Boundary spans may drain into the bounded recording
summary while Stop measures them independently. New spans enter only the Stop
probe. A changed power source, unavailable counter,
incomplete lifecycle, output collision, or Stop timeout fails without a
passing sample. Instruments remains optional corroboration, not receipt input.

The canonical resource baseline runner requires a clean worktree, builds one
exact Release version/build/commit, copies and re-signs it under the dedicated
`app.portavoz.mac.resource-bench` identity, and performs at least three runs.
Every run requires a disposable meeting database, scratch audio, process-local
secret storage, and a unique temporary participant-identity root. The
automation composition cannot inspect or mutate the host Keychain, voiceprint,
or participant-voice gallery; production still uses `KeychainSecretStore` and
its durable identity directory. Launch-only work settles for five seconds
before the collector captures a model-free idle window and loads recording
engines. It then measures recording and Stop through the real windowed path and
executes cold-runtime Refine, Summary, Ask, and standalone semantic-indexing
operations in separate processes. Refine uses a fixed English AIFF generated
from public synthetic text, requires the selected Whisper model, tokenizer, and
diarization model to pass full installed-artifact verification before sampling,
and never downloads a model inside the measured window. Summary verifies the
pinned Qwen3.5 MLX descriptor, stores a fixed public English
meeting/cast/transcript only in the disposable database, and measures the real
ApplicationKit regeneration workflow through successful transactional
persistence. Ask requires already-installed Apple Latin embedding assets and
available Foundation Models, then measures the real `AskMeetings.local`
workflow over the same fixed corpus. Its window intentionally includes current
synchronous corpus backfill, bilingual query expansion, hybrid retrieval, and
answer generation; a sample requires citations and nonempty generated text.
Standalone indexing prepares the already-installed embedding assets before
sampling, drains 1,024 fixed public English segments through
`IndexSemanticCorpus`, and requires every row to be embedded or deliberately
excluded before publication. Every bounded Refine, Summary, Ask, and indexing
operation uses the same unstructured first-result race, which enforces a
60–3,600 second timeout even if model work ignores cooperative cancellation.
Refine never applies its draft or persists user-visible content.

Recording plus indexing runs in its own real windowed recording process. It
prepares the same embedding runtime and fixed corpus before measurement, arms a
dedicated probe before product Start, and starts `IndexSemanticCorpus` only
after recording succeeds. Process counters freeze before Stop; the observer
remains installed until Stop closes live-transcription spans that were already
active, admitting their terminal outcomes while rejecting Stop-only work. The
recording stays active until indexing completes or its hard timeout wins, and
the sample is published only after the corpus validation and Stop both succeed.

Recording plus batch runs in another real windowed recording process against
the fixed public non-silent AIFF already used by Refine. It resolves the shared
Parakeet runtime before measurement, starts file transcription through the
production `TranscriptionScheduler.batch` post-capture lane only after Start
succeeds, and keeps recording active until the bounded job returns nonempty
speech or fails. It uses the same freeze-before-Stop boundary and publishes only
after both batch validation and Stop succeed. It deliberately excludes
diarization and summary so the contracted quality-transcription interference
cell remains independently attributable.

Only the hidden recording, recording-plus-indexing, recording-plus-batch,
Refine, and Summary resource benchmarks reuse the normal verified Portavoz
model cache; Ask and indexing rely on OS-managed assets and keep the disposable
model root. Ordinary XCUITest launches retain an empty temporary model root.
Partial fragments and the synthetic fixture stay private and are removed on
failure. Temporary identity state contains no durable secret and remains under
the system temporary root; a validated owner-only host receipt is published
atomically. The original
`resource-recording-baseline` command remains a compatibility alias for the
canonical `resource-baseline` runner. Once any resource benchmark dispatcher
is armed, app initialization returns before normal sync, recovery, provider
discovery, and dictation registration start. The AppKit delegate is not wired
to product services, preventing lifecycle callbacks from starting product work
beside the measured operation. The runner never launches or modifies the
notarized installed app.

**Rationale:** native counters make receipts deterministic and testable without
binding policy evidence to an Instruments export schema. Separating the
database, model, secret, and voice-identity isolation concerns protects user
meetings and enrolled identities while removing model-install noise.
Independent idle, recording, Stop, Refine, Summary, Ask, indexing,
recording-plus-indexing, and recording-plus-batch windows make residency and
interference attribution explicit. One reusable single-scenario probe avoids a
new collector lifecycle for every batch workflow, while the concurrent probe
makes its recording boundary explicit instead of merging Stop cost into the
sample.
Synthetic input keeps model-heavy evidence repeatable and private. Fail-closed
publication prevents a timeout, missing model or OS asset, silent fixture,
failed summary transaction, missing Ask evidence, incomplete index, or partial
run from looking like accepted hardware evidence.

## D151 — MLX inference has an independent explicit scheduler lane (Jul 2026)

**Context:** `MLXModelCache` is an actor, but its generation path awaits model
loading and `ModelContainer.perform`. Actor reentrancy across those awaits does
not establish a single-flight queue, priority policy, or measurable queue
boundary. Routing MLX through the existing Foundation Models scheduler would
solve that ambiguity by coupling unrelated GPU and ANE work, contradicting the
capability-owned scheduler architecture and potentially delaying an
interactive Apple request behind a long MLX summary.

**Decision:** `IntelligenceScheduler` owns two process-wide instances that
share only the content-free D148 telemetry relay. The existing lane serializes
Apple Foundation Models/ANE calls; a second lane serializes embedded MLX/GPU
calls. Each independently applies `interactive > live > background`, FIFO,
latest-wins, and caller-cancellation rules. `MLXSummaryProvider` defaults to
interactive priority for user-driven regeneration and Import. The durable
post-capture provider resolver constructs it with background priority. The MLX
cache remains the verified model/container and idle-release owner; it is not
treated as the queue. Apple and MLX inference never wait on each other's lane.

**Rationale:** explicit, independently observable queues preserve user-facing
priority without inventing cross-capability contention. Keeping the scheduler
policy reusable and the cache focused on model lifetime makes both boundaries
testable under strict concurrency. Shared payload-free telemetry gives the
resource baseline comparable queue and execution evidence without exposing
prompts, model identity, or scheduler keys.

## D152 — Semantic corpus indexing is one ApplicationKit maintenance operation (Jul 2026)

**Context:** Ask and instant Library search both embedded missing transcript
segments, excluded micro-segments, and persisted vectors, but implemented those
rules separately. Ask drained the complete missing corpus before retrieval,
while Library advanced at most 512 rows per query. D149 also requires a
standalone indexing resource cell before any background-indexing or governor
policy can be justified. Measuring a synthetic loop would not characterize the
released persistence and embedding path.

**Decision:** `ApplicationKit.IndexSemanticCorpus` owns semantic backfill with
two explicit entry points: one bounded batch and one complete drain. It accepts
a Sendable embedding capability, validates that every eligible segment receives
exactly one vector before persistence, writes an empty marker for rows shorter
than 20 characters, checks cancellation between fetch, embedding, and storage,
and emits one content-free `maintenance/searchIndex/execute` interval. Ask
retains its complete synchronous drain and Library retains its bounded batch,
so extraction changes no released retrieval behavior. Library continues to own
its process-shared `SentenceEmbedder`; sharing the operation does not imply a
shared model runtime.

The Release indexing benchmark prepares already-installed Apple Latin
embedding assets before measurement, inserts 1,024 fixed public English
segments into a disposable database, runs the complete operation in batches of
256, and publishes no sample unless every row is embedded or deliberately
excluded. The recording-plus-indexing benchmark prepares that same workload
before measurement and then executes it concurrently with the real recording
lifecycle. It neither downloads assets inside the measured window nor reads a
Portavoz model cache for indexing; the recording side reuses only the normal
verified recording models.

**Rationale:** one application-owned operation prevents Ask and Library from
drifting while creating a deterministic, independently measurable seam for
future background scheduling. Preserving caller-specific drain behavior keeps
the slice a Strangler extraction rather than an unmeasured product-policy
change. Embedding residency, background admission, recording interference, and
sqlite-vec remain separate decisions. Recording interference now has a
reproducible collector, but it still requires accepted host baselines before
governor policy can be derived.

## D153 — Microphone authorization precedes every meeting input graph (Jul 2026)

**Context:** the isolated Release resource app reached recording preparation
with a fresh TCC identity and then remained inside
`AVAudioEngine.inputNode`/Core Audio device binding for minutes. The app
previously relied on onboarding to request microphone access, but onboarding
is optional lifecycle state and disposable benchmark launches intentionally
skip it. Task cancellation cannot interrupt a synchronous Core Audio device
bind, and measuring a one-time permission prompt would also contaminate the
recording baseline.

**Decision:** `PlatformKit.MicrophonePermissionClient` owns one deterministic
authorization operation. Existing authorization passes without prompting,
an undetermined grant is requested only from the explicit user-initiated
recording action, and denied or restricted access fails closed. The macOS
recording runtime invokes this operation before constructing
`MicrophoneSource`, enumerating its selected engine route, or starting warm-up.
The isolated windowed resource runner invokes the same operation before any
resource probe is armed, so TCC interaction is preparation rather than measured
work. Onboarding retains its explicit permission control but is no longer a
hidden precondition for recording.

**Rationale:** permission is a platform precondition, not an audio-device
side effect. Resolving it before AVAudioEngine keeps the application boundary
typed, prevents a fresh installation or benchmark identity from entering an
ambiguous hardware path, and makes baseline windows comparable. This decision
does not claim that cooperative cancellation can interrupt a genuinely stalled
authorized Core Audio bind; if that separate field shape reproduces, it
requires its own bounded outer policy rather than a misleading structured-task
timeout.

## D154 — Microphone taps observe route format; they never coerce it (Jul 2026)

**Context:** the repeated 36 GB reference baseline changed the live microphone
route from a 48 kHz format to a 24 kHz AirPods format. The configuration-change
handler read the old output format, then passed it back to
`installTap(onBus:bufferSize:format:block:)` after the hardware had changed.
AVFAudio treats a non-nil tap format as a request to apply that format to the
bus and raised an uncaught Objective-C format-mismatch exception, aborting the
recording process.

**Decision:** the microphone input tap passes `nil` as its requested format,
leaving AVFAudio's current hardware bus unchanged. The callback derives its
native sample rate from each delivered `AVAudioPCMBuffer.format`, validates it,
and resamples to the immutable stream rate before timeline-gap accounting.
Warm-up and restart still reject unusable routes before preparation, serialize
graph mutation, retry absent routes, and preserve one stream and continuation.

**Rationale:** format inspection and route mutation cannot be made atomic across
Core Audio. Avoiding bus coercion removes that time-of-check/time-of-use crash
while retaining native capture, device-switch resampling, and dual-channel
alignment. A pure policy test locks both the nil requested format and dynamic
48 kHz/24 kHz source-rate observation; repeated Release collection remains the
real hardware regression gate.

## D155 — Resource probes require nominal inherited pressure (Jul 2026)

**Context:** two complete 36 GB reference collections executed every contracted
workload, but fixed-order rounds let a previous heavy scenario leave the host
in a fair thermal state when the next probe began. Idle CPU and Ask wall time
then crossed the 1.25 p95/p50 stability limit even though their nominal samples
agreed. Repeating the collection cannot turn a contaminated host into accepted
evidence.

**Decision:** benchmark-only probes wait after scenario preparation and before
opening their metric window until two consecutive thermal observations are
nominal, five seconds apart. The same gate runs after recording engines and
concurrent assets are prepared but before Start. It fails closed after five
minutes. Stop remains immediate because delaying it would change the product
lifecycle being measured.

**Rationale:** inherited host pressure is not attributable to the next
scenario, while thermal pressure created after counters start is part of that
scenario and remains recorded. Centralizing the gate avoids scenario-specific
sleep folklore, preserves cold-process and real-model behavior, and gives 8 GB,
16 GB, and reference receipts one reproducible precondition without weakening
the scorecard's stability threshold.

## D156 — Resource evidence launches the signed app bundle (Jul 2026)

**Context:** recording resource scenarios launched the copied signed `.app`
through LaunchServices, while Refine, Summary, Ask, and indexing executed the
SwiftUI/AppKit Mach-O directly. The exact `666d21d` collection then showed a
correlated third-round slowdown across those independent short processes even
though thermal state remained nominal, AC power was invariant, and Low Power
Mode was off. A raw GUI executable does not reproduce the normal application
launch or resource-management boundary.

**Decision:** every resource scenario launches the same copied, signed,
benchmark-identified application bundle with `open -W -n ... --args`. The
runner retains its disposable storage, content-free evidence, and exact commit
binding. It does not use `taskpolicy`, invent process priorities, or add a
benchmark-only `NSProcessInfo` activity.

**Rationale:** LaunchServices preserves the benchmark environment while
applying the platform's application semantics, bundle identity, and TCC
boundary consistently. This removes a harness asymmetry without changing the
product workload or hiding contention. Product ownership of explicit
user-initiated, background, and latency-critical activities belongs to GOV-1
policy rather than to measurement scaffolding.

## D157 — Resource admission is pure before it is enforced (Jul 2026)

**Context:** Portavoz has a closed content-free workload taxonomy and complete
collectors for nine resource scenarios, but accepted evidence does not yet
exist across the required 8 GB, 16 GB, and reference hosts. Runtime schedulers,
model caches, storage checks, and capture state also expose different platform
types. Encoding policy directly in those owners would duplicate business
rules, make the capture invariant difficult to test, and tempt arbitrary
memory or disk thresholds.

**Decision:** `PortavozCore` owns one synchronous, deterministic, Sendable
`ResourceGovernorPolicy`. It evaluates the existing workload descriptor and an
admission-versus-checkpoint phase against an immutable, content-free snapshot:
capture state/source health, categorical memory tier and disk state, memory and
thermal pressure, resident model families with optional measured footprints,
foreground-action presence, durable backlog, power source, and Low Power Mode.
Its result separates an admission disposition from a stable set of unrelated
idle model families to evict. Deferral conditions distinguish capture,
host-pressure, storage, external-power, and Low-Power-Mode waits; foreground
rejection carries an exact recovery action.

Recording-critical work is admitted after Start enters a protected lifecycle.
Before that boundary only failed input or critical storage rejects capture
preflight. Optional durable work defers or pauses during capture, live work
continues with reduced concurrency under pressure, and heavyweight user model
work waits on a constrained or pressured capture host. Model release remains
admitted under pressure. The policy performs no I/O, process inspection, task
scheduling, model operation, or audio callback work. No application workflow
calls it in this slice, and no numeric memory/disk threshold is encoded.

**Rationale:** a pure decision table makes call-safety and recovery behavior
exhaustively testable without loading a model or probing hardware. Separating
admission from eviction represents the real case where work can proceed only
after unrelated idle models leave memory. A general host/storage/power
deferral is necessary in addition to “until capture stops”; otherwise a
background job facing critical pressure while no recording exists would have
no truthful result. Runtime adapters, model residency, concurrency enforcement,
and measured numeric budgets remain later GOV slices and cannot be inferred
from incomplete GOV-0 evidence.

## D158 — Model residency has a pure lifecycle before runtime ownership (Jul 2026)

**Context:** heavyweight runtime ownership is currently fragmented by
capability. AppServices retains Parakeet, pyannote, and Whisper with independent
load tasks and release generations; IntelligenceKit owns the MLX container and
its timer; Library retains one Apple contextual embedder while Ask creates one
for each retrieval. `VerifiedModelLifecycle` coordinates installation evidence,
not loaded instances. Connecting the resource governor directly to those
implementations would make stale async completions, active-use release, and
resident-model projection depend on five unrelated conventions.

**Decision:** `PortavozCore` owns a synchronous, deterministic, Sendable
`ResourceModelResidencyLedger`. It models the closed heavyweight families as
unloaded, loading, resident, or releasing; tracks active use leases; carries
optional measured footprints; and emits the existing governor resident-model
projection in stable family order. Opaque monotonic tickets fence every load,
use, and release completion. Only an idle resident family may begin release,
and it remains projected as resident until the concrete owner confirms that the
runtime has been dropped. A failed current load returns only that family to
unloaded, while stale or duplicate completions are inert.

The ledger owns no runtime instance, task, timer, provider, model path,
download, checksum, pressure probe, scheduler, or audio callback behavior. It
does not interpret measured bytes or select an idle delay. Application
composition does not yet feed concrete transitions into it, so this decision
changes no product behavior or current cache lifetime.

**Rationale:** the state machine makes coalesced ownership and safe release
characterizable before capability-specific adapters are changed. It gives the
resource governor a truthful, content-free residency projection without moving
model implementations into Core or claiming that verified files equal resident
weights. Separating lifecycle correctness from runtime integration also keeps
arbitrary TTL and memory thresholds out of the code until the physical
resource matrix supplies evidence.

## D159 — Composition owns residency before adapters report it (Jul 2026)

**Context:** D158 defines lifecycle correctness, but constructing ledgers inside
each capability would reproduce the fragmented ownership that GOV-2 is intended
to remove. Immediately wiring the ledger is also unsafe: the shared speech
engines have multiple borrowers, two app workflows bypass the shared pyannote
owner, MLX owns a separate actor cache, and Library/Ask use incompatible
embedding lifetimes. Replacing the existing generation fences before those
paths are locked would make a release race look like a refactor regression.

**Decision:** the macOS `AppServices` composition root owns exactly one
`ResourceModelResidencyLedger` for the process. A source-level characterization
test locks every production app loader, the two direct pyannote paths, the MLX
singleton, both embedding lifetimes, and the existing 600/120/120-second release
fences. It also requires zero ledger transition submissions in this slice.
Concrete runtimes remain in their capability owners; the ledger is not exposed
as user diagnostics while it still reports only its initial state.

**Rationale:** this establishes ownership without publishing false residency or
changing runtime lifetime. The next adapter slice must update the
characterization as it routes one complete family through the ledger, including
load completion, active-use leases, cancellation/failure, and confirmed release.
The test deliberately makes unreviewed new bypasses fail rather than silently
escaping governor ownership.

## D160 — Quality speech pins runtime residency to each operation (Jul 2026)

**Context:** Refine and Import froze or sampled a Whisper descriptor during
preparation, but later transcribed by reading the mutable
`AppServices.whisper` cache. A concurrent operation or Settings variant change
could therefore replace the engine behind an in-flight processor even though
its provider fingerprint still named the original model. D158's ledger could
not become truthful if borrowers and release remained outside the same
lifecycle.

**Decision:** quality speech is the first fully integrated residency family.
`AppServices` coalesces same-descriptor runtime acquisition behind one load
task and submits its exact load success or failure to the process-owned ledger.
Each successful acquisition returns a `WhisperRuntimeLease` containing both
the concrete engine and one active-use token. Load publication and its first
use claim occur in one synchronous MainActor step; a different descriptor is
rejected while that load is active, while same-descriptor joiners each claim
their own token. Refine and Import retain the lease through every transcription
call and end it only at their existing application-owned idle-release hook.
They never re-read the shared mutable runtime after preparation.

An actively leased runtime cannot be released, deleted, or replaced by another
variant. Runtime release is two-phase: the ledger admits only an idle resident
family, AppServices detaches the concrete reference, and the exact release
ticket confirms unloaded state. Rejected confirmation restores the retained
engine and cancels the release transition. Verified model preparation remains
a separate asset lifecycle; the current two-minute idle generation fence is
unchanged, and no download, verification, or release wait enters an audio
callback.

**Rationale:** binding the engine and use token makes provider identity,
execution, and lifetime one invariant instead of three conventions. Migrating
one complete family keeps the Strangler slice reviewable and lets the source
ratchet reject partial or bypassed integration while live speech, diarization,
MLX, and embeddings remain explicitly characterized for later adapters.

## D161 — MLX container mechanics are injected into composition residency (Jul 2026)

**Context:** each `MLXSummaryProvider` reached
`IntelligenceKit.MLXModelCache.shared` directly. The actor serialized access to
its fields, and D151 serialized GPU inference through a separate scheduler,
but neither mechanism reported load/use/release to the process residency
ledger. The static cache also let a future provider bypass application
ownership, and Settings could remove verified assets while a generation still
held their loaded container.

**Decision:** IntelligenceKit replaces the singleton with an injectable
`MLXSummaryRuntimeClient` and concrete `MLXSummaryRuntime` actor. The actor
continues to own `ModelContainer` loading, strict-concurrency `perform`
access, the supported 20 MB MLX buffer-cache limit, and a standalone
two-minute idle policy for the terminating smoke runner. It does not own
application residency truth.

AppServices constructs exactly one production runtime. Its MLX adapter
coalesces an exact standardized verified-directory load behind one
`.languageIntelligence` ticket, publishes the successful runtime and claims
the first use in the same synchronous MainActor continuation, and gives every
manual, Import, and durable post-capture provider a narrow client over that
runtime. The client holds one active-use token through `respondPrepared` and
ends it on every terminal outcome before arming the existing 120-second idle
fence. A competing directory, release, or verified-file deletion is rejected
while load or use is active. Release drops the concrete container and then
confirms the exact ledger ticket.

The independent MLX scheduler remains the only GPU queue and retains
interactive/background priority plus content-free telemetry. Model download
and verification remain in `VerifiedModelLifecycle`; no asset operation,
container wait, or release enters an audio callback. The adapter records no
measured footprint and changes no TTL because those values still require
accepted per-family evidence.

**Rationale:** injected runtime access makes every production provider cross
one reviewable ownership boundary while preserving IntelligenceKit's
capability implementation and D151 scheduling. Publishing load and first use
atomically prevents idle release or Settings deletion from observing an
unleased resident container. Migrating MLX as the second complete family keeps
live speech, diarization, and embeddings explicitly pending instead of
claiming partial governor coverage.

## D162 — Live speech uses pinned runtime leases without gating capture (Jul 2026)

**Context:** AppServices coalesced and cached Parakeet, but recording,
Dictation, durable first-pass recovery, onboarding, and resource benchmarks
borrowed the raw engine without reporting active use. The 600-second release
fence therefore could not distinguish an idle runtime from one executing a
live stream or file transcription. Recording also has a stronger invariant
than the other model families: audio must become durable before a cold model
load can affect startup, and Stop must not wait for a process-owned download or
Core ML compilation.

**Decision:** live speech is the third fully integrated residency family.
`AppServices+LiveSpeechModels` coalesces one verified Parakeet load behind a
`.liveSpeech` load ticket and returns `LiveSpeechRuntimeLease`, binding the
concrete engine to one active-use token. Publication and first-use acquisition
occur in one synchronous MainActor continuation; each joiner receives a
distinct token. Dictation, durable post-capture transcription, onboarding, and
the recording resource benchmark retain and finish leases around their exact
operations.

Recording preparation may acquire only an already-resident lease. The private
runtime starts durable audio first and asks the recording-scoped
`LiveTranscriptionAttacher` to join a cold process load afterward. The attacher
owns an opaque runtime handle until every live channel drains. Stop cancels its
waiter but never awaits the shared load. If that load completes after the
recording is inactive, the attacher ends the returned lease without attaching
captions. Failed source start and cancelled preparation also end any hot lease.

Runtime release is two-phase and accepted only when active use is zero:
AppServices detaches the concrete engine and then confirms the exact ledger
ticket, restoring it if confirmation fails. Verified files remain independent,
the existing 600-second generation fence is unchanged, and no load, release,
verification, or ledger mutation enters an audio callback.

**Rationale:** one pinned engine/use pair makes process residency truthful
without moving FluidAudio types into Core or weakening audio-first startup.
Owning late-load cleanup at the recording attachment boundary preserves fast
Stop while preventing a completed process load from leaking a use token or
publishing into a closed session. Keeping the measured TTL unchanged separates
lifecycle correctness from future resource-policy tuning.

## D163 — Audio-route changes hand off fresh, generation-fenced graphs (Jul 2026)

**Context:** the first route-change repair stopped passing a cached input
format to AVFAudio, but real Tahoe crash reports still showed repeated
`SIGABRT` failures in `AVAudioEngineImpl::InstallTapOnNode` from
`MicrophoneSource.scheduleRestart`. AVFAudio permits only one tap per bus and
raises an Objective-C exception, not a Swift error, when that invariant is
violated. Input/output changes can issue a burst of asynchronous notifications,
and the system process-tap source separately allowed Stop to destroy mutable
Core Audio identifiers while an already queued rebuild was using them.

**Decision:** both capture sources use the same pure
`AudioRouteTransitionGate`. An active capture generation issues monotonically
newer route tickets; delayed work runs only for the newest ticket, and Stop
invalidates all outstanding work before touching a graph.

The microphone configuration callback performs no graph mutation and returns
from AVFAudio's internal queue. After a short settlement delay, the admitted
handoff stops and detaches the old graph, creates a fresh `AVAudioEngine`, and
installs exactly one `format: nil` tap. Unavailable hardware and Swift start
errors retry under the same ticket; a newer route event supersedes that retry.
The stream continuation, original sample rate, elapsed clock, and silence-gap
accounting survive the engine replacement.

`ProcessTapSource` moves initial construction and final teardown onto the same
serial queue that already owns route rebuilding. Output notifications and
liveness recovery request generation-fenced replacement on that queue; a
failed partial graph is destroyed before retry. Stop waits behind any current
mutation, invalidates delayed work, removes the listener, destroys the graph,
and ends the stream exactly once.

**Rationale:** a process-terminating framework precondition must be prevented,
not caught. Fresh microphone graph ownership makes one tap per bus structural,
while one queue plus generation admission makes input/output bursts and Stop
ordering deterministic. The change preserves raw call-safe capture, the
dual-channel timeline, and the audio-first durability boundary; real AirPods
continuity remains an explicit field validation rather than an inferred claim.

## D164 — Diarization reuses model weights, never speaker-session state (Jul 2026)

**Context:** AppServices cached one stateful `PyannoteDiarizer`, while live
recording and participant voice-memory extraction loaded additional one-shot
instances directly. The shared instance retained FluidAudio's mutable speaker
database across operations, so a later meeting could inherit clustering or an
enrolled-identity snapshot from an earlier one. The direct loaders also bypassed
the resource-residency ledger. The verified segmentation and embedding Core ML
models are process-reusable, but the manager that assigns speaker labels is
session state.

**Decision:** speaker diarization is the fourth fully integrated residency
family. `DiarizationKit.PyannoteDiarizationRuntime` retains only the verified
Core ML model pair. AppServices coalesces one process load behind a
`.speakerDiarization` ticket and returns a lease that binds those exact weights
to one active-use token. Publication and first use are one synchronous
MainActor transition; concurrent joiners receive separate tokens and cancelled
joiners return theirs.

Every live meeting, durable post-capture pass, Refine, Import, local-voice
enrollment, and participant-memory extraction constructs a fresh
`PyannoteDiarizer` from the leased weights and destroys that session after the
operation. Identity is sampled into the new session instead of the resident
weights. Durable post-capture additionally carries the exact voiceprint used by
its operation fingerprint into execution, so a concurrent enrollment change
cannot alter already-admitted work. Failed optional preparation or inference
continues to produce honest unattributed speech rather than invented speakers.

Release is two-phase and begins only when active use reaches zero. AppServices
detaches the model pair, confirms the exact release generation, and restores
the retained runtime if confirmation fails. Verified assets remain independent,
the standalone CLI remains short-lived composition, and the existing
600-second release fence is unchanged pending accepted resource evidence.

**Rationale:** separating immutable model residency from mutable meeting state
makes reuse safe and observable without reloading hundreds of megabytes for
each operation. Exact leases prevent release during inference, while fresh
speaker managers prevent cross-meeting contamination and let identity changes
take effect without dropping reusable weights.

## D165 — Library and Ask share one leased semantic embedding runtime (Jul 2026)

**Context:** Library retained one process-long `SentenceEmbedder`, while every
Ask retrieval created and prepared another instance. Both paths already shared
`IndexSemanticCorpus`, but their model lifetime was invisible to the process
residency ledger. Repeated Ask setup wasted loaded state, and neither a future
governor nor resource evidence could distinguish an idle embedding model from
one still indexing or querying.

**Decision:** semantic embedding is the fifth fully integrated residency
family. ApplicationKit defines a narrow `SemanticEmbeddingRuntimeClient` whose
operation closure receives an already-prepared embedding capability.
AppServices owns one `AppSemanticEmbeddingRuntime` actor and injects it into
Library, Ask, and the app resource benchmarks. The actor coalesces construction
and preparation of Apple's Latin contextual model, atomically publishes a
successful cold load and claims its first use, and holds one exact
`.semanticEmbedding` lease across the complete corpus-indexing, query-vector,
and retrieval operation. Load failure returns the exact generation to
unloaded, so a later request can retry.

The pure Core ledger remains platform-free. A lock-protected
`AppModelResidencyLedger` at composition is the sole process owner and lets
main-actor model adapters and the independent semantic actor submit atomic
transitions safely. Library still refuses to request assets while the user is
typing; Ask retains its explicit OS-asset preparation behavior. The CLI owns a
separate process runtime, and standalone scale constructors remain isolated
evidence harnesses rather than application borrowers.

Release is explicit and two-phase: it begins only when active use is zero,
drops loaded model state, and confirms the matching generation without
removing macOS-managed assets. This slice introduces no idle timer. Immediate
governor-requested release is the next policy adapter, and any TTL must come
from accepted per-family evidence rather than a new constant.

**Rationale:** a closure-shaped runtime contract makes preparation, execution,
and lifetime one invariant without exposing a mutable global model. Sharing
one process runtime removes repeated Ask setup, exact leases prevent release
during indexing or retrieval, and the composition-only lock preserves Core's
deterministic architecture while allowing actors with different executors to
report to one source of residency truth.

## D166 — Host pressure releases only idle leased model families (Jul 2026)

**Context:** the pure governor already returned a deterministic idle-family
eviction list and all five heavyweight model families had exact process
residency leases, but the app did not connect macOS pressure to those owners.
Existing delayed release fences could leave hundreds of megabytes resident
after the host reported memory or serious thermal pressure. A one-shot
pressure event could also arrive while a model was active and be lost by the
time its final borrower finished.

**Decision:** application composition installs one content-free
`AppResourcePressureMonitor` over macOS memory-pressure events and ProcessInfo
thermal notifications. It maps only categorical state into
`ResourceGovernorPolicy`, together with the real recording phase and residency
projection. The adapter executes only the policy's stable
`evictIdleModels` output. Admission, deferral, checkpoint, scheduler, and
concurrency decisions remain inactive until accepted multi-host evidence
defines them.

Every requested family releases through its existing concrete capability
owner and generation-fenced two-step transition. Active leases remain an
absolute rejection. `AppModelResidencyLedger` therefore invokes one
composition observer only when a valid final use makes a family idle, and only
after unlocking; AppServices re-evaluates the monitor's current state instead
of retaining a stale release request. Disposable UI-test stores and isolated
resource benchmarks install no platform monitor.

This adapter never enters AudioCaptureKit, waits for recording, deletes model
assets, changes the existing 120/600-second fences, invents a memory threshold,
or records meeting/model/path/error content.

**Rationale:** immediate release responds to actual host pressure without
turning the pure policy into a platform service or moving ownership out of
capability modules. Re-evaluating after the last exact lease closes the
busy-at-notification race, while narrow eviction-only adoption preserves live
and batch scheduler semantics until resource evidence supports broader policy.

## D167 — Protected capture blocks a second Whisper/MLX load on unknown hosts (Jul 2026)

**Context:** Portavoz had exact residency leases and pressure-driven release,
but a Refine/Import Whisper load and a built-in MLX summary load could still
overlap while recording. Production intentionally had no numeric memory-tier
classifier because the 8 GB, 16 GB, and reference-host evidence matrix was not
yet accepted. Checking only before an asynchronous load was insufficient:
capture or the peer model could start while verification or preparation was
suspended. The roadmap also required proof that model download, verification,
and release waits never entered a live audio callback.

**Decision:** application composition mirrors recording phase as one
lock-protected, content-free `ResourceCaptureState`. During starting, active,
or stopping capture, the pure governor treats `.unknown` like a conservative
tier only for the quality-speech/language-intelligence pair. Loading a second
member requests concrete-owner release of an idle peer; a loading peer or a
peer with an active lease defers the load until capture stops. Loading ledger
records count as non-idle governor occupancy but remain non-releasable. Tasks
already active before Start are not interrupted and become releasable only
after their final exact lease closes. The existing constrained-tier policy
remains stricter, and standard/large tiers are unchanged.

Whisper checks this gate before verified preparation, atomically rechecks and
reserves its loading generation immediately before engine loading, and checks
again before residency publication. MLX uses the same atomic
admission-and-reservation step after any prior-runtime release and immediately
before loading, then checks at the publication boundary. The adapter
re-evaluates after executing requested releases, fails if the peer remains,
and rolls back the exact loading generation on rejection. Recording phase
transitions and final-use notifications also reconcile an already-resident
idle pair. The adapter activates no other admission, scheduler, checkpoint,
disk, power, or concurrency decision and defines no RAM or TTL threshold.

Architecture ratchets prohibit verified model lifecycle, model stores,
Whisper, MLX, and their release owners in `AudioCaptureKit`. Verified assets
remain independent from loaded weights and are never deleted by capture
admission.

**Rationale:** a categorical pairwise gate protects audio-first recording now
without claiming unsupported hardware precision. Counting in-flight loads and
atomically joining load admission with its ledger reservation closes concurrent
acquisition races; the preparation and publication checks close suspension
races. Exact-owner release preserves residency invariants, and callback
ratchets keep model I/O entirely outside the real-time capture path.

## D168 — Derive live levels once and publish only the newest snapshot (Jul 2026)

**Context:** `RecordingSession` already scanned every accepted PCM chunk to
produce final peak/RMS media evidence. The app callback scanned the same arrays
again for microphone and system meters, then created one MainActor task per
chunk. Long dual-channel calls could therefore accumulate optional
presentation work even though the durable writer had already completed the
only required operation. A simple display throttle was insufficient because
the low-microphone and missing-system-audio diagnostics must still observe
every chunk.

**Decision:** after durable append, `RecordingSession` derives one compact
`PersistedAudioLevel` in its existing PCM scan and emits it through the
StartRecording callback boundary. The app submits each value synchronously to
one recording-scoped, lock-protected state machine. Every submission updates
the complete diagnostic state in O(1), while one latest-value slot retains the
newest snapshot and schedules at most one MainActor delivery per 50 ms. Stop,
failed Start, and reset cancel the relay; cancellation advances its generation
and rejects all scheduled or late callbacks from that session.

The meter may discard only obsolete presentation snapshots. Durable audio,
capture-health events, bounded live-transcription feeds, and final transcript
evidence retain their existing independent contracts. The app no longer scans
audio arrays or schedules one actor task per chunk, and no optional consumer
can backpressure the writer.

**Rationale:** one persisted-evidence pass removes redundant O(samples) work
from the presentation layer, while a generation-fenced latest-value relay
bounds actor pressure regardless of call duration. Separating complete
diagnostic ingestion from coalesced rendering preserves field warnings without
pretending every intermediate meter frame has product value.

## D169 — Wake live translation from state changes and bound every batch (Jul 2026)

**Context:** the active Apple Translation lane woke the MainActor every 300 ms
even when no caption, consent, or language state had changed. When work did
exist, one framework request could include every eligible row in the 60-row
live lookback. That permanent poll spent optional work throughout a recording,
while a large catch-up request delayed its earliest visible result and reduced
the number of cancellation boundaries available to a source/target change.
Returning from an idle lane was not safe because SwiftUI does not restart a
`translationTask` when a new caption produces the same source/target
configuration.

**Decision:** application composition owns one recording-scoped
`LiveTranslationWakeHub`. It broadcasts caption, live-speaker, target, source,
pair-consent, and unsupported-passthrough changes to current lane subscribers.
Each `AsyncStream` subscriber uses `bufferingNewest(1)`: signals carry no
content and mean only "recompute from current controller state." Idle,
download-gated, and unsupported lanes suspend on that stream. Preparation and
translation failures retain their two- and three-second retry backoffs,
respectively; successful or idle work has no timer.

`LiveTranslationRouting` retains its explicit recent-context policy of 60 rows
and admits at most eight chronological rows to one framework batch. A
successful response loop immediately requests the next bounded batch.
Source/target equality remains checked before every request and publication,
and task cancellation still fences an obsolete lane. Older untranslated rows
that age out of the live window remain in their spoken language instead of
forming an unbounded catch-up queue. The wake hub never carries transcript
text, owns durable evidence, delays capture, or changes Refine.

The recording stress and deterministic language gates include the wake relay,
consent integration, bounded routing, pair fencing, unsupported progression,
and mixed-language state tests. Architecture coverage rejects restoring the
300 ms idle poll, removing the one-wake buffer or bounded batch, and dropping
the relay from those release gates.

**Rationale:** a latest-state signal is the correct abstraction because every
wake invalidates the same derived routing snapshot; preserving a signal per
caption would add queue pressure without preserving additional truth. Small
batches improve first-result latency and cancellation responsiveness while the
existing source revision map provides exact idempotency. Keeping the spoken
transcript and durable audio outside this optional lane preserves Portavoz's
audio-first and multilingual-source contracts.

## D170 — Bound complete live Apuntador generation per recording (Jul 2026)

**Context:** each accepted live question created an unowned MainActor wrapper
task around the complete Apuntador operation. The `IntelligenceScheduler`
latest-wins key bounded only the classifier call inside that operation; BYOK
resolution, answer generation, and result delivery remained outside one
recording-scoped owner. A long call could therefore retain multiple obsolete
wrappers, and opt-out, reset, or Stop prevented stale publication without
stopping the model work that occupied shared inference capacity.

**Decision:** application composition owns one
`LiveCompanionWorkCoordinator` per `RecordingController`. It admits one active
complete `ProvenanceCompanion.generate` request and retains one newest pending
candidate. Submitting another candidate replaces only the not-yet-started
request; an active answer may finish without being preempted by ordinary turn
traffic. The existing Intelligence scheduler continues to own classifier and
answer priority, while the coordinator owns recording lifecycle and overflow.

Opt-out, reset, next-session, and Stop clear the pending slot and cancel the
worker. The worker checks cancellation after generation and before result
delivery, so a provider that ignores cancellation cannot publish obsolete
content. A request submitted for a fresh lifecycle while the cancelled
generator unwinds remains in the one pending slot and starts only after the
old worker exits. This preserves the one-active invariant instead of hiding
overlap behind cancellation. Accepted visible cards remain unlimited user
history; only ephemeral in-flight work is bounded.

The recording stress and deterministic release gates include the pure
turn-endpoint policy plus coordinator overflow, cancellation, and opt-out
integration tests. Architecture coverage rejects reintroducing a request
array, per-turn wrapper task, lifecycle cancellation gap, or release gate that
omits these tests.

**Rationale:** one active answer plus the newest waiting question preserves
useful conversational continuity while bounding memory, tasks, and model
pressure independently of meeting duration. Separating deterministic endpoint
admission, ephemeral lifecycle coordination, and scheduler execution keeps
each policy testable and prevents optional intelligence from delaying capture
or Stop.

## D171 — Wake live summary from evidence and bound each complete cycle (Jul 2026)

**Context:** the optional Foundation Models live summary ran a permanent
40-second MainActor loop for the whole recording. A successful tick selected
every unseen closed row, so a long outage could turn the next request into an
unbounded map step. The operation also appended its condensed note and advanced
the processed-row cursor before note collapse and final summary reduction had
succeeded. Cancellation or a later provider failure could therefore retain
partial internal state even when no coherent summary was published.

**Decision:** application composition owns one
`LiveSummaryWorkCoordinator` per `RecordingController`. Closed caption rows,
late live-speaker splits, and context-note changes set one pending invalidation
bit. The coordinator permits one active complete cycle, collapses any burst
into one later cycle, and enforces the established 40-second minimum cadence
without an idle poll.

`LiveSummaryWindowPolicy` admits the oldest unseen closed rows up to 32 rows
and 6,000 characters per cycle. The oldest row is admitted alone when it
exceeds the character budget, guaranteeing forward progress. A successful
cycle reports retained backlog so another bounded pass is scheduled. A failed
provider call leaves the cursor unchanged and waits for the next evidence
signal rather than retrying forever during an outage.

Condensed notes, processed row identities, and the visible summary are built as
candidate state. They publish atomically only after map, optional note
collapse, and reduce all succeed and the task still belongs to the same active
recording. Cancellation is checked after every model suspension. Reset,
next-session, and Stop clear pending work and cancel the worker. Automatic
objective checks share the bounded cycle, remain Apuntador-gated, and reject
late cancelled detector results before mutating presentation state.

The recording stress and deterministic release gates include coordinator
burst, overflow, backlog, cancellation, and window-policy tests. Architecture
coverage rejects restoring the timer loop, removing row/character budgets,
advancing candidate state before complete success, omitting lifecycle
cancellation, or dropping these suites from the reliability gates.

**Rationale:** summary invalidations describe newest observable state, not
independent work that must queue. One pending bit and bounded oldest-first
batches cap tasks and model input independently of meeting duration, while
atomic publication prevents partial progress from stranding evidence. Keeping
durable captions and final post-capture processing outside this optional path
preserves the audio-first contract.

## D172 — Admit generated intelligence after execution, not by string shape (Jul 2026)

**Context:** bounded schedulers and recording-scoped coordinators cap work, but
they do not make model output semantically idempotent. In a July 30 field call,
the open form and later close of one growing question produced multiple
successful Apuntador generations and near-duplicate, sometimes contradictory
cards. The same meeting showed decisions repeated as action items because one
rendering carried a speaker prefix while the other carried that identity in
the typed owner field. Foundation Models also transformed one spoken question
into every-word title case.

**Decision:** generated intelligence crosses a deterministic last-mile
admission boundary. `PortavozCore.CompanionCardAdmission` treats overlapping
question-segment identities as one source-turn lineage. When evidence
identities differ because adjacent live captions split, a 12-second lexical
fallback may establish equivalence only with enough distinctive tokens, very
high containment, and matching negation polarity. The more complete card
replaces the weaker card and its card-keyed artifact; a weaker candidate is
discarded. Exact wording outside the live window remains a later independent
question.

IntelligenceKit instructs question cleanup to use normal sentence case and
repairs only long outputs that overwhelmingly capitalize every word,
preserving the configured owner's name and common technical acronyms. It never
rewrites source transcript text. Summary action admission compares
attribution-independent statement bodies, so `S2: "Use X"` and `"Use X" — S2`
cannot become both a decision and a task. Provider instructions independently
require concrete future commitments or assigned next steps and permit an empty
task set.

**Rationale:** execution bounds protect performance while semantic admission
protects what users see and persist. Source lineage is stronger than generated
wording, lexical fallback must be narrow enough not to collapse repeated later
questions, and deterministic task semantics remain testable across every local
or BYOK provider. Presentation repair belongs after generation, never in the
spoken record.

## D173 — Treat live clipping as evidence, not gain control (Jul 2026)

**Context:** a July 30 field recording completed successfully but its system
channel reached 0 dBFS and the live transcript was visibly inaccurate. Final
per-file peak evidence can diagnose the meeting only after Stop. Detecting this
condition from callback counts would also be route-dependent because Core Audio
buffer sizes can change across built-in devices and AirPods.

**Decision:** the compact `PersistedAudioLevel` emitted by the durable writer
pass includes the accepted chunk duration. One recording-scoped,
constant-space detector accumulates sustained system-channel ceiling exposure
with hysteresis and measures policy thresholds in captured seconds rather than
callback count. The latest-value relay publishes the resulting transition with
the existing 20 Hz presentation snapshot. A dismissible warning explains the
live-transcript quality risk.

The detector does not rescan PCM, delay durable append, apply gain, alter the
call graph, rewrite audio, or suppress transcript rows. Invalid or zero
durations do not advance the policy, and each observation is bounded before it
changes exposure. Unit coverage proves that an isolated ceiling peak is
ignored, sustained exposure enters the warning, clean audio exits it, and
cancellation still fences delivery. Scoped bilingual XCUITest uses only the
compact level seam and proves visible copy plus dismissal.

**Rationale:** Portavoz can honestly surface damaged input without becoming an
unverified live audio processor. Captured time keeps the result stable across
route-specific buffer sizes, while same-pass compact evidence preserves the
audio-first boundary and makes future thresholds deterministic and testable.

## D174 — Bound live caption derivations, not transcript evidence (Jul 2026)

**Context:** `RecordingController` must retain the complete admitted caption
history until Stop because durable snapshot persistence, explicit recovery,
Refine, translation cursors, and generated-evidence provenance depend on it.
The live carousel was already limited to 150 source rows, but only at one
SwiftUI call site. The five-minute talk-balance cue still scanned every closed
row in the meeting on each presentation update.

**Decision:** the pure `LiveCaptionParagraphProjector` owns a 150-source-row
tail before it groups visible paragraphs and translations. Callers pass the
authoritative caption array without reimplementing that limit.
`LiveTalkTimePolicy` independently owns a maximum of 1,024 closed candidate
rows before applying its existing five-minute time filter. The newest growing
row remains excluded. These limits affect only ephemeral presentation
derivations; they do not truncate, reorder, or rewrite controller captions,
final audio, Stop payloads, translation state, summary cursors, or Refine
inputs.

**Rationale:** presentation work now remains constant with meeting duration
without weakening the audio-first durability contract. At the current
approximately one-final-row-per-second cadence on each of two channels, 1,024
closed candidates leave substantial headroom above the roughly 600 rows
expected in five minutes. Owning both bounds inside pure tested policies
prevents a future caller from accidentally restoring a whole-meeting scan.

## D175 — Cancel obsolete waveform derivation by route (Jul 2026)

**Context:** D84 made waveform generation stateless and fast, and Meeting
Detail already requested 600 buckets with an inline 2,000-bucket clamp.
However, preparation launched the complete file scan in an unstructured
detached task. Cancelling the SwiftUI route rejected its result only after that
task had finished. Leaving and quickly reopening a long meeting could therefore
run overlapping obsolete reads over the same finalized channels even though
neither result was durable evidence.

**Decision:** `MeetingWaveformDeliveryPolicy` owns the presentation contract:
600 buckets by default and at most 2,000 in one immutable published snapshot.
`AudioPlaybackKit.Waveform.generateCancellable` checks the caller before
starting, propagates later route cancellation into its off-main worker with a
task cancellation handler, and checks again before and after every fixed-size
read of at most 65,536 frames. Cancellation throws and publishes no partial
waveform. ApplicationKit retains the existing content-free workload interval
and installs the player, silence ranges, and waveform only after the complete
derivation survives the route fence.

The generator still reads the complete finalized system and microphone
timelines. It does not cache, rewrite, attenuate, truncate, or delete either
file, and it does not enter capture callbacks. D84's exact range-aligned
Accelerate envelope and replacement-sensitive benchmark remain unchanged.

**Rationale:** task lifetime was the remaining unbounded resource, not array
size or audio fidelity. A route-scoped cancellation boundary prevents obsolete
whole-file IO from accumulating during review navigation while preserving the
stateless design and the finalized recording as the authoritative evidence.

## D176 — Share one bounded semantic-indexing flight (Jul 2026)

**Context:** D152 extracted one semantic-corpus indexing operation and D165
gave Library and Ask one process-owned embedding runtime. The two surfaces
still constructed separate `IndexSemanticCorpus` values. Since actors are
reentrant, overlapping Library typing and Ask retrieval could read the same
durable missing rows, embed them twice, and contend to persist equivalent
vectors. A general request queue would merely move that duplication into an
unbounded maintenance backlog.

**Decision:** app composition owns one
`SemanticCorpusIndexingCoordinator` actor and injects it into Library and Ask.
The coordinator admits one active backfill task. Library requests at most one
bounded batch and coalesces when any flight or complete demand exists. Ask
joins an active bounded flight, then drains all still-missing rows before its
released hybrid retrieval; concurrent complete callers join the same drain.
A scalar complete-demand count prevents new bounded work from cutting between
those stages. The coordinator retains only the active task and waiter
identities, never a pending-request array.

Cancelling one waiter preserves work still borrowed elsewhere. Cancelling the
last waiter cancels the worker, and `IndexSemanticCorpus` checks cancellation
after embedding and before persistence. Coalesced Library requests lose no
evidence because missing embeddings remain durable `NULL` rows and are
rediscovered by a later pass. Exact FTS publishes independently and neither
schema-v7 Float32 BLOB storage nor exact-cosine ranking changes.

**Rationale:** one flight bounds duplicate CPU, memory, database, and model
work without turning search into a lossy queue. Durable missing-row state is
the retry ledger, so coalescing an opportunistic signal is safe while Ask's
complete contract remains intact. Background indexing and resource-governor
checkpoint admission remain separate slices rather than hidden policy inside
the coordinator.

## D177 — Pause semantic maintenance at durable capture checkpoints (Jul 2026)

**Context:** D157 already states that optional maintenance defers while capture
is protected and pauses only after a durable checkpoint. D176 bounded semantic
backfill to one process flight, but `IndexSemanticCorpus` still started and
drained batches without consuming that policy. Cancelling the flight on Start
would conflate expected suspension with failure and could discard expensive
vectors before their safe persistence boundary. Adding a retry queue or timer
would duplicate ownership already represented by the database.

**Decision:** ApplicationKit owns a reusable `DurableMaintenanceGate` that
accepts the existing content-free workload descriptor and an
admission/checkpoint phase. `IndexSemanticCorpus` evaluates admission before
its first storage read. A complete drain evaluates a checkpoint after every
persisted bounded batch and before fetching another. Policy suspension is a
successful, explicit `pausedByPolicy` result rather than cancellation or
failure.

D179 later promotes this capability-neutral value to PortavozCore so
IntegrationsKit can consume the same contract without a reverse dependency.

The macOS composition root builds the gate from
`AppResourceCaptureState` and the pure `ResourceGovernorPolicy`. Starting,
active, and stopping capture pause semantic maintenance; inactive capture
admits it. This first adapter supplies neutral or unknown host dimensions and
therefore activates no unmeasured RAM, disk, thermal, battery, concurrency, or
scheduler threshold. CLI, isolated benchmarks, and direct use-case composition
retain an explicit unrestricted default.

An already-admitted batch completes and persists its vectors or empty
micro-segment markers atomically before yielding. Remaining `NULL` embedding
rows are the durable job cursor across later requests and process relaunch.
Library exact FTS remains independent. Ask continues with lexical and
already-indexed semantic evidence when backfill pauses instead of surfacing an
expected resource decision as an error. No polling loop, pending request array,
new schema, vector rollback, or audio-callback work is introduced.

**Rationale:** capture receives immediate priority at the next proven durable
boundary while semantic work retains exact ownership and resumability. The
narrow gate makes the policy executable without coupling ApplicationKit to app
state and is reusable for later sync, graph, and export checkpoints. Moving the
complete drain off Ask, wake-on-capture-stop scheduling, durable leases and
heartbeats, and non-capture host adapters remain separate GOV-4 slices.

## D178 — Resume semantic maintenance from process signals (Jul 2026)

**Context:** D177 made semantic backfill yield safely during protected capture,
but remaining `NULL` rows resumed only when a later Library search or Ask
request happened to request indexing. That left corpus maintenance coupled to
foreground user latency. A periodic worker would waste wakeups, duplicate the
database's durable state, and risk rebuilding model pressure during a call.

**Decision:** the macOS composition root owns one
`SemanticCorpusIndexingSupervisor`. App launch, searchable mutations, and the
capture mirror returning inactive call its idempotent wake method. One drain may
run at a time. Any number of signals received while it runs collapse into one
subsequent drain, represented by a scalar bit rather than a request queue. The
supervisor has no timer, sleep, polling loop, or retry schedule.

D200 later adds one cancellable future wake derived from persisted retry or
lease-expiry evidence; it does not add polling or weaken this signal contract.

The production background adapter first checks cancellation and protected
capture, then queries at most one missing embedding row. It borrows the shared
semantic runtime only when work exists and Apple's Latin contextual embedding
assets are already installed. Background work always passes
`allowAssetDownload: false`. Temporary stores and isolated benchmark
composition disable the owner. The existing D177 gate remains authoritative
inside each indexed batch and can pause a drain that was admitted before
capture changed.

Ordinary failure is logged without meeting content and leaves missing rows
untouched. The next explicit signal or process launch retries from those
durable rows; no volatile retry ledger is needed. Ask keeps its released
synchronous complete-drain behavior for compatibility so a request sees the same
semantic completeness as before. Moving that drain entirely behind the
background owner requires separate measured parity evidence.

**Rationale:** explicit lifecycle and mutation signals make semantic recall
self-maintaining without permanent process activity. One process owner, one
shared coordinator, and one SQLite cursor keep concurrency and recovery
bounded while capture remains the highest-priority workload and background
maintenance cannot surprise the user with an asset download.

## D179 — Checkpoint existing-library sync around protected capture (Jul 2026)

**Context:** the explicit “include existing library” action persisted its
request and then marked every meeting in one StorageKit transaction before
starting a manually driven CloudKit cycle. Large libraries could therefore
compete with protected capture, and the operation had no durable intermediate
boundary. A single transaction also hid a two-store recovery problem:
meeting-journal admission lives in SQLite while account-scoped transport
progress lives in a separately protected IntegrationsKit snapshot. A crash
between those stores must never skip a meeting or create an extra generation
each time the same batch is retried.

**Decision:** PortavozCore owns the capability-neutral
`DurableMaintenanceGate`; D177's ApplicationKit operation and the
IntegrationsKit seed coordinator both consume it. The macOS composition root
continues to build the gate from `AppResourceCaptureState` and the pure
`ResourceGovernorPolicy`. The sync descriptor is maintenance/library-sync
execution. Starting, active, and stopping capture return `pause`; inactive
capture returns `proceed`.

The explicit action first persists account-scoped seed intent and does no
library work inside that state mutation. StorageKit then marks meetings through
`markMeetingsForInitialSync(after:limit:)`, ordered by opaque UUID identity.
Each bounded batch is one transaction and returns its final identity plus
completion state. A row whose generation is already pending remains at that
generation; a fully acknowledged row receives a new generation. Deletion state
and the newest change time remain current. Invalid limits fail closed.

IntegrationsKit persists the SQLite batch first and only then advances its
protected cursor. A crash in that window replays the same batch idempotently
instead of skipping it. A separate prepared marker proves that the complete
library has entered the journal before seed completion may consider the journal
and protected attempts drained. Duplicate requests for the same account do not
reset cursor, prepared state, or completion. The optional cursor and prepared
fields preserve format-v1 decoding; an older requested snapshot safely
re-admits pending rows before continuing.

The coordinator evaluates admission before the first storage read and a
checkpoint after every committed batch, including the final batch before any
transport driver is constructed. Work already inside a transaction commits;
the next batch pauses. AppServices emits one content-free wake when capture
returns inactive, and `MeetingSyncModel` requests a cycle only when sync is
enabled and a seed remains explicitly requested. Relaunch and ordinary manual
sync also resume from the protected cursor. There is no timer, sleep, polling
loop, volatile retry queue, lease, heartbeat, new SQLite schema, or audio
callback work.

This gate applies only to explicit existing-library admission. Ordinary
future-change delivery keeps its released behavior; the decision does not claim
that all CloudKit transport pauses during recording.

**Rationale:** bounded, idempotent checkpoints give capture immediate priority
at a proven commit boundary while preserving the user's opt-in across crashes,
relaunches, and account-scoped transport recovery. Promoting the generic gate
to Core avoids an IntegrationsKit-to-ApplicationKit dependency, and using the
two existing durable stores is simpler than introducing a third job ledger.

## D180 — Defer whole-library backup before its coherent snapshot (Jul 2026)

**Context:** D99 intentionally reads meeting identities and every strict
meeting aggregate inside one `DatabaseQueue.read`, then renders and publishes
the complete Markdown backup. Starting that work during protected capture can
compete for SQLite, memory, CPU, and filesystem bandwidth. Pausing after the
read is not a safe incremental fix: it would retain a content-heavy copy of the
whole library during the call, while discarding it and rereading per meeting
would combine different database moments. Child-row mutations also do not
provide one aggregate-wide revision fence that could prove a split read is
equivalent to D99.

**Decision:** `ExportLibraryMarkdownBackup` is a maintenance/media-export
workload and consumes the shared `DurableMaintenanceGate`. It checks admission
before the source snapshot and returns a typed `suspended` execution outcome
without reading storage, inspecting the destination, rendering Markdown, or
publishing files. Successful work continues to use the unchanged D99 one-read
snapshot and atomic filesystem adapter.

`LibraryMarkdownBackupModel` owns one process-scoped pending destination. A
suspended request remains in the preparing state, and AppServices notifies the
model when capture returns inactive so it retries without reopening the folder
picker. The actor serializes execution, and a scalar resume bit remembers a
capture-stop signal that arrives while admission is still resolving. Completion
or failure clears pending ownership.

This decision does not checkpoint an export after admission and does not make
backup execution relaunch-durable. If capture starts after the coherent source
snapshot begins, that export finishes. Intra-export pause requires a separate
bounded durable-staging design with destination recovery, collision
reservation, cleanup, privacy, and restart semantics.

**Rationale:** an admission checkpoint removes avoidable backup interference
from calls without weakening D99 consistency, holding a complete library while
waiting, or introducing a polling task and volatile retry queue. Retaining the
chosen destination gives the user automatic recovery after Stop while keeping
the limitation explicit for the next GOV-4 slice.

## D181 — Checkpoint whole-library backup through one immutable SQLite stage (Jul 2026)

**Context:** D180 defers backup before the coherent D99 source read, but an
admitted export still loads the complete library into Swift memory and finishes
even when protected capture starts. Reading each meeting independently from the
live database would reduce memory but combine different database moments,
weakening backup consistency.

**Decision:** StorageKit copies the live database into one private transient
SQLite workspace with GRDB's bounded backup API. Copy progress is checked after
each 256-page group. If capture closes the maintenance gate, the partial stage
is removed and preparation returns a typed suspension. The stage root and
workspace are owner-only, the staged database is `0600`, and the root is
excluded from backup. Schema v16 adds a partial
`meeting(startedAt DESC, id ASC)` index for live roots; because the index is
part of the coherent copy, staged iteration can use a stable keyset cursor
without repeated offset scans.

After a complete copy, a stage session reads one live meeting aggregate at a
time in `startedAt DESC, id ASC` order. Later live-database mutations cannot
change the export. Corrupt required aggregates remain typed per-meeting
failures, while optional General-summary corruption degrades to no summary as
before.

`ExportLibraryMarkdownBackup` is an actor that owns one active run. It checks
the shared maintenance gate before each staged read, after loading one
aggregate, after rendering one document, and after atomic publication. A
suspended run retains its stage cursor, filename allocator, typed results, and
at most one pending aggregate or rendered document. Publication is the commit
point, so resume does not rerender or republish completed meetings.

Normal completion and failure close and remove the stage. This decision is
process-local: it does not persist destination authorization, collision
reservations, a publication manifest, or ownership needed to adopt an
abandoned stage after app termination.

**Rationale:** one immutable on-disk stage preserves a coherent library moment
while bounding live-database contention and in-memory content. Explicit
checkpoints let recording take priority without duplicate publication, polling,
or a second durable-work ledger. Relaunch-safe destination and stage recovery
remain separate work rather than being implied by process-local suspension.

## D182 — Prove backup-stage abandonment with kernel ownership (Jul 2026)

**Context:** D181 removes a stage during normal completion and failure, but
`SIGKILL`, a crash, or power loss can leave its private SQLite copy in the
temporary directory. Deleting every directory at the next launch is unsafe:
the release app, Dev app, or another process instance can still own an active
export. A PID file can be reused, an age threshold guesses at ownership, and a
heartbeat would add background work while still requiring a stale-time policy.

**Decision:** every current-format stage holds an exclusive BSD `flock(2)` on
an owner-only `.owner.lock` file for the full workspace lifetime. Stage
creation and scanning also share a persistent root coordination lock so a
scanner cannot observe a newly created directory before its owner lease exists.
The coordinator file remains at the root; unlinking a lock file after release
could let concurrent processes synchronize on different inodes.

At process launch, the process-owned backup model asks StorageKit to scan at
utility priority. Cleanup opens a regular, non-symlink owner file with
`O_NOFOLLOW` and removes the workspace only when it can take a nonblocking
exclusive lock, proving that no live owner retains the open-file-description
lease. Active workspaces, symlinks, malformed entries, and legacy lockless
directories are preserved fail-closed. Disposable test composition does not
scan the host root. The scan contains no meeting content, path logging, timer,
PID heuristic, or heartbeat.

This establishes crash-safe ownership and cleanup only. It does not persist a
destination security-scoped bookmark, reserve destination names, record atomic
publication in a manifest, or adopt and continue a stage after relaunch.

**Rationale:** the kernel releases `flock` ownership when a process exits, so
abandonment is immediate and deterministic without guessing elapsed time.
Root serialization closes the only creation/cleanup race, while fail-closed
shape validation protects concurrent and older Portavoz installations. Keeping
adoption separate avoids claiming relaunch durability before publication can
be made idempotent across its move/manifest crash window.

## D183 — Retain backup destination identity, not open access (Jul 2026)

**Context:** D181 retains an in-process backup run across capture-policy
suspension, but it retains only the originally selected destination URL. A URL
does not preserve filesystem identity when the directory moves, while holding
security-scoped access for an arbitrarily long suspended interval would leak a
bounded kernel resource. The current hardened-runtime app does not adopt App
Sandbox, so describing its access as security-scoped would also be inaccurate.

**Decision:** ApplicationKit owns an opaque destination-bookmark value and a
destination-access port. The port prepares identity only after maintenance
admission and coherent source staging, then acquires one destination lease for
the current execution interval. The use case inspects and publishes through
the lease's resolved URL, refreshes the retained bookmark when resolution marks
it stale, and closes the lease on every completion, suspension, and error path.
Resuming a process-local run reacquires from the retained identity instead of
requesting the folder again.

PlatformKit implements the current adapter with a regular Foundation bookmark
created using `withoutImplicitSecurityScope`. Focused filesystem evidence
proves that identity follows a directory rename on the current macOS target.
The app lease is intentionally a no-op resource boundary today because the app
is not sandboxed. A future App Sandbox composition may replace only that
adapter with balanced `startAccessingSecurityScopedResource()` and
`stopAccessingSecurityScopedResource()` calls; ApplicationKit and the backup
workflow do not change.

This decision does not persist bookmark bytes, the filename allocator,
publication results, or an atomic manifest. Process termination therefore
still cannot adopt the staged source or continue publication safely.

**Rationale:** durable identity and bounded access are separate concerns. A
regular non-implicit bookmark accurately matches the current entitlement
model, while an explicit lease prevents today's process-local workflow from
normalizing unbounded access and gives a future sandbox adapter one auditable
place to balance capability lifetime. Keeping persistence and the
move/manifest crash window for the next slice avoids a false relaunch-resume
claim.

## D184 — Journal backup publication before and after the atomic move (Jul 2026)

**Context:** D183 retains destination identity only inside the active actor.
Even after persisting bookmark bytes, an app termination between moving a
complete Markdown document into the destination and recording that move would
leave the next process unable to distinguish “publish again” from “already
published.” Persisting rendered Markdown in a work ledger would duplicate user
content and enlarge the private recovery surface.

**Decision:** every staged backup exposes the UUID already used by its private
workspace. ApplicationKit uses that UUID as the recovery-operation identity
and owns a narrow `LibraryMarkdownBackupRecoveryStore` port. Before publishing
each rendered document, the workflow atomically saves one exact pending record:
meeting identity, allocated portable filename, SHA-256, and byte count. After
the no-replacement atomic move succeeds, it appends that record to completed
publications and clears the pending reservation. Small operation metadata also
stores the regular destination bookmark and an active/completed phase. The
journal stores no transcript, summary, or rendered Markdown bytes.

The macOS adapter writes version-1 JSON under one owner-only UUID operation
directory in
`Application Support/Portavoz/LibraryMarkdownBackupRecovery`. Metadata and one
pending record are atomically replaced; successful completion moves that
pending record atomically into an immutable sequence-named `completed`
directory. This keeps steady-state work O(1) per document instead of rewriting
the growing manifest after every meeting. Each record is capped at 1 MiB, all
directories/files are private, and the root is excluded from backup. Loading
and deletion reject symlinks, malformed or oversized records, unknown
versions, noncontiguous sequences, invalid publication metadata, and
operation-ID mismatches. Disposable composition uses a unique temporary root.

The atomic move remains the publication commit point. A recovery-save failure
after that move records the published result and exact pending journal
completion in process memory before surfacing a stable fatal error. Retry
finishes that journal transition before reading or publishing another document
and therefore cannot publish the same document twice. A refreshed bookmark is
persisted before replacing the actor's bookmark; failed publication clears its
reservation before recording the typed failure. Terminal completion and
source-read failure retain explicit process-local intent: retry removes the
journal before closing the stage and does not reacquire a destination that is
no longer needed. Storage cleanup now accepts only canonical lowercase
UUID-named current-format workspaces and returns the exact IDs it proved
abandoned. App launch removes only matching recovery documents, preserving
active, noncanonical, malformed, and unknown work fail-closed.

This decision persists evidence needed to reconcile the move/manifest crash
window but does not perform that relaunch reconciliation yet. The SQLite
stage's keyset cursor and any pending rendered document remain process-local,
and launch still discards an abandoned stage plus its matching journal instead
of adopting them.

**Rationale:** reservation-before-move and completion-after-move establish the
minimum auditable publication protocol without copying meeting content into a
second durable store. Exact UUID cleanup keeps stage and journal lifecycles
aligned. Keeping source-cursor persistence and stage reopening for the next
slice avoids claiming end-to-end relaunch resume before every boundary is
actually adoptable.

## D185 — Reopen only an exact staged source at an exact keyset cursor (Jul 2026)

**Context:** D184 makes destination publication observable across a crash, but
StorageKit still exposes only a process-local stage actor. Adding application
relaunch orchestration before the immutable SQLite source can be reopened
safely would force launch code either to trust a path, restart from the
beginning, or delete evidence it cannot validate. Persisting a meeting title,
transcript, summary, or rendered document merely to locate the next row would
also enlarge the private recovery surface without being necessary.

**Decision:** the immutable backup stage exposes a content-free keyset cursor:
the exact `startedAt` value and raw staged record identity already used by its
`startedAt DESC, id ASC` traversal. StorageKit provides one adoption operation
for a canonical stage UUID and optional cursor. It coordinates through the
existing root lock, requires the workspace, owner file, and `source.sqlite` to
be expected non-symlink shapes, and acquires the owner lease nonblockingly
before opening the database read-only. Active ownership or a missing workspace
returns unavailable. Malformed shapes, an unreadable database, a nonfinite or
empty cursor, and a cursor that does not match exactly one live staged row fail
closed without deleting the workspace. An adopted stage continues strictly
after the validated cursor and retains the existing close/removal lifecycle.

The application recovery contract does not persist this cursor yet, and the
launch path does not invoke adoption. Pending-publication digest reconciliation
also remains absent. Consequently this decision adds the safe storage primitive
needed for relaunch continuation but does not claim that backups now resume
after app termination.

**Rationale:** a narrow, validated adoption primitive separates filesystem and
SQLite ownership correctness from application recovery orchestration. The
ordering pair is sufficient to resume the immutable keyset scan and contains
no meeting prose. Read-only reopening plus exact row validation prevents a
stale or forged checkpoint from silently skipping source data, while keeping
the remaining crash-window work explicit and independently testable.

## D186 — Advance backup recovery only after durable publication (Jul 2026)

**Context:** D185 makes an immutable source stage adoptable at an exact
content-free keyset position, but persisting the stage actor's cursor as soon as
it reads a row would be unsafe. Rendering or destination publication can still
fail afterward, and those typed per-meeting outcomes are currently held only by
the process-owned run. A relaunched process must not continue after an outcome
that its journal cannot reconstruct. Publication completion and source position
also cannot be one atomic write because completed records are immutable
sequence files while the cursor belongs to bounded metadata.

**Decision:** ApplicationKit maps each nonempty staged-source checkpoint into a
`LibraryMarkdownBackupSourceCursor` and carries it beside the pending document.
After a destination move succeeds, the workflow first promotes the exact
publication reservation into its immutable completed record. Only then may it
apply `checkpointSource` to optional format-v1 recovery metadata. The recovery
adapter rejects malformed cursors and any checkpoint while a publication
reservation remains pending. It accepts the current cursor as an idempotent
retry and accepts only a position later in the immutable
`startedAt DESC, id ASC` traversal; rollback fails closed.

If the publication completion succeeds but cursor persistence fails, the active
run retains only the pending metadata checkpoint and retries it before any next
source read. The destination move and completed publication record are not
repeated. After the first source-entry, document-render, or publication
failure, the run keeps reporting and processing later healthy meetings but
freezes durable cursor advancement because that failure outcome is not yet in
the journal.

This decision does not reconcile a pending reservation against destination
bytes, persist typed failure outcomes or a rendered document, or invoke stage
adoption during launch. Cleanup still removes abandoned current-format stages
and their matching recovery journals. T26 therefore remains open and full
relaunch continuation is not claimed.

**Rationale:** completion-before-checkpoint makes every persisted source
position conservative: all successful publications at or before it are already
durable, while unjournaled failures can never be silently skipped. An
idempotent metadata retry closes the same-process crash boundary without
rewriting completed evidence or republishing files. Keeping pending-digest
reconciliation, failure reconstruction, and launch adoption as explicit later
slices prevents a partial protocol from being described as restart-safe.

## D187 — Reconcile only exact pending backup publication evidence (Jul 2026)

**Context:** D184 reserves a destination filename and digest before the atomic
move, while D186 advances the staged-source cursor only after immutable
completion. A process can still terminate after reservation either before or
after the move. On relaunch, the same pending record therefore cannot reveal
whether the destination is absent, contains the intended bytes, or was occupied
by different content. The reservation also did not retain the exact source
cursor needed to complete a matching publication without restarting or
silently skipping a row.

**Decision:** every new pending publication carries the exact content-free
source cursor when durable advancement remains safe. The recovery adapter
validates the cursor independently and requires its record identity to equal the
reserved meeting UUID. The optional field preserves decoding of format-v1
journals created before this contract and marks new publications after an
earlier process-local failure freezes advancement. No cursor-less reservation
can advance source progress.

`LibraryMarkdownBackupFiles` exposes typed evidence for one exact reservation.
The macOS adapter opens the acquired destination directory with `O_NOFOLLOW`,
opens the final filename relative to that directory descriptor with `openat`,
`O_NOFOLLOW`, and `O_NONBLOCK`, requires a regular file with the reserved byte
count, and streams SHA-256 in bounded chunks. It forwards cancellation into
that utility task and checks it between reads. It never follows the reserved
final name as a symbolic link.

ApplicationKit owns one bounded reconciliation use case keyed by the immutable
operation UUID. It loads active recovery state, repairs a lagging checkpoint
from the latest immutable completed publication without destination access, and
otherwise acquires one destination lease and persists refreshed bookmark
identity before inspection. Missing evidence clears only the reservation so a
future adopted source can retry that row. Exact matching evidence with a bound
cursor promotes the pending record and then checkpoints its cursor. Conflicting
evidence and every matching cursor-less record remain blocked and untouched.
Destination and persistence failures are typed, cancellation propagates, and
the lease always closes.

This use case is not invoked by app launch yet. Typed failure/render
reconstruction and the ordering of reconciliation, stage adoption, and cleanup
also remain open. T26 therefore remains unresolved and Portavoz does not claim
that a whole-library backup resumes after termination.

**Rationale:** exact no-follow content evidence closes the reservation/move
ambiguity without persisting meeting prose or guessing from filenames. Binding
the source cursor to the same immutable publication makes a matching recovery
safe, while missing and conflicting outcomes preserve user data. Separating the
primitive from launch orchestration keeps the next restart slice independently
reviewable and prevents a reusable recovery contract from being hidden in the
macOS lifecycle model.

## D188 — Journal typed backup failures before advancing the source (Jul 2026)

**Context:** D186 conservatively froze the staged-source checkpoint after the
first source, render, or publication failure because the released partial
result existed only in process memory. D187 can reconcile destination bytes,
but launch adoption still cannot continue past a failed row without either
silently losing that outcome or repeating all later work. Persisting rendered
Markdown would duplicate meeting content in private recovery state and create a
second document lifecycle.

**Decision:** the recovery journal now stores one immutable, independently
sequenced failure record for each failed staged row. The bounded record contains
the exact content-free source cursor, optional meeting identity, bounded title,
and typed source/document/publication stage needed to reconstruct the released
partial-result contract. It contains no transcript, summary, or rendered
Markdown bytes. ApplicationKit normalizes the title to at most 4 KiB of UTF-8
before persistence, so an unbounded domain title cannot strand the operation.
Non-source failures require a meeting identity, and every
present identity must match the cursor's staged record. Current metadata is
format 2 and requires a private `failures` directory; format-1 journals without
that directory remain readable and migrate before their first failure record.
Failure files are immutable, contiguous, owner-only, bounded to 1 MiB, and an
exact retry of an already persisted record is idempotent.

ApplicationKit persists a failure before checkpointing that row. A failed
failure write keeps the in-process row pending; a failed checkpoint retries only
the metadata cursor and neither rerenders nor duplicates the failure record.
Publication failure first clears its failed reservation, so a crash before the
failure record leaves the durable cursor behind and safely retries the immutable
source row. Later healthy publications again carry their exact cursor because
all earlier outcomes are now durable. Reconciliation repairs a lagging cursor
from the furthest durable publication or failure without destination access.

Successful rendered documents are deliberately not journaled. Before a
publication reservation exists, the durable cursor still points to the prior
outcome, so an adopted immutable stage can replay the same row and render it
again. This decision still does not invoke reconciliation or stage adoption at
launch; T26 remains open and relaunch-safe whole-library backup is not claimed.

**Rationale:** one minimal typed outcome per failed row restores monotonic source
progress and exact partial-result reconstruction without turning the recovery
journal into a second meeting-content store. Keeping the checkpoint behind both
successful publication evidence and failure evidence makes every crash window
conservative: work is either durably represented or replayed from the immutable
stage.

## D189 — Recover one whole-library backup from exact launch evidence (Jul 2026)

**Context:** D185 can reopen one immutable SQLite stage at an exact content-free
cursor, D187 can reconcile the reservation/move boundary, and D188 makes every
failed-row outcome durable. Launch still removed abandoned stages before asking
whether a matching journal needed them. Simply reversing that call order is not
enough: a malformed journal might still name the only source, multiple journals
make ownership ambiguous, recovered filenames can collide with files created
while Portavoz was closed, and a destination failure after adoption must not
delete the stage merely because its actor leaves scope.

**Decision:** ApplicationKit owns one `RecoverLibraryMarkdownBackup` launch
operation. It first catalogs every canonical lowercase UUID child of the private
recovery root without trusting that child's shape or contents. The full catalog
is passed to StorageKit cleanup as a preservation set, so even a canonical
symlink or malformed journal protects its matching stage until strict loading
reports the error. Zero operations performs ordinary abandoned-stage cleanup.
More than one operation is ambiguous: Portavoz adopts none, deletes none, and
blocks a new backup rather than choosing by timestamp, directory order, or PID.

One operation enters the shared maintenance/media-export gate before
reconciliation or stage adoption. ApplicationKit reconciles the exact pending
publication and any lagging checkpoint, then adopts only the stage whose UUID
and cursor match the journal. Recovered active state requires no pending
reservation; contiguous publication and failure sequences; cursor-bound
publications; unique filenames and source positions; a checkpoint equal to the
furthest durable outcome; and an outcome count no greater than the immutable
stage total. Completed state additionally requires the outcome count to equal
that total. Invalid, missing, conflicting, cursor-less, or unavailable evidence
remains untouched and blocks a second backup.

The exporter rebuilds its collision allocator from the union of current
destination Markdown names and durable completed filenames, reconstructs typed
exported names and failures, and resumes strictly after the adopted cursor. A
completed journal reconstructs its final result without destination access,
removes the journal, and only then closes and deletes the stage. An adopted
stage does not remove its workspace on deinitialization. Recovery setup failure
uses explicit `abandon()` to close the read-only database and release the kernel
lease while preserving the journal and source for a later launch. Capture can
suspend recovery before reconciliation or adoption; the existing capture-stop
signal retries the unresolved operation. No timer, polling task, PID heuristic,
transcript, summary, or rendered Markdown is added.

A fatal source read that completes terminal journal/stage cleanup also clears
launch ownership. The coordinator checks whether the exporter still owns a
prepared or active immutable run before treating an error as retryable, so a
later capture-stop signal cannot reinterpret the remembered destination URL as
authorization to start a new live-library backup.

**Rationale:** catalog-before-cleanup prevents the recovery protocol from
destroying evidence it has not yet validated. Exact reconciliation, adoption,
and state validation turn every supported crash window into either durable
progress or deterministic replay. Failing closed on ambiguity and conflict
protects user files, while explicit abandon separates retryable ownership
release from terminal deletion. The implementation now supports relaunch
continuation; a real process-kill/relaunch exercise remains field evidence, not
a prerequisite for the code-level contract.

## D190 — Release owner-leased jobs explicitly on intentional suspension (Jul 2026)

**Context:** durable post-capture jobs use an exclusive owner lease and periodic
heartbeat because their model work and generated publication cannot be resumed
from an internal cursor. A task cancellation previously returned from
ApplicationKit while leaving the row `running`. Launch recovery could only
interpret the later lease expiration as worker death, consuming an attempt and
eventually exhausting work that had merely been suspended by policy or process
coordination. Reusing the same ownership mechanism for semantic indexing,
existing-library sync, or staged backup would add timers without improving
their already exact replay boundaries.

**Decision:** StorageKit adds one owner- and unexpired-lease-fenced suspension
transition. It returns the claimed job to `pending`, resets non-resumable
progress, clears lease/error/terminal fields, and refunds exactly the claim
attempt that opened the interrupted execution. Stale owners and repeated
suspension fail as lease loss. `ProcessPostCaptureJobs` invokes this transition
when capability work throws `CancellationError` and emits a distinct
`suspended` outcome only after the durable write succeeds, then stops the
current drain invocation so it cannot immediately reclaim pending work. Lease
loss remains a separate outcome; another persistence error stays a typed
preservation issue.

Replay-safe maintenance keeps its existing narrower ownership. Semantic
backfill and the existing-library seed publish explicit paused outcomes at
their durable database cursors. Whole-library backup journals every safe source
advance and uses a kernel lease for its immutable stage. None receives a timer,
PID heuristic, or heartbeat. Future graph rebuild must select one of these
contracts only after its derived index and rebuild cursor exist.

**Rationale:** an explicit release makes intentional suspension observable and
repeat-safe without waiting for time to prove a worker dead. Refunding the claim
is required: a pending row at `maxAttempts` is not claimable and would otherwise
be stranded. Matching ownership strength to recovery granularity keeps the
durable worker strict while avoiding artificial liveness machinery around
idempotent checkpoint workflows.

## D191 — Prove accelerated long capture separately and bound finalization heap (Jul 2026)

**Context:** GOV-5 needs both synthetic three-hour continuity and real-time
recording/interference evidence. Adding multi-hour cells to the exact 27-cell
resource matrix would make ordinary collection impractical and would conflate
deterministic file conservation with hardware, route, thermal, and power
behavior. The first accelerated dual-channel Release run conserved every frame
but retained roughly the full 691 MiB PCM payload after Stop. Short tests did
not expose that `FileHandle.read(upToCount:)` produced one autoreleased `Data`
per SHA-256 block on a long-lived utility queue.

**Decision:** `RecordingSession.Summary` carries exact integer frame counts in
addition to projected seconds. `CaptureFileWriter` owns one grow-only reusable
PCM buffer per channel and an explicit idempotent close; Stop closes every
writer before publication rather than depending on task-context destruction.
The streaming SHA-256 loop reads and updates each 1 MiB block inside its own
autorelease pool.

A separate `bench-capture` CLI drives microphone and system sources through the
production session. It admits one chunk pair, waits until both chunks have been
persisted, then admits the next. `make long-capture-baseline` requires a clean
commit and Release build, refuses to overwrite an existing receipt, rechecks
source identity before destination-local atomic publication, and validates an
exact-shaped, owner-only, source-commit-bound report. Canonical evidence
requires exactly three logical hours at 16 kHz: 172,800,000 writer and
published-file frames per channel, healthy CAFs, zero frame drift, and at most
16 MiB incremental allocator heap. Unknown fields, private paths/content,
debug builds, malformed numbers, partial channels, and inconsistent counts
fail closed.

Accelerated process physical footprint is excluded from this report because
writing 691 MiB in seconds creates dirty-page pressure unlike real elapsed
capture. The 16 MiB limit is a duration-invariance safety fence for the
synthetic process, not a product RAM tier. The existing real-time resource
contract remains unchanged and owns physical-footprint, thermal, power, disk,
resident-model, and call-route acceptance.

**Rationale:** deterministic frame conservation can run quickly and catch
duration-proportional heap defects without multiplying every hardware cell.
Keeping the contracts separate prevents a fast synthetic writer from making
false real-call claims while still turning multi-hour capture and Stop into a
repeatable release gate. Explicit close and scoped autorelease make the
architecture's bounded-memory publication claim true rather than relying on
ARC timing.

## D192 — Trace Ask stages without admitting meeting content (Jul 2026)

**Context:** progressive Ask must remove complete corpus backfill and optional
generation from time-to-first-evidence without changing citation quality. The
existing resource telemetry identifies only a broad user-initiated workload;
the historical lexical and semantic probes cannot explain expansion,
readiness, retrieval, or generation time inside one real Ask. Overloading the
generic resource taxonomy with search-specific stages would couple unrelated
governor policy to benchmark implementation.

**Decision:** ApplicationKit owns a separate closed `AskPipelineTelemetry`
port. One random process-local trace spans a validated search, evidence, or
answer operation. `LocalAskMeetingRetrieval` emits matched intervals for corpus
readiness, query expansion, lexical query, query embedding, semantic scan,
fusion, and citation materialization. `AskMeetings` emits first evidence, the
first token observable at its answer boundary, and a completed, cancelled, or
failed terminal outcome. Empty and invalid requests create no trace.

The trace types carry only closed operation/stage/milestone/outcome enums and
random correlation UUIDs. The macOS composition root maps them to OSLog Points
of Interest through one adapter whose API cannot receive question text,
meeting or segment identity, citations, paths, model names, or error text. An
explicit observer seam lets deterministic benchmarks receive the same event
stream without parsing Instruments output. The current answer capability is
not streaming, so first-token observation honestly coincides with the complete
answer crossing ApplicationKit; it does not claim model-internal timing.

This slice does not retain samples, create a benchmark report, alter corpus
writes, reorder retrieval, or change model readiness. Those changes require a
separate comparable evidence slice over this stable vocabulary.

**Rationale:** a dedicated application-level trace makes every current latency
component visible without weakening privacy or turning measurement labels into
resource policy. Establishing stable before-state evidence first lets later
progressive retrieval prove lower time-to-first-evidence and unchanged
citations rather than merely moving work and assuming improvement.

## D193 — Pair every Ask resource run with one authoritative pipeline receipt (Jul 2026)

**Context:** D192 established a stable content-free event vocabulary, but the
resource matrix still retained only broad process counters. A trace visible in
Instruments was insufficient benchmark authority: it did not bind stage timing
to the exact resource run, prove the current corpus readiness transition, or
fail the matrix when citations changed. Parsing signpost text would also make
the benchmark depend on a presentation format rather than the application
contract.

**Decision:** the hidden macOS Ask benchmark installs one observer around its
single disposable `AskMeetings.local` operation. A strict native collector
accepts one answer trace, every declared stage exactly once, first evidence,
first observable answer token, and one successful terminal outcome. It samples
monotonic wall and process CPU at those boundaries and atomically writes one
owner-only, non-overwriting sidecar named for the same numeric run as the broad
resource receipt. Duplicate, foreign, incomplete, failed, post-completion,
misordered, or malformed-digest evidence cannot publish.

The receipt contains only closed labels, timings, counts, a fixed corpus
generation, a SHA-256 checksum over canonical public-fixture fields, cold
readiness state, and a SHA-256 digest over validated fixture citation ordinals.
Runtime trace/segment/meeting IDs, question and transcript text, generated
answers, model names, paths, and errors remain outside the schema. Canonical
timestamps use their IEEE-754 bit patterns rather than locale-sensitive text.

The assembler requires exact one-to-one broad Ask and pipeline run sets. The
evaluator reports p50/p95 wall and CPU for total time, first evidence, first
observable token, post-evidence generation, and every stage; insufficient or
unstable samples block. Corpus and citation identity must be deterministic
within a memory profile and comparable across profiles. The current v1
before-state deliberately requires all ten fixed segments to move from pending
to ready during the request. SEARCH-1 must version or replace that readiness
contract when request-time backfill is removed.

**Rationale:** pairing native stage evidence with the already isolated host
resource run makes performance changes explainable without exposing meeting
content or allowing instrumentation to affect product policy. Exact corpus and
citation gates distinguish a faster implementation from one that silently did
less work, while an explicit before-state gives later progressive retrieval a
real comparison boundary.

## D194 — Freeze multilingual Ask quality before retrieval changes (Jul 2026)

**Context:** D192–D193 make the current Ask latency and resource path
explainable, but deterministic citation identity over a ten-segment performance
fixture does not prove retrieval or answer quality. Removing request-time
corpus writes, changing progressive orchestration, chunking, embeddings, or the
vector engine without one stable quality boundary could make Ask faster by
silently losing bilingual evidence, exact facts, abstention, or citation
integrity. Using a second model as the only judge would also make the release
gate nondeterministic and difficult to reproduce offline.

**Decision:** benchmark tooling owns an adapter-neutral schema and a canonical
public-synthetic fixture with exactly 240 judged queries: 60
Spanish-to-Spanish, 60 English-to-English, 40 English-to-Spanish, 40
Spanish-to-English, 20 code-switched, and 20 robustness cases. Robustness keeps
Spanish evidence fixed while independently testing accent removal, spelling
errors, technical-identifier noise, and missing-fact abstention. Exact fact
intents require relevant evidence at rank one. Every query also declares
graded evidence, canonical timestamp/owner labels, hard negatives, and an
answer-or-abstain policy.

One strict local evaluator rejects duplicate or unknown fields, incomplete
query coverage, duplicate hits, unsafe identities, stale citation revisions,
non-finite scores, and noncanonical public fixtures. It reports Hit@1,
Recall@10, reciprocal rank, nDCG@10, factuality, citation coverage, answer
policy accuracy, hard-negative hits, invalid/stale citations, and unsupported
claims overall and per relationship. Passing requires exact facts at rank one,
explicit overall and per-relationship retrieval/answer floors, canonical
citations, correct abstention, no hard negatives, and zero unsupported claims.
The observation schema contains no question, transcript, generated answer, or
owner text; the owner-only non-overwriting scorecard contains only aggregate
metrics plus fixture, adapter, build, and commit identity.

The public corpus is tracked and deterministic. A later private anonymized pack
must use the same schema but remains untracked. This decision adds no product
runtime dependency and does not select an index or embedding provider. SEARCH-1
cannot claim quality parity until its real retrieval path emits complete
observations that pass this contract.

**Rationale:** deterministic labels make regression detection local,
repeatable, and independent of whichever model is under test, while factuality
and citation metrics still permit separately versioned human or model-assisted
annotation when producing a fixture. Freezing the scoring contract before the
implementation changes makes latency improvements comparable rather than
subjective and preserves multilingual, evidence-linked behavior as an explicit
architecture invariant.

## D195 — Observe production Ask retrieval without claiming answer quality (Jul 2026)

**Context:** D194 freezes an adapter-neutral quality contract, but generated
fixtures and evaluator tests do not prove that the shipped retrieval path can
produce canonical observations. Linking benchmark code into the app or opening
the user's library would weaken product boundaries and privacy. Conversely,
filling answer scores from retrieval evidence would falsely claim generative
factuality and citation coverage.

**Decision:** `portavoz-cli bench-ask-quality` loads a verified quality fixture
into a disposable owner-only `MeetingStore`, executes the real
`LocalAskMeetingRetrieval` hybrid path with deterministic no-expansion control,
maps ephemeral identities back to fixture identities, and atomically publishes
one non-overwriting observation document. `SearchHit` and `AskCitation` carry
the meeting transcript revision so every observed citation includes canonical
revision provenance. The adapter never opens the user library and is not linked
into the app.

This first production adapter evaluates retrieval only. Every answer observation
is explicitly `notEvaluated`, with null factuality and citation coverage and zero
unsupported-claim assertions. The evaluator may report retrieval metrics, but
the answer policy and quality gates remain blocked. A later separately versioned
answer adapter or judge must provide that evidence; retrieval success cannot be
promoted into an answer-quality claim.

**Rationale:** exercising the shipped retrieval implementation closes the gap
between a synthetic contract and product code while preserving privacy and
dependency direction. Explicitly incomplete answer evidence keeps the release
gate honest and lets retrieval architecture evolve without hiding the remaining
generative-quality work.

## D196 — Keep product Ask corpus-read-only (Jul 2026)

**Context:** the signal-driven semantic maintenance owner already wakes at app
launch, searchable mutations, capture completion, and explicit reconciliation,
but `LocalAskMeetingRetrieval` still downloaded/prepared assets and drained
every missing embedding before returning evidence. A user query therefore
owned model setup, maintenance admission, database writes, and retrieval in one
latency/cancellation scope. D192–D195 provide stage, corpus, citation, and
multilingual quality evidence that can distinguish that historical path from a
read-only request.

**Decision:** product Ask retrieves exact FTS evidence first and never invokes
`IndexSemanticCorpus`, persists an embedding, or requests semantic asset
download. It inspects `hasAvailableAssets`; only when assets are already
available does it borrow the process runtime with `allowAssetDownload: false`,
embed query variants, and search vectors already published by maintenance.
Missing assets and ordinary preparation/query failures produce no semantic
candidates and preserve lexical evidence. `CancellationError` and task
cancellation still terminate the request.

Complete corpus drains remain owned by signal-driven background maintenance;
Library may retain its existing bounded opportunistic batch in this slice.
Explicit benchmark setup may index only its disposable store before observing
a query. The native Ask resource sidecar advances to schema 2 and generation
`ask-resource-v2`: it proves every fixture row was pending at seed time, zero
rows were pending before and after the measured query, and both readiness
states were true. The production quality observation adapter advances to
`local-hybrid-preindexed-no-expansion-evidence-v2` and likewise prepares its
disposable corpus outside query observation. Schema-1 cold-backfill receipts
and adapter-v1 observations remain historical before-state evidence and are
not silently mixed with version 2.

This decision does not yet expose user-facing `ready`/`partial`/`building`/
`unsupported`/`failed` state, move Library's bounded batch, activate durable
index jobs, or claim accepted answer quality.

**Rationale:** query cancellation and optional semantic capability should not
control durable corpus progress, and a cold or failed model must never block
exact local evidence. Separating benchmark preparation from query measurement
keeps comparisons honest while making the architecture's ownership boundary
enforceable in source and tests.

## D197 — Centralize semantic readiness and product write ownership (Jul 2026)

**Context:** D196 removed request-time corpus writes from Ask, but Library still
advanced a bounded embedding batch while a user typed. Ask and Library also
inspected runtime assets independently, so neither had one typed explanation
for a complete, partially published, actively building, unsupported, or failed
semantic corpus. Query cancellation could still own Library persistence, and
the background supervisor's active/failure phase was not available to either
consumer.

**Decision:** ApplicationKit owns a closed `SemanticCorpusReadiness` contract
with `ready`, `partial`, `building`, `unsupported`, and `failed` states.
`ResolveSemanticCorpusReadiness` derives that state without preparation or
writes from three inputs: installed query-vector capability, a one-row durable
pending-embedding probe, and one lock-protected process maintenance phase. A
complete corpus reports `ready` even if the last process pass failed. Pending
rows report `partial` while idle, `building` during an active drain, and
`failed` after an ordinary drain error. Missing query-vector capability reports
`unsupported`.

Exact FTS remains available in every state. Ask and Library may read already-
published vectors in `ready`, `partial`, `building`, and `failed`; only
`unsupported` skips semantic work. Both product query paths are corpus-read-
only: they cannot own an indexing coordinator, invoke `IndexSemanticCorpus`,
persist vectors, or request asset download. The signal-driven macOS supervisor
is the sole product corpus writer and publishes its payload-free process phase
to the shared resolver. Explicit benchmark preparation may continue writing
only to its disposable store outside the observed product request.

This phase is deliberately not durable progress. Missing `NULL` embedding rows
remain the authoritative cursor. D200 later adds content-free scheduling
ownership and restart recovery around that cursor without moving progress into
the job ledger.

**Rationale:** one typed read model gives every query surface identical,
testable degradation while separating user latency and cancellation from
durable corpus progress. Keeping persistence behind the background owner makes
write scheduling independently governable without sacrificing exact search or
the value of semantic rows that are already published.

## D198 — Fence semantic publication by exact transcript source (Jul 2026)

**Context:** the `NULL` embedding cursor was crash-resumable, but batch
selection returned only segment ID and text and publication updated by segment
ID alone. A transcript edit, reviewed replacement, or deletion racing the
embedding model could therefore let an old vector reach a reused segment
identity. Activating the dormant `.index` processing-job kind does not solve
that race and would currently let degradable derived work drive the meeting's
visible `processing`/`needsAttention` lifecycle.

**Decision:** every semantic candidate carries segment ID, meeting ID,
transcript revision, and exact text from selection through publication.
StorageKit accepts an exact candidate/vector key set and conditionally writes
each vector only while the same segment remains live and unembedded, its exact
text is unchanged, and its live meeting remains at the selected transcript
revision. Concurrent completion, correction, replacement, or tombstone is a
content-free skipped outcome. `IndexSemanticCorpus` reports accepted full-text
vectors, accepted empty micro-segment markers, and skipped rows separately;
the current live replacement remains `NULL` for a later signal-driven pass.

This is the first SEARCH-2 durability unit, not a second job cursor. `NULL`
rows remain authoritative across pause, failure, and relaunch, Ask and Library
remain read-only, FTS remains independent, and `.index` remains dormant until
derived-maintenance scheduling can be separated from the meeting lifecycle.
This decision itself does not add model/index-schema fingerprinting,
invalidation, bounded retry ownership, or relaunch evidence. D199 subsequently
adds the profile fingerprint and invalidation boundary; D200 subsequently adds
independent retry ownership and relaunch recovery without changing this source
fence.

**Rationale:** stale derived data must be impossible before retry scheduling is
made more durable. Compare-and-swap at the storage boundary protects every
caller and preserves the smallest exact replay unit without manufacturing a
second progress source or turning optional semantic maintenance into meeting
recovery state.

## D199 — Fence semantic reads and rebuilds by embedding compatibility (Jul 2026)

**Context:** D198 proved that a vector belongs to an exact transcript source,
but the persisted BLOB still did not identify the vector space that produced
it. An operating-system model revision, dimension change, Portavoz pooling
change, or binary-schema change could leave structurally valid but semantically
incompatible rows queryable. Vector width alone cannot prove compatibility,
and existing databases contain unprofiled vectors.

**Decision:** PortavozCore owns `SemanticEmbeddingProfile`, a content-free
typed identity containing the concrete model identifier and revision, vector
dimension, pooling-pipeline identifier and revision, and vector-schema version.
Its stable SHA-256 fingerprint is stored atomically beside each embedding.
The prepared embedder is the authority for the active profile; app and CLI
runtimes, readiness, maintenance, Ask, Library, and benchmark paths pass the
same value through their existing boundaries.

Storage rejects an invalid profile, a non-empty vector of the wrong dimension,
and every non-finite value. Semantic lookup accepts a query only at the active
dimension and scans only rows with the exact active fingerprint. Maintenance
detects missing or incompatible rows, resets incompatible derived vector state
to the existing `NULL` cursor, and rebuilds it under the active profile before
publication. Empty libraries use a profile-free row-existence probe and do not
touch model assets. Schema v17 adds nullable `segment.embeddingFingerprint` and
fails closed by clearing legacy unprofiled embedding BLOBs; transcript, FTS,
meeting revision, and all other authoritative rows remain untouched.

This remains derived background maintenance, not meeting processing. Ask and
Library stay corpus-read-only, exact FTS stays available during a rebuild, no
query or background path downloads assets, and the dormant `.index` processing
kind remains inactive. The fingerprint contains no meeting, transcript, or
query content.

**Rationale:** semantic results are valid only when both their source and
vector space are current. A single typed profile and fail-closed storage fence
make that invariant enforceable at every read/write boundary, while reusing the
existing crash-resumable `NULL` cursor avoids a second ledger and preserves
exact local search throughout migration and rebuild.

## D200 — Own semantic maintenance independently from meetings (Jul 2026)

**Context:** source- and compatibility-fenced `NULL` vector rows made indexing
replayable, but ordinary failures still depended on another app signal and a
relaunch before a dead worker lease expired had no deterministic future wake.
The existing `processingJob.index` contract is meeting-scoped and may move an
otherwise searchable meeting into `processing` or `needsAttention`, so it is
not a valid owner for degradable library-wide derived work.

**Decision:** schema v18 adds a content-free derived-maintenance source and job
ledger independent from meeting rows. Triggers advance one semantic source
generation for authoritative transcript mutations but exclude embedding
publication. The active compatibility profile plus generation produces one
idempotent operation fingerprint. Superseded pending operations are cancelled;
one kind-wide lease, heartbeat, bounded attempts, stable error code, and future
retry timestamp own scheduling only. `NULL` or incompatible segment vectors
remain the sole progress cursor.

ApplicationKit recovers expired ownership, admits and claims the operation,
borrows only already-installed semantic assets, and settles success, capture
suspension, or failure. Capture suspension clears the lease and refunds the
attempt. Ordinary failure retries after 5 and 30 seconds before becoming a
terminal derived result. The macOS supervisor schedules one cancellable wake
for the earliest retry or live predecessor lease expiration; mutation and
capture-stop signals still coalesce into one immediate rerun. Relaunch recovery
therefore resumes only remaining vector rows without polling or duplicate
publication.

Exact FTS and compatible published vectors remain available in every state.
Derived failure never changes meeting lifecycle, stores meeting/transcript
content, or activates `processingJob.index`.

**Rationale:** retry ownership and indexing progress have different recovery
boundaries. A small independent lease envelope makes process death and bounded
retry deterministic, while the existing row cursor remains the exact,
idempotent proof of completed derived work.

## D201 — Publish exact Ask evidence before generation (Jul 2026)

**Context:** D196–D200 separated product queries from corpus maintenance, but
Ask still invoked optional Foundation Models query expansion before exact FTS.
A cold or busy local model could therefore delay evidence that SQLite already
had, while the full Ask surface exposed only one undifferentiated spinner.
Sequential lexical and semantic work also made semantic readiness part of the
exact-result critical path.

**Decision:** `AskMeetings` owns a storage-independent progressive evidence
contract with `lexical` and `fused` phases while preserving its existing final
answer API for CLI, MCP, the command palette, and meeting preparation. The
local adapter first applies the deterministic bounded English/Spanish lexicon,
then starts exact FTS and optional published-vector augmentation concurrently.
Exact citations cross the application boundary as soon as FTS finishes. The
bounded reciprocal-rank-fused set is immutable before answer generation begins
and is the only evidence supplied to the answer model.

Foundation Models query expansion is no longer on the first-evidence path. It
runs only when deterministic bilingual lexical retrieval plus available
semantic retrieval found no citation, admits at most three new normalized
variants, and never downloads an asset. That late fallback remains inside the
operation's total duration but does not emit a duplicate primary expansion
stage; adding dedicated fallback-stage timing requires a separately versioned
telemetry receipt. Ordinary semantic or generation failure still preserves
exact evidence, while cancellation propagates through every concurrent task.

The macOS full Ask model presents distinct finding, semantic-refinement, and
answer-generation states, exposes early citations, and fences every update by
the request generation. Cancel or navigation removes pending state and rejects
late evidence or completion. Other consumers retain their final-result
behavior.

**Rationale:** local evidence should feel instantaneous and must not depend on
optional generation. A two-phase application contract makes progressive UX a
presentation choice without exposing storage or model details, while one final
evidence fence keeps generated answers and citations coherent.

## D202 — Define speaker-safe retrieval chunks before changing the index (Jul 2026)

**Context:** production semantic retrieval still embeds one transcript segment
per row. That preserves exact citations and correction invalidation, but very
short fragments can lack enough context for useful ranking. Replacing the
storage layout first would make attribution, mixed-language fidelity,
incremental rebuild cost, and quality regressions inseparable from a schema
migration. A meeting-wide transcript revision alone is also too broad an
invalidation key: correcting one word must not require re-embedding unrelated
turns.

**Decision:** ApplicationKit defines a pure, storage-independent
`RetrievalChunk` and deterministic `speaker-turn-v1` chunker. A chunk may join
only adjacent nonempty segments that resolve to the same confirmed person, the
same meeting-local speaker, or the local microphone. Unattributed system and
room segments stay isolated. A different actor always starts another chunk,
even when joining would improve length. Append admission is bounded to 900
normalized characters, 45 seconds, and a 2.5-second gap; an oversized
authoritative source remains indivisible rather than fabricating subsegment
citations.

Each chunk carries ordered source segment IDs, timestamps, channel,
meeting-local speaker IDs, confirmed person IDs, and normalized per-source
spoken-language tags. Spoken text is Unicode/whitespace normalized only; it is
never translated or vocabulary-corrected by chunking. Chunk identity depends
on meeting, chunker version, and ordered source membership. A separate source
fingerprint includes each source's normalized text plus attribution, language,
and timing, so moving words between unchanged source IDs is still a change.
The transcript revision is retained as a publication fence but excluded from
identity and rebuild admission, so a revision increment retains unaffected
chunks while a correction republishes only overlapping evidence.

This slice adds no table, vector, query adapter, product write, or UI behavior.
The schema-v18 segment vectors remain the production default. Any persistence
or retrieval adapter for chunks must resolve every selected chunk back to its
current ordered source rows, run through the canonical multilingual quality
pack and resource matrix under a distinct adapter identity, and match or beat
segment retrieval before selection.

**Rationale:** source-safe context must be proven before it becomes durable.
A pure deterministic boundary lets competing chunk policies share one exact
provenance model, makes selective correction invalidation testable, and keeps
the current local-first search fully available while evidence is collected.

## D203 — Score retrieval units through exact source membership (Jul 2026)

**Context:** D202 defines speaker-safe candidate chunks, but the D195 quality
observation represented every ranked result as one `segmentID`. Reusing that
shape for a chunk would either hide additional sources, flatten them into
independent ranks, or conceal a hard negative that shares the selected turn.
None is a truthful comparison with the segment control. Building a second
retrieval algorithm only for the benchmark would also stop testing the shipped
ranking path.

**Decision:** `portavoz-cli bench-ask-quality` accepts an explicit
`segment|speaker-turn` retrieval unit. It projects the selected units into its
disposable owner-only database, prepares the same semantic corpus, and runs the
same `LocalAskMeetingRetrieval` implementation. The speaker-turn candidate uses
the D202 chunk identity and spoken text; it creates no product table, migration,
maintenance job, or query lane.

New observations use schema 2. Every ranked hit contains one stable `unitID`
and its complete ordered `sourceSegmentIDs`, plus meeting, first-source
timestamp, and transcript revision. The evaluator normalizes historical
schema-1 segment hits into one-source units. It scores rank by retrieval unit,
recall by covered canonical sources, and rejects repeated units or sources.
Unknown sources, incorrect order, a wrong meeting or first timestamp, and a
stale revision fail citation integrity. A hard-negative source counts even
when the same chunk also contains relevant evidence. Observation and scorecard
artifacts remain content-free outside the private fixture and retain build,
commit, adapter, and observation-schema identity.

This slice enables comparison but does not declare a winner. The current
canonical public fixture rarely contains adjacent rows from the same actor, so
a later versioned corpus topology and paired comparison receipt must exercise
real multi-segment turns before speaker-turn retrieval can claim parity. Product
Ask, Library, schema v18, and segment-level vectors remain unchanged.

**Rationale:** a richer retrieval unit is acceptable only if every piece of
evidence remains inspectable at its original transcript identity. Reusing the
production retrieval path isolates chunk topology as the variable under test,
while source-aware scoring prevents apparent recall gains from hiding wrong or
stale evidence.

## D204 — Version corpus topology and compare retrieval candidates as one run (Jul 2026)

**Context:** D203 can score segment and speaker-turn units truthfully, but the
first public corpus generation grouped four different actors per meeting. The
candidate therefore collapsed to the segment control on almost every row, and
independent scorecards could still be compared across a different corpus,
build, commit, or observation schema. Replacing the original fixture would
also make historical evidence impossible to reproduce.

**Decision:** tracked public fixture generations are immutable. The historical
`public-synthetic-v1` fixture remains accepted at its original checksum. The
current `public-synthetic-v2` fixture preserves the exact 240-query multilingual
distribution but deterministically interleaves relationships into sixty
four-segment meetings. Every meeting has two ordered two-segment same-actor
turns, including mixed-language turns. Hard negatives come from another
meeting, so the speaker-turn candidate is exercised without manufacturing a
hard-negative failure in every relevant chunk.

The offline comparator accepts one validated canonical fixture and two complete
scorecards. The control must use the D203 segment adapter, the candidate the
D203 speaker-turn adapter, and both must share build, commit, fixture checksum,
and observation schema 2. It publishes an owner-only, atomic, non-overwriting,
payload-free receipt with aggregate and per-relationship retrieval deltas.
Candidate parity requires no degradation in Hit@1, Recall@10, MRR, nDCG@10, or
exact-rank-one, canonical citations for both candidates, and no hard-negative
increase. Identity, aggregate, or language-slice mismatch blocks the receipt.

A `candidate-parity` receipt is quality evidence only. It does not choose the
product adapter or authorize chunk persistence, semantic maintenance, or query
changes. Resource cost, correction cost, answer quality, and accepted hardware
evidence remain separate gates before production selection.

**Rationale:** corpus topology must vary the retrieval unit without changing
the judged distribution, while one paired receipt must prove both candidates
were measured from the same source and build. Immutable generations preserve
historical reproducibility; strict per-slice comparison prevents an aggregate
gain from hiding a Spanish, English, mixed, or cross-lingual regression.

## D205 — Publish retrieval comparisons only through a clean-source pair (Aug 2026)

**Context:** D204 defines the comparison receipt, but manually invoking two
CLI observations and three evaluator commands can mix commits, builds, fixture
generations, or partial artifacts. The observation adapter also requested
Apple's OS-managed embedding assets implicitly. That acquisition can take
minutes, fail for host-service reasons, and contaminate the boundary between
environment readiness and candidate retrieval quality.

**Decision:** `make ask-quality-pair` is the accepted orchestration path for a
segment versus speaker-turn comparison. It requires a clean worktree, derives
the full HEAD SHA itself, validates the canonical v2 fixture, builds one Release
CLI, and fixes both observations to the same receipt-safe build identity. The
runner always passes `--asset-download never`. Direct development CLI runs may
opt into `if-needed`, but the CLI default is also `never`; acquisition is a
separate preparation concern and is never part of accepted quality evidence.

The runner admits evaluator exit 1 only when a complete owner-only scorecard
was published, because the current answer fields are deliberately
`notEvaluated`. It then requires the comparator exit status to agree with its
`candidate-parity|blocked` receipt and exact build/commit identity. All two
observations, two scorecards, and the comparison are mode 0600 in one mode-0700
staging directory. An exclusive sibling lock, non-overwriting destination, and
final directory rename prevent a partial run from becoming comparable
evidence. Setup, model, host-service, malformed receipt, or identity failure
removes staging and exits as a contract error. Repository-local output must be
ignored.

This decision does not declare speaker-turn parity, choose production chunk
storage, or weaken the resource, correction-cost, answer-quality, hardware, or
field gates. Model unavailability is recorded as a blocked environment, never
as a retrieval regression or fabricated score.

**Rationale:** comparison evidence is useful only when both candidates have one
immutable source identity and complete publication boundary. Separating asset
preparation from measurement makes failures fast and attributable, while one
private atomic run prevents accidental cross-build conclusions.

## D206 — Inject one read-only semantic-index query port before shadow engines (Aug 2026)

**Context:** Ask and Library called `MeetingStore.searchSemantic` directly.
That is correct for the shipped Accelerate exact scan, but it makes a controlled
shadow bake-off awkward: each consumer would need engine-specific branching,
and a candidate could accidentally become coupled to query-vector creation,
corpus maintenance, or user-visible fusion before its evidence is accepted.

**Decision:** ApplicationKit owns one narrow `SemanticIndexSearching` query
port. It accepts a finite vector space through the exact active
`SemanticEmbeddingProfile` plus a bounded limit and returns ranked, current
`SearchHit` projections. Ask and Library borrow the embedding runtime and create
the query vector exactly as before, then call the injected port. Their default
is `AccelerateExactSemanticIndex`, a behavior-preserving adapter over the
existing SQLite-streamed Accelerate implementation.

The seam is read-only and does not own embedding assets, vector publication,
compatibility invalidation, maintenance scheduling, lexical search, fusion, or
answer generation. Exact control remains the sole product result source.
Candidate packages, persistence, shadow orchestration, content-free comparison
telemetry, and engine selection remain separate SEARCH-5 slices. A future
candidate adapter must still return authoritative current citation projections;
it cannot make its derived index the meeting-data authority.

**Rationale:** one injected port isolates the variable that the benchmark needs
to compare without changing the safe exact-first product. Retaining the current
adapter as the default creates a reversible Strangler seam and prevents a
research engine from spreading into retrieval consumers or the durable writer
before quality, resource, lifecycle, licensing, and packaging gates pass.

## D207 — Shadow candidates never serve results or carry payload telemetry (Aug 2026)

**Context:** D206 isolates semantic queries, but an adapter seam alone does not
make a safe bake-off. Awaiting a candidate would add its latency to Ask;
returning candidate hits would silently change product quality; logging queries,
citations, model errors, or identifiers would violate the local-first evidence
contract. A control failure also leaves no valid baseline for comparison.

**Decision:** ApplicationKit provides a benchmark-only
`ShadowComparingSemanticIndex`. It executes the exact control first and returns
those hits without awaiting an explicitly injected candidate task. Candidate
success, failure, or cancellation cannot change the returned value or throw into
the control path. A control failure is propagated and schedules no candidate.
Ask and Library continue to compose `AccelerateExactSemanticIndex` directly.

Before telemetry emission, the wrapper reduces control and candidate hits to
private segment/revision keys and emits only aggregate count, overlap,
same-rank, optional top-hit agreement, closed outcome, vector dimension, limit,
and duration fields. Candidate identity is a closed research-family enum. The
event has no query, vector, meeting/citation identifier, title, transcript text,
model identifier, path, or raw error field. No durable receipt, candidate
dependency, index schema/writer, or app composition is introduced by this
slice. Both telemetry and executor are mandatory constructor arguments; there
is no evidence-disabled default that can silently spend candidate resources.

**Rationale:** shadow evidence is useful only when control behavior and privacy
are invariant by construction. Separating candidate scheduling and allowlisting
event fields keeps the Strangler reversible, makes failures observational, and
lets later adapters be measured without granting them product authority.

## D208 — Admit semantic shadows as capture-safe, no-backlog maintenance (Aug 2026)

**Context:** D207 makes candidate results non-serving and payload-free, but its
explicit detached executor can still start multiple candidates, compete with a
recording, or accumulate work outside the resource-governor boundary. Adding a
candidate adapter before constraining admission would make resource interference
part of the engine experiment and could harm the call-safe recording invariant.

**Decision:** benchmark composition may provide
`SemanticIndexShadowCoordinator` as the D207 executor. Every submitted candidate
is evaluated through the existing `DurableMaintenanceGate` at `.admission` with
the closed `.maintenance` / `.searchIndex` / `.execute` descriptor. The actor
owns at most one active cooperative task and no backlog. Policy denial, an
occupied flight, and capture suspension emit distinct closed skip outcomes;
they never queue or run the candidate. Capture suspension cancels the active
task, and resume waits for that task to settle before admitting later work.

Exact control still returns immediately and remains the sole result authority.
The coordinator carries no query, vector, citation, meeting, model, path, or raw
error into telemetry. It has no app composition, durable receipt, package,
schema, writer, or concrete candidate adapter. The unrestricted detached
executor remains available only for explicit deterministic or benchmark use;
shipping composition must not bypass governed admission if a shadow lane is
ever enabled.

**Rationale:** candidate cost must be bounded before candidate technology is
introduced. Reusing one capture-aware maintenance gate prevents research work
from competing with live audio, while single-flight/no-backlog behavior makes
load deterministic and preserves the reversible exact-first Strangler seam.

## D209 — Bind shadow evidence identity to the candidate implementation (Aug 2026)

**Context:** D207 recorded a closed candidate-family label beside work submitted
through the generic semantic-index port. The label and candidate were separate
constructor arguments, so a benchmark call site could accidentally identify a
sqlite-vec implementation as Core Spotlight or USearch. Aggregate telemetry
would remain payload-free but become untrustworthy, and no later receipt could
recover which implementation actually produced it.

**Decision:** every research candidate conforms to
`SemanticIndexShadowCandidateSearching`, which refines the D206 query port and
owns one closed `SemanticIndexShadowAdapter` identity. The shadow decorator
accepts only that identity-bearing candidate and derives completed, failed,
cancelled, and skipped event identities from `candidate.adapter`. There is no
independent adapter-label constructor argument.

This contract does not introduce a concrete engine, package dependency,
derived schema, index writer, app composition, or durable receipt. Exact
Accelerate control remains the only product authority, and D208 admission still
governs every optional benchmark candidate.

**Rationale:** benchmark attribution must be correct by construction before
engine work begins. Making identity an implementation property prevents label
drift, keeps aggregate evidence explainable, and preserves the reversible
shadow boundary without granting a candidate product authority.

## D210 — Project derived ranks through current authoritative evidence (Aug 2026)

**Context:** a sqlite-vec, USearch, or Core Spotlight candidate will maintain
derived state that can lag transcript correction, deletion, or rebuild. The
D206 query port returns complete `SearchHit` citations, so allowing an engine to
construct those values would make derived storage an accidental content
authority. Comparing stale text or an old transcript revision could also make
aggregate agreement look valid while its source evidence is no longer current.

**Decision:** research engines implement `SemanticIndexShadowRanking` and
return only ordered `SemanticSearchCandidateIdentity` values containing segment
ID and transcript revision. `ProjectedSemanticIndexShadowCandidate` bounds the
ranked window to the requested limit and resolves it through `MeetingStore`.
Storage preserves first-seen candidate order while omitting negative revisions,
duplicate IDs, missing or deleted segments, deleted meetings, and any candidate
whose revision differs from the current meeting transcript. It does not search
beyond the bounded candidate window to replace rejected ranks.

The ranker owns its D209 adapter identity. The projection returns authoritative
current text, title, time, meeting identity, and revision; candidate-provided
content cannot cross the query port. This slice adds no concrete engine,
package, schema, writer, app composition, or durable shadow receipt, and exact
Accelerate control remains the only product authority.

**Rationale:** a derived index may propose rank but never evidence. Installing
the revision-fenced projection before an engine experiment isolates ranking as
the measured variable, makes correction/deletion races fail closed, and keeps
future adapters reversible without duplicating authoritative meeting content.

## D211 — Start engine research with pinned static sqlite-vec exact (Aug 2026)

**Context:** D206-D210 make a non-serving candidate safe to compare, but the
first concrete engine choice can still confound the experiment. sqlite-vec now
has a stable v0.1.9 exact full-scan release and separate alpha ANN/DiskANN work;
USearch provides HNSW with Swift support. Starting with either approximate path
would mix packaging and execution cost with recall loss, build parameters, and
incremental-index behavior. macOS system SQLite also blocks dynamic extensions
by default, and a loadable dylib is an unnecessary signing and runtime surface.

**Decision:** the first disposable SEARCH-5 engine is sqlite-vec v0.1.9 exact
full-scan, statically compiled from the official amalgamation archive. The
archive is pinned to SHA-256
`b87cdda12112657ba5ab8842f0088a4090982eaf41f22b2bd6d495b81765a8c9`.
`scripts/vendor-sqlite-vec.sh` downloads that release URL or accepts the same
offline archive, verifies the digest before extraction, uses the upstream MIT
terms from the tagged source, and stages only C source, header, that
checksum-pinned license text, and provenance. The official amalgamation
manifest contains only `sqlite-vec.c` and `sqlite-vec.h`, so the reviewed MIT
text is retained separately under `scripts/vendor-metadata/` rather than
pretending it came from the binary release asset. Existing destinations are
never overwritten. Dynamic extension loading is forbidden.

This slice selects and secures the source but does not vendor it, change
`Package.swift`, create a schema or writer, implement a ranker, compose a
benchmark, or alter product behavior. The next slice must statically compile
the verified source and prove an isolated exact query before any meeting index
exists. sqlite-vec ANN prereleases and USearch HNSW remain later candidates.

**Rationale:** exact-versus-exact establishes packaging, latency, memory, disk,
and correction cost without approximate-recall ambiguity. A small dependency-
free C amalgamation fits the local-first and MIT/Apache policy, while strict
digest verification and static linking keep the experiment reproducible and
compatible with the signed macOS app. Deferring source activation also leaves
the current build fully reproducible when network access is unavailable.

## D212 — Compile sqlite-vec only as an isolated static research probe (Aug 2026)

**Context:** D211 selected and checksum-pinned the first exact engine source,
but linking a C extension into an app target before proving its static ABI would
expand signing and runtime risk without producing useful benchmark evidence.
The official release-asset transport was unavailable on the development host,
while GitHub still exposed the immutable `v0.1.9` tagged C blob and the tagged
header template through its authenticated content boundary.

**Decision:** vendor the C amalgamation byte-identical to Git blob
`de3176f9ca28a273c5086f1cc995ebf4e3c04c22` and SHA-256
`ba081a47fa02eadc3cf6b16c314b695b84081269349aac722b4efa338fe8fd85`.
Render the public header deterministically from the official tagged template,
fixed version, tag commit, and tag-commit timestamp; retain its digest, the
template/version blob identities, the archive digest, selected MIT license, and
acquisition explanation in `Vendor/sqlite-vec/PROVENANCE.md`. The canonical
vendoring script additionally verifies the archive's C digest and renders that
same header, so a later offline archive reproduces the activated files.

Compile the amalgamation textually inside `CSQLiteVecResearch` with
`SQLITE_CORE`, `SQLITE_VEC_STATIC`, and `SQLITE_VEC_OMIT_FS`. Only
`PortavozTests` depends on this target. Its sole executable proof opens an
in-memory SQLite database, registers `vec0` directly, inserts four fixed
vectors, and requires the exact query to return row 3 at zero distance. The app
and CLI do not link the target. This slice creates no meeting schema, writer,
ranker, shadow composition, durable observation, model, or user-visible path.

**Rationale:** one static smoke separates source/build compatibility from the
later ranking and benchmark experiment. Immutable blob and content digests keep
the fallback acquisition auditable without claiming that a blocked ZIP was
downloaded, while test-only linkage proves macOS compatibility without adding
code, filesystem helpers, or dynamic-loader surface to either shipping binary.

## D213 — Put a disposable sqlite-vec ranker behind authoritative projection (Aug 2026)

**Context:** D212 proved the pinned static amalgamation and one query, but it
did not exercise the D210 identity-only ranker contract or D207 aggregate
comparison path. A direct product dependency, persisted `vec0` table, or app
composition would grant an unmeasured engine authority too early. sqlite-vec
also permits only one KNN sort term, so equal-distance row order is not the
same deterministic contract as the current Accelerate traversal order.

**Decision:** add `SQLiteVecResearchKit`, reachable only by `PortavozTests`,
with `SQLiteVecExactShadowRanker` exposing an identity-only exact rank
primitive without depending back on `ApplicationKit`. A test-owned
`SemanticIndexShadowRanking` adapter provides the D210 research conformance.
Construction builds one disposable in-memory
cosine `vec0` table after validating one exact embedding profile, finite fixed-
dimension vectors, nonnegative transcript revisions, and unique segment IDs.
Queries require the same profile and emit only ordered segment/revision
identity. The native wrapper requests the complete exact result and retains a
bounded top-k by distance then original corpus position, making equal-distance
evidence deterministic before D210 projection. Task cancellation is checked
before and after native execution and signalled through a native atomic token
and SQLite progress handler.

Characterization composes the concrete ranker through
`ProjectedSemanticIndexShadowCandidate` and
`ShadowComparingSemanticIndex`: Accelerate control is returned immediately,
StorageKit rehydrates current citation evidence, and only payload-free
aggregate agreement is recorded. The app, CLI, and `ApplicationKit` do not
depend on either research target. This decision creates no product schema,
writer, durable receipt, app composition, or user-visible path, and accepts no
quality or resource evidence.

**Rationale:** exercising the complete Strangler path finds engine-specific
correctness differences before persistence or product integration. A
disposable index keeps authoritative data untouched and deletion/correction
fencing in StorageKit. Deterministic tie normalization prevents false rank
drift; its complete-result overhead is deliberately visible and must be
measured before any adoption decision.

## D214 — Measure exact engines through a content-free test root (Aug 2026)

**Context:** D213 exercises sqlite-vec behind the complete projection and
aggregate-shadow path, but a tiny characterization cannot establish scale cost
or parity. Reusing a product writer, persisting observations, or emitting
fixture identities would expand authority and privacy surface before the first
measurement contract is understood. Comparing build numbers without naming
their lifecycle boundaries would also be misleading because Accelerate reads
authoritative StorageKit rows while the disposable candidate starts from
prepared vectors.

**Decision:** add a test-only schema-1 exact-path harness over one deterministic
`synthetic-exact-path-v1` vector corpus. It runs the real scratch-`MeetingStore`
`AccelerateExactSemanticIndex` and `SQLiteVecExactShadowRanker` with the same
512-dimensional vectors, eight queries, top 10, and canonical 1k/10k/50k/100k
scales. Record fixture preparation, control-store build, candidate-index build,
and query wall distributions separately; alternate query execution order under
`alternating-query-order-v1`. Treat control build as source/FTS/embedding
publication cost and candidate build as prepared-vector index cost, not as a
direct build-speed contest.

The first 10k execution exposed sqlite-vec's hard 4,096 KNN result window in
the D213 complete-result query. Keep the candidate exact and deterministic by
using sqlite-vec's scalar `vec_distance_cosine` over the full virtual table,
ordering by distance then source row, and returning only requested top-k. Add a
4,097-row regression so canonical scales cannot silently fall back to an
unsupported KNN limit.

Run each selected scale in a fresh Release XCTest process. Emit one content-free
JSON object to stdout containing only host/configuration, byte/count, timing,
and aggregate agreement fields. Do not expose queries, vectors, citation
identity, transcript content, model identity, paths, or raw errors; do not
accept a durable output destination. The harness adds no product dependency,
schema, writer, app/CLI command, scheduler, accepted receipt, or selection.

**Rationale:** a closed synthetic root makes exact-path query cost and aggregate
agreement reproducible without borrowing user data or candidate authority.
Process isolation bounds cross-scale residency, separated phases prevent an
invalid lifecycle comparison, and stdout-only observations force a later
explicit validation/acceptance boundary before any engine decision.

## D215 — Accept exact-path evidence through one closed host receipt (Aug 2026)

**Context:** D214 emits useful content-free observations, but a copied line, a
partial scale run, mixed hardware, unstable timing, or a dirty source checkout
could still look like comparable evidence. Persisting raw observations first
would also bypass the explicit acceptance boundary. Cross-host selection cannot
be honest until every concrete host provides the same complete, source-bound
shape.

**Decision:** track one exact-path host-matrix contract. It requires the D214
schema-1 fixture and alternating query policy, Release configuration, 512
dimensions, eight queries, five runs per query, top 10, 1k/10k/50k/100k scales,
three observations per scale, Apple Silicon, Sequoia or Tahoe, and an existing
8 GB, 16 GB, or reference-memory profile. Reuse the established nearest-rank
stability rule: p95/p50 above 1.25 blocks each individual query observation or
repeated fixture, build, query-p50, or query-p95 distribution. Aggregate build
figures only within the same engine and scale; never use them to compare the
control's source/FTS/embedding publication lifecycle against the candidate's
prepared-vector lifecycle.

The evaluator consumes JSONL, rejects duplicate keys, unknown fields,
non-finite or inconsistent values, mixed hosts, noncanonical configuration or
engine order, incomplete result counts, excess observations, and byte-identical
copied observations. Missing scales, unstable timing, or less than full
expected-top-hit, engine-top-hit, or top-k-set overlap produce an exact-shaped
blocked receipt; malformed evidence produces no receipt. Exact ordered-rank
agreement remains visible but is not a host-receipt gate because equivalent
floating cosine implementations may order lower same-set results differently;
the separate multilingual MRR/nDCG scorecard owns that quality judgment. The
aggregate contains only source commit,
toolchain, closed host/configuration, byte/count/timing distributions,
agreement, and per-scale state.

The accepted runner starts from one clean commit, executes three complete D214
matrices through ephemeral owner-only files, then verifies that commit and
worktree are unchanged before exposing the aggregate on stdout. It accepts no
raw or aggregate output path. One passing receipt proves one concrete host
matrix only. It creates no product dependency, schema, writer, app command,
durable baseline, cross-host verdict, engine comparison, or selection authority.

**Rationale:** separating raw measurement, one-host acceptance, cross-host
comparison, and product selection makes every trust transition explicit.
Fail-closed exact shapes preserve privacy and expose missing or unstable work
without allowing one convenient developer run to become architecture policy.

## D216 — Validate three-profile evidence before retaining a baseline (Aug 2026)

**Context:** D215 accepts one host at a time, but its schema-1 receipt retained
only a final unstable label for the within-observation query ratio. A later
consumer could not independently recompute that state, and three individually
valid receipts could still be incomparable because of missing hardware tiers,
single-OS coverage, or different source/toolchain identities. None of those
conditions should silently become a baseline.

**Decision:** evolve the host receipt to schema 2. Every aggregate engine row
retains the maximum within-observation query p95/p50 ratio; `null` represents a
nonzero p95 over a zero median and is unstable. Add an exact host-receipt
validator that recomputes closed configuration, canonical scales, distribution
counts and monotonicity, timing/agreement state, and final outcome without raw
observations. It rejects an internal ratio below the lower bound demonstrated
by its own aggregate distributions. Cross-host candidate/control ratios with a
zero control denominator are `not-comparable`, including zero divided by zero,
rather than an invented equality result.

Track a separate cross-host contract requiring exactly one receipt for each
8 GB, 16 GB, and reference-memory profile. The three-host set must represent
both supported OS majors, Sequoia and Tahoe, at least once; do not require the
unnecessary six-machine profile-by-OS Cartesian product. A passing scorecard
also requires one source commit, one Apple Swift toolchain, and a passing host
receipt for every profile. Missing profile or OS coverage, valid blocked host
evidence, or source/toolchain mismatch emits a complete blocked scorecard.
Malformed, duplicate, payload-bearing, or repeated-profile evidence emits no
scorecard.

The stdout-only scorecard may expose closed host/configuration fields, separate
engine query p50/p95, candidate-to-control query ratios, exact-rank agreement,
byte counts, and lifecycle-labelled build p50 values. It accepts no output
destination. The versioned comparison policy divides candidate query timing by
the control timing measured on that same host; a zero control denominator is
`not-comparable`, never reported as an equal-performance ratio. The scorecard
authorizes no retained baseline, budget, quality judgment, engine selection,
product schema, writer, app composition, or user-visible candidate. Accelerate
exact remains the sole serving authority.

**Rationale:** coverage and comparability must be proven before performance can
be interpreted. Recomputable receipts prevent a status label from becoming a
trust shortcut, while a three-profile/two-OS matrix captures the supported
resource and compatibility surfaces without multiplying machines that add no
new acceptance dimension. Keeping the scorecard ephemeral preserves a final,
explicit baseline-review and engine-decision boundary.

## D217 — Retain one exact-path research baseline only after digest-bound review (Aug 2026)

**Context:** D216 can prove that three independently accepted host receipts form
one comparable cross-host scorecard, but deliberately emits that scorecard only
to stdout. Redirecting stdout to a file is not an acceptance act: the file could
change after review, come from a different source checkout, omit its receipts,
or be mistaken for an engine-selection decision. A boolean `--accept` would
record intent without binding that intent to the exact artifact reviewed.

**Decision:** track one schema-1 baseline-admission contract and a tooling-only
publisher. Admission requires the canonical D216 scorecard stdout file, its
complete three-receipt JSONL source, the lowercase SHA-256 of the exact scorecard
file, and its sole source commit. The active checkout must be clean at that
commit before validation, immediately before publication, and immediately after
publication. A final source mismatch withdraws the new artifact.

Recompute the scorecard exactly from independently validated schema-2 receipts
and the active contracts. Require a passing scorecard, canonical profile order,
canonical stdout bytes, bounded UTF-8 JSON/JSONL inputs, exact scalar types, and
no duplicate or unknown fields. Publish one owner-only file atomically without
replacement. A destination inside the repository must already be ignored. The
retained envelope includes the scorecard, its three aggregate receipts, source
commit, scorecard-file and canonical receipt-set digests, and the review-policy
version. It permanently fixes `authority` to `research-comparison-only` and
`engineDecision` to `not-evaluated`; it accepts no reviewer identity or free-form
notes.

No real baseline is added to source control and this boundary defines no timing
budget, quality verdict, candidate winner, product schema, writer, app
composition, or user-visible authority. Accelerate exact remains the sole
serving adapter.

**Rationale:** explicit digest and source acknowledgement binds maintainer intent
to one immutable aggregate evidence set instead of a mutable pathname or a
click-through flag. Revalidation keeps the source receipts auditable, while
private non-overwriting publication prevents an accepted run from being silently
replaced. The acknowledgement does not authenticate the reviewer or prove
engine superiority; those remain separate human and later selection gates.

## D218 — Measure exact-path corrections through atomic disposable mutations (Aug 2026)

**Context:** D214-D217 isolate exact query scale, host acceptance, cross-host
comparison, and reviewed baseline retention, but SEARCH-5 also requires
incremental add/update/delete and correction cost. Rebuilding the disposable
candidate after every edit would hide its maintenance behavior; adding a writer
to product storage before measuring it would grant an unselected engine durable
authority. A mutable in-memory candidate can also corrupt deterministic tie
order if deleted slots are silently reused or Swift identity state advances
before the native transaction commits.

**Decision:** extend only the test-owned sqlite-vec exact ranker with one atomic
mutation batch. Existing segment identities update in their original source-row
slot, deleted slots remain empty permanently, and new identities append as one
contiguous suffix. Validate profile, dimensions, finite vectors, revisions,
duplicate identities, missing deletes, overlaps, and append shape before
starting one native `BEGIN IMMEDIATE` transaction. Delete/replace rows and add
new rows inside that transaction; on any failure roll back and leave the actor's
identity slots unchanged. Query bounds use live-row count while row validation
uses the monotonic slot count.

Add a test-only `synthetic-exact-path-mutation-v1` harness over the same
1k/10k/50k/100k, 512-dimensional exact corpus family. Measure add, update, and
delete batches of 1, 10, and 100 for five runs by default, alternating which
engine mutates first. After every operation, require the real scratch-store
Accelerate control and sqlite-vec candidate to agree on top hit and top-k source
identity; retain exact ordered-rank agreement as a diagnostic. Record one full
reconstruction per engine, but label control source/FTS/embedding publication
and candidate prepared-vector construction as different lifecycles rather than
comparing their values directly. Label mutation timing separately for the same
reason: control add/update/delete includes authoritative source and embedding
publication, while the candidate receives prepared vectors. A raw observation
must not report a cross-engine mutation ratio.

Emit one schema-1, content-free stdout observation from a fresh Release XCTest
process per scale. The report may contain only closed operation names,
host/configuration, byte/count, timing distributions, and aggregate agreement;
it accepts no output path. This slice creates no accepted mutation baseline,
cross-host correction receipt, crash/interruption proof, product schema, durable
writer, app/CLI wiring, or serving authority. Accelerate exact remains the only
product adapter.

**Rationale:** atomic disposable mutation semantics expose the candidate's real
incremental cost without risking authoritative user data. Stable monotonic slots
preserve deterministic ties across corrections, and post-operation rank checks
make deletion or update drift visible. Keeping raw measurements stdout-only
preserves separate resource acceptance and engine-decision gates.

## D219 — Require human review for complete mutation host evidence (Aug 2026)

**Context:** D218 emits deterministic correction-cost observations, but one
development smoke or one timing sample cannot support an engine decision.
Reusing D215's 1.25 timing-stability threshold would silently declare a
performance policy before mutation evidence exists on the required hardware.
Retaining raw observations would also widen the research-data surface, while a
receipt named `pass` could be confused with resource acceptance.

**Decision:** define a separate schema-1 mutation-host contract over exactly
three D218 observations per canonical 1k/10k/50k/100k scale. Every observation
must come from one supported declared memory profile and OS, a Release build,
the exact fixture/measurement/lifecycle versions, canonical engine and
operation order, 1/10/100 batches, five samples per batch, finite monotonic
timings, and bounded agreement counts. Duplicate JSON keys, copied
observations, mixed hosts, excess evidence, unknown fields, and malformed
configuration produce no receipt. Missing coverage or top-hit/top-k-set drift
produces a complete `blocked` receipt.

When coverage and agreement are complete, emit `review-required` under
`human-threshold-free-mutation-review-v1`, not `pass`. Retain aggregate
nearest-rank distributions for fixture preparation, full reconstruction, and
each operation/batch, including within-observation p95/p50 ratio diagnostics.
Do not compare the unlike control/candidate lifecycle values and do not apply a
numeric timing threshold. The clean-source runner binds the receipt to source
commit, Apple Swift toolchain, host profile, OS, and contract versions, checks
the checkout before and after collection, accepts no output path, and deletes
the temporary raw observations.

This slice creates no real receipt, accepted baseline, cross-host verdict,
performance threshold, product schema/writer, app/CLI composition, serving
change, or migration authority. Accelerate exact remains the only product
adapter.

**Rationale:** structural completeness and rank parity can be enforced before
real resource distributions exist, while timing policy cannot. An explicit
human-review outcome makes that distinction machine-readable and prevents
premature engine selection without sacrificing aggregate evidence needed for
the later cross-host decision.

## D220 — Keep cross-host mutation evidence in explicit review (Aug 2026)

**Context:** D219 can prove that one host produced complete, content-free
mutation observations with top-hit and top-k-set parity, but its
`review-required` outcome is deliberately not a performance pass. Reviewing
the required hardware matrix needs one portable document without silently
introducing the query benchmark's candidate/control ratios or accepting a
threshold before real correction-cost evidence exists.

**Decision:** define a separate schema-1 cross-host review contract over
exactly one revalidated D219 receipt for each 8 GB, 16 GB, and reference
profile. The three receipts must collectively cover Sequoia and Tahoe and use
one source commit, Apple Swift toolchain, fixture, measurement policy, host
review policy, and Release configuration. Duplicate JSON keys, repeated
receipts or profiles, tampered nested evidence, unsupported identity, and
non-canonical scorecards produce no document. Missing coverage, a blocked host
receipt, or source/toolchain divergence produces a complete `blocked`
scorecard.

Complete comparable evidence remains `review-required` under
`human-threshold-free-mutation-cross-host-review-v1`. Preserve per-host
aggregate rebuild and operation/batch distributions plus agreement counts for
human review, but derive no candidate/control speed ratio, numeric threshold,
or automatic pass. Build the scorecard as a detached value and require exact
recomputation from its receipts. The CLI reads aggregate JSONL and writes only
stdout; it does not retain a baseline.

This slice creates no real field scorecard, accepted baseline, product schema,
writer, adapter choice, app/CLI product composition, migration, or rollback
authority. Accelerate exact remains the only product adapter.

**Rationale:** hardware and OS coverage, input integrity, and common build
identity are objective gates; unlike lifecycle performance is a review input.
Keeping the outcome explicit prevents a complete evidence bundle from being
mistaken for a product decision while making later maintainer review fully
recomputable.

## D221 — Retain mutation evidence only after explicit human acknowledgement (Aug 2026)

**Context:** D220 produces one exactly recomputable cross-host mutation
scorecard, but complete evidence deliberately remains `review-required` because
control and candidate mutation timings describe unlike lifecycle boundaries.
Redirecting that scorecard to a file neither records that a maintainer reviewed
the distributions nor binds the review to immutable source evidence. Reusing
the passing-query baseline contract would also imply performance authority that
the correction-cost evidence does not have.

**Decision:** define a separate schema-1 mutation-baseline admission contract.
Admission requires one canonical D220 scorecard file, its lowercase SHA-256,
its sole source commit, the exact three-receipt JSONL source, and the literal
human acknowledgement `timings-reviewed-no-engine-decision-v1`. Revalidate the
scorecard from independently validated receipts and preserve their canonical
8 GB, 16 GB, and reference order. Only a complete `review-required` scorecard
is admissible; blocked or malformed evidence produces no baseline and admission
does not convert the outcome into `pass`.

The active checkout must be clean at the accepted commit before evidence is
read, immediately before publication, and immediately after publication. A
post-publication mismatch withdraws the artifact. Publish one bounded,
owner-only file atomically without replacing an existing path. Repository-local
destinations must already be ignored. The retained envelope includes the exact
scorecard, its three aggregate receipts, source commit, scorecard-file and
canonical receipt-set digests, review policy, and fixed acknowledgement. Shared
private-publication primitives enforce this policy for both query and mutation
research baselines.

The envelope permanently fixes authority to
`research-correction-cost-only`, with `engineDecision` and
`performanceDecision` both `not-evaluated`. It accepts no reviewer identity or
free-form notes. No real mutation baseline is added to source control, and this
boundary creates no threshold, engine verdict, product schema, writer, app
composition, migration, or rollback authority. Accelerate exact remains the
sole serving adapter.

**Rationale:** an explicit, fixed acknowledgement makes the required human
timing review machine-checkable without pretending to authenticate a reviewer
or to prove one engine faster. Digest, receipt, and source binding make the
retained aggregate reproducible; private non-overwriting publication prevents
later replacement from silently changing what was reviewed. Keeping the
scorecard's original `review-required` outcome preserves the separation between
evidence retention and any future performance or product decision.

## D222 — Freeze Meeting Detail behavior before decomposition (Aug 2026)

**Context:** Meeting Detail remains the largest presentation surface and the
next roadmap band will split its scene, generated document, transcript,
playback, and secondary flows. Existing feature tests cover released journeys,
but no machine-readable boundary assigned every journey to one owner or
detected unreviewed changes across controls, identifiers, routes, sheets, and
keyboard behavior. The older 5,000-segment baseline measured first projection
and health work but not playback seek or 20,000-segment transcript scrolling.

**Decision:** generate and track a canonical Meeting Detail interaction
contract before changing the composition. It snapshots source-derived state,
control, presentation, keyboard, identifier, and navigation signals across the
reviewed detail files; assigns every `MeetingDetailUITests` journey to exactly
one of ten feature owners; derives screenshot ownership from each test body;
and binds the performance evidence, parser, and runner by SHA-256. Any boundary,
owner, test, screenshot, or evidence change requires an explicit snapshot.

Extend the disposable scale fixture to 5,000 and 20,000 segments. Hidden
performance journeys require `-use-temp-store`, `-seed-scale`, and
`-detail-performance-profile` together, emit payload-free signposts, and never
read the user library. The 5k profile uses generated two-channel audio for
exactly five seeks; the 20k profile performs exactly five transcript scrolls.
SwiftUI and Animation Hitches traces retain a deterministic delayed summary
mutation, while the Logging trace excludes it so the view replacement cannot
cancel the interaction loop. Missing, excess, malformed, or referenced-cycle
samples fail closed. The runner refuses the notarized release bundle.

The Aug 2026 Xcode 26.6 evidence records 5k/20k first content at
111.25/197.35 ms, seek/scroll p95 at 0.52/331.94 ms, and zero app hitches or
potential hangs. Time Profiler contains both detail and transcript symbols.
The SwiftUI template emitted no update rows for either profile, so exact body
invalidation counts remain `unavailable-toolchain`; they are not zero and do
not become an acceptance claim. The evidence is a refactor-parity baseline,
not production telemetry, a product schema, or a new performance budget.

**Rationale:** a reviewed inventory makes Strangler decomposition auditable:
each extracted section must preserve its owner, journey, screenshot, and
measured behavior. Restricting automation to a disposable store prevents
benchmark code from becoming a production back door. Recording unavailable
tool output explicitly preserves trust while still providing actionable first-
content, interaction, hitch, hang, and symbol evidence for later decomposition.

## D223 — Own Meeting Detail composition in an explicit scene (Aug 2026)

**Context:** the D222 contract froze released behavior, but
`MeetingDetailView` still observed process-wide `AppServices`, constructed its
own route model, and mixed locale-dependent formatting with a 2,400-line
presentation. Extracting visual sections on top of that ownership would let
every child inherit the composition root and make route lifetime ambiguous.

**Decision:** route every selected meeting through `MeetingDetailScene`. The
scene is the sole Meeting Detail presentation type that receives `AppServices`
and owns one `MeetingDetailModel` in `@State` for the route lifetime. The route
keys scene identity by `MeetingID`, preventing a new destination from retaining
the previous route's state. It passes
the child immutable observed values and explicit meeting-scoped actions; the
child never receives or discovers `AppServices`. Keep application workflows in
their current owners and preserve every released gesture and result while the
later decomposition narrows each section to only its relevant closure.

Move locale and time-zone formatting into a Foundation-only,
side-effect-free `MeetingDetailPresentation` value. It receives all varying
inputs explicitly and cannot reach storage, platform capability, clocks, or
application services. Expand the D222 reviewed source boundary to include the
scene, producing 252 interaction signals across twelve files while preserving
the same 23 journeys and ten feature owners. Scene/presentation diffs select
all Meeting Detail UI journeys until later sections have independent mappings.

**Rationale:** explicit scene ownership gives the route one observable model,
makes the composition root mechanically enforceable, and creates a stable
Strangler seam without a feature-parity rewrite. Pure presentation formatting
is deterministic and directly testable, while explicit action projection keeps
future child views from gaining broad capabilities by convenience.

## D224 — Compose Meeting Detail from explicit review sections (Aug 2026)

**Context:** D223 established one route owner, but `MeetingDetailView` still
implemented meeting identity and participants, durable processing/privacy
trust, and the complete generated document in the same large presentation
type. That concentration mixed unrelated local UI state, made narrow UI-test
selection impossible, and allowed a canonical Markdown action-item appendix to
appear beside the equivalent typed To-dos controls.

**Decision:** extract `MeetingDetailHeaderSection`,
`MeetingDetailTrustSection`, and `MeetingGeneratedDocumentSection`. Each child
receives immutable values and explicit actions and is forbidden from reaching
`AppServices`, `MeetingDetailModel`, storage, or global preferences. Header
suggestions remain inert until accepted and expose independent dismissal
actions. The trust section owns only retry progress. The generated-document
section owns only tab selection and keeps current/stale/unavailable evidence
actions adjacent to overview, decision, open-question, and action-item claims;
Apuntador reuses the same content-free evidence control.

Add a Foundation-only `MeetingGeneratedDocumentPresentation` projection. It
preserves each Markdown section's original ordinal so persisted evidence keeps
resolving after visual filtering. It suppresses canonical `Action Items` or
`Pendientes` sections only when typed commitments exist; otherwise legacy or
partial summaries retain their Markdown content. Expand the reviewed
interaction boundary to 265 signals across fifteen source files while keeping
the same 23 UI journeys and ten owners, and map each extracted section only to
its owned feature tests.

**Rationale:** focused sections make presentation ownership and mutation
capability auditable without changing the route or application workflow.
Keeping ephemeral state beside its control reduces unrelated invalidation.
The pure projection prevents duplicate task presentation without weakening
legacy data or proof coordinates, and the shared evidence surface keeps trust
behavior consistent wherever generated claims appear.

## D225 — Read transcripts through a correction-ready snapshot (Aug 2026)

**Context:** D224 removed generated-document presentation from the Meeting
Detail coordinator, but that coordinator still built transcript rows, computed
chapters, owned evidence focus, and wired every seek. Playback also found the
active row by scanning the complete transcript every 200 ms. A later
correction overlay must be able to split or merge visible rows without breaking
persisted evidence coordinates or teaching SwiftUI which transcript version is
authoritative.

**Decision:** make `ApplicationKit.MeetingTranscriptContent` the immutable
reading snapshot consumed by Meeting Detail. Each stable visible row carries
its ordered immutable source-segment identities, speaker, channel, spoken
language, timing, confidence, and finality. Chapters are projected from the
same snapshot. The current `accepted` factory remains a one-source-to-one-row
projection; a future correction composer may provide split or merged rows
through the same public value without introducing correction policy into the
view.

Resolve evidence routes by source-segment identity and Library/Ask/Spotlight
routes by timestamp. One small navigation value retains the focused visible row
and an exact pending seek until playback exists. Active playback lookup uses a
start-time upper-bound search plus a maximum-end segment tree, preserving the
released overlap and gap behavior in logarithmic time rather than rescanning a
large meeting on every playhead update.

Extract the transcript and chapter surfaces behind explicit immutable values
and actions. Row rendering remains a stable-ID `LazyVStack`; the shared focused
viewport is generic over identifiable rows and keeps its playback-versus-live
follow ownership as a pure policy. These presentation types cannot access the
route model, services, store, or global preferences. Expand the reviewed
interaction boundary to 267 signals across sixteen source files while retaining
the same 23 UI journeys and ten feature owners. Transcript-section and reading-
snapshot diffs select only audio, evidence, chapter/health, and scale journeys.

**Rationale:** source mappings let immutable generated evidence survive future
visual correction composition. One reading snapshot prevents rows and chapters
from disagreeing, while indexed playback work keeps synchronization cost
bounded for long meetings. Explicit values/actions preserve the D223 scene as
the route owner and make correction policy independently testable before any
editable overlay is introduced.

## D226 — Compose Meeting Detail playback through one explicit section (Aug 2026)

**Context:** D225 extracted transcript reading and navigation, but the Meeting
Detail coordinator still rendered the complete docked player and audio-
compression status inline. That left transport, waveform, clip export, clear
playback, voice-only playback, and compression presentation split across the
route coordinator and `MeetingPlayerBar`, making the playback boundary harder
to review and narrowly test.

**Decision:** extract `MeetingDetailPlayerSection` as the complete docked
playback presentation boundary. It receives only the current playback session,
immutable waveform buckets, compression capability/progress/message values,
and explicit clip-export and compression actions. Playback preparation,
compression, file re-resolution, pending seeks, and route lifetime remain in
the model and application workflow; the section imports neither
`AudioPlaybackKit` nor storage and owns no local state. `MeetingPlayerBar`
continues to own only focused player interaction state and the native save
panel needed for clip export.

Give the section one accessibility-contained root without masking its existing
nested controls. Map changes to this boundary only to the four playback and
clip journeys. Expand the reviewed interaction boundary to 268 signals across
seventeen source files while retaining the same 23 UI journeys and ten feature
owners.

**Rationale:** one explicit playback section makes the visual and interaction
boundary auditable without moving audio policy into SwiftUI. Immutable values
and narrow intents preserve the scene/model/application ownership chain, while
focused UI-test selection protects released playback behavior without running
unrelated Meeting Detail journeys.

## D227 — Own Meeting Detail secondary flows through explicit boundaries (Aug 2026)

**Context:** D226 extracted the playback dock, but the Meeting Detail
coordinator still rendered the action row, secondary rail, and persisted
Companion cards inline. It also owned separate booleans and payloads for
rename, recap, custom structure, Gist, summary setup, speaker identity, person
linking, and file export. Those independent flags could represent impossible
overlapping presentations and made each flow hard to review or test without
selecting the whole detail surface.

**Decision:** extract two additional values/actions boundaries.
`MeetingDetailActionSection` owns Refine, recap, export, Gist, and delete
controls. `MeetingDetailRailSection` owns the independently scrolling recovery,
privacy, health, chapters, and persisted Companion presentation. Their
application work remains in the route model and ApplicationKit. They import no
storage or composition root and own no local presentation state. Health
availability is projected once by the coordinator so the rail does not rescan
large transcripts merely to decide whether it is visible.

Move route-lifetime presentation state to one scene-owned
`MeetingDetailFlowState`. One typed route per sheet, dialog, alert, and file
export makes mutually exclusive presentations unrepresentable, while explicit
operation state may coexist with them. Refine review and the post-meeting mirror
remain source-derived sheets because their lifetimes belong to the Refine
service and just-recorded state rather than an independent Boolean.

Give every extracted surface one accessibility-contained root without masking
its existing nested controls. Map each new file only to its owned UI journeys.
The reviewed interaction boundary now contains 262 signals across twenty source
files while retaining the same 23 UI journeys and ten feature owners.

**Rationale:** explicit sections make secondary behavior auditable without
moving audio, persistence, identity, or processing policy into SwiftUI. Typed
routes eliminate contradictory modal state. Immutable values, narrow intents,
and feature-scoped tests preserve the scene/model/application ownership chain
while protecting released behavior without running unrelated journeys.

## D228 — Complete Meeting Detail through route-level composition (Aug 2026)

**Context:** D224–D227 extracted the stable visual sections and replaced
independent modal flags, but `MeetingDetailView` still implemented document,
identity, Refine, notes, and platform effects in a collection of private
extensions. It also retained cross-section transcript/playback navigation and
modal rendering alongside the route observation lifecycle. The visible
sections were narrow, but effect and presentation ownership remained harder to
audit than the intended final architecture.

**Decision:** keep `MeetingDetailView` as a compact route projection and
observation-lifecycle surface, capped by architecture tests at 500 physical
lines. Project a short-lived `MeetingDetailCoordinator` value from the route's
model, scene values/actions, and scene-owned flow state. The coordinator owns
no observation state and translates only explicit feature intents into route
model or scene effects; identity and document operations live in focused
extensions. Presentation children never receive the coordinator, model,
services, storage, or provider adapters.

Move sheets, dialogs, alerts, and file export into `MeetingDetailFlowHost`,
which receives typed flow values and platform actions explicitly. Extract raw
and enhanced notes into `MeetingDetailNotesSection`, Refine comparison into
`MeetingDetailRefineReviewSheet`, and cross-section evidence/player navigation
into one view-lifetime `MeetingDetailPlaybackNavigation`. The navigation owner
may operate an already prepared playback session but cannot construct audio,
storage, model, or provider capabilities. Keep summary regeneration and its
search invalidation in one structured task so the extraction does not change
operation ordering. Keep route mutation and the `mirrorAfterMeeting`
preference in `MeetingDetailScene`; the child receives only explicit route and
preference actions plus the projected preference value.

Expand the reviewed interaction boundary to 263 signals across 27 source
files while retaining ten feature owners and all 23 UI journeys. Add explicit
UI-scope mappings for every new file and architecture tests that reject direct
model effects in the root, broad dependencies in presentation children, and
unbounded root growth.

**Rationale:** route-level composition makes state and effect ownership
legible without introducing a second observable owner or a feature-parity
rewrite. Focused values/actions surfaces can be tested and changed
independently, while the route model remains the application effect owner and
scene flow remains the presentation-state owner. Preserving structured
concurrency, interaction contracts, and scoped UI selection makes removal of
the monolith a mechanical refactor rather than a behavioral migration.

## D229 — Define correction composition before persistence (Aug 2026)

**Context:** D225 gave Meeting Detail a correction-ready reading snapshot, but
the system had not defined how several edits compose, which revision they may
target, or when downstream consumers see them. Starting with storage or UI
would make persistence details decide domain semantics and could silently feed
partially corrected text into search, summaries, exports, or generated
evidence.

**Decision:** keep accepted raw or refined transcript segments immutable and
define a pure ApplicationKit `ComposeTranscript` operation first. A typed event
may replace text, change speaker attribution, split one segment, merge adjacent
same-speaker/channel segments, suppress exactly one row, or restore a
superseded edit. Each event targets one explicit accepted revision and
immutable segment IDs. Identity-first input validation plus deterministic
source and `(createdAt, UUID)` composition ordering selects active events;
stale revisions, missing or repeated targets, overlapping active events,
branched or target-changing supersession,
non-finite event times, nonlexical replacements, partial or gapped splits,
out-of-order/incompatible merges, provisional base rows, and ambiguous output
row identities fail before a composed snapshot is returned. A split must
partition the complete source interval, and both merge targets and
supersession targets preserve their explicit source order.

Both accepted and composed readings use `MeetingTranscriptContent`. Every row
retains its source-segment IDs, and `MeetingTranscriptLineage` identifies raw
versus refined material, the selected accepted/composed projection, and active
correction IDs. The projection remains explicit even when composed and
accepted rows are currently identical. Downstream use is an explicit
`TranscriptReadingPolicy` choice, guarded by an initial source allowlist that
contains only the composer itself. This slice deliberately adds no tables,
migration, sync envelope, editing surface, invalidation, or automatic consumer
switch; all current product paths remain on accepted content.

**Rationale:** freezing composition semantics independently makes later event
storage additive and keeps SwiftUI, GRDB, and generated artifacts from becoming
policy authorities. Explicit lineage preserves auditability and source
navigation, while fail-closed validation prevents stale or ambiguous edits
from changing what users read. Deferring consumer adoption preserves every
released feature until each path has its own correction and invalidation
contract.

## D230 — Persist and synchronize correction history without product adoption (Aug 2026)

**Context:** D229 defines correction composition independently from storage,
but process-local values cannot survive relaunch, explain undo, or synchronize
across an opted-in private library. Letting a database row, opaque JSON payload,
or transport adapter become the first durable contract would collapse domain
validation, local persistence, cross-device convergence, and downstream product
adoption into one risky migration.

**Decision:** move the portable correction event and its typed payloads into
`PortavozCore`. Each immutable event records the meeting and accepted transcript
revision, ordered source-segment targets, operation kind, user author, source
device, creation/update time, optional tombstone, and optional predecessor. A
strict format-1 transport-neutral envelope canonicalizes order and rejects
unknown versions, malformed operation shapes, duplicate identities, missing or
branched predecessors, target-changing supersession, wrong meetings, and
overlapping live terminal events. Meeting-local accepted targets, speakers,
split intervals, and merge adjacency remain StorageKit validation because they
require one current database snapshot.

Add schema v19 with normalized `transcriptCorrection`, ordered target, scalar
payload, and split-part tables. Parent material and child payload rows are
immutable. The only update is one monotonic tombstone transition for privacy or
malformed-event removal; undo is a new restore event that supersedes the current
terminal event. Appending validates and inserts the complete event atomically,
and an exact retry is idempotent after timestamps are canonicalized to database
millisecond precision. History reads include tombstones so removing a terminal
event cannot reactivate its predecessor. Target rows deliberately omit a
segment foreign key: a later Refine replacement or source purge may make the
target unavailable but must not rewrite what the user corrected. Every schema
v1-v18 library migrates through empty additive tables, and legacy/imported
meetings receive no synthetic events.

Correction parent inserts and tombstones advance the content-free meeting sync
journal exactly once; ordered targets and typed payload children never create
extra generations. Meeting aggregate format 2 transports the canonically
ordered typed history. Replay rejects immutable identity or payload rewrites and
tombstone regression before replacing v2 history atomically. A legacy format-1
aggregate cannot carry corrections and therefore preserves local correction
history rather than treating absence as deletion. Trigger-generated replay
work is acknowledged inside the same aggregate transaction.

Persistence and synchronization do not authorize product adoption. Meeting
Detail, search, summaries, exports, generated evidence, chapters, and playback
continue to read accepted material. Derived invalidation and editing UI require
later explicit decisions and characterization boundaries.

**Rationale:** one Core contract lets local persistence and future transports
share deterministic validation without reversing StorageKit and ApplicationKit
dependencies. Typed additive tables make migration, corruption, and rollback
observable; append-only undo and retained tombstones preserve auditability.
Separating durable convergence from product visibility preserves every released
feature while the remaining correction policies are implemented incrementally.

## D231 — Adopt focused text and speaker corrections in Meeting Detail (Aug 2026)

**Context:** D230 made correction history durable and convergent but deliberately
kept every product path on accepted transcript material. The first editing
surface must let a user correct ordinary text and attribution without making
SwiftUI a domain authority, destructively rewriting evidence, or silently
presenting stale summaries and search results as corrected.

**Decision:** model text and speaker attribution as independent correction
domains. Both may be active on the same accepted source segment, while
split/merge/suppress remains one exclusive structural domain. A restore inherits
its predecessor's domain, and malformed or cyclic history fails closed. Add the
ApplicationKit `CorrectMeetingTranscript` command: it loads and validates the
complete retained history, accepts one current accepted source row, derives the
active terminal per domain, and atomically appends only the changed text and
speaker events. Returning a domain to its exact original value emits a
superseding restore event. A no-op emits nothing; exact unchanged text is never
trimmed by a speaker-only edit. Both events use the same stable installation
source-device identity.

Extend the scoped Meeting Detail read model with ordered correction history and
raw/refined base identity. Its application projection composes only events for
the currently observed transcript revision; composition failure returns the
accepted snapshot rather than partially applying history. No other consumer is
authorized by this slice: search, summaries, exports, generated evidence, and
semantic/FTS indexes remain on accepted material until explicit invalidation and
adoption decisions land.

Expose correction through a focused SwiftUI editor reachable only from a visible
row that maps to one accepted source segment. It offers text and speaker controls,
immutable original evidence, append-only history, keyboard default/cancel
actions, progress/error state, durable Undo, and stable accessibility identifiers.
A structurally corrected row explains why text/speaker editing is unavailable
instead of opening an ambiguous editor. Presentation receives values and actions
only; it imports neither StorageKit nor the meeting store. The reviewed Meeting
Detail interaction contract now contains 289 signals, eleven owners, and 24 UI
journeys, including one disposable end-to-end save/reopen/undo journey with
app-window evidence.

**Rationale:** independent lanes match the user's intent without forcing an
unrelated text rewrite when attribution changes. Atomic application commands,
immutable originals, and append-only restores preserve auditability and sync
convergence. Limiting adoption to Meeting Detail gives immediate value while
keeping every derived consumer honestly stale until the next correction slices
define invalidation and regeneration.

## D232 — Make structural transcript corrections explicit and recoverable (Aug 2026)

**Context:** D231 adopted text and speaker lanes but intentionally left split,
merge, and suppress unavailable. Structural edits need stronger target and time
rules, and suppression must not become a convenient path to erase accepted
recording evidence.

**Decision:** add an ApplicationKit `RestructureMeetingTranscript` command over
one exact accepted projection and revision. Split requires two lexical outputs
and a strictly interior time boundary. Merge requires an explicit ordered,
contiguous selection from one meeting, speaker, and audio channel; Meeting
Detail offers only pairwise previous/next candidates and never infers a merge.
Accepted merge intervals must remain time-monotonic. Generated event and split-
part identities retry within one bounded budget and fail closed if they collide
with accepted rows, retained events, or historical split parts.
Suppress appends a typed event and removes only the composed row. Every output
retains the ordered accepted source map.

Expose structural actions through the focused correction surface. A hidden-
line review keeps exact accepted text visible and offers durable Restore after
the row leaves the composed reading. Restore remains immutable terminal lineage but is not applied to the reading
projection or retained as a target owner, so restored evidence may receive a
later explicit correction. Property lanes and structure remain mutually
exclusive while active. The route supplies immutable values and explicit
actions; SwiftUI owns no correction or persistence policy. One immutable
structural projection precomputes accepted evidence, active ownership, merge
candidates, and hidden rows for the complete Meeting Detail snapshot, leaving
visible-row lookups constant time. Its bidirectional source map uses an evidence
timestamp to select the matching visible split part and preserves the reverse
mapping to immutable sources. The reviewed Meeting Detail boundary now
contains 328 interaction signals, eleven owners, and 25 UI journeys.

No derived consumer adopts structural corrections in this decision. Search,
summaries, generated evidence, exports, chapters, FTS, and semantic indexes stay
on accepted material until a separate invalidation policy prevents stale work
from publishing.

**Rationale:** explicit selection prevents grouping guesses, complete source
maps preserve future audio navigation, and recoverable suppression removes
reading noise without deleting evidence. Keeping invalidation separate avoids
silently mixing corrected presentation with stale derived artifacts.

## D233 — Fence derived artifacts by effective correction lineage (Aug 2026)

**Context:** D229–D232 make transcript correction composition deterministic,
durable, synchronized, and editable in Meeting Detail, but deliberately leave
derived consumers on accepted material. Without one correction identity and an
atomic invalidation boundary, old summary/index work can publish after an edit,
fingerprint-identical cache entries can be reused from the wrong transcript
overlay, and immutable summaries or Apuntador cards can look current while their
source evidence has changed.

**Decision:** define `TranscriptCorrectionRevision` as the convergent identity
of the effective correction overlay for one accepted transcript revision. It is
the literal `accepted` value when no event is active; otherwise it is a SHA-256
fingerprint over meeting identity, accepted transcript revision, and the
canonically ordered effective event IDs. Malformed history has no valid
revision and fails closed.

StorageKit computes that revision in the same database snapshot as correction
append, tombstone, and format-2 sync replay. Only a before/after change cancels
pending or running accepted-only `summary` and `index` jobs and advances the
independent semantic-corpus source generation. Transcription and diarization
work remain valid. Its timestamp is the maximum of the correction event,
meeting, affected jobs, and current semantic-maintenance source, preventing an
older synced event from moving local maintenance metadata backward. No
correction transaction starts model execution or rewrites an immutable
generated artifact.

Every accepted-only retrieval path shares one SQL predicate that removes source
rows with active corrections from FTS candidates, semantic reads, embedding
candidates, vector publication, and current identity projection. Unaffected rows
remain searchable. Restore makes an accepted row eligible again and the source-
generation advance wakes maintenance. Corrected text is not yet materialized in
an index, so this decision prefers an honest omission over returning stale text.

Summary and Apuntador generation runs carry both accepted transcript revision
and effective correction revision. Apuntador includes both in its operation
fingerprint; the summary fingerprint remains content-derived, while cache and
translation-pivot reuse additionally require a linked run with matching
lineage. StorageKit rechecks the same lineage inside each artifact publication
transaction. Legacy provenance is accepted only for an uncorrected
revision-zero meeting.
Explicit summary regeneration and review-metadata suggestions use composed rows.
Generated evidence is projected back to ordered immutable accepted source IDs
before persistence.

The reviewed Meeting Detail boundary advances to 332 interaction signals,
eleven owners, and 26 UI journeys, including one deterministic stale-
artifact journey. Meeting Detail retains old summaries and Apuntador cards
as immutable history but marks them stale, disables their evidence as
current proof, offers explicit
summary regeneration, and clears route-local generated chapter/title/recipe
suggestions when correction lineage changes. Automatic Apuntador regeneration,
corrected-text search/index storage, and composed export remain separate future
adoptions.

**Rationale:** one content-derived correction identity converges across devices
without a mutable counter. Transactional cancellation plus publication fences
prevents stale work at both ends of the race. Retaining immutable artifacts with
truthful freshness preserves auditability, while explicit on-demand generation
avoids surprising model cost and keeps correction writes fast. Excluding only
affected accepted rows preserves useful search without pretending the corrected
projection is already indexed.

## D234 — Export corrected readings and converge private replicas without guessing (Aug 2026)

**Context:** D233 makes the effective correction overlay safe for regeneration
and invalidation, but document export still reads accepted-only rows and private
sync still defers every live/live collision. That leaves a corrected meeting
inconsistent across review and export, and it cannot distinguish independent
edits that can converge from two devices changing the same authored truth.

**Decision:** introduce one ApplicationKit `MeetingDocumentContent` projection
for Markdown, PDF, SRT, WebVTT, CLI, and Gist. It loads one coherent Library
snapshot, verifies the persisted correction revision against the complete
history, composes only events for the accepted transcript revision, retains
original source IDs and time intervals, and omits a summary whose correction
lineage is stale. Any malformed or revision-mismatched snapshot fails closed
before a renderer or remote publisher receives content. Correction provenance
is explicit opt-in metadata. Markdown and PDF append an overlay disclosure and
source map; WebVTT uses a valid `NOTE` plus corrected-cue markers; SRT uses only
visible markers so its grammar remains portable. Meeting Detail keeps the option
route-local and disables it when no correction exists; the CLI offers the same
contract through `--correction-provenance`. Playback always seeks the immutable
original audio coordinates. The reviewed Meeting Detail contract therefore
advances to 334 interaction signals while retaining eleven owners and the same
26 journeys; the existing export journey now owns deterministic app-window
evidence for the provenance choice.

Define a transport-neutral `TranscriptCorrectionReplicaMerge` in
`PortavozCore`. Matching correction IDs require identical immutable fields;
tombstones converge only through the existing monotonic transition. Disjoint
text/speaker/structural lanes may union only when the complete accepted segment
base and revision match. Competing lanes, divergent tombstones, and incompatible
accepted bases fail closed without partial storage changes. During a private-
sync collision, IntegrationsKit preserves the exact remote payload and blocks
outgoing attempts across relaunch, explicit retry, and late save callbacks. An
explicit local restore or tombstone may make both histories compatible; replay
then merges them, deletes only the obsolete blocked attempt, releases the send
fence atomically, and publishes the newest local generation. Remote deletion
remains privacy-dominant and legacy format-1 peers remain local-wins.
Only deterministic replica-merge and correction-history validation failures
map to the user-visible correction conflict; unrelated database or storage
failures remain typed failures and roll back instead of masquerading as an edit
collision.

Corrected-text search/index materialization, MCP transcript adoption, and
automatic Apuntador regeneration remain separate decisions. The accepted raw or
refined transcript and original audio are never rewritten.

**Rationale:** every exported format should represent the same reading the user
reviewed without pretending an overlay changed the recording. One projection
prevents renderer drift, opt-in provenance keeps normal documents clean, and
immutable source coordinates preserve audit and playback. Set union is safe for
independent correction lanes, while a durable conflict fence prevents silent
last-writer-wins loss when two devices edit the same claim.

## D235 — Close correction composition with recovery and scale gates (Aug 2026)

**Context:** D229–D234 define and adopt an immutable correction overlay, but
examples alone did not prove that arbitrary operation order, mixed-language
refined material, an interruption during derived-index invalidation, duplicate
CloudKit delivery, or more than two replicas preserve the same truth. The
roadmap also required one measured 20,000-segment composition boundary before
the correction band could close.

**Decision:** retain production policy unchanged and add deterministic quality
authority at its existing boundaries. A seeded 64-case operation suite shuffles
accepted rows and correction history while exercising replace, speaker, split,
merge, suppress, and restore. A separate refined Spanish/English fixture
requires each row to retain its spoken language, exact text, immutable source
IDs, and explicit refined lineage. A database trigger aborts semantic-source
generation after correction insertion; the complete transaction must leave no
event, journal advance, job cancellation, search exclusion, or generation
advance. Repeated delivery of one blocked remote correction is ignored before
and after transport-state relaunch, while three compatible device histories
must converge under every tested merge association.

Add a test-only, content-free Release benchmark over 20,000 mixed-language
segments and 400 distributed corrections. Inputs are prebuilt and permuted
outside measurement; the report contains only fixture version, host shape,
counts, build configuration, and p50/p95/max timing. The canonical reference
gate is 250 ms p95. Five runs on the current 14-core arm64, 36 GiB reference Mac
recorded p50 168.85 ms and p95/max 175.20 ms, producing 19,867 visible rows.
The raw aggregate is retained in
`docs/evidence/correction-composition-20260802.json` and the reproducible runner
is `make correction-composition-benchmark`.

This budget covers pure correction composition only. It does not convert the
D222 UI baseline into a combined rendering budget, does not authorize corrected
search materialization, and does not weaken the accepted-only retrieval fence.

**Rationale:** deterministic permutations and injected failure boundaries prove
semantic invariants better than a few UI examples, while one bounded aggregate
benchmark prevents a correct overlay from becoming unusable on a large meeting.
Keeping the harness payload-free and test-only preserves local-first privacy and
prevents benchmark machinery from becoming a production back door.

## D236 — Benchmark commitment candidates before creating continuity state (Aug 2026)

**Context:** summary providers already emit evidence-linked generated action
items, but a cross-meeting Commitment Radar needs a stricter meaning: an
explicit future promise or assigned next step that a user can later confirm,
reassign, reschedule, complete, reopen, or dismiss. Promoting generated action
items directly would confuse suggestions, hypotheticals, status reports, and
questions with commitments and could silently invent owners or deadlines.

**Decision:** establish an adapter-neutral research gate before adding storage
or UI. The canonical public fixture contains exactly 48 synthetic cases,
balanced 16/16/16 across English, Spanish, and mixed speech, with 12 explicit
commitments and nine cases for each negative class: suggestion, hypothetical,
status report, and question. Each case contains bounded transcript turns, one
generated action-item observation, and explicit candidate, owner, deadline,
and evidence truth. A candidate counts only when its nonempty evidence IDs are
present in both the transcript and generated action item; unsupported output
fails closed. Scorecards report candidate precision, recall, F1, and false-
positive rate, exact evidence, exact owner/deadline recovery, and owner/deadline
false positives overall and by language/class.

One runner supports a transparent deterministic research control and an
explicit-loopback-IP OpenAI-compatible model adapter over the same public
fixture. The model endpoint cannot contain credentials or address a nonlocal
host. Optional per-case details are owner-only and non-overwriting; tracked
research retains only aggregate public-fixture values. Scorecard comparison
requires an identical canonical fixture and reports deltas only: quality stays
`review-required`, the winner stays `not-evaluated`, and no product decision is
made automatically. The first uncommitted-development observation of local
`qwen3-coder:latest` produced candidate precision 0.588235, recall 0.833333,
F1 0.689655, overall false-positive rate 0.194444, owner false-positive rate
0.179487, and deadline false-positive rate 0.157895. It is explicitly not an
engine selection or product evidence.

Do not add a commitment entity, confirmation lifecycle, sync envelope, or UI
in this slice. Generated `ActionItem` remains an immutable model observation;
future continuity state must be a separate user-confirmed aggregate. A model
may propose owner or deadline values but cannot confirm ownership, due dates,
or completion.

**Rationale:** false commitments are more damaging than an empty radar. A
multilingual, evidence-bound benchmark quantifies that risk before schema and
UX make it durable, while the adapter-neutral and loopback-only boundary keeps
local model research replaceable, private, and incapable of silently changing
product truth.

## D237 — Persist only explicitly confirmed commitment continuity (Aug 2026)

**Context:** D236 established that candidate extraction still has material
false positives and therefore cannot choose an engine or promote generated
action items automatically. Continuity nevertheless needs a durable domain
boundary before a confirmation inbox or cross-meeting read model can be built.
Conflating that boundary with candidate storage would let experimental model
output become user truth and would make regeneration capable of overwriting
ownership, due dates, or completion.

**Decision:** add schema v20 as a confirmed-only aggregate. `ActionItem` remains
the generated observation attached to an immutable summary; there is no
`proposed` commitment status or candidate table. A commitment starts only at an
explicit confirmation boundary from one of three origins: an existing generated
action item with nonempty current-revision live same-meeting evidence, a live
user note, or a manual entry. The aggregate stores one immutable title and
source history plus append-only confirm, reassign, reschedule, complete, reopen,
and dismiss events. Current `confirmed`/`done`/`dismissed` state, optional owner,
and optional due date are projections updated in the same transaction as each
new event. Invalid lifecycle transitions write nothing.

Canonical ownership accepts only an exact live `PersonID`. Alias or name
similarity may be presented later as a candidate, but cannot enter persistence.
Source meeting, action-item, note, and segment identities are retained as
historical references rather than cascade ownership; source/evidence/event rows
and commitment title/creation identity are database-immutable.

Define a canonical format-1 `CommitmentContinuityEnvelope` in PortavozCore and
exact replay in StorageKit. Exact retries are idempotent; conflicting identity,
missing local source truth, mismatched evidence, or unavailable exact people
fails closed before any insert. This is a transport-neutral representation, not
yet a `.portavoz` meeting-bundle field, CloudKit meeting record, CLI/MCP
contract, or UI. Candidate admission, confirmation UX, library-global sync
transport, and the Radar read model remain separate decisions.

**Rationale:** storing only confirmed user truth makes candidate models
replaceable and keeps summary regeneration harmless to longitudinal state.
Append-only events preserve auditability and future convergence, while exact
identity/evidence admission prevents aliases or stale generated output from
silently becoming ownership claims.

## D238 — Keep commitment review feedback source-bound and separate from candidate generation (Aug 2026)

**Context:** D237 provides confirmed continuity, but the confirmation inbox also
needs reversible dismiss and defer choices before a user-facing surface can be
built. Persisting generated candidate text, proposed owners, or proposed dates
would let experimental output become a second mutable truth and could make
summary regeneration silently inherit decisions from an unrelated fresh action
item.

**Decision:** add schema v21 with one `commitmentReviewDecision` row keyed to an
existing generated `ActionItem`. The row may contain only `dismissed`, or
`deferred` with a revisit date strictly after its update time, plus creation,
update, and tombstone timestamps. It stores no title, owner, deadline, evidence,
score, model, or candidate payload. Mutations require the action item to belong
to the newest live summary for the requested meeting and reject a source that is
already confirmed.

Build the inbox candidate as a transient ApplicationKit projection over the
newest immutable summary, typed action-item evidence, current cast, review
feedback, and confirmed continuity. Evidence remains mandatory. An owner may be
suggested only when the source speaker already carries an exact live
`PersonID`; alias and display-name similarity are not admission rules. No due-
date suggestion is produced until a separately benchmarked extractor is chosen.

Local confirmation and exact format-1 replay tombstone source feedback in the
same transaction that inserts confirmed continuity. A unique partial index
prevents one generated action item from backing more than one commitment.
Meeting Detail observes the reconciliation independently from transcript,
summary, Apuntador, privacy, processing, and notes. This decision adds no
candidate engine, visual inbox, Radar query, bundle field, CloudKit transport,
CLI, or MCP contract.

**Consequences:** dismiss and defer remain explicit, reversible user treatment
without becoming model material. A regenerated summary creates fresh action-
item identities and intentionally does not inherit feedback. Exact owner
identity and absent deadline suggestions can produce a sparse inbox, but the
system fails closed instead of presenting guesses as durable truth. The later
visual adoption may add confirm, edit, dismiss, defer, and source navigation
without changing persistence semantics; D239 owns that adoption.

## D239 — Make commitment admission evidence-first and explicit (Aug 2026)

**Context:** D237 and D238 created confirmed-only continuity plus reversible
source review, but users still needed a safe way to decide whether one generated
action item should become longitudinal truth. Reusing the summary task list or
adding a one-click confirmation without context would hide the distinction
between generated observation and user-owned commitment, and could admit stale
evidence, an inferred person, or a guessed deadline.

**Decision:** render a separate Meeting Detail confirmation inbox from the
transient ApplicationKit projection. Each pending candidate shows its generated
wording, exact transcript evidence, exact linked-person suggestion when one
already exists, and the explicit absence of a deadline suggestion. The evidence
control uses the established playback-navigation owner to focus the immutable
source and seek retained audio. Confirmation is unavailable when evidence is
stale or missing.

The user must open an editor before confirmation. That editor may change the
title, choose one exact canonical person or leave ownership unassigned, and add
a date manually. Confirm, dismiss, and defer are routed through
`ManageMeetingCommitmentInbox`, an ApplicationKit use case backed by the narrow
`MeetingCommitmentReviewRepository`; presentation receives immutable values and
never imports StorageKit. Dismiss and defer remain reversible source treatment,
while confirmation crosses the existing D237 persistence boundary and removes
the source from the inbox. Each candidate keeps individual evidence and actions;
there is no bulk operation that can hide evidence.

**Consequences:** generated action items remain visible as generated content and
cannot silently become continuity state. A sparse inbox is intentional: owner
similarity, aliases, free-text dates, and model scores are not admission rules.
The visual surface does not select a candidate engine, infer deadlines, create a
Radar query, or extend bundle, CloudKit, CLI, or MCP contracts. Future read
models can consume only the confirmed aggregate without depending on this UI.

## D240 — Keep self, participant, and unassigned commitment ownership distinct (Aug 2026)

**Context:** confirmed continuity stored only an optional canonical `PersonID`.
That value could identify an external participant or be absent, but the
structural local `Me` speaker is deliberately not a canonical person. Treating
nil as both self and unassigned would make ownership filters dishonest, while
creating a person for `Me` would violate the identity boundary.

**Decision:** represent commitment ownership in PortavozCore as exactly one of
`me`, `person(PersonID)`, or `unassigned`. Schema v22 adds the corresponding
kind to the current projection and confirm/reassign events. Legacy rows with an
exact person migrate to `person`; every legacy nil owner migrates to
`unassigned`. The migration never infers self and restores immutable event
history before application writes resume. Database triggers reject every
kind/person mismatch.

The continuity envelope advances to format 2 and writes the typed owner. Its
decoder accepts format 1 by mapping an exact person to `person` and nil to
`unassigned`; format 1 cannot represent self. Meeting Detail adds an explicit
localized `Me` choice beside exact canonical participants and `Unassigned`.
ApplicationKit carries that typed choice unchanged to the existing confirmed-
only persistence boundary.

**Consequences:** future read models can distinguish mine, others, and
unassigned without name matching or synthetic identity. Existing libraries and
portable format-1 data remain readable without retroactive guesses. This
decision does not add a Radar query, candidate engine, automatic ownership,
deadline inference, bundle field, CloudKit transport, CLI, or MCP contract.

## D241 — Bound Commitment Radar as a confirmed-only read model (Aug 2026)

**Context:** D237–D240 created evidence-backed, explicitly confirmed continuity
with honest ownership, but a global view could still regress into per-row
Meeting Detail hydration, mix generated candidates with user truth, or invent
calendar semantics inside persistence. A useful Radar also needs source and
history without allowing an unbounded library to become an unbounded read.

**Decision:** define the Radar contract in PortavozCore and let ApplicationKit
own relative-time policy through an injected calendar and clock. `dayStart`,
the half-open seven-day due-soon boundary, and the seven-day new-activity
boundary enter StorageKit as concrete dates. The read accepts explicit owner,
urgency, and activity filters and never calls an intelligence provider.

StorageKit executes one snapshot-consistent read with at most four set-based
SELECT statements independent of root count: bounded roots, bounded oldest
sources, bounded newest events, and referenced exact-person labels when needed.
Root pages are limited to 200 and source/history rows to 20 per root; exact
counts and truncation flags remain visible. Every result preserves durable
source identities, lifecycle history, and optional source-meeting navigation.
No row hydrates Meeting Detail.

Urgency applies only to open confirmed work. Activity is derived from current
status plus the latest immutable event: `done`/`complete` is completed,
`confirmed`/`reopen` is reopened, and a latest recent `confirm` is new; other
coherent open state is unchanged. Projection/history disagreement fails the
read. Dismissed and tombstoned roots are excluded.

**Consequences:** Radar distinguishes mine, exact people, and unassigned work
and exposes bounded proof without importing model guesses into continuity. The
macOS Library now owns a dedicated global route backed by a per-window model and
narrow composition adapter. It filters by owner, due date, and activity, groups
only by canonical owner or exact source meeting, and opens that durable source
without per-row Meeting Detail hydration. The surface adds no schema migration,
candidate engine, inferred owner/deadline, automatic promotion, reminder,
bundle/CloudKit field, CLI, or MCP contract. Project/topic grouping remains
deferred until a real project/topic entity exists; meeting navigation is source
evidence, not a project proxy. The canonical 1k/10k Release benchmark remains
separate quality work.

## D242 — Gate Commitment Radar with a content-free Release benchmark (Aug 2026)

**Context:** D241 bounds the Radar structurally, but query-count assertions do
not prove that the real StorageKit read remains responsive as confirmed history
grows. Adding cross-meeting suggestions before measuring the existing read
would mix baseline cost with new schema and ranking work. Running against a user
library would also make performance evidence private, unstable, and difficult
to reproduce safely.

**Decision:** retain a canonical content-free Release benchmark over fresh
synthetic stores containing 1,000 and 10,000 confirmed commitments. Fixture
construction occurs outside timing; one warm read precedes three to twenty
measured reads, with five as the standard observation. Every run requests a
100-root page, must return stable identities and exact totals, and must execute
the maximum four-SELECT/WITH query shape. A synthetic exact canonical person
keeps the optional name lookup active deliberately.

The gate uses nearest-rank p95 with an absolute 100 ms budget. Its runner emits
one aggregate schema-v1 JSON observation to stdout, keeps build/test progress on
stderr, never opens a user library, and persists no report. The payload excludes
commitment, source, event, meeting, text, and database-path identity. On the
2 Aug 2026 arm64 reference host, five Release reads measured 4.06 ms p50 and
4.25 ms p95 at 1,000 rows, then 25.10 ms p50 and 25.27 ms p95 at 10,000 rows.

**Consequences:** COMMIT-3 now has reproducible scale evidence before
cross-meeting continuity work begins. Statement growth, unstable result
identity, or a p95 budget miss fails the benchmark instead of being accepted as
incidental host noise. The observation authorizes neither a candidate engine
nor a storage-engine replacement, and it says nothing about SwiftUI rendering,
semantic linking quality, reminders, sync, CLI, or MCP latency; those remain
separate contracts.

## D243 — Append cross-meeting commitment evidence only after explicit confirmation (Aug 2026)

**Context:** confirmed commitments and their bounded Radar exist, but a later
meeting can produce a new generated action item about the same obligation. A
semantic or person match may be useful evidence, yet automatically merging it
would turn a ranking heuristic into durable user truth. Current transcript
evidence alone is also insufficient because summary regeneration can retire an
otherwise current-revision action item.

**Decision:** add a typed `CommitmentLinkConfirmation` and route it through
`ManageMeetingCommitmentInbox` to one atomic StorageKit operation. The target
must be open. The action item must remain in the expected meeting's newest live
summary, retain nonempty current-revision direct evidence, have no existing
confirmed source, and come from a meeting not already represented in the target.
Only after that explicit command does StorageKit append the immutable source and
ordered evidence and tombstone any review treatment for the linked item.
Its source timestamp is advanced beyond the target's latest source or lifecycle
timestamp when the caller's wall clock regresses, preserving append order.

The transaction does not create or merge a commitment, append a lifecycle
event, or rewrite the canonical title, owner, due date, projection, or
projection timestamps. It needs no migration. Candidate ranking cannot invoke
the command; the current transient inbox projection remains read-only with
respect to links.

**Consequences:** later semantic/person scoring can remain non-serving until a
user confirms the proposed relationship, while source history can accumulate
without falsifying lifecycle history. A commitment accepts at most one linked
source per meeting. The app repository adapter exists, but no SwiftUI link
affordance or scorer ships in this slice. `firstSeenAt` records confirmation
time, so future first-promised/last-discussed labels must derive meeting
chronology explicitly. Sync/export, reminders, CLI, and MCP remain unchanged.

## D244 — Rank commitment links from exact person and evidence identity only (Aug 2026)

**Context:** D243 provides the only durable way to append later evidence to an
open commitment, but it deliberately supplies no candidate policy. Reusing a
model answer, display-name similarity, or an uncalibrated vector score here
would let probabilistic output look like an identity decision. The current
semantic query boundary returns an authoritative ordered list of segment
identities, not calibrated scores, so it cannot yet support an honest global
similarity threshold.

**Decision:** add one pure, storage-independent PortavozCore ranker. A new
action-item candidate may suggest an existing open commitment only when its
known typed assignee exactly equals the confirmed target assignee and the
caller's ordered semantic segment identities intersect the target's exact
stored evidence identities. Nil or unassigned candidates, conflicting owners,
same-meeting targets, closed or deleted commitments, malformed continuity
values, duplicate identities, and any input beyond its fixed bounds abstain.

The ranker accepts at most 20 semantic hits and 200 targets, inspects at most 20
meeting and evidence identities per target, and returns at most three
suggestions. It orders by earliest semantic hit, then greater exact evidence
coverage, then commitment UUID for a stable tie. Every result carries only the
candidate identity, target commitment, exact assignee, matched evidence IDs,
and explainable one-based semantic rank. It cannot call ApplicationKit,
IntelligenceKit, StorageKit, a provider, or the D243 mutation command.

**Consequences:** the policy can be benchmarked without becoming a serving
feature or creating a second semantic engine. No similarity threshold is
selected until a cross-meeting quality pack supplies calibrated evidence. A
future adapter must assemble current bounded targets and semantic identities,
and a future UI must require the user to confirm through D243. This slice adds
no schema, storage query, application composition, SwiftUI, automatic merge,
chronology presentation, sync/export field, reminder, CLI, or MCP contract.

## D245 — Separate semantic relevance from commitment-link legality (Aug 2026)

**Context:** D244 can prove that a suggestion obeys the current exact-person,
evidence-intersection, lifecycle, and cross-meeting rules, but that does not
prove the semantic hit was relevant. An irrelevant top-k row from the correct
person can be policy-valid and still create a false link. Conversely, the same
obligation can be semantically relevant but illegal to link because it belongs
to another person, the current meeting, an inactive commitment, or an
unassigned candidate. Treating those outcomes as one label would hide the most
important false-positive classes and could let a transparent Core policy be
mistaken for retrieval-quality evidence.

**Decision:** establish a second adapter-neutral public quality authority for
cross-meeting links. Its reproducible schema-1 fixture contains exactly 36
bounded synthetic cases: 12 English, 12 Spanish, and 12 mixed; 18 linkable and
18 mandatory-abstention cases. It covers ordinary continuation, ambiguous
multiple targets, local-user ownership, wrong person, no semantic overlap,
same-meeting evidence, done and dismissed targets, and unknown ownership. Every
case declares semantic-relevant target identities separately from legally
linkable target identities and retains only synthetic action, commitment,
meeting, and evidence material.

An observation is bound to the canonical fixture digest and may contain at
most the D244 limits of 20 ordered evidence identities and three suggestions.
Unknown, duplicate, missing, or over-bounded identities fail closed. The
evaluator reports semantic target Hit@1/Recall@20 separately from link
precision/recall/F1, Hit@1/Recall@3, abstention accuracy, false-suggestion rate,
and exact policy-explanation support, overall and by language/class. A
policy-valid but semantically irrelevant link therefore remains a measured
false positive. Optional per-case details are owner-only and non-overwriting.

The perfect control exists only to prove fixture and evaluator arithmetic. All
scorecards remain `review-required`, product decisions remain `not-evaluated`,
and this slice defines no quality floor, similarity threshold, engine winner,
runtime adapter, storage read, app composition, UI, mutation, or retained real-
meeting evidence. A later product-path adapter must emit this exact observation
contract before any suggestion can become user-visible, and D243 remains the
only durable confirmation boundary.

**Rationale:** semantic retrieval and domain admission fail for different
reasons and need different evidence. A public multilingual pack makes both
failures reproducible without user data, while a digest-bound, bounded,
review-only evaluator prevents benchmark machinery from silently becoming a
serving policy.

## D246 — Observe commitment links through bounded product ports (Aug 2026)

**Context:** D245 defines the observation contract for cross-meeting link
quality, but it deliberately has no product-path adapter. Evaluating only a
synthetic control would not prove that Portavoz can assemble current confirmed
targets, use its real semantic query boundary, and apply D244 without creating
a second engine or accidentally exposing suggestions. The adapter also needs
to distinguish ordinary runtime unavailability from a legitimate abstention.

**Decision:** add one non-serving ApplicationKit observer over the existing
semantic-readiness, embedding-runtime, and `SemanticIndexSearching` ports. Its
typed request carries the new ActionItem identity, meeting, text, and already
resolved assignee. It trims and bounds the candidate text, requires a compatible
published corpus, borrows only installed embedding assets with downloads
disabled, validates one finite query vector, and accepts at most 20 unique
ordered semantic segment identities. It then delegates legal admission solely
to D244 and returns semantic hit identities separately from final proposals.

StorageKit supplies one snapshot-consistent target read over open confirmed
commitments. Roots are bounded to 200; source meetings and evidence identities
are each bounded to 20 per root. Three set-based queries retrieve roots,
sources, and evidence, using one extra ranked row to detect and omit malformed
over-bounded aggregates. Identity decoding is strict. The adapter does not
score, update, confirm, merge, or create continuity.

Semantic unavailability, invalid candidate text, malformed vectors, and
duplicate or over-bounded result identities fail through explicit typed errors.
They are not converted into empty quality observations. The observer is not
composed into `portavoz-app`, SwiftUI, CLI, or MCP, and cannot call the D243
mutation boundary.

**Consequences:** Portavoz now has a real, bounded product-path seam for
collecting retrieval and admission evidence without serving it. D245 can next
receive observations produced through the same semantic and persistence ports
used by the product while keeping provider choice, score thresholds, accepted
quality floors, UI, chronology presentation, and automatic behavior deferred.
No schema, index, migration, model download, durable write, user-visible
feature, sync/export field, reminder, or external API is added.

## D247 — Measure commitment links through isolated product-path fixtures (Aug 2026)

**Context:** D246 exposes the real read-only Storage/Application observation
seam, but D245 cannot score it until fixture identities are mapped to durable
meetings, transcript evidence, generated action items, canonical people, and
confirmed continuity. Running all 36 fixture cases in one corpus would also let
evidence from unrelated cases enter top-k results and turn benchmark leakage
into apparent product quality.

**Decision:** add a CLI-only product adapter for the exact D245 schema. It
accepts only the canonical public fixture digest, creates one mode-0700 scratch
root, and uses a separate `MeetingStore` database for every case. Each case is
materialized through public product boundaries: target evidence becomes
transcript segments; exact external people are created through the explicit
speaker-link transaction; evidence-backed generated action items are saved in
immutable summaries; and targets cross the confirmed-continuity transaction
before optional complete/dismiss lifecycle events are applied. Fixture
identities map deterministically to domain UUIDs and map back to the exact
external IDs required by D245.

The runner indexes each isolated corpus with `IndexSemanticCorpus`, invokes
`ObserveCommitmentLinkSuggestions`, and emits semantic hits separately from
D244 proposals. The adapter identity includes a bounded prefix of the exact
embedding-profile fingerprint. Asset download defaults to `never` and requires
an explicit `if-needed` CLI argument; D246's measured query still prohibits a
download. Output uses one shared owner-only, atomic, non-overwriting CLI JSON
publisher. The runner never opens the user library, enters app composition,
serves a suggestion, invokes link confirmation, retains transcript text, or
selects a threshold.

**Consequences:** D245 can now score the real persistence, indexing, semantic
query, and legal-admission path without exposing it. A dirty-head development
smoke using the installed Apple profile completed all 36 cases and validated
through the public evaluator: semantic Hit@1 was 0.969697, Recall@20 was 1.0,
link precision was 0.777778, link recall was 1.0, abstention accuracy was
0.666667, and six false suggestions remained. All proposals were explanation-
supported, but same-owner distractors in no-overlap and wrong-person cases show
that exact ownership plus evidence identity is not a semantic relevance floor.
The result is review-required development evidence, not a clean-head baseline
or product decision. Serving stays blocked pending an ignored anonymized pack,
clean-head profile matrix, explicit similarity/abstention research, and an
accepted quality floor.

## D248 — Preserve profile-bound similarity without defining admission (Aug 2026)

**Context:** the product-path link runner proved that exact owner and evidence
identity are explainable but insufficient: six semantically irrelevant links
survived legal admission. The exact Accelerate search already computes cosine
similarity to rank every result, but `SearchHit` discarded that value before
the non-serving observer could measure it. Choosing a threshold without the
source score and embedding-profile identity would be irreproducible; applying
one directly in Core or SwiftUI would turn one dirty-head smoke into policy.

**Decision:** retain an optional profile-local semantic similarity on the
authoritative transcript search projection. Lexical search and identity-only
research projections leave it absent; the shipped exact semantic adapter
attaches the already computed dot-product value without adding another scan or
persisting it. Existing Ask and Library consumers continue to ignore it.

The non-serving commitment-link observer now returns ordered
`CommitmentLinkSemanticHit` values plus the exact embedding-profile
fingerprint. It requires every semantic result to carry a finite cosine value
within a small floating-point tolerance of `[-1, 1]`, clamps only that tolerance
drift, and rejects ascending rank order. Missing, non-finite, out-of-range, or
misordered evidence is a typed measurement failure rather than an abstention.
The observer still passes only ordered segment identities into D244, so score
cannot alter legal admission.

**Consequences:** a later offline evaluator can replay explicit
similarity/abstention candidates against the public and ignored real-meeting
packs using evidence from the actual exact adapter. Scores remain transient,
profile-bound, absent from persistence, support diagnostics, sync, bundles,
MCP, app composition, and SwiftUI. This decision selects no threshold, margin,
quality floor, engine, or product behavior and creates no user-visible feature.

## D249 — Version scored commitment-link evidence separately from quality observations (Aug 2026)

**Context:** D248 makes exact profile-local similarity observable, but D245's
schema-1 quality document intentionally contains only external hit identities
and legal suggestions. Adding scores in place would invalidate retained
observations and couple the accepted adapter-neutral evaluator to an unfinished
admission experiment. Publishing an unscored and a scored file from one command
would also allow a second-file failure to leave an ambiguous partial run.

**Decision:** add a separate schema-1, owner-only similarity-observation
contract and a dedicated CLI command over the same isolated D247 product path.
Each document binds the canonical fixture generation and digest, the full
embedding-profile fingerprint, a bounded receipt-safe build identifier, and
one full lowercase source commit. Every canonical case contains ordered
external evidence identities with finite cosine scores in `[-1, 1]` plus the
unchanged D244 suggestion rows needed for later policy replay. It carries
literal `not-evaluated` and `not-approved` states.

The adapter-neutral validator requires an exact schema, one unique row per
fixture case, only known and unique evidence/target identities, D244's 20-hit
and three-suggestion bounds, descending score order, exact provenance shapes,
and the non-serving states. Owner-only atomic publication never overwrites an
earlier receipt. D245's fixture, unscored observation schema, evaluator, and
product command remain unchanged.

**Consequences:** a later deterministic evaluator can sweep explicit
similarity and abstention candidates from one provenance-complete artifact
without rerunning retrieval or inferring scores from rank. This slice still
selects no threshold, margin, quality floor, or winner; does not read a user
library; and adds no app composition, persistence, diagnostics, sync, bundle,
MCP, SwiftUI, confirmation, or serving behavior. A clean-head local-profile
matrix and ignored anonymized real-meeting evidence remain required before any
policy can be accepted.

## D250 — Replay every distinct similarity-admission outcome without choosing one (Aug 2026)

**Context:** D249 preserves exact product-path scores, but a fixed hand-written
threshold grid could miss a behavior change or encode an arbitrary preference.
Applying a threshold to raw semantic hits would also alter retrieval evidence,
while allowing it to mask an unsupported legal suggestion could make a broken
adapter appear safer than it is. Policy research therefore needs a deterministic
boundary that separates retrieval from admission and can be recomputed exactly.

**Decision:** add an adapter-neutral offline replay over one validated D249
artifact and the canonical D245 fixture. Every baseline suggestion must first
pass the existing exact legal/explanation check. For each suggestion, the replay
uses the greatest similarity among its matched evidence, which is the first
matched row in the validated descending semantic result. Raw semantic hits stay
unchanged. Candidate admission applies only the inclusive rule `best matched
evidence similarity >= minimum similarity`.

The sweep sorts the unique baseline suggestion scores and derives one stable
representative threshold for every distinct admission outcome: `-1.0` retains
the complete legal baseline, midpoints between adjacent values represent each
subsequent equivalence class, and a midpoint between the maximum and `1.0`
represents full abstention when that interval exists. It therefore neither
misses an observed behavior transition nor invents a coarse product grid.

The schema-1 replay binds the exact source-observation digest plus fixture,
adapter, embedding profile, build, and source commit. It records admitted and
rejected suggestion counts, changed cases, full aggregate quality metrics, and
language/class slices for every candidate. Validation recomputes the complete
document rather than trusting supplied metrics or order. Output is owner-only,
atomic, and non-overwriting, with literal `review-required`, `not-selected`,
`not-evaluated`, and `not-approved` states.

**Consequences:** reviewers can inspect the complete public-fixture precision,
recall, and abstention frontier without rerunning embeddings or allowing the
tool to name a winner. This decision selects no threshold, margin, quality
floor, model, or engine and changes no product retrieval, Core policy,
persistence, application composition, SwiftUI, confirmation, sync/export,
diagnostics, public product CLI/MCP surface, or serving behavior. An ignored real-
meeting contract, clean-head profile matrix, explicit human review, and an
accepted multilingual quality floor remain mandatory before product wiring.

## D251 — Keep real-meeting link calibration private, balanced, and owner-reviewed (Aug 2026)

**Context:** D250 can enumerate public-fixture policy outcomes, but a synthetic
pack cannot establish field precision. Retaining raw meetings, identities,
paths, or account material in Git would violate Portavoz's local-first boundary.
Conversely, an unconstrained private pack could change class or language
denominators and make its metrics incomparable with the public authority.
Automated pattern matching can catch obvious identifiers but cannot honestly
certify that free text has been anonymized.

**Decision:** define a separate schema-1 private companion fixture. It reuses
the exact public 36-case structural and distribution contract: 12 English, 12
Spanish, 12 mixed; the same nine class counts; 18 linkable and 18 mandatory-
abstention cases; and identical candidate, target, evidence, assignee, and truth
rules. Its root instead requires a `private-anonymized-*` generation, literal
`private-anonymized-local` content source, and `owner-reviewed-redaction-v1`
attestation. The owner must explicitly state that the pack contains no audio,
filesystem paths, account identifiers, or direct identifiers.

The validator rejects obvious email addresses, URLs, user/home filesystem
paths, phone-like numbers, and UUIDs in candidate, target-title, and evidence
text. Those checks are a fail-closed backstop, not a claim of automatic
de-identification. CLI validation accepts only a regular non-symlink mode-
`0600` file. If the file is under the repository root, `git check-ignore` must
prove that it is ignored; `/private-evidence/` is the canonical local location
and repository hygiene asserts that boundary. No private fixture is committed.

**Consequences:** a future collector can receive field cases with the same
metric shape as the public pack without weakening or mutating the canonical
public fixture. This slice validates metadata, balance, structure, path safety,
and obvious identifier patterns only; human owner review remains authoritative.
It does not yet let the Swift product-path runner ingest a private fixture,
collect scores, replay policy, retain a baseline, or choose a threshold. It
adds no app composition, persistence, support diagnostics, sync/export, bundle,
public CLI/MCP surface, SwiftUI, confirmation, or serving behavior.

## D252 — Measure private commitment links without weakening public evidence (Aug 2026)

**Context:** D251 defines a safe local shape for owner-reviewed field cases,
but the D247/D249 Swift runner accepts only the reproducible public fixture
digest. Broadening that command to accept either root would make a private file
indistinguishable at the composition boundary, and reusing the public receipt
kind would let field evidence be mistaken for the synthetic authority. A
private collector must also avoid retaining the anonymized source text merely
because it needs that text transiently to seed scratch stores.

**Decision:** add a dedicated CLI command and distinct schema-1 private
similarity receipt. The private loader accepts only a regular non-symlink mode-
`0600` file with the D251 root, exact 36-case language/class/link/abstention
balance, literal owner-reviewed redaction attestation, safe bounded identities,
legal link truth, and the same obvious identifier backstops. The Make target
runs the Python authority before collection, preflights the destination, and
validates both the fixture and owner-only output afterward; repository-local
evidence must remain gitignored.

Every accepted case runs through the existing D247 isolated scratch
`MeetingStore`, product semantic indexing operation, D246 observer, and D244
legal admission. The receipt binds the full private fixture digest, content
source, complete anonymization attestation, embedding-profile fingerprint,
bounded build, and full source commit. Its rows contain only anonymized external
case/evidence/commitment/person identities, ordered cosine values, and legal
suggestions. Candidate, target, and evidence source text is never encoded. The
receipt remains literally `not-evaluated` and `not-approved`, owner-only,
atomic, and non-overwriting.

The canonical public commands and digest checks remain unchanged. The private
collector is absent from app composition and does not open the user library,
serve or confirm a suggestion, replay a threshold, retain an accepted baseline,
or enter persistence, diagnostics, sync/export, bundles, MCP, or SwiftUI.

**Consequences:** owner-reviewed field cases can now produce provenance-complete
scores through the same real product path as the public pack without mixing the
two evidence authorities or leaking fixture text into the receipt. Human review
still owns anonymization. Private policy replay, a clean-head profile matrix,
quality-floor acceptance, and any serving decision remain separate pending
slices.

## D253 — Replay private commitment-link evidence without selecting policy (Aug 2026)

**Context:** D252 produces field-derived similarity evidence, but the D250
replay accepts only the canonical public receipt. Reusing the public command or
receipt kind for private evidence would erase its owner-reviewed provenance and
make a field candidate matrix look like synthetic authority. Duplicating the
candidate arithmetic would create a second threshold policy that could drift
silently.

**Decision:** add a distinct private replay and validation path around one
shared deterministic candidate core. The private path accepts only the D251
mode-`0600` fixture and D252 mode-`0600` scored receipt, revalidates their exact
fixture/anonymization/profile/build/commit relationship, and preflights an
owner-only non-overwriting output that must be gitignored when repository-
local. The output has its own `commitment-link-private-similarity-policy-replay`
kind and binds both the complete fixture digest and complete scored-receipt
digest plus the original provenance.

For both authorities, retrieval stays fixed and only already legal D244
suggestions are filtered. One inclusive threshold represents every distinct
observed admission outcome; unsupported baseline suggestions fail closed. The
private candidate matrix carries only aggregate counts and language/class
metrics, never fixture text. Exact recomputation rejects changed candidates,
ordering, source evidence, or review state. Its statuses remain literally
`review-required`, `not-selected`, `not-evaluated`, and `not-approved`.

**Consequences:** public and private runs now produce comparable candidate
arithmetic without sharing evidence identity or choosing a winner. The shared
core reduces policy drift, while separate validators and envelopes prevent
private evidence from weakening the canonical public boundary. This slice does
not retain a baseline, accept a quality floor, select a similarity threshold,
or add app composition, persistence, diagnostics, sync/export, bundles, MCP,
SwiftUI, confirmation, or serving behavior. A clean-head profile matrix and
explicit human review remain pending.

## D254 — Compare public and private commitment-link evidence on one clean profile (Aug 2026)

**Context:** D250 and D253 can replay public and private score distributions,
but separately collected receipts do not prove that the same executable,
embedding profile, build, or source commit produced them. Their independently
observed equivalence candidates can also use different threshold values, so
placing the two replay files side by side is not a valid point-by-point
comparison. A field matrix must prevent source drift without copying private
fixture text into retained evidence.

**Decision:** add one clean-head Release orchestrator and one exact comparison
authority. The orchestrator validates the owner-reviewed private fixture,
requires an unchanged committed checkout before and after collection, resolves
the full HEAD, builds `portavoz-cli` once, and runs both the canonical public
and separate private scored collectors through that executable with asset
downloads fixed to `never`. It validates both receipts, produces both distinct
replays, and publishes all five artifacts only after the complete matrix
validates. A mode-`0700` sibling stage plus exclusive destination lock prevents
partial or concurrent publication; every artifact is regular, non-symlink,
mode `0600`, non-overwriting, and gitignored when repository-local.

The comparison requires exact equality of embedding-profile fingerprint,
build, and source commit. It binds complete fixture, scored-receipt, and replay
digests for both authorities plus the private anonymization provenance. Because
the score distributions can yield different replay candidates, it evaluates
both fixtures at the sorted union of their observed inclusive thresholds. The
same deterministic arithmetic produces aggregate, language, and class metrics
without fixture text. Exact recomputation rejects changed inputs, candidate
ordering, metrics, provenance, or review state.

**Consequences:** a future real private pack can now be compared to the public
authority under one local profile without source/executable drift or synthetic
field evidence. The bundle remains literally `review-required`, `not-selected`,
`not-evaluated`, and `not-approved`; it does not retain an accepted baseline,
choose a threshold, accept a quality floor, or add app composition, storage,
diagnostics, sync/export, bundles, MCP, SwiftUI, confirmation, or serving
behavior. Collecting the real owner-reviewed pack and making an explicit human
quality decision remain pending field work.

## D255 — Require an explicit private calibration review before product evaluation (Aug 2026)

**Context:** D254 can produce a provenance-complete public/private matrix, but
the matrix deliberately contains every observed threshold outcome and names no
winner. Automatically ranking those candidates would turn implementation code
into an undeclared quality policy. Conversely, recording only a numeric
threshold would lose the exact public/private, language, and class evidence the
maintainer reviewed. No real private matrix exists in the repository, so this
slice must define the decision boundary without fabricating its outcome.

**Decision:** add a separate private calibration-review admission authority.
It revalidates the owner-reviewed private fixture, the four scored/replay
artifacts, and the D254 matrix by exact recomputation. Admission requires a
clean checkout at the matrix's full source commit plus literal maintainer input
for the exact matrix-file SHA-256, source commit, candidate ID, and fixed
`selected-candidate-metrics-reviewed-no-serving-approval-v1` acknowledgement.
The selected candidate must exist exactly once and admit at least one public
and private suggestion.

The retained schema-1 receipt binds matrix file/document digests, profile,
build, source commit, both evidence authorities, selected threshold, and the
candidate's complete public/private aggregate and language/class metrics. Those
observed metrics are the accepted floor for a future confirmation evaluation;
they are not a globally configured threshold or automatic model verdict. The
owner-only output is atomic, non-overwriting, gitignored when repository-local,
and withdrawn if the checkout changes after publication. Deterministic
validation recomputes it from the complete private evidence bundle.

**Consequences:** Portavoz now has an auditable capability for the required
human quality decision without letting synthetic tests or code choose a
candidate. The receipt is permanently `private-commitment-link-calibration-only`,
`owner-selected-for-evaluation`, `accepted-for-confirmation-evaluation`,
product `not-evaluated`, and serving `not-approved`. It does not enter app
composition, product persistence, diagnostics, sync/export, bundles, MCP,
SwiftUI, confirmation, or source-link commands. A real owner-reviewed private
pack and explicit invocation remain mandatory before a tracked product policy
or confirmation experiment can be designed.

## D256 — Route Radar lifecycle actions through append-only continuity (Aug 2026)

**Context:** confirmed continuity already stores complete, reopen, and
reschedule as validated immutable events, but the global Commitment Radar was a
read-only projection. Letting SwiftUI call StorageKit would reverse the feature
boundary, while changing a due date in place would erase the history that makes
the Radar trustworthy. A reminder snooze is also not a due-date change: it is a
delivery decision with different lifecycle and audit semantics.

**Decision:** add a narrow `ManageCommitmentRadar` ApplicationKit use case for
only complete, reopen, and optional due-date reschedule. The use case owns the
event identity and timestamp, attaches no source meeting, and delegates to the
existing atomic append-event/project-current-state transaction. The per-window
model serializes one mutation, retains the current page if the operation fails,
and reruns the same bounded read after success. SwiftUI owns only the due-date
editor and explicit intents; it imports neither StorageKit nor IntelligenceKit.

Reminder snooze is deliberately absent. It will require separate reminder-
delivery history and cannot be represented by rewriting a commitment deadline.
No schema, candidate admission, notification, sync/export, bundle, CLI, or MCP
surface changes in this slice.

**Consequences:** users can now complete, restore, and reschedule confirmed work
from its global review surface while every change remains durable and auditable.
The existing projection/event consistency checks and bounded Radar query remain
authoritative. Delivery schedules, notification permission recovery, review
queues, and snooze still require later COMMIT-5 slices.

## D257 — Persist commitment reminder delivery separately from due dates (Aug 2026)

**Context:** D256 intentionally refused to model reminder snooze as a
commitment reschedule. A process-local timer or notification identifier alone
would lose delivery state across relaunch, while reusing the generic outbox
would conflate local user attention with publication/sync delivery. A reminder
also must never be created from an unconfirmed generated ActionItem or continue
silently after the confirmed commitment changes.

**Decision:** add schema v23 with one `commitmentReminderState` projection per
commitment and an immutable `commitmentReminderEvent` ledger. The typed state
machine accepts schedule, present, snooze, dismiss, and cancel. Every change
appends one predecessor-linked event and updates the projection atomically.
Schedule and active delivery transitions require an existing open confirmed
commitment whose current due date exactly matches the cycle's captured
`sourceDueAt`. Snooze preserves that fence and changes only `scheduledFor`;
cancel remains available to retire a stale active cycle after completion or
reschedule.

The migration creates empty tables and no synthetic reminders. Event payload
checks, a unique predecessor, a same-commitment predecessor trigger, immutable
history, a composite latest-event foreign key, and monotonic projection time
make malformed or branched persistence fail closed. D257 adds no
UserNotifications adapter, permission request, scheduler, SwiftUI, sync/export,
bundle, CLI, or MCP surface.

**Consequences:** Portavoz now has a relaunch-safe local foundation for
confirmed-only reminders and honest snooze history without weakening durable
commitment truth. Later COMMIT-5 slices can resolve due deliveries and add
permission-aware local presentation against one bounded projection. Until
then, no new reminder is scheduled or shown to users.

## D258 — Reconcile reminder intent through a content-free scheduler port (Aug 2026)

**Context:** durable reminder state alone cannot recover a missing or stale
operating-system request after relaunch. Letting a macOS adapter query and
mutate SQLite directly would duplicate confirmation/due-date policy, while a
bounded read that silently truncates could leave old reminders active. A due
date change also cannot be implemented as a persisted cancel followed by a
separate schedule: failure between those writes would strand the reminder in a
terminal state and explicit dismissal must never be silently reversed.

**Decision:** add one complete-count reconciliation projection containing
unscheduled confirmed due commitments plus every active reminder that may need
retirement. Terminal projections remain outside the operational set so old
dismissals and cancellations cannot consume its bounded capacity.
`ReconcileCommitmentReminders` fails before side effects on invalid, duplicate,
or partial snapshots and talks only to an idempotent content-free scheduler
port keyed by `CommitmentID`. Matching schedules are reasserted after relaunch;
completed, deleted, and due-less commitments cancel active delivery; presented
matching reminders and terminal user decisions remain unchanged. A first
schedule uses the exact due date, or a small injected future delay when already
overdue.

Due-date replacement first upserts the stable scheduler request and then uses
one StorageKit transaction to append cancel and schedule events and publish
only the final projection. Initial persistence failure attempts compensating
scheduler cancellation. Terminal cancel is allowed for a soft-deleted
commitment whose row still exists, while schedule, present, and snooze retain
the live confirmed exact-due fence. The scheduler input contains no title,
transcript, person, or meeting content. No `UserNotifications` adapter,
permission prompt, application timer, UI, sync/export, bundle, CLI, or MCP
surface is added.

**Consequences:** local delivery can converge idempotently after relaunch and
partial failure without letting platform code own business policy or leaking
commitment text into its request boundary. Reconciliation refuses to claim
success when more than 256 relevant roots exist; paging or a larger measured
bound must be designed rather than silently skipping work. Actual macOS
notification scheduling, permission recovery, delivery actions, and reminder
review UI remain explicit separate work.

## D259 — Observe delivered notifications before reminder upsert (Aug 2026)

**Context:** D258's idempotent scheduler model is sufficient while a request is
pending, but Apple documents different behavior after delivery: adding a new
request with the same identifier alerts again and replaces the delivered item.
A relaunch that blindly reasserted every durable schedule could therefore
duplicate a reminder. Reconciliation also runs outside a user gesture, so it
must not ask for notification permission, and lock-screen content must not
expose commitment, person, meeting, or transcript text.

**Decision:** make scheduler upsert return either `scheduled` or one exact
`alreadyPresented` observation carrying the original scheduled timestamp and
the system delivery timestamp. ApplicationKit records a `present` transition
instead of re-adding the request. If a prior attempt reached Notification
Center but failed before its initial durable schedule write, reconciliation
reconstructs a valid schedule/present pair from those content-free timestamps.
Compensating cancellation remains limited to a newly scheduled request; an
already-observed delivery is never erased because persistence failed again.

The macOS executable implements the port with `UserNotifications`. One stable
identifier derives from `CommitmentID`. The request stores only that identity,
the scheduled timestamp, and the exact source due-date fence; visible content
is generic localized copy. Exact pending requests are no-ops, exact delivered
requests become presentation outcomes, stale delivered copies are removed
before replacement, and cancellation removes both pending and delivered
copies. Authorized, provisional, and ephemeral settings may schedule.
Not-determined and denied settings fail closed. Permission request is exposed
as a separate explicit method and is never called by upsert.

The adapter remains outside `AppServices` composition in this slice. No launch
owner, polling timer, permission UI, notification delegate/action, Radar
control, sync/export, bundle, CLI, or MCP surface is added.

**Consequences:** Portavoz now has a testable native macOS adapter that can
converge operating-system delivery without duplicate alerts or sensitive
notification content, while business eligibility remains in ApplicationKit
and durable truth remains in StorageKit. Users still receive no commitment
notification until a later explicit composition and permission-recovery slice
installs the adapter and gives them control.

## D260 — Compose commitment reminders behind explicit user permission (Aug 2026)

**Context:** D259 supplied a privacy-safe native scheduler, but leaving it
outside the executable graph meant confirmed due commitments never reached
Notification Center. Asking for permission at launch would violate the
local-first consent model, and a polling timer would keep reading storage while
the app is idle. Reconciliation also needs to follow durable commitment
mutations without allowing SwiftUI or the platform adapter to own eligibility.

**Decision:** install one process-owned `CommitmentReminderModel` in
`AppServices`. On launch it inspects the current notification authorization
state without prompting. Only the explicit **Enable reminders** action in
Commitment Radar may request authorization. Authorized, provisional, and
ephemeral states enter the existing fail-closed reconciliation workflow;
not-determined and denied states remain inert and visible to the user.

The model is signal-driven rather than timer-driven. Launch authorization
inspection, successful Meeting Detail confirmation, and successful Radar
complete, reopen, or due-date mutations request reconciliation. A burst keeps
at most one active pass and one coalesced rerun. The ApplicationKit workflow
continues to decide which confirmed commitments qualify, StorageKit remains the
durable authority, and the UserNotifications adapter receives only the stable
identity/date metadata defined by D259. Disposable UI-test stores use an
in-memory notification center and never touch host notification permission.

No notification delegate, action button, snooze UI, review queue, external-
sync mutation signal, sync/export field, bundle, CLI, or MCP surface is added.
Denied permission is recoverable through an explicit status refresh after the
user changes macOS settings; Portavoz does not rely on an undocumented Settings
URL.

**Consequences:** users can opt in to generic, local, confirmed-only due-date
alerts from the Radar, while a normal launch never presents a permission dialog
or performs periodic background reads. Relaunch and in-app commitment mutations
converge through one observable process owner, and deterministic tests can
exercise the complete flow without changing machine notification state.
Notification actions, snooze controls, review queues, and signals for mutations
arriving from another device remain later slices.

## D261 — Treat reminder presentation as an exact durable input (Aug 2026)

**Context:** D260 can schedule generic alerts, but foreground delivery and a
Notification Center tap were not observed by Portavoz. Relaunch reconciliation
eventually discovers delivered requests, yet a selected alert had no product
destination, and letting the delegate mutate storage would duplicate due-date
and terminal-state policy. Old Notification Center items can also outlive a
replaced schedule.

**Decision:** register the content-free reminder category and install the native
notification-center delegate before application launch finishes. Both
foreground delivery and the default alert response decode only the stable
commitment identifier, scheduled time, source due-date fence, and system
delivery time. They call `RecordCommitmentReminderPresentation`, an
ApplicationKit use case that appends `present` only when the current durable
reminder is still scheduled for the exact same time and exact same source due
date. An already-presented delivery is idempotent; missing, replaced, terminal,
malformed, or chronologically impossible input is ignored or rejected without
reviving work.

The default alert response then routes the process to Commitment Radar and
activates the app. The delegate does not read StorageKit, does not carry
commitment, person, meeting, or transcript text, and does not reinterpret
eligibility. Foreground presentation remains a generic banner and sound. Custom
action buttons, snooze/dismiss commands, review queues, external-sync mutation
signals, and sync/export surfaces remain deferred.

**Consequences:** selecting a private due alert now returns the user to the one
confirmed-work review surface, while delivery history converges immediately and
exactly once. Stale Notification Center items cannot restore cancelled work or
block a later snoozed schedule. Relaunch recovery remains a fallback rather than
the only presentation observer. Scoped bilingual XCUITest proves the route
without touching host notification state.

## D263 — Snooze a private alert without moving commitment truth (Aug 2026)

**Context:** D257 already models reminder snooze separately from a commitment
deadline, and D261 observes an exact native delivery, but users still cannot
defer that alert. Reusing Radar's due-date editor would falsely change the
business commitment. Letting the notification delegate append storage events
or schedule a new request would duplicate ApplicationKit eligibility and
reconciliation policy. A custom action also must not reveal private work or
unnecessarily open the app.

**Decision:** register one non-foreground **Remind me in 15 minutes** action on
the existing content-free category. The native delegate classifies its stable
identifier, decodes the same commitment identity and date fences as default
delivery, completes the platform callback, and forwards a typed request to the
process reminder model. It never reads StorageKit, embeds commitment text, or
activates the app for snooze.

`SnoozeCommitmentReminder` owns the durable transition. It first records the
exact presentation through D261's use case, re-reads the resulting projection,
and appends `snooze` only while status, original scheduled time, and source due
date still match. The request requires finite monotonic delivery, handling, and
next-alert times. Replaced, terminal, repeated, missing, and malformed inputs
cannot rearm work. A successful mutation signals D260's process-wide
reconciler, which removes the old delivered request and schedules the generic
replacement. The confirmed commitment's `dueAt` and append-only continuity
history remain unchanged.

No dismiss command, Radar due-date mutation, new schema, polling timer,
external-sync signal, sync/export field, bundle, CLI, MCP, or review queue is
added. Deterministic tests exercise the workflow and native action metadata;
there is no new app-window UI to justify an XCUITest.

**Consequences:** users can defer a generic confirmed-work alert for fifteen
minutes without weakening business truth or privacy. Snooze survives relaunch,
duplicate notification responses are idempotent, and platform code remains an
adapter rather than a policy owner. Explicit dismissal and pre/post-meeting
review remain later COMMIT-5 slices.

## D264 — Treat clearing a native alert as durable dismissal (Aug 2026)

**Context:** D263 lets users defer a delivered alert, while the domain and
storage already support a terminal reminder dismissal. The macOS category did
not request dismissal callbacks, however, so clearing an alert in Notification
Center left the durable projection presented. Although current reconciliation
does not immediately rearm a matching presentation, a platform-visible choice
should be captured explicitly rather than inferred from a missing delivered
request. The native delegate must not own storage or commitment policy.

**Decision:** opt the content-free reminder category into
`customDismissAction`, classify `UNNotificationDismissActionIdentifier` as a
closed response action, and forward the existing opaque commitment identity,
scheduled time, source due date, delivery time, and callback handling time to
ApplicationKit. The callback completes before asynchronous policy work and does
not activate Portavoz.

`DismissCommitmentReminder` validates finite monotonic chronology, records the
exact presentation through D261's use case, re-reads the projection, and appends
`dismiss` only while status, scheduled time, and source due date still match.
The resulting projection is terminal and therefore excluded from process
reconciliation. The confirmed commitment, its `dueAt`, and continuity history
remain unchanged. Replaced, repeated, missing, terminal, and malformed
responses are fail-closed no-ops.

Foreground presentation and dismissal can arrive close enough to race across
the ApplicationKit read/append boundary. If a present append loses that race,
the presentation workflow re-reads the projection and accepts success only
when the exact scheduled time and source due-date fences are already presented;
every other failure remains visible. This allows the later dismiss transition
to proceed without masking replacement or storage errors.

No new schema, Radar mutation, permission request, reconciliation kick, polling
timer, app-window UI, external-sync signal, sync/export field, bundle, CLI, MCP,
or review queue is added. Deterministic tests characterize the native category,
classifier, ApplicationKit workflow, storage timeline, and architecture
boundary; Notification Center interaction remains a later field check.

**Consequences:** clearing a generic private alert now has durable semantics and
cannot be silently undone on relaunch. Platform code remains a content-free
adapter, while ApplicationKit owns chronology and stale-delivery policy. The
pre/post-meeting review queue and calendar/Shortcuts preview remain later
COMMIT-5 work.

## D265 — Bound generated-work review before composing new surfaces (Aug 2026)

**Context:** Meeting Detail already offers exact evidence-first confirmation
for one meeting, and Commitment Radar deliberately contains only confirmed
truth. Pre-meeting preparation and post-meeting review still need a shared view
of generated work that requires attention. Hydrating Meeting Detail once per
candidate would create an unbounded N+1 read, while reusing Radar rows would
blur generated suggestions into confirmed continuity. Presentation must also
not read the clock, guess an owner or deadline, or confirm from a truncated
evidence preview.

**Decision:** add a storage-independent `CommitmentReviewQueueQuery` for either
the whole library or an exact duplicate-free set of at most 50 meetings.
ApplicationKit samples one concrete review time and caps each page at 100 roots
and each evidence preview at 20 segments. StorageKit resolves the request in one
snapshot with at most two set-based SELECT statements: roots plus ranked
evidence. Each meeting contributes only open action items from its newest live
summary across all recipes. Eligible roots require an ended live meeting and
nonempty typed evidence, and exclude any confirmed source, dismissed review,
or deferred review whose revisit time is still in the future. Due deferrals
sort before new post-meeting work.

Exact canonical owner hints may be returned only from a live linked speaker;
no due date is inferred. Evidence status describes the complete source, while
the returned segments are an explicitly bounded preview with exact count and
truncation metadata. Stale or partially unavailable source evidence returns no
preview rows. The queue is read-only and cannot confirm, remind, sync, export,
or hydrate Meeting Detail. Exact confirmation remains on the existing
per-meeting editor, and no app route or pre-meeting composition is added in this
slice.

**Consequences:** future pre- and post-meeting surfaces can share one honest,
bounded source of review candidates without weakening the confirmed-only Radar
or creating per-row reads. A future UI must open the exact source meeting for
review and confirmation, explicitly present truncation, and route dismiss/defer
through the existing ApplicationKit mutation boundary. Bundle, CloudKit, CLI,
MCP, reminders, and external task creation remain unchanged.

## D266 — Separate generated review from confirmed Radar truth (Aug 2026)

**Context:** D265 provides one bounded whole-library source of generated work,
but leaving it uncomposed makes post-meeting review discoverable only one
meeting at a time. Mixing those candidates into the existing Radar list would
make an AI suggestion look like a confirmed commitment. Confirming directly
from a bounded evidence preview would also bypass the complete Meeting Detail
review contract.

**Decision:** compose the D265 library queue as a separately labeled **To
review** mode inside Commitment Radar. Confirmed and review modes retain
independent load, page, request-fence, mutation, and failure state. Review cards
are visually identified as suggestions and expose only reversible **Dismiss**
and **Review later** actions plus **Review in meeting**. The latter opens the
complete source meeting and seeks to the first exact transcript source only
when evidence is current; stale or unavailable evidence opens the meeting
without claiming an exact timestamp. The app reuses the existing
`ManageMeetingCommitmentInbox` mutation boundary, while direct confirmation
remains exclusively in Meeting Detail.

**Consequences:** users gain one bounded cross-meeting triage queue without
weakening confirmed continuity, duplicating review policy, or introducing an
N+1 Meeting Detail read. Confirmed filters, reminders, grouping, and mutation
state cannot leak into suggestion review. Pre-meeting composition, candidate
admission, external task creation, sync/export, CLI, and MCP remain unchanged.

## D267 — Measure commitment field quality without retaining meeting content (Aug 2026)

**Context:** the candidate and continuity quality packs measure synthetic model
and linkage behavior, but COMMIT-6 also needs to quantify what users actually
confirm or reject over time. Reusing raw transcript, action-item, person, or
meeting records in a scorecard would create a second sensitive-data surface.
Counting pending or deferred work as correct would also make precision improve
without a human judgment, while dropping invalid confirmed evidence would hide
the most important invariant failure.

**Decision:** introduce one pure PortavozCore evaluator over a rolling 90-day
cohort capped at 50,000 content-free observations. An observation contains only
a UUID, an English/Spanish/mixed bucket, first-presentation and optional review
timestamps, pending/deferred/dismissed/confirmed state, optional opaque local
owner UUIDs and due dates, and one confirmation basis. It contains no text,
name, title, path, meeting identity, model material, or provider metadata.

Confirmed and dismissed observations alone form the terminal-review
denominator. The field false-positive proxy is dismissals divided by terminal
reviews. Owner and due-date precision include only claims that reached a
terminal review: a dismissal is incorrect, while a confirmation must exactly
match the opaque owner token or millisecond date. Evidence coverage includes
confirmed generated direct evidence, user notes, and explicit manual origins;
`missing` remains a valid input category that fails coverage. Confirmation
latency uses deterministic nearest-rank p50/p95. The evaluator reports the same
metrics overall and in stable language order, leaves zero-denominator rates
undefined, rejects duplicate/malformed/out-of-window observations, and makes no
threshold or product decision.

The canonical public fixture contains twelve content-free synthetic
observations across the exact 90-day window and intentionally exercises pending,
deferred, dismissed, confirmed, corrected owner/date claims, manual evidence,
and one missing-evidence failure. It proves evaluator arithmetic only. This
slice adds no database query, persisted field observation, private fixture,
diagnostic export, quality floor, application adapter, Settings surface, or
notification recovery behavior.

**Consequences:** future field evidence can be assembled behind a narrow port
and compared without exposing meeting content or allowing incomplete reviews to
inflate quality. Dismissal remains a field proxy rather than labeled model
ground truth. A later slice must define the storage projection, anonymization
and owner-only retention boundary, real fixture protocol, and explicit release
gates before any metric can block or approve product behavior.

## D268 — Persist content-free commitment presentation evidence (Aug 2026)

**Context:** D267 defines score arithmetic but intentionally cannot observe the
product. Generation time is not presentation time, current review decisions are
mutable, and a confirmed commitment's current owner or due date can change
after the user's first decision. Reconstructing field truth from current rows
would therefore move the denominator, erase corrected mistakes, and silently
lose unreviewed candidates when regeneration retires their source.

**Decision:** add schema v24 with one immutable, idempotent
`commitmentFieldPresentation` row per generated action item at its first real
presentation. The row stores only an opaque presentation UUID, source
action-item UUID, coarse English/Spanish/mixed/other-or-unknown language,
optional domain-separated SHA-256 owner token, optional suggested due date, and
first-presentation time. It stores no meeting identity, text, name, path,
provider material, or foreign key that could delete the field record when the
source is retired. Today's generated inbox infers no deadline, so the persisted
due-date suggestion is intentionally absent.

Presentation capture is allowed only for an open action item from an ended
meeting's newest live summary with complete current direct evidence. Exact
canonical-person suggestions receive an installation-local owner token;
unassigned or ambiguous suggestions do not. Replays return the first record,
including after source retirement, so presentation retries cannot rewrite the
cohort.

StorageKit assembles the current rolling 90-day cohort with one bounded SELECT
of at most 50,001 rows and fails closed above D267's 50,000-observation limit.
The first immutable confirmation event supplies confirmed owner/date/time truth
instead of the mutable current projection. Current dismissal and defer state
remain distinct; a source that disappears before terminal review becomes
`withdrawn`, which stays visible but outside terminal precision. This is a
current rolling observation query, not arbitrary historical reconstruction.

**Consequences:** the product can measure first-presented generated commitment
quality without retaining meeting content or letting later edits rewrite first
confirmation truth. The ledger and query remain local-only and are absent from
CloudKit, bundles, diagnostics, CLI, MCP, export, and application presentation.
Manual and user-note commitments are representable in D267's evaluator but are
not yet emitted by this generated-candidate adapter. A later slice must compose
presentation recording and score display, define owner-reviewed anonymized
evidence and an accepted floor, and keep every metric advisory until that gate
exists.

## D269 — Keep commitment field quality private and advisory (Aug 2026)

**Context:** D268 persists the minimum content-free evidence but deliberately
does not observe product presentation or expose quality to the user. Generation
cannot stand in for a card that the user actually saw, a review mutation may
retire its source before delayed instrumentation runs, and small local cohorts
can look authoritative even though no accepted product floor exists. SwiftUI
must not receive opaque owner tokens, presentation identities, or raw field
observations merely to render a scorecard.

**Decision:** ApplicationKit owns two narrow use cases. The presentation writer
creates the observation identity and samples its clock when a review card first
appears; idempotent StorageKit persistence preserves the original first-seen
record across view retries. A review mutation makes its own best-effort
presentation attempt before dismissing or deferring so source retirement cannot
win the normal path. Process-local in-flight coalescing collapses concurrent
appearance/review attempts, while persistent idempotency remains authoritative.
Instrumentation failure never blocks the user's review and the visible card may
retry later.

The reader samples one rolling-window endpoint, evaluates the bounded cohort,
and returns only `CommitmentFieldQualityScorecard`. Commitment Radar gives this
read an independent **Quality** mode, request fence, loading/empty/failure state,
and bilingual view. Every mode change invalidates all three request lanes so a
late result cannot publish into an inactive surface. Presentation receives
aggregate rates, counts, latency, and
language buckets only. The surface explicitly says that the local rolling
90-day numbers are private and advisory; it has no threshold, release verdict,
automatic mutation, reminder action, or candidate decision authority.

This field evidence remains absent from sync, export, diagnostics, bundles,
CLI, MCP, and notifications. The scorecard does not become a Settings toggle or
a background poll: it is loaded only when its Radar mode is selected.

**Consequences:** real card exposure and explicit local reviews can now improve
the user's understanding of suggestion quality without storing meeting content
or turning an immature metric into policy. Because observation is intentionally
nonblocking, a failed write can make the advisory cohort incomplete; it must not
be described as an exhaustive audit. Owner-reviewed anonymized evidence and an
accepted quality floor remain prerequisites for any future release gate or
serving threshold.

## D270 — Define Meeting Memory Graph questions before schema (Aug 2026)

**Context:** a graph schema chosen from entity names alone would encode an
unproven product shape before Portavoz can state which longitudinal questions
must be answered, which evidence makes an answer valid, and when the correct
behavior is to abstain. A synthetic corpus that shares unrelated truth across
cases can also make an invalid adapter appear correct by leaking an answer that
the isolated question did not support.

**Decision:** define one adapter-neutral query contract before adding product
storage. The canonical public-synthetic corpus contains the six named jobs:
decision history, change since a prior meeting, one person's commitments,
commitment blockers, first discussion, and contradictory or superseding
decisions. Each job is exercised through English-to-English,
Spanish-to-Spanish, English-to-Spanish, Spanish-to-English, code-switched, and
mandatory-abstention cases for an exact 36-case cross-product.

Every case owns an isolated meeting/evidence set, source facts with explicit
generated/confirmed state, revision and freshness, expected typed result IDs,
exact evidence IDs, and forbidden temptations. Expected answers are identities
and evidence rather than generated prose. Abstentions use one typed reason per
job and are valid only when both source text and typed oracle lack the required
confirmed/current truth. The fixture's typed facts are evaluator-only oracle
material; they do not choose a database model or become product entities.

The generator and validator enforce canonical distribution, duplicate-key and
identity safety, current confirmed answer truth, exact evidence ownership,
language relationship, and abstention semantics. This slice adds no migration,
topic/decision projection, background job, model, provider, UI, threshold, or
graph engine. SQLite remains authoritative and a specialized graph remains
unjustified until named product queries miss measured relational budgets.

**Consequences:** GRAPH-1 and later adapters inherit a stable, bilingual,
source-backed oracle and cannot silently redefine correctness around their own
schema. The public corpus proves contract mechanics, not real-world quality.
An owner-reviewed anonymized private pack, correction/rebuild behavior, and
scale/latency evidence remain required before any longitudinal graph answer is
served to users.

## D271 — Keep topic identity relational and explicitly confirmed (Aug 2026)

**Context:** the graph query contract needs topic continuity before decision or
timeline queries can be implemented, but inferred labels are not durable
identity. The same bilingual alias can describe different subjects, generated
similarity can be wrong, and transcript correction or deletion can invalidate
the evidence that originally suggested a link. Persisting generated clusters
or mutable freshness would silently turn inference into authority and rewrite
history.

**Decision:** add schema v25 with four narrowly scoped relational tables.
`topic` owns a UUID and an optional current redirect; `topicAlias` stores an
immutable normalized presentation candidate that is unique only within one
topic; `topicMeetingEvidence` stores immutable exact meeting, segment,
transcript-revision, observed alias, proposal origin, user resolution, and any
profile-local similarity candidate metadata; and
`topicIdentityEvent` records every explicit merge or split append-only. Evidence
source identifiers intentionally have no meeting or segment foreign key so
physical deletion cannot erase why a link once existed.

Constructing a `TopicLinkProposal`, including one produced by generated
similarity, has no side effect. Explicit ApplicationKit commands atomically
create or link a topic only from current exact evidence with no active
correction. Linking first creates the observed topic and then redirects it to
the user-selected active root, leaving alias and evidence on the reversible
child. Alias lookup may return multiple active candidates and resolves merged
aliases to their active UUID root. Explicit merge and split commands append
history and update only the current redirect projection. Evidence status is
derived on read: exact current revision and accepted source is current,
revision drift is stale, and corrected or missing source material is
unavailable.

Every confirmation carries caller-supplied stable identities. A retry that
finds immutable evidence already committed validates that the persisted
identity and content are exactly the same before replaying it; it does not
re-authorize that historical write against transcript state that may have
changed later. The returned evidence still derives its current, stale, or
unavailable status from present authoritative state. Reusing any proposal or
identity-event ID with different content fails closed.

This decision adds no proposal model, threshold, global taxonomy, background
projection, decision continuity, app composition, query-serving adapter,
specialized graph engine, sync/export format, CLI, or MCP behavior. Those must
be earned independently against the graph query contract and real private
evidence.

**Consequences:** Portavoz can retain bilingual topic continuity without
equating labels with identity or allowing a model to merge user knowledge. All
identity changes are explicit, reversible as current projection, and auditable
through immutable events; all links remain inspectable against exact source
evidence. Historical evidence survives source purge but becomes honestly
unavailable. The next slice may define decision continuity on this foundation,
while correction-driven rebuild, scale evidence, UI, and serving remain open.

## D272 — Promote generated decisions only through explicit confirmation (Aug 2026)

**Context:** immutable summary decision evidence identifies exact generated
bullets and transcript support, but generation is not user truth. A later
meeting may restate, replace, or contradict an earlier decision; corrections or
physical deletion may invalidate the source; and semantic similarity cannot be
allowed to confirm a relationship. Reusing generated summary coordinates as a
mutable cross-meeting identity would let regeneration rewrite history.

**Decision:** add schema v26 beside the existing generated evidence. A
`DecisionObservation` is read-only, uses the existing `SummaryDecisionID`, and
always has status `observed`. It resolves the exact rendered bullet, summary,
meeting, transcript revision, and ordered segment evidence. Loading or ranking
that observation performs no mutation. Only an explicit ApplicationKit command
may atomically create a separate stable decision UUID, immutable source
snapshot, ordered durable segment identities, and initial `confirm` event from
complete current accepted evidence with no active correction.

The persisted current projection permits `confirmed`, `superseded`, or
`reversed`; generated `observed` state is never inserted there. Additional
meetings may support the same decision only through an explicit source-link
command. The original confirmed statement remains stable while every accepted
source retains its own exact observed wording, meeting, summary, generated
decision, revision, and segment order. These source identities intentionally
have no ownership foreign key to meeting, summary, or segment rows, so source
purge changes derived availability to unavailable without erasing why the user
confirmed the decision.

Supersession and reversal are explicit relations between two current confirmed
decision UUIDs. One terminal event is appended to the older target and names
the newer successor; the target projection changes atomically while the
successor remains confirmed. Self-relations, terminal-to-terminal rewrites,
foreign confirmation sources, invalid lifecycle history, and identity reuse
with different content fail closed. Exact retries validate persisted identity
before mutable source state and return current derived availability.

No provider, similarity threshold, automatic promotion, projection job,
timeline, Ask lane, UI, sync/export envelope, CLI, MCP surface, or graph engine
is added. Those boundaries must be earned separately against D270's query and
evidence contract.

**Consequences:** Portavoz can preserve decision history across meetings
without treating model output as authority. Confirmed truth is explainable,
source-backed, correction-aware, idempotent, and explicit about which newer
decision superseded or reversed an older one. Decision discovery, bounded
rebuilds, chronology presentation, and serving remain open slices rather than
implicit side effects of this storage foundation.

## D273 — Project memory topology as disposable durable state (Aug 2026)

**Context:** D270 defines evidence-backed longitudinal questions, while D271
and D272 establish explicit topic and decision authority beside existing
confirmed people and commitments. Traversing those normalized source tables
for every future question would couple serving latency to aggregate history,
but introducing a graph engine or persisting inferred relationships would add
complexity before product queries justify it. A derived projection also cannot
advertise partial rebuilds as current, lose work during capture, or let one
expired process publish after another owner resumes the same job.

**Decision:** add schema v27 with one relational, disposable, versioned Meeting
Memory Graph projection. Its v1 edge vocabulary is deliberately limited to
meeting-person, meeting-topic, meeting-decision, meeting-commitment, and
commitment-person. Every edge is rebuilt only from authoritative local rows.
Observed topic evidence remains attached to its reversible child UUID while
the disposable meeting-topic edge resolves to the current live family root.
Confirmed historical relationships may remain topological edges; source
freshness continues to be derived from authoritative evidence and is not
copied into the graph.

SQLite triggers advance one content-free kind-wide source generation and
upsert one invalidation row per affected meeting, person, topic, decision, or
commitment scope. Alias-only presentation edits and other fields that cannot
change v1 topology do not schedule work. Topic merge/split changes invalidate
the source plus old and new roots. Profile changes clear only typed edge tables
and seed every authority scope; newer invalidations are retained rather than
overwritten.

Every bounded publication validates the exact running durable job, lease
owner, target fingerprint, claimed source generation, and lease time. A batch
commits complete scopes and removes only cursor rows no newer than the scope it
rebuilt. Projection high-water advances only after no invalidation at or below
the claimed generation remains. The public snapshot fails closed unless its
profile equals the compiled v1 profile, its generation equals the current
source generation, and the cursor is empty.

ApplicationKit owns the resource-governed projector and durable orchestration.
The macOS composition root owns one signal-driven supervisor, reuses the
generic derived-maintenance lease/retry/suspension ledger, runs only outside
capture, coalesces burst wakes, and resumes committed cursor state after lease
expiry or relaunch. It borrows no model runtime. Launch, recording completion,
and successful topology mutations signal reconciliation; triggers persist work
but do not poll or execute it.

This decision adds no serving timeline, evidence hydration, graph answer,
ranking, provider, model, threshold, graph database, sync/export envelope,
CLI/MCP surface, or UI. Those remain GRAPH-4 and later boundaries and must fail
closed on stale evidence.

**Consequences:** Portavoz now has bounded, crash-resumable local topology
without making generated output authoritative or adding a specialized graph
dependency. Corrections, deletion, reassignment, topic-family changes, and
profile evolution converge by replay from source truth. The projection can be
discarded and rebuilt at any time, while partial or incompatible state is never
servable. Query semantics and evidence freshness remain explicit future work
rather than hidden projection policy.

## D274 — Rehydrate memory timelines from current authority (Aug 2026)

**Context:** D273 deliberately stores disposable topology without evidence
freshness or answer text. Serving those edges directly would let a corrected,
deleted, partial, or profile-incompatible projection look like current truth.
The first longitudinal product read also needs a precise meaning for “since
last time” and must not infer that every decision in a meeting belongs to every
participant. Portavoz still has no confirmed unresolved-question lifecycle;
Apuntador cards are generated assistance, not durable user truth.

**Decision:** add a bounded `MeetingMemoryTimelineQuery` for one exact current
topic or person UUID. An optional exact related meeting is the through anchor;
otherwise the latest related meeting is used. Its immediate prior related
meeting is the baseline. No baseline, stale graph generation, incompatible
profile, pending invalidation, missing subject, unrelated anchor, or invalid
limit returns a typed abstention rather than a partial chronology.

StorageKit executes topology lookup, continuity loading, evidence hydration,
and result assembly in one SQLite read snapshot. Graph edges select candidate
identities only. Every returned decision or commitment event is rehydrated from
its current authoritative continuity record and exact ordered final accepted
segments with no active correction and the matching meeting revision. Current
same-meeting evidence wins over stale or unavailable older sources; otherwise
omissions remain explicit. Output is newest-first, UUID-stable on ties, bounded
to 1...100 items, and carries honest overflow plus stale/unavailable counts.
Each item owns direct meeting, segment, and timestamp navigation.

Topic timelines may expose confirmed decisions, explicit supersession or
reversal, and newly confirmed commitments connected through that meeting's
typed topology. Person timelines expose only commitments whose **current
canonical owner** is that person. Participant topology establishes chronology
but cannot attribute meeting decisions or historical commitments to a person.
The read emits only confirmed authority wording and no generated narrative.
Later commitment lifecycle changes are reported as unsupported until their
events own exact source-segment identity; a nearby commitment source does not
prove a reassignment, reschedule, completion, reopen, or dismissal. Unresolved
questions are likewise unsupported until a separate explicit lifecycle exists;
generated question text cannot substitute for it.

ApplicationKit owns one narrow loading use case. This decision adds no schema,
cache, answer synthesis, Ask lane, UI, model, threshold, graph engine,
sync/export, CLI, or MCP contract. D270 corpus mapping, blocker authority, scale
budgets, and private field evidence remain later gates.

**Consequences:** Portavoz can now compare two related meetings with exact,
correction-aware evidence while preserving SQLite as the source of truth and
the graph as discardable acceleration. Consumers can distinguish an empty
current timeline from unsupported fact classes and typed evidence failure.
Broader longitudinal answers cannot claim completeness until unresolved
questions/blockers and the remaining D270 jobs earn their own authority and
quality evidence.

## D275 — Bind commitment lifecycle changes to exact transcript evidence (Aug 2026)

**Context:** D274 could prove a newly confirmed commitment from its exact
source, but append-only reassignment, reschedule, completion, reopen, and
dismissal events carried at most a meeting UUID. Borrowing the original promise
or a nearby segment would misrepresent why a later state changed. Existing
libraries can also contain valid user-authored lifecycle history that predates
event-level evidence and must remain readable without being upgraded by guess.

**Decision:** extend non-confirm `CommitmentEvent` values with optional exact
authority: one source meeting UUID, that meeting's transcript revision, and an
ordered non-empty set of unique segment UUIDs. Core format 3 validates that the
event and evidence meeting agree; formats 1 and 2 remain decodable. Storage
schema v28 persists the revision on the event and ordered segment identities in
an immutable child table. The child intentionally has no segment foreign key,
so transcript purge makes evidence unavailable instead of mutating history.

The transition write validates one live matching meeting revision and final
accepted segments without active corrections, then inserts event evidence and
updates the commitment projection in one transaction. A SQLite insert trigger
repeats the freshness boundary. Portable replay requires the same exact local
evidence before mutation. The memory timeline rehydrates evidence again in its
read snapshot and emits a typed state change rather than generated prose.
Missing, stale, corrected, deleted, or non-final evidence is omitted honestly.
Legacy lifecycle events remain loadable; when a query encounters one, its fact
kind is reported as unsupported instead of attaching unrelated evidence.

This decision changes no SwiftUI, model, ranking, Ask, graph topology,
sync/export, CLI, or MCP surface. Commitment Radar actions performed outside a
meeting continue to append valid user truth without transcript evidence and are
therefore not evidence-backed chronology items.

**Consequences:** later commitment state can participate in longitudinal memory
only when Portavoz can navigate to the exact current words that authorized the
change. Existing user history remains compatible, and the read model preserves
the distinction between known state and provable meeting chronology. The next
authority gap remains explicit unresolved-question and blocker continuity.

## D276 — Confirm topic-scoped questions before longitudinal serving (Aug 2026)

**Context:** D274 can disclose unresolved questions as unsupported but cannot
serve them because Apuntador cards, summary open-question bullets, and Companion
answers are generated artifacts. Promoting any of those outputs would turn a
model guess into durable meeting truth. A question also has no safe person owner
by default: the speaker who voiced it, the participant expected to answer it,
and the person accountable for follow-up may all differ. Finally, opening a
question does not prove why it was later resolved, reopened, or dismissed.

**Decision:** add schema v29 with an explicit, topic-scoped question authority.
A confirmation command requires one stable question UUID, one exact current
root topic UUID, user-reviewed nonempty wording, and an exact current transcript
revision with a nonempty ordered set of unique final accepted segments that have
no active correction. The opening evidence and wording are immutable. Generated
summary, Companion, and Apuntador records have no path to this boundary without
a separate explicit user confirmation.

Each resolve, reopen, or dismiss command appends one immutable event with its
own exact meeting revision and ordered segment identities. Core permits only
open-to-resolved, resolved-to-open, and open-or-resolved-to-dismissed
transitions in strictly increasing event time. Storage validates the same
current evidence before mutation, repeats the boundary in SQLite triggers, and
updates the current projection atomically from the inserted event. Exact command
retries return persisted authority; reuse of a question or event identity with
different content fails closed. Evidence identities have no meeting or segment
ownership foreign key, so source purge preserves the historical explanation
while later reads report it unavailable.

The Meeting Memory Graph v2 profile adds only meeting-question and
topic-question topology. Opening/tombstone changes invalidate the source
meeting and topic; lifecycle events invalidate only their evidence meeting
because status does not change topic membership. Topic timelines select
question UUIDs through those disposable edges and rehydrate the opening or
transition from authoritative SQLite rows plus current exact evidence in the
same snapshot. They emit typed opened, resolved, reopened, or dismissed facts
with direct navigation. Person timelines report these kinds unsupported rather
than inferring ownership.

This decision adds no blocker relation, generated candidate promotion, UI,
Ask synthesis, model, semantic threshold, graph database, sync/export envelope,
CLI, or MCP contract. Those remain separate gates.

**Consequences:** Portavoz can now preserve and revisit explicit unresolved
questions across meetings without confusing generated assistance with truth or
guessing who owns the question. Every lifecycle claim is independently
navigable and correction-aware, and graph rebuilds remain disposable. The next
authority slice is an explicit decision-to-commitment blocker relationship;
broader D270 product serving still requires adapter and scale evidence.

## D277 — Preserve explicit decision-to-commitment blocker continuity (Aug 2026)

**Context:** the D270 `commitmentBlockers` job still had no authoritative
relationship to serve. A decision appearing near a commitment, or generated
Summary, Companion, and Apuntador prose saying that one blocks the other, is
not durable user truth. A current active flag alone would also erase why a
blocker was cleared and later reopened. Finally, a commitment can become
unblocked while the decision-to-commitment relationship remains part of the
meeting history, so graph topology and current serving state cannot be the same
projection.

**Decision:** add schema v30 with one explicit stable blocker UUID relating one
confirmed live decision to one confirmed live commitment. Initial confirmation
requires an exact current transcript revision and an ordered nonempty set of
unique final accepted segments without active corrections. The relationship
starts active. Clear and reopen are the only lifecycle transitions; each
appends an immutable event with its own exact accepted-transcript evidence and
strictly increasing time. Reopen additionally requires both endpoints to remain
confirmed and live. Exact retries are idempotent, while reuse of a blocker or
event identity with different content fails closed. Storage transactions and
SQLite triggers independently enforce endpoint, evidence, transition,
projection, and immutable-history constraints.

Meeting Memory Graph profile v3 adds disposable `meeting-blocker` and
`decision-commitment-blocker` topology. Every live opening and transition
evidence meeting remains connected after a clear, and the stable relationship
remains projected while its endpoints are live. Lifecycle status therefore
does not invalidate or filter topology; deletion and relationship/evidence
membership do. The topic timeline uses graph rows only to select candidate
blocker UUIDs, then rehydrates authoritative opening or transition records and
current exact evidence in the same SQLite snapshot. It emits typed blocked,
cleared, and reopened facts with direct segment navigation. Active-blocker
serving is a separate bounded read and requires the blocker and both endpoints
to be currently active/confirmed/live.

Generated summary, Companion, Apuntador, proximity, semantic similarity, and
model output cannot call the confirmation or transition boundaries. No app UI,
Ask synthesis, automatic candidate promotion, model threshold, graph database,
sync/export envelope, CLI, or MCP contract is added by this slice.

**Consequences:** Portavoz can now explain that a confirmed decision blocked a
confirmed commitment, why that blocker changed, and where each claim was said,
without turning generated language into authority or deleting cleared history.
The graph remains disposable and status-independent while current serving stays
strict. The remaining D270 gates are the corpus-to-product adapter, relational
scale budgets, owner-reviewed field evidence, and eventual Ask/UI composition.

## D278 — Serve explicit blocker facts without promoting graph topology (Aug 2026)

**Context:** D277 established authoritative blocker continuity and disposable
graph edges, but the D270 `commitmentBlockers` job still had no product query.
Returning graph rows directly would make an acceleration structure appear
authoritative. Hydrating every related record before bounding candidates would
make one exact question unbounded, while applying the visible result limit
before evidence validation could let a newer stale candidate hide an older
current fact.

**Decision:** add the first exact graph-fact query for one caller-supplied live
`CommitmentID`. The public Core contract accepts only a 1...100 result limit
and returns typed active `decision-blocks-commitment` facts or a typed
abstention. StorageKit first requires a ready current graph projection, then
uses only decision-commitment-blocker topology to select a deterministic
bounded candidate window. It rehydrates blocker, decision, and commitment
authority in the same SQLite read snapshot and requires the blocker to remain
active plus both endpoints to remain confirmed and live.

The exact fact evidence is the current accepted commitment source followed by
the explicit blocker-confirmation source, with duplicate segments removed.
The blocker evidence is the primary navigation target. Historical decision
confirmation evidence is not appended merely because the decision is an
endpoint: the D270 oracle requires the commitment and causal-relation sources,
not unrelated provenance. Active corrections, transcript revision drift,
missing/non-final segments, or a commitment without exact transcript evidence
cannot become a fact. Unusable candidates are filtered before the visible
result limit; bounded overflow remains explicit through `hasMore` or
`candidate-budget-exceeded`, never a fabricated complete answer.

ApplicationKit exposes one injected `LoadCommitmentBlockers` use case that
returns typed facts and evidence only. The macOS Ask composition root does not
adopt it in this slice. No natural-language commitment discovery, answer
synthesis, UI, provider/model call, graph database, sync/export envelope, CLI,
or MCP surface is added.

**Consequences:** one named D270 job now has a source-backed product adapter
whose graph is only a candidate index and whose facts remain explainable from
authoritative local records. Query cost and output are bounded, correction
behavior fails closed, and a missing exact commitment source is disclosed
rather than silently weakened. Ask integration, person/topic/date/status
filters, cross-lane selection, corpus mapping, private field evidence, and
relational scale budgets remain separate GRAPH-5/GRAPH-6 gates.

## D279 — Map canonical blocker cases through public product boundaries (Aug 2026)

**Context:** D278 characterized its exact query with focused hand-built Store
fixtures, while D270's six multilingual `commitmentBlockers` oracle cases still
ran only in an adapter-neutral Python evaluator. Passing both independently did
not prove that product persistence, projection, ApplicationKit orchestration,
and canonical expected identities agreed. Importing oracle facts directly into
runtime storage would make the test fixture appear authoritative and could hide
missing confirmation boundaries.

**Decision:** add a test-only product conformance adapter for exactly the six
canonical blocker cases. Every case receives a fresh in-memory `MeetingStore`
and deterministic local identities. The adapter saves exact transcript and
Summary evidence, confirms the generated-action commitment, confirms the
decision observation, confirms a blocker only when the corpus contains one
explicit confirmed `blocks` relation, runs leased graph projection, and invokes
`LoadCommitmentBlockers`. It maps only returned typed decision and transcript
identities back to external corpus IDs, then requires exact ordered results,
exact ordered evidence, exclusion of every forbidden result, and the declared
unsupported-causality abstention.

Generated `associatedWith` distractors are deliberately not persisted. The
adapter cannot write authority directly through GRDB, imports no
IntelligenceKit provider, reads no user library, and is absent from app, Ask,
CLI, MCP, sync, and UI composition. The corpus remains a test oracle rather
than a product data source.

**Consequences:** the first named D270 product query now proves end-to-end
conformance across English, Spanish, cross-language, code-switched, and
abstention cases using the real local boundaries. This does not make natural-
language commitment discovery or answer synthesis available, does not validate
the other five jobs, and supplies no relational scale or private field
evidence. Those remain later gates.

## D280 — Keep first-discussion chronology authoritative and graph-checked (Aug 2026)

**Context:** D271 made confirmed `TopicMeetingEvidence` the durable authority
for a topic family's meeting membership, while D273 projected disposable
meeting-topic topology. The D270 `firstDiscussion` job still had no product
query. Ordering graph rows would make a rebuildable index decide chronology;
skipping a stale earliest mention in favor of a later current mention would
silently change the meaning of "first"; and resolving free-form labels inside
the query would conflate identity discovery with evidence serving.

**Decision:** add an exact `TopicFirstDiscussionQuery` for one caller-supplied
`TopicID`. StorageKit resolves that identity to its current topic-family root,
loads the complete authoritative family evidence in chronological meeting and
segment order, and selects the canonical earliest row before considering
freshness. A ready graph projection must contain the matching root-topic to
meeting edge, but it cannot choose or reorder the result. The same SQLite read
snapshot then hydrates the exact current accepted transcript segment and emits
one typed `topic-discussed-in-meeting` fact with canonical topic/meeting UUIDs,
authoritative labels, event time, exact evidence, and direct navigation.

If the authoritative earliest row is stale, unavailable, corrected, or absent,
the query abstains rather than substituting a later mention. A ready projection
that lacks the exact authoritative edge reports `projection-inconsistent`.
ApplicationKit exposes the injected `LoadTopicFirstDiscussion` boundary;
natural-language topic discovery, Ask composition, answer generation, and
cross-lane ranking remain separate work.

Map exactly the six canonical `firstDiscussion` cases through fresh in-memory
Stores using only public meeting, transcript, topic-confirmation, graph-job,
and ApplicationKit APIs. Persist the distractor topic as a distinct confirmed
identity, map returned typed evidence back to corpus IDs, and require exact
results, exact evidence, forbidden-result exclusion, and the declared stale-
evidence abstention. The adapter imports no IntelligenceKit or GRDB and cannot
write authority directly.

**Consequences:** Portavoz can now answer one exact identity-resolved
first-discussion question without treating graph topology, labels, or generated
prose as truth. English, Spanish, cross-language, code-switched, distractor,
and stale cases exercise the real product boundaries. Ask still cannot discover
or compose this lane, and the other four unimplemented D270 jobs, graph scale
budgets, owner-reviewed private evidence, sync/export, CLI, MCP, and UI remain
open.

## D281 — Keep person commitments exact, current, and source-backed (Aug 2026)

**Context:** the D270 `personCommitments` job had authoritative confirmed
commitments, explicit `me`/person/unassigned ownership, and disposable
commitment-person topology, but no exact graph-fact query. Reading graph edges
as ownership could return stale or corrupted assignments; reusing Commitment
Radar would hydrate presentation/history that this fact lane does not need; and
accepting a display name in StorageKit would conflate ambiguous identity
discovery with factual serving.

**Decision:** add a bounded `PersonCommitmentsQuery` for one caller-supplied
live `PersonID`. StorageKit first counts authoritative open confirmed
commitments whose current assignee is exactly that person and requires the
ready graph projection to contain the same complete active ownership set.
Missing or partial commitment-person topology returns
`projection-inconsistent`; no current work returns `no-active-commitments`.
Only a matching projection may select a deterministic bounded newest-first
candidate window.

Every candidate is rehydrated from its complete commitment continuity envelope
in the same SQLite read snapshot. Current status, exact typed assignee, wording,
and source order remain authoritative. At least one current accepted transcript
source is mandatory. If any reassignment exists, the latest reassign event must
agree with the current assignee and carry its own exact current transcript
evidence. The reassignment evidence is primary, followed by deduplicated
original-promise evidence, and its event time becomes the fact time. An
evidence-less or stale reassignment fails closed instead of borrowing the former
owner's source. Other stale, unavailable, corrected, non-final, missing, or
manual evidence without an exact segment also fails closed. Evidence validation
precedes the visible result limit, candidate overflow stays explicit, and each
typed `person-committed-to` fact carries current wording plus exact navigation.
Completed, dismissed, `me`, unassigned, and other-person work is excluded.

ApplicationKit exposes only an injected `LoadPersonCommitments` use case. Ask
does not compose it, and free-form name/alias resolution remains outside the
storage contract. The canonical ambiguous-Alex abstention therefore belongs to
a later identity-resolution/product-conformance slice rather than a display-name
parameter here. No model, answer synthesis, UI, graph database, sync/export,
CLI, or MCP surface is added.

**Consequences:** Portavoz now has an exact person/status fact lane that cannot
let graph popularity, proximity, or labels invent ownership and cannot present
completed work as current. Focused tests cover lifecycle exclusion, partial
projection corruption, bounded ordering, stale evidence, unavailable identity,
exact reassignment provenance, evidence-less reassignment, former-owner
exclusion, and application delegation. Canonical multilingual mapping, identity
discovery, cross-lane Ask selection, relational scale budgets, and private field
evidence remain open.

## D282 — Resolve person aliases once and abstain before factual serving (Aug 2026)

**Context:** D281 deliberately accepted only an exact `PersonID`, while the
canonical `personCommitments` corpus asks by human name. Five cases name one
confirmed Mara, but the abstention case contains two deliberately distinct
people who both have the exact alias Alex. Letting StorageKit choose one
candidate would invent identity; making callers manually combine candidate
lookup and fact loading would duplicate fail-closed semantics before Ask can
compose the lane; and giving the lookup port mutation capabilities would let a
read path merge people accidentally.

**Decision:** split read-only `CanonicalPersonCandidateReading` from the
explicitly mutating `CanonicalPeopleStore`. Add
`LoadPersonCommitmentsByAlias` as a narrow ApplicationKit orchestration over
that candidate port and the existing exact `PersonCommitmentFactReading` port.
Its input is a caller-extracted alias plus the existing bounded item limit; it
does not parse natural language. Blank aliases and invalid limits abstain as an
invalid query, no exact normalized candidate abstains as person unavailable,
and more than one distinct candidate abstains as ambiguous person. Only one
candidate can become a `PersonCommitmentsQuery`, so StorageKit continues to
receive exact UUID identity and remains unaware of names.

Map all six canonical `personCommitments` cases through fresh in-memory Stores
using only public meeting, speaker, person create/link, transcript, Summary,
commitment confirmation/lifecycle, graph-maintenance, and ApplicationKit APIs.
Persist every forbidden completed or other-person commitment rather than
removing distractors in the adapter. Derive the lookup alias from fixture
identity, never by parsing query prose, and map only returned typed commitment
and transcript identities back to corpus IDs. Require exact ordered result and
evidence identities, forbidden-result exclusion, and ambiguous-Alex abstention.
The adapter imports neither GRDB nor IntelligenceKit and performs no direct
authority write.

**Consequences:** all three implemented source-backed graph fact lanes now
cross their canonical public product boundaries. Person lookup is reusable,
read-only, normalized by the existing store, and fail-closed for same-name
people; it cannot create or merge identities. Ask still does not extract an
alias, compose this use case, synthesize an answer, or rank graph facts against
transcript retrieval. The remaining three D270 jobs, relational scale budgets,
owner-reviewed private evidence, sync/export, CLI, MCP, and UI remain open.

## D283 — Keep graph facts beside transcript evidence, never in its place (Aug 2026)

**Context:** three exact source-backed graph queries now pass canonical product
conformance, but Ask exposed only transcript lexical/semantic citations. Adding
graph facts directly to the existing citation array would erase their typed
subject, object, status, and abstention semantics; ranking them as transcript
hits would let topology compete with source evidence; and sending them to the
answer model before an explicit contract would make a dormant architecture
slice change user-visible answers.

**Decision:** add one independent `AskGraphFactRetrieving` lane. Its closed
`AskGraphFactQuery` accepts only a caller-resolved exact commitment blocker,
topic first discussion, or person commitment query. The local adapter delegates
to the existing three ApplicationKit fact use cases and returns
`MeetingMemoryGraphQueryResult` unchanged. `AskEvidenceBundle` stores transcript
citations and a graph outcome separately. A lane that was not requested remains
distinguishable from a typed domain abstention. Ordinary graph operational
failure becomes an explicit unavailable outcome without removing transcript evidence;
cancellation still cancels the complete bundle.

`AskMeetings.evidenceBundle` runs the two lanes concurrently, while every
released `search`, `evidence`, and `answer` API remains source compatible and
continues to use transcript retrieval alone. The answer provider still accepts
only `[AskCitation]`; no graph fact is converted into generated prose or added
to transcript RRF. Production local composition owns the exact graph adapter,
but no current UI, CLI, MCP, command-palette, or meeting-brief path requests the
new bundle.

**Consequences:** Ask has a reversible, testable seam for longitudinal facts
without weakening exact transcript evidence or changing shipped answers. The
next slices must resolve explicit person/topic/date/status filters, define the
typed fact-aware synthesis contract, and measure bounded cross-lane selection
before any user-facing composition. Graph telemetry, the remaining three D270
jobs, relational scale budgets, private evidence, sync/export, CLI, MCP, and UI
remain open.

## D284 — Resolve exact Ask filters without changing fact authority (Aug 2026)

**Context:** D283 gave Ask a separate typed graph-fact lane, but callers could
only submit an already-resolved graph query. Filtering a returned page by an
unresolved name would risk guessing between same-name people or topics.
A post-page date or status filter would also be semantically wrong: a matching
fact can sit beyond the candidate limit, and first-discussion chronology must
be evaluated inside the requested range rather than filtered after choosing an
all-time winner.

**Decision:** add a caller-extracted `AskGraphFactFilterRequest` in
ApplicationKit. It accepts at most one exact person or topic alias, one finite
half-open occurrence range, and one typed fact status. The local resolver uses
the existing read-only canonical-person and canonical-topic candidate ports;
zero or multiple candidates abstain, and candidate lookup cannot mutate or
merge identity. The resolved identity must equal the exact `PersonID` or
`TopicID` already carried by the compatible graph query. Mixed identity
dimensions, identity mismatch, or attaching an identity to another graph job
is invalid before fact retrieval.

Add one shared `MeetingMemoryGraphFactFilter` to the three exact query
contracts. Its finite half-open occurrence interval and closed typed status are
intersected with any existing exact constraints before the query enters
StorageKit; disjoint constraints abstain as `no-matching-facts`. Blocker
confirmation time and the authoritative person-commitment occurrence time
(latest reassignment, otherwise commitment creation) participate in candidate
SQL before ordering and limit. First-discussion serving chooses the earliest
authoritative topic evidence inside the range; meeting and segment chronology
is batch-loaded, and an unknown occurrence fails closed rather than skipping a
potentially earlier source.
Every candidate is still rehydrated and rechecked against the same filter in
the SQLite snapshot. The fixed active/confirmed fact shapes reject incompatible
statuses as a typed no-match.

**Consequences:** Ask now has a deterministic, local, ambiguity-safe filter
boundary for exact person, topic, occurrence date, and fact status without
changing transcript retrieval, answer generation, storage schemas, or factual
authority. Pagination and chronology remain truthful because filtering occurs
before the visible limit, never over an already bounded page. It is not a
natural-language parser and no released UI, CLI, MCP, command-palette, or
meeting-brief consumer invokes it yet. Typed fact-aware synthesis, bounded
cross-lane selection, the other three D270 fact jobs, telemetry, scale budgets,
and private field evidence remain separate gates.

## D285 — Give Ask synthesis typed facts and exact source segments (Aug 2026)

**Context:** Ask could retrieve source-backed graph facts beside transcript
citations, but its answer provider accepted only `[AskCitation]`. Flattening a
fact into that ranked array would discard subject/object/status semantics, let
graph popularity impersonate transcript relevance, and make generated prose
the only visible representation of a relationship. Passing a fact without its
current exact source segments would also weaken the provenance contract already
enforced by storage.

**Decision:** preserve the released transcript-only `AskMeetingAnswering` port
and add a separate opt-in `AskEvidenceBundleAnswering` port over one storage-
independent `AskSynthesisInput`. The new input keeps transcript citations and a
closed typed graph lane separate. Each admitted
`AskGraphFactSynthesisEvidence` carries the original typed fact plus exact
source citations derived from current authoritative evidence. Admission
requires non-empty evidence, the declared primary segment, unique segment
identities, and consistent current material when a segment appears in both
lanes. Typed domain abstention, operational unavailability, and malformed
provenance remain distinguishable; malformed graph evidence is excluded
without erasing valid transcript material.

Add one opt-in `AskMeetings.answerBundle` workflow. It accepts an already exact
graph job and optional exact filter, runs the existing two-lane retrieval, sends
the typed synthesis input to generation, and returns the unchanged evidence
bundle beside optional generated text. Existing released `answer` calls keep
their transcript-only provider and response shape. Fact-aware generation
requires both independently ranked exact transcript citations and a valid
source-backed graph page: graph facts cannot replace an empty transcript result,
and a transcript retrieval error still fails the complete operation. Page
truncation, projection generation, and stale or unavailable evidence omissions
travel with the admitted facts so incomplete graph results cannot authorize an
exhaustive "all" or "none" claim.

IntelligenceKit represents graph relationships as `RAGFact` values with exact
`RAGPassage` sources inside a disclosure-bearing `RAGFactPage`. Transcript
passages and facts receive separate prompt markers; graph sources are
deduplicated only by exact segment identity. Fact markers communicate structure
but are not valid citations. Generated claims must cite exact transcript or
graph-source segment markers, and invalid primary, duplicate, inconsistent, or
stale source provenance fails before model execution.

**Consequences:** Ask now has a reversible, local fact-aware synthesis contract
without changing released UI behavior, transcript RRF, storage schemas, or graph
authority. Evidence survives model absence and ordinary generation failure.
At this decision boundary cross-lane selection was intentionally absent, so no
presentation, CLI, MCP, command-palette, or meeting-brief surface could adopt
graph-aware generation until bounded selection proved exact evidence could not
be drowned by volume.

## D286 — Reserve transcript rank before bounded graph facts (Aug 2026)

**Context:** the typed synthesis boundary kept graph relationships out of
transcript RRF, but it still passed every retrieved fact and exact source to the
opt-in provider. A large graph page could therefore consume the local model's
context, make repeated topology look more important than the independently
ranked transcript evidence, or require dropping only part of one fact's exact
provenance. Deduplicating sources without disclosing the resulting selection
would also make an incomplete page appear complete.

**Decision:** run one deterministic ApplicationKit selector after transcript
RRF and before the opt-in fact-aware provider. Reserve the unchanged first six
transcript citations. Then admit one query-ordered contiguous prefix of at most
four graph facts, never more facts than selected transcript citations. A fact
is atomic with all exact source segments. Admit at most eight unique graph
sources not already present in the transcript selection; overlapping exact
sources consume zero additional budget and reuse their transcript prompt
marker. Stop before the first fact that would exceed the source budget rather
than skipping it for a cheaper later relationship. If no fact fits, return a
typed selection-budget-exceeded graph lane and do not generate.

Carry candidate, selected, additional-source, and omitted-fact counts in one
closed selection disclosure. Selection omissions participate in page
completeness. ApplicationKit validates that disclosure against the selected
material, while IntelligenceKit independently validates the same counts,
facts-to-transcript bound, exact source overlap, and additional-source count
before constructing a prompt. Prompt source deduplication is identity-based:
an overlapping graph source cites `[T…]`; only a new source receives `[S…]`.

**Consequences:** graph volume cannot alter transcript RRF or displace the
reserved transcript prefix, and no selected relationship loses provenance.
The model receives bounded, deterministic, omission-aware material while the
answer result retains the full unselected two-lane evidence bundle. There is no
schema, graph authority, model, or released-product behavior change. Released
Ask, UI, CLI, MCP, command-palette, and meeting-brief surfaces remain
transcript-only; remaining graph jobs, scale evidence, telemetry, and explicit
adoption are separate decisions.

## D287 — Clear playback ducks only where a full ramp cycle fits (Aug 2026)

**Context:** clear playback ducks the microphone outside transcript-confirmed
local turns, ramping up 60 ms before each turn and back down 120 ms after it.
`CleanPlaybackPolicy` merged only overlapping ranges, so two turns separated by
any positive gap stayed distinct. When that gap was shorter than one full
duck-and-recover cycle the emitted ramps overlapped — an observed pair produced
a release ramp of `[262.680, 262.800]` immediately followed by an attack ramp
of `[262.700, 262.760]` nested inside it. `AVMutableAudioMixInputParameters`
answers an out-of-order or overlapping ramp with an Objective-C exception,
which Swift cannot catch, so opening the meeting aborted the process. Nine of
39 real local meetings carried at least one such pair; every one of them was
unopenable, and refining a transcript could introduce the condition because it
rewrites turn timings.

**Decision:** decide separation with the same arithmetic the schedule emits.
Two ranges stay distinct only when the earlier release ramp ends no later than
the later attack ramp starts; otherwise they merge into one audible range —
ducking for under `attack + release` is inaudible anyway. Volume events become
pure policy: `CleanPlaybackPolicy.volumeSchedule` returns the complete typed
timeline, and `MeetingAudioComposition` only replays it. Because the merge
predicate and the schedule compute identical expressions, no rounding at the
boundary can leave the schedule overlapping.

The AVFoundation boundary additionally validates the schedule with
`isStrictlyOrdered` and returns no mix when it is violated, so a future policy
regression degrades to an unducked microphone instead of terminating the app.

**Consequences:** meetings with rapid back-and-forth turns open and play. Very
closely spaced local turns are ducked as one range rather than individually,
which is the audible intent. Clip export shares the composition and inherits
the fix. There is no schema, capture, transcript, or storage change.

## D288 — Replace a superseded summary instead of losing it (Aug 2026)

**Context:** the post-capture workflow enqueues the summary job while
publishing the diarization artifact, and binds it to a fingerprint computed
from the attributed material still in memory. The summary worker later recomputes
that fingerprint from a durable `MeetingDetail` read and refuses to run when the
two differ. Nothing replaced the refused job: `reconcileProcessingLifecycle`
treats `cancelled` as neither pending nor failed, so the meeting settled on
`ready` with `lastProcessingError` cleared and no summary, and Meeting Detail
showed the ordinary **Generate summary** button as though the user had simply
never asked.

Two meetings in a 47-meeting local library reached that state, six seconds after
capture, with no transcript correction anywhere in their history. Recomputing
their enqueued fingerprint from the frozen durable rows failed across every
combination of segment order, output language, glossary, provider, and
transcript revision, while the same reconstruction reproduced a succeeded
meeting's fingerprint exactly. The prediction is therefore not reliably
reproducible from the rows it fences, and no single drifting input explains it.

Separately, the reviewed transcript projection those fingerprints hash ordered
segments by `startTime` alone. The microphone and system channels routinely open
a segment at the same instant — both affected meetings contain such pairs — so
that projection had no total order and the fingerprint was not a function of the
durable rows.

**Decision:** stop depending on the prediction being right.
`TranscriptSegmentOrder` is the one transcript order shared by every durable
read and every in-memory artifact: start time, then segment identity, which
`ORDER BY startTime, id` reproduces byte-for-byte. The reviewed detail
projection and the export aggregate adopt it, and the post-capture workflow
canonicalizes attributed material before it both fingerprints and publishes it,
so the producing stage and the consuming stage agree by construction.

When the summary worker still finds a mismatch it cancels the stale attempt and
admits a replacement bound to the fingerprint it just read, in the same
transaction. Storage admits one replacement per kind per meeting — the attempt
being cancelled is still `running`, so an earlier cancelled sibling means the
repair already happened and a second drift means the input keeps moving. The
existing `(meeting, kind, fingerprint)` idempotency key makes a repeated
replacement a no-op. The completion action moves to the attempt that settles the
meeting rather than firing on a cancellation that still owes it a summary.

This does not extend to D233. A transcript correction cancels accepted-only
`summary` and `index` work inside the correction transaction with the owner
lease cleared, so it can never reach the worker's replacement path; explicit
regeneration remains the contract for corrected material. What D233 left
missing there is the signal, not the job: `MeetingDetailSummaryPlaceholder`
now states that the automatic summary was cancelled — distinguishing a
superseded input from an unavailable engine — directly above the generation
button that repairs it. The meeting keeps reporting `ready`, which is true: its
audio and transcript are intact, and `needsAttention` would offer recording
recovery for a summary that was never a recording problem. The reviewed Meeting
Detail boundary advances to 372 interaction signals, twelve owners, and 28 UI
journeys.

**Rationale:** a fingerprint that fences durable work must be a function of
durable state; a total order makes that true and removes one proven source of
drift. Because the field evidence shows drift this repository cannot yet fully
explain, correctness cannot rest on having found every cause — replacing the
attempt repairs the meeting whatever the cause, while the one-replacement bound
keeps a genuinely unstable input from spinning the worker. Leaving the
lifecycle state alone keeps `ready` honest and puts the explanation where the
user can act on it.

## D289 — Keep one local planning file and one durable gap ledger (Aug 2026)

**Context:** planning truth was spread across four documents totalling roughly
405 KB. `docs/ROADMAP.md` held the forward bands, `docs/refactor-20260714.md`
held a migration program whose bands 0–6 were complete, and
`docs/STRATEGY-20260716.md` mixed engineering guidance with pricing, website,
marketing, and competitive strategy. All three were local-only. The tracked
`docs/GAPS.md` had grown to 65 KB, most of it prose describing resolved gaps
whose rationale already lived in `DECISIONS.md` and the specs. A session could
not answer "what is pending" without reading all four and reconciling their
overlapping, partly stale status claims.

**Decision:** `docs/ROADMAP.md` becomes the single local planning authority. It
carries the program rules, the shared definition of done, a per-ticket working
agreement, the architecture context a pending ticket needs, a one-line-per-slice
delivered ledger, and an ordered ticket queue. Completed work is never described
at length there — it points at its decision numbers, because `DECISIONS.md` is
already the authority for why something was done.

Business strategy — pricing policy, packaging, commerce provider selection,
website and marketing principles, and product anti-goals — moves to the tracked
`docs/PRODUCT.md`, which already owned vision, positioning, and the competitive
map. `docs/refactor-20260714.md` and `docs/STRATEGY-20260716.md` are deleted.

`docs/GAPS.md` stays tracked and keeps every gap as a ledger row, but a resolved
row is compressed to its verdict plus decision references. Open and partial rows
state their remaining scope in full, because a tracked document must remain
self-sufficient — it may not depend on the gitignored roadmap for its meaning.

**Consequences:** the planning corpus drops from about 405 KB to 111 KB with no
pending work, acceptance criterion, or field-validation item lost. One file
answers "what is next", one answers "what is missing", one answers "why", and
one answers "what is built". The hygiene script keeps rejecting all three
retired planning paths if they are ever tracked.

## D290 — Score every Ask query variant in one corpus traversal (Aug 2026)

**Context:** deterministic bilingual expansion turns one question into several
query variants so an unaccented Spanish phrasing can reach accented source text.
`LocalAskMeetingRetrieval` then called the semantic port once per variant, and
the exact Accelerate control answers each call by streaming every compatible
embedding BLOB out of SQLite. Three variants therefore streamed and scored the
whole corpus three times to produce one fused result, and the cost grew with
both corpus size and expansion breadth — on the retrieval path whose budget is
first evidence.

**Decision:** the semantic port gains a batch entry point that takes the query
variants together and returns results corresponding positionally to them. The
protocol supplies a default that loops the single-query call, so an adapter that
cannot fuse the work — including every shadow research candidate — keeps exactly
its previous behavior. `AccelerateExactSemanticIndex` overrides it, and
StorageKit scores all variants during one cursor: the row is read once, each
variant's dot product runs against the same BLOB, and each variant keeps its own
bounded top-k with the unchanged score-then-traversal-order tie-break.

A variant that does not match the active profile, or whose score is not finite,
contributes nothing while keeping its position, because the caller's fusion
ranks by variant order. The single-query entry point is now a wrapper over the
batch, so both paths share one implementation.

**Consequences:** Ask reads the corpus once per request instead of once per
variant, and expansion breadth stops multiplying I/O. Ranking, fusion, top-k
bounds, profile fencing, and citation authority are unchanged — the equivalence
is asserted per variant against the previous per-query scan. There is no schema,
product, or UI change.

## D291 — Keep the batched scan's hot loop free of per-row overhead (Aug 2026)

**Context:** D290's batched traversal rebased a query slice and took an `inout`
array-element reference once per row *per variant*. At corpus scale that is
100k pointer rebases and 100k bounds-and-exclusivity checks for work that does
not change between rows. A same-host A/B against the pre-change build measured
the one-variant path slower after batching, which would have made the
optimization a trade rather than a win for Library search and any single-query
consumer.

**Decision:** slice every variant once before the row loop, and hold the
candidate lists through `withUnsafeMutableBufferPointer` so admission writes
through a direct element pointer. The scan keeps one shape for every variant
count; there is no separate single-query loop to drift from the batched one.

**Consequences:** the measured one-variant p95 improved from 177.66 ms to
154.25 ms and p50 from 144.89 ms to 137.02 ms on the same host.

The attribution evidence in `docs/evidence/semantic-batch-attribution-20260806.json`
is explicitly diagnostic. It reproduces the property D290 exists for — three
variants cost about one traversal rather than three — in both builds. It does
**not** settle whether a residual one-variant regression remains: the runs
disagree with themselves, one of them measuring three variants faster than one,
so this workstation's noise exceeds the effect. Every run there, including the
pre-change build at 129.14 ms, sits far above both the 100 ms budget and the
92.85 ms committed baseline, which is itself evidence that the host is not the
release authority PERF-001 requires. Confirming the budget stays a controlled-host
measurement in the field queue, and SEARCH-3 is not claimed closed on budget.


## D292 — Declare skill capability before reading what a skill acts on (Aug 2026)

**Context:** Band 8 turns confirmed memory into actions. The material those
actions run over is a transcript — text other people spoke, read by a model.
Any design where the thing being acted on can influence what the action is
allowed to do is a prompt-injection hole with a real external effect at the end
of it. Nothing in Portavoz had a skill vocabulary yet, so this is the moment the
boundary is cheap to set.

**Decision:** a skill publishes an immutable `SkillDefinition` — id, version,
capability set, confirmation policy — and that declaration is the ceiling. A
`SkillProposal` may request a subset of it and never a superset;
`SkillAdmissionPolicy` refuses `undeclaredCapability` without inspecting
anything else. Arguments are typed values (`meeting`, `segment`, `person`,
`commitment`, bounded `text`, `date`), so there is no free-form command string
for injected text to inhabit; admission validates their shape and never their
meaning.

Confirmation is per proposal by default and expires after fifteen minutes, so a
proposal the user left unconfirmed is re-proposed rather than executed later
against changed material. A standing rule may replace that confirmation only
when every requested capability is reversible, checked both at definition time
and against the requested subset that will actually run. Remote capability
additionally requires separately permitted egress.

`SkillExecutionState` distinguishes the states that cannot have acted
(`proposed`, `previewed`, `dismissed`) from those that may have
(`confirmed` onward), and `SkillExecution` carries an idempotency key stable
across retries of one proposal.

**Consequences:** this slice is pure policy in `PortavozCore` with no executor,
no storage, no UI, and no adapter. No skill can run yet, which is the point: the
admission rule exists before anything can be admitted. The shipped no-egress
tier will declare only `readMeetingMaterial`, `writeLocalDraft`, and
`writeLocalFile`; `sendRemote` stays declarable but unused until external
integrations are a separate decision.

## D293 — Claim the effect before running it (Aug 2026)

**Context:** D292 decides whether a skill *may* run. Nothing yet decides whether
it *already has*. A skill's effect is outside Portavoz — a reminder draft, a
file — so a retry, a relaunch after a crash, or two windows acting at once must
not produce it twice. Deciding that in memory loses the answer exactly when it
matters, at relaunch.

**Decision:** schema v31 adds the shape the reminder lifecycle already
established — an append-only `skillExecutionEvent` log as the authority and one
`skillExecutionState` projection so relaunch answers "did this already run?" in
one read instead of replaying history.

The claim is the `idempotencyKey`, unique across the table, so two proposals can
never own one effect and a repeat confirmation of one proposal returns the
existing claim rather than creating a second. `(proposalID, attempt, kind)` is
unique too, so a duplicated transition is refused by the database rather than by
trusting the caller to have checked.

Transitions are deliberately asymmetric about what may already exist. A
`succeeded` execution is never admitted again. An `executing` one found at
relaunch is also not admitted: the process died mid-run, so the effect may or
may not exist and the caller must reconcile rather than repeat. A `failed` one
may retry under an incremented attempt, so the log distinguishes the retry from
the original. Cancellation is legal only before the run begins; afterwards only
the outcome can be recorded, because the effect may already be real.

History is ordered by insertion rather than by `occurredAt`. Two transitions can
share a timestamp, and ordering by time with an id tiebreak sorted a
confirmation after the run it authorized whenever both landed in the same
instant. The log is append-only, so insertion order is the causal order.

Events carry a typed `FailureCategory` and never a message, because a failure
string is the easiest place for meeting-derived text to leak into a durable
record.

**Consequences:** storage and policy only — no executor, no adapter, no UI, and
no skill that can run. Secrets stay in Keychain and never reach these tables.

## D294 — Admit, then claim, then act (Aug 2026)

**Context:** D292 decides whether a skill may run and D293 whether it already
has. Composing them is where the ordering becomes load-bearing, and where the
two decisions can quietly become three.

**Decision:** `ExecuteSkill` runs admission first. A refused proposal writes
nothing, because a claim with no admission would leave an execution nobody can
settle and nothing to reconcile it against. An unregistered skill is refused at
the same point, for the same reason: a claim with no way to perform it could
never reach a terminal state.

The durable claim then happens strictly before the effect, so a crash between
them is recoverable as an interrupted run rather than an invisible one.
`beginSkillExecution` remains the **only** place that decides which states may
proceed. The executor's first draft duplicated that policy, gating on
`confirmed` alone, and thereby blocked the retry the store explicitly allows
after a failure — the duplicated rule had already drifted from the one it
copied. The executor now passes any existing claim through and lets storage
answer.

Effects are ports. `SkillEffectPerforming` hides the platform entirely, so
ApplicationKit never imports EventKit, and `ReminderDraftSkill` decides what a
draft contains as a pure projection over typed arguments before any framework
is involved. Exactly one title and at most one due date; a second of either is
refused rather than resolved, because guessing which the user meant is how a
draft ends up asserting something they never confirmed.

A failure records a typed `FailureCategory` taken from the error itself through
`CategorizedFailure`; an untyped error settles as `recoverable` rather than
inventing a severity.

**Consequences:** the full path — admit, claim, perform, settle — is exercised
end to end with one reversible, no-egress skill. Delivery to the platform, the
other four skills, and the product surface remain separate. No user-visible
behavior changes yet, so there is no CHANGELOG entry.

## D295 — A skill is a contract over work the product already does (Aug 2026)

**Context:** the no-egress tier names five actions — reminder draft, recap,
meeting-package export, open a cited meeting, pre-meeting brief. Three of them
already exist as shipped capabilities with their own use cases. Writing skill
versions of that work would create a second implementation of each, free to
drift from the one the rest of the product uses.

**Decision:** a skill contributes the *contract* — declared capabilities, typed
arguments, confirmation, an idempotency key naming one intended effect, and a
durable receipt — and delegates the work. `RecapDraftEffect` calls
`RecapComposer`, `MeetingPackageExportEffect` calls `ExportMeetingBundle`, and
`PreMeetingBriefEffect` calls `PrepareMeetingBrief`. An architecture ratchet
pins those delegations so a future edit cannot quietly inline the work.

Argument projection refuses rather than resolves: a recap of two meetings is
not a recap, so two `meeting` arguments are an error instead of a choice. The
package export excludes audio, because one confirmation should not move far
more than its preview showed. The export is the only local skill declaring
`writeLocalFile`, which is irreversible and therefore permanently ineligible
for a standing rule even though it never leaves the Mac.

The idempotency key names the effect, not the subject: exporting one meeting to
two destinations is two effects, so the destination is part of the key.

**Deliberately deferred, and why.** AUTO-2 owns no user interface — the
Automation center is AUTO-6 and Shortcuts/App Intents are AUTO-3 — so:

- **Opening a cited meeting** is a navigation action needing a route that only
  those bands introduce.
- **Start/stop recording through App Intents** is AUTO-3's surface, and
  `StartRecordingIntent` already ships.
- **The EventKit reminder adapter** stays a port with no implementation.
  Delivering to Reminders needs `NSRemindersFullAccessUsageDescription` and a
  new TCC prompt, and nothing in this band can invoke it. Shipping a permission
  request with no feature behind it, plus an adapter no code path reaches, is
  worse than the port alone.

**Consequences:** four declared local skills, none able to leave the Mac,
asserted rather than assumed by `LocalSkills.isEntirelyLocal`. No user-visible
behavior changes yet — nothing can propose a skill — so there is no CHANGELOG
entry and no XCUITest applies.

## D296 — Reclaim a dead worker's lease at claim time, not only at launch (Aug 2026)

**Context:** post-capture jobs carry a 120-second lease with a 30-second
heartbeat, so a worker that dies mid-job always leaves 90–120 seconds of lease
behind. `recoverExpiredProcessingJobs` had exactly one production caller,
launch recovery, which runs immediately on relaunch — while that lease is still
valid. Nothing recovered it, `claimNextProcessingJob` selected only `pending`
rows so it saw an empty queue, and `nextScheduledProcessingDate` considered only
future `notBefore` values, so no wake was ever armed. The meeting stayed in
`processing` with a spinner for the rest of the session, and only a second
relaunch more than two minutes after the crash released it. A plain Cmd-Q or a
Sparkle update during diarization was enough to reach it — there is no
termination handler anywhere in `Sources/`.

The sibling derived-maintenance lane already solved this: `claimDerivedMaintenance`
recovers inline before selecting, and `nextScheduledDerivedMaintenanceDate`
unions `leaseExpiresAt` for running rows.

**Decision:** mirror that lane. `recoverExpiredProcessingJobs` gains a static
form callable inside an existing write, and `claimNextProcessingJob` calls it
before selecting, so the next claim by any worker reclaims abandoned work.
`nextScheduledProcessingDate` becomes the minimum of future `notBefore` values
for pending jobs and `leaseExpiresAt` for running ones, both still fenced on a
live meeting, so the supervisor arms a wake at lease expiry instead of never.

**Consequences:** an interrupted post-capture job resumes within one lease
period without a relaunch. An unexpired lease still belongs to its owner —
reclaiming remains impossible before expiry, and a reclaim is a new attempt
against the same bounded retry budget. A tombstoned meeting's lease wakes
nobody. Two deterministic tests fail against the previous implementation and
pass against this one.

## D297 — Never migrate the recordings root over a live capture (Aug 2026)

**Context:** `migrateAudio` enumerates every meeting directory under the
recordings root and, when the destination is on another volume, `moveItem`
fails and the fallback runs `copyItem` then `removeItem` — deleting the source.
Its comment justified that with "meeting dirs are immutable UUID-named
recordings", which is false for exactly one directory: the one being recorded.

Settings is a separate scene with no recording-phase gate, and its "Change…"
control is disabled only while a migration is already running, so choosing an
external volume mid-meeting was reachable. The live directory would be copied
as a snapshot and then unlinked while `RecordingSession`'s writers still held
it open; every sample after the copy point lands in an unlinked inode. At Stop,
publication fails on the vanished staging path and `reconcileEmptyCapture`
finds the truncated copy, so the user is told audio was *preserved* while an
arbitrary tail of the meeting is gone. Choosing an external volume is the main
reason to use this setting, so the destructive branch was the common one.

**Decision:** recording safety outranks the setting, so the move fails closed.
`ManageRecordingStorage` takes an optional `RecordingStorageActivity` and
throws `recordingInProgress` before any file work when capture or post-capture
is busy; `processing` counts as busy because workers still read that audio and
publication resolves paths under the current root. Inspection stays available,
so Settings can still show where recordings live during a meeting.

`migrateAudio` additionally accepts `skipping:` names it must leave in place.
That is defence in depth rather than the primary gate: a future caller that
forgets the activity check still cannot unlink a directory whose writers are
live, and the skipped meeting simply stays at the old root.

**Consequences:** the user is asked to finish the recording first instead of
silently losing its tail. A partially migrated library remains readable because
`RecordingsLocation.resolve` already falls back across roots. Tests cover the
refusal, that no file work precedes it, that inspection still works while busy,
and that a reserved directory is neither copied nor unlinked.

## D298 — A live-lane failure at Stop still raises recovery (Aug 2026)

**Context:** `LiveTranscriptionAttacher.finish()` clears `active` and only then
drains the consumer tasks, but `liveLaneFailed()` opened with
`guard active else { return }`. The engine's final flush — the likeliest place
for a transcription failure, because that is where SpeechAnalyzer finalizes and
tears down — therefore recorded nothing.

`requiresRecovery` stayed false, so `StopRecording` saw non-empty live captions
with no recovery flag, enqueued only diarization over those partial captions
instead of a full durable transcription, and committed the meeting as complete.
The tail of the conversation was permanently missing from the transcript while
the finalized CAF files still contained it. `finish()` reads `requiresRecovery`
after the drain, so the guard was the only thing preventing correct behaviour.

**Decision:** separate the two concerns the guard had merged. Recording the
failure always happens; only the live-caption UI notification is gated on
`active`, because that surface is genuinely gone once the session ends.

**Consequences:** a transcription failure during Stop now falls back to durable
re-transcription from the finalized audio, which is what the recovery flag
exists for. A test drives an engine that fails as its audio stream closes and
fails against the previous implementation.

## D299 — Inspection that could not finish keeps its channel (Aug 2026)

**Context:** `AudioSilence.fileIsSilent` promises in its own docstring to return
false when a file cannot be read, "better to transcribe a channel than to
silently drop one we failed to inspect". The failure-to-*open* path honoured
that, but a read failure part way through the file `break`ed out of the loop and
fell through to `return true`, so a file we could not finish inspecting was
reported silent and its channel dropped.

**Correction (same day).** This entry first named a crash-truncated *capture*
file as the case. That is wrong, and measurably so: `CaptureFileWriter` uses CAF
precisely because its data chunk is sized to EOF, so a killed recording's
declared length equals its readable bytes and every read succeeds. The reachable
inputs come from elsewhere — `resolveExternalRefineAudio` passes arbitrary
user-imported files, and `MeetingAudioLayout` resolves compressed `.m4a` copies
and legacy WAV — plus any read that fails because the recordings volume went
away mid-scan. The fix is unchanged; the justification was not true and is
recorded here rather than quietly rewritten.

**Decision:** only reaching the end of the file intact may conclude silence. A
read that fails short of the end returns false, exactly as an unopenable file
does; an empty read remains an ordinary end-of-file. Three tests cover a
truncated file, an unreadable path, and an audible file.

Separately, dictation's engine feed becomes `.bufferingNewest(128)`, matching
the recording lane. Its producer never suspends on the consumer, so the previous
unbounded stream let a stalled engine grow the backlog for as long as dictation
ran. Dropping the oldest audio is the trade live transcription already makes.

**Consequences:** a damaged channel is transcribed rather than discarded, and no
live audio handoff in the app is unbounded.

## D300 — Correction lane resolution indexes the history once (Aug 2026)

**Context:** `TranscriptCorrectionPolicy.correctionDomain(of:in:)` grouped the
whole correction history by id on every call, and every caller resolves the lane
of *each* active correction — twice per compose, once per Meeting Detail
snapshot. That is quadratic in a meeting's correction count. Measured on 8 000
segments with 4 000 corrections: **p95 12 749 ms**, on the interactive path.

**Decision:** `TranscriptCorrectionDomainIndex` indexes one history once and
answers per-event lookups. Per-event semantics are unchanged, including which
event id a duplicate reports — the duplicate check is deferred to the query so
the refusal still names the event that was asked about, rather than an arbitrary
event discovered while indexing. `correctionDomain(of:in:)` remains, implemented
on top of the index, for the single-event callers.

Same fixture after: **p95 185 ms**, a 69× reduction, and
`testDenseCorrectionHistoryStaysWithinTheCompositionBudget` now guards it.

**Consequences:** a heavily corrected meeting stays interactive. Composition
cost is now dominated by the segments, not by the correction history.

## D301 — A skill's destination travels in the proposal (Aug 2026)

**Context:** `MeetingPackageExportSkill.idempotencyKey(for:destination:)`
scopes an export by its destination, but the effect never read one — the writer
resolved a path of its own. The key could therefore distinguish two writes the
effect could not, so one confirmation authorised a path the user never saw in
the preview it confirmed.

**Decision:** the destination is a typed argument of the proposal. The effect
projects it with the same "exactly one, validated" rule the meeting subject
uses, and `MeetingPackageWriting.write(_:for:to:)` receives it. Key and effect
now derive the destination from one place. `PreMeetingBriefSkill` gains the
matching `event(from:)` projection, so no effect reads raw arguments any more.

**Consequences:** what the receipt says was written, and where, is what
happened. Both previously untested effects now have behavioural tests, including
that a failed export leaves nothing written.

## D302 — Playback ordering is judged on the ticks AVFoundation receives (Aug 2026)

**Context:** D287 made the clear-playback schedule fail closed on an out-of-
order or empty volume ramp, because AVFoundation raises an uncatchable ObjC
exception instead of returning an error. The check ran on `TimeInterval`
seconds, but the schedule is delivered as `CMTime` at timescale 600. Two events
ordered by microseconds are one instant at 1/600 s, so a ramp proven non-empty
in seconds could still reach AVFoundation empty — the exact crash D287 closed,
through the gap the check did not cover.

**Decision:** the timescale belongs to the policy. `CleanPlaybackPolicy.tick`
quantizes, `isStrictlyOrdered` compares ticks, and the composition builds
`CMTime` from that same tick. `audibleRanges` refuses a bound that has no tick
at all — a non-finite or astronomically large time would make the ordering check
reject the whole schedule and silence clear playback for the entire meeting.

**Correction (same day).** This entry first claimed the sub-tick *length* check
was what stopped the schedule failing. Measured, that is false: keeping a
sub-tick range still passes `isStrictlyOrdered`, because both ramp emissions are
already tick-guarded and `.level` events have no non-emptiness requirement. The
length check is tidiness — such a turn raises and lowers the microphone at the
same instant, so its instructions do nothing. The representable check is the
crash guard. The code is unchanged; the stated reason was wrong.

**Consequences:** what is validated is exactly what AVFoundation receives.

## D303 — The live turn timeline is the session's, not the consumer's (Aug 2026)

**Context:** `PyannoteDiarizer.diarize` positioned each window by counting the
windows it had consumed, starting at zero. Live diarization attaches only once
system levels arrive and the runtime is acquired — after capture has begun — and
reads an `AsyncStream` with `.bufferingNewest(128)`, which drops audio under
back-pressure. Every live turn was therefore placed earlier than it happened,
drifting further with each drop, and the live speaker labels drifted against the
caption timeline they relabel.

**Decision:** windows are anchored to `AudioChunk.timestamp`, the session clock
the capture layer already stamps (and already pads across output-switch gaps).
A chunk that does not continue where the held buffer ends releases that buffer
as its own window instead of splicing a jump cut into one window. The logic
lives in `DiarizationWindowCutter` — pure and synchronous, so the timeline is
tested without the model.

The gap that triggers a re-anchor is measured between chunk timestamps, never
against how many *resampled* samples are held: the resampler's output count is
not an exact function of elapsed time, and measuring against the buffer would
accumulate its rounding until a contiguous stream read as a drop.

**Consequences:** live labels stay aligned with the captions regardless of when
the consumer attached or what the stream dropped.

## D304 — A failed recordings migration puts back what it moved (Aug 2026)

**Context:** `migrateAudio` moves meeting directories one at a time and the
caller only persists the new root once it returns. A throw part way through left
recordings under the destination while the root still pointed at the origin —
and `RecordingsLocation.resolve` only ever looks at the current and default
roots, so those recordings were reachable from neither.

**Decision:** a failure restores every directory that run moved, so a thrown
error really does mean nothing happened. The failing entry's hidden
`.partial-<name>` cross-volume temp is removed too — it is a complete copy of
that meeting's audio, and a later resume could not tell it from a finished
directory. Restoration puts the destination copy back *over* an existing source rather
than deleting it: the resume branch drops its source with `try?`, so a source
that is present may be a partial leftover, and trusting it would destroy audio.

**Correction (same day).** The first attempt used `FileManager.replaceItemAt`,
which fails this job twice and was caught by an adversarial pass that
reproduced both on a mounted volume. It cannot cross volumes at all (EXDEV) —
and crossing volumes is the only reason the migration has a copy path — so on
an external drive it stranded every directory it was meant to restore. On one
volume it can also throw *after* it has already swapped: the good copy lands
correctly, the old contents are left at the destination's **real** name, and
the caller is told the entry was stranded. A later resume then reads that name
as a finished migration and drops the restored source, destroying the audio.

`putBack` replaces it: the existing origin is renamed aside to a hidden
`.superseded-<name>` **inside the source folder** — a rename needs no
permission to delete children, and `contentsOfDirectory` skips hidden entries,
so no later migration can mistake it for a meeting — then `moveItem` brings the
copy back, which does cross volumes. A failed move puts the origin back, so a
restore that cannot finish leaves it no worse. Both failure shapes now have
tests; the cross-volume one mounts a scratch disk image and skips where it
cannot.

When a restore itself fails, the error becomes
`RecordingsMigrationError.stranded`, carrying a count and the folder — enough to
find them, without naming meetings in an error message. The app adapter
translates it into `ManageRecordingStorageError.recordingsStranded` so
presentation reads an ApplicationKit error, and Settings gives it its own
message: every other migration failure is a true no-op, and the existing
"Nothing was lost" text is precisely what this case is not.

**Consequences:** a failed migration is a no-op, or it says precisely what it
could not undo — and never silently tells the user nothing was lost when
recordings really are in another folder.

## D305 — Library observation regions are column-scoped (Aug 2026)

**Context:** `observeLibraryMeetings` and `observeLibrarySearch` tracked
`Table("segment")` as a whole. The semantic backfill writes `embedding` and
`embeddingFingerprint` on `segment` in batches, so every batch commit re-fetched
the entire library, recomputed every voice mix, and re-ran any active full-text
query. The more of the library was being indexed, the more often it happened.

**Decision:** both observations track only the `segment` columns their queries
read — `librarySegmentRegion` and `searchSegmentRegion`. GRDB narrows the region
to those columns, so an embedding write no longer intersects either, while any
change to what the projections actually show still does. An architecture ratchet
refuses a whole-table `segment` region in that file.

**Consequences:** indexing is invisible to the library, and search results stay
exactly as fresh as before.

## D306 — A release gate never asserts a model's exact words (Aug 2026)

**Context:** `testCommandPaletteSearchAnswerAndCitationSurviveNoStaleState`
asserted that a specific Spanish sentence appeared after Enter. That sentence is
`RAGAnswerer` output — an on-device Foundation Models session. When the model is
unavailable or throttled, `AskMeetings` honestly falls back to "Closest passages
from your meetings:" with the same citations, and the gate failed. Measured on a
quiet machine: **3 of 6 runs failed**, none of them a regression.

**Decision:** the test asserts the property it is named for instead. The
`palette-answer` element renders only from `state.answer`, which nothing but
`submit()` sets, so its presence *is* the proof that Enter ran the full Ask
workflow rather than reusing the instant FTS hits — and the citation still
proves the receipt reaches the exact second. Same strength for the stated
property, no dependency on a model. 6 of 6 runs pass after the change.

No UI gate may assert generated text. A model's availability is not a property
of this repository, and a gate that fails for it teaches the team to ignore red.

**Consequences:** the bilingual gate means what it says again.

## D307 — A palette query that did not change cannot cancel its own answer (Aug 2026)

**Context:** `CommandPaletteModel.updateQuery` bumped the generation and
cancelled the in-flight answer on *every* binding update, including one whose
text was unchanged. SwiftUI delivers such updates — coalesced typing, an IME
commit, a re-render with the same value — and after `onSubmit` that left the
palette showing hits, no answer, and nothing to restart it.

**Decision:** an update whose text equals the current query returns early.
`answer` also clears `isAnswering` for its own generation in a `defer`, so a
future cancel that forgets to bump the generation cannot leave the flag set and
make `submit` refuse every later Enter. That second part is defence in depth and
is documented as such: removing it leaves every palette test green, so it is
unreachable today rather than a fix for a live defect.

**Consequences:** Enter always produces an answer or an honest failure.

## D308 — Decision↔topic aboutness is explicit authority, never co-occurrence (Aug 2026)

**Context:** the three remaining memory-graph jobs — decisionHistory,
decisionConflicts, changeSince — all answer a question about a *subject*, and no
decision↔topic edge existed. The cheap route, joining
`topic → meeting → decision`, returns every decision taken in any meeting where
the topic was mentioned: proximity dressed up as aboutness, exactly the failure
the corpus distractors exist to catch, and exactly what D270/D271 forbid the
graph to invent.

**Decision:** schema v32 adds the authority, modelled on the existing
continuity shapes. `decisionTopicLink` carries `confirmed`/`retracted` with a
partial-unique "one active link per pair" (a mis-click retraction must not
poison the pair forever); `decisionTopicLinkSource` is immutable and copies the
exact summary/meeting origin, observed statement, topic label, and
`sourceTranscriptRevision` — no foreign keys, so purge cannot erase why the
user linked; `decisionTopicLinkEvent` is append-only with one confirm and at
most one retract.

The structural rule sits in the v32 confirm trigger, not only in Swift: a
confirm event is legal only over a source whose observation the decision
*itself already owns* as evidence (`decisionContinuitySource` for the same
decision). Nothing that merely co-occurred in a meeting can satisfy that, from
any code path, present or future.

The disposable `meetingMemoryGraphDecisionTopic` edge derives from confirmed
live links alone, targets the topic family's current root (a merge changes
traversal without rewriting authority), and is rebuilt under both the decision
and topic scopes. Mutation-tested: rewriting either rebuild site to
co-occurrence fails the acceptance test, including in an incremental
decision-only rebuild where the topic scope cannot mask it, and removing the
trigger's ownership clause fails the direct-SQL test.

`ConfirmDecisionTopicLink`, `RetractDecisionTopicLink`, and
`LoadDecisionTopicLinks` are the only commands; semantic retrieval may suggest,
never execute. No UI surface exists yet — the confirmation gesture ships with
the adapter slice that consumes it.

**Consequences:** GRAPH-5b's three adapters can now be honest: "about
`atlas-001`" always resolves through user-confirmed authority with exact source
evidence, and a rebuild from nothing reproduces the same edges.

## D309 — decisionConflicts and changeSince answer from the aboutness authority (Aug 2026)

**Context:** with D308's decision↔topic authority in place, two of the three
remaining memory-graph jobs could become honest. Both ask about a *subject* —
"which decisions about `atlas-001` conflict?", "what changed about it since the
last meeting?" — and both are the same underlying relationship: one confirmed
decision explicitly superseding or reversing another.

**Decision:** one shared adapter serves both jobs. Candidates come only from
`decisionTopicLink` (family-resolved, confirmed, live); the projection edge is
cross-checked and a missing edge abstains as `projectionInconsistent` rather
than being silently repaired; every returned fact is rehydrated from decision
continuity with the exact current source segments of *both* decisions, replaced
first, successor second. A relationship where either side is about the topic is
relevant to it.

`decisionConflicts` is the unanchored reading. `changeSince` resolves one exact
anchor meeting *before topology is consulted* — an unknown or deleted baseline
abstains as `missingTemporalBaseline`, mirroring the canonical corpus's rule
that "since when" is never guessed — and then keeps only relationships whose
event occurred after the anchor ended. Decisions about the topic with no
confirmed relationship abstain as `unsupportedConflict`: a generated note that
"guessed" a replacement was never confirmed, so it does not exist as authority
and needs no exclusion logic.

Mutation-tested: ignoring the anchor fails the boundary test, and rewriting
candidate selection to meeting co-occurrence fails against a fixture that keeps
a fully confirmed, co-occurring, *unlinked* decision pair in the same meetings —
the discriminator proximity cannot pass.

**Consequences:** five of the six D270 jobs now answer from source-backed
authority. `decisionHistory` remains open, and the decision-topic confirmation
gesture still has no UI surface; both ship together as the band's next slice.

## D310 — decisionHistory answers only with current confirmed truth (Aug 2026)

**Context:** the last of the six D270 jobs. "What did we decide about X" must
return the decision that stands — the superseded one and a decision about a
different subject are exactly the corpus's forbidden results, and a generated
observation that nobody confirmed cannot answer at all.

**Decision:** `DecisionHistoryQuery` serves current confirmed decisions linked
to the topic family through the D308 authority. A superseded decision keeps its
link — decisionConflicts serves it — but its projected status excludes it here;
the exclusion is mutation-tested. The returned fact stands on the authority row
itself (`decisionAboutness(linkID)`), and abstains
`insufficientConfirmedDecision` when the topic has no current confirmed
decision, matching the canonical corpus reason name exactly as every other job
does. All 6 canonical cases traverse public product boundaries, with the
distractor decision linked to *its own* subject's topic — as an honest user
would leave it — and still excluded.

**Consequences:** all six D270 jobs now answer from source-backed authority.
GRAPH-6 is unblocked once the confirmation gesture ships.

## D311 — The decision confirmation gesture composes both authorities (Aug 2026)

**Context:** decision continuity (D270-band) and the decision-topic authority
(D308) were store-complete with no production caller — no released surface ever
confirmed a decision. The graph jobs those authorities feed were tested against
seeded truth only.

**Decision:** the Decisions tab offers one explicit gesture per generated
decision bullet: **Confirm…**, rendered only over current, resolvable evidence.
The sheet quotes the exact statement and takes an optional topic; on confirm,
`ConfirmDecisionAboutTopic` composes `ConfirmObservedDecision` and — when a
topic was named — `ConfirmDecisionTopicLink`. A typed label with exactly one
existing alias match links to that topic; no match creates one grounded on the
decision's own evidence segment; an ambiguous label refuses rather than
guessing identity, and the decision stays confirmed so the user can retry the
link. Re-running the gesture on a confirmed observation reuses the decision, so
a topic can be added later. The durable state renders as a badge naming the
topics, with an explicit accessibility label so the state is announced whole.

**Consequences:** the six graph jobs now have a real production writer behind
them. Retraction UI and a dedicated review surface remain open, recorded in the
roadmap rather than implied.

## D312 — GRAPH-6: relational storage meets the product queries (Aug 2026)

**Context:** band 7's exit gate had to prove the relational projection serves
the longitudinal product queries at scale, or produce the ADR for a graph
engine. The harness seeds a deterministic synthetic corpus — dense repeated
topics, merged-topic families, same-name canonical people, per-topic
supersession chains — through the same public confirmation paths the product
uses, projects through the real maintenance path, and measures every one of the
six D270 jobs.

**Measured (in-memory store, Apple Silicon; 30 samples per lane; evidence in
`docs/evidence/meeting-memory-graph-scale-20260807.json`):** at 10k meetings /
1k topic families / 10k confirmed decisions and commitments, every job answers
between 2.3 ms and 76.1 ms p95 against the 250 ms interactive budget — worst
lane firstDiscussion at 76.1 ms, over 3× headroom. Recursive-CTE probes for
topic-family roots (10k topics with merges) and supersession chains stay under
6 ms, so recursive read models are not a blocker either. Disk 119 MB; physical
footprint delta under 6 MB.

**Decision:** the specialized-graph-engine gate stays closed. SQLite remains
authoritative, the projection remains disposable, and no ADR is needed.

Two findings are recorded rather than smoothed over. Full rebuild-from-zero
projection is superlinear — 414 edges/s at 1k falling to 48.9 at 10k
(17.6 minutes) because per-scope rebuilds load every live topic row to resolve
family roots; the normal incremental path touches few scopes, and the job is
checkpointed, resumable, and capture-yielding by design, so this is a GAPS
throughput item, not a gate failure. And returning to the canonical profile
after an alternate one at the same source generation is refused by operation
idempotency — reachable only via binary downgrade, also in GAPS.

The always-on invariants run on every push at small scale: no edge without
provenance across all seven projection tables, correction-awareness (rewriting
the transcript under the current decision's evidence abstains stale while an
untouched subject answers), and rebuild determinism proven through a full
profile reset comparing raw authority-keyed edge sets.

**Consequences:** band 7 is code-complete. What remains for the band is UI
(link retraction) and field validation, not storage design.

## D313 — Corrected text reaches search through a per-segment projection; MCP appends portavoz-reading/2 (Aug 2026)

**Context:** correction composition was complete (D225, D229–D235) but a
corrected word made its line unfindable: any active correction removed the
segment from FTS and semantic serving, MCP reads stayed accepted-only, and the
originally designed fix — materializing composed rows into a correction-local
index — was proven unsound under adversarial review. `segmentID` is the
citation identity of the whole stack (RRF fusion deduplicates by it, Library
selection resolves by it, commitment-link evidence throws on duplicates), and
composed rows are not 1:1 with segments: a split mints N rows from one
segment, a merge collapses several. Synchronous recomposition inside the
write transaction was also impossible — `ComposeTranscript` lives in
ApplicationKit, which StorageKit must not import.

**Decision:** serve corrected text only where it is 1:1 with a segment.

1. **`segmentCorrectedText` (v33)** holds at most one row per segment — the
   active `replaceText` correction's text — with an FTS5 mirror maintained by
   the same GRDB trigger mechanism as v1's `segmentSearch`. The projection is
   disposable and rebuilt transactionally by every path that changes
   correction state or the accepted revision (append, tombstone, replica
   merge, sync replay, refine, re-transcription), plus a v33 backfill so
   upgraded libraries find their corrected text immediately. Active-ness is
   resolved by `SegmentCorrectedTextProjection` over
   `TranscriptCorrectionPolicy.effectiveCorrections` — one shared answer to
   "which corrections count", not a second one.
2. **The search lane gets its own predicate.**
   `acceptedSegmentHasNoActiveTextAffectingCorrectionSQL` excludes only
   corrections that change what text exists (`replaceText`, `split`, `merge`,
   `suppress`). An active `changeSpeaker` no longer hides its line from
   search — that was a bug, since neither the text nor its embedding changed.
   Evidence and continuity lanes keep the stricter any-correction predicate:
   a speaker correction does change who said it, which those lanes cite.
3. **Search unions the two lanes.** Accepted-text hits and corrected-text
   hits merge under one bm25 ordering; a segment can never serve from both
   because the projection row exists exactly when the predicate excludes the
   accepted text. Citation identity stays the accepted `segmentID`, so Ask
   fusion, Library selection, and evidence linking are untouched.
4. **MCP appends, never mutates.** The six existing tools are frozen — same
   names, order, accepted-only text, clamps, and error strings — and three
   tools are appended under the `portavoz-reading/2` contract:
   `get_transcript_v2` (composed reading, on-demand `ComposeTranscript`, row
   pagination), `get_summary_v2` and `get_action_items_v2` (accepted reading
   with correction provenance). Every v2 response opens with one content-free
   header line — `portavoz-reading/2 meeting=<uuid> base=<n>
   correction=<accepted|16-hex|unavailable> reading=<composed|accepted>
   composed=<current|pending>` — and fails closed: corrected text serves only
   when the full composition succeeds against the current revision; anything
   else downgrades to the accepted reading and says so.

**Deliberately excluded:** split/merge/suppress content stays out of search
(their rows have no 1:1 segment identity); semantic search still serves no
text-replaced segment (its stored embedding describes the original text);
Spotlight stays correction-unaware; Apuntador regeneration policy remains
deferred until source/evidence semantics are characterized. All four are
recorded in GAPS, not silently absorbed.

**Consequences:** fixing one word makes the line findable by its corrected
text and unfindable by the stale one, with search, Ask, Library, and MCP all
converging on the same segment identity. Existing MCP consumers observe no
change unless they opt into the appended tools.

## D314 — Graph rebuild resolves topic families in SQL, not by loading the table (Aug 2026)

**Context:** the GRAPH-6 verdict (D312) recorded one known cost honestly
instead of smoothing it: rebuild-from-zero was superlinear because every
topic/decision scope called `liveTopicRecords` — a full fetch of all live
topics — to resolve merge-family roots, making a full reset roughly
scopes × topics row loads (414 edges/s at 1k collapsing to 48.9 at 10k;
17.6 minutes for a complete rebuild).

**Decision:** family resolution moves into two recursive CTEs that stay
O(family) per scope. `topicFamilyRootID` walks one redirect chain upward with
the same failure semantics as the in-memory `topicRoot` walk — a redirect
cycle (bounded by an explicit depth cap) and a redirect into a tombstoned or
missing topic both throw; a missing starting topic returns nil. One deliberate
narrowing: broken chains in *other* families are no longer visited, so they
fail their own scope instead of every scope. `topicFamilyMemberIDs` walks
downward with `UNION` recursion so a corrupt cycle terminates. The three graph
rebuild scopes use these helpers; query-lane call sites keep their measured,
budget-passing shape and are deliberately untouched.

**Measured (same in-memory harness and fixture as D312; evidence in
`docs/evidence/meeting-memory-graph-rebuild-20260807.json`):** 2 766 edges/s
at 1k and 1 892.9 edges/s at 10k — 27.2 s for the full 10k rebuild, 38.7×
the baseline and near-linear across the decade. Conformance, projection
checkpoint/resume, and the always-on scale invariants (including rebuild
determinism via raw edge-set comparison) all pass unchanged.

**Consequences:** the D312 GAPS throughput item is resolved; a full
profile-fingerprint reset at 10k meetings costs under half a minute inside
the existing checkpointed, capture-yielding maintenance job.

## D315 — The Ask answer judge is deterministic, content-free, and says what it cannot see (Aug 2026)

**Context:** SEARCH-0b's honest-quality boundary (D192–D196) judges retrieval
but left answers explicitly unevaluated — nothing could say whether the
generated answer respected the abstention policy or grounded its citations,
and Q7's chunking comparison needs exactly that judge.

**Decision:** `scripts/ask_answer_quality.py` adds a separately versioned
answer judge (answer schema 1, its own observation and scorecard kinds; the
retrieval schema is untouched). The observation contract is content-free:
per fixture query it carries only the outcome (`answered`/`abstained`), the
cited segment identities, and a character count — answer text is a forbidden
key, so the same contract serves the public synthetic fixture and a future
private anonymized pack. Validation fails closed: every fixture query judged
exactly once, no unknown or duplicate citation, an abstention must be
evidence-free, and an answer without a single citation (or with an empty
artifact) is inadmissible rather than low-scoring. The judge scores
`answerOutcomeAccuracy`, `citationPrecision`, `evidenceRecall`,
`falseAnswerCount`, `missedAnswerCount`, and `hardNegativeCitationCount`
(the hallucination surrogate), with optional explicit floors.

**Deliberate limit, stated instead of hidden:** every scorecard carries
`"proseQuality": "notEvaluated"`. A deterministic judge verifies grounding
and policy, not eloquence; a semantic quality judge would need a model and
remains a separate, unmade decision.

**Consequences:** collecting answer observations from the product adapter and
the private pack (the remaining Q6 items) now has a fixed, fail-closed
contract to land on, and chunking comparisons (Q7) can include answer
grounding without inventing a metric per run.

## D316 — Skill proposals surface beside their meeting, and dismissal is durable (Aug 2026)

**Context:** the no-egress skill tier (D292–D295, D301) was complete but
unreachable — no user could run a skill. The obvious wiring was refuted
before building: routing the existing manual flows (recap sheet, export
panel) through `ExecuteSkill` would receipt artifacts the user did not send,
because the manual surfaces allow edits that never travel in the typed
arguments. The skills tier's differentiator is the PROPOSAL motion, so the
proposal needed its own surface.

**Decision:** phase 1 anchors proposals to their subject. A badged offers
menu beside Meeting Detail's document actions proposes the meeting-scoped
skills — recap draft and text-only package export — once the meeting has a
summary. Each offer opens the confirmation sheet, which shows the EXACT artifact (the composed recap
verbatim; the meeting title and chosen destination for export) plus the
declared capabilities, and confirming runs the durable execution machinery:
claim before effect, one auditable receipt per intent, failure categories
typed. Receipts render in the meeting's trust rail beside the privacy
receipt. The export destination is resolved by the native save panel BEFORE
the proposal exists, so the confirmed proposal never resolves a path behind
the user's back; recap delivery is the pasteboard — exactly what the manual
sheet's Copy does, and the user still sends it themselves.

The exact-preview contract crosses confirmation as an immutable snapshot, not
as permission to re-read the meeting later. Confirmation re-composes current
durable material and compares it with the sheet's preview before any claim; a
changed meeting requires a fresh preview. The accepted material snapshot then
feeds the effect, so a second store read cannot change the copied draft.
Pasteboard rejection is a typed failed effect, not a successful receipt.
Cancellation remains available only before the durable begin/handoff: the
executor records that no-effect terminal state, while the sheet disables both
cancel and interactive dismissal once execution is running.

Dismissal became durable state (schema v34, `skillOfferDismissal`): the AUTO
contract makes `dismissed` terminal from `proposed`, but the execution tables
only begin at confirmation. The offer key is the stable intent identity
(skill + meeting), deliberately not the random per-render proposal ID, so a
regenerated banner can never resurrect a declined offer. A succeeded recap
retires its offer (the draft exists; re-drafting is the manual sheet's job);
export keeps offering because each destination is a distinct intended
effect; a failed run keeps offering because retry is legitimate.

**Two presentation lessons recorded for the next surface.** A ViewBuilder
branch that renders nothing is never installed, so a load trigger attached
to the offers view could never fire before the first offers arrive — the
empty state renders a hidden 1×1 anchor so the tree keeps a node to hang
the trigger on. And Meeting Detail tolerates NO persistent vertical
insertion: a banner inside the height-ratcheted artifacts viewport pushed
the document's own controls out of the box (seven gates failed), a banner
above it displaced the sections below (four more) — exactly what those
gates exist to catch — so the proposals took a zero-height slot in the
actions row instead.

**Deliberately excluded from phase 1:** the reminder-draft skill's UI (its
delivery adapter needs EventKit and a permission moment of its own), the
pre-meeting brief (its subject is a calendar event, not a past meeting), a
Skills management pane (phase 2, when egress skills need consent and
standing-rule management), and any menu-bar moment (phase 3; its
verification cost is documented in the roadmap).

**Consequences:** a user can now run a skill end to end — proposal, exact
preview, explicit confirmation, durable receipt — with nothing leaving the
Mac, and the phase-2 pane will be born with real receipts in it.

## D317 — Skills controls are durable execution authority, not preferences (Aug 2026)

**Context:** phase 1 made two local skills reachable and left durable receipts,
but there was no central place to understand or stop them. A Settings-only
`UserDefaults` switch would let the app, CLI, and future process surfaces
disagree. A pane listing all four declared contracts as runnable would also be
dishonest: reminder delivery and the event-scoped brief surface have not
shipped. Finally, a switch evaluated only when a proposal is rendered cannot
revoke an already-open confirmation sheet.

**Decision:** `LocalSkillCatalogue` is the central ApplicationKit projection.
It marks recap draft and text-only package export `available`, and reminder
draft plus pre-meeting brief `planned`. Schema v35 stores content-free policy
beside execution authority: singleton `skillControl` owns global pause and
sparse `skillDisablement` rows own individual choices. Missing disablement
means enabled; global pause is an independent override and never rewrites the
sparse set. Missing or corrupt singleton state fails closed.

Meeting offer loading consults this policy before presenting proposals.
`ExecuteSkill` independently reads it again immediately before admission and
before the durable claim, so an old pane snapshot or open confirmation sheet
cannot authorize an effect. The Settings pane writes through
`ManageSkillControl`, which accepts only known, available catalogue entries.
It projects 20 recent content-free receipts by default; application requests
are clamped to 50, storage refuses more than 100, and SQLite serves
`updatedAt DESC, proposalID ASC` through a direction-matched index. Malformed
persisted receipt identities fail the read instead of disappearing.

Egress consent and standing-rule controls remain absent until a real egress
adapter exists. Irreversible package export keeps explicit confirmation per
destination. Planned entries are labels, not disabled switches that imply an
implementation.

**Consequences:** the management pane, proposal surface, and final execution
gate share one durable authority across processes; pause is reversible without
forgetting individual choices; receipt cost stays bounded as history grows;
and Phase 2 does not over-promise reminder, brief, or network automation.

## D318 — Map only local-internal Portavoz databases for exact semantic reads (Aug 2026)

**Context:** the authoritative 8 Aug release ledger measured the exact
100,000-vector scan at 139.64 ms wall / 141.98 ms CPU p95 against a 100 ms
budget. Reproduction on the current clean parent produced two stable misses at
128.16/129.30 ms and 126.44/127.29 ms. A Release CPU sample located the work:
5,535 of 6,330 search frames were inside `sqlite3_step`, 2,997 samples ended in
`pread`, and only 117 ended in Accelerate's dot product. Ranking, bounded top-k,
and winner hydration were not the first bottleneck; SQLite was copying the same
large sequential BLOB pages through its private page cache on every query.

**Decision:** keep `AccelerateExactSemanticIndex`, the normalized Float32 BLOB
schema, one-cursor multi-query scan, correction fences, and authoritative
hydration unchanged. A file-backed macOS `MeetingStore` configures only
`main.mmap_size` to a hard application cap of 512 MiB when Foundation reports
that the symlink-resolved database directory belongs to a local, internal
volume. SQLite may clamp or ignore the advisory request and uses ordinary reads
beyond it. The mapping is read-only, virtual, file-backed, and demand-paged; it
is not an eager 512 MiB heap allocation. In-memory stores, other platforms, and
non-local, removable, or unclassified volumes retain the default `xRead` path.

This is deliberately narrower than enabling mmap for arbitrary SQLite files.
SQLite documents that an underlying I/O fault on a mapped page becomes a
process signal instead of a recoverable database error. The shipped database
is one app-owned file under internal Application Support, with no selectable
external location or second process writer; the volume guard excludes the
known network/removable cache-consistency hazards. Any future external library
location, attached authority database, or multi-process writer must revisit
this decision. The residual local-media I/O-signal risk remains explicit rather
than being misreported as eliminated.

**Consequences:** three independently seeded 20-query Release runs at
100,000 × 512 dimensions measured wall p95 67.25/63.98/63.49 ms and CPU p95
68.07/64.90/64.30 ms, with 9.22–9.47 MiB baseline process footprint and
0.16–0.19 MiB incremental p95. The canonical 9 Aug release ledger then measured
63.53/64.54 ms wall/CPU p95 and 0.17 MiB incremental footprint on the same
Tahoe reference host while every other measured journey remained within its
budget. Two file-store characterizations assert the effective bound and exact
ranking/similarity parity across close/reopen, while a third ratchets symlink
resolution before volume classification. No schema migration, candidate engine,
resident vector cache, ranking change, or new product writer is introduced;
multi-host Sequoia/Tahoe evidence remains an independent acceptance gate.

## D319 — Database launch failure is a recoverable root state, never a partial app (Aug 2026)

**Context:** `AppServices.init` terminated the process with `fatalError` when
the authoritative meeting database could not open. That prevented a misleading
half-functional Library, but corruption, permissions, unavailable storage, or
a failed migration also gave the user no safe way to retry, retain evidence,
or produce support diagnostics. Constructing service owners before attempting
the store would make a retry path equally unsafe: a failed launch could install
global telemetry or start model, sync, scheduler, and hot-key state without its
authority.

**Decision:** `AppServices` is throwing and opens `MeetingStore` before it
constructs any other process service. The SwiftUI root owns one observable
`AppLaunchModel` with exactly three states: opening, one complete ready service
graph, or database unavailable. Only the ready transition can install the
AppKit delegate destination and start benchmark owners, pressure monitoring,
search reconciliation, reminders, sync, backup recovery, capture/job recovery,
provider discovery, or dictation registrations; activation is idempotent.
Retry replaces the failed state with a newly attempted complete graph. A native
App Intent that arrived while the database was unavailable stays buffered and
is re-notified, not consumed, after readiness.

The unavailable state exposes three bounded actions. Retry performs no repair.
Recovery copy reads the failed authority and its committed WAL into a hidden
private snapshot inside the user-selected destination, opens only that snapshot
read-only, uses SQLite online backup, requires
`PRAGMA quick_check == ok`, applies mode `0700`/`0600`, and publishes by a
same-directory rename to a unique visible folder. It never overwrites, migrates,
renames, deletes, or writes the source; a failed operation removes only its
hidden stage. If the authority or WAL size/modification evidence changes while
the private snapshot is copied, publication fails instead of claiming a
coherent recovery point. Launch diagnostics are content-free JSON: app/build, numeric OS,
typed failure authority/category/code, and source-file presence/size. They
contain no path, raw SQLite message, SQL, transcript, title, identifier, or
other library content. Diagnostics are first written to a hidden mode-`0600`
sibling and only then atomically published, so no permissive file exists if
permission hardening fails.

The deterministic failure switch and injectable database path are accepted
only together with `-use-temp-store`. XCUITest first materializes a valid
disposable SQLite authority, then fails before service composition so the real
read-only copy and diagnostics journey is exercised without touching the host
library. Normal process environment cannot redirect the production database.
The surface uses standard SwiftUI/AppKit APIs available from the macOS 14.4
deployment floor; it does not adopt a Tahoe-only presentation API.

**Deliberately excluded:** Portavoz does not infer corruption repair, restore a
copy over the authority, auto-delete, silently recreate an empty production
library, export raw errors, or present the normal app with disabled controls.
Choosing which retained copy to restore remains an explicit future workflow;
support can inspect the bounded diagnostic without receiving meeting content.

**Consequences:** a database-open failure now leaves Portavoz running in one
focused bilingual recovery surface with the original library unchanged.
Unit tests prove source-byte preservation, restored meeting parity, private
permissions, non-overwrite, corrupt-input cleanup, content-free diagnostics,
stable retry identity, and complete-graph retry. One bilingual real-app
XCUITest proves the process remains alive, normal Library controls remain
absent, copy and diagnostics succeed, the source is unchanged, and a repeated
failure returns to recovery.

## D320 — First Listen owns microphone and SpeechAnalyzer work as one cancellable session (Aug 2026)

**Context:** Tahoe onboarding starts Apple's SpeechAnalyzer before Portavoz's
downloaded speech models exist. The engine created an unstructured input feeder:
cancelling or failing the result consumer finished its output but could leave
that feeder reading a still-open audio stream and retaining the analyzer.
First Listen also opened the microphone before awaiting Apple's optional speech
asset, so a cold wait accumulated chunks in an unconsumed default stream. Its
cleanup used an unawaited task, and moving from the first step did not cancel it
because the root onboarding view itself remained mounted.

**Decision:** `SpeechAnalyzerEngine` gives its input feeder lexical ownership
inside one throwing task-group scope. Normal result completion, result failure,
and parent cancellation cancel and drain that child before the output job ends;
the AnalyzerInput continuation always finishes. One actor gate invokes
`cancelAndFinishNow()` at most once and is triggered early enough to unblock a
feeder that is finalizing. Empty chunks fail admission before buffer creation,
and the PCM copy has no forced optional address.

`FirstListenController` resolves caption readiness before it acquires the
microphone. One injected capture boundary and one session identity own capture,
caption delivery, teardown, and presentation publication. Continue, Skip,
dismissal, explicit cancellation, or a newer run invalidate that identity,
cancel the caption consumer, and await capture plus analyzer cleanup. A stale
run cannot publish completion or failure into the current onboarding state.
Sequoia retains the same capture lifecycle with captions unavailable; the
SpeechAnalyzer branch remains availability-gated to macOS 26.

**Consequences:** cold Tahoe preparation has no hidden microphone backlog,
leaving First Listen stops listening, and consumer cancellation cannot retain a
SpeechAnalyzer feeder. Twelve deterministic unit cases cover readiness ordering,
cancel-before-capture, cancellation while awaiting captions, exactly-once
capture teardown, available/unavailable caption outcomes, internal cancellation
recovery, partial-sample disposal, completed-sample reuse, stale-phase exclusion,
and structured feeder completion/error/cancellation plus coalesced cleanup
completion. The existing
bilingual Onboarding XCUITest remains the real-app navigation gate; microphone
and Apple asset behavior still require real-device field evidence rather than a
CI simulation.

## D321 — A Skill retry resumes its original durable proposal (Aug 2026)

**Context:** storage gives one proposal exclusive ownership of an idempotency
key. Meeting Detail previously created the proposal only when the user pressed
Confirm, so a recoverable effect failure left its durable claim under one UUID
while the next press manufactured another. Storage correctly rejected that
second UUID as a competing claim. The confirmation sheet and failure state
therefore promised a retry that the application could not execute.

**Decision:** Meeting Detail allocates the proposal UUID with the exact preview
and carries it through the coordinator, model, app client, and proposal factory
for every Confirm press. The effect key remains the durable identity of the
intended action and can never transfer to another proposal. If SwiftUI
reconstructs the presentation after an attempt, an exact StorageKit lookup by
that key returns its original owner and the app reattaches to that UUID.

Preview revalidation still happens before claim lookup or execution. The
existing executor remains the only authority that distinguishes a failed
attempt, which may increment and retry, from a succeeded, dismissed, or
interrupted attempt, which must not repeat. Recap delivery is process-owned so
an adapter's retry state survives presentation work. A disposable-store-only
XCUITest adapter rejects its first pasteboard handoff and delegates the second
to the real system pasteboard; production construction cannot select it. The
sheet renders the recoverable reason beside the retry control rather than only
behind the modal presentation.

**Consequences:** a failed recap advances the original attempt and delivers the
same artifact the user approved. A fresh competing proposal is still rejected,
and an already succeeded or potentially interrupted effect is never repeated.
Unit tests cover identity routing, proposal construction, and exact durable
owner lookup; the real app's English and Spanish XCUITest journey covers
failure, visible recovery, retry, receipt, sheet dismissal, and byte-for-byte
pasteboard output. No schema migration or external egress was introduced.

## D322 — A resident brief proposal is scoped to one opaque calendar event (Aug 2026)

**Context:** the pre-meeting brief capability already existed as a manual
Library action and as an unexposed local Skill contract. Phase 3 needed a real
proposal moment without making the resident menu bar prompt for Calendar,
recomposing after confirmation, guessing event identity from private title and
time, or bypassing the durable policy and execution authority delivered by the
first two Skills phases. EventKit documents that its local event identifier can
change when an event moves calendars and may be lost after a full sync.

**Decision:** `UpcomingEvent` stores one bounded, byte-preserved opaque platform
identifier. The EventKit adapter omits events without a valid identifier,
queries only when full access already exists, and resolves a proposal with
`event(withIdentifier:)`; it never matches title or timestamp. Missing or
changed identity makes the proposal stale. `LoadPreMeetingBriefOffer` combines
the next event with the shared fail-closed Skills policy, event-scoped durable
dismissal, and existing execution state. Only no owner or the same failed owner
is actionable. That rule is rechecked at confirmation: a rebuilt presentation
may attach to a different UUID only when its prior effect failed; a different
settled or potentially delivered owner cannot claim the new preview.

The menu-bar model composes one exact `MeetingBrief` before it creates the
confirmation UUID. The sheet renders that immutable artifact and declared
local capabilities. Immediately before `ExecuteSkill`, the app re-resolves and
compares the complete event snapshot. `PreMeetingBriefEffect` receives the
approved brief directly and crosses one process-owned local-draft delivery
boundary; it cannot query Calendar, Ask, storage, or a model after approval.
Cancellation and observation identity are checked after resident async reads
and after execution before presentation state is published. Success retires
the offer and adds the ordinary global Skill receipt; failure retains the
original proposal for retry; dismissal persists independently for that event.

The XCUITest fixture requires both disposable storage and an explicit menu-bar
content flag. It mounts the production content/model in the app window because
the actual `MenuBarExtra` shell is owned by SystemUIServer and is not
deterministically automatable across supported macOS versions. It never reads
the host Calendar. Actual status-item, TCC, identifier-sync, and cross-version
behavior remain an explicit Sequoia/Tahoe field gate.

**Consequences:** Skills Settings now marks pre-meeting briefs available. The
resident proposal previews and delivers the same cited artifact, never sends
data off-device, and leaves a content-free durable receipt. Unit and
architecture tests cover identity bounds, policy, retry, cancellation, exact
material, exact lookup, and fixture isolation; one English and one Spanish
real-app journey cover preview through receipt. Reminder-draft permission work,
external egress consent, standing rules, and physical cross-version shell
evidence remain open.

## D323 — A reminder proposal binds one confirmed commitment to one exact list (Aug 2026)

**Context:** the local Reminder Draft Skill contract and durable execution
authority already existed, but no subject surface or EventKit effect adapter
could run it. Reusing notification reminders would conflate content-free alert
history with a user-authored Reminders item. Prompting from a resident load,
selecting a fallback list after preview, or querying one execution per Radar
row would also violate explicit consent, exact-preview, and bounded-read rules.

**Decision:** Commitment Radar projects at most 200 confirmed, non-deleted
commitments through one ApplicationKit use case. Policy, dismissal, and durable
execution state are read in three bounded operations, including one batch
idempotency-key query. A per-window `ReminderDraftModel` previews the canonical
title and due date and inspects authorization without prompting. Only the
explicit **Allow Reminders Access** action may request full Reminders access.
Full access resolves the default list to a bounded, byte-preserved opaque
identifier plus display title, both of which remain attached to the preview.

Confirmation re-reads the exact commitment, proposal surface, Skill policy,
durable owner, authorization, and destination. Only the same failed durable
owner is retryable. One process-owned actor retains a single `EKEventStore` for
default-list lookup, exact identifier re-resolution, `EKReminder` construction,
and save. Permission, list removal, or title drift fails closed; no title match
or alternative list is allowed. An explicit list refresh rebinds and displays
the current default before another confirmation, avoiding a retry loop against
stale destination data. The canonical preview arguments are the exact effect
arguments. Success retires the offer and leaves the content-free receipt
on the commitment and in Skills Settings; dismissal is scoped to that
commitment and never removes a receipt.

The disposable UI-test boundary starts authorization undetermined and grants it
only through the production permission action. It exposes one fake list and
never reaches host TCC or Reminders. The shipping and UI-host bundles both carry
the localized full-access purpose string.

**Consequences:** all four local Skills are now honestly available in the
central catalogue, so Settings omits its empty planned section. Unit and
architecture tests cover bounds, batching, canonical arguments, durable retry,
state fencing, permission, destination drift, same-store save, fixture
isolation, and bundle configuration. One English and one Spanish real-app
journey cover explicit access through subject and global receipts. Actual TCC
prompt text, default-list behavior, save semantics, and permission/list drift
on physical Sequoia and Tahoe Macs remain an explicit field gate; external
egress consent, standing rules, and AUTO-3 through AUTO-6 remain open.

## D324 — Native recording actions foreground one process and never invent Stop success (Aug 2026)

**Context:** the first native App Intent could start recording, but AUTO-3 had
no system action for ending the live session. Its foreground contract also used
`openAppWhenRun`, which the macOS 26 SDK deprecates in favor of
`supportedModes`; replacing it outright would break the macOS 14.4 deployment
floor because `IntentModes` itself starts at macOS 26. A Stop action cannot
honestly return success merely because it posted a notification: the app may be
opening, the database may still be unavailable, capture may be preparing or
already finalizing, and the durable stop workflow can still expose typed
recovery.

**Decision:** Start and Stop declare immediate foreground execution on macOS
26+ and retain Apple's documented deprecated compatibility property for earlier
supported macOS versions. The SDK-only intents file remains the single metadata
source. Packaging accepts exactly `StartRecordingIntent` and
`StopRecordingIntent`; no App Shortcuts provider, URL lookup, project-module
import, or second recording controller is introduced.

Stop posts one buffered process-local request. If the complete service graph is
not ready, that request survives launch or database recovery. Once ready, the
AppKit delegate consumes it with exactly one synchronous disposition: accepted,
no active recording, recording still preparing, already stopping, or recovery
required. An invocation that returns before a delegate exists says only that
Portavoz will handle the request after opening. Each non-actionable result names
one next step. Accepted work is fenced by one delegate-owned task, navigates to
the live recording surface, and calls the process-owned
`RecordingController.stop`; the dialog says **stopping**, never **stopped**.
Preparing and already-stopping states also bring the live surface forward.
Recovery-required uses a distinct non-starting route that reuses the typed
failure UI; only its explicit retry control can begin another capture.
Processing and typed failure recovery therefore remain visible, and a repeated
action cannot start a competing finalization. The
accepted task strongly owns the service graph until Stop returns, while its
weak delegate reference prevents an ownership cycle.

The disposable real-app fixture requests Stop only after the production Start
workflow has returned in `.recording`; it then requires capture to leave the
live state and surface the existing typed no-audio recovery. Unit tests cover
cold republishing, synchronous one-shot resolution, duplicate fencing, and all
recording-phase dispositions. App Intent source changes select that one journey
in English and Spanish. The stable, Dev, and UI-test bundle identities remain
separate.

**Consequences:** user-created Shortcuts can now start and stop Portavoz without
addressing capture hardware or persistence outside the app. Sequoia keeps the
released foreground behavior while Tahoe adopts the modern API. Local metadata,
package, and bilingual UI evidence do not prove physical Shortcuts picker, Siri,
Spotlight, cold database recovery, or cross-version registration behavior for
Stop; those remain explicit Sequoia/Tahoe field gates. Meeting, person, and
confirmed-commitment App Entities and the remaining AUTO-3 through AUTO-6 work
are still open.

## D325 — App Entities resolve bounded private identity into one exact app route (Aug 2026)

**Context:** AUTO-3 still lacked native values for choosing a meeting, a
canonical person, or a user-confirmed commitment from Shortcuts and Siri.
Mirroring persistence models into App Intents would expose unrelated private
fields, while loading a complete library for every picker keystroke would make
system queries unbounded. A second retained service registry would also compete
with the database lifecycle already owned by `AppServices`. Finally, opening a
commitment behind the Radar window's previous filters could make a valid exact
route look missing.

**Decision:** the SDK-only metadata source declares three narrow `AppEntity`
values and `EntityStringQuery` types: meeting title/date, canonical-person
name, and confirmed-commitment title/optional due date. Entity resolution uses
Apple's standard `AppDependencyManager`; the application installs one
database-backed catalog only after the authoritative store opens. Its
ApplicationKit request rejects more than 50 identifiers, result limits outside
1...50, normalized text over 120 characters, and mixed exact/text selectors.
StorageKit performs escaped literal SQL matching, excludes tombstones and
dismissed commitments, preserves
exact identifier order, and returns at most the requested bound without
hydrating transcripts, audio, summaries, or evidence. System suggestions use
20 rows.

Three foreground `OpenIntent`s re-read the exact identity immediately before
handoff. A meeting opens its Detail, a person opens Commitment Radar with a
visible reversible canonical-owner focus, and a commitment opens only that
exact Radar item. Exact commitment identity overrides prior Radar owner, due,
and activity filters; person focus temporarily overrides owner and uses all
due/activity states. **Show all** restores the window's previous filters.
Missing values route to Library or unfiltered Radar with one explicit recovery
sentence; database failure opens the same surfaces so their existing recovery
state remains reachable. The process bridge keeps only the latest destination
while launch is blocked, consumes it once after the complete service graph
exists, validates every UUID before constructing a typed route, and never
builds an unbounded navigation queue.

`AppEntity`/`EntityStringQuery` remain compatible with the macOS 14.4
deployment floor. `IndexedEntity` conformance is availability-gated to macOS
15+, but this slice does not publish person or commitment entities through
Core Spotlight and therefore makes no native Spotlight-indexing claim. The
existing protected meeting-document index remains separate. Packaging now
fails unless metadata contains exactly five actions, three entities, and three
queries, and still rejects automatic App Shortcuts. The disposable UI fixture
invokes the same SDK-only open-action logic as each production `OpenIntent`
after seeding, passes its disposable catalog explicitly, and never queries the
user's real library. It does not call `perform()` directly because App Intents
initializes `@AppDependency` only inside the system-owned execution flow.

**Consequences:** user-created Shortcuts can choose and open one local meeting,
canonical person, or confirmed commitment through a bounded private catalog,
with exact visible navigation and reversible focus. Unit tests cover bounds,
literal wildcard handling, tombstone/dismissal exclusion, canonical identity,
exact order, forged IDs, filter precedence, and one-shot recovery. One English
and one Spanish real-app journey cover all three destinations. Physical
Shortcuts picker/search, Siri disambiguation, cold database recovery, native
entity Spotlight publication, and registration on Sequoia and Tahoe remain
field or later AUTO-3 evidence; AUTO-3 is not closed by local metadata alone.

## D326 — One protected Spotlight generation changes shape by OS capability (Aug 2026)

**Context:** D325 supplied three native App Entities but did not publish them.
Adding a second entity index beside the released meeting-document index would
show duplicate meetings and schedule two competing full-library workers.
Replacing document search outright would regress the macOS 14.4 deployment
floor, where App-Entity indexing is unavailable. A native entity snapshot must
also preserve the released capped meeting-body search instead of becoming a
title-only regression.

**Decision:** one process-scoped `SpotlightIndexer` now owns one protected named
`app.portavoz.search.v3` generation. On macOS 15 and later it publishes meeting,
canonical-person, and non-dismissed confirmed/done commitment values through
`CSSearchableIndex.indexAppEntities`; on 14.4 it publishes the existing meeting
documents. Both modes replace the complete index in 500-value batches and use
different versioned SHA-256 client-state prefixes, so an OS capability change
cannot mistake the other representation for current data. Meeting App Entities
reuse the D85 title, date, newest cross-recipe summary, and first 40 live
segments under the same 4,000-character cap. People carry only canonical name;
commitments carry only title and optional due date.

StorageKit supplies one transactionally consistent, platform-neutral snapshot
for the entity mode. Tombstones and dismissed commitments remain excluded.
The worker retains burst coalescing, bounded retry, launch repair, content-free
telemetry, and no-content logging. The new AppIntents overlay does not mark its
async index receiver Sendable under strict Swift 6, so the entity backend uses
a task-local named `CSSearchableIndex` rather than transferring an actor-owned
framework reference. Only after v3 has valid client state does cleanup remove
the older named and default indexes; the old named index receives a foreign
migration state so an older app rebuilds rather than accepting an empty index.

**Consequences:** Sequoia and Tahoe have one native private entity search
generation instead of duplicate meeting results, while Sonoma retains released
meeting search. Local tests prove projection fences, mode-state separation,
retry/coalescing/migration behavior, and exact searchable attributes. Metadata
and bilingual real-app navigation remain necessary but do not prove system
result presentation, picker registration, Siri disambiguation, or cold recovery
on physical Sequoia and Tahoe; those field gates keep AUTO-3 open.

## D327 — An email Skill opens one reviewed draft and never owns Send (Aug 2026)

**Context:** Portavoz already has a manual editable recap and system ShareLink,
but the confirmed-Skill surface had only local effects. The first AUTO-4 adapter
must prove a real external boundary without inventing recipients, reusable
consent, delivery success, or a parallel recap implementation. Treating an
email composer as local would also be misleading: the external client may save
or sync meeting-derived text as soon as it receives the draft.

**Decision:** `EmailRecapDraftSkill` is the single definition in a new
`ExternalSkills` registry, leaving `LocalSkills.isEntirelyLocal` intact. It
declares `readMeetingMaterial` and `sendRemote`, is irreversible, and requires
`explicitPerProposal` confirmation. One meeting UUID is the complete typed
argument and scopes the stable meeting-level idempotency key; no recipient,
address book, account, or destination is inferred or stored.

The skill delegates to the existing summary-only `RecapComposer` and renders
its Markdown through the existing plain-text exporter. Meeting Detail captures
the exact durable meeting/speaker/summary material shown in the sheet and uses
an email-specific preview shape, so a clipboard recap approval cannot authorize
an external-app handoff. Confirmation re-reads and recomposes the material
before any claim and refuses a changed subject, body, or preview kind. The
sheet shows the complete subject/body, explicitly states that recipients are
empty, warns that the email app may save or sync the text, and says that the
user still presses Send. The Settings toggle enables proposals only; it is not
egress consent. The sheet's submit action alone supplies the exact proposal's
egress permission to `ExecuteSkill`. Its UUID and `proposedAt` timestamp are
captured with the preview and retained across clicks; confirmation cannot mint
a fresh timestamp to extend the 15-minute admission window.

The macOS adapter creates `NSSharingService(.composeEmail)` task-locally on the
main actor, verifies it can accept the approved body, assigns an empty
`recipients` array plus the approved subject, and performs that handoff. It
contains no network client, email SDK, credential, AppleScript, recipient
lookup, or Send command. An unavailable composer is a recoverable failed
effect. AppKit provides no synchronous proof that the external client saved or
sent a message, so a successful content-free receipt means **composer handoff
requested**, never delivered or sent. That success retires only the email offer;
a failed attempt keeps the original durable proposal retryable. An interrupted
`executing` owner remains receipted but is not offered again because the
composer may already have opened; ambiguity never authorizes a duplicate.
Its UI says that the handoff status is unknown rather than claiming the client
did not open.
Meeting Detail reads the local and external one-shot execution keys in one
bounded exact-key batch, and combines that with one literal package-prefix
receipt read, so adding this adapter does not create a per-offer query loop.

Disposable UI automation injects an inert opener which exercises the real
proposal, admission, claim, effect, settlement, and receipt path without
launching the host email client. Unit coverage pins the external registry,
capabilities, one-meeting projection, exact composer reuse, egress refusal
before claim, preview separation, delivery failure, and receipt retirement.
Bilingual XCUITest pins the full preview, no-recipient/sync disclosures,
localized action, unchanged clipboard, foreground app, receipt, and independent
offer retirement.

**Consequences:** Portavoz gains one useful external Skill while remaining a
drafting assistant rather than an email sender. There is no schema, credential,
standing rule, unattended egress, recipient automation, or background network
work. Physical default-client availability, draft presentation, and handoff on
Sequoia and Tahoe remain explicit field evidence; local automation must not be
reported as proof of those system-owned surfaces.

## D328 — A secret-Gist Skill is exact, one-shot, and fail-closed after egress (Aug 2026)

**Context:** Portavoz already had a manual GitHub Gist exporter, a Keychain
token, a canonical correction-aware Markdown renderer, and a data-egress
gateway that persists a content-free attempt before `URLSession`. AUTO-4b
needed to make that capability proposal-driven without adding another
renderer, a second network stack, reusable consent, or a false promise that a
timed-out `POST /gists` did not create anything. GitHub's create-Gist endpoint
does not accept a caller-owned idempotency key, so ordinary automatic retry is
not safe after transport becomes possible.

**Decision:** `SecretGistPublishSkill` is the second definition in
`ExternalSkills`. It declares `readMeetingMaterial` and `sendRemote`, requires
`explicitPerProposal` confirmation, accepts exactly one meeting UUID, and owns
one meeting-scoped one-shot key. The confirmation preview is a typed
`SecretGistDraft`: the exact canonical Markdown bytes, slugged `.md` filename,
meeting-title description, and fixed `api.github.com` destination. It states
that the Gist is secret only in GitHub's unlisted sense and that anyone holding
the URL can read it. Enabling the Settings row never authorizes publication.
The complete Markdown stays selectable in a read-only TextKit viewport, which
avoids one monolithic SwiftUI `Text` layout for long transcripts without
truncating or changing the material being approved.

Preview and effect reuse `PrepareMeetingDocument`, `AppGistDocumentPublisher`,
`GistPublisher`, and `URLSessionDataEgressGateway`. Confirmation re-renders the
current meeting and compares the complete typed draft before resolving or
writing any Skill claim. The GitHub token is loaded from Keychain during
publisher preparation before `ExecuteSkill`; a missing token is therefore a
known pre-egress failure and can be retried after configuration. No token,
Markdown, filename, description, or returned URL enters a durable Skill or
privacy receipt.

The exact proposal UUID also becomes the `DataEgressEventID`. The gateway
inserts that UUID into `dataEgressEvent` before `URLSession` can observe the
request. If confirmation is reconstructed or a prior attempt is replayed, the
stable Skill key reattaches to its original proposal owner; a duplicate egress
UUID then fails at the local primary key before a second transport. This is a
fail-closed duplicate fence, not a claim that GitHub supports request
idempotency.

After publisher preparation, every provider, response-decoding, settlement,
interruption, or transport failure is conservatively **outcome unknown**. A
failed or still-executing Gist receipt suppresses the offer and never exposes
an automatic or in-sheet retry; the UI tells the user to inspect GitHub first.
When GitHub returned a URL but local success settlement failed, that URL remains
available only in the confirmation sheet's terminal result surface while the
receipt stays honest. A clean 201 plus local settlement transitions that same
sheet to the returned URL and records both the content-free egress attempt and
the ordinary Skill success. Keeping the terminal result inside the existing
sheet avoids racing a second presentation controller against sheet dismissal.

Disposable UI composition still runs the real proposal, canonical renderer,
`GistPublisher` request codec, egress metadata checks, durable disposable
receipts, effect, and settlement. Its gateway substitutes only transport with
a provider-shaped 201 response and stable fake URL; it cannot touch the host
network or Keychain. Unit and architecture gates pin exact preview/effect
identity, pre-claim drift refusal, proposal-to-egress UUID equality, no second
transport after replay, typed ambiguous outcomes, canonical endpoint reuse,
and removal of endpoint force unwraps. Bilingual XCUITest pins the complete
Markdown, filename, host, audience warning, localized action, result URL,
Skill receipt, privacy egress receipt, Settings status, and independent offer
retirement.

**Consequences:** Portavoz can publish exactly one reviewed secret Gist without
becoming an autonomous exporter. There is no new schema, token store, renderer,
transport, standing rule, background task, or unattended retry. The code uses
only APIs available at the macOS 14 deployment target, so it introduces no new
Sequoia/Tahoe availability split. Real GitHub authentication, provider response,
network interruption, browser opening, and result presentation on physical
Sequoia and Tahoe remain explicit field evidence and must not be inferred from
the disposable adapter.

## D329 — Spotlight adopts correction-fenced text without expanding identity (Aug 2026)

**Context:** the D85 Spotlight snapshot met its 100,000-meeting budget by
selecting every meeting, one summary, and only 40 transcript rows in one SQL
read. It still indexed accepted segment text after D313 gave lexical search a
transactional corrected-text lane, and it continued to publish a known-stale
summary after the correction overlay changed. Moving full transcript
composition into the app indexer would either load complete libraries or
restore per-meeting reads. Publishing split or merge rows as segment results
would also reopen the unresolved citation-identity contract that D313 kept out
of search.

**Decision:** Spotlight keeps one result identity per meeting and adopts the
same bounded text policy as lexical search. Its transcript CTE unions accepted
segments that have no active text-affecting correction with current-revision
`segmentCorrectedText` rows, ranks that union by the accepted segment timeline,
and then applies the existing first-40 and 4,000-character caps. Speaker-only
corrections retain the accepted text. Active split, merge, and suppress targets
are omitted; their composed replacement rows remain outside search until a
shared structural identity contract exists. Restore makes the accepted row
eligible again.

Schema v36 adds sparse `transcriptCorrectionSearchState`: one meeting ID,
accepted transcript revision, and opaque effective correction revision only
while an active overlay exists. The same transaction that refreshes D313 text
now deletes and rebuilds both projections for append, tombstone, replica merge,
sync replay, Refine, and re-transcription; migration backfills only meetings
that have correction history. The row contains no transcript, summary, speaker,
provider, or destination content.

The Spotlight summary CTE publishes only provenance that matches that sparse
revision. A direct or legacy summary is eligible only for an accepted reading;
a generated summary for a corrected meeting must carry the exact current
`sourceCorrectionRevision`. Invalid JSON, a missing generation run, a stale
revision, or active history without current sparse state omits the summary
instead of failing the complete snapshot or serving stale words. Corrected
transcript rows also require the current sparse revision and
their live terminal replacement event. The published fields remain unchanged,
so the existing SHA-256 client state naturally replaces the index only when
the actual title/date/body or entity catalog changes.

The storage read begins with one content-free `EXISTS` probe inside the same
SQLite snapshot. With no active correction history or sparse state it retains
D85's fast transcript statement plus D329's unconditional summary-provenance
checks; otherwise it runs the correction-aware CTEs above. This keeps the common
100,000-meeting path within its established performance budget without
weakening missing-state or malformed-provenance fail-closed behavior. Both
routes remain set based and bounded; the probe does not restore per-meeting
reads.

Successful Meeting Detail text and structural correction writes now wake the
shared search-reconciliation funnel; failed writes do not. The process actor,
protected v3 index, 500-value batches, mode split, retry policy, launch repair,
and macOS 14.4/15 availability boundary stay unchanged. Tests cover corrected
and stale text, current/stale/malformed summary lineage, structural omission,
restore, missing-state fail-closed behavior, migration backfill, client-state
replacement, and success-only invalidation.

**Consequences:** a corrected word can reach both lexical search and the
meeting's Spotlight body without reviving the D85 N+1 architecture, while a
known-stale summary stops matching system search. Structural composed content,
semantic re-embedding, and Apuntador regeneration remain explicit T28 gaps.
Deterministic projection/backend tests do not prove physical result presentation
or Core Spotlight recovery on Sequoia and Tahoe; those remain field evidence.

## D330 — Corrected transcript text owns a fenced semantic lane (Aug 2026)

**Context:** D313 made active `replaceText` corrections immediately findable by
FTS, and D329 reused that projection for bounded Spotlight documents. Semantic
maintenance still excluded the accepted segment as soon as its text changed,
but had no current corrected source to embed or search. Replacing the accepted
vector would make restore unnecessarily rebuild immutable material; scanning a
second lane for every accepted-only library would also put the established
100,000-vector exact-path budget at risk.

**Decision:** schema v37 adds nullable `embedding` and
`embeddingFingerprint` columns to the disposable `segmentCorrectedText`
projection. The immutable accepted vector remains on `segment`. Exactly one
source lane is eligible for a segment: accepted text when no active
text-affecting correction owns it, or the current corrected row when a live
terminal `replaceText` event, sparse correction state, and accepted transcript
revision all agree. Restore therefore exposes the already cached accepted
vector without re-embedding it.

Semantic candidates carry an explicit accepted/corrected source identity; the
corrected identity includes the correction UUID. Publication is one
compare-and-swap update over segment ID, meeting ID, correction ID, accepted
revision, exact corrected text, missing vector state, live meeting/segment,
current sparse state, and terminal correction ownership. A superseded,
structural, deleted, stale, conflicting, or unfenced source is a content-free
skip and remains on the durable `NULL` cursor only if a current lane still
exists. Non-positive candidate limits return no rows rather than reaching
SQLite's negative-`LIMIT` unbounded behavior.

Correction projection refresh preserves an existing corrected vector only when
correction ID, accepted revision, corrected text, and language all still match;
unrelated correction activity cannot force needless re-embedding, while any
source drift clears the derived value. Profile invalidation covers both tables.
The existing background semantic owner, capture checkpoints, durable lease,
bounded batches, readiness states, and no-download policy need no second
scheduler or cursor.

Exact search performs one content-free probe inside the same GRDB read
snapshot. If no current corrected vector exists, it retains the accepted-only
stream and deterministic fingerprint/order. Otherwise one ordered `UNION ALL`
stream scores accepted and corrected vectors once per query batch. Hit
materialization revalidates the same current corrected source and returns its
text under the accepted segment ID, so citation/navigation identity does not
expand. Storage code is decomposed into lexical search, semantic maintenance,
and semantic retrieval owners; no ApplicationKit or app composition enters the
database path. The D210 research projection remains accepted-only because its
identity carries segment ID and accepted revision but no correction lineage;
an actively corrected row is omitted rather than applying a stale candidate
rank to different text.

**Consequences:** an accepted word replaced by the user becomes semantically
findable after ordinary background maintenance, readiness honestly returns to
partial while that vector is pending, and undo reuses the accepted vector.
Active split, merge, and suppress output still has no shared search-result
identity and remains excluded; automatic Apuntador regeneration also remains
separate. Deterministic migration, correction, publication, readiness, search,
restore, and bilingual app tests do not prove model assets, correction-heavy
latency, or memory behavior on physical Sequoia/Tahoe hosts, so those remain
explicit performance and field-evidence gates.

## D331 — Recheck stale Apuntador cards only on explicit corrected review (Aug 2026)

**Context:** D233 honestly retains Apuntador cards as stale after a transcript
correction and disables their evidence, but leaves no recovery action. The
post-Refine pipeline can rebuild a complete accepted snapshot, and explicit
summary regeneration already consumes composed corrected rows. Reusing either
without an evidence rule would persist ephemeral split/merge IDs that StorageKit
correctly rejects; running automatically on each correction would also surprise
the user with model cost or configured BYOK traffic and make editing latency
depend on intelligence availability.

**Decision:** add one explicit section-level recheck when any Meeting Detail
Apuntador card is stale. ApplicationKit owns a `RegenerateCompanionCards` use
case over `MeetingTranscriptGenerationMaterial`. The app adapter reuses the
bounded post-Refine turn pipeline under a distinct `meeting-review` workflow.
The live-recording enable toggle does not gate a direct user request, while the
Foundation Models classifier still requires macOS 26 and available Apple
Intelligence; a configured, consented BYOK endpoint remains only the knowledge-
answer provider.

The generation request carries the composed-row-to-accepted-source map. Its
private version-3 operation fingerprint binds each relevant generated row and
its ordered source IDs. Question and cited-answer evidence expands through that
map and deduplicates in first-use order before persistence, so
replace/split/merge material can inform the model while durable links continue
to target immutable accepted segments. Suppressed rows never enter the
generated material.

Only a complete pass with no terminal outcome replaces the whole card snapshot,
including with an empty set when no eligible question remains. Model
unavailability, cancellation, any incomplete pass, transcript/correction drift,
invalid evidence, or a late transaction failure preserves every previous stale
card. Explicit-review storage rejects a new card without immutable question
evidence. Current terminal runs are saved best effort. The replacement
transaction rechecks meeting and transcript identity, effective correction
revision, workflow, succeeded run, and every evidence link before tombstoning
the old snapshot. Correction writes still start no model work, and automatic
regeneration remains absent.

**Rationale:** an explicit whole-snapshot action gives stale assistance a safe
recovery path without weakening local-first consent, correction responsiveness,
or immutable evidence. One accepted-source projection prevents corrected
generation from inventing a second evidence identity system, while atomic
replacement makes partial answers and stale races observationally impossible.

## D332 — Semantic assets prepare only from an explicit Settings action (Aug 2026)

**Context:** Ask and Library intentionally preserve exact FTS and never request
Apple's Latin contextual-embedding assets while the user types. Background
maintenance also accepts only already-installed assets. That protects latency,
capture, and consent, but a clean Mac had no way to enable semantic augmentation
or even see why it was absent. Asset availability and corpus completeness were
also easy to conflate. The current macOS 26.5 SDK confirms that contextual
assets are downloaded over the air and recommends considering `NLEmbedding` for
semantic similarity, but that guidance alone is not evidence that replacing
Portavoz's bilingual compatibility-profile-fenced model improves the product.

**Decision:** ApplicationKit separates a side-effect-free
`InspectSemanticSearchAssets` contract from the sole explicit
`PrepareSemanticSearchAssets` workflow. Inspection requires a valid model
profile and reads only `hasAvailableAssets`. Preparation returns unsupported
without touching the runtime, loads an already-installed model with download
permission disabled, and passes `allowAssetDownload: true` only when a valid
model reports missing assets. `SentenceEmbedder` remains the only source that
calls Apple's `requestAssets()` API.

The Intelligence Settings pane owns the only button for that workflow. One
process-scoped observable model serializes clicks and persists status across
Settings-window lifetime. Its app client runs semantic-family resource
admission first, so protected capture fails with a retryable finish-recording
state. Ordinary failure is retryable, cancellation re-inspects readiness, and
only verified readiness wakes the existing signal-driven corpus supervisor.
Settings never indexes the library itself. Ask, Library, launch, and automatic
maintenance retain `allowAssetDownload: false`; exact FTS remains available in
every asset and corpus state.

The UI describes macOS ownership, background indexing, exact-search fallback,
and variable storage cost. A Tahoe 26.5 reference-host probe observed the
revision-1, 512-dimensional Latin model supporting 20 languages including
English and Spanish, about 79 MiB process RSS, and a 301 MiB app-specific
compiled BNNS cache. These are scoped observations, not a universal download
size. A fake model exists only behind both temporary-store isolation and a
dedicated XCUITest flag; bilingual UI automation can therefore prove the real
explicit transition without touching host assets.

**Consequences:** clean installations have an honest opt-in recovery path and
semantic preparation can no longer hide behind search latency. Corpus progress
continues through the existing readiness and durable-maintenance contracts.
Physical clean-install disk deltas and runtime behavior on Sequoia and other
Tahoe builds remain field evidence. Replacing contextual embeddings with
`NLEmbedding`, sqlite-vec, USearch/ANN, or another engine still requires the
accepted bilingual quality, latency, memory, correction, rebuild, and rollback
matrix rather than documentation preference alone.

## D333 — Derive Skills privacy disclosure from executable capabilities (Aug 2026)

**Context:** the Phase-2 Skills pane correctly kept durable enablement separate
from per-proposal consent, but every available row still displayed the same
green `On this Mac` badge. That copy contradicted the executable contracts for
Email Recap and Secret Gist, which both declare `sendRemote`, and it overstated
the local rows as well: a chosen file, clipboard consumer, native Reminders
list, or system app can sync without Portavoz performing a network request.
Hardcoding two lists of identifiers in SwiftUI would eventually drift from the
admission policy it claims to explain.

**Decision:** `SkillControlCenterItem` derives one bounded disclosure from its
immutable `SkillDefinition`. A definition that declares any external effect is
an `externalHandoff`; every other definition is a
`noDirectNetworkHandoff`. Settings renders the former as material that may
leave Portavoz and the latter only as the absence of a direct Portavoz network
handoff. It independently renders explicit-per-proposal confirmation as
approval required every time. Neither statement is selected from a title,
localized copy, registry position, or skill identifier.

**Consequences:** enabling Email Recap or Secret Gist can no longer look like
reusable egress permission, and local/native effects no longer promise that an
OS-managed destination cannot sync. The change adds no capability, adapter,
standing rule, transport, consent persistence, or retry path. New external
Skills automatically inherit the conservative disclosure as soon as their
executable definition declares `sendRemote`; unit, architecture, localization,
and bilingual real-app tests keep that projection from regressing.

## D334 — Structural transcript rows own shared search identity (Aug 2026)

**Context:** accepted segments and active text replacements are one-to-one, so
the existing lexical and semantic lanes can use the accepted segment UUID.
Structural corrections change cardinality: one split creates several visible
rows, one merge combines several accepted rows, and suppression creates no
visible content. Treating any of those as one accepted segment would make
deduplication, citations, semantic publication, and UI navigation ambiguous;
excluding them left what the user saw different from what Search, Ask, and
Spotlight could find.

**Decision:** schema v38 adds a disposable `transcriptStructuralSearchRow`
projection with an FTS mirror, optional profile-fingerprinted semantic vector,
and an ordered `transcriptStructuralSearchSource` relation back to live
accepted segments. An active split emits one row per authored part under that
part's stable UUID. An active merge emits one row under its correction UUID.
Suppression emits no row. Restore removes the derived structural rows and
reactivates the accepted rows and their cached accepted vectors.

`SearchHit.segmentID` remains a compatibility name for the visible retrieval
unit and now has an explicit `resultID` source of truth plus ordered
`sourceSegmentIDs`. Application Library and Ask values preserve both. Product
navigation continues to use meeting plus exact timestamp, so it never assumes
that a structural result is a stored accepted segment. Durable graph and
generated-artifact evidence remain accepted-source authority.

Correction refresh rebuilds replacement text, sparse correction lineage, the
structural projection, and source relations in the same transaction on every
append, tombstone, replica merge, sync replay, accepted-revision replacement,
or rebuild. Existing structural vectors survive only when result identity,
correction identity, revision, kind, text, language, and timing still match.
FTS, semantic candidate selection/publication/materialization, Library
observation, and Spotlight revalidate current correction ownership and live
source rows. Semantic publication uses the result UUID, so split parts are
independent candidates and a stale pre-restore result is a content-free skip.
Accepted-only semantic libraries keep their established fast scan.

**Consequences:** queries can span the accepted boundaries of a visible merge,
split parts are found independently, suppressed speech stays absent, and undo
restores accepted identities without model work. The projection is derived,
device-local, excluded from sync/export authority, and rebuildable from
immutable correction history plus accepted transcript material. This closes
the missing structural identity in code; correction-heavy latency, memory,
cold recovery, Core Spotlight registration, and physical Sequoia/Tahoe model
behavior remain field-evidence gates rather than inferred release claims.

## D335 — Receipt inspection replays one content-free causal chain (Aug 2026)

**Context:** Skills Settings exposed the newest bounded execution receipts, but
each row flattened the durable result into one status. A user could not inspect
whether a run was confirmed, began, failed, retried, or completed, even though
schema v31 already stores that exact append-only evidence. Reading the current
projection and events independently would introduce a race: another process
could settle a run between reads and produce a terminal status beside a
timeline that still ended at `begin`. Showing raw proposal arguments or the
idempotency key would also turn a content-free audit surface into a potential
meeting-identity leak.

**Decision:** the first AUTO-6 slice makes each recent receipt inspectable.
StorageKit returns `SkillExecutionAudit` from one SQLite read snapshot containing
the exact current record and its predecessor-linked events in causal insertion
order. An unknown persisted failure category is an error instead of silently
becoming `nil`; StorageKit also verifies each predecessor pointer and the
current projection's latest-event tail. `LoadSkillReceiptInspection` maps that
validated storage vocabulary into a typed presentation timeline and replays the
permitted state machine, including attempt increments on retry; a missing,
empty, impossible, or projection-inconsistent chain fails closed. The audit
query probes at most 257 events and rejects a chain longer than the 256-event
presentation ceiling rather than materializing unbounded local history.

The Settings sheet receives only skill identity/version, current state and
attempt, timestamps, typed failure category, and causal event labels. It never
receives the idempotency key, proposal arguments, destination, provider result,
or meeting material. Its retry button retries only the audit read and cannot
claim, execute, or repeat an effect. Causal ordering remains insertion-based;
wall-clock time is display evidence and may move backward. The implementation
uses only APIs available at the macOS 14.4 deployment floor.

**Consequences:** a user can now understand one Skill run and retry history
without exposing its content or authorizing a new action. This is an incremental
AUTO-6 control-center slice, not the complete Automation center: proposed and
waiting queues, receipt-level workflow actions, explanation of proposal inputs,
and AUTO-5 standing rules remain open. No schema, egress consent, external
adapter, background task, or unattended execution was added.

## D336 — Skill activity scopes query durable execution state directly (Aug 2026)

**Context:** the first Skills pane showed only the 20 newest executions. A
confirmed run waiting to begin or an older failed run could fall outside that
window, and filtering the bounded recent array in SwiftUI would make the
result look complete while silently hiding matching durable history. Proposed
offers cannot yet join the same surface honestly: they are owned by individual
presentation flows rather than one central durable proposal authority.

**Decision:** Core defines four execution-review scopes: Recent, Waiting,
Needs attention, and Completed. Waiting is exactly durable `confirmed` state;
Completed is `succeeded` or pre-handoff `cancelled`; Needs attention excludes
only those known waiting and terminal states, so a future unknown state remains
visible fail closed. Every StorageKit read validates a 1...100 limit and orders
by `(updatedAt DESC, proposalID ASC)`. Schema v39 adds one partial index in that
order for each state scope. Scoped SQL explicitly uses its matching index so
SQLite cannot prefer the older state-leading index and then sort a sparse or
empty result in a temporary B-tree.

`LoadSkillControlCenterRequest` and its snapshot carry the selected scope. The
Settings segmented control renders receipts only when the returned scope still
matches the selection; loading and error states therefore cannot relabel stale
rows. A scope-only read failure is isolated from the already verified pause and
per-Skill policy, while a failed mutation still disables those controls until
the durable policy is re-read. The existing receipt inspector remains read
only and unchanged.

**Consequences:** users can find waiting, active/failed, and terminal runs
without a full-history scan or a misleading client-side filter. The three
partial indexes together contain one entry per execution—the cardinality of
one full index—while preserving exact newest-first plans for each state group.
This slice adds no proposal queue, proposed-offer persistence, workflow action,
standing rule, egress authority, background execution, or adapter. Explaining
why an offer appeared and what data it will use requires the next central
durable proposal slice rather than inference from whichever UI is open.

## D337 — Proposed Skills use one content-free observed-offer authority (Aug 2026)

**Context:** Meeting Detail, the resident pre-meeting card, and Commitment
Radar each owned actionable offers only in transient presentation flows.
Settings therefore could not honestly show a Proposed queue, explain why an
offer appeared, or name the data categories it would read. Reconstructing
offers by scanning meetings, transcripts, commitments, and EventKit would make
the review surface a second product-policy engine and would centralize private
content. Effect capabilities alone were also insufficient disclosure: they say
what an adapter may do, not which meeting or platform material influences its
output. Finally, v34 limited a dismissal key to 200 characters while the
released calendar boundary accepts byte-opaque EventKit identities up to 2,000
UTF-8 bytes, so one valid long offer could not be durably dismissed.

**Decision:** every `SkillDefinition` declares a nonempty bounded set of
`SkillInputDataClass` values, and every exact `SkillProposal` requests a
nonempty subset alongside its requested capabilities. Admission rejects either
undeclared ceiling violation. The six released Skills declare their actual
meeting details, summary, transcript, notes, Companion history, commitment,
calendar event, and selected-destination inputs explicitly.

Schema v40 adds `skillOfferProposal` plus normalized
`skillOfferProposalInput`. A `SkillOfferRegistration` is keyed internally by
the existing stable offer intent but exposes an unrelated random review UUID.
It stores only Skill identity/version, typed reason and subject, exact input
classes, first/last observation, and optional expiry. Meeting and commitment
subjects use cascade cleanup; calendar identity remains opaque and expires at
the event start. The migration also rebuilds `skillOfferDismissal` with one
shared 2,200-byte key ceiling, preserving existing rows and provider identity
bytes without trimming.

Every released producer reconciles at most 200 unique candidate intents before
returning offers. Inactive evaluated candidates retire, while dismissal and
one-shot confirmation delete their matching authority inside the same write
transaction. Exact execution UUID and preview still belong to confirmation,
not discovery: package export is intentionally destination-free at offer time
and may lead to several destination-scoped execution claims, so its reusable
offer authority is not one exact `SkillProposal`.

The Settings read prunes expired rows before a pinned newest-first index walk,
loads input classes in one bounded batch, and refuses more than 100 storage or
50 application rows. ApplicationKit then requires a current available catalogue
entry, exact Skill version, compatible typed reason, and declared input subset;
global pause and individual disablement remain the shared deny authority. The
SwiftUI section receives no stable offer key, subject identity, title,
transcript, preview, argument, destination, recipient, or execution action. Its
proposal load and failure state are independently request-fenced, so an
unverified proposal read shows no rows without disabling already verified
policy controls.

**Consequences:** users can inspect why a real product surface proposed a Skill
and which exact data categories it may use without creating a central content
index or reusable consent. The original surface remains the only owner of the
exact preview and confirmation. Same-version input-explanation drift is rejected
once observed; changing that contract requires a Skill version increase.
Calendar deletion can be learned only when its owning surface sees it again, so
expiry remains the content-free upper bound. This slice adds no Settings-side
confirm/dismiss/retry/revoke action, standing rule, background execution,
adapter, transport, or egress authority; those remain separate AUTO-6/AUTO-5
work with physical Sequoia, separate-hardware Tahoe, and VoiceOver evidence.

## D338 — Proposed dismissal is opaque, linearizable, and claim-fenced (Aug 2026)

**Context:** D337 gave Settings a content-free Proposed queue but deliberately
left it read only. Reusing the existing stable offer key in SwiftUI would expose
meeting, commitment, or opaque calendar identity. Optimistically hiding a row
would also be unsafe: a storage failure could lose the visible proposal without
recording the user's decision. More importantly, a real subject surface may
have read an offer before Settings dismisses it, and an already-open
confirmation may still hold an exact valid preview. Deleting only the central
row would let stale reconciliation recreate it or let the stale sheet execute
after the user said no.

**Decision:** Settings sends only the unrelated v40 review UUID through
`DismissSkillOfferReview`. Storage resolves a nonexpired authority row, inserts
its existing `skillOfferDismissal` tombstone, and deletes the proposal in one
SQLite write transaction. Missing, expired, concurrently retired, and repeated
UUIDs return the same content-free unavailable outcome. The app reloads after a
verified dismissed/unavailable result; a thrown mutation retains the exact row,
shows an inline retry, and does not disable independently verified Skill policy.

Reconciliation reads dismissals for its bounded active set inside the same
write and deletes/skips those authorities before upsert. A producer whose
subject read preceded the dismissal therefore cannot recreate a hidden row.
Every execution request now carries its reviewed `offerKey` separately from the
exact effect `idempotencyKey`. Storage accepts equality for one-shot offers or
an exact `offerKey + ":"` prefix for reusable package destinations, rejects
unrelated slots, and checks the durable dismissal inside the confirmation
transaction before granting any new claim. An exact owner that committed first
is resolved before the tombstone check so retry remains idempotent. Opaque
provider identity bytes are preserved rather than compared with a trimmed copy.

**Consequences:** SQLite write serialization supplies one linearization point.
If dismissal commits first, later stale reconciliation remains absent and an
open confirmation receives typed `offerDismissed` without a claim or effect.
If a one-shot confirmation commits first, it retires the review and a later
dismissal UUID is simply unavailable. A reusable package claim deliberately
keeps its destination-free review: a later dismissal fences every new
destination while the exact effect owner that already committed remains
idempotently resolvable. No schema, preview storage, central content scan,
Settings confirmation, receipt retry/revoke, standing rule, background
execution, adapter, transport, or egress consent is added. The implementation
uses APIs available at the macOS 14.4 floor; physical VoiceOver, Sequoia, and
separate-hardware Tahoe behavior remain field evidence.

## D339 — Waiting approval revocation is content-free and handoff-fenced (Aug 2026)

**Context:** the indexed Waiting scope exposed durable executions in
`confirmed` state, but the receipt inspector could only explain them. A user
who changed their mind before execution began had no central way to withdraw
that one approval. Reconstructing a proposal or retrying an effect from the
receipt would be unsafe: the control-center projection intentionally has no
preview, arguments, subject identity, destination, or idempotency key. An
optimistic row removal would also lie if storage rejected the mutation, and a
cancel racing the execution handoff must not report success after the effect
may have started.

**Decision:** a receipt exposes **Revoke approval** only after one verified
inspection reports durable `confirmed` state. SwiftUI sends only the proposal
UUID to `RevokeWaitingSkillExecution`. Its narrow storage protocol exposes only
`cancelSkillExecution`; it has no claim, begin, settle, proposal, adapter, or
effect authority. The existing storage transition atomically changes
`confirmed` to terminal `dismissed` and appends one `cancel` event. Unknown or
no-longer-confirmed executions share one content-free unavailable outcome.
Unexpected admission shapes fail closed as inconsistent authority.

Storage serializes cancellation with `beginSkillExecution`. If revocation
commits first, begin observes the terminal state and no effect starts. If begin
commits first, revocation is unavailable because handoff may already have
started. A thrown mutation keeps the verified Waiting receipt and exposes an
inline retry; a verified revoked or unavailable result reloads both the
inspection and selected scope from storage. UI-test fixture and failure flags
are admitted only with the disposable temporary store.

**Consequences:** a user can stop one waiting run without granting Settings
enough information to execute or retry it, and every accepted revocation is a
durable causal event rather than optimistic presentation state. The action is
absent after begin, on terminal/failed receipts, and whenever inspection cannot
verify authority. This adds no schema, effect retry, proposal confirmation,
standing rule, background executor, adapter, transport, destination authority,
or egress consent. Physical VoiceOver behavior and cross-process race timing on
Sequoia and separate Tahoe hardware remain field evidence.

## D340 — Proposed review returns to context without moving consent (Aug 2026)

**Context:** D337 explained each content-free Proposed row and D338 let the user
dismiss it, but the copy only told people to find the original surface
themselves. A failed execution receipt cannot safely supply that path: it has
no subject, proposal arguments, preview, destination, or idempotency key, and a
remote failure may have an unknown outcome. Giving the bounded list a subject
identity would weaken its privacy boundary. Opening the main `WindowGroup` by
identifier alone would also create a duplicate library window whenever the
existing one was merely behind Settings. Finally, SwiftUI provides no public
action that programmatically presents a `MenuBarExtra`.

**Decision:** meeting and commitment rows expose **Review in context**.
SwiftUI sends only the unrelated review UUID to
`ResolveSkillOfferReviewDestination`. Storage resolves a current nonexpired,
nondismissed, individually enabled authority row in one snapshot and returns a
transient typed subject record. ApplicationKit revalidates Skill identity,
catalogue version, global pause, individual policy, reason, and subject shape,
then maps only to Meeting Detail, focused Commitment Radar, or the resident menu
bar. Missing, expired, disabled, dismissed, and concurrently retired rows share
one unavailable result. Malformed authority fails closed. No subject enters the
bounded review snapshot or remains in SwiftUI state after routing.

Navigation writes the existing inert `AppServices.pendingRoute`, opens the
primary scene, and dismisses Settings. The main `WindowGroup` now presents one
constant `MainWindowIdentity.primary` value; every programmatic open supplies
that value, so SwiftUI brings an existing main window forward or creates it only
when absent. Calendar rows show **Review in menu bar** as resident guidance and
do not attempt private status-item traversal or simulate a click. A thrown
resolution keeps the proposal row and exposes an inline retry.

**Consequences:** the central panel can return people to the surface that owns
the exact preview without becoming a confirmation or retry engine. Routing
alone cannot claim, begin, settle, choose a destination, or perform an effect;
the destination rebuilds and revalidates its own proposal. The change uses
public SwiftUI window APIs available below the macOS 14.4 floor and adds no
schema, stored content, receipt retry, standing rule, background executor,
adapter, transport, or egress authority. Physical VoiceOver behavior and real
window restoration on Sequoia and separate Tahoe hardware remain field
evidence.

## D341 — Failed-receipt recovery stores subject, never effect authority (Aug 2026)

**Context:** a failed execution receipt could explain its causal history but
could not safely return to the surface that owned its exact preview. The
execution projection stored only a proposal UUID, Skill identity/version,
idempotency key, state, attempt, and event tail. Parsing an idempotency key to
guess a meeting, commitment, or calendar owner would make an implementation
string into authorization. A generic Retry button would be worse: local
projection failure may be safe to review again, while a remote or destructive
failure may have crossed its handoff and already produced an outside effect.
Deleting the original meeting or commitment must also remove any navigation
authority without erasing the durable content-free receipt.

**Decision:** every executable `SkillDefinition` declares one
`SkillSubject.Kind`; every exact `SkillProposal` carries one matching valid
`SkillSubject`, represented exactly once in typed arguments and covered by the
definition's input-data declaration. Admission rejects a missing, duplicated,
mismatched, or invalid subject before the claim.

Schema v41 adds the current optional `failureCategory` to
`skillExecutionState`, backfills it from the exact latest failure event, and
uses triggers to require it if and only if state is `failed`. A separate
`skillExecutionSubject` row is written in the same confirmation transaction.
It contains only proposal UUID plus exactly one meeting, commitment, or bounded
opaque calendar identity. Meeting and commitment foreign keys cascade this row
when the subject is deleted; the execution state and event receipt remain.
Existing pre-v41 executions intentionally receive no subject backfill. Offer or
idempotency keys are never parsed, and confirming an existing proposal with a
different subject is rejected.

`LoadSkillReceiptInspection` classifies recovery only after replaying the
causal chain and reading current policy. External and destructive categories
are always **verify externally**. Other failures require a live subject, the
same currently available catalogue definition/version/subject kind, global
resume, and individual enablement. Meeting and commitment subjects may return
to context; calendar recovery stays in the resident menu bar. Missing, deleted,
legacy, stale, disabled, malformed, or unknown authority is unavailable.

Settings sends only the proposal UUID through
`ResolveSkillReceiptRecoveryDestination`, which repeats audit, policy, and
catalogue validation and returns at most an inert typed destination. SwiftUI
stores that destination until the receipt sheet's `onDismiss`, then sets the
existing `pendingRoute`. After the sheet has fully dismissed, the Settings root
opens the value-scoped primary window and invokes `close()` on its weakly
captured exact presenting `NSWindow`. The sheet's `DismissAction` owns only the
sheet, and both a presenter-root `DismissAction` and `dismissWindow` left the
Settings host open in real-app XCUITest. `NSApp.keyWindow` has already returned
to the primary scene by the time `onDismiss` runs, so process-wide inference is
also unsafe. The
original destination must reconstruct a fresh exact proposal and obtain a new
confirmation. A thrown resolution keeps the receipt and retries only
destination verification; no argument, preview, offer key, idempotency key,
destination, confirmation, claim, settlement, adapter, or effect port enters
the control center.

**Consequences:** a recoverable local failure now has an honest path back to
review without turning a receipt into reusable consent. Calendar and
outcome-unknown external work retain their stronger resident/verification-only
boundaries. Subject deletion revokes recovery navigation without destroying
audit history, and legacy rows fail closed rather than receiving guessed
authority. The migration and UI use APIs available below the macOS 14.4 floor.
Physical VoiceOver behavior, real external reconciliation, Sequoia, and
separate-hardware Tahoe behavior remain field evidence. Standing rules,
unattended execution, and central effect retry are still absent.

## D342 — Receipt dismissal restores context in the row-owned focus scope (Aug 2026)

**Context:** the Phase-2 Skills pane could open a receipt inspector and native
Escape dismissed it, but the presenting row had no explicit continuation
contract. A mouse-driven XCUITest on a host with macOS Keyboard Navigation off
also looked like a focus regression even though AppKit intentionally excludes
buttons from that focus mode. A raw `performAccessibilityAudit(.all)` was not a
usable gate: XCTest inspected the hidden primary window behind Settings and
reported unrelated native SwiftUI contrast, action, and hierarchy findings.
Recovery routing adds a second constraint because the Settings window closes;
restoring focus there would compete with the admitted destination.

**Decision:** the Settings root remembers only the exact inspected proposal
UUID. An ordinary sheet dismissal waits for AppKit to remove the modal focus
scope, confirms that the Skills pane is still present, and emits one bounded
focus request. A recovery destination clears both the remembered UUID and any
focus request before opening the primary scene and closing Settings.

`SkillActivitySection`, which owns the receipt controls, owns the matching
`FocusState` and `AccessibilityFocusState`. Its rows explicitly accept the
activation focus interaction and bind both focus channels to `proposalID`. The
request handler accepts an initial value because SwiftUI may reconstruct the
section after sheet dismissal, then yields once so the row targets exist before
applying focus. The receipt sheet itself receives no focus or navigation
authority, and every task is finite and guarded against a changed pane or a
replacement sheet.

The XCUITest runner enables macOS Keyboard Navigation only when the dedicated
focus journey or a full catalogue will run. It snapshots the exact prior global
preference and restores it on normal exit, interruption, hangup, or termination;
unrelated scoped suites do not mutate it. The journey scopes XCTest's sufficient-
description audit to identified Skills controls, proves native Escape dismissal,
and uses Space reopening the same receipt as the observable keyboard-focus
contract. Functional UI tests continue to cover native control actions instead
of accepting unrelated whole-process audit findings.

**Consequences:** keyboard and assistive users retain their exact position after
inspection without moving effect, subject, or recovery authority into Settings.
The change uses public SwiftUI APIs available at the macOS 14.4 floor and adds
no schema, storage read, retained window, AppKit introspection, standing rule,
retry, or effect execution. Deterministic automation proves the real app on the
current Tahoe-family host; physical VoiceOver, Sequoia, and separate Tahoe
hardware remain field evidence.

## D343 — Skills activity keeps policy and receipt truth independent (Aug 2026)

**Context:** the status-scoped activity UI rejected a snapshot from a different
scope, but it continued rendering rows from a matching snapshot while that same
scope refreshed. A verified revocation could therefore leave its old row visible
until storage returned. The combined control-center use case also threw away a
successfully read policy whenever the independent receipt query failed. Settings
then had no typed way to distinguish missing policy authority from unavailable
history, and receipt loading disabled controls whose policy was already verified.
Generic empty copy and silent asynchronous replacement made the transition less
clear for keyboard and VoiceOver users.

**Decision:** `LoadSkillControlCenter` starts policy and bounded receipt reads
concurrently but gives them separate outcomes. Policy failure still throws and
fails the pane closed. After policy succeeds, a non-cancellation receipt failure
returns that verified catalogue/policy, the requested scope, no rows, and an
explicit `SkillControlCenterReceiptLoadState.unavailable`. Cancellation always
propagates instead of becoming a partial result.

`SkillActivityPresentationState` is the single rendering boundary. Loading has
priority over a same-scope snapshot, followed by unavailable, verified empty,
and verified rows. Policy mutations may begin during a receipt load: they first
invalidate its UUID fence, then own the write and authoritative reload, so the
older task cannot publish afterward. Receipt loading does not disable verified
policy or proposal actions. Scope-specific empty titles never imply deletion.

The terminal empty and unavailable states are combined semantic elements and
request one localized medium-priority announcement with the public
`NSAccessibility.post` application notification. SwiftUI on the supported macOS
SDK has no live-region modifier, and the `updatesFrequently` trait would
misdescribe one-off status transitions, so loading is silent and Retry remains a
separate control. The delayed and failure fixtures are legal only with the
temporary UI-test store.

**Consequences:** changing activity scope and refreshing after a receipt mutation
hide stale rows immediately without sacrificing independently verified control
authority. Receipt-only failures no longer masquerade as policy failures or
verified emptiness. The slice adds no schema, unbounded read, central effect
retry, observer, retained accessibility object, timer, standing rule, or effect
authority. Automated semantics and bilingual real-app transitions are local
evidence; physical VoiceOver, Sequoia, and separate Tahoe hardware remain field
validation.

## D344 — UI gates observe host ownership without resetting it (Aug 2026)

**Context:** macOS XCUITest shares host-wide automation infrastructure. During
the D343 closure, one concurrent UI suite opened a SecurityAgent authentication
window and later unrelated Apple automation invalidated several app connections
without producing a Portavoz crash. The old preflight warned whenever Gancho
was merely running, queried only UserNotificationCenter through an unbounded
System Events AppleScript, and unconditionally killed `testmanagerd`. That
combination could miss the actual SecurityAgent blocker, hang while probing,
or disrupt a different repository's active suite while still allowing ours to
start into contaminated evidence.

**Decision:** the Make target gives only its own stale Portavoz Dev instance a
three-second bounded quit request, then delegates host classification to a
read-only checker. The checker takes
two snapshots one second apart and starts no XCUITest unless both are clean.
The process probe uses `ps` executable identity plus arguments to reject active
`xcodebuild test`/`test-without-building` commands and UI-test runners. It does
not reject an ordinary build, an idle XcodeBuildMCP server, unit-only `xctest`,
or the persistent `testmanagerd`, and it never terminates any of them.

A separate current-toolchain Swift 6 probe uses public CoreGraphics window-list
metadata available below the macOS 14.4 floor. It asks only for on-screen,
non-desktop owner and layer values, ignores Notification Center's negative-layer
desktop surfaces, and returns bounded counts for visible Notification Center
and SecurityAgent windows. It never reads `kCGWindowName`, bounds, dialog text,
controls, or credentials. The orchestrator applies explicit timeouts, validates
the exact JSON shape, and fails closed when either inventory is unavailable or
malformed. It reports only blocker categories and never dismisses a prompt.
The UI-test bundle installs no interruption monitor for external system
prompts, so it cannot answer a privacy or authentication decision that appears
after the final sample.

**Consequences:** already-present authentication alerts, notification alerts,
Xcode test commands, and UI runners now fail before Portavoz spends a build or
produces misleading product failures. The checker cannot reserve Apple's global
automation service: an unrelated client can still start after the second
sample, and a generic accessibility client may have no safe process signature.
Those cases remain result-bundle/host classification followed by a quiet-host
rerun, not evidence of a Portavoz crash. The LaunchServices claimant check
remains advisory because rebuilding that database is also a system-wide
mutation. No shipping binary, product permission, application behavior, or
minimum deployment target changes.

## D345 — Semantic performance evidence is comparable only through sealed identity (Aug 2026)

**Context:** SEARCH-0b still cited two apparently equivalent 100,000-vector,
512-dimension Release observations: 90.22 ms wall p95 from 17 July and 92.85 ms
from 26 July. Both name the same broad host and benchmark configuration, but
the earlier artifact has no toolchain and neither one retains source commit,
dirty state, built-binary identity, exact embedding profile, asset state,
fixture/query-pack identity, or stage boundaries. The runner also let the
performance ledger add toolchain metadata after measurement. Calling their
2.63 ms difference a regression, improvement, or noise would therefore assert
a cause that the artifacts cannot prove.

**Decision:** `bench-semantic` advances to observation schema 2. Each fresh
Release process records the exact `SemanticEmbeddingProfile`, whether the
Apple Latin assets are already installed under an explicit never-download
policy, the deterministic public-synthetic corpus/vector generator, the exact
present-vector query pack, and separate wall/process-CPU distributions for
store open, corpus seed, warmup queries, and measured queries. The measured
vectors remain deterministic normalized Float32 values; model assets qualify
the compatibility environment but do not generate the timed corpus.

`run-semantic-scale-baseline.sh` validates requested scales before building,
snapshots the source commit plus a twice-collected content digest over Git
status, the full tracked diff against `HEAD`, and every untracked path, mode,
size, symlink target, and content digest. It then builds one Release CLI and
binds its SHA-256 and size to the Apple Swift/Xcode target and exact
hardware/OS identity, then runs every scale in a fresh process. The strict
assembler rejects duplicate JSON keys, unknown fields, booleans masquerading
as integers, non-finite/non-monotonic or wrong-count distributions,
profile/configuration mismatch, incomplete top-k, corpus arithmetic drift,
cross-process host/profile/asset/fixture changes, or any source, binary,
toolchain, or host change after the build. Publication is owner-only and
atomic. The performance ledger may not restamp this sealed toolchain.

One recomputable comparability digest covers source, binary, toolchain, host,
build configuration, embedding profile, assets, fixture, query pack, stage
policy, configuration, and measured scales. Only the clean canonical
1k/10k/50k/100k matrix with 20 measured queries per scale is retention
eligible. A dirty or custom matrix can be compared only to another manifest
with the exact same digest and remains `comparable-development`. Identity
drift is `not-comparable`. The comparator reports only observations and
nearest-rank aggregates; its fixed decision authority is `none`.

**Consequences:** the tracked historical reconciliation preserves the exact
90.218/92.850 ms wall and 91.257/94.252 ms CPU observations but classifies the
pair `not-comparable` because schema 1 lacks required identity. That is the
honest reconciliation; no code can retroactively reconstruct missing evidence.
Future current-control claims require repeated clean schema-2 manifests on the
same stable host, followed by the existing profile/Sequoia/Tahoe field matrix.
This slice changes no product retrieval, ranking, schema, model, chunk, engine,
writer, scheduler, or user-visible behavior, and it does not close private
real-meeting answer quality or authorize SEARCH-4b/5 selection.

## D346 — Retain repeated semantic control only after measured-query stability (Aug 2026)

**Context:** D345 made individual Release manifests comparable but its general
comparator retained only the 100k query p95 values and an opaque identity hash.
It did not prove three observations existed at every scale, expose other stage
or footprint aggregates, or decide whether the query measurement agreed with
itself. Six clean observations from committed D345 source also showed why the
distinction matters: measured-query timing stayed tight while the third 100k
corpus seed was 1.41x the first two for one query variant and 1.64x for three.
Treating every undersampled lifecycle stage as stable would be false; omitting
the variation would be equally misleading.

**Decision:** add a separate `semantic-scale-control-baseline` receipt. It
accepts exactly three unique clean schema-2 manifests with one recomputed
identity, canonical 1k/10k/50k/100k scales, 20 measured queries per scale, and
either `queryVariants=1` or the explicitly diagnostic `queryVariants=3` shape.
Duplicate observations, dirty source, identity/configuration drift, unsupported
variants, missing scales, or measured-query wall/CPU p95-to-p50 or
across-observation max-to-min p95 above 1.25 produce no receipt.

The receipt retains the complete content-free identity payload, three raw
manifest digests, three distinct measurement-payload digests, and the
content-free per-observation distributions required to recompute every
count/size/footprint and wall/CPU summary. A receipt SHA-256 covers the retained
result. Only the 20-sample measured-query stage owns
the stability gate. Store open and corpus seed have one sample per process and
warmup has two, so their ratios stay explicit diagnostic evidence and cannot
pass or fail query stability. At 100k, the canonical receipt applies the
existing 100 ms wall-and-CPU current-control target. A three-variant receipt is
always diagnostic, has a separate identity, and receives no budget authority.
Neither receipt can claim cross-host coverage, retrieval/answer quality,
serving authority, or engine selection.

**Consequences:** three alternating clean D345 runs on Mac16,6 / macOS 26.5.2
produced canonical one-vector wall/CPU p95 maxima of 73.921/74.503 ms at 100k,
with within-run ratios at most 1.028/1.025 and across-run ratios 1.038/1.033.
The separate three-vector diagnostic measured 80.374/81.627 ms, with
within-run ratios at most 1.026/1.025 and across-run ratios 1.024/1.027. The
canonical current control therefore passes on this one reference host; no
cross-identity speedup or regression is derived. Raw manifests remain
ephemeral and only the two aggregate receipts are tracked. Stable comparable
evidence from the required 8/16 GiB profiles and both Sequoia/Tahoe families,
plus owner-supplied private quality evidence, remains required before chunk or
engine selection. `scripts/run-semantic-control-baseline.sh` makes the protocol
repeatable: it fails fast on a dirty checkout, alternates the one- and
three-vector matrices, rechecks source before publication, validates both
receipts, and writes them owner-only without retaining raw manifests.

## D347 — Cross-host semantic control requires real profile and OS receipts (Aug 2026)

**Context:** D346 proves the 100 ms current-control budget only on one 36 GiB
Mac16,6 running Tahoe. It defines no consumer that can combine aggregate
receipts without accidentally accepting the diagnostic three-vector identity,
mixing workloads, double-counting one memory profile, or promoting missing
Sequoia evidence into a pass. Rebuilding the later evidence tooling directly
inside the D345 source checkout would also make that source dirty and destroy
the identity the next host must reproduce.

**Decision:** add a self-verifying `semantic-scale-cross-host-matrix`. It
accepts one to three complete D346 aggregate receipts but only the canonical
one-vector scope. The required set is one receipt in each existing shared
resource profile: 7–10 GiB, 14–18 GiB, and at least 32 GiB reference memory.
The three receipts collectively cover macOS 15 Sequoia and macOS 26 Tahoe.
This follows the established cross-host contract; it does not silently expand
the requirement into every profile/OS Cartesian pair.

Source, clean state, Swift and Xcode version/build, Release configuration,
semantic compatibility profile, asset policy, synthetic fixture/query pack,
stage policy, and canonical scales must be byte-for-byte equivalent. Host
identity may differ. The Swift target is retained per receipt and must match
that host's architecture and OS major, so it is not falsely treated as one
cross-OS toolchain constant. The Release binary is likewise retained per host
and excluded from the shared workload identity. Duplicate receipts or
profiles, unsupported hosts, incoherent targets, and workload drift produce no
matrix. Cross-host qualification remains Apple-Silicon-only.

Every output embeds the validated aggregate receipts and exactly recomputes its
profile/OS coverage, shared workload identity, outcome, reasons, authority, and
matrix SHA-256. Missing profile or OS coverage is
`incomplete-required-matrix` with no cross-host authority. A complete matrix
may report only whether every receipt met the established 100 ms wall-and-CPU
current-control budget. It never derives a cross-host performance ratio or
claims retrieval quality, answer quality, chunk policy, serving authority, or
engine selection.

Both collectors separate their current validation-tool root from an optional
`PORTAVOZ_SEMANTIC_SOURCE_ROOT`. This lets field hosts use the D347 validator
while building a separate clean worktree at the exact D345 commit carried by
the reference receipt. Source inspection, Release build, binary hashing, and
measurement all remain rooted in that clean checkout.

**Consequences:** the first tracked matrix embeds only the real Tahoe/reference
receipt and is honestly 1/3 complete. It names 8 GiB, 16 GiB, and Sequoia as
missing and carries no cross-host budget authority. No unavailable hardware
evidence is fabricated, and SEARCH-0b remains open for those field receipts and
owner-supplied private real-meeting quality evidence.

## D348 — Retrieval chunks carry correction publication authority (Aug 2026)

**Context:** D202's pure speaker-turn candidate predates the immutable
correction overlay. Its `RetrievalChunk` carries the accepted transcript
revision but not D233's effective `TranscriptCorrectionRevision`. D330 and D334
now make accepted, replacement, split, and merge material independently
searchable, so any future chunk publication that cannot name the exact
correction overlay could reuse a candidate across different current text or
speaker authority. Treating the correction revision as chunk identity instead
would cause an unrelated correction elsewhere in the meeting to rebuild every
unchanged turn.

**Decision:** require every `RetrievalTurnChunker.chunks` call to provide a
typed correction revision and retain it on every derived `RetrievalChunk`.
The presentation-only `unavailable` sentinel is rejected. There is no default:
the uncorrected public benchmark passes `.accepted` explicitly, so a future
corrected caller cannot accidentally omit provenance.

Transcript and correction revisions are publication fences, not membership or
source identity. Neither enters the stable chunk ID or `sourceFingerprint`.
`RetrievalChunkDelta` compares current source membership and content exactly as
before, returns the current values for retained chunks, and therefore advances
both fences without scheduling an unchanged chunk for re-embedding. A text,
speaker, person, language, timing, or membership change still upserts only the
overlapping derived unit.

**Consequences:** the speaker-turn candidate is now correction-ready at its
pure ApplicationKit boundary without adding storage, a migration, an index
writer, product composition, or serving authority. Segment vectors remain the
shipping default. SEARCH-4b still lacks short conversational-window and
semantic-boundary candidates, paired quality/resource/correction evidence for
those strategies, and an accepted production-selection decision.

## D349 — Short conversation windows remain bounded evidence candidates (Aug 2026)

**Context:** D202 evaluates complete single-actor turns, but many meeting facts
depend on a short question/response exchange. Simply sliding a window over
turns would repeat canonical segments across ranked units. Observation schema
2 rejects that ambiguity because one source appearing at multiple ranks would
inflate retrieval evidence and make citation and hard-negative accounting
non-canonical. Flattening several actors into one apparent speaker would also
discard the topology the candidate is meant to test.

**Decision:** add a pure `conversation-window-v1` candidate derived only from
validated `speaker-turn-v1` chunks. It greedily emits non-overlapping windows
of at most three complete consecutive turns. Adjacent turns must resolve to
different actors, using confirmed person, meeting-local speaker, local
microphone, then isolated-turn identity precedence. A window keeps the
single-turn append budgets of 900 normalized characters, 45 seconds, and a 2.5
second inter-turn gap; exceeding any budget starts a new unit. An indivisible
canonical turn that already exceeds a budget remains isolated rather than
being split, truncated, dropped, or duplicated, so its cost remains explicit
candidate evidence.

Every `RetrievalChunk` now carries exact ordered turn boundaries in addition
to its flat canonical sources. Each turn retains source, speaker, person,
channel, language, and time authority, so a multi-actor window is context and
never one synthetic speaker. Conversation windows inherit turn validation and
the mandatory transcript/correction publication fences. Their stable identity
and source fingerprint are versioned independently; the correction revision
still remains outside rebuild identity.

The disposable Ask benchmark admits `conversation-window` as an explicitly
named candidate with its own adapter and deterministic projected identities.
The paired runner can select either registered candidate, and the comparator
continues to require the segment control while rejecting unknown candidate
adapters. Canonical sources never repeat across the candidate corpus. The app,
StorageKit schema, semantic maintenance owner, Library, Ask serving path, and
segment default remain unchanged.

**Consequences:** the public-synthetic-v2 topology projects each meeting into
one exact four-source conversation unit instead of two single-speaker turns,
making question/response context comparable through the existing production
retrieval path without weakening citation semantics. A text-only correction
that preserves turn topology and resource-bound window membership invalidates
only its containing window. A correction crossing a character append budget,
or a split, merge, insertion, removal, or actor change, can reflow later greedy
windows; that cost remains explicit candidate evidence rather than a false
locality guarantee. This slice adds candidate code and deterministic
comparison capability only; it does not claim quality parity, private-answer
quality, resource superiority, or serving authority. Clean paired
quality/resource/correction evidence and the separate semantic-boundary
candidate still precede any product-selection decision.

## D350 — Semantic boundary proposals fail closed before implementation (Aug 2026)

**Context:** SEARCH-4b still needs a semantic-boundary candidate, but selecting
a tokenizer or model first would bypass the citation and bilingual constraints
learned from the existing candidates. Splitting one transcript segment into
multiple sentence units would repeat its canonical source identity across
ranks, which observation schema 2 deliberately rejects. A multi-actor semantic
unit could also erase turn authority, and a language-specific sentence model
could silently compare English and Spanish vectors from unrelated spaces.
Apple's current Natural Language guidance directs semantic-similarity work
toward `NLEmbedding` sentence embeddings, while those embeddings are selected
by language and revision. The OS sentence tokenizer, by contrast, exposes no
model/revision identity suitable for stable cross-host candidate evidence.

**Decision:** add a pure `RetrievalSemanticBoundaryPreflight` contract in
ApplicationKit before implementing any semantic chunker. It grants only
benchmark admission. A proposal must carry a bounded lowercase identifier and
positive revision, operate on complete canonical turns, preserve ordered actor
topology, avoid source overlap, and use at least two turns without exceeding
the conversation-window ceilings of three turns, 900 characters, 45 seconds,
and a 2.5-second adjacent gap. Tighter bounds are allowed and fingerprinted.
Intra-source sentence fragments, product-serving scope, actor flattening,
overlap, non-finite limits, and an unversioned OS tokenizer fail closed.

The only admitted boundary signal is semantic similarity with a valid exact
`SemanticEmbeddingProfile` and a finite per-space cosine threshold in
`-1...1`. English and Spanish are mandatory. A proposal may explicitly declare
one shared bilingual vector space and threshold, or provide distinct language
profiles with independently calibrated thresholds that force a boundary at
every language transition and never compare cross-space vectors. Duplicate or
malformed languages, ambiguous reused partitioned profiles, and more than
sixteen profiles are rejected. A stable SHA-256 covers
the candidate, scope, source, actor, resource, threshold, language-space, and
model-profile identities; canonical sorting and signed-zero normalization keep
semantically identical proposals from acquiring different identities. No text,
query, vector, meeting, or source identifier enters that fingerprint.

**Consequences:** D350 selects the safety envelope, not a model or chunking
algorithm. The contract imports neither NaturalLanguage nor StorageKit, loads
no assets, derives no chunks, changes no schema, and is absent from the app and
serving composition. A declared shared-space capability still requires runtime
and quality evidence; admission cannot prove a model card or OS capability.
The current contextual embedder remains the shipping segment-vector authority,
and `NLEmbedding`, a pinned open model, or any other semantic-boundary signal
must first implement this contract and pass clean bilingual quality, resource,
correction-cost, and Sequoia/Tahoe comparison before any product decision.

## D351 — Semantic boundaries stay partitioned and benchmark-only (Aug 2026)

**Context:** D350 defines the safe proposal envelope but deliberately leaves
the concrete model, boundary algorithm, and evidence path open. Apple's current
sentence embeddings are selected by language: on the current Tahoe-family host
the English and Spanish sentence profiles expose different dimensions. Treating
them as one coordinate space would make cross-language cosine meaningless.
Materializing every meeting vector would also add avoidable memory cost to an
experiment whose decision depends only on adjacent complete turns. Finally, a
static adapter label would let a changed Apple revision, dimension, threshold,
or policy reuse incompatible quality receipts.

**Decision:** implement `RetrievalSemanticBoundaryChunker` as a pure
ApplicationKit, benchmark-only candidate over the existing validated complete
turns. It makes one forward pass and keeps only the current draft plus adjacent
vectors as boundary state. Every supported turn is vectorized once. Adjacent
turns join greedily only when they share one normalized primary language and
exact profile, meet that language's cosine threshold, and stay within the
conversation-window append ceilings. Source membership remains complete,
ordered, and non-overlapping; actor turns are never flattened. Missing,
unsupported, or mixed-language turns are isolated without vectorization, and
every English/Spanish transition is a boundary. The implementation refuses
shared spaces and fails closed on language, profile, dimension, finite-value,
or nonzero-magnitude disagreement.

Add `CLIAppleSentenceBoundaryEmbedding` as the sole concrete outer adapter. It
lives only in `portavoz-cli`, selects the exact current revision through
`NLEmbedding.sentenceEmbedding(for:revision:)`, verifies runtime language and
dimension, and never requests downloads. English and Spanish have distinct
`SemanticEmbeddingProfile` values and provisional cosine thresholds of 0.60
and 0.75. The thresholds are fingerprinted experimental inputs, not model
calibration claims. The exact adapter identity is
`semantic-v1.<proposal-sha256>`. The disposable quality mapping, evaluator, and
paired runner preserve and validate that dynamic identity while retaining all
canonical source members in observation schema 2.

**Consequences:** D351 adds deterministic candidate mechanics and a clean
evidence route, not a product choice. The app, StorageKit, semantic maintenance,
Ask serving, Library serving, and the canonical segment default remain
unchanged. The one-pass decision state avoids retaining a vector corpus, but
the canonical turn projection and output are still materialized, so this is not
a total constant-memory claim. A current-host live vector smoke proves only API
availability on that machine. The provisional thresholds and Apple profiles
must still pass clean paired bilingual quality, resource, correction-cost,
private-corpus, and physical Sequoia/Tahoe evidence before any serving or
storage proposal.

## D352 — Ask quality evidence rejects randomized ties (Aug 2026)

**Context:** three fresh Release processes ran the exact D351 segment control
and semantic-boundary candidate over `public-synthetic-v2`. All three retained
the same source identity, dynamic adapter, citation validity, Recall@10,
hard-negative count, and blocked candidate verdict, but several equal-rank
semantic hits exchanged positions. `LocalAskMeetingRetrieval` reduced every
segment to its best rank across query variants and then sorted a Swift
dictionary by rank alone. Dictionary iteration order is intentionally
process-randomized, so equal ranks leaked that randomness into user citations
and rank-sensitive quality metrics. The one-run pair orchestrator could not
detect the drift even though SEARCH-0b requires deterministic evidence.

**Decision:** preserve best-rank authority and break equal semantic ranks by
the earliest deterministic query variant, then by stable result UUID before
RRF. Non-tied semantic rank, lexical rank, scores, source projection, and
citation content do not change. The clean-pair
orchestrator now runs the segment control and selected candidate three times in
alternating fresh Release CLI processes. Each role must produce byte-identical
schema-2 observations before evaluation; any disagreement removes the private
staging directory and publishes no partial comparison. A sixth owner-only
`ask-quality-determinism` receipt records the run count and SHA-256 digests of
the two canonical observations and their comparison. The runner accepts only
three to five repetitions, defaults to three, keeps asset downloads disabled,
and retains the existing clean-commit and dynamic-adapter fences. CLI help must
list the semantic-boundary retrieval unit that D351 made executable.

**Consequences:** repeating the same local Ask query now gives equal-rank
evidence a stable order across processes, and candidate evidence cannot be
published from one lucky ordering. Previously arbitrary ties may move once to
their variant-then-UUID order; this is an explicit determinism fix rather than
a relevance claim. The three D351 diagnostic pairs remain blocked: the semantic
candidate improved aggregate retrieval and kept zero invalid/stale citations,
but added 39 hard-negative hits and regressed code-switched and same-language
relationship slices. No threshold is tuned from that one host, no candidate is
selected, and resource, correction-cost, private-corpus, Sequoia, and
independent Tahoe evidence remain open.

## D353 — Chunk resource evidence stays threshold-free (Aug 2026)

**Context:** D351 added a concrete semantic-boundary candidate, but the first
quality comparison carried no construction, memory, or correction-cost
evidence. Comparing one timing from a warm process would mix model preparation,
candidate construction, indexing, and serving lifecycles. It would also invite
a product or performance verdict from one synthetic corpus on one Tahoe-family
development host. Correction publication fences, representation-only text
changes, topology changes, and structural split/merge operations exercise
different invalidation behavior and must remain distinguishable.

**Decision:** add a CLI-only, content-free resource/correction observation for
the segment source control, `speaker-turn-v1`, `conversation-window-v1`, and
the dynamic `semantic-v1.<proposal-sha256>` candidate. One fresh process owns
one role. Concrete Apple model construction happens before measurement and
never requests asset downloads; the measured construction lifecycle begins at
candidate derivation and ends before any persistent index write or query. It
reports wall time, process CPU, baseline/peak/ending physical footprint,
resulting unit/source/turn counts, and semantic boundary counters. It never
emits transcript text, meeting/source/unit identities, vectors, model names,
queries, or paths.

The correction matrix rebuilds only one deterministic meeting and records
construction cost plus retained, upsert, and removed unit counts for publication
fences, Unicode/whitespace-equivalent text, replacement text, actor and language
changes, and structural split/merge. Semantic vector calls remain separate from
delta upserts because this benchmark candidate has no incremental vector cache
or product writer. The clean orchestrator binds observations to fixture digest,
source commit, Release build, toolchain digest, explicit host profile, runtime
OS, hardware shape, and dynamic adapter. It rotates all four roles across three
to five fresh processes, requires exact structural agreement while retaining
raw timing samples, publishes owner-only non-overwriting artifacts, and leaves
candidate selection and performance `not-evaluated`. No numeric pass threshold
is derived.

**Consequences:** the canonical public-synthetic-v2 corpus produces 120
complete turns but zero baseline semantic vector calls: every turn either
contains mixed English/Spanish source metadata or carries the explicit mixed
sentinel, so the partitioned candidate correctly refuses cross-space cosine.
The clean receipt must therefore be `blocked` for semantic resource coverage
rather than laundering model-load footprint into vector-construction evidence.
The matrix still characterizes deterministic unit and correction invalidation
mechanics for every role. A separate public, truthful bilingual resource fixture
with homogeneous complete turns, plus physical Sequoia and independent Tahoe
hosts and owner-reviewed private evidence, is required before resource review.
This decision changes no app composition, StorageKit schema, semantic writer,
Ask/Library serving path, product default, threshold, or engine authority.

## D354 — Bilingual semantic resource coverage uses a separate warm fixture (Aug 2026)

**Context:** D353 correctly blocked semantic resource review because the judged
Ask quality fixture has no homogeneous complete turns. Rewriting that fixture
to make a resource benchmark pass would silently change the multilingual
quality corpus. D353 also constructed the two Apple sentence-embedding objects
before sampling, but its zero-vector corpus never exercised either language
path. A runtime that performs meaningful work on first `vector(for:)` could
therefore place first-use cost inside the measured candidate stage once a new
fixture reached those paths.

**Decision:** keep `public-synthetic-v2` unchanged and add a separate canonical
`public-bilingual-homogeneous-v1` resource fixture. Its deterministic generator
owns 60 meetings, 480 sources, and 240 complete two-source turns: 120 English
and 120 Spanish. Four distinct actors per meeting preserve every D353
correction scenario. The verifier requires the exact public generation and
rejects duplicate JSON keys, unknown fields, repeated identities, meeting/order
drift, unsafe bounds, and mixed-language turns. The CLI owns a separate bounded
Swift loader rather than importing quality-query semantics into resource work.

Version the observation and receipt to schema 2. The semantic role admits the
proposal and validates one fixed public-synthetic English vector and one fixed
public-synthetic Spanish vector before any resource sample. The warmup phrases
are not fixture text; preparation counts are content-free and nonsemantic roles
must report zero. Baseline footprint includes the prepared runtime while first
model use remains outside incremental construction samples. The collector binds
the exact fixture generation and homogeneous-language counts, rejects duplicate
or nonstandard observation JSON and cross-role host drift, derives the fixture
digest from the exact byte snapshot accepted by the verifier, rechecks clean
source after compilation and before publication, and blocks any semantic
construction count below all 240 turns. Complete coverage yields
`review-required`, not `pass`; no timing floor or cross-engine ratio is added.

**Consequences:** public resource characterization can now exercise both
language-partitioned vector spaces without weakening quality provenance or
prewarming the actual measured turns. Schema-1 D353 artifacts remain historical
and cannot mix with schema-2 evidence. A `review-required` receipt proves only a
complete, warm, content-free one-host construction/correction matrix. It does
not prove model quality, performance superiority, private-corpus behavior,
physical Sequoia, independent Tahoe hardware, cross-host stability, persistent
indexing, serving, or product acceptance. The app, StorageKit, Ask, Library,
semantic maintenance, segment default, provisional thresholds, and engine
authority remain unchanged.

## D355 — Nemotron Latin remains a pinned non-serving live challenger (Aug 2026)

**Context:** `bench-live` already gives live engines the same real-time pacing,
finalization-lag, WER/CER, and JSON evidence boundary, but Parakeet had no
executable open-model challenger. FluidAudio 0.15.5 now exposes a multilingual
Nemotron streaming manager and an upstream Latin 1120 ms CoreML build. Importing
the whole repository would add unused preprocessors and decoder variants, a
moving branch would make later evidence irreproducible, timestamp-based delta
deduplication can drop RNN-T tokens that share a time, and placing an
unqualified candidate in app composition would turn upstream claims into a
product decision. Its OpenMDW-1.1 terms also require owner review before
distribution policy can be accepted.

**Decision:** add one research-only `ModelCatalog.nemotronLatin1120` descriptor
pinned to exact revision `1a41b75758b0337ff67db7d5408280aaaf23074e` and ten
individually sized and SHA-256-pinned artifacts: encoder, fused decoder/joint,
metadata, and tokenizer. FluidAudio's native Swift mel path and fused B1 decode
make all other repository artifacts inapplicable. Add
`NemotronLatin1120Engine`, which preloads one immutable shared model set and
creates all converter, cache, prediction, and decoder state per stream. The
adapter accepts only an explicit English or Spanish hint, rejects vocabulary
prompts it cannot honor, validates finite positive PCM and finite monotonic
token intervals, consumes cumulative timings with an integer cursor, finalizes
once, and cleans up on success, failure, or cancellation. The shared live
benchmark must propagate engine/file errors rather than score or write a
partial hypothesis; it rejects invalid duration/audio, cancels and drains its
real-time feeder on error, and fails if an engine ends before input completion.

Expose the candidate only as the exact opt-in CLI value
`bench-live --engine nemotron-latin-1120`. Validate its hints before model
download, then reuse the existing reference and JSON harness unchanged.
`ModelCatalog.recommended(for: .liveTranscription)` continues to return
Parakeet, and the macOS app, recording flow, scheduler, residency ledger,
Settings model UI, and durable recovery do not reference Nemotron. Gated
real-model coverage requires a separately installed verified model and explicit
environment opt-in; ordinary tests and XCUITest never download it.

**Consequences:** Portavoz now has reproducible challenger plumbing and unit
ratchets for artifact scope, default routing, language/capability admission,
stable delta projection, malformed model output, and final deduplication. It
does not yet have a Nemotron Portavoz quality result, model-residency/thermal
result, physical Sequoia/Tahoe result, code-switching acceptance, or approved
OpenMDW redistribution/attribution decision. The descriptor's rounded 0.02
real-time factor reflects an upstream machine-dependent aggregate and is never
Portavoz evidence. Parakeet remains the live product authority unless the
owner-reviewed bilingual matrix wins within the existing D7/D137 latency and
resource budgets and the license review is explicitly accepted.

## D356 — Legacy CLI input is bounded before side effects and capture tasks drain (Aug 2026)

**Context:** the original development CLI commands parsed numbers with
`Int`/`Float`/`Double` plus a fallback to the current default. Malformed values
therefore looked successful, while negative recording or benchmark durations
could later trap when converted to `UInt64`. Negative FTS corpus dimensions
could trap in ranges or allocation, their product could overflow, and a
negative Ask limit could behave as an effectively unbounded request. The
recording and concurrent M2 harnesses also created unstructured work whose
cancellation and startup-failure ownership was incomplete. Newer evidence
commands already have strict typed option structs, but importing another direct
argument-parser dependency solely for these internal commands would not repair
their capture lifetimes.

**Decision:** retain the small hand-written development dispatcher and add one
shared throwing value reader for its seven legacy commands. It rejects missing
or empty strings, a following option in place of a value, malformed and
non-finite numbers, and values outside explicit closed bounds before any model,
database, capture, file, or corpus work begins. Durations are 1 through 86,400
seconds, Ask limits 1 through 50, process IDs positive `pid_t` values,
diarization thresholds strictly between zero and one, DER collars zero through
60 seconds, meetings 1 through 100,000, and segments per meeting 1 through
10,000. FTS corpus size uses checked multiplication and has a separate
1,000,000-segment ceiling.

Use clock durations with `Task.sleep(for:)` rather than converting unchecked
user input to nanoseconds. The recording command finishes every channel stream
and awaits each live transcription; failure or cancellation first stops
capture, then cancels and drains those jobs. The M2 harness creates its batch
task only after microphone startup succeeds. Its cancellation path stops the
microphone, finishes the feed, cancels the feeder/consumer and batch work, and
awaits both top-level jobs. Its successful measurement still drains the live
feed and waits for the already-running batch pass so the acceptance report does
not change semantics.

**Consequences:** invalid legacy options fail closed instead of selecting a
default, trapping in a numeric conversion, or allocating an attacker-sized
synthetic corpus. Returning from a cancelled capture command no longer means
owned capture/transcription work may still be running. The helper is not a
promise that the development CLI has a stable public argument ABI, and this
decision does not change the app, MCP protocol, production schedulers, model
selection, or product behavior. Real microphone, process-tap, and concurrent
model evidence remains hardware- and permission-dependent; unit and source
ratchets cannot certify those field conditions.

## D357 — Existing encrypted voice data requires explicit recovery (Aug 2026)

**Context:** the local voiceprint and remembered-participant gallery are
biometric data split between AES-GCM ciphertext and a device-only Keychain key.
Their read paths treated an existing file with a missing key as absent or empty,
and gallery mutations additionally converted every decrypt, authentication, or
decode failure into an empty collection. A later enrollment, remember, or
remove action could therefore create a replacement key and overwrite or delete
the only encrypted identity evidence. Both stores also force-unwrapped the
sealed representation. Settings swallowed the user's own status failure, and
the remembered-voices view attached its initial load to a conditional group
that could render no child, so neither the gallery nor its failure was
guaranteed to appear.

**Decision:** use one shared storage boundary for both encrypted voice stores.
If ciphertext already exists, key creation is forbidden: missing and malformed
key material are typed failures, and unreadable ciphertext, authentication, or
decoding failures propagate unchanged. Every gallery mutation must decrypt and
decode the authoritative collection before constructing a replacement. Guard
the AES-GCM combined representation rather than force-unwrapping it. Only the
existing explicit delete/reset actions may remove the unreadable file and key;
after that boundary, a fresh key and enrollment/gallery are allowed.

Settings must present unreadable own-voice and gallery state without claiming
that anything changed. It offers a separate retry and explicit destructive
reset, retains any already verified gallery rows on reload failure, and renders
an initial loading anchor so the first asynchronous read always starts. The
deterministic unavailable fixture is conjunctively gated by `-use-temp-store`;
it can exercise the real Settings journey but cannot inspect or mutate host
Keychain or biometric files.

**Consequences:** losing or corrupting Keychain material no longer authorizes
silent biometric replacement, and corrupt ciphertext can no longer become an
empty gallery during mutation. The user must deliberately discard unreadable
identity state before reenrolling, because Portavoz cannot recover plaintext
without the original key. This changes neither voice matching, thresholds,
automatic-name admission, synchronization policy, nor model lifetime. Unit and
real-app automation prove fail-closed preservation and recovery presentation;
they do not prove a real Keychain-reset journey, recover lost biometric data,
or replace physical Sequoia/Tahoe and VoiceOver evidence.

## D358 — Encrypted voice identity mutations are serialized across processes (Aug 2026)

**Context:** D357 made each encrypted read fail closed but did not make a
multi-step mutation indivisible. Two `VoiceGallery` values could both decrypt
the same collection and atomically replace it in succession, silently losing
one newly remembered participant. An own-voice save could also cross a delete
between its file and Keychain operations and leave ciphertext without its key.
App adapters execute these synchronous capabilities on independent utility
tasks, and the stable app, Dev app, and CLI may share the same local identity
root. A Swift actor or in-memory mutex would protect only one instance/process;
`Synchronization.Mutex` additionally requires macOS 15 while the package still
compiles for macOS 14.4.

**Decision:** guard each encrypted identity payload with a persistent,
content-free sidecar (`voiceprint.lock` or `voice-gallery.lock`) and hold one
exclusive BSD `flock` lease across the complete authoritative transaction:
file-presence recheck, Keychain read/create/delete, decrypt/decode,
read-modify-write, encryption and atomic replacement, or payload deletion.
Open the sidecar with `O_CLOEXEC | O_NOFOLLOW`, force mode `0600`, retry
`EINTR`, and fail before touching identity state when open, permission, or lock
acquisition fails. The sidecar remains after explicit reset so reset and save
cannot cross. A public `exists` property remains only a momentary UI/test
snapshot and is never mutation authority.

Keep the capability API synchronous and the existing app adapters on their
utility executor. Once a transaction has been admitted, caller cancellation
waits for that short file/Keychain boundary rather than splitting it. The file
descriptor releases the advisory lock on scope exit, thrown error, or process
termination.

**Consequences:** gallery additions/removals are linearizable per payload even
across separately constructed stores and processes, while own-voice save/load/
delete cannot interleave their ciphertext and key halves. Independent files do
not block each other, the lock stores no biometric material, and no macOS
15-only synchronization API raises the deployment floor. Deterministic tests
hold one store inside the secret boundary and prove a contender cannot enter,
then verify both gallery updates survive and save-then-delete leaves neither
file nor key. They also verify empty mode-`0600` sidecars and fail-closed
symlink handling. Automation does not replace a physical stable/Dev/CLI
abrupt-termination exercise on Sequoia and Tahoe. BSD locking is advisory, so
a still-running pre-D358 process does not cooperate; mixed-version exclusion
remains an operational constraint rather than a data-migration guarantee.

## D359 — Verified non-failed Skill receipts may reopen their exact source (Aug 2026)

**Context:** the Skills control center could inspect every causal execution
receipt, revoke a run still waiting for handoff, and return a failed local run
to a fresh recovery review. A succeeded, executing, waiting, or cancelled
receipt still became a dead-end even when schema v41 retained a current exact
meeting or commitment owner. Reusing failed-run recovery for this broader
journey would incorrectly make historical evidence depend on current pause or
enablement policy, while resolving subjects in SwiftUI would expose authority
and duplicate the existing inert navigation boundary.

**Decision:** classify source context independently from failed-run recovery.
After replaying the bounded causal audit, a non-failed receipt may expose a
meeting or commitment route only when its current subject is valid, its owner
still exists, and its Skill identity, catalogue version, availability, and
subject kind still match. Calendar receipts remain resident menu-bar guidance
because public SwiftUI has no supported `MenuBarExtra` opener. Historical
source review deliberately ignores global pause and individual disablement;
failed receipts retain D341 recovery policy, including external/destructive
verification-only behavior.

Resolve the action through a proposal-UUID-only ApplicationKit use case that
depends on the content-free audit-reading port, not execution policy. It may
return only the existing inert `SkillOfferReviewDestination` and may not
confirm, claim, begin, settle, retry, or perform an effect. Settings generalizes
its weak-window source/recovery bridge but still receives no subject, offer key,
idempotency key, arguments, preview, destination content, result, or effect
port. A failed route keeps the receipt, causal evidence, independent Waiting
revocation, and a route-only retry.

**Consequences:** existing execution evidence can lead back to the exact place
that explains it even when future Skill execution is paused, without turning
Settings into an execution surface. Deleted or legacy subjects, stale catalogue
versions, mismatched kinds, malformed histories, failed receipts on the general
route, and calendar subjects without a public opener fail closed. Deterministic
unit and bilingual real-app tests cover successful and failed routing and prove
the execution history is unchanged; physical VoiceOver, Sequoia, separate-
hardware Tahoe, and resident menu-bar interaction remain field evidence.

## D360 — Re-admit an unsatisfied graph profile without inventing authority (Aug 2026)

**Context:** the graph maintenance operation fingerprint deliberately combines
kind, target profile, and authoritative source generation. That makes duplicate
admission idempotent, but it also made one binary-downgrade sequence terminal:
after canonical → alternate → canonical at an unchanged source generation, the
second canonical admission found its old `succeeded` row, claim found no
`pending` work, and the projection remained unavailable until an unrelated
authority mutation created another operation fingerprint. A cancelled target
could stall the same way. Advancing source generation for a profile request
would falsely describe derived policy as authority; deleting the old job or
adding a random operation identity would discard deterministic idempotency.

**Decision:** keep the existing operation fingerprint and make readmission a
narrow graph-only scheduler policy. Inside the same admission transaction that
cancels obsolete pending work, reload and fully validate the exact persisted
job. If its state is `succeeded` or `cancelled` and the current projection still
requires that target — because its active profile differs or invalidation rows
remain — move the same row back to `pending`. Preserve job ID, operation
fingerprint, target profile, source generation, and creation time; reset attempt
to zero, apply the current bounded maximum, and clear prior scheduling, lease,
error, start, and finish state. `pending` and `running` jobs are not rewritten,
and `failed` remains terminal so repeated profile selection cannot bypass the
bounded failure policy. Semantic maintenance retains its original no-readmit
policy.

The first profile-reset batch clears all disposable edge tables, including the
later decision-topic family, then reseeds every authority scope under the
existing lease/publication fence. No schema migration, authority write, source-
generation advance, polling loop, graph engine, answer composition, sync field,
CLI, MCP, or UI control is added.

**Consequences:** completed and cancelled graph targets recover deterministically
across repeated same-generation profile transitions while keeping one exact
durable operation identity. Checkpoint/resume, expired-owner recovery,
capture-yielding batches, snapshot fail-closure, and failure bounds are
unchanged. Focused projection tests prove completed and cancelled readmission
plus terminal-failure exclusion; the always-on scale invariant now resets
alternate → canonical and compares all
authority-keyed edge sets, including decision-topic aboutness. Released Ask and
field-evidence limits remain separate.

## D361 — Release one exact graph query before natural-language inference (Aug 2026)

**Context:** all six Meeting Memory Graph jobs crossed public Core, Storage,
projection, and ApplicationKit boundaries, but no released query surface used
them. Free-form extraction would have needed to guess a job and possibly a
person alias before the user could verify identity. It would also have coupled
the first graph result to model availability even though the exact typed facts
and source evidence already existed. Foundation Models is unavailable on
Sequoia and may be unavailable by policy or setup on Tahoe.

**Decision:** add a separate **By person** surface to the full Ask window rather
than changing free-form Ask. Search the existing protected canonical-person
SQLite catalogue with a 21-row request, display at most 20 rows plus overflow,
and accept only one exact currently displayed `PersonID` selected by the user.
Do not parse question text, infer aliases, merge identities, or fall back to a
nearby person.

Pass that identity directly to `LoadPersonCommitments` with its maximum
100-fact bound. Before presentation, validate the complete page through
`AskGraphFactSynthesisPage` and require every row to be an active
person-to-commitment relationship whose subject is the selection and whose
object matches its commitment ID. Render the typed fact directly with
truncation and omission disclosure; every source action reuses the exact
meeting-and-timestamp route. Keep canonical-person and commitment tasks under
independent per-window cancellation and generation fences. A temporary-store
XCUITest fixture may project one real disposable confirmed event because the
background projector is deliberately disabled for temporary stores.

**Consequences:** one of six graph jobs now has a released, source-backed,
identity-safe UI without Foundation Models on Sequoia or Tahoe. The graph-aware
answer bundle, exact alias-filter boundary, free-form Ask, command palette,
CLI, MCP, and meeting briefs remain unchanged and transcript-only. The other
five dedicated job surfaces, natural-language extraction, private evidence,
sync/export, telemetry, physical VoiceOver, clean-install Sequoia, and
separate-hardware Tahoe validation remain open. This decision does not create
new graph authority, write user data, select another graph engine, or claim
private-corpus answer quality.

## D362 — Release current decisions behind one exact topic selection (Aug 2026)

**Context:** D361 proved the first identity-safe graph consumer through a
canonical person selector, while the roadmap still prioritized topic/history
before any free-form graph inference. `LoadDecisionHistory` already served
current confirmed decisions for one exact topic family, but the only public
topic lookup was exact-alias authority and the broad linkable-topic read would
hydrate the full active catalogue. Reusing either directly for typeahead would
mix mutation semantics with presentation or introduce an unbounded Swift read.
Guessing a topic from question prose would recreate the ambiguity D361 avoided.

**Decision:** add a read-only `LoadConfirmedTopicCatalog` ApplicationKit
boundary with a 1...50 result bound and 120-character normalized-query bound.
Storage searches active normalized aliases, escapes literal wildcard input, and
uses one recursive SQLite CTE to resolve matched merged children to distinct
live roots before stable ordering, limiting, and Swift hydration. Empty input
returns only bounded live roots. Catalogue text remains discovery metadata and
never authorizes a fact; full Ask accepts only one exact currently displayed
`TopicID` selected by the user.

Add **By topic** as a separate full-Ask surface. Pass that exact identity to
`LoadDecisionHistory` with its existing 100-fact maximum. Before presentation,
validate the complete page through `AskGraphFactSynthesisPage` and require every
row to be a confirmed decision-about-topic relationship whose object and live
label match the selection and whose primary evidence exists. Keep catalogue and
decision tasks under independent per-window cancellation and generation fences;
oversized, duplicate, merged, malformed, wrong-topic, or incomplete responses
fail closed. Reuse the existing exact meeting-and-timestamp evidence route.

**Consequences:** two of six graph jobs now have released source-backed,
identity-safe SwiftUI consumers without Foundation Models on Sequoia or Tahoe.
A deterministic temporary-store fixture confirms a real summary decision about
a real topic, projects the disposable graph, and bilingual XCUITest follows its
evidence. No schema, authority write from the explorer, FTS table, graph engine,
model prompt, sync/export field, CLI, MCP, palette, brief, or free-form Ask
behavior is added. The substring catalogue returns and hydrates only a bounded
page, but SQLite may still scan active aliases for a leading-wildcard match;
measure a materially larger topic catalogue before selecting FTS, prefix-only,
or another index. The other four dedicated jobs, private evidence, telemetry,
physical VoiceOver, clean-install Sequoia, and separate-hardware Tahoe remain
open.

## D363 — Release first confirmed discussion inside exact topic memory (Aug 2026)

**Context:** D362 already established a bounded, alias-aware topic catalogue and
required the user to choose one canonical live `TopicID`. Four dedicated graph
jobs remained without released presentation. `LoadTopicFirstDiscussion` was the
next coherent topic journey because its authoritative earliest occurrence,
source evidence, typed abstention, and six-case canonical conformance were
already implemented. Adding another top-level Ask surface would duplicate topic
identity selection, while calling the result “first ever” would overstate an
explicit-confirmation boundary.

**Decision:** extend the existing **By topic** surface with a subordinate
**Current decisions / First confirmed discussion** selector. Pass only the
user-selected `TopicID` to `LoadTopicFirstDiscussion`; topic search text remains
discovery metadata and no model or natural-language resolver chooses authority.
Keep one generation-fenced fact task shared by the two jobs so changing the job,
topic, Ask surface, or window cancels and rejects late results.

Admit a first-discussion result only when `AskGraphFactSynthesisPage` validates
it and the page is complete: exactly one confirmed topic-to-meeting fact for the
selected topic, exactly one current primary source, matching object/source
meeting identities and titles, and an occurrence timestamp equal to meeting
start plus the source segment offset. Any extra fact/source, pagination,
omission, entity mismatch, or temporal mismatch fails closed. Render the exact
meeting, date, and source navigation with the narrower phrase **first confirmed
discussion**.

**Consequences:** three of six dedicated graph jobs now have released,
source-backed, identity-safe SwiftUI consumers without Foundation Models or a
Tahoe-only API. The existing disposable confirmation fixture can exercise the
new path through independent English and Spanish XCUITest and exact evidence
seek without mutating storage authority. No schema, new search index, graph
engine, model prompt, sync/export field, CLI, MCP, palette, brief, or free-form
Ask behavior is added. Active blockers still need an exact commitment selector;
decision conflicts and change-since still need bounded decision/meeting anchors.
Private evidence, telemetry, physical VoiceOver, clean-install Sequoia, and
separate-hardware Tahoe validation remain open.

## D364 — Release confirmed decision changes inside exact topic memory (Aug 2026)

**Context:** D362–D363 already give one canonical live `TopicID` an exact
current-decision and first-confirmed-discussion journey. Three dedicated graph
jobs remained without presentation. `LoadDecisionConflicts` was the next most
cohesive consumer because it needs only that same exact topic identity and its
source-backed reader, while active blockers still need an exact commitment
selector and change-since needs a second exact meeting anchor. Adding another
top-level Ask surface or inferring a topic from prose would duplicate selection
or weaken authority.

**Decision:** add **Decision changes** as the third subordinate **By topic**
job. Pass only the selected `TopicID` and the existing 100-fact maximum to
`LoadDecisionConflicts`. Keep the single topic fact task and generation fence,
so changing the job, topic, Ask surface, or window cancels the read and rejects
late results. Topic labels remain discovery metadata; no model chooses graph
authority.

Before presentation, require `AskGraphFactSynthesisPage` to validate the page
and every row to be one confirmed decision-relationship event with distinct
successor and replaced decision identities, nonempty statements, at least two
exact current source segments, and one exact primary source. Render the
successor as **Changed to**, the prior statement as **Replaced**, retain all
evidence, and place the successor's primary source first for navigation.
Preserve pagination and stale/unavailable omission disclosure. Treat
`unsupportedConflict` as an honest no-confirmed-change state, not a vague query
failure.

**Consequences:** four of six dedicated graph jobs now have released,
source-backed, identity-safe SwiftUI consumers without Foundation Models or a
Tahoe-only API. A deterministic temporary-store fixture confirms an unlinked
earlier decision, links the successor to the exact topic, confirms their
supersession, projects the real disposable graph, and lets independent English
and Spanish XCUITest verify both statements, both sources, and the successor
seek. No schema, authority write from the explorer, search index, graph engine,
model prompt, sync/export field, CLI, MCP, palette, brief, or free-form Ask
behavior is added. Exact active blockers, exact topic-plus-meeting change-since,
private evidence, telemetry, physical VoiceOver, clean-install Sequoia, and
separate-hardware Tahoe validation remain open.

## D365 — Release active blockers behind one exact current commitment (Aug 2026)

**Context:** D361 already lets a user select one canonical `PersonID` and load
that person's current confirmed commitments. After D364, two dedicated graph
jobs remained without presentation. `LoadCommitmentBlockers` already accepted
an exact `CommitmentID`, returned only active source-backed causal authority,
and needed no new identity catalogue; change-since still needs a separately
designed exact meeting-anchor selector. Inferring either a commitment or
causality from prose would weaken the explicit authority model.

**Decision:** add **Show active blockers** to each validated commitment card in
**By person**. Start the bounded `CommitmentBlockerQuery` only when the exact
identity is still present in the current person-commitment result. Give the
nested read its own weak task and generation fence; changing person, reloading
commitments, selecting another commitment, changing Ask surface, or closing the
window cancels and rejects late publication.

Before presentation, require `AskGraphFactSynthesisPage` to validate the page
and every row to be an active decision-to-commitment fact whose object identity
and title equal the selected current commitment. Preserve all exact sources and
present the fact's blocker-confirmation source first. Do not require two
citations: storage legitimately deduplicates evidence when commitment and
blocker authority share one segment, but that exact primary blocker segment
remains mandatory. Render unsupported causality as an honest no-active-blocker
state, distinct from malformed evidence and operational failure.

**Consequences:** five of six dedicated graph jobs now have released,
source-backed, identity-safe SwiftUI consumers without Foundation Models or a
Tahoe-only API. A temporary-store-only fixture confirms the commitment, a
separate Spanish decision, and their causal blocker, then projects the real
disposable graph. Independent English and Spanish XCUITest verify both exact
sources and follow the blocker primary source to 00:04 using synthetic audio.
No schema, authority write from the explorer, inferred causality, search index,
graph engine, model prompt, sync/export field, CLI, MCP, palette, brief, or
free-form Ask behavior is added. Exact topic-plus-meeting change-since, private
evidence, telemetry, physical VoiceOver, clean-install Sequoia, and separate-
hardware Tahoe validation remain open.

## D366 — Release change-since behind exact topic and meeting selection (Aug 2026)

**Context:** D361–D365 released five identity-safe graph consumers. The final
dedicated job, `LoadChangeSince`, already required one exact `TopicID` and one
exact `sinceMeetingID`, but its result does not echo the temporal baseline.
Inferring “last meeting” from question prose or restricting the anchor to a
topic-related meeting would add unsupported authority. Adding its catalogue and
cards directly to the already large topic files would also create avoidable
presentation and testing risk.

**Decision:** add **Changes since** as the fourth subordinate **By topic** job.
Reuse `LoadAutomationEntities.meetings` as a bounded, newest-first, title-only
discovery catalogue: request 21, display 20 plus overflow, and allow only a
currently visible exact `MeetingID` to enter `ChangeSinceQuery` beside the
already selected exact `TopicID`. Accept any live meeting as the baseline. Show
`endedAt` when present and otherwise `startedAt`, exactly matching StorageKit's
temporal contract; reject invalid aggregate dates and catalogue shape.

Own meeting discovery in a focused per-window weak cancellable model. Changing
topic, job, meeting query, or exact anchor clears facts and cancels the request;
publication must still match topic, anchor, job, and generation because the
result cannot validate the baseline itself. Reuse one strict decision-
relationship preparation and rendering boundary for decision conflicts and
change-since, preserving distinct endpoints, at least two exact current
sources, the successor primary source, and typed page disclosure. Replace the
three-way segmented job picker with a native radio group so four localized jobs
remain legible and follow standard macOS accessibility behavior.

**Consequences:** all six dedicated graph jobs now have released, source-backed,
identity-safe SwiftUI consumers without Foundation Models or a Tahoe-only API.
The existing temporary fixture already contains an exact earlier **Planning
baseline** meeting and later confirmed replacement, so bilingual XCUITest can
select the baseline, verify both Spanish statements and both sources, and seek
the successor at 00:03 without new schema or user data. No graph authority,
natural-language inference, search engine, model prompt, sync/export field,
CLI, MCP, palette, brief, or free-form Ask behavior is added. Private owner-
reviewed evidence, telemetry, physical VoiceOver, clean-install Sequoia, and
separate-hardware Tahoe validation remain open.

## D367 — Observe exact graph query timing without content (Aug 2026)

**Context:** D361–D366 released identity-safe product consumers for all six
exact Meeting Memory Graph jobs. The relational harness supplies deterministic
synthetic scale evidence, but the live product had no per-job timing boundary
from which to collect supported-host receipts. Reusing the general Ask pipeline
taxonomy would mislabel direct exact reads and could encourage question or
evidence payloads. Starting timing before alias resolution would also record an
ambiguous identity lookup as an authorized person query.

**Decision:** define a separate ApplicationKit observation port with a closed
six-job taxonomy: commitment blockers, topic first discussion, person
commitments, decision conflicts, change since, and decision history. A trace
contains only a random process-local UUID and its job. Completion contains only
facts, abstained, cancelled, or failed. The disabled adapter remains the
default.

Measure the repository boundary inside each exact use case. For alias-based
person commitments, start only after exactly one candidate resolves. Compose
the shared graph-fact workflow from those measured use cases rather than adding
an outer span. The app injects one process-scoped `OSSignposter` adapter whose
interval messages expose only job and outcome and whose observer lifetime uses
an explicit removable token.

**Consequences:** Instruments and controlled probes can distinguish timing and
terminal behavior for every released exact graph read without logging meeting,
person, topic, commitment, decision, question, answer, source, count,
abstention-reason, or error material. Nothing is persisted or sent over a
network. This adds no UI, graph authority, schema, query semantics, model, or
performance baseline; accepted Sequoia/Tahoe receipts and physical VoiceOver,
private-corpus, sync/export, CLI/MCP, and broader graph-answer evidence remain
external gates.

## D368 — Collect exact graph product timing without user content (Aug 2026)

**Context:** D367 created the only content-free timing seam for the six released
exact graph reads, but signposts alone are not reproducible field evidence. A
manual Instruments capture could mix background work, use a private library,
omit build provenance, or silently compare different host conditions. The
existing synthetic relational scale harness does not execute the composed app
path.

**Decision:** add one hidden process-owning app runner over the complete public
disposable fixture. It must execute the existing six ApplicationKit use cases
through `AppMeetingMemoryGraphQueryTelemetry`, suppress normal post-seed search
reconciliation, perform one unmeasured warmup, and measure 5...1,000 iterations
per job. A six-minute independent deadline prevents a hung app process.

The process-local collector requires matched traces, exactly the requested
factful samples for every closed job, arm64/AC/nominal/non-Low-Power host state,
and the fixed public fixture generation. It emits only wall/process-CPU
nearest-rank p50, p95, and maximum summaries plus categorical host/run metadata;
trace and domain identities, text, evidence, domain counts, paths, and raw
errors are structurally excluded. Files are owner-only, atomic, and
non-replacing.

The canonical script refuses a dirty worktree, requires one real Developer ID
identity, builds and signs one isolated Release app plus its embedded frameworks
with that same team, assigns a separate bundle identity, then collects at least
three fresh processes. Ad-hoc signing fails closed because hardened-runtime
library validation cannot load separately ad-hoc-signed embedded Sparkle. A
strict duplicate-key-rejecting assembler requires contiguous runs with
identical host and iteration evidence and binds the final receipt to the exact
source commit, version, and build.

**Consequences:** Portavoz can now produce reproducible content-free timing
input from the actual composed graph-query path without reading a user library
or creating a second query implementation. The collector changes no UI,
authority, schema, model, ranking, query limit, serving behavior, or budget. One
Tahoe machine is not Sequoia or cross-hardware evidence, and the receipt itself
accepts no latency policy; supported-host acceptance, private owner-reviewed
behavior, physical VoiceOver, and broader graph adoption remain separate gates.

## D369 — Receipt inspection reads execution policy only when recovery needs it (Aug 2026)

**Context:** D359 made non-failed receipt source review independent from pause
and per-Skill enablement, and D341 made external/destructive failures
verification-only. The route resolver already depended only on the content-free
audit, but `LoadSkillReceiptInspection` still started an execution-policy read
for every receipt before causal replay. An unrelated missing or temporarily
unavailable policy could therefore hide verified historical evidence or the
warning to verify an outcome outside Portavoz. It also spent one unnecessary
database read on every normal receipt inspection.

**Decision:** load one read-consistent audit first, verify its proposal identity,
and replay the complete bounded causal chain before deriving presentation.
Resolve non-failed recovery as unavailable, external/destructive failures as
verification-only, and missing/legacy/stale local subjects as unavailable
without reading execution policy. Only an otherwise-valid failed local subject
and matching current catalogue version may request current global pause and
per-Skill enablement. Check structured-task cancellation before the audit,
after that optional policy read, and before publishing the inspection.

Keep local recovery fail-closed: if its required policy read fails, the
inspection remains unavailable and no recovery route appears. A temporary-store
test adapter fails only this optional policy port; the real-app waiting-receipt
journey proves historical source review, causal evidence, and independent
revocation still work without consulting it. Unit tests count exact policy
reads for non-failed, external, and local-recovery cases.

**Consequences:** verified historical evidence and outcome-unknown external
guidance no longer disappear because unrelated future-execution controls cannot
be read, and ordinary inspection performs less I/O. Local recovery still needs
current policy and receives no cached or optimistic authority. No schema,
receipt payload, standing rule, confirmation, retry, adapter, transport, effect,
or deployment-floor change is introduced. Deterministic automation exercises
public APIs available at the macOS 14.4 floor; physical VoiceOver, Sequoia, and
separate-hardware Tahoe behavior remain field evidence.

## D370 — An unverified Skill-control mutation recovers by reading, never replaying (Aug 2026)

**Context:** Skills Settings already retained the last verified snapshot and
disabled policy controls when a mutation or its owned refresh failed, but its
only guidance was to close and reopen Settings. The same view had a
generation-fenced control load that could safely recover durable truth, yet no
action exposed it from that stale state. Automatically retrying the mutation is
not safe: the write may have committed even when its response or following read
failed, so replay could create a duplicate or reverse a later choice.

**Decision:** keep the stale snapshot visibly fail-closed and add one explicit
**Reload controls** action. It invokes only the existing control-center read,
never `ManageSkillControl`. A successful read adopts the durable global pause,
per-Skill values, and selected receipt scope before re-enabling controls; a
failed read keeps the same disabled state and retry. Recovery stays in the
current Settings scene rather than requiring window reconstruction.

Add a temporary-store-only mutation-failure argument that commits the requested
policy write and then throws instead of returning; subsequent reads remain
healthy. Cover the real app in both locales: the unverified toggle must not look
committed before a read, controls must disable, reload must adopt the committed
durable value and clear stale state, and the Skills pane must remain open. Give
the action a stable accessibility identifier and keep its selector in the
diff-to-UI-test catalogue. While auditing that boundary, require the older
proposal-read failure argument to be temporary-store-only as its quality
contract already stated.

The first closure catalogue exposed an independent harness defect on a
multi-display host: the Spanish Voice Settings journey reached a lower control,
then XCTest tried to scroll its ancestor at a negative global coordinate and
could not synthesize a hit point. Temporary-store windows therefore share one
AppKit placement boundary that uses `NSScreen.screens.first`, the documented
zero screen. It moves both the disposable primary window and real Settings
scene and constrains Settings to the visible frame; the harness rejects a
negative Settings anchor before continuing. Production launches never enter
this path and keep the user's saved multi-display placement.

**Consequences:** users can recover from transient or ambiguous persistence
failures without losing context, while Portavoz never guesses whether to repeat
a write. This adds no schema, optimistic state, background retry, confirmation,
effect authority, adapter, consent, or standing rule. Automation exercises the
public SwiftUI/AppKit path on the local Tahoe-family host; physical VoiceOver,
Sequoia, and separate-hardware Tahoe behavior remain field evidence.

## D371 — Skill activity expands through one bounded replacement read (Aug 2026)

**Context:** every Skills activity scope used the 20-receipt application
default even though the established request contract already clamps reads to a
50-receipt maximum and StorageKit refuses more than 100. The pane disclosed the
20-row window but provided no way to reach an older receipt. Loading 50 by
default would make every scope change more expensive, while infinite scroll or
view-owned accumulation would weaken the bounded memory and query contract.

**Decision:** start every selected scope at 20. Show **Show more runs** only
when that verified page is full, and let it replace the projection through one
request at the existing 50-row application ceiling. The action disappears
after expansion. Scope changes reset to 20 before loading; same-scope refreshes
and verified policy mutations retain the selected 20-or-50 limit. Scope,
requested limit, and load generation must all match before the view adopts a
response. Do not add cursors, automatic prefetch, background polling, appended
view state, receipt mutation, or a larger storage query.

A temporary-store-only fixture creates 25 content-free confirmed package-export
executions under one reusable offer with 25 distinct destination-scoped effect
slots. The bilingual real-app test proves exactly 20 rows appear initially,
all 25 appear only after the identified expansion action, and the action does
not turn into repeated pagination. Pure tests pin the 20/50 transition and
reset behavior, while the diff-to-XCUITest catalogue keeps the journey attached
to Skills sources.

**Consequences:** the panel can inspect older durable evidence without paying
the maximum read cost for its common path or holding an unbounded receipt
collection. No schema, index, execution authority, proposal content, standing
rule, adapter, egress consent, or platform API changes. Automation remains
local Tahoe-family evidence; physical VoiceOver, Sequoia, and separate-hardware
Tahoe behavior remain field evidence.

## D372 — Verified Skill activity refreshes only on explicit request (Aug 2026)

**Context:** receipt state can change after the Skills pane loads because an
already confirmed execution may begin or settle outside the Settings-owned
mutation path. The pane refreshed after its own receipt mutation and whenever
the user changed scope, but a verified empty or populated scope had no direct
way to re-read durable truth. Closing Settings or changing filters is hidden
refresh behavior; adding a timer, observer, or automatic polling owner would
increase database work and introduce a lifetime that the read-only panel does
not otherwise need.

**Decision:** expose **Refresh activity** only for a verified empty or populated
scope. The action invokes the existing generation-fenced control-center read
with the current scope and current 20-or-50 requested limit. It publishes the
ordinary loading state, which hides the old rows immediately, and adopts a
response only while scope, limit, and generation still match. Loading and
unavailable states expose no competing refresh; unavailable retains its
existing exact retry. The action does not reload proposals, mutate a receipt,
confirm or execute a Skill, install a timer, or observe the database.

The bilingual real-app fixture reuses the 25 confirmed package-export receipts
and the established delayed non-Recent read. It selects Waiting, expands from
20 to all 25 rows, activates the identified refresh, observes the loading state
with no stale rows, and verifies that all 25 return under the retained 50-row
window. Pure presentation tests admit refresh only for verified empty/receipt
states, and source ratchets keep the action read-only and timer-free.

**Consequences:** users can reconcile a long-lived Skills pane with current
durable execution state without changing filters, losing their bounded history
position, or paying an automatic polling cost. No schema, index, scheduler,
observer, background task, receipt mutation, execution authority, adapter,
standing rule, egress consent, or deployment-floor change is introduced.
Automation remains local Tahoe-family evidence; physical VoiceOver, Sequoia,
separate-hardware Tahoe, and cross-process timing remain field evidence.
