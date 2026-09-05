# Spec 02 — Transcription (TranscriptionKit, ModelStoreKit)

Status: implemented and verified. Decisions: D7 (routing by task), D15 (sha256 pinning), D16 (live captions), D25 (multiple engines), D35 (independent language policies), D46 (external-audio import boundary), D47 (revision-fenced refine boundary), D49 (Start runtime ownership), D65 (accepted Refine transcript provenance), D70 (audio-first start and durable first-pass recovery), D71 (app-scoped proactive Whisper preparation), D73 (role-specific speech-model readiness), D103 (terminal file analysis and persisted refine workflows), D104 (application-owned post-capture execution), D113 (verified model lifecycle), D121 (bounded live hot attachment), D122 (lexical transcript and generated-output admission), D128 (explicit per-turn live-translation lanes), D130 (unhinted automatic Refine), D131 (bounded cross-channel caption admission), D148 (content-free resource measurement), D160 (pinned quality-speech runtime), D162 (pinned live-speech runtime), D169 (signal-driven bounded live translation), D173 (observational clipping evidence), D174 (bounded live-caption presentation derivations), D229 (pure correction composition policy), D230 (durable correction history without product adoption), D231 (focused Meeting Detail text/speaker correction), D232 (explicit structural correction commands), D233 (correction-aware derived-artifact lineage and invalidation), D234 (correction-aware document projection and replica convergence), D320 (structured SpeechAnalyzer and First Listen lifetime), D355 (pinned non-serving Nemotron challenger), D433 (pinned non-serving compact MLX challengers and exact live-translation admission).

Additional decision: D235 (correction recovery and scale gates).

## Correction composition contract (D229)

The accepted machine transcript remains immutable. ApplicationKit exposes a
pure `ComposeTranscript` policy over one explicit raw or refined transcript
revision. Corrections are typed as text replacement, speaker reassignment,
split, adjacent same-speaker/channel merge, single-row suppression, or
restoration. Each visible composed row retains the ordered accepted segment IDs
from which it was derived, and composed chapters are rebuilt from the same
rows.

Every correction's lane — text, speaker, or structure — is resolved through
`TranscriptCorrectionDomainIndex`, which indexes one history once (D300). A
restore inherits its predecessor's lane, so resolution walks the supersession
chain; doing that against a freshly grouped copy of the whole history per event
made composition quadratic in a meeting's correction count, on the interactive
path. Measured on 8 000 segments with 4 000 corrections: p95 12 749 ms before
and 185 ms after. `testDenseCorrectionHistoryComposesStablyOutsideTimedGate`
retains that dense semantic shape, exact row count, and complete composed
content equality across shuffled inputs, while an architecture
ratchet pins the two indexed passes and the isolated Release benchmark owns the
250 ms admission budget. Per-event semantics are unchanged, including which
event id a duplicate reports — the
duplicate check is deferred to the query so the refusal still names the event
that was asked about.

Composition fails closed for an unspecified base, stale revision, duplicate
correction identity, missing or repeated target, overlapping active edits,
invalid or branched supersession, a target-changing supersession, nonmonotonic
or partial split, nonadjacent/out-of-order/incompatible merge, nonlexical
replacement, provisional base row, non-finite event time, or generated row-ID
collision. Splits partition the complete source interval without gaps or
zero-duration rows; merge and supersession target order is authoritative.
Invalid inputs are admitted in correction-ID order so failure selection is
stable; source order plus `(createdAt, correction ID)` then orders valid
composition deterministically. Only the terminal event in a linear
supersession chain is active. Text and speaker attribution are independent
domains that may coexist on one source; structural edits conflict with either
domain. Restore remains in its predecessor's domain, and cyclic domain
resolution fails closed.

`TranscriptComposition` exposes both immutable accepted and composed readings.
Their lineage carries an explicit accepted/composed projection even when no
correction is active and both row arrays match. Callers must choose through
`TranscriptReadingPolicy`; an architecture allowlist admits only the composer
for direct projection choices. Meeting Detail now composes current-revision text
and speaker changes through its application read model. At the D229 boundary,
export, search, summary, generated evidence, and indexing still used accepted
material merely because corrections were supplied; D233 adopts composed summary
generation and correction-aware invalidation without silently extending the
other consumers.

## Durable correction history (D230)

`PortavozCore` owns a versioned portable correction event with meeting and base-
revision identity, ordered accepted-segment targets, a typed payload, user
author, source device, timestamps, optional tombstone, and optional superseded
event. Portable validation rejects malformed metadata, language identifiers,
operation shapes, duplicate identities, missing/branched/target-changing
supersession, and overlapping live terminals before either persistence or
envelope decoding accepts the history.

