# Spec 05 — Persistence (StorageKit)

Status: implemented and in production (the user's DB survived a real incident thanks to tombstones). Decisions: D4 (frozen contract), D19 (GRDB+FTS5), D36 (additive v6 durability foundation), D37 (provisional recording rollback), D38 (captured Unit of Work), D39 (durable job leases and idempotency), D40 (evidence-first launch recovery), D41 (atomic generated-artifact completion), D42 (process-scoped exact execution), D43 (atomic Stop handoff), D44 (application dependency ratchet), D45 (newest immutable detail snapshot), D46 (atomic imported aggregate), D47 (revision-fenced refined aggregate), D48/D49 (application-owned Stop/Start policy), D50 (application-owned launch reconciliation), D51 (complete bundle aggregate Unit of Work), D52 (read-consistent bundle export), D54 (scoped Library observations), D58/D59 (scoped Insights/Meeting Detail observations), D62–D67 (atomic summary, accepted Refine transcript, Apuntador-card provenance, and content-free destination scope), D70 (durable first-pass transcript recovery), D75 (immutable egress attempts and honest receipt coverage), D76 (atomic redacted support snapshot and bounded durable retry), D79 (measured scale gates before storage complexity), D80 (prefix-evidenced interruption scan), D81 (safe rank top-k and integration-owned lexical candidates), D82 (isolated semantic resource evidence), D83 (exact streamed semantic adapter retained after budget pass), D86 (explicit canonical people and aliases), D87 (typed summary evidence), D88 (current claim feedback), D89 (position-typed decision evidence), D90 (identity-typed action-item evidence), D91 (role-separated Apuntador evidence), D92 (content-free generation-fenced meeting change journal), D93 (exact portable aggregate projection and replay), D99 (read-consistent whole-library Markdown backup), D103 (coherent terminal product workflows), D104 (ApplicationKit durable-workflow ownership), D115 (durable private-iCloud receipt disclosure), D122 (accepted Refine lexical integrity), D123 (content-free capture-shape diagnostics), D127 (audio-priority Stop and same-pass shell recovery), D179 (bounded idempotent existing-library sync checkpoints), D180 (capture-safe whole-library backup admission), D181 (staged whole-library backup checkpoints), D182 (crash-safe backup-stage ownership), D183 (process-local destination identity), D184 (durable publication evidence), D185 (strict staged-source adoption), D186 (durable source checkpoints), D187 (pending-publication reconciliation), D188 (durable typed failure outcomes), D189 (launch recovery stage preservation), D230 (typed immutable transcript-correction history), D231 (atomic focused correction batches), D232 (append-only structural correction commands), D233 (correction-aware derived-artifact invalidation and publication fences), D234 (correction replica convergence and conflict fencing), D237 (confirmed-only commitment continuity), D238 (source-bound commitment review feedback), D240 (typed commitment ownership), D241 (bounded commitment Radar read model), D242 (content-free Radar scale gate).

D190 adds explicit intentional suspension for owner-leased processing jobs.
D198 adds exact source identity and compare-and-swap publication for semantic
embedding batches.
D199 adds compatibility-fingerprinted semantic vectors and fail-closed rebuilds
when the model or vector pipeline changes.
D200 adds content-free, independently leased scheduling for semantic
maintenance without changing meeting lifecycle or replacing the vector cursor.
D235 adds correction transaction and replica-replay recovery gates without a
schema change.
D239 adopts the existing v21 review and confirmation transactions through a
narrow ApplicationKit repository; it adds no schema or presentation-owned SQL.
D243 adds an explicit append-only cross-meeting source link; it reuses schema
v20–v22 and adds no migration.
D244 adds only a storage-independent Core suggestion policy. It neither queries
nor writes StorageKit and adds no schema, index, migration, or product adapter.
D245 adds only a public fixture and adapter-neutral evaluator. It reads no
meeting database, persists no score, and does not change the D243 explicit
confirmation transaction.

## Database

GRDB 7 (`upToNextMajor(from: 7.11.1)`), SQLite WAL, at `~/Library/Application Support/Portavoz/portavoz.sqlite` (`MeetingStore.defaultDatabaseURL`; CLI accepts `--db`).

### Schema (`v1`–`v22` migrations registered in `Sources/StorageKit/Schema.swift`)

Singular camelCase tables, 1:1 with Codable records:

| Table | Key columns |
|---|---|
| `meeting` | id (UUID TEXT PK), title, startedAt, endedAt, language, audioDirectory (RELATIVE), retention, visibility (reserved), **lifecycleState**, **transcriptRevision**, **lastProcessingError** (v6), createdAt/updatedAt/deletedAt |
| `speaker` | id, meetingID (FK CASCADE), label (S1/Me…), displayName, isMe, personID? (v8, FK SET NULL), tombstone |
| `segment` | id, meetingID, speakerID?, channel, text, language?, startTime/endTime, confidence?, isFinal, **embedding BLOB** (v2), **embeddingFingerprint** (v17), generationRunID? (v6), tombstone |
| `summary` | id, meetingID, recipeID, language, markdown, **version** (UNIQUE meetingID+recipeID+version — immutable snapshots), **fingerprint** (v4, D25 — language-independent material identity; NULL in old snapshots = never match), generationRunID? (v6) |
| `actionItem` | id, summaryID (FK CASCADE), meetingID, text, ownerSpeakerID?, isDone (the MUTABLE exception), tombstone |
| `contextItem` (v3) | id, meetingID (FK CASCADE), kind (note/link/codeSnippet/file), content, timestamp (seconds from start), tombstone — user notes (D28) |
| `companionCard` (v5) | id, meetingID (FK CASCADE), question, answer, kind, source, directed, askedAt, generationRunID? (v6), createdAt/updatedAt/deletedAt — reviewable Apuntador snapshot (D26) |
| `audioAsset` (v6) | id, meetingID, channel, role, unique relativePath, optional finalized media metadata/checksum/levels, healthStatus, sourceAssetID lineage, createdAt/updatedAt/supersededAt/deletedAt |
| `processingJob` (v6) | durable job state, priority/progress, retries, scheduling/lease/error timestamps; UNIQUE meetingID+kind+inputFingerprint; equal-timestamp reads use SQLite insertion order rather than random UUID order |
| `generationRun` (v6) | provider/model/config/input/output/outcome/metrics envelope; nullable `generationRunID` FKs exist on segment, summary, and companionCard. Manual/post-refine, durable post-capture, and external-audio import successful summaries link atomically; accepted Refine links every replacement segment; generated live/post-Refine Apuntador cards link one current-workflow run and record only conservative external destination scope when transfer is attempted; failed/cancelled attempts persist separately (D62–D67) |
| `outboxEvent` (v6) | idempotent external-side-effect envelope with delivery state, attempts, and retry/delivery timestamps |
| `meetingPreference` (v6) | one row per meeting for independent transcript/summary language modes and optional recipe/summary/refine engines |
| `dataEgressEvent` (v7) | immutable content-free attempt: meeting, operation, conservative destination scope/host, classification, consent, provider/model, and attemptedAt; indexed by meeting/time |
| `privacyReceiptCoverage` (v7) | singleton `meeting-content-egress` row with the migration timestamp that bounds trustworthy receipt history |
| `person` (v8) | id, preferredName, createdAt/updatedAt/deletedAt — one user-confirmed human identity independent from meeting observations |
| `personAlias` (v8) | id, personID (FK CASCADE), normalizedAlias, source, confidence, createdAt/updatedAt/deletedAt; unique per person+alias but deliberately repeatable across people |
| `summaryClaim` (v9) | id, summaryID (FK CASCADE), kind (`overview` only), sourceTranscriptRevision, createdAt; unique summary+kind |
| `summaryClaimSegment` (v9) | id, claimID (FK CASCADE), segmentID? (FK SET NULL), ordinal, createdAt; unique claim+ordinal and claim+live-segment |
| `summaryClaimFeedback` (v10) | claimID (PK/FK CASCADE), kind (`correction` or `unsupported`), correctionText?, createdAt/updatedAt/deletedAt; one current mutable assessment per immutable claim |
| `summaryDecisionEvidence` (v11) | id, summaryID (FK CASCADE), sectionOrdinal, bulletOrdinal, sourceTranscriptRevision, createdAt; unique summary+section+bullet |
| `summaryDecisionEvidenceSegment` (v11) | id, decisionID (FK CASCADE), segmentID? (FK SET NULL), ordinal, createdAt; unique decision+ordinal and decision+live-segment |
| `summaryActionItemEvidence` (v12) | id, actionItemID (unique FK CASCADE), sourceTranscriptRevision, createdAt; one immutable evidence aggregate per durable task |
| `summaryActionItemEvidenceSegment` (v12) | id, evidenceID (FK CASCADE), segmentID? (FK SET NULL), ordinal, createdAt; unique evidence+ordinal and evidence+live-segment |
| `companionCardEvidence` (v13) | id, cardID (unique FK CASCADE), sourceTranscriptRevision, createdAt; one immutable evidence aggregate per Apuntador card |
| `companionCardEvidenceSegment` (v13) | id, evidenceID (FK CASCADE), role (`question` or `answer`), segmentID? (FK SET NULL), ordinal, createdAt; unique evidence+role+ordinal and evidence+role+live-segment |
| `meetingSyncState` (v14) | meetingID (TEXT PK, deliberately no FK), localGeneration, acknowledgedGeneration, changedAt, isDeleted; content-free coalesced mutation state with pending index and purge-surviving deletion evidence |
| `segmentSearch` | FTS5 external-content over segment.text, synchronized by ai/ad/au triggers |
| `enhancedNote` (v15) | id, meetingID (UNIQUE, FK cascade), markdown, language, inputFingerprint (all checked non-empty), generationRunID (FK `setNull`, device-local), createdAt/updatedAt/deletedAt; ONE regenerable enhanced-notes document per meeting (D135), replaced in place preserving createdAt, portable via v15-registered `enhancedNote_sync_ai/au/ad` triggers over [markdown, language, inputFingerprint, deletedAt] |
| `derivedMaintenanceSource` (v18) | kind (TEXT PK), sourceGeneration, updatedAt; content-free mutation identity for derived work, never a progress cursor |
| `derivedMaintenanceJob` (v18) | content-free kind/profile/source operation identity, bounded attempts and scheduling time, lease owner/expiry, stable error code and timestamps; independent from meeting lifecycle |
| `transcriptCorrection` (v19) | immutable event identity, meeting FK, accepted revision, typed kind, user author, source device, optional unique superseded event, timestamps, and optional tombstone; only one monotonic tombstone transition may update a row |
| `transcriptCorrectionTarget` (v19) | correction FK plus ordered accepted segment identity; unique per correction, deliberately no segment FK so source replacement cannot erase history |
| `transcriptCorrectionPayload` (v19) | one typed scalar payload for replace/speaker/merge operations; text, language, and speaker fields are decoded against the parent kind |
| `transcriptCorrectionPart` (v19) | stable split-row identity plus correction FK, ordinal, text, optional speaker/language, and finite ordered interval |
| `commitment` (v20) | confirmed continuity identity, optional exact canonical person FK, immutable title/createdAt, current `confirmed`/`done`/`dismissed` projection, optional due date, timestamps, and tombstone |
| `commitmentSource` (v20) | commitment FK plus typed generated-action-item, user-note, or manual source; durable meeting/action/note identities and optional transcript revision intentionally have no ownership FK |
| `commitmentEvidenceSegment` (v20) | source FK, ordered typed evidence role, and optional durable segment identity without a segment FK so later source retirement cannot rewrite history |
| `commitmentEvent` (v20) | immutable append-only confirm/reassign/reschedule/complete/reopen/dismiss event with optional exact person FK and historical source-meeting identity |
| `commitmentReviewDecision` (v21) | action-item PK/FK plus current `dismissed` or future-dated `deferred` treatment, timestamps, and tombstone; no candidate text, owner, deadline, or evidence payload |

Schema v16 adds the partial
`meeting_on_live_startedAt_id(startedAt DESC, id ASC)` index for deterministic
newest-first keyset scans. It contains no new data and is copied into a backup
stage with the database.

Schema v17 adds nullable `segment.embeddingFingerprint`. Existing vectors have
no trustworthy model/pipeline identity, so the migration clears only their
derived embedding BLOB and fingerprint to the established `NULL` replay cursor.
It does not rewrite transcript text, segment identity, meeting revisions, or
FTS rows. Background maintenance may therefore rebuild a compatible vector
space while exact search remains available.

Schema v18 adds `derivedMaintenanceSource` and `derivedMaintenanceJob` for
independent semantic-maintenance ownership. Five triggers advance the semantic
source generation for segment insertion, source-relevant segment update,
segment deletion, meeting transcript/tombstone update, and meeting deletion.
Embedding and fingerprint publication do not advance it. Existing live
libraries seed generation one; empty libraries seed zero. The migration does
not rewrite transcript, FTS, vector, profile, meeting lifecycle, or user data.

Schema v19 adds empty normalized transcript-correction tables and immutable
payload/update triggers. It rewrites no meeting, segment, speaker, accepted
revision, FTS row, vector, or generated artifact. Every schema v1-v18 database
migrates through the same additive step, and legacy/imported meetings remain
valid with no synthetic events. Parent deletion cascades the correction history;
target identities intentionally outlive source-row retirement because they have
no segment foreign key.

Schema v20 adds empty confirmed-continuity tables, indexes for status/due date,
person/status, source lookup, and event history, plus immutability triggers for
the commitment identity and all source/evidence/event rows. The migration does
not inspect action items, infer owners, create candidates, or synthesize
commitments. Confirmation inserts the current projection, one explicit source,
and the first `confirm` event atomically. Generated action items qualify only
when their immutable evidence is nonempty, current-revision, live, and
meeting-local; user notes and manual entries remain explicitly user-authored
origins. Ownership accepts the explicit local user, an exact live `PersonID`,
or an unassigned state. Later transitions append one validated event and update
the current projection in the same transaction; invalid lifecycle edges write
nothing.

The format-2 `CommitmentContinuityEnvelope` is a database-record-independent,
canonically ordered replay representation with explicit `me`, `person`, and
`unassigned` ownership. Its decoder accepts format 1 as exact-person or
unassigned legacy truth and never guesses a local-user assignment. Exact replay
is idempotent; identity reuse with different content fails closed. Imports
require referenced meetings, notes/action items/evidence, and people to exist
locally with exact identities before any row is inserted. This boundary does
not add the envelope to meeting
bundles, the CloudKit meeting replica, CLI, MCP, or a user-facing import/export
surface.

Schema v21 adds an empty `commitmentReviewDecision` table keyed to the existing
immutable generated `ActionItem`. It persists only reversible user treatment:
`dismissed`, or `deferred` with a revisit date strictly after the update time.
It does not inspect action-item text, synthesize candidates, copy evidence,
infer an owner, or extract a deadline. Reads reconcile active rows and any
confirmed commitment against action items from the newest live summary in one
bounded database snapshot; older regenerated sources retain no inherited
feedback.

Local confirmation and compatible continuity replay tombstone matching review
feedback in the same transaction that inserts confirmed continuity. A unique
partial index on generated-action source identity prevents one action item from
confirming multiple commitments. The migration deliberately does not
deduplicate legacy rows: no product confirmation surface existed before v21,
so an impossible duplicate fails migration rather than being guessed away.
Review feedback is not yet part of bundles, the meeting CloudKit aggregate,
CLI, MCP, or any user-facing import/export contract.

Schema v22 adds `assigneeKind` to the current commitment projection and its
assignment events. Legacy rows with an exact person become `person`; all other
legacy owners become `unassigned`. The migration performs only that controlled
backfill before restoring immutable-history enforcement. Insert/update triggers
then require `person` to carry exactly one canonical ID and require `me` and
`unassigned` to carry none. The migration does not infer self or extend any
sync/export surface.

`ManageMeetingCommitmentInbox` owns the commitment-inbox product commands. Its
`MeetingCommitmentReviewRepository` adapter delegates to the existing atomic
Store operations for confirm, link, dismiss, defer, and restore; SwiftUI never
receives a Store or record type. The current visual confirmation surface uses
confirm and review operations while link remains reserved for later adoption.
Confirmation therefore
reuses current-evidence, exact-person, unique-source, and feedback-tombstone
validation instead of duplicating those rules in presentation. The UI may
collect edited wording, explicit self/person/unassigned ownership, and a
user-entered due date, but StorageKit still accepts them only through the
confirmed aggregate boundary.

`linkCommitmentSource` is the D243 append-only cross-meeting boundary. It
accepts only an existing open commitment and a generated action item that is
still in the expected meeting's newest live summary, has current direct
same-meeting evidence, has not backed any confirmed commitment, and comes from
a meeting not already represented in the target. One transaction appends the
immutable source/evidence rows and tombstones source-bound review feedback. It
does not insert a lifecycle event or update the commitment projection, title,
owner, due date, or projection timestamps. A regressed proposed timestamp is
advanced by one millisecond beyond the latest source or lifecycle timestamp so
the append remains canonically ordered across return and reload. No migration
is required. The
application repository exposes this command for later presentation adoption,
but no UI invokes it yet. D244's pure Core scorer consumes bounded target
snapshots supplied by a future adapter; it does not open this Store or call the
link command.

`commitmentRadar(_:)` is the library-global continuity read boundary. One GRDB
snapshot performs at most four set-based SELECT statements regardless of root
count: a bounded root page, bounded oldest-first sources, bounded newest-first
events, and exact names for referenced people when any exist. It never calls a
Meeting Detail aggregate per row. Root pages are limited to 200; source and
history material are independently limited to 20 per commitment, with exact
total counts and explicit truncation flags. Each source and history row retains
its durable identity plus optional source-meeting title and availability for
navigation.

ApplicationKit supplies concrete calendar boundaries. Storage filters overdue
as an open due date before `dayStart`, due soon as an open due date in
`[dayStart, dueSoonEnd)`, and no date as an open commitment with no due date.
The latest immutable event distinguishes new, unchanged, completed, and
reopened activity. The read fails closed when current status disagrees with that
event instead of converting corruption into a label. Dismissed and tombstoned
roots are excluded. This query adds no schema migration, model call, inferred
owner/date, sync/export field, reminder, CLI, or MCP contract.

`make commitment-radar-benchmark` exercises that exact Store boundary in
Release mode without opening the user database. For each canonical corpus it
creates a fresh in-memory store, inserts 1,000 or 10,000 synthetic confirmed
commitments outside the timed interval, performs one warm read, and measures
five stable reads of a 100-root page. A synthetic exact person intentionally
keeps the optional name lookup active, so the benchmark proves the maximum
four-SELECT shape instead of a cheaper all-unassigned path. The gate fails if
output identity changes, statement count differs from four, or nearest-rank
p95 exceeds 100 ms. On 2 Aug 2026 the arm64 reference host measured 4.06/4.25
ms p50/p95 at 1,000 rows and 25.10/25.27 ms at 10,000. The schema-v1 report is
aggregate-only and carries no domain identity, text, or database path.

`appendTranscriptCorrection` canonicalizes timestamps to persisted
milliseconds, validates portable history plus current meeting/revision/targets,
meeting-local speakers, complete splits, adjacent same-speaker/channel merges,
and globally unused generated identities, then inserts the parent, ordered
targets, and typed payload in one transaction. Repeating the exact event is
idempotent; identity reuse, stale or overlapping edits, malformed payloads, and
branched supersession write nothing. `transcriptCorrectionHistory` always
returns tombstones, and `tombstoneTranscriptCorrection` is the only mutable
operation. Product undo appends a restore event. The strict transport-neutral
format-1 envelope exposes domain values rather than database records. Parent-
only insert/update/delete triggers advance the meeting sync journal once per
logical correction; child rows are transaction-internal and do not inflate its
generation. D231 adds an atomic multi-event append for independent text and
speaker lanes: every staged event is validated against one evolving history,
duplicate IDs or any invalid later event roll back the complete batch, and exact
retries remain idempotent after timestamp canonicalization. D232 reuses the same
immutable rows for split, merge, suppress, and restore. Suppression never
tombstones a source segment, and restore remains retained while releasing its
target from active correction ownership. Persistence independently rejects
foreign-meeting or nonaccepted targets and requires merge targets to remain
ordered, contiguous, same-speaker, same-channel, and time-monotonic.

D233 derives one effective correction revision from immutable history inside the
same database snapshot. Append, tombstone, and format-2 sync replay compare the
before/after revision; an idempotent retry or history rewrite with the same
effective overlay does nothing. A change cancels only pending/running `summary`
and `index` jobs with `processing.input.superseded`, preserves transcription and
diarization work, and advances `semantic-corpus` source generation once so a
restore can resume background indexing. Timestamps remain monotonic with the
meeting, affected jobs, and existing semantic-maintenance source even when an
older correction arrives through sync replay.

One shared SQL predicate excludes actively corrected accepted rows from FTS,
semantic reads, embedding candidates, vector publication, and identity
projection. Unaffected rows remain available. Restored rows become eligible
again; corrected text has no index row yet. Summary and Apuntador publication
now require exact current accepted-transcript and correction revisions from
the linked `GenerationRun`. Summary cache lookup applies the same requirement,
and malformed provenance fails closed. No further correction schema migration
is needed: the existing history and generation/maintenance tables already hold
the authority.

D235 proves the correction transaction's crash boundary with an injected
`BEFORE UPDATE` abort on the semantic-maintenance generation. An append that has
already inserted its typed event still rolls back the event and children,
meeting sync generation, accepted-only job changes, FTS eligibility, and
semantic source generation. The same quality boundary redelivers a blocked
remote correction before and after transport-state relaunch and requires one
unchanged deferred payload and one blocked outgoing attempt. Three compatible
device histories converge under different merge associations; no schema or
last-writer-wins rule is added.

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

Schema v8 is an additive human-memory migration (D86). It creates empty
`person`/`personAlias` tables, adds nullable indexed `speaker.personID`, and
rewrites no existing name, cast, transcript, biometric file, or meeting. The
foreign key uses `ON DELETE SET NULL`, while aliases cascade with their person.
Alias source/confidence constraints reject unknown evidence and non-finite or
out-of-range confidence. Exact alias lookup permits several live people with
the same normalized name; ambiguity is product truth, not a migration error.

Schema v9 is the additive typed-evidence migration (D87). Existing summaries
gain no synthetic claims. Saving a new claim and immutable summary is one
transaction: exactly one overview claim is allowed; its segment IDs must be
nonempty, unique, live, and owned by the same meeting; any supplied source
revision must equal the meeting; Storage stamps the current revision. Physical
segment deletion nulls the link so absence stays visible. Refine tombstones the
old transcript and advances the meeting revision, making older claims stale
without deleting immutable history. A current claim with any null, missing, or
tombstoned segment is wholly unavailable rather than partially navigable.

Schema v10 is the additive current-feedback migration (D88). Existing claims
gain no synthetic assessment. A live row is either unsupported with no text or
a correction containing 1–2,000 trimmed Unicode scalars.
`setSummaryClaimFeedback` accepts only the claim owned by the newest live
summary across every recipe; a newer snapshot makes an in-flight write fail
instead of changing hidden history. Replacement updates the same child row.
Clear first sets `correctionText` to NULL and then tombstones the row,
preserving nonsensitive future-sync evidence without retaining private
free-form text. Generated summary saves reject feedback; validated bundle
import is the explicit portable insertion boundary.

Schema v11 is the additive decision-evidence migration (D89). It deliberately
does not widen the schema-v9 one-overview table. The immutable summary
transaction parses Markdown through `SummaryMarkdownOutline`, rejects duplicate
decision IDs or rendered section/bullet positions, requires every coordinate
to address a real bullet, and reuses the same nonempty unique live
same-meeting-segment and source-revision validation as overview evidence. The
database stamps the current meeting revision. Link order is durable and a
physical segment deletion sets the link null, making the whole decision source
unavailable rather than partially navigable.

Schema v12 is the additive action-item-evidence migration (D90). Existing
tasks gain no synthetic provenance. A new evidence aggregate must target one
unique action-item ID in the same `SummaryDraft`; IDs and targets cannot
repeat. The summary transaction reuses the nonempty unique live
same-meeting-segment and revision validation from overview/decision evidence,
then stamps the current meeting revision. Toggling `actionItem.isDone`
updates only the task row, so its evidence identity and links remain stable.
Physical segment deletion sets a link null and makes the whole task source
unavailable rather than partially navigable.

Schema v13 is the additive Apuntador-card-evidence migration (D91). Existing
cards gain no synthetic evidence. One optional aggregate must target its card,
contain nonempty unique question links, contain unique answer links, and
reference only live segments from the same meeting. Storage stamps the current
transcript revision in the same transaction as the card. Question and answer
ordinals are independent; one segment may legitimately appear in both roles.
Physical segment deletion sets only the affected link null and increments that
role's unavailable count on read. Replacing a card with evidence `nil` deletes
the prior evidence child instead of retaining obsolete provenance.

Schema v14 is the additive transport-independent sync-admission migration
(D92). It creates an empty `meetingSyncState` table and 48 transactional
triggers; it never backfills an upgraded offline library. `meeting`, `speaker`,
`segment`, `summary`, `actionItem`, `contextItem`, `companionCard`, current
claim feedback, and all typed evidence parents/links coalesce into the owning
meeting row. `UPDATE` triggers compare portable `OLD` and `NEW` values with
SQLite's null-safe `IS NOT`, because GRDB whole-row saves may include unchanged
columns. Audio paths, embeddings, generation-run links, canonical-person
links, jobs, receipts, model/provenance state, audio, secrets, and voiceprints
are excluded.

`markMeetingsForInitialSync(after:limit:)` is the only initial-seed boundary.
It reads UUID-ordered meeting identities after an opaque cursor, marks one
bounded batch transactionally, and returns the final identity plus completion
state. Replaying a committed batch before the transport cursor is published is
idempotent: an already-pending generation is not incremented again, while a
fully acknowledged aggregate receives a new generation. This closes the
cross-store crash window without adding a schema table or mixing CloudKit state
into StorageKit.
`pendingMeetingSyncChanges(limit:)` returns bounded content-free state, and
`acknowledgeMeetingSync(_:)` advances only the generation actually sent. If a
local edit creates N+1 while N is in flight, acknowledging N leaves the row
pending. Invalid limits, future generations, and unknown identities fail
closed. The table has no meeting foreign key, so `purge` can delete every
meeting-owned row while its final deletion state survives. All trigger writes
share the aggregate transaction and therefore roll back with it. This version
contains no CloudKit/CKSyncEngine state, transport, account behavior, conflict
resolver, audio sync, SyncKit product, iOS target, or UI.

Band 6B1 adds no schema migration. `meetingSyncEnvelope(for:sourceDeviceID:)`
reads one journal row and its complete live portable aggregate in the same
snapshot, requiring the requested generation to remain the newest pending
generation. The versioned envelope contains source device, generation, change
time, and either deletion or text-first aggregate mutation. Meeting aggregate
format 2 contains the root, observed speakers, ordered transcript, every live
immutable summary version with action items/typed evidence/current claim
feedback, notes, Apuntador cards/evidence, and complete canonically ordered
transcript-correction history. It clears the local audio directory and canonical
person link and has no audio asset, embedding, generation run, job, receipt,
model, secret, or voiceprint type. Format-1 decoding remains supported and
cannot carry corrections.

`applyRemoteMeetingSyncEnvelope(_:)` validates format, identity, ownership,
uniqueness, evidence completeness, immutable-summary identity, portable
correction history, immutable correction material, and monotonic tombstones
before one write transaction. With no unsent local generation, it replaces
portable rows and v2 correction history, preserves matching local paths/person
links/embeddings/provenance, preserves local corrections for a legacy v1
aggregate, and advances trigger-created generations to acknowledged before
commit. A live remote aggregate normally returns `localChangePending` when
local work is unsent. D234 narrows that rule for format-2 correction history:
when the complete accepted segment base matches, disjoint correction lanes
union transactionally and advance the local journal to a new converged
generation; competing lanes or an incompatible accepted base return a typed
correction conflict without changing rows. Matching event IDs require immutable
equality, and a tombstone wins only through the existing monotonic transition.
Remote deletion is deliberately privacy-dominant, soft-deletes instead of
purging, settles the journal, and reports the discarded generation. Invalid
relations and immutable collisions roll back. Only deterministic replica-merge
and correction-history validation failures are classified as correction
conflicts; unrelated database or storage failures propagate as typed failures
and roll back. CloudKit/account/retry behavior remains absent from StorageKit
(D93/D234).

Band 6B2 does not change schema v14 or move transport authority into StorageKit.
IntegrationsKit separately protects account-scoped consent/seed policy, opaque
CKSyncEngine/system fields, exact attempts, retries, replay cursors, and fetched
deferrals. Its coordinator calls only the bounded projection,
acknowledgement, and remote-replay APIs above. A thin CloudKit delegate cannot
write GRDB or define conflict semantics directly. This separation keeps the
portable journal usable by another transport and ensures account switches do
not rewrite meeting content (D94/D95).

Band 6C1 adds one read-only, content-free observation above the same schema:
`meetingSyncJournalStatus()` and `observeMeetingSyncJournalStatus()` publish
only the pending row count and newest change timestamp. They never project a
meeting title, transcript, speaker, summary, or identifier. The IntegrationsKit
lifecycle combines this signal with its separately protected transport state;
StorageKit still has no CloudKit import or account policy. Pausing or removing
this device through that lifecycle never changes meeting rows. Remove-this-
device clears only IntegrationsKit transport metadata and protected payload
files (D96).

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
state), and inserts the provisional live cast/transcript, notes, and Apuntador
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

