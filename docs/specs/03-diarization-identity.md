# Spec 03 — Diarization and identity (DiarizationKit + naming)

Status: implemented; DER verified against real AMI; real meeting processed. Decisions: D5 (structural Me), D17 (threshold), D21 (voiceprint + verified names).

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

## LIVE diarization — `LiveSpeakerLabeler` (Jul 2026)

Field request: two remote voices speaking one after the other were merged into a single live "Ellos" row — it was not apparent that they were two people. Pipeline:

- `RecordingController` feeds the system channel to a **DEDICATED instance** of `PyannoteDiarizer` (fresh SpeakerManager per session — the durable post-capture pass remains uncontaminated) via `diarize(AsyncStream)`, in 10 s windows; inference runs on the diarizer actor (~14 MB, ms per window — it never competes with Parakeet's live lane).
- With each turn, `LiveSpeakerLabeler.relabel` (pure, idempotent, 7 tests) relabels CLOSED system rows: a row that crosses two voices is **split** at turn boundaries (reuses `SpeakerAttributor`, proportional word distribution), and each piece shows its **S1/S2** pill (or "Me"→"Yo" via voiceprint). The last row (still growing, a coalescer invariant) is never touched; rows without a covering window remain "Ellos". Split rows receive new IDs → live translation picks them up automatically (it translates closed rows without a translation).
- Live labels are **ephemeral hints**: after Stop's durable handoff, the process-scoped batch pass (`diarizeFile` + micro-cluster merge + attribution) remains the truth and reattributes everything from the file; live S-numbers do not have to match the final ones.
- Best-effort: if the models fail to load, the feed closes (an entire meeting is not accumulated in memory), and captions remain "Ellos" as before.
- **Verified with a real meeting** (Jul 2026): the streaming path found ≥2 voices in the first 4 min of the system channel and processed them in 2.4 s (~100× real time) — gated test `testLiveStreamingPathFindsMultipleVoices`.

## Voiceprint — `VoiceprintStore` (D8/D21)

- 256-dim WeSpeaker embedding from ~12 s of voice alone (the source audio is NOT retained). AES-GCM encrypted; the key is ONLY in Keychain (service `app.portavoz.voiceprint-key`, injectable for tests). `delete()` destroys the file + key in one action. It is never synchronized (reenrollment per device).
- Enrollment: app (Ajustes → "Enrolar mi voz", 12 s) or CLI `voice enroll --file <wav>`. The diarizer loads it with `initializeKnownSpeakers(isPermanent: true)` → reserved cross-channel "Me" label (hybrid meetings: your voice arriving through the room/system is also yours).

## Remembered participant voices (Jul 2026) — cross-meeting naming

Field request: remember a participant's voice across meetings to autosuggest their name. STRICTER rules than for the user's own voiceprint (storing third-party biometrics is more sensitive, D8):

- **`VoiceGallery`** (`voice-gallery.enc`, same pattern as VoiceprintStore: AES-GCM, key only in Keychain service `app.portavoz.voice-gallery-key`, never sync). A voice is added ONLY through an explicit gesture: the "Remember X's voice?" chip that appears after confirming a name (manual rename or applied chip). Rerecording someone REPLACES their embedding (one per person, case-insensitive). Individually removable (context menu in Ajustes → "Remembered voices"), and "Forget all voices" destroys the file + key in one action.
- **`PyannoteDiarizer.extractVoiceprints(fromFile:rangesBySpeaker:minimumSeconds:maximumSeconds:)`**: one embedding per speaker from their system-channel spans — resamples the file ONCE, slices by ranges (longest first up to 20 s; < 5 s is discarded: a short embedding would match noise). Embeddings are transient: NOTHING is persisted here.
- **`VoiceMatcher`** (pure, 5 tests): its own cosine distance (outside FluidAudio — internal clustering does not work cross-meeting), threshold `maxCosineDistance = 0.54` (the same effective yardstick as D17 clustering; pending field calibration). Each speaker receives at most their closest voice, and each gallery voice is suggested for at most one speaker (two speakers cannot both be "Marta"). Degenerate embeddings (norm 0, different dimensions) never match.
- **UI (MeetingDetailView)**: when opening a detail with unnamed speakers + a nonempty gallery, an EPHEMERAL diarizer (~14 MB; heavy engines are NOT loaded) extracts and matches once per visit → "S1 → ¿Marta?" chips with a waveform icon (the evidence is the voice, not the transcript — therefore it does NOT pass through `NameSuggestionFilter`). Same D21 contract: chip, click, never applied automatically.

## Automatic names (D21) — IntelligenceKit

- `SpeakerNamer.suggestNames`: proposes label→name ONLY with evidence. `NamingExcerpt` builds the context: first 3 substantial interventions (≥25 chars) per speaker + lines that mention calendar candidates, chronological, capped at 2000 chars (a blind prefix overflowed the 4096 window and saw only the beginning). Retry with an excerpt half the size if it still overflows.
- **Never-trust-verify** (`NameSuggestionFilter`, pure and tested): the proposed name must appear LITERALLY in the full transcript OR among the calendar attendees (the model fabricates names with fabricated evidence — observed: "John" from nowhere).
- `CalendarAttendeeSource` (IntegrationsKit): attendees of EventKit events around the meeting as candidates (requests calendar TCC).
- UI: "S1 → ¿Ana?" chips with evidence in a tooltip; one click applies; nothing is applied automatically.

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

After launch recovery, the process worker claims a matching diarization job,
keeps its lease alive, and checks the identity again. It runs only finalized
system audio longer than one second. Silent or absent remote audio produces no
turns. Model load/inference failure retains the released best-effort behavior
and publishes honest unattributed system segments; a finalized audio path that
has disappeared is a durable retryable failure. `SpeakerAttributor` output,
homogeneous language, transcript revision increment, job success, and the exact
dependent summary enqueue share one StorageKit transaction. D43 makes normal
Stop produce the first exact job atomically with captured content, using the
same recording-scoped voiceprint value that seeded live diarization.

## Known limits

1. Formal DER for a real meeting pending (draft RTTM awaiting user correction in `~/Desktop/portavoz-verificacion/`).
2. Sortformer (better for fast dialogue, according to humla) not evaluated; Argmax's SpeakerKit (same package as WhisperKit) is an alternative to benchmark.
3. Attribution with long coalesced rows relies more on proportional distribution (acceptable, not measured separately).