`StorageKit` persists the same values in normalized schema-v19 tables and
appends or tombstones them atomically. Undo remains a new restore event, not a
destructive rewrite. History reads include tombstones; source segment IDs remain
durable even if later accepted revisions retire those rows. A strict format-1
correction envelope makes the database layout private. Meeting aggregate format
2 carries the same ordered typed history through the existing private-sync
boundary, rejects immutable rewrites and tombstone regression, and preserves
local history when decoding a legacy aggregate that cannot contain corrections.
The focused Meeting Detail editor now writes text and speaker corrections
through an atomic ApplicationKit command. It exposes immutable original evidence
and appends domain-specific restore events for Undo. Exports adopt the composed
projection under D234; corrected-text search/index materialization and automatic
Apuntador refresh remain separate policies.

## Structural correction command (D232)

`RestructureMeetingTranscript` accepts one explicit accepted projection and its
revision. It rejects stale/composed input, missing or repeated targets,
incompatible active lanes, nonlexical or nonmonotonic splits, and unordered,
nonadjacent, cross-speaker, or cross-channel merges before persistence. The
Meeting Detail read model offers only compatible previous/next merge candidates;
the user must choose one. Every split/merge keeps its ordered accepted source
map. One bidirectional source map resolves visible rows back to immutable
accepted IDs and uses evidence timestamps to choose the correct half of a split
during playback or citation navigation. Suppression removes a row only from the
composed reading and exposes its accepted text through a hidden-evidence sheet
with durable restore.

Restore is retained in correction lineage and domain validation but does not
compose as an active edit or reserve a target lane. A restored accepted row can
therefore receive a later explicit correction without rewriting history.

## Correction revision and derived consumers (D233)

`TranscriptCorrectionRevision` identifies the effective overlay for one exact
accepted transcript revision. It is `accepted` with no active correction and a
convergent SHA-256 identity over the meeting, accepted revision, and canonical
effective event IDs otherwise. The identity is not a device-local counter and
therefore survives sync replay without inventing conflicts.

Summary and metadata generation may explicitly consume composed rows. Generated
split/merge row identities remain temporary inputs; every persisted evidence
link is mapped back to the immutable ordered accepted source IDs. Existing
summary and Apuntador artifacts retain their original transcript/correction
lineage and become stale instead of being rewritten. Search still has no
corrected-text projection: affected accepted rows are excluded from exact and
semantic retrieval until restore, while unaffected rows remain available.
Document exports compose the current correction overlay, preserve original row
times and accepted source IDs, omit summaries from a different correction
revision, and can disclose the overlay through explicit provenance. Automatic
Apuntador regeneration remains deferred. No correction starts model work
automatically.

## Correction quality and scale authority (D235)

Composition is characterized across 64 seeded permutations of accepted rows
and complete correction history. The fixture combines every supported operation
and requires exactly equivalent accepted/composed values regardless of
input order. A separate refined bilingual fixture proves that Spanish and
English remain per-row spoken-language evidence; correction composition is
never a translation step.

`TranscriptCorrectionScaleBenchmarkTests` owns the payload-free synthetic scale
fixture. `make test-correction-composition` validates its schema and dense
semantic output without wall-clock admission;
`make correction-composition-benchmark` measures twenty Release permutations
of 20,000 rows and 400 corrections, failing above 250 ms p95. The deterministic
release runner executes that command sequentially after the full package suite.
The retained Aug 2026 reference observation used the original five-sample
policy and records p50 168.85 ms and p95/max 175.20 ms. Search does not invoke
this composer and corrected text remains intentionally unmaterialized.

## Roles and engines (D7)

| Role | Engine | Status |
|---|---|---|
| Live (`liveTranscription`) | Parakeet TDT 0.6B v3 int8 (FluidAudio) | ✅ 0.53 s p95 measured |
| Quality (`finalTranscription`) | Whisper large-v3-turbo (WhisperKit 1.1.0, exact pin) | ✅ 23–42x measured |
| Research-only live challenger | Nemotron 3.5 ASR Latin 1120 ms (FluidAudio) | Adapter complete; Portavoz evidence not accepted |
| Multiple per role with recommender | — | Planned (D25/M12) |

## Model registry — ModelStoreKit