D127 preserves that atomic boundary while making rejection recovery ordered
and finite. ApplicationKit submits the exact full snapshot one additional time
for a transient Store failure. A repeated rejection may submit a core snapshot
that retains transcript, cast, notes, and only Companion cards with valid
provenance; then an audio/notes snapshot with exact complete-transcription work;
then canonical `capture.publication.failed` or
`capture.snapshot.persistence.failed` needs-attention projections. StorageKit
does not special-case or partially accept any rung: every request still passes
the same reservation, child, provenance, job, and lifecycle invariants in one
transaction. Generated cards cannot enter without their successful run.

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

Intentional suspension is a separate owner-fenced transition (D190). It returns
the running job to pending, resets non-resumable progress, clears lease and
error fields, and refunds the claim attempt. Repeated policy cancellation
therefore cannot consume `maxAttempts`; only an expired running lease records
`processing.lease.expired` or `processing.lease.exhausted` during launch
recovery. A stale owner or repeated suspension is rejected as lease loss.
ApplicationKit stops that drain invocation after the transition, preventing an
immediate reclaim while the cancellation policy is still active.

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
For a stale content-bearing `recording` shell, ApplicationKit first performs the
repeat-safe transition to `needsAttention` with
`capture.publication.failed`, then invokes this same asset transaction in the
same launch pass. It never replaces existing transcript children. The Store
derives `ready` only when the existing content and complete validated assets
already satisfy the publication-only invariant; otherwise the shell remains
explicitly recoverable (D127).
`markMeetingNeedsAttention` is repeat-safe and accepts only incomplete live
states. The app invokes expired-lease recovery and these boundaries at process
launch, then runs the concrete D42 diarization/summary executor. Normal Stop
now reaches it through D43's atomic snapshot/initial-job handoff. The isolated
characterization fixture uses the same exact request factory and normal queue
admission without real capture evidence.
Generation runs are consumed by summary producers and accepted Refine; outbox
events and per-meeting preferences are not consumed yet. D85 explicitly keeps
Spotlight off the outbox at the measured scale.

