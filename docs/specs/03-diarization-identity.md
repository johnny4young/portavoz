# Spec 03 — Diarization and identity (DiarizationKit + naming)

Status: implemented; DER verified against real AMI; real meeting processed. Decisions: D5 (structural Me), D17 (threshold), D21 (voiceprint + verified names), D46 (degradable external-audio attribution), D47 (reviewable refine attribution), D48 (application-owned initial Stop request), D49 (recording-scoped Start runtime), D65 (accepted Refine transcript provenance), D86 (explicit canonical people), D103 (terminal diarization and local-voice workflows), D104 (application-owned durable attribution policy), D105 (application-owned participant voice memory), D106 (application-owned app enrollment), D107 (application-owned verified name suggestions).

## PyannoteDiarizer — `Sources/DiarizationKit/PyannoteDiarizer.swift`

- pyannote community-1 (segmentation) + WeSpeaker v2 (embeddings) via FluidAudio; 10 sha256-pinned artifacts (~14 MB). `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)` loads from explicit paths and **never downloads** (unlike `AsrModels.load`).
- Streaming in 10 s windows with `atTime` (the internal `SpeakerManager` keeps S1/S2… stable across windows) + batch `diarizeFile`.
- **`clusteringThreshold = 0.45` (D17) — DO NOT RAISE**: FluidAudio's internal wiring multiplies by ×1.2 (effective cosine distance 0.54). Measured calibration: at 0.50 the AMI sample already merges its 2 real speakers (DER 7.6% → 49.8%); but in a real remote meeting 0.45 fragments (11 clusters where there were ~4; distances 0.55–0.64). Fragmentation is addressed post-clustering, not with the threshold.
- **`sanitizeTurns`**: labels that appear only in the last window (zero-padded by the model) with quality < 0.35 are discarded — the final window routinely produces a phantom speaker (q ≈ 0.2). "Me" is never touched.
- **`mergeMicroClusters`** (batch/`diarizeFile` only): labels with < 15 s of total speech yield each turn to the temporally nearest major label. Verified: real meeting 11 → 4 speakers; AMI unchanged (7.6%). Biometric rules: "Me" never absorbs or is absorbed (a phantom Me would contaminate action item owners); with no majors available, turns remain unchanged (short meeting ≠ fragmentation). 6 tests.
- One instance = one session (SpeakerManager accumulates the voice base): different meetings do NOT share a diarizer.
- **Do not calibrate with TTS**: `say` voices share a vocoder and are nearly indistinguishable to WeSpeaker. Calibration fixture: `sample.wav` + `sample.rttm` from pyannote-audio (real AMI, 2 speakers, public ground truth).

## Attribution — `SpeakerAttributor` (pure functions)

- Mic channel → "Me" (hardware truth, D5). System channel → turn with the greatest temporal overlap.
- Multi-turn segments are split at turn boundaries with proportional word distribution. No turn → unattributed (honest, editable in the UI).
- Turns labeled "Me" (voiceprint on the system channel) are merged with the user's identity.

Standalone terminal diarization enters `ApplicationKit.DiarizeAudioFile`.
ApplicationKit owns file admission, threshold forwarding, elapsed-time policy,
fresh meeting identity for optional transcript attribution, and attributed
speaker/segment results. The executable processor owns pinned model loading,
the optional encrypted local voiceprint read, pyannote inference, and the
Parakeet attribution pass. The command retains only argument parsing and the
existing turn/transcript rendering (D103).

For external audio, `ApplicationKit.ImportMeeting` requires the initial shared
recording-engine preparation before transcription, preserving the released
model-readiness contract. Immediately before attribution it asks the app
processor to reload the diarizer because another idle-release task may have
dropped the shared reference during the Whisper pass. The second reload is
best-effort and does not suppress the inference attempt: if an already-loaded
shared diarizer remains usable, attribution can still succeed. If no usable
diarizer remains or inference fails, the workflow installs the full transcript
with no invented speakers or speaker IDs. Storage then commits the meeting,
any attributed cast, and all segments atomically (D46).