- `ModelCatalog` with 10 pinned descriptors: `parakeetTdtV3` (21 artifacts, 483 MB, int8 subset), research-only `nemotronLatin1120` (10 artifacts, ~588 MB, lean fused-decoder subset), `speakerDiarization` (10 artifacts, ~14 MB), `whisperLargeV3Turbo` (24 artifacts, ~1.6 GB), `whisperLargeV3_626MB`, `whisperTokenizer` (3 files), the default `mlxQwen35`, the retained `mlxQwen3` A/B alternative, and evaluation-only Qwen3.5 0.8B/2B MLX challengers. Each `ModelArtifact` = relative path + sha256 + size; `resolveBase` is pinned to an exact Hugging Face commit. The compact challengers are reachable only through exact `--mlx-smoke qwen35-0.8b` or `qwen35-2b` tokens and never through Settings, product routing, or `recommended(for:)`; promotion requires Portavoz quality/resource evidence rather than upstream claims (D433).
- `ModelStore` (actor): download each artifact into a sibling on the destination volume → verify size + sha256 (CryptoKit streaming 1 MiB) → atomically rename or replace. `verify()` re-hashes; `ensureAvailable()` heals missing/corrupt artifacts without first deleting the old destination. The default is `Portavoz/Models/` inside the platform Application Support container (`~/Library/Application Support` on macOS; the app container on iOS), with a `--models-dir` override.
- `VerifiedModelLifecycle` (actor): coalesces complete descriptor checks, returns an opaque `VerifiedInstallation` only after every pinned digest passes, and caches only successful evidence by descriptor ID + revision. Missing/corrupt results are never cached. Same-descriptor install/remove operations execute in invocation order; invalidation and forced verification supersede stale checks, and waiting callers retry current evidence rather than returning an obsolete result. Cancellation is honored before publication but not reported as false failure after a verified install commits. No app readiness path infers installation from one filename or aggregate size.
- **Gotcha protected by a test**: Parakeet's `folderName` must be `parakeet-tdt-0.6b-v3` (WITHOUT the `-coreml` suffix) — FluidAudio resolves the folder that way, and if it does not find the files it **re-downloads the entire repository without verification** into a sibling directory.
- The sha256 values come from the HF tree API (`/api/models/<repo>/tree/<rev>?recursive=true`): LFS provides `lfs.oid`; small files are hashed manually. Procedure in the doc comment for `ModelCatalog.parakeetTdtV3`.

## Live: ParakeetEngine + mapper

- Custom sliding window **left 11 s / chunk 1.0 s / right 0.4 s** (≤ 15 s model limit). FluidAudio's `.streaming` preset does NOT work: its `hypothesisChunkSeconds` is dead code (it emits only on `chunkSeconds` = 11 s → 13+ s latency).
- **Custom delta filter** (`ParakeetSegmentMapper`): upstream dedup fails with small chunks (re-emits ~all left context). Updates' `tokenTimings` use absolute stream time → filter `startTime > last emitted boundary` and reconstruct text with `joinedText` (handles SentencePiece `▁`).
- Batch: long-form disk-backed `AsrManager`, `parallelChunkConcurrency: 1` (courtesy to the live slot), `melChunkContext: false` (recommended for multilingual v3). Sentence segments by punctuation (TDT timings contain no gaps: pause splitting almost never triggers; `sentenceTerminators` + 0.5 s pauseSplit + 15 s max).
- `TranscriptionScheduler` (D7): immediate live lane; serial FIFO batch slot in
  `Task.detached(priority: .utility)`. Queued batch callers carry identified
  throwing continuations and are removed immediately on cancellation,
  including cancellation that races the actor enqueue; a cancelled caller is
  never retained behind an unrelated long transcription. Actor serialization
  installs each continuation before the nonisolated cancellation handler can
  mutate the queue; a second check after slot handoff releases the lane instead
  of admitting a cancelled caller to its job. In the macOS recording path, the
  private `StartRecordingRuntime` creates
  one bounded, non-suspending feed per selected channel before capture. A
  recording-scoped attacher owns one pinned Parakeet runtime lease, connects
  direct streams immediately when the verified engine is resident, or joins
  the process-owned load and connects them later; these streams never enter or
  wait for the serial batch slot. File imports, Refine, and durable first-pass
  recovery remain serial batch work.
- D148 measures the live execution lane separately from batch queue wait and
  execution. The app also measures verified Parakeet and Whisper
  prepare/load/release plus actual Refine, Import, durable-recovery, and live
  consumer work. Descriptors contain only workload class, resource family, and
  operation; no audio callback is instrumented, and the scheduler's capacity
  and FIFO behavior are unchanged.
- `TdtDecoderState()` is `throws` and is passed `inout` (local variable). `ASRResult.duration` = 0 on the disk-backed path → read actual duration with AVAudioFile.
- First load compiles for ANE (~14 s for the encoder on M4 Max); CoreML caches it afterward (~1 s).
- Licenses: Parakeet v3 model CC-BY-4.0, FluidAudio Apache-2.0, WhisperKit MIT — all MIT-compatible with attribution.

## Research-only live challenger: Nemotron Latin 1120 ms (D355)