The migration is verified both by a deterministic v5 fixture and by migrating
a scratch copy of the real release database: legacy logical rows and meeting
fields were preserved, the new workflow tables remained empty, integrity was
`ok`, and foreign-key violations remained zero. The live database was never
opened by v6 code.

The current release-upgrade gate independently treats migrations `v1`–`v5` as
the exact schema shipped in Portavoz v0.6.0. It creates a disposable file-backed
v5 library containing a bilingual transcript, cast, summary and action item,
note, Apuntador card, and relative audio reference; opening that file through
`MeetingStore` must apply `v6`–`v15` without changing any user content. The gate
requires `PRAGMA integrity_check = ok`, zero foreign-key violations, no implicit
sync seed, and the same result after a second open. A separate empty-library
case proves that a clean install creates the latest schema and also reopens
idempotently. Neither case reads or copies the user's real library.

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
  item, or Apuntador card. `ApplicationKit.StartRecording` invokes it only
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

`MeetingStore` conforms to ApplicationKit's post-capture storage port without
moving transaction policy out of StorageKit. The application workflow selects
supported kinds, lease/heartbeat timing, fingerprints, dependencies, retries,
cancellations, and wake timing; the adapter delegates claims and atomic
artifact publication to the APIs above. StorageKit therefore remains the sole
owner of durable rows, owner/revision fences, lifecycle reconciliation, and
aggregate integrity while exposing no GRDB record to the workflow (D104).

