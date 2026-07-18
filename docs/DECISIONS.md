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
- **Waveform** per meeting: channel peak envelope downsampled to the requested bucket count and colored by source. The original persisted `waveform.bin` proposal is superseded by D84: measured stateless vectorized generation is fast enough and cannot become stale.
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
**Decision:** adopt the same pattern ONLY for verification tooling. `project.yml` generates `Portavoz.xcodeproj` (gitignored) with two targets: `Portavoz` (app, recompiles `Sources/portavoz-app` against the package's library products) and `PortavozUITests` (`bundle.ui-testing`, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`, `GENERATE_INFOPLIST_FILE: YES` so Xcode signs the runner — Gatekeeper blocks unsigned runners). The app honors testing launch args: **`-use-temp-store`** (disposable DB, never touches the real library, and treats the encrypted participant-voice gallery as empty so automation cannot inspect the host gallery or Keychain) and **`-seed-demo`** (seeds a deterministic meeting with transcript, summary, co-authorship bullet "▸", **and audio** — `AppServices.seedDemoIfRequested()`). Audio is isolated through the **`PORTAVOZ_AUDIO_ROOT`** env var (relocatable audio root, without touching your folder): the seed synthesizes a two-tone clip (mic 220 Hz / system 440 Hz, half and half → the waveform shows both colors) or **adopts a real recording** if one already exists in the root — a UITest points `PORTAVOZ_TEST_AUDIO_ROOT` to a real copy to exercise the player with real audio (verified: 8 real min, player + waveform OK). `make test-ui` runs `xcodebuild test`. Ad-hoc signing (`CODE_SIGN_IDENTITY: "-"`, no team, hardened runtime off) — local tooling, not distribution.
**Rationale:** reproducible, automated UI verification without driving the screen. **Shipping remains `make-app.sh`** (signed + notarized, D20/D23 intact); this project is only for `make test-ui` and is not the release path. XCTest in the UI target coexists with the XCTest package suite (D13). Verified: `LibraryUITests` (library renders) and `MeetingDetailUITests` (transcript + summary + D28 co-authorship mark ▸) are green.

## D31 — IntegrationsKit is the only cross-Kit layer (Jul 2026)

**Context:** the RAG pipeline (`AskPipeline`) needs StorageKit (store/FTS/vectors) and IntelligenceKit (embedder, query expansion) at the same time; it was duplicated in the CLI and app because no Kit could depend on both.

**Decision:** IntegrationsKit is the only Kit authorized to depend on non-foundational capability sibling Kits (`IntelligenceKit` + `StorageKit`). It is the cross-cutting integration layer over stored meetings (export, RAG retrieval, calendar). `TranscriptionKit` and `DiarizationKit` additionally depend on the foundational `ModelStoreKit`; all other capability Kits depend only on Core. `AskPipeline` lives in IntegrationsKit once; the CLI and app consume it.

**Current qualification:** D33 later introduced ApplicationKit as the authorized application-orchestration fan-in. D100 moves Ask coordination and local retrieval there. IntegrationsKit remains the only *capability* module that depends on sibling capabilities, but it no longer owns the Ask application workflow.

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
nothing; enabling sync must explicitly call `markAllMeetingsForInitialSync()`.

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
CloudKit encrypts by default. Asset staging uses a unique local file, complete
file protection, and backup exclusion. The payload SHA-256 is also an encrypted
field. Only format version, payload-storage selector, record type/identity, and
the asset field itself remain outside `encryptedValues`; no transcript,
summary, title, speaker, source-device, generation, or digest value is exposed
as a regular queryable field.

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
Its complete-protection, backup-excluded JSON snapshot contains only hashed
account scope/consent, explicit initial-seed state, Apple's opaque
`CKSyncEngine.State.Serialization`, CKRecord system fields, exact outgoing
generation/digest/file metadata, retry clocks/categories, deferred-replay
metadata, and replay cursors keyed by meeting plus source device. Exact outgoing
and deferred envelope bytes live in separately protected `0600` files and are
validated against identity, byte count, digest, and deterministic filename on
open. Snapshot mutations roll back if persistence fails; orphaned payload files
are removed on restart.

Consent is explicit and bound to a SHA-256 fingerprint of the current-user
record name. Sign-out and temporary account loss pause delivery without erasing
device-owned outgoing attempts. A real account switch clears old account-scoped
engine state, system fields, replay cursors, deferred payloads, and seed state,
then requires consent for the new account. Initial seeding is requested and
completed explicitly; this adapter never opts an upgraded library in by itself.
The coordinator's explicit request invokes StorageKit's
`markAllMeetingsForInitialSync()` and marks the seed complete only after both
the journal and protected attempts drain.

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