- `ModelCatalog.nemotronLatin1120` pins the exact upstream revision and all ten
  files required by FluidAudio's lean B1 path. Native Swift computes mel input;
  the fused `decoder_joint.mlmodelc` makes bare decoder/joint and preprocessor
  bundles unnecessary. Before load, an exact directory fence rejects every
  symlink, special file, unlisted file, and unlisted directory: FluidAudio's
  optional-bundle discovery must never choose an artifact outside the verified
  descriptor. The registry entry is not returned by `recommended`.
- `NemotronLatin1120Engine` preloads one immutable
  `SharedNemotronMultilingualModels` set, then constructs a fresh actor-owned
  stream manager for every transcription. Per-stream caches, decoder state,
  audio conversion, prediction buffers, cancellation, finalization, and cleanup
  therefore never cross jobs.
- The upstream manager exposes cumulative stable token timings. The adapter
  remembers an integer token cursor and emits only its new suffix; timestamp
  filtering is forbidden because adjacent RNN-T tokens may share a timestamp.
  Cursor regression, non-finite timings, invalid PCM, missing/unsupported
  language, and vocabulary prompts fail closed. A timing-free final transcript
  has one duration-bounded fallback segment.
- The only composition path is
  `portavoz-cli bench-live --engine nemotron-latin-1120 --language en|es`.
  It validates hints before a possible ~588 MB download and reuses the existing
  real-time pacing, finalization-lag, WER/CER, and JSON evidence harness. That
  harness now rejects nonpositive duration and invalid audio, propagates stream
  and file-read failures instead of returning partial evidence, and cancels and
  drains its real-time feeder if an engine fails or ends early. The app,
  recording, scheduler, residency ledger, and product model UI do not reference
  this candidate.
- OpenMDW-1.1 is recorded as upstream license metadata, not accepted
  redistribution policy. Parakeet remains the live engine until the same
  owner-reviewed bilingual corpus demonstrates quality, names/digits,
  code-switching, latency, thermals, and resident memory on supported Sequoia
  and Tahoe hosts and the owner accepts the license/attribution obligations.

Live transcript presentation also receives a content-free quality signal when
the accepted system channel remains at the PCM ceiling. This warning is
derived from the durable writer's compact level evidence, uses captured
duration rather than callback count, and never changes Parakeet input,
captions, or stored audio. It tells the user that the source may already be
distorted; Refine remains the explicit quality pass and field WER/CER remains
the acceptance measure.

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
app runtime claims a lease only when Parakeet is already resident, creates
bounded `bufferingNewest` feeds, and starts durable mic/system capture. A
resident model attaches immediately; otherwise `LiveTranscriptionAttacher`
joins the shared verified Parakeet task and connects the same active recording
when it completes. The attacher retains that exact engine/use token until every
live stream drains. Stop cancels only its waiter and returns immediately; if the
process load later completes, the inactive attacher ends the new lease without
publishing captions.
Only recent context and future frames enter the late live consumers, so a long
download cannot accumulate an unbounded inference backlog. Typed preparing,
available, and failed state keeps the recording UI honest.

If no live transcriber existed at Start, even if it attaches later, or either
direct stream throws, the session carries a recovery bit into `StopRecording`
because the finalized audio before attachment still needs complete coverage. Stop admits an exact
`.transcription` job whose length-framed fingerprint binds meeting ID, source
transcript revision, Parakeet provider/model/revision, automatic multilingual
mode, no vocabulary, and the current finalized channel IDs, health, checksums,
durations, and byte counts. Pending evidence, missing-only evidence, and purely
silent audio cannot produce runnable work.

`ApplicationKit.ProcessPostCaptureJobs` revalidates that fingerprint and asks
the app capability adapter to join only verified Parakeet loading and transcribe
healthy/clipped system and microphone files through the serial batch scheduler
while preserving their real `AudioChannel`. Automatic mode
uses no fixed language and no vocabulary so a mixed Spanish/English meeting is
not biased or translated. Mic fragments pass `TranscriptNoiseFilter` and
`MicBleedFilter`; StorageKit then atomically publishes the complete attributed
cast/transcript, advances `transcriptRevision`, completes the owned lease, and
enqueues exact diarization. The application workflow owns job leases,
dependency admission, retry/cancellation, and publication order; the adapter
owns recording paths, filesystem validation, engines, and preferences. Whisper
Refine remains the explicit reviewable quality pass and is not replaced by this
safety net.

## Quality: WhisperEngine — `Sources/TranscriptionKit/WhisperEngine.swift`

Two whisper.cpp-era hardening patterns are deliberately absent, verified against WhisperKit's source (Jul 2026): per-job decoder-state isolation is structural — WhisperKit prepares fresh decoder inputs and KV cache on every transcription call and Portavoz builds promptTokens per call, so the prompt_past cross-job poisoning class cannot occur; and VAD speech-only stitching is inapplicable because refine requires exact timestamps, which stitching desynchronizes (the pattern's own reference implementation skips it whenever timestamps are requested). The applicable input-side protections already exist: peak normalization, digitally-silent channel skipping, single-worker decoding, and anti-boilerplate hygiene.