Canonical people use three narrow D86 APIs. `people(matchingAlias:)` applies
Core's POSIX-stable whitespace/case/diacritic/width normalization and returns
every exact live candidate in deterministic order without writing. The
separate `createPersonAndLink` and `linkSpeaker` transactions accept only one
live, non-user observed speaker. They atomically insert/reactivate the alias,
set `speaker.personID`, and canonicalize that speaker's display name; failure
leaves no person, alias, or partial link. Creating a distinct person remains
valid when another person owns the same normalized alias. Linking an already
linked speaker to a different person, a deleted/missing person, `isMe`, or an
empty name throws `StorageError.invalidPersonLink`.

`meetingExportSnapshot(_:)` is the dedicated read-side aggregate for sharing.
One GRDB read loads the live meeting, cast, ordered transcript, newest summary
across every recipe, ordered notes, and ordered Apuntador cards. The required
meeting/cast/transcript projection remains strict; optional summary, note, and
card decoding retains the released degradable fallback. Audio bytes are not a
database concern and remain behind the application filesystem port (D52).
The format adapter removes every `speaker.personID` before encoding and again
when remapping imported speakers, so canonical device identity never travels
in a `.portavoz` bundle; accepted meeting-local display names still round-trip.

`prepareLibraryMarkdownBackupStage(mayContinue:)` is the dedicated
whole-library open-format source (D99/D181–D189). StorageKit copies the live database
into a private transient SQLite workspace through GRDB backup steps of 256
pages. The synchronous checkpoint runs between page groups; if capture closes
the gate, the partial stage is removed before returning a typed suspension.
The stage root and workspace are owner-only, the database is `0600`, and the
root is excluded from backup. A current-format workspace is named by its
stage UUID and retains an exclusive
kernel lease until close or deallocation. Creation and cleanup serialize
through a root lock; launch cleanup removes only directories whose regular,
non-symlink owner file can be locked nonblockingly and returns the exact
removed UUIDs. The app can therefore prune only matching recovery journals. A
live owner, non-UUID entry, and unknown legacy shape are preserved fail-closed.

