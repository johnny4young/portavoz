# Spec 05 — Persistence (StorageKit)

Status: implemented and in production (the user's DB survived a real incident thanks to tombstones). Decisions: D4 (frozen contract), D19 (GRDB+FTS5), D36 (additive v6 durability foundation), D37 (provisional recording rollback), D38 (captured Unit of Work), D39 (durable job leases and idempotency), D40 (evidence-first launch recovery), D41 (atomic generated-artifact completion), D42 (process-scoped exact execution), D43 (atomic Stop handoff), D44 (application dependency ratchet), D45 (newest immutable detail snapshot), D46 (atomic imported aggregate), D47 (revision-fenced refined aggregate), D48 (application-owned Stop policy).

## Database

GRDB 7 (`upToNextMajor(from: 7.11.1)`), SQLite WAL, at `~/Library/Application Support/Portavoz/portavoz.sqlite` (`MeetingStore.defaultDatabaseURL`; CLI accepts `--db`).

### Schema (`v1`–`v6` migrations in `Sources/StorageKit/Schema.swift`)

Singular camelCase tables, 1:1 with Codable records:

| Table | Key columns |
|---|---|
| `meeting` | id (UUID TEXT PK), title, startedAt, endedAt, language, audioDirectory (RELATIVE), retention, visibility (reserved), **lifecycleState**, **transcriptRevision**, **lastProcessingError** (v6), createdAt/updatedAt/deletedAt |
| `speaker` | id, meetingID (FK CASCADE), label (S1/Me…), displayName, isMe, tombstone |
| `segment` | id, meetingID, speakerID?, channel, text, language?, startTime/endTime, confidence?, isFinal, **embedding BLOB** (v2), tombstone |
| `summary` | id, meetingID, recipeID, language, markdown, **version** (UNIQUE meetingID+recipeID+version — immutable snapshots), **fingerprint** (v4, D25 — language-independent material identity; NULL in old snapshots = never match) |
| `actionItem` | id, summaryID (FK CASCADE), meetingID, text, ownerSpeakerID?, isDone (the MUTABLE exception), tombstone |
| `contextItem` (v3) | id, meetingID (FK CASCADE), kind (note/link/codeSnippet/file), content, timestamp (seconds from start), tombstone — user notes (D28) |
| `companionCard` (v5) | id, meetingID (FK CASCADE), question, answer, kind, source, directed, askedAt, createdAt/updatedAt/deletedAt — reviewable Companion snapshot (D26) |
| `audioAsset` (v6) | id, meetingID, channel, role, unique relativePath, optional finalized media metadata/checksum/levels, healthStatus, sourceAssetID lineage, createdAt/updatedAt/supersededAt/deletedAt |
| `processingJob` (v6) | durable job state, priority/progress, retries, scheduling/lease/error timestamps; UNIQUE meetingID+kind+inputFingerprint |
| `generationRun` (v6) | provider/model/config/input/output/outcome/metrics envelope; nullable `generationRunID` FKs were added to segment, summary, and companionCard |
| `outboxEvent` (v6) | idempotent external-side-effect envelope with delivery state, attempts, and retry/delivery timestamps |
| `meetingPreference` (v6) | one row per meeting for independent transcript/summary language modes and optional recipe/summary/refine engines |
| `segmentSearch` | FTS5 external-content over segment.text, synchronized by ai/ad/au triggers |

Schema v6 is an additive foundation (D36). Existing meetings migrate to
`ready`, revision zero, and no processing error. The migration does not inspect
the filesystem or synthesize `audioAsset` rows, so `Meeting.audioDirectory`
remains the authoritative product audio reference for legacy and new meetings.

Band 1 slice 1B adopts the first v6 workflow surface. `AudioAssetID`,
`AudioAsset`, and `AudioAssetRecord` map typed channels and strict health
states. `MeetingStore.beginRecording` inserts one `recording` meeting plus all
pending capture assets in a single transaction before sources start;
`audioAssets(for:)` exposes them only through a live meeting root.

Slice 1C reserves `<audioDirectory>/<channel>.partial.caf` and introduces
`MeetingStore.installCapturedSnapshot`. After filesystem publication, this one
transaction verifies that the live recording shell is untouched and the asset
IDs/channels/creation timestamps exactly match their pending reservations. It
then advances the meeting to `captured`, updates published assets with complete
CAF/checksum/level/health metadata (or explicit metadata-free missing/pending
state), and inserts the provisional live cast/transcript, notes, and Companion
cards. A changed shell, preexisting child/summary, malformed finalized
metadata, final-path uniqueness collision, or child insert failure rolls the
entire transaction back.

D43 extends this boundary with `installCapturedSnapshot(_:enqueue:at:)`.
Normal Stop supplies the exact initial diarization request, and the same
transaction installs captured content, inserts that immutable-key job, and
derives `processing`. A job constraint/write failure therefore rolls the
snapshot and job back together; package tests inject that failure and verify
the original recording shell plus pending reservation remain untouched.

Slice 1D-a maps `processingJob` through strict `ProcessingJobID`, open typed
kinds, states, requests/failures, and `ProcessingJobRecord`. One enqueue
transaction inserts each `(meetingID, kind, inputFingerprint)` only once and
derives the aggregate lifecycle; re-enqueue returns the original row without
changing its execution policy or reviving terminal work. Workers claim only
supported kinds from live meetings, ordered by priority and due time, and every
heartbeat/success/failure write requires the same unexpired owner lease.
Progress is monotonic, retry delay is durable in `notBefore`, and repeat-safe
expired-lease recovery either returns work to pending or exhausts it. Active
jobs keep the meeting `processing`; after active work ends, failure yields
`needsAttention` and otherwise terminal work yields `ready`.

The first 1D-b2b control-plane unit adds owner-leased cancellation and scheduled
wake discovery. Cancellation records a terminal reason without claiming an
artifact exists; because it represents intentionally degradable or superseded
work, it does not make the aggregate fail. `nextScheduledProcessingDate`
returns the earliest future `notBefore` for explicit worker capabilities while
excluding deleted meetings and exhausted attempts, allowing workers to sleep
without polling.

Slice 1D-b1 adds `installRecoveredCaptureAssets`, a repeat-safe transaction
for the filesystem/SQLite Saga. It replaces the exact pending reservation set
with fully validated published/missing evidence, preserves immutable asset
identity and ownership, rolls the entire update back on any conflict, and
allows an exact finalized repeat as a no-op. An interrupted `capture.*`
`needsAttention` shell can install the recovered captured snapshot directly;
an already-ready meeting can validate exact evidence but cannot be downgraded
or mutated. Publication-only recovery returns an aggregate with existing
transcript content and no jobs to `ready`; usable audio without transcript is
retained as `needsAttention` with `transcription.empty`.
`markMeetingNeedsAttention` is repeat-safe and accepts only incomplete live
states. The app invokes expired-lease recovery and these boundaries at process
launch, then runs the concrete D42 diarization/summary executor. Normal Stop
now reaches it through D43's atomic snapshot/initial-job handoff. The isolated
characterization fixture uses the same exact request factory and normal queue
admission without real capture evidence.
Generation runs, outbox events, and per-meeting preferences are also not
consumed yet.

The migration is verified both by a deterministic v5 fixture and by migrating
a scratch copy of the real release database: legacy logical rows and meeting
fields were preserved, the new workflow tables remained empty, integrity was
`ok`, and foreign-key violations remained zero. The live database was never
opened by v6 code.

### D4 contract (enforced, not aspirational)

- PKs = UUID string. `updatedAt` on every write, `createdAt` preserved on updates (`save()` methods fetch first).
- Persisted identity is strict: every UUID-bearing record and read model uses
  `PersistedIdentity`; malformed values throw
  `StorageError.invalidPersistedUUID` and are never replaced with a fresh UUID
  or silently omitted. Invalid persisted record enums such as segment channel
  and card/context kind throw `StorageError.invalidPersistedValue` rather than
  changing meaning.
- **Tombstones for user meetings** (`deletedAt`; future sync needs them). The
  sole D37 exception is `discardUnstartedRecording`: it can hard-delete only a
  shell still in `recording` state with no speaker, segment, summary, context
  item, or Companion card, and the controller calls it only when no reserved
  channel file exists. Assets cascade with that no-data rollback. Any file or
  content preserves the meeting for recovery.
- **Relative paths only**: `save(meeting)` REJECTS absolute paths or `..` (`StorageError.absolutePathRejected`).
- Schema-v6 `audioAsset.relativePath` independently rejects absolute and
  parent-traversal paths. Reserved assets may leave finalized media metadata
  NULL, but channel, role, path, health state, and timestamps are mandatory.
- Meeting lifecycle values, non-negative transcript revisions, bounded job
  progress/retries, unique job fingerprints, and fixed-language requirements
  are database constraints rather than caller conventions.
- Embedding preserved when the text did not change (segment save compares text).

## MeetingStore — API

Recording durability APIs are `beginRecording(_:assets:)` (atomic shell plus
reservations), `audioAssets(for:)` (strict, live-rooted read), and
`discardUnstartedRecording(_:)` (D37-guarded no-data rollback).
`installCapturedSnapshot(_:enqueue:at:)` is the D38/D43 Unit of Work for the
first durable post-capture projection and optional initial jobs; it accepts
only an untouched `recording` shell with the exact pending reservation set and
at least one published healthy, silent, or clipped channel. Recovery uses
`installRecoveredCaptureAssets(_:for:at:)`, the same captured Unit of Work for
an interrupted `capture.*` shell, and
`markMeetingNeedsAttention(_:errorCode:endedAt:at:)`; these operations protect
ready aggregates and are exact-repeat safe (D40).

Durable work APIs are `enqueueProcessingJobs(for:requests:at:)`,
`processingJobs(for:)`, `claimNextProcessingJob(kinds:owner:leaseDuration:at:)`,
`heartbeatProcessingJob`, `completeProcessingJob`,
`completeDiarizationJob`, `completeSummaryJob`, `failProcessingJob`, and
`cancelProcessingJob`, `nextScheduledProcessingDate`, and
`recoverExpiredProcessingJobs`. Claims and scheduled wakes are capability-
filtered and owner-fenced; generated work must use its artifact completion API, while the
generic completion path remains available only to non-content jobs. Storage
derives meeting lifecycle rather than asking callers to save a second,
potentially inconsistent aggregate state.

The existing aggregate API remains:
`save(meeting/speakers/segments/contextItems)`, `contextItems(for:)`, `deleteContextItem(_:)` (tombstone), `save(companionCards:for:)`, `companionCards(for:)`, `deleteCompanionCard(_:)`, and `replaceCompanionCards(_:for:)` (atomic replacement with tombstones), `meetings(includeDeleted:)`, `detail(id)` (live meeting+speakers+segments), `delete(id)` (tombstone), `saveSummary(draft)` (auto-incrementing version per meeting+recipe; never touches previous snapshots; persists the D25 fingerprint), `summary(id:recipeID:version:)` (recipe-specific snapshot, General by default), `mostRecentSummary(id)` (newest live snapshot across recipes by creation/insertion order for Meeting Detail), `latestSummary(id:recipeID:fingerprint:language:)` (D25 — with `language`, it is the exact recipe-scoped cache hit; without it, returns that recipe's translation pivot in any language), `search(text, requireAll:)` (FTS5 with snippets; `ftsQuery` quotes tokens — hostile input sanitized), `searchSemantic(vector, limit:)`, `segmentsNeedingEmbeddings`/`storeEmbeddings`, `openActionItems`/`setActionItem(done:)`, `replaceCast(for:speakers:segments:)` (legacy/general atomic cast replacement), `applyRefinedCast(for:expectedTranscriptRevision:language:speakers:segments:)` (validated, revision-fenced refined aggregate replacement — D47), `enforceAudioRetention(audioRoot:)` (deletes ONLY expired audio according to the meeting's policy, never the transcript; anti-path-escape guard).

External audio uses the dedicated
`saveImportedMeeting(_:speakers:segments:)` Unit of Work. It validates the
meeting's relative audio path, requires every speaker and segment to belong to
that meeting, and rejects segment references outside the supplied cast with
`StorageError.invalidImportedMeeting`. One GRDB transaction inserts the
meeting root, speakers, and segments; a duplicate or injected child failure
rolls back the complete aggregate, so the Library never observes a meeting
without its required transcript (D46). The optional summary remains a later
immutable `saveSummary` operation and cannot roll the aggregate back.

Accepted refine drafts use the dedicated
`applyRefinedCast(for:expectedTranscriptRevision:language:speakers:segments:)`
Unit of Work. Before writing, it requires a nonnegative source revision, a
nonempty transcript, unique children owned by the meeting, speaker references
inside the proposed cast, and no attempt to move an existing speaker/segment
from another meeting. Inside one GRDB transaction it reloads the live meeting,
rejects a stale revision with `StorageError.staleRefineDraft`, tombstones the
old live cast/transcript, inserts the accepted children, replaces language
including `nil`, increments `transcriptRevision`, and updates the aggregate
timestamp. Immutable summaries are untouched. Validation, a stale draft, or
an injected child failure leaves language, cast, transcript, revision, and
summary history unchanged. The app enters this Unit of Work through
ApplicationKit; CLI refine calls the same StorageKit API (D47).

All cross-library projections are live-rooted. `libraryFacts`, `findingInputs`,
`openActionItems`, `summary`/`latestSummary`, `voiceMixes`, and `voiceBalance`
join or validate a non-deleted meeting before exposing data. Deleting a meeting
therefore removes it from Insights and library totals without mutating its
children; restoring the root returns the exact previous projections.

## `.portavoz` bundle (M15 L0)

`MeetingBundle` preserves `formatVersion = 1` and evolves only with optional/additive fields. It exports the transcript, cast, latest summary, notes, Companion cards, and, if the user requests it, audio. Import remaps meeting, speaker, segment, action item, note, and card IDs so that two imports are independent. An older v1 bundle without `companionCards` or v6 meeting lifecycle fields still decodes; absent lifecycle data means `ready` at revision zero. Local paths never travel.

## Recordings folder — `RecordingsLocation`

- User-selectable root; persists as a plain absolute path in `recordings-root.txt` NEXT TO THE DB (file, not UserDefaults → the CLI honors the same folder). No security-scoped bookmark: the app has hardened runtime but is NOT sandboxed; TCC prompts once for protected folders (usage strings in Info.plist, including external drives).
- `currentRoot()` falls back to the default if the marker points to a missing folder (disconnected drive). `resolve(relative)` tries the current root → default (an interrupted migration remains fully readable).
- `migrateAudio(from:to:progress:)` is resumable: one meeting directory (immutable UUID) at a time; cross-volume copies to `.partial-<n>` and publishes with an atomic rename; existing destination = already migrated (skips and cleans the source). 7 tests.

## Audio layout — `MeetingAudioLayout`

`channelFile(named:in:)` locates audio by channel inside `Audio/<uuid>/`: prefers `.m4a` after user-requested compression, then `.caf` (current capture, crash-safe), then `.wav` (pre-Jul-2026 meetings). Staging `.partial.caf` files are intentionally invisible. All readers (refine CLI and app) pass through this layout.

## Secrets — `PortavozCore.SecretStore`

Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Services: GitHub token, Linear token, voiceprint key. Never in SQLite/UserDefaults.

## Known limits

1. No SQLCipher (optional and planned, PRODUCT/security).
2. The nullable `generationRunID` columns and envelope exist, but no generation
   producer writes provenance yet; behavioral adoption remains Band 3 work.
3. `visibility` reserved and unused (sharing D12).
4. FTS at 1,000 meetings / 80k segments is measured at p50 22.8 ms and
   p95 23.9 ms (`portavoz-cli bench-fts`, spec 08). Larger-library and
   semantic-search budgets are planned in the refactor program.
## Trash (Jul 2026)

Deletes were ALWAYS tombstones (D4); the trash provides a way back.
`deletedMeetings()` returns tombstoned meetings most recent first.
`restore(_:)` clears only the aggregate root's tombstone; child rows are not
tombstoned, so meeting-scoped detail/search data returns immediately.
`purge(_:)` hard-deletes every row and REFUSES live meetings; FTS cleans itself
through GRDB's `synchronize` triggers, while the caller deletes on-disk audio.
The app exposes a collapsed "Recently deleted" section, one-click restore,
"Delete permanently", and >30-day launch auto-purge. The delete → restore,
purge, and cross-library projection-conservation paths are covered by storage
and voice-mix tests plus E2E verification. Since Band 0 slice 0A, trash cannot
affect live summaries, findings, participants, actions, voice mixes, or talk
balance; restoring a meeting exposes its untouched children again. Since Band
2 slice 2B, app delete and restore mutations enter through ApplicationKit's
`DeleteMeeting`/`RestoreMeeting` and narrow `MeetingLifecycleStore` port;
MeetingStore remains the production adapter and its storage semantics are
unchanged. Slice 2C routes manual and expired purge through a separate
`MeetingPurgeStore` projection. ApplicationKit receives pure candidates rather
than StorageKit records, preserves the strict `deletedAt < cutoff` comparison,
and continues to later tombstones when one purge fails. Slice 2D adds the
narrow `SummaryRegenerationStore`: MeetingStore adapts note reads, D25
fingerprint lookups, and immutable snapshot saves without exposing GRDB records
to the use case. Read/save failures retain the released best-effort behavior,
but persistence success is explicit in the application result.
Slice 2E keeps cache/pivot reads recipe-scoped and adds
`mostRecentSummary`: the active Meeting Detail snapshot is ordered by
`createdAt DESC, rowid DESC` across recipes. The rowid tie-breaker makes
same-timestamp insertions deterministic; recipe-specific versions and every
older immutable row remain unchanged (D45).
Slice 2F adds `saveImportedMeeting` as the production implementation of
ApplicationKit's imported-aggregate store port. The app treats the copied
audio directory as staged until this transaction succeeds and removes it
best-effort after any earlier required failure. Database and filesystem are
not one distributed transaction; the explicit staged ownership and
compensating delete form the bounded local Saga without changing the schema or
turning import into a durable background job (D46).
Slice 2G adds `applyRefinedCast` as the production implementation of
ApplicationKit's refine store port. Draft generation performs no writes;
acceptance uses optimistic revision fencing and one aggregate transaction.
Companion cards are a separate optional post-commit replacement, and summaries
remain immutable history. A source rule prevents the macOS app from bypassing
the use case through direct refine mutations (D47).

Slice 2H makes `MeetingStore` conform to the narrow `StopRecordingStore` port.
The adapter exposes guarded empty-shell discard, canonical recovery marking,
and the existing captured snapshot plus initial-job Unit of Work; it does not
expose GRDB records or transaction mechanics to ApplicationKit. A failed first
admission rolls back before `StopRecording` attempts an explicit no-job
`needsAttention` snapshot. A real in-memory adapter test proves the successful
snapshot and exact diarization job become visible together, while the source
ratchet prevents `RecordingController` from returning to direct Stop writes
(D48).