For the in-app quality pass, `ApplicationKit.RefineMeeting` asks its processor
port to diarize only a non-silent system channel after Whisper succeeds. A
diarizer error is degradable and publishes a review draft with the full honest
transcript but no invented speakers or speaker IDs; `CancellationError` is
explicitly rethrown so a canceled quality pass cannot surface a draft. The
draft carries the transcript revision used for attribution. If accepted,
StorageKit validates every speaker/segment identity and speaker reference,
then replaces cast, transcript, language, and revision atomically; a stale
draft or invalid child preserves the current aggregate (D47). The accepted
segments also link to Refine's composite Whisper generation run in that same
transaction. Inline best-effort diarization does not yet receive a separate
run/artifact link; D65 records the coherent transcript operation without
misrepresenting diarizer failure as transcript failure.

Accepted Refine speakers are fresh meeting observations with fresh IDs. Even
if a prior speaker had a D86 canonical-person link, Refine does not copy it by
label, display name, alias, or voice suggestion. The person remains stored,
but the new observed speaker requires a fresh explicit confirmation; this
prevents unstable diarization labels from becoming cross-meeting identity.

## LIVE diarization — `LiveSpeakerLabeler` (Jul 2026)

Field request: two remote voices speaking one after the other were merged into a single live "Ellos" row — it was not apparent that they were two people. Pipeline:

- `RecordingController` feeds the system channel to a **DEDICATED instance** of `PyannoteDiarizer` (fresh SpeakerManager per session — the durable post-capture pass remains uncontaminated) via `diarize(AsyncStream)`, in 10 s windows; inference runs on the diarizer actor (~14 MB, ms per window — it never competes with Parakeet's live lane).
- With each turn, `LiveSpeakerLabeler.relabel` (pure, idempotent, 7 tests) relabels CLOSED system rows: a row that crosses two voices is **split** at turn boundaries (reuses `SpeakerAttributor`, proportional word distribution), and each piece shows its **S1/S2** pill (or "Me"→"Yo" via voiceprint). The last row (still growing, a coalescer invariant) is never touched; rows without a covering window remain "Ellos". Split rows receive new IDs → live translation picks them up automatically (it translates closed rows without a translation).
- Live labels are **ephemeral hints**: after Stop's durable handoff, the process-scoped batch pass (`diarizeFile` + micro-cluster merge + attribution) remains the truth and reattributes everything from the file; live S-numbers do not have to match the final ones.
- Best-effort: if the models fail to load, the feed closes (an entire meeting is not accumulated in memory), and captions remain "Ellos" as before.
- **Verified with a real meeting** (Jul 2026): the streaming path found ≥2 voices in the first 4 min of the system channel and processed them in 2.4 s (~100× real time) — gated test `testLiveStreamingPathFindsMultipleVoices`.

The private `StartRecordingRuntime` creates exactly one recording-scoped
voiceprint task after reservation and keeps it inside the opaque active
session. `RecordingController` awaits that same future for live diarization;
`ApplicationKit.StopRecording` receives the same value for the exact durable
operation. Stop cancels the read only after the handoff completes, so live and
batch identity cannot accidentally sample different enrollment state (D49).

## Voiceprint — `VoiceprintStore` (D8/D21)

- 256-dim WeSpeaker embedding from ~12 s of voice alone (the source audio is NOT retained). AES-GCM encrypted; the key is ONLY in Keychain (`app.portavoz.voiceprint-key`). `VoiceprintStore` receives the Core `SecretStoring` port from app/CLI composition and never imports or constructs Keychain. `delete()` destroys the file + key in one action. It is never synchronized (reenrollment per device).
- Enrollment: app (Settings → "Enroll my voice", 12 s) or CLI `voice enroll --file <wav>`. Every path enters `ApplicationKit.ManageLocalVoiceIdentity`. CLI enrollment admits a source file. Settings requests a fresh echo-cancelled capture; Onboarding either reuses its already captured first-listen sample or requests a fresh raw capture. The workflow bounds capture to 1...60 seconds, requires at least four seconds of finite sample data, emits typed capture/extraction/persistence progress, and writes only after extraction succeeds. App composition retains microphone lifetime, exact capture mode, guaranteed stop, verified pyannote loading, transient extraction, encrypted Keychain-backed storage, and diarizer invalidation after a successful save/delete. A failed delete remains visible and does not clear the enrolled state. Disposable UI-test composition never reads or mutates the host identity. Status and delete never load a model or read source audio (D103/D106). The diarizer loads the enrolled value with `initializeKnownSpeakers(isPermanent: true)` → reserved cross-channel "Me" label (hybrid meetings: your voice arriving through the room/system is also yours).

## Remembered participant voices (Jul 2026) — cross-meeting naming

Field request: remember a participant's voice across meetings to autosuggest their name. STRICTER rules than for the user's own voiceprint (storing third-party biometrics is more sensitive, D8):

- **`VoiceGallery`** (`voice-gallery.enc`, same pattern as VoiceprintStore: AES-GCM, key only in Keychain service `app.portavoz.voice-gallery-key`, never sync). It receives the same injected Core secret port. A voice is added ONLY through an explicit gesture: the "Remember X's voice?" chip that appears after confirming a name (manual rename or applied chip). Rerecording someone REPLACES their embedding (one per person, case-insensitive). Individually removable (context menu in Ajustes → "Remembered voices"), and "Forget all voices" destroys the file + key in one action. The app adapter performs gallery reads and writes on a utility executor so the encrypted file and securityd cannot block MainActor; `-use-temp-store` returns an empty gallery and never inspects the host biometric file or key.
- **`PyannoteDiarizer.extractVoiceprints(fromFile:rangesBySpeaker:minimumSeconds:maximumSeconds:)`**: one embedding per speaker from their system-channel spans — resamples the file ONCE, slices by ranges (longest first up to 20 s; < 5 s is discarded: a short embedding would match noise). Embeddings are transient: NOTHING is persisted here.
- **`VoiceMatcher`** (pure, 5 tests): its own cosine distance (outside FluidAudio — internal clustering does not work cross-meeting), threshold `maxCosineDistance = 0.54` (the same effective yardstick as D17 clustering; pending field calibration). Each speaker receives at most their closest voice, and each gallery voice is suggested for at most one speaker (two speakers cannot both be "Marta"). Degenerate embeddings (norm 0, different dimensions) never match.
- **Application workflow (D105):** `ManageMeetingVoiceMemory` loads one coherent detail, considers only unnamed non-user speakers, degrades gallery/extraction failure to no suggestions, and applies `VoiceMatcher` one-to-one. An explicit remember request must still identify a currently named non-user speaker; insufficient audio is typed and a gallery write failure remains visible. The app adapter owns recording-path resolution, the ephemeral diarizer (~14 MB; heavy engines are NOT loaded), transient extraction, encrypted storage, and disposable-test isolation.
- **UI (MeetingDetailView):** opening an eligible detail asks the route-owned
  `MeetingDetailModel` to load suggestions once and renders "S1 → ¿Marta?"
  chips with a waveform icon (the evidence is the voice, not the transcript —
  therefore it does NOT pass through `NameSuggestionFilter`). The model owns
  suggestion state and explicit actions/effects, removes a chip only after the
  rename persists, and keeps a failed confirmation visible. Same D21 contract:
  chip, click, never applied automatically. SwiftUI does not read the gallery,
  resolve audio files, load a model, extract embeddings, or perform matching.

## Automatic names (D21/D107)

- `SpeakerNamer.suggestNames`: proposes label→name candidates for explicit
  review. `NamingExcerpt` builds the context: first 3 substantial interventions
  (≥25 chars) per speaker + lines that mention calendar candidates,
  chronological, capped at 2000 chars (a blind prefix overflowed the 4096
  window and saw only the beginning). Retry with an excerpt half the size if it
  still overflows.
- **Application workflow:** `SuggestMeetingSpeakerNames` loads one coherent
  meeting detail, excludes `Me` and already named speakers before optional
  work, obtains calendar candidates through a port, invokes an untrusted
  proposer, trims and deduplicates eligible labels, and independently verifies
  each normalized name as complete tokens in a real transcript line or calendar
  candidate. It derives typed evidence from that exact source and ignores
  generator-authored evidence prose. Missing meetings are typed; generation
  failure remains visible; no proposal mutates a speaker.
- **Defense in depth:** `NameSuggestionFilter` also verifies the concrete
  Foundation Models output before the app adapter maps it into the application
  contract. The model has fabricated names with fabricated evidence, so neither
  layer trusts substring matches or prose evidence alone.
- `CalendarAttendeeSource` (IntegrationsKit) owns EventKit candidates and the
  explicit TCC request. The route-owned `MeetingDetailModel` owns loading and
  suggestion state, removes a chip only after the rename persists, and keeps a
  failed confirmation visible. SwiftUI renders "S1 → ¿Ana?" chips with a
  localized transcript or calendar-candidate tooltip; one click applies, and
  nothing is applied automatically. Accepted calendar candidates use
  `PersonAliasSource.calendarSuggestion`, not transcript provenance.

## Canonical people (Band 5A / D86)

- `Speaker` remains one meeting observation. Its optional `personID` links to
  one user-confirmed `Person`; labels, accepted display names, calendar
  attendees, and voice matches are never identity by themselves.
- After a user manually renames a non-user speaker or accepts a transcript,
  calendar, or voice suggestion, Meeting Detail shows a separate explicit
  Remember action. The evidence source is retained as alias provenance but
  cannot invoke persistence automatically.
- Exact normalized aliases are candidate lookup only. No candidate lets the
  explicit action create a person; one or more candidates open a chooser that
  also offers “Create a separate person.” Duplicate human names therefore stay
  representable rather than being silently merged.
- `Me` remains structural hardware/voiceprint identity and is excluded from
  this first other-participant person vertical. `VoiceGallery` remains an
  independent encrypted file with its existing explicit consent, deletion,
  and no-sync behavior; schema v8 does not bind it to `Person`.
- A confirmed speaker pill shows a local checkmark. `.portavoz` bundles keep
  the meeting-local display name but strip `personID`, so the receiving device
  does not inherit private identity claims.

## Evaluation — `DiarizationEvaluation` + `portavoz-cli der`

- `parseRTTM` + scoring with FluidAudio's `DiarizationDER`. **Units**: miss/falseAlarm/confusion arrive in SECONDS and `der` as a ratio → normalize by total reference speech.
- Measured: **AMI 7.6%** (miss 3.7 / FA 1.3 / conf 2.6, collar 0.25 s) — M3 criterion < 15% ✓.

## Durable post-capture execution (D42)

`DiarizationOperationFingerprint` is the exact versioned identity of one
post-capture attribution attempt. It length-prefixes and hashes the meeting and
transcript revision, sorted full segment identity (including original per-turn
language), pinned diarization model/revision, clustering threshold, finalized
system-audio health/hash/duration evidence, and enrolled voiceprint. Pending or
incomplete runnable audio evidence cannot produce a job identity; no system
asset and terminal missing/corrupt evidence are explicit stable states.

After launch recovery, `ApplicationKit.ProcessPostCaptureJobs` claims a matching
diarization job, keeps its lease alive, and checks the identity again. It asks
the app capability adapter to process only finalized system audio longer than
one second. Silent or absent remote audio produces no turns. Model
load/inference failure retains the released best-effort behavior and publishes
honest unattributed system segments; a finalized audio path that has
disappeared is a durable retryable failure. `SpeakerAttributor` output,
homogeneous language, transcript revision increment, job success, and the exact
dependent summary enqueue share one StorageKit transaction. The application
workflow owns lease, dependency, retry, cancellation, and completion policy;
the adapter owns recording-path resolution, the encrypted voiceprint read,
pyannote loading, and inference. For normal capture,
`ApplicationKit.StopRecordingJobFactory` produces the first exact job and
`StopRecording` admits it atomically with captured content, using the same
recording-scoped voiceprint future that seeded live diarization (D48/D49/D104).

## Known limits

1. Formal DER for a real meeting pending (draft RTTM awaiting user correction in `~/Desktop/portavoz-verificacion/`).
2. Sortformer (better for fast dialogue, according to humla) not evaluated; Argmax's SpeakerKit (same package as WhisperKit) is an alternative to benchmark.
3. Attribution with long coalesced rows relies more on proportional distribution (acceptable, not measured separately).