The stage exposes a content-free keyset checkpoint containing only the exact
`startedAt` and raw record identity used by its newest-first ordering.
`adoptLibraryMarkdownBackupStage(id:cursor:)` can reopen one canonical UUID
workspace only after acquiring its abandoned owner lease under the same root
lock. It opens `source.sqlite` read-only and requires a supplied cursor to
match one exact live staged row. A live owner returns unavailable; a symlink,
unexpected file shape, invalid cursor, or unreadable database fails closed
without deleting the workspace. ApplicationKit persists this cursor only after a publication or typed
failure outcome is durable. Launch recovery catalogs operation UUIDs before
cleanup, passes them into the root-coordinated preservation set, and consumes
the exact cursor only after destination reconciliation. An adopted stage does
not remove its workspace on deinitialization; explicit `abandon()` closes the
read-only database and releases the owner lease while preserving the source for
a later attempt, whereas terminal `close()` removes it only after journal
removal.

After the copy completes, `MeetingMarkdownBackupStage.next()` selects one live
meeting root at a time in `startedAt DESC, id ASC` order and loads its strict
cast/transcript aggregate from the immutable stage. Later writes to the live
database cannot change this backup. Schema v16's matching partial index keeps
the keyset cursor logarithmic instead of rescanning previously exported roots.
A corrupt required aggregate becomes a
content-free `MeetingMarkdownBackupReadFailure` and does not block healthy
meetings. The latest live General-recipe summary preserves the released
Settings export contract; optional summary decode failure degrades to no
summary. Closing the stage removes its workspace. StorageKit returns values
only—it does not render Markdown, inspect a destination folder, or publish
files. Destination bookmark preparation and bounded resolution remain an
ApplicationKit port with a PlatformKit macOS adapter; bookmark identity never
enters the database stage or StorageKit.