Model load degrades before it fails (Jul 2026): a failed load — accelerator context creation is the recurring field class (ANE/GPU contention, stale Metal contexts) — retries exactly once with CPU-only compute units via the pure, tested `AcceleratorFallback`; a user cancel never triggers the second load, and a dual failure surfaces both causes so diagnostics distinguish an accelerator-only fault from a broken model directory. Artifact downloads were already atomic before this (D113: verified sibling staging + streaming sha256 + atomic rename preserving the previous file).

Hardened against 3 REAL WhisperKit failures (all reproduced and verified, Jul 2026):

1. **`concurrentWorkerCount: 1`** — the default is 16, and workers race over shared decoder state: entire chunks disappear SILENTLY and nondeterministically (a real 482 s meeting collapsed to 3 segments; WhisperKit's VAD-chunked path swallows per-chunk failures with `Logging.debug`, without rethrowing). With 1 worker: correct and 23x (the ANE serializes anyway).
2. **Peak-normalize before transcription** (`AudioLevel.normalizePeak`, target 0.9, gain cap 20x): WhisperKit's EnergyVAD gates on ABSOLUTE energy (0.02 threshold), and a low-volume meeting falls below it → "no hay voz."
3. **Coverage retry based on CLEAN segments**: if transcribed speech < 20% of file duration (audio > 60 s), decode again sequentially (`chunkingStrategy: nil` — that path DOES propagate errors) and WITHOUT promptTokens. Two covered traps: poisoned chunks return valid timespans with text that `cleanSegmentText` empties (raw coverage is misleading), and the vocabulary prompt derails windows that do not mention the terms (verified: with 12 terms, only the chunk that said them survived). Verified: 3 → 82 segments with vocabulary.
4. **Anti-silence hygiene**: segments without lexical content (for example, `.` alone) do not enter the final result; in addition, if the mic channel produces the same short Whisper boilerplate on a VAD cadence (real case: `Me: Thank you.` every ~30 s without the user speaking), post-processing removes it. An isolated occurrence of "Thank you" is preserved.
5. **Spoken language preserved per segment (D35/D130)**:
   `TranscriptLanguagePolicy.automatic` always leaves the full-channel
   `hints.language` nil, even when stale meeting metadata or provisional
   segments appear homogeneous. `WhisperEngine` also sets WhisperKit
   `detectLanguage = true` in that mode: nil alone is insufficient because
   WhisperKit otherwise disables detection while decoder prefill is enabled
   and falls back to English. Each VAD result retains its detected language,
   while `task = .transcribe` preserves spoken-language output instead of
   requesting translation. A fixed transcript policy is an explicit
   per-meeting recovery tool for weak/noisy audio; summary and UI language
   never become recognition fallbacks. Refine recomputes `Meeting.language`
   from the attributed result and clears stale aggregate metadata when the
   result is mixed or unknown.

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
pinned model and tokenizer artifact must pass its expected SHA-256 digest;
actual preparation always re-enters `ModelStore` verification/repair before a
new token can be produced. Settings inventory, support diagnostics, and MLX
provider resolution use the shared verified lifecycle rather than separate
filesystem probes. The production root is
`~/Library/Application Support/Portavoz/Models`, not the application bundle, so
`make install`, Sparkle replacement, and Homebrew application-bundle upgrades
preserve verified models. Preparation now carries an explicit activity bit:
Settings, Refine, Import, and CLI say **checking local files** during a
checksum-only pass and show **downloading** with a percentage only after
ModelStore found missing or corrupt pinned artifacts. Integrity verification
remains mandatory in both paths.

### Role-specific speech readiness (D73)

Parakeet, pyannote, and Whisper are independent app-scoped capabilities, not a
single readiness bundle. Separate retained tasks deduplicate each verified
load across concurrent callers. Parakeet acquisition also returns one
active-use lease per recording, Dictation session, durable first-pass file,
onboarding check, or measured benchmark operation. Durable first-pass recovery
and Dictation ask only for Parakeet. Refine prepares only required Whisper before its composite
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
overrides the sampled policy; automatic mode always leaves the complete-channel
Whisper hint `nil`, and the aggregate language is recomputed only when the
result is homogeneous. Summary/UI language and stale meeting metadata never
enter recognition.

Digitally silent channels never reach Whisper — but only a channel proven
silent. `AudioSilence.fileIsSilent` reads the file in ~1 s blocks and can
conclude silence *only* by reaching the end intact; a read that fails short of
it returns false, exactly as an unopenable file does (D299). Not a capture
file: `CaptureFileWriter` uses CAF precisely so a killed recording stays fully
readable. The reachable inputs arrive from elsewhere —
`resolveExternalRefineAudio` passes arbitrary user-imported files, and
`MeetingAudioLayout` resolves compressed `.m4a` copies and legacy WAV — plus any
read that fails because the recordings volume went away mid-scan.
`TranscriptContentPolicy`
removes rows with no letter or digit from both system and microphone results;
Whisper mapping, the ApplicationKit Refine boundary, accepted-aggregate storage,
and intelligence formatting independently enforce the same minimum. Microphone
results then pass through `TranscriptNoiseFilter` and `MicBleedFilter`,
preserving the released anti-hallucination and echo behavior. Required preparation/transcription errors
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
channel's audio digest. Those components are appended in small, explicitly
typed steps so the supported Sequoia Swift 6.2 compiler retains the exact same
order and operation identity. Finalized v6 capture checksum evidence is reused
only after the current file size matches; legacy recordings are streamed
through local SHA-256. Raw paths and vocabulary never enter the persisted
envelope. A successful run stays in the review draft until Apply; discarding it
or losing the revision fence stores no success. Failure or cancellation after
the attempt begins stores only a content-free standalone terminal run best
effort (D65).

## SpeechAnalyzer spike (M12/D25) — status and findings (Jul 2026)

`SpeechAnalyzerEngine` (macOS 26, `#if canImport(Speech)`): implemented against the local SDK's REAL `.swiftinterface` — same shape as Parakeet live for identical benchmarks. Spike findings:

1. **SpeechAnalyzer DOES accept custom vocabulary** — `AnalysisContext.contextualStrings[.general]` exists in SDK 26.5 and the engine wires it from `hints.vocabulary`. This CORRECTS round 2 research ("lost contextualStrings") — it arrived in a beta after the reviews.
2. **⚠️ Hangs in CLI processes without a bundle**: `SpeechTranscriber.supportedLocale(equivalentTo:)` (first await) suspends FOREVER in `portavoz-cli` — sample shows the cooperative pool empty and the run loop parked (the Speech daemon never responds to a process without bundle/TCC context). **The live-role benchmark must run INSIDE the app** — `NSSpeechRecognitionUsageDescription` has already been added to Info.plist.
3. **Shared harness**: `LiveTranscriptionBench` (TranscriptionKit) paces the file in real time (1 s chunks) and measures finalization lag. Entry points: `portavoz-cli bench-live --engine parakeet` and, for speech, `Portavoz.app/Contents/MacOS/portavoz-app --bench-live <file> [--seconds] [--language]` (hidden launch argument: runs in-bundle, prints to stdout, exits).
4. **Accuracy lane (MODEL-001, Jul 2026)**: `TranscriptionAccuracy` (TranscriptionKit, pure, 5 tests) computes WER and CER with rolling-buffer Levenshtein over normalization that keeps Spanish accents — they are phonemic ("papa" vs "papá" is a real error), while case, punctuation, and whitespace are not. The bench result now carries every final row (`Result.hypothesis`), and `bench-live` gains `--reference <txt>` (scores WER/CER against a plain-text transcript) and `--output <json>` (one evidence artifact per run, same convention as the scale benches), so an engine comparison leaves committed numbers instead of prose. The quality spec's rule stands: third-party accuracy tables are citations, never our measurements.
5. **Nemotron challenger (MODEL-001/D355, Aug 2026)**: FluidAudio
   0.15.6—the exact resolved dependency—contains
   `StreamingNemotronMultilingualAsrManager` and tagged downloadable Nemotron
   3.5 ASR Streaming Multilingual 0.6B CoreML variants. The Latin-vocabulary
   ship serves English and Spanish, and the upstream benchmark documentation
   identifies 560/1120/2240 ms tiers targeting macOS 14+/iOS 17+. This
   supersedes the earlier Qwen3 wait: FluidAudio 0.15.3
   explicitly removed that experimental backend. No upstream WER/RTFx value is
   a Portavoz result. D355 now supplies the **non-serving, sha256-pinned 1120 ms
   Latin adapter** through `bench-live --reference/--output`; no model was
   downloaded and no quality run is implied by that code delivery. The next
   step is the same owner-reviewed bilingual comparison against Parakeet v3 for
   accents, code-switching, names, digits, latency, thermal, and resident
   memory. Product routing stays unchanged until that evidence wins within
   D7/D137 resource budgets and the OpenMDW-1.1 redistribution/attribution terms
   pass owner review.
6. **⚠️ Finalization bug (fixed)**: `finalizeAndFinishThroughEndOfInput()` is called by the FEEDER when the input is exhausted — sequencing it after the `transcriber.results` loop deadlocks (results ends only when someone finalizes; the first benchmark remained parked forever).
7. **AVAudioConverter concurrency boundary**: the converter's `@Sendable` input callback receives its fully initialized, immutable source through one private lock-protected one-shot box. The localized `@unchecked Sendable` proof avoids mutable captures and does not suppress AVFoundation concurrency checking at import scope (D118).
8. **Structured cancellation and input ownership**: the input feeder is a child task of the results scope, not an unstructured task. Results completion, error, or consumer cancellation cancels and drains the feeder before output termination; its input continuation always finishes, and one actor gate invokes `cancelAndFinishNow()` at most once. Empty chunks are rejected before AVAudioPCMBuffer construction and no unsafe buffer address is force-unwrapped. First Listen prepares the optional Apple asset before opening the microphone, so a cold wait cannot accumulate an unbounded capture backlog.
9. **Measured comparison (same 60 s of a real EN meeting, system channel, M4 Max)**:

| | Parakeet v3 (CLI) | SpeechAnalyzer en_US (in-app) |
|---|---|---|
| first result | 1.13 s | **1.03 s** |
| finalization lag p50/p95/max | **0.07 / 0.68 / 0.72 s** | 0.47 / 0.82 / 0.82 s |
| emission | 36 append-only finals (small deltas: "uh", "and") | 9 sentence finals + **150 volatile** (replace) |
| final chars | 461 | 603 |
| style | clean | verbatim with disfluencies ("uh") |
| with wrong locale (es_CL over EN) | — | same latency (p50 0.16) but garbage text → detecting language BEFOREHAND matters |

Historical M12 interpretation: both engines stayed below 1 s p95 finalization
lag in this one sample; Parakeet finalized sooner in that measurement. This is
not a current cross-engine quality ranking or evidence for changing the serving
engine. SpeechAnalyzer supports volatile results and custom vocabulary, but
**on-device does not mean no download**: `ensureAssets` resolves a supported
locale and invokes `AssetInventory.assetInstallationRequest` /
`downloadAndInstall` when its Apple-hosted model is missing. Availability depends
on the OS, hardware, locale, and installed assets. Apple's
[SpeechAnalyzer introduction](https://developer.apple.com/videos/play/wwdc2025/277/)
describes that asset lifecycle. A future serving change still needs the exact
bilingual comparison and append-versus-replace integration: Speech volatile
results replace their range; the current caption coalescer assumes deltas.

## Caption coalescer — `CaptionCoalescer` (used by the app)

The newest row grows while the channel keeps speaking: mid-sentence pauses ≤ 6 s stay in the row, continuation < 2 s after a closed sentence flows on the microphone, but on `system`/`room` the pause after a sentence splits earlier (0.6 s) so two consecutive remote participants appear as two `Ellos` rows even before refine. Hard split at 280 chars. Closing is delta-driven (silence alone never closes a row); the Apuntador's D138 endpointer compensates on the intelligence side by consuming the open remote row after 2.0 s of delta silence, without touching this coalescer. Deltas without lexical content are discarded except final punctuation that completes an existing row (an isolated `"."` does not create `Yo: .`). Stable row identity (id/startTime are preserved) → SwiftUI does not rebuild, and translation translates only closed rows (only the last global row can grow).

The merged live projection also applies a bounded twelve-row cross-channel
admission rule (D131). Matching microphone spill is dropped when recent direct
system or room speech already exists; a delayed direct row replaces a matching
microphone copy only while that mic row is still newest and open. Older rows
stay immutable after translation or rolling-summary consumers can observe
them. One-word acknowledgements always survive. An exact two-word copy is
admitted as bleed only when the microphone and direct timelines truly overlap;
three contiguous words at either rolling edge can reject a longer noisy copy.
Sequential acknowledgements and distinct overlapping speech remain. Raw
channels and finalized audio stay unchanged. A separate presentation
projection groups consecutive microphone rows or the same stable live voice
without changing source rows, translations, Companion evidence, or rolling
summary cursors. Generic `Them` never groups because it may still represent
two different voices. This projector owns its 150-source-row tail rather than
relying on a particular view caller. The controller still keeps every admitted
caption for Stop and recovery. The separate five-minute talk-balance cue caps
its candidate scan at 1,024 closed rows before applying the time window, so
live presentation work does not grow with meeting duration.

## Live translation lanes (D128)

The source transcript remains a multilingual sequence. For each closed row,
`LiveTranslationRouting` first trusts its persisted BCP-47 language. If that is
absent, a local `NLLanguageRecognizer` fallback requires at least 12 letters and
confidence of 0.65; shorter or uncertain rows remain exactly as spoken. Rows
already in the selected target language are also left untouched.

Eligible rows are grouped into one explicit source-to-target lane at a time.
The macOS adapter constructs `TranslationSession.Configuration` with both
languages; it never supplies a nil source and therefore never delegates source
selection to a framework modal during the meeting. Download consent belongs to
that exact pair. Switching the target cancels and fences old work, clears
translated rows, unsupported-passthrough IDs, active source, and consent, then
resolves the new lanes from the original transcript. An unsupported pair keeps
its closed rows exactly as spoken and marks them handled, allowing routing to
advance to later supported languages while the UI reports partial support.
The newest growing row can translate before another speaker closes it once it
has enough language evidence. Its stable ID is paired with the exact translated
source text, so another request is admitted after at least 18 characters of
growth or a sentence boundary rather than leaving a stale partial translation.
`TranslationSession.translate(batch:)` responses publish as they arrive. A
labeled indigo language rail visually separates translated text from the
spoken row. Routing and state transitions have deterministic mixed
Spanish/English, same-target, unknown, unsupported-then-supported, consent,
cancellation, and stale-result tests, including growing-row revisions.

### Signal-driven live translation (D169/D433)

The active lane subscribes once to a recording-owned `LiveTranslationWakeHub`.
New captions, live-speaker splits, target/source changes, pair consent, and
unsupported-passthrough updates broadcast a content-free invalidation signal.
Each subscriber buffers only the newest wake. Idle, download-gated, and
unsupported lanes await that signal rather than polling every 300 ms; only
actual Apple framework execution errors use deterministic 1, 2, 4, then
8-second capped retry backoff. Installed pairs start without repeat consent;
downloadable pairs wait for exact pair-scoped consent and one preparation
attempt; unsupported pairs remain visible. Preparation failure returns to the
consent boundary instead of opening an automatic retry loop.

Routing examines the newest 60 rows as an explicit live-context window and
sends no more than eight chronological rows in one framework request.
Successful batches drain immediately through another bounded request. Every
iteration keeps the full source/target fence. Result admission additionally
requires the current row UUID, exact requested source text, and source language
to match. Duplicate current row identities, blank translations, and partial
batches fail closed and cannot complete the batch; this prevents a late result
from flashing over a newer form of a still-growing row.
The final controller boundary also checks the caller's cancellation state,
not just its pair: choosing the same pair again does not authorize an old
cancelled callback. Lane selection, unsupported IDs, rendered rows, state, and
download-consent revocation share this rule. Cancellation before provider work
or during a streamed batch ends the task without claiming a provider failure;
ordinary preparation failures continue to require fresh explicit consent.
Rows that fall outside the live window before translation remain in their
spoken language. Source captions, final transcript evidence, audio capture,
and Refine are independent from this optional relay.

## Vocabulary — `VocabularyPrompt`

`parse()` (comma-separated, trim, dedup) and `text()` (natural EN/ES sentence according to the homogeneous spoken language). Sources: app Ajustes (UserDefaults `customVocabulary`, list editor), CLI `--vocab`. **VocabularyMiner** (pure, 6 tests): mines domain-shaped terms (acronyms, letter+digit codes, CamelCase — never ordinary capitalized words) that recur ≥3 times in the last 12 transcripts and suggests them as chips in Ajustes → Vocabulario. **Review-before-adding flow** (field case: the miner suggests what Whisper HEARD — it suggested "Qord2M" when the real term was "Kord2m"): the chip preloads the text field to correct the spelling and confirm with Add; ✕ rejects it forever (`vocabularyRejectedSuggestions` in defaults, excluded by the miner); adopting an edited version also rejects the raw misheard form so it does not return. It does not run under XCUITest to avoid shifting the layout asynchronously. Consumers: WhisperEngine (promptTokens only when the language is homogeneous), summaries (glossary, spec 04). **Live Parakeet has no bias hook** — refine corrects the record.

## Known limitations

1. Live Parakeet degrades with non-native accents (verified: an accented EN contribution was garbled live; the same audio through Whisper was clean) — current response: refine.
2. System-wide dictation is implemented in the macOS app (⌥⌘D by default,
   configurable, with a non-activating panel and Accessibility paste/restore;
   see spec 06). It reuses live Parakeet and does not change meeting capture.
3. ~~Quantized Whisper models not yet in the catalog~~ — **DONE (M12)**:
   **626 MB** variant (`whisper-large-v3-626mb`, 17 artifacts sha256-pinned to
   the same argmax commit as turbo) for low disk space.
   `WhisperEngine.loadPrepared(_:)` loads the verified descriptor selected by
   `AppServices.acquireWhisperRuntime`; the "Whisper compacto" toggle
   (Ajustes) selects the compact descriptor, while the recommender enables it
   when low disk space is detected. Refine freezes that selection for its whole
   operation, and Turbo remains the default.
4. ~~FluidAudio pinned by revision `c367a18e`~~ — **RESOLVED**:
   `Package.swift` uses `.upToNextMinor(from: "0.15.5")`, which contains the
   upstream #732 type-checker fix.
