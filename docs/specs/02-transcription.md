# Spec 02 — Transcription (TranscriptionKit, ModelStoreKit)

Status: implemented and verified. Decisions: D7 (routing by task), D15 (sha256 pinning), D16 (live captions), D25 (multiple engines), D35 (independent language policies), D46 (external-audio import boundary), D47 (revision-fenced refine boundary), D49 (Start runtime ownership), D65 (accepted Refine transcript provenance), D70 (audio-first start and durable first-pass recovery), D71 (app-scoped proactive Whisper preparation), D73 (role-specific speech-model readiness), D103 (terminal file analysis and persisted refine workflows).

## Roles and engines (D7)

| Role | Engine | Status |
|---|---|---|
| Live (`liveTranscription`) | Parakeet TDT 0.6B v3 int8 (FluidAudio) | ✅ 0.53 s p95 measured |
| Quality (`finalTranscription`) | Whisper large-v3-turbo (WhisperKit 1.0.0, exact pin) | ✅ 23–42x measured |
| Multiple per role with recommender | — | Planned (D25/M12) |

## Model registry — ModelStoreKit

- `ModelCatalog` with 4 pinned descriptors: `parakeetTdtV3` (21 artifacts, 483 MB, int8 subset), `speakerDiarization` (10 artifacts, ~14 MB), `whisperLargeV3Turbo` (24 artifacts, ~1.6 GB), `whisperTokenizer` (3 files). Each `ModelArtifact` = relative path + sha256 + size; `resolveBase` pinned to an exact HF commit.
- `ModelStore` (actor): download per artifact → verify size + sha256 (CryptoKit streaming 1 MiB) → atomic move. `verify()` re-hashes; `ensureAvailable()` heals missing/corrupt artifacts. Installed in `~/Library/Application Support/Portavoz/Models/` (`--models-dir` override).
- **Gotcha protected by a test**: Parakeet's `folderName` must be `parakeet-tdt-0.6b-v3` (WITHOUT the `-coreml` suffix) — FluidAudio resolves the folder that way, and if it does not find the files it **re-downloads the entire repository without verification** into a sibling directory.
- The sha256 values come from the HF tree API (`/api/models/<repo>/tree/<rev>?recursive=true`): LFS provides `lfs.oid`; small files are hashed manually. Procedure in the doc comment for `ModelCatalog.parakeetTdtV3`.

## Live: ParakeetEngine + mapper

- Custom sliding window **left 11 s / chunk 1.0 s / right 0.4 s** (≤ 15 s model limit). FluidAudio's `.streaming` preset does NOT work: its `hypothesisChunkSeconds` is dead code (it emits only on `chunkSeconds` = 11 s → 13+ s latency).
- **Custom delta filter** (`ParakeetSegmentMapper`): upstream dedup fails with small chunks (re-emits ~all left context). Updates' `tokenTimings` use absolute stream time → filter `startTime > last emitted boundary` and reconstruct text with `joinedText` (handles SentencePiece `▁`).
- Batch: long-form disk-backed `AsrManager`, `parallelChunkConcurrency: 1` (courtesy to the live slot), `melChunkContext: false` (recommended for multilingual v3). Sentence segments by punctuation (TDT timings contain no gaps: pause splitting almost never triggers; `sentenceTerminators` + 0.5 s pauseSplit + 15 s max).
- `TranscriptionScheduler` (D7): immediate live lane; serial FIFO batch slot in `Task.detached(priority: .utility)`. In the macOS recording path, the private `StartRecordingRuntime` instantiates one direct Parakeet stream per selected channel only when the verified engine is already resident; these streams never enter or wait for the serial batch slot. File imports, Refine, and durable first-pass recovery remain serial batch work.
- `TdtDecoderState()` is `throws` and is passed `inout` (local variable). `ASRResult.duration` = 0 on the disk-backed path → read actual duration with AVAudioFile.
- First load compiles for ANE (~14 s for the encoder on M4 Max); CoreML caches it afterward (~1 s).
- Licenses: Parakeet v3 model CC-BY-4.0, FluidAudio Apache-2.0, WhisperKit MIT — all MIT-compatible with attribution.

Standalone terminal transcription enters
`ApplicationKit.TranscribeAudioFile`. The use case admits a readable file,
constructs language/vocabulary hints, owns stable progress and result metrics,
and delegates the selected Parakeet or Whisper engine to an executable adapter.
Commands never construct `ModelStore`, `ParakeetEngine`, or `WhisperEngine`.
Synchronous verified-download callbacks are relayed in order and drained before
the result is printed, so a late percentage cannot appear after terminal
success (D103).

### Audio-first model readiness and recovery (D70)

Recording does not await `ModelStore` downloads or Core ML compilation. The
app runtime snapshots the currently resident Parakeet instance, starts durable
mic/system capture, and then joins or starts independently deduplicated
Parakeet and pyannote preparation tasks. The recording UI states that audio is active and the complete
transcript will appear after local preparation when live captions are deferred.

