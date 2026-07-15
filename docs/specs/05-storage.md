# Spec 05 — Persistence (StorageKit)

Status: implemented and in production (the user's DB survived a real incident thanks to tombstones). Decisions: D4 (frozen contract), D19 (GRDB+FTS5), D36 (additive v6 durability foundation), D37 (provisional recording rollback), D38 (captured Unit of Work), D39 (durable job leases and idempotency).

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
`needsAttention` and otherwise terminal work yields `ready`. The app does not
enqueue or execute this queue yet, and launch reconciliation of meeting/staging
state remains slice 1D-b. Generation runs, outbox events, and per-meeting
preferences are also not consumed yet.

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
`installCapturedSnapshot(_:)` is the D38 Unit of Work for the first durable
post-capture projection; it accepts only an untouched `recording` shell with
the exact pending reservation set and at least one published healthy, silent,
or clipped channel.

Durable work APIs are `enqueueProcessingJobs(for:requests:at:)`,
`processingJobs(for:)`, `claimNextProcessingJob(kinds:owner:leaseDuration:at:)`,
`heartbeatProcessingJob`, `completeProcessingJob`, `failProcessingJob`, and
`recoverExpiredProcessingJobs`. Claims are capability-filtered and
owner-fenced; storage derives meeting lifecycle rather than asking callers to
save a second, potentially inconsistent aggregate state.

The existing aggregate API remains:
`save(meeting/speakers/segments/contextItems)`, `contextItems(for:)`, `deleteContextItem(_:)` (tombstone), `save(companionCards:for:)`, `companionCards(for:)`, `deleteCompanionCard(_:)`, and `replaceCompanionCards(_:for:)` (atomic replacement with tombstones), `meetings(includeDeleted:)`, `detail(id)` (live meeting+speakers+segments), `delete(id)` (tombstone), `saveSummary(draft)` (auto-incrementing version per meeting+recipe; never touches previous snapshots; persists the D25 fingerprint), `summary(id)` (latest live-meeting snapshot + version), `latestSummary(id:fingerprint:language:)` (D25 — with `language`, it is the exact cache hit; without it, returns the translation pivot in any language), `search(text, requireAll:)` (FTS5 with snippets; `ftsQuery` quotes tokens — hostile input sanitized), `searchSemantic(vector, limit:)`, `segmentsNeedingEmbeddings`/`storeEmbeddings`, `openActionItems`/`setActionItem(done:)`, `replaceCast(for:speakers:segments:)` (tombstones the live cast and inserts the new one, atomically — D7 refine), `enforceAudioRetention(audioRoot:)` (deletes ONLY expired audio according to the meeting's policy, never the transcript; anti-path-escape guard).

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
5. The durable job queue is not yet the app's post-capture execution path;
   launch recovery and concrete workers remain Band 1 slice 1D-b.

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
balance; restoring a meeting exposes its untouched children again.