The existing aggregate API remains:
`save(meeting/speakers/segments/contextItems)`, `contextItems(for:)`, `deleteContextItem(_:)` (tombstone), `save(companionCards:for:)` (preserves an existing run link and transactionally replaces optional typed evidence), `companionCards(for:)`, `deleteCompanionCard(_:)`, `saveCompanionGenerationRun(_:workflow:sourceTranscriptRevision:)` (current-revision failed/cancelled attempt), and `replaceCompanionCards(_:generated:for:)` (current-revision atomic card/run/evidence replacement with tombstones), `meetings(includeDeleted:)`, `detail(id)` (live meeting+speakers+segments), `delete(id)` (tombstone), `saveSummary(draft)` (auto-incrementing version per meeting+recipe; never touches previous snapshots; persists the D25 fingerprint and rejects user feedback), `setSummaryClaimFeedback(_:for:meetingID:)` (newest-claim-fenced replace/clear), `summary(id:recipeID:version:)` (recipe-specific snapshot, General by default), `mostRecentSummary(id)` (newest live snapshot across recipes by creation/insertion order for Meeting Detail), `latestSummary(id:recipeID:fingerprint:language:)` (D25 — with `language`, it is the exact recipe-scoped cache hit; without it, returns that recipe's translation pivot in any language), `search(text, requireAll:)` (FTS5 with snippets — hostile input sanitized), `searchSemantic(_:profile:limit:)`, `hasSemanticCorpusRows()`, `semanticIndexRequiresMaintenance(for:)`, `invalidateSemanticEmbeddings(incompatibleWith:)`, `segmentsNeedingEmbeddings`/`storeEmbeddings(_:for:profile:)`, `openActionItems`/`setActionItem(done:)`, `replaceCast(for:speakers:segments:)` (legacy/general atomic cast replacement), `applyRefinedCast(for:expectedTranscriptRevision:language:speakers:segments:generationRun:)` (validated, revision-fenced refined aggregate replacement with optional accepted-transcript provenance — D47/D65), `enforceAudioRetention(audioRoot:)` (deletes ONLY expired audio according to the meeting's policy, never the transcript; anti-path-escape guard).

`detail(id)` orders summary metadata by creation time, then version, recipe,
and identity. The explicit tie-break keeps the newest immutable version first
when SQLite's millisecond date precision gives two snapshots the same
`createdAt`, including after portable replay.

`spotlightDocuments()` is the D85 read-side projection for local OS search. A
single `DatabaseQueue.read` uses ranked CTEs to select every live meeting, its
newest live summary across all recipes, and its first 40 live segments ordered
by start time and rowid. Documents are ordered by meeting start and identity,
and their summary-plus-transcript description retains the released 4,000-
character cap. Tombstoned meetings, summaries, and segments are excluded.
StorageKit returns platform-neutral `SpotlightDocument` values; Core Spotlight
batching, protection, retry, and cleanup remain private app adapter concerns.

Privacy evidence adds `recordDataEgressEvent(_:)`,
`dataEgressEvents(for:)`, and `privacyReceipt(for:)`. The first is the
fail-closed `DataEgressEventRecorder` implementation used by production network
composition. Receipt reads include live generation runs but expose only their
purpose-built provider/model/time/outcome projection, never raw config,
fingerprints, metrics, or meeting content. The same read transaction also
projects `meetingSyncState.acknowledgedGeneration`: only a positive
acknowledgement records an encrypted private-iCloud copy. The disclosure never
reverts after later local edits or sync pause, while a pending or absent journal
row makes no cloud claim (D115).

`supportDiagnosticsSnapshot()` reads every support-safe live meeting, privacy
coverage boundary, durable job, generation run, egress event, content-free
sync acknowledgement, current audio-channel metadata, and aggregate transcript
counts inside one SQLite snapshot, then groups rows in memory to avoid one
query per meeting. Audio SQL selects only channel/role/codec, health, positive
finite sample rate, nonnegative duration/size, and finite signal values;
transcript SQL selects only per-channel and
attribution counts. The projection does not fetch audio paths or checksums,
title, language, speaker identity, transcript, summary/action/card text, or
filesystem paths.
Before the projection crosses the Store, stable database identities and stored
fingerprints are one-way hashed, labels/codes/hosts are sanitized, and raw
prompt/config/metrics/error payloads are omitted. ApplicationKit applies the
same allowlist again while encoding support format 2 and scopes an otherwise
all-local status to `all-tracked-processing-stayed-on-device` whenever the
separate sync disclosure records an acknowledged copy (D76/D115/D123).

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
identities; meeting ownership; cast references; summary/action ownership; and
current, card-targeted Apuntador evidence over imported segments.
One transaction rejects an existing meeting ID and inserts the meeting, cast,
transcript, optional summary as immutable version 1 with its action items,
notes, Apuntador cards, and their evidence. A failure in the final evidence
link insert rolls back every earlier row, while invalid foreign children are
rejected before any write.

Accepted refine drafts use the dedicated
`applyRefinedCast(for:expectedTranscriptRevision:language:speakers:segments:generationRun:)`
Unit of Work. Before writing, it requires a nonnegative source revision, a
nonempty transcript whose every row contains a letter or digit, unique children
owned by the meeting, speaker references inside the proposed cast, and no
attempt to move an existing speaker/segment
from another meeting. Inside one GRDB transaction it reloads the live meeting,
rejects a stale revision with `StorageError.staleRefineDraft`, tombstones the
old live cast/transcript, optionally inserts one validated successful
transcript run, inserts the accepted children with that run link, replaces
language including `nil`, increments `transcriptRevision`, and updates the aggregate
timestamp. Immutable summaries are untouched. Validation, a stale draft, or
an injected child failure leaves language, cast, transcript, revision,
generation history, and summary history unchanged. A linked run must match the
meeting, transcript kind, success outcome, output language, Refine workflow,
and exact source revision. App and CLI enter this Unit of Work through the same
ApplicationKit draft/apply boundary; terminal code does not call the Store
directly (D47/D103).

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
immutable summary across recipes plus current action items and typed overview/
decision evidence observe `meeting`, `summary`, `actionItem`, `summaryClaim`,
`summaryClaimSegment`, `summaryClaimFeedback`, `summaryDecisionEvidence`,
`summaryDecisionEvidenceSegment`, `summaryActionItemEvidence`, and
`summaryActionItemEvidenceSegment`; persisted Apuntador cards observe `meeting`,
`companionCard`, `companionCardEvidence`, and
`companionCardEvidenceSegment`; the privacy receipt observes `meeting`, `generationRun`,
`dataEgressEvent`, and `privacyReceiptCoverage`; durable processing observes
only `meeting` and `processingJob`. Every projection is filtered to one live meeting. The core and
Apuntador helpers are shared with `detail` and `companionCards(for:)`, while
the summary stream reuses `mostRecentSummarySnapshot`; one-shot and observed
selection, ordering, tombstone scope, and strict decoding therefore remain
identical. The app maps these StorageKit edge values into storage-independent
ApplicationKit review updates.

