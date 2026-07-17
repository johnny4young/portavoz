# Spec 05 — Persistence (StorageKit)

Status: implemented and in production (the user's DB survived a real incident thanks to tombstones). Decisions: D4 (frozen contract), D19 (GRDB+FTS5), D36 (additive v6 durability foundation), D37 (provisional recording rollback), D38 (captured Unit of Work), D39 (durable job leases and idempotency), D40 (evidence-first launch recovery), D41 (atomic generated-artifact completion), D42 (process-scoped exact execution), D43 (atomic Stop handoff), D44 (application dependency ratchet), D45 (newest immutable detail snapshot), D46 (atomic imported aggregate), D47 (revision-fenced refined aggregate), D48/D49 (application-owned Stop/Start policy), D50 (application-owned launch reconciliation), D51 (complete bundle aggregate Unit of Work), D52 (read-consistent bundle export), D54 (scoped Library observations), D58/D59 (scoped Insights/Meeting Detail observations), D62–D67 (atomic summary, accepted Refine transcript, Companion-card provenance, and content-free destination scope), D70 (durable first-pass transcript recovery), D75 (immutable egress attempts and honest receipt coverage), D76 (atomic redacted support snapshot and bounded durable retry).

## Database

GRDB 7 (`upToNextMajor(from: 7.11.1)`), SQLite WAL, at `~/Library/Application Support/Portavoz/portavoz.sqlite` (`MeetingStore.defaultDatabaseURL`; CLI accepts `--db`).

### Schema (`v1`–`v7` migrations in `Sources/StorageKit/Schema.swift`)

Singular camelCase tables, 1:1 with Codable records:

| Table | Key columns |
|---|---|
| `meeting` | id (UUID TEXT PK), title, startedAt, endedAt, language, audioDirectory (RELATIVE), retention, visibility (reserved), **lifecycleState**, **transcriptRevision**, **lastProcessingError** (v6), createdAt/updatedAt/deletedAt |
| `speaker` | id, meetingID (FK CASCADE), label (S1/Me…), displayName, isMe, tombstone |
| `segment` | id, meetingID, speakerID?, channel, text, language?, startTime/endTime, confidence?, isFinal, **embedding BLOB** (v2), generationRunID? (v6), tombstone |
| `summary` | id, meetingID, recipeID, language, markdown, **version** (UNIQUE meetingID+recipeID+version — immutable snapshots), **fingerprint** (v4, D25 — language-independent material identity; NULL in old snapshots = never match), generationRunID? (v6) |
| `actionItem` | id, summaryID (FK CASCADE), meetingID, text, ownerSpeakerID?, isDone (the MUTABLE exception), tombstone |
| `contextItem` (v3) | id, meetingID (FK CASCADE), kind (note/link/codeSnippet/file), content, timestamp (seconds from start), tombstone — user notes (D28) |
| `companionCard` (v5) | id, meetingID (FK CASCADE), question, answer, kind, source, directed, askedAt, generationRunID? (v6), createdAt/updatedAt/deletedAt — reviewable Companion snapshot (D26) |
| `audioAsset` (v6) | id, meetingID, channel, role, unique relativePath, optional finalized media metadata/checksum/levels, healthStatus, sourceAssetID lineage, createdAt/updatedAt/supersededAt/deletedAt |
| `processingJob` (v6) | durable job state, priority/progress, retries, scheduling/lease/error timestamps; UNIQUE meetingID+kind+inputFingerprint |
| `generationRun` (v6) | provider/model/config/input/output/outcome/metrics envelope; nullable `generationRunID` FKs exist on segment, summary, and companionCard. Manual/post-refine, durable post-capture, and external-audio import successful summaries link atomically; accepted Refine links every replacement segment; generated live/post-Refine Companion cards link one current-workflow run and record only conservative external destination scope when transfer is attempted; failed/cancelled attempts persist separately (D62–D67) |
| `outboxEvent` (v6) | idempotent external-side-effect envelope with delivery state, attempts, and retry/delivery timestamps |
| `meetingPreference` (v6) | one row per meeting for independent transcript/summary language modes and optional recipe/summary/refine engines |
| `dataEgressEvent` (v7) | immutable content-free attempt: meeting, operation, conservative destination scope/host, classification, consent, provider/model, and attemptedAt; indexed by meeting/time |
| `privacyReceiptCoverage` (v7) | singleton `meeting-content-egress` row with the migration timestamp that bounds trustworthy receipt history |
| `segmentSearch` | FTS5 external-content over segment.text, synchronized by ai/ad/au triggers |

Schema v6 is an additive foundation (D36). Existing meetings migrate to
`ready`, revision zero, and no processing error. The migration does not inspect
the filesystem or synthesize `audioAsset` rows, so `Meeting.audioDirectory`
remains the authoritative product audio reference for legacy and new meetings.

Schema v7 is an additive privacy-evidence migration (D75). It creates no event
for historical activity and never reads meeting content. Instead, one persisted
coverage timestamp lets new meetings claim complete tracked history while
legacy meetings disclose that only later activity is covered. Event constraints
admit only the known operations/scopes/classifications/consents; the runtime
additionally requires an existing meeting, non-empty host/provider, and exact
host/provider equality, then recomputes conservative scope from the host. A
malformed, falsely local, or unowned event writes nothing.

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
entire transaction back. GRDB persists `Date` as UTC text with millisecond
precision; shell `startedAt` and asset `createdAt` therefore match by their
exact canonical database values. Raw submillisecond `Date` equality is never
used as a stronger, non-durable identity constraint.

D43 extends this boundary with `installCapturedSnapshot(_:enqueue:at:)`.
Normal Stop supplies the exact initial diarization request when live captions
are complete, or D70's exact initial transcription request when captions are
empty/degraded but finalized audio is usable. The same transaction installs
captured content, inserts that immutable-key job, and derives `processing`. A
job constraint/write failure therefore rolls the snapshot and job back
together; package tests inject that failure and verify the original recording
shell plus pending reservation remain untouched.

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
Generation runs are consumed by summary producers and accepted Refine; outbox
events and per-meeting preferences are not consumed yet.

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
  item, or Companion card. `ApplicationKit.StartRecording` invokes it only
  after checking every reserved staging and published channel path. Assets
  cascade with that no-data rollback. Any file or content preserves the meeting
  for recovery.
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
`MeetingStore` implements `StartRecordingStore` by adapting same-day sequence
counting, `beginRecording`, guarded discard, and canonical
`capture.start.failed` needs-attention marking. ApplicationKit sees no GRDB
record or transaction detail; a real adapter test proves shell and all selected
assets exist before the runtime source-start callback (D49).
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
`completeTranscriptionJob`, `completeDiarizationJob`, `completeSummaryJob`, `failProcessingJob`, and
`cancelProcessingJob`, `nextScheduledProcessingDate`, and
`recoverExpiredProcessingJobs`. `retryFailedProcessingJobs(for:at:)` is the
explicit user-recovery boundary: in one transaction it resets only exhausted
jobs to pending, clears lease/attempt/error timing, preserves job identity,
idempotency key, kind, input fingerprint, and source revision, and reconciles
the meeting to processing. Claims and scheduled wakes are capability-
filtered and owner-fenced; generated work must use its artifact completion API,
while the generic completion path remains available only to non-content jobs.
`completeTranscriptionJob` validates the exact meeting/fingerprint/source
revision, replaces the live cast/transcript with one canonical meeting-owned
artifact, advances `transcriptRevision`, completes the lease, enqueues exact
diarization, and reconciles lifecycle in one transaction. Transcription and
diarization share one internal transcript-artifact envelope so identity,
ownership, tombstoning, and revision rules cannot drift between stages.
`SummaryArtifact` requires the successful generation run whose operation
fingerprint matches the job. `completeSummaryJob` validates that run and inserts
it with the immutable summary/actions, job success, and lifecycle
reconciliation inside the same lease/revision-fenced transaction. Storage
derives meeting lifecycle rather than asking callers to save a second,
potentially inconsistent aggregate state (D63).

`meetingExportSnapshot(_:)` is the dedicated read-side aggregate for sharing.
One GRDB read loads the live meeting, cast, ordered transcript, newest summary
across every recipe, ordered notes, and ordered Companion cards. The required
meeting/cast/transcript projection remains strict; optional summary, note, and
card decoding retains the released degradable fallback. Audio bytes are not a
database concern and remain behind the application filesystem port (D52).

The existing aggregate API remains:
`save(meeting/speakers/segments/contextItems)`, `contextItems(for:)`, `deleteContextItem(_:)` (tombstone), `save(companionCards:for:)` (preserves an existing run link), `companionCards(for:)`, `deleteCompanionCard(_:)`, `saveCompanionGenerationRun(_:workflow:sourceTranscriptRevision:)` (current-revision failed/cancelled attempt), and `replaceCompanionCards(_:generated:for:)` (current-revision atomic card/run replacement with tombstones), `meetings(includeDeleted:)`, `detail(id)` (live meeting+speakers+segments), `delete(id)` (tombstone), `saveSummary(draft)` (auto-incrementing version per meeting+recipe; never touches previous snapshots; persists the D25 fingerprint), `summary(id:recipeID:version:)` (recipe-specific snapshot, General by default), `mostRecentSummary(id)` (newest live snapshot across recipes by creation/insertion order for Meeting Detail), `latestSummary(id:recipeID:fingerprint:language:)` (D25 — with `language`, it is the exact recipe-scoped cache hit; without it, returns that recipe's translation pivot in any language), `search(text, requireAll:)` (FTS5 with snippets — hostile input sanitized), `searchSemantic(vector, limit:)`, `segmentsNeedingEmbeddings`/`storeEmbeddings`, `openActionItems`/`setActionItem(done:)`, `replaceCast(for:speakers:segments:)` (legacy/general atomic cast replacement), `applyRefinedCast(for:expectedTranscriptRevision:language:speakers:segments:generationRun:)` (validated, revision-fenced refined aggregate replacement with optional accepted-transcript provenance — D47/D65), `enforceAudioRetention(audioRoot:)` (deletes ONLY expired audio according to the meeting's policy, never the transcript; anti-path-escape guard).

Privacy evidence adds `recordDataEgressEvent(_:)`,
`dataEgressEvents(for:)`, and `privacyReceipt(for:)`. The first is the
fail-closed `DataEgressEventRecorder` implementation used by production network
composition. Receipt reads include live generation runs but expose only their
purpose-built provider/model/time/outcome projection, never raw config,
fingerprints, metrics, or meeting content.

`supportDiagnosticsSnapshot()` reads every support-safe live meeting, privacy
coverage boundary, durable job, generation run, and egress event inside one
SQLite snapshot, then groups rows in memory to avoid one query per meeting. The
StorageKit projection contains structural state needed by ApplicationKit but
does not fetch title, transcript, summary/action/card text, or filesystem paths.
Before the projection crosses the Store, stable database identities and stored
fingerprints are one-way hashed, labels/codes/hosts are sanitized, and raw
prompt/config/metrics/error payloads are omitted. ApplicationKit applies the
same allowlist again while encoding the public report (D76).

External audio uses the dedicated
`saveImportedMeeting(_:speakers:segments:)` Unit of Work. It validates the
meeting's relative audio path, requires every speaker and segment to belong to
that meeting, and rejects segment references outside the supplied cast with
`StorageError.invalidImportedMeeting`. One GRDB transaction inserts the
meeting root, speakers, and segments; a duplicate or injected child failure
rolls back the complete aggregate, so the Library never observes a meeting
without its required transcript (D46). The optional summary remains a later
transaction. On success, `saveSummary(_:generationRun:)` atomically inserts its
terminal run, immutable snapshot, and action items. A provider or publish
failure stores one standalone failed/cancelled run best effort, while the prior
imported aggregate cannot roll back (D64).

Meeting-bundle import uses the superset
`saveImportedMeetingBundle(_:at:)` Unit of Work (D51). Before writing it
validates the relative audio directory; unique speaker/segment/note/card/action
identities; meeting ownership; cast references; and summary/action ownership.
One transaction rejects an existing meeting ID and inserts the meeting, cast,
transcript, optional summary as immutable version 1 with its action items,
notes, and Companion cards. A failure in the last card insert rolls back every
earlier row, while invalid foreign children are rejected before any write.

Accepted refine drafts use the dedicated
`applyRefinedCast(for:expectedTranscriptRevision:language:speakers:segments:generationRun:)`
Unit of Work. Before writing, it requires a nonnegative source revision, a
nonempty transcript, unique children owned by the meeting, speaker references
inside the proposed cast, and no attempt to move an existing speaker/segment
from another meeting. Inside one GRDB transaction it reloads the live meeting,
rejects a stale revision with `StorageError.staleRefineDraft`, tombstones the
old live cast/transcript, optionally inserts one validated successful
transcript run, inserts the accepted children with that run link, replaces
language including `nil`, increments `transcriptRevision`, and updates the aggregate
timestamp. Immutable summaries are untouched. Validation, a stale draft, or
an injected child failure leaves language, cast, transcript, revision,
generation history, and summary history unchanged. A linked run must match the
meeting, transcript kind, success outcome, output language, Refine workflow,
and exact source revision. The app enters this Unit of Work through
ApplicationKit; CLI refine calls the same StorageKit API (D47).

All cross-library projections are live-rooted. `libraryFacts`, `findingInputs`,
`openActionItems`, `summary`/`latestSummary`, `voiceMixes`, and `voiceBalance`
join or validate a non-deleted meeting before exposing data. Deleting a meeting
therefore removes it from Insights and library totals without mutating its
children; restoring the root returns the exact previous projections.

Library now has four independent GRDB `ValueObservation` streams (D54).
Meeting rows plus voice mix explicitly observe `meeting`, `speaker`, and
`segment`; open items observe `meeting`, `summary`, and `actionItem`; trash
observes `meeting`; active FTS observes the base `meeting` and `segment` tables
rather than FTS5 shadow tables. Each source uses newest-value buffering and
cancels its observation task when the consumer ends. The three persistent
sidebar sources fail independently, so corrupt meeting projection data does
not prevent open-item or trash reads from remaining available. Meeting rows
retain the released partial fallback: if the meeting list is valid but voice
mix cannot be decoded, rows publish with empty mixes and one inline failure.

The existing one-shot `meetings`, `voiceMixes`, `openActionItems`,
`deletedMeetings`, and `search` APIs share private query helpers with the
observed paths; ordering, live-root joins, tombstone scope, and limits therefore
have one implementation. StorageKit keeps GRDB-specific projection types at
its edge, while the app maps them to ApplicationKit Library read contracts.

Insights has four additional independent observations (D58). Meeting chronology
observes `meeting`; confirmed participant and commitment facts observe
`meeting`, `speaker`, `summary`, and `actionItem`; voice balance observes
`meeting`, `speaker`, and `segment`; finding evidence observes `meeting`,
`segment`, `summary`, and `actionItem`. Finding keys are selected from the 60
newest live meetings inside the active `DateInterval` before transcript,
newest-summary, and action-item evidence is assembled. A scope change creates a
new observation. Facts, voice balance, and finding inputs share their fetch
helpers with the existing one-shot APIs, so live-root scope, ordering, and
degradable optional-row behavior cannot drift. The app maps these projections
to ApplicationKit contracts; no GRDB projection reaches `InsightsView`.

Meeting Detail has five independent observations (D59/D75/D76). Its live root, cast,
and ordered transcript observe `meeting`, `speaker`, and `segment`; its newest
immutable summary across recipes plus current action items observe `meeting`,
`summary`, and `actionItem`; persisted Companion cards observe `meeting` and
`companionCard`; the privacy receipt observes `meeting`, `generationRun`,
`dataEgressEvent`, and `privacyReceiptCoverage`; durable processing observes
only `meeting` and `processingJob`. Every projection is filtered to one live meeting. The core and
Companion helpers are shared with `detail` and `companionCards(for:)`, while
the summary stream reuses `mostRecentSummarySnapshot`; one-shot and observed
selection, ordering, tombstone scope, and strict decoding therefore remain
identical. The app maps these StorageKit edge values into storage-independent
ApplicationKit review updates.

The database remains a `DatabaseQueue`. The original scoped-observation slices
added no migration; 3H adds only the schema-v7 receipt tables, while 3I adds no
schema and leaves all existing rows and query behavior unchanged.

## `.portavoz` bundle (M15 L0)

`MeetingBundle` preserves `formatVersion = 1` and evolves only with optional/additive fields. It exports the transcript, cast, latest summary, notes, Companion cards, and, if the user requests it, audio. Import remaps meeting, speaker, segment, action item, note, and card IDs so that two imports are independent. An older v1 bundle without `companionCards` or v6 meeting lifecycle fields still decodes; absent lifecycle data means `ready` at revision zero. Local paths never travel. The imported remapped aggregate crosses ApplicationKit only after attachment metadata is reduced to unique canonical system/microphone channels with m4a/caf/wav extensions; StorageKit then publishes all relational content together (D51). Export crosses the symmetric ApplicationKit boundary from one `meetingExportSnapshot`, clears the local directory before encoding, and preserves the newest summary across recipes with its notes/cards from the same database moment (D52).

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
2. Manual/post-refine regeneration, durable post-capture generation,
   external-audio import summaries, accepted Refine transcripts, and generated
   live/post-Refine Companion cards now write
   validated terminal `generationRun` records. Manual/import success commits run, immutable
   summary, and actions together; durable success additionally shares the job's
   lease/revision-fenced completion and lifecycle transaction. Import summary
   work starts only after its required aggregate transaction. Exact cache hits,
   unavailable import providers, and pre-attempt durable exits create no run;
   accepted Refine success additionally shares the source-revision-fenced cast
   and transcript transaction and links every replacement segment. Discarded,
   empty, stale, invalid, and rolled-back drafts leave no orphaned success;
   post-attempt failures and cancellations persist separately on a best-effort
   basis. The Store exposes typed run history and summary-link lookup, rejects
   orphaned success and malformed or mismatched links, and stores no meeting
   content in config/metrics. Companion config may additionally store only the
   `local-device`/`remote` destination scope produced by D67's egress policy;
   it stores no URL or request body. Inline diarization has no separate durable artifact
   link beyond the transcript it attributes; transient suggestions/briefs remain
   intentionally ephemeral (D62–D67).
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
ApplicationKit's refine store port. Successful draft generation performs no
durable write; after D65, a begun failed/cancelled attempt may persist one
standalone diagnostic run. Acceptance uses optimistic revision fencing and one
aggregate/provenance transaction.
Companion cards are a separate optional post-commit replacement, and summaries
remain immutable history. After D66, a complete refresh atomically replaces
cards plus successful runs only when the run's post-refine source revision is
still current. An incomplete refresh preserves the prior snapshot and may store
current failed/cancelled attempts best effort. Later generic card saves retain
the established link. A source rule prevents the macOS app from bypassing the
use case through direct refine mutations (D47/D65/D66).

Slice 2H makes `MeetingStore` conform to the narrow `StopRecordingStore` port.
The adapter exposes guarded empty-shell discard, canonical recovery marking,
and the existing captured snapshot plus initial-job Unit of Work; it does not
expose GRDB records or transaction mechanics to ApplicationKit. A failed first
admission rolls back before `StopRecording` attempts an explicit no-job
`needsAttention` snapshot. A real in-memory adapter test proves the successful
snapshot and exact diarization job become visible together, while the source
ratchet prevents `RecordingController` from returning to direct Stop writes
(D48).

Slice 2I makes `MeetingStore` conform to the narrow `StartRecordingStore` port.
The use case supplies one immutable meeting plus all selected pending assets to
the existing atomic reservation API before asking the capture runtime to start.
If that runtime fails, the store adapter can either perform D37's guarded empty
shell discard or mark the incomplete aggregate `needsAttention`; filesystem
evidence checks remain in a separate app-owned adapter. The architecture rule
requires `RecordingController` to enter through `StartRecording` and rejects a
return to direct reservation or concrete source/session construction (D49).

Slice 2J makes `MeetingStore` conform to
`RecoverInterruptedMeetingsStore`. Its adapter filters ready aggregates before
the pass, recovers expired leases at the workflow timestamp, projects only
meeting/transcript/job state required by reconciliation, and delegates every
write to the existing guarded discard, captured-snapshot, recovered-assets, or
canonical needs-attention transaction. ApplicationKit receives no GRDB record
or SQL detail. A real in-memory adapter test proves a ready aggregate remains
untouched while an empty interrupted recording shell is the only hard-deleted
candidate (D50).

Slice 2K makes `MeetingStore` conform to `ImportMeetingBundleStore` through
the complete imported-bundle Unit of Work. ApplicationKit supplies one
validated snapshot and one sampled timestamp; StorageKit validates every
aggregate relation before entering a single GRDB write. Summary/action rows,
notes, and Companion cards can no longer commit independently of their meeting,
cast, and transcript. Focused real-Store tests prove full conservation,
pre-write rejection of foreign children, and rollback when an injected trigger
rejects the final Companion card (D51).

Slice 2L makes `MeetingStore` conform to `ExportMeetingBundleStore` through
`meetingExportSnapshot(_:)`. One live-rooted GRDB read supplies the meeting,
cast, ordered transcript, newest summary across recipe histories, notes, and
Companion cards to ApplicationKit. Audio stays outside SQLite, and no database
record or SQL detail crosses the port. Focused real-Store tests prove complete
content conservation, newest-recipe selection, tombstone exclusion, and the
released optional-row degradation policy (D52).