If no live transcriber existed at Start, or either direct stream throws, the
session carries a recovery bit into `StopRecording`. Stop admits an exact
`.transcription` job whose length-framed fingerprint binds meeting ID, source
transcript revision, Parakeet provider/model/revision, automatic multilingual
mode, no vocabulary, and the current finalized channel IDs, health, checksums,
durations, and byte counts. Pending evidence, missing-only evidence, and purely
silent audio cannot produce runnable work.

The process worker revalidates that fingerprint, joins only verified Parakeet loading,
and transcribes healthy/clipped system and microphone files through the serial
batch scheduler while preserving their real `AudioChannel`. Automatic mode
uses no fixed language and no vocabulary so a mixed Spanish/English meeting is
not biased or translated. Mic fragments pass `TranscriptNoiseFilter` and
`MicBleedFilter`; StorageKit then atomically publishes the complete attributed
cast/transcript, advances `transcriptRevision`, completes the owned lease, and
enqueues exact diarization. Whisper Refine remains the explicit reviewable
quality pass and is not replaced by this safety net.

## Quality: WhisperEngine — `Sources/TranscriptionKit/WhisperEngine.swift`

Hardened against 3 REAL WhisperKit failures (all reproduced and verified, Jul 2026):

1. **`concurrentWorkerCount: 1`** — the default is 16, and workers race over shared decoder state: entire chunks disappear SILENTLY and nondeterministically (a real 482 s meeting collapsed to 3 segments; WhisperKit's VAD-chunked path swallows per-chunk failures with `Logging.debug`, without rethrowing). With 1 worker: correct and 23x (the ANE serializes anyway).
2. **Peak-normalize before transcription** (`AudioLevel.normalizePeak`, target 0.9, gain cap 20x): WhisperKit's EnergyVAD gates on ABSOLUTE energy (0.02 threshold), and a low-volume meeting falls below it → "no hay voz."
3. **Coverage retry based on CLEAN segments**: if transcribed speech < 20% of file duration (audio > 60 s), decode again sequentially (`chunkingStrategy: nil` — that path DOES propagate errors) and WITHOUT promptTokens. Two covered traps: poisoned chunks return valid timespans with text that `cleanSegmentText` empties (raw coverage is misleading), and the vocabulary prompt derails windows that do not mention the terms (verified: with 12 terms, only the chunk that said them survived). Verified: 3 → 82 segments with vocabulary.
4. **Anti-silence hygiene**: segments without lexical content (for example, `.` alone) do not enter the final result; in addition, if the mic channel produces the same short Whisper boilerplate on a VAD cadence (real case: `Me: Thank you.` every ~30 s without the user speaking), post-processing removes it. An isolated occurrence of "Thank you" is preserved.
5. **Spoken language preserved per segment (D35)**:
   `TranscriptLanguagePolicy.automatic` sets `hints.language` only when
   transcript evidence is homogeneous (`Meeting.language` with no prior
   segments, per-segment tags, or local `NLLanguageRecognizer`). If the meeting
   is mixed — for example, one person speaks Spanish and another English — it
   leaves the hint `nil` so Whisper auto-detects each speaker/segment. A fixed
   transcript policy is an explicit recovery tool for weak/noisy audio; summary
   and UI language never become recognition fallbacks. Refine recomputes
   `Meeting.language` from the attributed result and clears stale aggregate
   metadata when the result is mixed or unknown.

- Loads model+tokenizer from verified directories, `download: false` (never downloads without verification). Local tokenizer avoids the network.
- Vocabulary (`hints.vocabulary`) → `promptTokens` as a natural sentence in the homogeneous spoken language ("In this meeting we discussed …" / "En esta reunión hablamos de …", not a "Glossary:" list); for mixed/unknown meetings, the prompt is omitted to avoid biasing Whisper toward one language. WhisperKit prepends it with `<|startofprev|>` and filters special tokens.
- `timings.inputAudioSeconds` under-reports with VAD → duration comes from the file.

### Proactive verified preparation (D71)

`WhisperEngine.prepare` downloads and verifies the selected Turbo/Compact
descriptor plus the shared tokenizer through `ModelStore`, reporting one byte
progress domain across both stores. It returns an opaque `PreparedModel` whose
directories cannot be constructed outside TranscriptionKit.
`loadPrepared` is the only runtime-allocation path after that split and still
sets `download: false`.

The macOS composition root serializes one preparation task across Settings,
Refine, and external-audio Import. Settings can start it explicitly, and its
lifetime is independent from the Settings window. Matching consumers join the
active task; a different variant waits rather than starting a second large
transfer. Successful verification leaves the opaque token app-scoped so the
first later quality pass does not hash the full model again, while the loaded
Whisper runtime still releases after two idle minutes. Deleting that variant
invalidates its token and runtime. Persisted readiness is conservative: every
pinned model and tokenizer artifact must exist at its exact expected size;
actual preparation always re-enters `ModelStore` verification/repair before a
new token can be produced.

### Role-specific speech readiness (D73)

Parakeet, pyannote, and Whisper are independent app-scoped capabilities, not a
single readiness bundle. Separate retained tasks deduplicate each verified
load across concurrent callers. Durable first-pass recovery and Dictation ask
only for Parakeet. Refine prepares only required Whisper before its composite
transcription attempt and requests only pyannote when best-effort speaker
attribution begins. External-audio Import also requests pyannote directly and
never loads Parakeet as an incidental dependency. Explicit onboarding/model
setup and the recording benchmark remain the only paths that intentionally
request both live models.

This keeps optional attribution failure from blocking transcript recovery and
prevents an unrelated live-model compile/download from failing a Whisper
quality pass. A pyannote failure during Refine still follows the application
contract below: the draft succeeds with honest unattributed system segments.

### External audio import (D46)

`ApplicationKit.ImportMeeting` owns the external-file workflow without
constructing model objects itself. The app processor prepares the shared
Whisper engine as a required step, reports verified model-download progress,
loads only pyannote for its separately degradable attribution step, and
transcribes the copied system-channel file with the once-sampled
`TranscriptLanguagePolicy` and vocabulary. Automatic mode leaves the hint nil,
so a mixed Spanish/English recording keeps each segment's detected language;
the independently configured summary language never becomes a recognition
fallback. A required transcription failure rolls back the staged copy before
the aggregate exists. Once Whisper was prepared, the same idle release policy
as the released import path is scheduled on every later exit.

### Meeting refinement (D47)

`ApplicationKit.RefineMeeting` owns the quality re-pass without constructing
model objects or reading platform settings/files itself. The app adapter
resolves retained system/microphone channels off the MainActor, samples the
global transcript policy and vocabulary once, and maps typed progress while the
use case prepares required Whisper, transcribes, requests pyannote only for
best-effort attribution, and builds the
reviewable `RefineDraft`. A per-meeting fixed Spanish/English recovery choice
overrides the sampled policy; automatic mixed-language evidence leaves the
Whisper hint `nil`, and the aggregate language is recomputed only when the
result is homogeneous. Summary/UI language never enters recognition.

Digitally silent channels never reach Whisper. Microphone results pass through
`TranscriptNoiseFilter` and then `MicBleedFilter`, preserving the released
anti-hallucination and echo behavior. Required preparation/transcription errors
propagate; diarization degrades to honest unattributed segments; cancellation
is never swallowed. Every exit after model ownership begins schedules both
Whisper and recording-engine idle release. The draft carries the source
`transcriptRevision`; acceptance is a separate ApplicationKit use case and
StorageKit transaction that rejects stale drafts rather than overwriting a
newer transcript.

The terminal's `RefinePersistedMeeting` wrapper uses the same draft and apply
use cases. It loads the current `MeetingDetail` through an injected reader,
optionally resolves explicit audio through the file port, and applies only the
revision-fenced draft it just produced. External files are fingerprinted with
streaming SHA-256 rather than loading the whole recording into memory. The CLI
maps typed progress to its existing download, per-channel timing, and
diarization messages (D103).

Refine defines one exact composite operation identity across the non-silent
channels that actually reach Whisper. The length-framed SHA-256 fingerprint
binds meeting/source revision, the selected WhisperKit provider/model/revision,
automatic or fixed language hint, ordered vocabulary material, and each
channel's audio digest. Finalized v6 capture checksum evidence is reused only
after the current file size matches; legacy recordings are streamed through
local SHA-256. Raw paths and vocabulary never enter the persisted envelope. A
successful run stays in the review draft until Apply; discarding it or losing
the revision fence stores no success. Failure or cancellation after the
attempt begins stores only a content-free standalone terminal run best effort
(D65).

## SpeechAnalyzer spike (M12/D25) — status and findings (Jul 2026)

`SpeechAnalyzerEngine` (macOS 26, `#if canImport(Speech)`): implemented against the local SDK's REAL `.swiftinterface` — same shape as Parakeet live for identical benchmarks. Spike findings:

1. **SpeechAnalyzer DOES accept custom vocabulary** — `AnalysisContext.contextualStrings[.general]` exists in SDK 26.5 and the engine wires it from `hints.vocabulary`. This CORRECTS round 2 research ("lost contextualStrings") — it arrived in a beta after the reviews.
2. **⚠️ Hangs in CLI processes without a bundle**: `SpeechTranscriber.supportedLocale(equivalentTo:)` (first await) suspends FOREVER in `portavoz-cli` — sample shows the cooperative pool empty and the run loop parked (the Speech daemon never responds to a process without bundle/TCC context). **The live-role benchmark must run INSIDE the app** — `NSSpeechRecognitionUsageDescription` has already been added to Info.plist.
3. **Shared harness**: `LiveTranscriptionBench` (TranscriptionKit) paces the file in real time (1 s chunks) and measures finalization lag. Entry points: `portavoz-cli bench-live --engine parakeet` and, for speech, `Portavoz.app/Contents/MacOS/portavoz-app --bench-live <file> [--seconds] [--language]` (hidden launch argument: runs in-bundle, prints to stdout, exits).
4. **⚠️ Finalization bug (fixed)**: `finalizeAndFinishThroughEndOfInput()` is called by the FEEDER when the input is exhausted — sequencing it after the `transcriber.results` loop deadlocks (results ends only when someone finalizes; the first benchmark remained parked forever).
5. **Measured comparison (same 60 s of a real EN meeting, system channel, M4 Max)**:

| | Parakeet v3 (CLI) | SpeechAnalyzer en_US (in-app) |
|---|---|---|
| first result | 1.13 s | **1.03 s** |
| finalization lag p50/p95/max | **0.07 / 0.68 / 0.72 s** | 0.47 / 0.82 / 0.82 s |
| emission | 36 append-only finals (small deltas: "uh", "and") | 9 sentence finals + **150 volatile** (replace) |
| final chars | 461 | 603 |
| style | clean | verbatim with disfluencies ("uh") |
| with wrong locale (es_CL over EN) | — | same latency (p50 0.16) but garbage text → detecting language BEFOREHAND matters |

M12 interpretation: both remain below 1 s p95 — SpeechAnalyzer IS viable for the live role (zero download, rich volatile results for captions, custom vocabulary), while Parakeet retains the finalization crown. What remains before swapping them in the app is the coalescer's append-vs-replace decision (Speech volatile results REPLACE the range; the current coalescer assumes deltas).

## Caption coalescer — `CaptionCoalescer` (used by the app)

The newest row grows while the channel keeps speaking: mid-sentence pauses ≤ 6 s stay in the row, continuation < 2 s after a closed sentence flows on the microphone, but on `system`/`room` the pause after a sentence splits earlier (0.6 s) so two consecutive remote participants appear as two `Ellos` rows even before refine. Hard split at 280 chars. Deltas without lexical content are discarded except final punctuation that completes an existing row (an isolated `"."` does not create `Yo: .`). Stable row identity (id/startTime are preserved) → SwiftUI does not rebuild, and translation translates only closed rows (only the last global row can grow). 13 tests.

## Vocabulary — `VocabularyPrompt`

`parse()` (comma-separated, trim, dedup) and `text()` (natural EN/ES sentence according to the homogeneous spoken language). Sources: app Ajustes (UserDefaults `customVocabulary`, list editor), CLI `--vocab`. **VocabularyMiner** (pure, 6 tests): mines domain-shaped terms (acronyms, letter+digit codes, CamelCase — never ordinary capitalized words) that recur ≥3 times in the last 12 transcripts and suggests them as chips in Ajustes → Vocabulario. **Review-before-adding flow** (field case: the miner suggests what Whisper HEARD — it suggested "Qord2M" when the real term was "Kord2m"): the chip preloads the text field to correct the spelling and confirm with Add; ✕ rejects it forever (`vocabularyRejectedSuggestions` in defaults, excluded by the miner); adopting an edited version also rejects the raw misheard form so it does not return. It does not run under XCUITest to avoid shifting the layout asynchronously. Consumers: WhisperEngine (promptTokens only when the language is homogeneous), summaries (glossary, spec 04). **Live Parakeet has no bias hook** — refine corrects the record.

## Known limitations

1. Live Parakeet degrades with non-native accents (verified: an accented EN contribution was garbled live; the same audio through Whisper was clean) — current response: refine.
2. System-wide dictation is implemented in the macOS app (⌥⌘D by default,
   configurable, with a non-activating panel and Accessibility paste/restore;
   see spec 06). It reuses live Parakeet and does not change meeting capture.
3. ~~Quantized Whisper models not yet in the catalog~~ — **DONE (M12)**: **626 MB** variant (`whisper-large-v3-626mb`, 17 artifacts sha256-pinned to the same argmax commit as turbo) for low disk space. `WhisperEngine.loadRecommended(descriptor:)` selects it; `AppServices.loadWhisperIfNeeded` chooses it according to the "Whisper compacto" toggle (Ajustes) and reloads if it changes; the recommender enables it if low disk space is detected. Turbo remains the default.
4. ~~FluidAudio pinned by revision `c367a18e`~~ — **RESOLVED**:
   `Package.swift` uses `.upToNextMinor(from: "0.15.5")`, which contains the
   upstream #732 type-checker fix.