The database remains a `DatabaseQueue`. The original scoped-observation slices
added no migration; 3H adds only the schema-v7 receipt tables, while 3I adds no
schema and leaves all existing rows and query behavior unchanged.

Launch and presentation receipts use bounded aggregate projections (D101).
`liveMeetingCount()` counts only non-tombstoned roots without materializing the
library. `meetingBriefSummaryMarkdowns(for:)` deduplicates a bounded ID set and
returns the newest live General-recipe Markdown per meeting in one database
read; tombstoned roots, deleted summaries, other recipes, and superseded
versions are excluded. The app maps both projections to content-independent
ApplicationKit contracts, and brief commitments continue to use the existing
latest-summary-only `openActionItems(limit:)` query.

## `.portavoz` bundle (M15 L0)

`MeetingBundle` preserves `formatVersion = 1` and evolves only with optional/additive fields. It exports the transcript, cast, latest summary, typed overview/decision/action-item evidence and current overview feedback, notes, Apuntador cards with optional role-separated evidence, and, if the user requests it, audio. Import remaps meeting, speaker, segment, claim, decision, action-item, action-evidence, note, card, and card-evidence IDs so that two imports are independent; evidence follows fresh segments and its typed task/card identity, feedback follows its fresh overview claim, foreign source revisions are cleared, and Storage stamps the imported meeting revision. Malformed Apuntador evidence is dropped without legitimizing a foreign card target or losing the card. An older v1 bundle without claims, decisions, action evidence, feedback, Apuntador evidence, `companionCards`, or v6 meeting lifecycle fields still decodes; absent lifecycle data means `ready` at revision zero. Local paths and canonical person IDs never travel. The imported remapped aggregate crosses ApplicationKit only after attachment metadata is reduced to unique canonical system/microphone channels with m4a/caf/wav extensions; StorageKit then publishes all relational content together (D51/D87/D88/D89/D90/D91). Export crosses the symmetric ApplicationKit boundary from one `meetingExportSnapshot`, clears the local directory before encoding, and preserves the newest summary across recipes with its evidence/feedback/notes/cards from the same database moment (D52).

## Recordings folder — `RecordingsLocation`

- User-selectable root; persists as a plain absolute path in `recordings-root.txt` NEXT TO THE DB (file, not UserDefaults → the CLI honors the same folder). No security-scoped bookmark: the app has hardened runtime but is NOT sandboxed; TCC prompts once for protected folders (usage strings in Info.plist, including external drives).
- `currentRoot()` falls back to the default if the marker points to a missing folder (disconnected drive). `resolve(relative)` tries the current root → default (an interrupted migration remains fully readable).
- `migrateAudio(from:to:progress:)` is resumable: one meeting directory (immutable UUID) at a time; cross-volume copies to `.partial-<n>` and publishes with an atomic rename; existing destination = already migrated (skips and cleans the source). A destination that resolves to the current root, including a symlink alias, is a no-op so it can never trigger the resume cleanup against its own source. 9 tests.

The macOS Settings surface enters `ApplicationKit.ManageRecordingStorage` to
inspect or change the root. SwiftUI retains the native folder panel and
localized progress only. The private app adapter drains migration progress in
order, waits for migration completion, and updates `recordings-root.txt` only
after success. A failure leaves the marker unchanged; already moved directories
remain at the destination, and retry resumes the remaining source directories
before publishing the marker.

## Audio layout — `MeetingAudioLayout`

`channelFile(named:in:)` locates audio by channel inside `Audio/<uuid>/`: prefers `.m4a` after user-requested compression, then `.caf` (current capture, crash-safe), then `.wav` (pre-Jul-2026 meetings). Staging `.partial.caf` files are intentionally invisible. All readers (refine CLI and app) pass through this layout.

## Secrets — Core port and PlatformKit adapter

`PortavozCore` defines stable `SecretIdentifier` values and the Sendable
`SecretStoring` port. `PlatformKit.KeychainSecretStore` implements it with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; app and CLI composition create
the adapter and inject it into application credential workflows and encrypted
voice stores. GitHub, Linear, BYOK, voiceprint, and voice-gallery secrets never
enter SQLite, UserDefaults, sync payloads, bundles, or diagnostics.

## Known limits

1. No SQLCipher (optional and planned, PRODUCT/security).
2. Manual/post-refine regeneration, durable post-capture generation,
   external-audio import summaries, accepted Refine transcripts, and generated
   live/post-Refine Apuntador cards now write
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
   content in config/metrics. Apuntador config may additionally store only the
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
Apuntador cards are a separate optional post-commit replacement, and summaries
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
notes, and Apuntador cards can no longer commit independently of their meeting,
cast, and transcript. Focused real-Store tests prove full conservation,
pre-write rejection of foreign children, and rollback when an injected trigger
rejects the final Apuntador card (D51).

Slice 2L makes `MeetingStore` conform to `ExportMeetingBundleStore` through
`meetingExportSnapshot(_:)`. One live-rooted GRDB read supplies the meeting,
cast, ordered transcript, newest summary across recipe histories, notes, and
Apuntador cards to ApplicationKit. Audio stays outside SQLite, and no database
record or SQL detail crosses the port. Focused real-Store tests prove complete
content conservation, newest-recipe selection, tombstone exclusion, and the
released optional-row degradation policy (D52).

## Measured scale baseline (Band 4A, Jul 2026)

`portavoz-cli bench-scale` creates only throwaway databases and exercises the
production schema, FTS triggers, aggregate saves, scoped detail core read, and
current pure chapter/health policies in a Release build. The tracked host
result is `docs/evidence/scale-baseline-20260716.json` (20 storage/query samples
and three expensive algorithm samples per point):

| Corpus | Exact FTS p95 | Broad OR p95 | Allocated DB |
|---:|---:|---:|---:|
| 1,000 segments / 5 meetings | 0.59 ms | 1.12 ms | 0.77 MB |
| 10,000 / 50 | 3.08 ms | 8.60 ms | 5.40 MB |
| 50,000 / 250 | 15.77 ms | 57.64 ms | 26.40 MB |
| 100,000 / 500 | 44.35 ms | 121.64 ms | 52.40 MB |

| One meeting | Scoped core read p95 | Chapters p95 | Meeting health p95 |
|---:|---:|---:|---:|
| 30 min / 1,250 segments | 4.32 ms | 0.24 ms | 24.25 ms |
| 2 h / 5,000 | 17.22 ms | 0.85 ms | 347.58 ms |
| 8 h / 20,000 | 67.70 ms | 3.84 ms | 5,385.76 ms |

D79 therefore retains the single `DatabaseQueue`: the scoped read has no
measured contention or latency case for `DatabasePool`. It also retains direct
chapter extraction and the existing segment embedding BLOB layout. Exact FTS
still meets its p95 50 ms budget at 100k segments; the OR question path misses
because its candidate set is broad, so query selectivity is the next search
work before a vector/storage migration. `MeetingHealth`, not SQLite or chapter
extraction, is the first detail optimization. Band 4B must preserve arbitrary
overlap semantics and rerun this exact matrix before any later architecture is
selected.

Band 4B fulfills that gate without changing storage. The tracked comparable
report is `docs/evidence/scale-baseline-20260716-after-health.json`:

| One meeting | Health before p95 | Health after p95 | Speedup |
|---:|---:|---:|---:|
| 30 min / 1,250 segments | 24.25 ms | 2.55 ms | 9.5× |
| 2 h / 5,000 | 347.58 ms | 9.94 ms | 35.0× |
| 8 h / 20,000 | 5,385.76 ms | 41.39 ms | 130.1× |

The algorithm adds only an in-memory prefix maximum-end array over the already
loaded, sorted transcript. It changes no row, index, schema, query, observation,
or persisted output. Scoped reads remain p95 16.27 ms at 5k and 64.91 ms at
20k in the after report. D80 therefore continues to reject a `DatabasePool` or
detail cache: the next measured miss is broad OR candidate selectivity, not
storage concurrency.

Band 4C changes no schema or database concurrency model. StorageKit exact FTS
orders by FTS5's hidden `rank`, which defaults to the same BM25 score and is
characterized against explicit `bm25()` IDs. Every `SearchHit` now exposes the
complete segment text for retrieval while preserving the bounded highlighted
snippet consumed by Library, CLI, and MCP search surfaces. Quoted hostile input,
AND semantics, tombstones, and observation regions are unchanged. IntegrationsKit,
not StorageKit, owns the bounded per-term RAG policy (D81).

The comparable report is
`docs/evidence/scale-baseline-20260716-after-search.json`:

| Corpus | Exact FTS p95 | Lexical Ask p95 | Previous lexical p95 |
|---:|---:|---:|---:|
| 1,000 segments | 0.47 ms | 1.89 ms | 1.14 ms |
| 10,000 | 2.37 ms | 5.80 ms | 8.03 ms |
| 50,000 | 11.93 ms | 25.12 ms | 53.59 ms |
| 100,000 | 30.99 ms | 66.89 ms | 111.19 ms |

Both published lexical targets pass. D81 therefore retained FTS5,
`DatabaseQueue`, and the current embedding BLOB layout pending Band 4D's
semantic measurement.

Band 4D measures that semantic path without changing it. The dedicated Release
harness creates a fresh production-schema process for each corpus, stores
normalized 512-dimensional Float32 BLOBs, validates the exact fixture vector
ranks first, and records wall time, Mach-timebase-corrected CPU, footprint,
payload, and database size. Results:

| Corpus | Wall p95 | CPU p95 | Incremental footprint p95 | Database |
|---:|---:|---:|---:|---:|
| 1,000 segments | 2.62 ms | 2.66 ms | 0.17 MiB | 4.36 MiB |
| 10,000 | 29.72 ms | 30.26 ms | 8.42 MiB | 42.26 MiB |
| 50,000 | 159.07 ms | 161.98 ms | 8.44 MiB | 208.38 MiB |
| 100,000 | 325.41 ms | 328.43 ms | 8.50 MiB | 416.54 MiB |

The 100k latency/CPU path misses 100 ms while footprint remains bounded. D82
therefore selects streamed, allocation-free, bounded-top-k adapter work for
Band 4E. sqlite-vec and the additive `segmentEmbedding` layout remain
conditional on the comparable after report still missing.

Band 4E implements that adapter without changing the schema or vector format.
The first query streams only SQLite-owned BLOB bytes and rowids, scores each
exact production-width vector with Accelerate, and retains deterministic
bounded top-k candidates. It excludes tombstoned meetings through a single
subquery rather than a join per vector; a second bounded query materializes
complete segment text only for winners. Wrong-width/non-finite vectors, empty
queries, and non-positive limits return no invalid hits. Comparable results:

| Corpus | Wall p95 | CPU p95 | Incremental footprint p95 | Absolute peak p95 |
|---:|---:|---:|---:|---:|
| 1,000 segments | 0.51 ms | 0.55 ms | 0.03 MiB | 6.75 MiB |
| 10,000 | 9.86 ms | 9.95 ms | 8.41 MiB | 15.50 MiB |
| 50,000 | 45.18 ms | 45.86 ms | 8.44 MiB | 15.66 MiB |
| 100,000 | 90.22 ms | 91.26 ms | 8.42 MiB | 15.66 MiB |

The 100k wall/CPU path is 72.3%/72.2% faster and passes both targets. D83
retains exact schema-v7 Float32 BLOBs and rejects sqlite-vec, a new embedding
table, and approximation at the measured scale.
D176–D178 and D196–D200 retain `NULL` embedding rows as the durable retry
ledger while ApplicationKit coalesces redundant background-maintenance flights,
pauses between committed batches, and resumes from explicit app
lifecycle/mutation/capture-stop signals. D198 strengthens the write boundary:
`segmentsNeedingEmbeddings` returns segment/meeting/revision/text source
identity, and `storeEmbeddings(_:for:profile:)` accepts only an exact
candidate/vector set plus a valid compatibility profile. Each non-empty vector
must match the declared dimension and contain only finite values. Each
conditional update requires that same live unembedded segment, exact text, and
a live meeting at the selected transcript revision; vector and profile
fingerprint publish atomically. Concurrent
publication, correction, replacement, or deletion is an idempotent skipped
outcome and cannot overwrite current derived state. Ask and Library only read
vectors carrying the active fingerprint; their shared typed readiness probe
checks at most one missing or incompatible row and never changes storage.
Maintenance resets incompatible derived vectors and fingerprints to `NULL`
before rebuilding; exact FTS and authoritative transcript state are unchanged.
D200 wraps that cursor in an independent content-free admission and retry
ledger. Source generation plus the active profile creates one idempotent
operation identity; a lease and heartbeat prove the current scheduling owner,
not indexing progress. Capture suspension refunds the attempt. Ordinary
failures use bounded future scheduling, and an expired owner is recovered on
relaunch. The earliest pending retry or unexpired predecessor lease exposes
one deterministic wake. There is no polling loop, second progress cursor, or
second product indexing lane.

D202 deliberately changes no StorageKit schema or query. ApplicationKit's
candidate `RetrievalChunk` model retains ordered current segment identities,
source metadata, a stable membership ID, and a content-sensitive fingerprint
so turn-level retrieval policies can be benchmarked without making them
durable. Production remains one embedding per segment in schema v18. A future
chunk adapter must persist only rebuildable derived state, validate its
meeting/revision/source membership atomically against current rows, and
materialize citations from those rows rather than treating chunk text as new
authoritative evidence. Until that adapter passes the canonical quality and
resource gates, no chunk table, migration, maintenance cursor, or alternate
product search lane exists.

D203 adds only a disposable CLI benchmark projection. It may save one derived
speaker-turn candidate as one temporary segment so the existing production
retrieval implementation can rank it, but the owner-only observation maps the
candidate back to every ordered canonical fixture segment. This is not a
StorageKit schema, migration, product write path, or authorization to persist
chunk text in the user library.

D204 versions only tracked synthetic fixtures and publishes a private
content-free comparison receipt. Historical fixture verification, scorecard
comparison, and receipt publication do not create a database schema, migration,
derived corpus row, or product maintenance operation.
