# Spec 08 — Quality: tests, harnesses, and measured numbers

Status: 891 package tests passing (13 gated) + 37 XCUITest UI cases. CI on GitHub Actions (`.github/workflows/ci.yml`: macos-latest build/test, an explicit macos-15 Sequoia build/test lane, and **SwiftLint `--strict`**). The latest full English and Spanish local UI runs each passed all 37 cases and retained app-only Meeting Detail claim review, overview/decision/action-item/Companion source navigation, confirmed-person memory, 5k-segment scale detail, full Ask and command-palette answer/citation navigation, source-grounded meeting preparation, exact local-data receipts, Library/search, Insights, post-meeting mirror, proactive Whisper Settings, Sequoia intelligence-setup, explicit private-sync opt-in/older-library separation, whole-library Markdown backup, privacy-receipt, redacted-support, durable-post-capture-recovery, processing-recovery, and typed recording-failure screenshots; earlier automation-mode harness failures remain documented below.

**SwiftLint (`.swiftlint.yml`, `strict: true`)**: industry-recommended config (default rules + correctness/clarity opt-ins, industry thresholds: line 120, function-body 60/100, cyclomatic 12/20, type-body 400/600). `swiftlint lint --strict --no-cache` passes with **zero violations across 325 Swift source files**; in CI, any violation breaks the build. Inherent exceptions are suppressed inline with justification (catalog sha256 data, CLI arg-parser dispatchers, large SwiftUI views) — splitting those views remains technical debt.

## Test suite — `Tests/PortavozTests/`

| File | Coverage |
|---|---|
| ArchitectureDependencyTests | SwiftPM/XcodeGen dependency ratchets, no capability reverse dependencies, approved application imports, workflow bypass prevention including ApplicationKit-owned durable post-capture policy, a platform-free Core, Core-only PlatformKit, composition-root-only Keychain construction, onboarding permission adapters, bounded ApplicationKit CLI/MCP library reads, product-command ApplicationKit entry with presentation-only command sources, audio/model/release/privacy boundaries, scoped feature ownership including first-run/local-receipt/meeting-preparation owners, explicit canonical-people, typed overview/decision/action-item/Companion evidence, private-feedback boundaries, the content-free generation-fenced sync journal, CloudKit ownership limited to the IntegrationsKit codec/state/coordinator/delegate/runtime/platform boundary with domain replay still in StorageKit, a CloudKit-free lifecycle policy outside views, one inert consent-gated container owner, exact local/Developer-ID entitlement and profile gates, one shared Ask workflow with presentation/CLI/MCP/brief bypass prevention, architecture-document vocabulary rules, no speculative SyncKit bypass, local diagnostics/signpost redaction, and measured scale source/evidence gates |
| MeetingSyncStateTests | Empty v13→v14 migration, transactional rollback, portable versus device-local mutation filtering, typed-evidence-only replacement, in-flight N/N+1 acknowledgement, explicit live/deleted initial seed, delete/restore/purge tombstone behavior, and fail-closed limits/acknowledgements |
| MeetingSyncAggregateTests | Exact-current-generation envelope, deterministic codec, idempotent full-history replay, millisecond-tied summary-version ordering, device-local path/person/embedding preservation, trigger-echo suppression, deferred live/live local-pending conflict, recoverable privacy-dominant remote deletion, invalid-relation rollback, and immutable summary-root/child collision rejection |
| CloudMeetingRecordCodecTests | Encrypted inline payload/digest placement, protected backup-excluded CKAsset fallback, private-zone deterministic identity, matching-record reuse, checksum tamper rejection, strict format/type validation, and deletion as a saved tombstone envelope |
| CloudMeetingSyncStateTests | Content-free snapshot validation, account-scoped consent and explicit seed state, account loss/switch semantics, exact-generation attempts, bounded retries, protected payload integrity, replay cursors, restart cleanup, and atomic persistence rollback |
| CloudKitMeetingSyncPlatformTests | Exact signed container/service/environment/push/profile admission, supported development signing values, and fail-closed missing or invalid restricted capabilities without creating a container |
| MeetingSyncModelTests | Zero-observer local-only launch, explicit enable wakeup arming, journal burst coalescing, account-loss disarm, pause, silent-push/manual-cycle parity, FIFO preservation during suspended lifecycle work, and continued draining after an earlier action makes a queued sync inapplicable |
| CloudMeetingSyncCoordinatorTests | Initial-seed drain, independent partial outcomes, authenticated fetched replay and durable deferral, physical-delete metadata handling, server-tombstone settlement, split-persistence reconstruction, and stale N/N+1 save re-admission |
| CloudMeetingSyncLifecycleTests | Zero-platform local-only launch, explicit enable/seed separation, account loss and account-switch consent behavior, typed capability and identity failure, truthful retry/pause/remove-device semantics, exact-attempt readmission, and observable journal pending/acknowledged transitions |
| LibraryModelTests | Complete/empty/degraded/failed Library snapshots, reload-version and search-query fences, trimmed/debounced FTS phases, rename/action/delete/restore/purge effects, degradable mutation diagnostics, import progress/success/failure, calendar access, and on-demand brief state through a database-free client fake |
| FirstRunExperienceTests / PresentationReadModelTests | Forced/disposable/completed/existing-library welcome decisions, no unnecessary Store reads, retryable cancellation, one process-wide resolution, one restored-window presentation host, durable completion, and exact/partial local-receipt model state |
| LocalDataLedgerTests / PresentationReadStorageTests | Concurrent exact meeting/audio/voice metrics, per-source unavailable-versus-zero behavior, cancellation, live-root counting, and one batched latest-live-General-summary projection with tombstone, recipe, superseded-version, and duplicate-ID filtering |
| PrepareMeetingBriefTests | Shared Ask evidence ranking, batched current-summary admission, related-only bounded commitments, source-indexed navigable synthesis, weak/missing evidence, independent failure degradation, and cancellation propagation |
| MeetingLibraryQueryTests / ManageSecretsTests | Empty and invalid request short circuits, normalized bounded list/search/open-item delegation, and async secret round-trip/delete behavior over deterministic injected ports |
| AnalyzeAudioFileUseCaseTests / ManageLocalVoiceAndModelsUseCaseTests / PublishMeetingContentUseCaseTests | File admission and policy forwarding; deterministic transcription metrics; diarization threshold/timing/optional attribution; meeting-before-provider summary persistence; voice enroll/status/delete isolation; catalog-order verification and sequential model installation; coherent Markdown/PDF/Gist export; pending-only owner-resolved action publication; typed missing/empty states; and zero concrete model, Keychain, filesystem, or network dependency |
| MenuBarModelTests / MenuBarObservationTests | Storage-independent recent/pending composition, empty/degraded/failed phases, last-healthy-section preservation, and bounded newest-first live meeting roots through delete/restore |
| ExportLibraryMarkdownBackupUseCaseTests / LibraryMarkdownBackupStoreTests / LibraryMarkdownBackupFilesTests / LibraryMarkdownBackupModelTests | Portable canonical filename allocation, existing/concurrent collision retries, typed partial and fatal outcomes, one newest-first live SQLite snapshot with corrupt-aggregate isolation and General-summary parity, atomic non-replacing file publication, and process-scoped progress/terminal state |
| AskMeetingsUseCaseTests | Shared trimming/search/evidence/answer behavior, no-evidence generation skip, evidence-preserving ordinary generation failure, honest cancellation propagation, and capability bypass for empty/invalid requests |
| AskPresentationModelTests | Full Ask evidence fallback, process-scoped palette search/answer ownership, stale completion rejection across reset/reopen, and Markdown answer receipts |
| MeetingLifecycleUseCaseTests | Exact Delete/Restore port delegation, failure propagation, and real-Store tombstone, aggregate, trash, and voice-mix conservation through the ApplicationKit boundary |
| MeetingPurgeUseCaseTests | Manual and expired purge ports, degradable audio failure, propagated storage failure, strict cutoff, continue-after-failure, and real scratch audio/database removal |
| SummaryRegenerationUseCaseTests | Provider override, recipe/language/glossary/notes material, direct-provider failure, Apple exact cache and translation pivot/fallback, silent Apple failure, unavailability, best-effort context/save semantics, successful/failed/cancelled provenance, exact-cache no-run semantics, validation, transactional rollback, and real MeetingStore summary/run linkage |
| SummaryCapabilityTests | Deterministic Sequoia capability, clean-install Ollama chat-model selection, OCR-only Ollama fallback to MLX, and exact no-fallthrough behavior for selected but unconfigured Ollama/MLX engines |
| CompanionGenerationProvenanceTests | Exact ordered private-material fingerprints including question segment identity; external-provider sensitivity; exact local-RAG citation-to-answer-source mapping; role-separated evidence construction; content-free classifier/provider/egress configuration; aggregate-only metrics; remote success, on-device fallback, and cancelled external-provider attribution |
| DataEgressGatewayTests | Conservative loopback classification; exact remote/local Companion, summary, and explicit-publishing metadata; decoded question-only and full-summary request bodies; operation/classification/destination/provider/model/consent mismatch and non-HTTP rejection; required meeting identity; canonical publishing endpoint policy; content-free receipt-before-transport ordering; fail-closed recorder behavior; retained attempts on transport failure; redirect denial; and real gateway-backed summary response parsing |
| PrivacyReceiptTests | v6→latest migration and schema constraints; honest complete-versus-since coverage; content-free local/remote attempt and generation aggregation; strict missing/unknown/forged event rejection; and zero partial writes |
| CanonicalPeopleTests / CanonicalPeopleUseCaseTests | POSIX-stable alias normalization; real v7→v8 migration; duplicate aliases and exact candidates; explicit create-versus-existing delegation; atomic links; `Me`, missing, and already-linked rejection; and zero partial person/alias/speaker writes |
| ImportMeetingUseCaseTests | Required preparation/transcription order, typed progress, mixed-language preservation, best-effort diarization/summary, exact idle release, staged-audio rollback, atomic imported aggregate persistence, successful/failed/cancelled/no-provider summary provenance, privacy-safe metadata, and real MeetingStore summary linkage/rollback adaptation |
| ImportMeetingBundleUseCaseTests | Canonical attachment validation, duplicate rejection, text/audio ordering, machine-path clearing, early-failure isolation, compensation without error masking, full relational conservation including Companion evidence, foreign-child/evidence rejection, and rollback after an injected final evidence-link failure |
| ExportMeetingBundleUseCaseTests | Canonical attachment admission, text/audio ordering, opt-in and no-directory behavior, machine-path clearing, typed boundary failures, newest cross-recipe summary plus live-child conservation, tombstone exclusion, and degradable optional-row corruption through real MeetingStore adaptation |
| RefineMeetingUseCaseTests | Draft order/progress/language, silence/noise/bleed hygiene, exact composite transcript provenance, content-free metadata/metrics, no-attempt/failure/cancellation outcomes, revision-fenced run/segment linkage, persisted-detail/external-audio draft-and-apply ordering, fresh-speaker canonical-person non-inheritance, invalid-run rejection, Companion outcomes, immutable summaries, stale rejection, and injected transactional rollback through real MeetingStore adaptation |
| StartRecordingUseCaseTests | Once-sampled preferences, title/sequence and event-title policy, audio-first start with no live transcriber, preparation/reservation/source order, callback forwarding, selected-channel assets, typed preparation failures, staging/published evidence preservation, guarded empty-shell discard, reconciliation failure reporting, release, and real MeetingStore atomic reservation before source invocation |
| StopRecordingUseCaseTests | Finalized/missing asset reconciliation, provisional attribution, per-turn mixed-language preservation, exact diarization/transcription initial-job policy and order, empty/partial-lane transcript recovery, truly silent/no-audio outcomes, admission and fallback failures, unconditional engine release, and atomic real-Store snapshot/job adaptation |
| MeetingStoreTests summary history/evidence | Per-recipe immutable versions, newest-across-recipe selection, retained history, fingerprint cache/pivots, atomic same-meeting overview/decision/action/Companion validation, canonical decision coordinates, stable task/card identity, role-separated links, evidence clear-on-overwrite, revision stamping/staleness, physical-deletion unavailability, correction/unsupported replacement, active-claim fencing, text-erasing clear, and rollback on foreign evidence |
| AudioCaptureTests | CaptureFileWriter staging CAF, atomic no-overwrite publication, persisted-PCM recovery measurement, complete checksum/media/health evidence, drift summary, Downmix, **Resample.linear**, startup cleanup |
| AudioProcessCatalogTests | direct tap scope by bundle ID: exact app/allowed helpers accepted, lookalikes and unrelated apps rejected |
| TranscriptionTests | Mapper/deltas, WhisperEngine helpers, anti-silence hygiene, **SpokenLanguageDetector** with automatic/fixed mixed-language policy, **VocabularyPrompt**, **AudioLevel.normalizePeak** |
| CaptionCoalescerTests | 13 coalescer cases (merge, identity, channels, pauses, limits, loose punctuation, early split of `system` after sentence) |
| DiarizationTests | Catalog, SpeakerAttributor (multi-turn), SanitizeTurns, **MergeMicroClusters** (6), DiarizationEvaluation (units), live streaming (gated) |
| ProcessingOperationFingerprintTests / InitialTranscriptionOperationFingerprintTests | Length-framed SHA-256 identity; diarization segment-order stability and material/revision sensitivity; finalized audio/voiceprint/model evidence; summary provider/language/revision separation; Refine channel-order stability plus material/revision/language sensitivity and invalid-evidence rejection; and deterministic first-pass recovery identity across channel order, revision/audio changes, pending/missing/silent rejection, and canonical request policy |
| LiveSpeakerLabelerTests | 7 cases: row split with two voices, last row untouched, idempotency, mic never relabeled, "Me" by voiceprint |
| IntelligenceTests | PromptFactory, naming filters, **NamingExcerpt**, **LiveSummaryPolicy** |
| ChapterExtractorTests / PlaybackRangesTests / SummarySectionsTests / VoiceHueTests / TranscriptNoiseFilterTests | chapter boundaries/labels, safe duration-bounded voice-range complements, language-agnostic summary sections, stable speaker hues, and conservative fragment filtering without losing sentences/acronyms |
| InsightsScopeTests / LibraryStatsTests / InsightsFindingsTests | current/previous calendar windows, duration averages, zero-filled weekly cadence and heatmaps, streaks, no-decision evidence thresholds, recurring-topic ranking, stoplists, and participant exclusion |
| InsightsReadModelTests | complete scoped projection, current/previous totals, decision evidence from summaries/actions, recurring-topic extraction, and confirmed-participant exclusion |
| InsightsModelTests | complete/empty/degraded/failed phases, one read snapshot, section-local replacement, scope restart, and no-global-version behavior through a database-free client fake |
| InsightsObservationTests | independent live-rooted meeting/fact/voice/finding observations, delete/restore conservation, and active-scope finding bounds through real `MeetingStore` adaptation |
| MeetingDetailModelTests | complete/degraded/missing/failed review phases, one storage-independent projection, section-local replacement including privacy receipts, explicit persistence and canonical-person candidate/link actions/effects, exact silent versus visible failure policy, and Spotlight reconciliation requests through a database-free client fake |
| MeetingDetailObservationTests | live-rooted transcript/cast, newest-summary/action-item, Companion card/evidence, and privacy-receipt observations; evidence-link-only and independent event updates; lifecycle conservation; card/event cascades; and newest cross-recipe selection through real `MeetingStore` adaptation |
| BriefRelevanceTests / ReminderPolicyTests / MirrorStatsTests | explainable passage ranking and weak-match rejection, reminder lead window/session deduplication/off state, mirror qualification/notable delta, and factual English/Spanish synthesis |
| MeetingBundleTests | round-trip/remap of text, audio, notes, and Companion cards with role-separated evidence; malformed source-card target rejection; canonical-person link stripping; additive compatibility of format v1 |
| MeetingHealthTests | 8 cases: talk-time/share, ES/EN questions, thresholded interruptions, older-long-overlap conservation behind an ended neighbor, 200 dense timelines matched to the exhaustive reference, chained monologues, unattributed excluded |
| VocabularyMinerTests | 6 cases: domain forms, recurrence threshold, existing-vocabulary/stoplist exclusion, form heuristics |
| MeetingTypeDetectorTests | Recipes catalog + capped excerpt; gated: classifies standup/planning/interview and leaves general alone (M13b criterion) |
| StorageTests / StorageSchemaV6Tests / RecordingPersistenceTests / ProcessingJobPersistenceTests / VoiceMixTests | Complete D4/D36–D43/D63–D66/D70/D75 contract: strict persistence, tombstones, hostile FTS, hidden-rank/BM25 top-k equivalence, complete-text plus highlighted-snippet search hits, retention, paths, migration, lifecycle/idempotency constraints, atomic recording/artifact handoffs, owner-leased durable work, provenance linkage, revision fences, and injected rollback |
| PostCaptureSummaryGenerationAttemptTests | Content-free durable provider/model/job/revision/config metadata, aggregate-only success metrics, and distinct failed/cancelled terminal attempts without invented output metrics |
| ProcessPostCaptureJobsUseCaseTests | Mixed-language first-pass cleanup/attribution and follow-up admission; real-Store diarization-to-summary publication; provider retry; optional-summary exhaustion; supersession; lease loss; typed diagnostics; and injected-clock no-poll scheduling |
| RecordingsLocationTests | 7: marker, fallback, resolve, resumable migration |
| CoreTypesTests | Types + **TitleTemplate** + canonical `LanguageCode`, canonical person/alias normalization, independent transcript/summary policies, and backward-compatible role-separated Companion evidence resolution |
| LocalizationTests / EnglishSourceTests | EN/ES String Catalogs, placeholders, `.lproj` export, public-source English hygiene (README/top-level tooling, scripts, `.github`, packaging, app source), and English explanatory prose throughout `docs/` |
| RAGTests / MCPServerTests / VoiceIdentityTests / IntegrationsTests | Term-level lexical RRF, multi-term evidence, duplicate suppression, complete segment context, long-question broad-OR fallback, production-width semantic top-k, scalar-oracle equivalence, stable ties, safe limits, malformed/non-finite-vector exclusion, hybrid RAG fusion, MCP protocol, encrypted voiceprint, and offline exporters |
| ParakeetIntegrationTests + gated | Real models — require `PORTAVOZ_MODEL_TESTS=1` + `PORTAVOZ_TEST_WAV` / `PORTAVOZ_TEST_CONVERSATION_WAV` / `PORTAVOZ_TEST_ENROLL_WAV` |

Band 1 slice 1A additionally ran a manual storage acceptance smoke: copy the
real v5 database to `/tmp`, migrate only the scratch file through the current
CLI, and compare legacy logical rows and meeting fields before/after. The v6
copy preserved them, left all new workflow tables empty, returned
`integrity_check = ok`, and had zero foreign-key violations. The live database
was never opened by v6 code.

Band 1 slice 1B adds four focused persistence tests. They prove that the shell
and every pending asset commit atomically, a conflicting asset path rolls the
new shell back, invalid ownership/channel/path/state shapes write nothing, and
hard rollback cannot remove a shell that already owns transcript content.
Controller integration is retained by the full app build and the existing
English/Spanish XCUITest suites; capture hardware itself is not simulated by
XCUITest. The dev app is reinstalled only as `/Applications/Portavoz Dev.app`;
the install target now fails closed unless both the pre-copy bundle and installed
copy pass deep/strict code-signature verification before launch.

Slice 1C adds six focused tests. Audio coverage proves that final CAF names do
not exist while recording, Stop publishes a readable file with complete
duration/size/SHA-256/level/health evidence, and an existing final file is
never overwritten while staging remains recoverable. It also verifies finite
silence and clipped-PCM evidence. Storage coverage proves that
meeting/assets/provisional cast/transcript/notes/cards commit together, a
final-path collision rolls every write back, malformed finalized metadata is
rejected, and a shell modified after reservation cannot be replaced.

Slice 1D-a adds seven focused durable-job tests. They prove atomic immutable-key
enqueue and terminal idempotency, reject invalid batches before writes, fence
heartbeat/completion/failure by owner and expiry, order due work by priority
within worker capabilities, hide and skip tombstoned meetings, schedule retries
without duplicate jobs, derive `processing`/`ready`/`needsAttention`, recover
expired leases repeat-safely through exhaustion, and reject corrupt persisted
identity/state/lease contracts.

Slice 1D-b1 adds three focused package tests. Audio coverage proves recovery
rereads persisted PCM after in-memory meters are gone and publishes complete
evidence. Storage coverage proves multi-channel recovered assets commit
atomically, conflicts roll back earlier channel updates, exact repeats are
no-ops, ready meetings cannot be downgraded, and an interrupted `capture.*`
shell becomes a captured `needsAttention` aggregate with its audio intact.
The same 16-case XCUITest suite passes in default, forced-English, and
forced-Spanish launches (48 UI executions); the recovery case opens the
restored meeting and observes the real player controls.

Slice 1D-b2a adds five focused durable-artifact tests. They prove that
diarization replacement, transcript revision, job success, and dependent
enqueue commit together; an injected SQLite failure rolls the cast and job
back together; a changed transcript revision rejects a stale summary without
writing; summary snapshot and job success commit once; and generated-content
jobs cannot bypass their artifact boundary through generic completion. The
existing capture-recovery test now also proves successful job history neither
hides unresolved publication nor blocks a later return to `ready`.

The first 1D-b2b control-plane unit adds two focused job tests. They prove that
cancellation is owner-fenced, terminal, non-resurrecting, and non-failing for the
meeting aggregate; and that scheduled-wake discovery returns the earliest future
deadline only for supported kinds rooted in live meetings.

The second 1D-b2b unit adds four focused operation-fingerprint tests and the
concrete process-scoped executor. The tests prove delimiter-safe generic
identity; stable segment-order handling with sensitivity to material and source
revision changes; refusal to run with incomplete audio evidence; and distinct
summary operations for provider, output-language, and transcript-revision
changes. A direct app launch against fresh disposable database/audio roots
reached `ready` at transcript revision 1 with both jobs succeeded and the
original Spanish transcript unchanged. A 17th XCUITest characterizes the same
launch-resume chain with a deterministic fake summary provider. Its
`-seed-processing` fixture is legal only with `-use-temp-store` and bypasses
real audio, models, biometric files, and Keychain. Meeting Detail also treats
the participant-voice gallery as empty in this mode. Five local XCUITest attempts
across the executor and producer units ended before assertions with `Timed out
while enabling automation mode`; this is the harness flake documented below,
not a product assertion failure.

The final 1D-b2b producer unit adds three focused package tests. They prove the
canonical initial diarization request's priority and retry policy, successful
atomic captured-snapshot plus initial-job admission, and rollback to the
original recording shell when SQLite rejects the job insert. Normal Stop now
uses that Unit of Work, opens the meeting as soon as its durable handoff commits,
and lets the process supervisor finish diarization and summary. The worker runs
the configured post-meeting Shortcut only after the last applicable artifact is
durable; disposable `-use-temp-store` launches never invoke host Shortcuts.

Band 2 slice 2A adds five architecture tests and no production behavior. The
tests parse the real Package.swift target blocks rather than a duplicate graph,
verify the XcodeGen product edge, exercise the generic use-case boundary, and
scan source imports. At that checkpoint the dependency ratchet began with
ApplicationKit → Core and temporarily allowlisted Core's Security import. The
current ratchet requires zero platform-framework imports in Core and confines
Keychain construction to the app and CLI composition roots through PlatformKit.

Band 2 slice 2B adds three lifecycle use-case tests and one architecture rule.
The unit boundary records the exact requested delete/restore operations through
a database-free actor port and proves persistence errors remain typed failures
instead of being swallowed. The real-store characterization verifies a deleted
meeting disappears from live lists, detail, and voice mix while remaining in
trash, then returns with the same meeting, speaker, segment, and mix identities.
The source rule rejects direct `store.delete/restore` writes in the
app, covering the Library, Meeting Detail, and Recently Deleted adoption.

Band 2 slice 2C adds four purge tests without a new dependency. They prove
audio removal is attempted before storage, an audio error does not block the
privacy purge, a storage error still propagates, and expired cleanup filters
strictly before its injected cutoff while continuing after one failed entry.
The integration case removes both a real in-memory tombstone and its scratch
audio directory. The existing source rule now also rejects direct app
`store.purge` writes; FileManager stays confined to the private app adapter.

Band 2 slice 2D adds nine regeneration tests and a seventh architecture rule.
The tests characterize the complete Meeting Detail decision tree without real
models: per-meeting override plus recipe/language/glossary/notes, direct local
generation, Apple exact cache, translated pivot, translation fallback to full
generation, unavailable engines, visible versus silent provider failure, and
the released best-effort note/save policy. A real in-memory MeetingStore case
proves note loading and immutable snapshot persistence through the port. The
source rule rejects the former direct provider/cache coordination in the app.

Band 2 slice 2E adds the T16 storage/history test, strengthens the existing
Apple reuse test with an explicit Standup recipe key, and adds the 18th
XCUITest. The UI fixture stores General first and Standup second; Meeting Detail
must render the Standup badge and content after its normal reload. This proves
the visible state through the real app/store boundary without invoking a model,
while the storage test proves the older General snapshot remains addressable.
The focused newest-recipe case and the complete 18-case local XCUITest suite
both pass.

Band 2 slice 2F adds thirteen import tests and an eighth architecture rule. Port
fakes characterize exact progress/order, automatic mixed-language recognition,
required first model preparation and transcription, degradable second
diarizer reload/inference (including reuse of an existing engine after reload
failure), optional summary generation/persistence, and the
released idle-release boundary. Failure cases prove every required precommit
error attempts staged-audio cleanup without masking its original error. A real
in-memory MeetingStore case persists the aggregate and summary through the
ports; ownership validation rejects foreign children, and an injected SQLite
segment failure proves meeting, cast, and transcript roll back together. The
source rule permits one app wrapper only and rejects a return to direct import
orchestration. Strict SwiftLint remains clean across 206 source files.

Band 2 slice 2G adds sixteen refine tests and a ninth architecture rule. Port
fakes characterize exact progress/order, fixed-language recovery versus
automatic mixed-language evidence, silent-channel skipping, microphone
noise/bleed filtering, required preparation/transcription failures,
best-effort diarization, cancellation propagation, and exact idle release.
Apply cases prove the source revision reaches storage, empty drafts never write,
Companion unavailable/incomplete/complete-empty/persistence-failure outcomes
preserve the transcript contract, and real MeetingStore acceptance increments
the revision while retaining immutable summaries. Stale drafts preserve the
newer aggregate, while an injected SQLite child failure rolls language, cast,
transcript, and revision back together. The architecture rule rejects direct
app `applyRefinedCast`, `replaceCast`, or `replaceCompanionCards` bypasses. A
temp-store-only running-refine fixture adds the 19th XCUITest: cancel returns
the existing control to idle and leaves the visible Spanish transcript intact.
Strict SwiftLint remains clean across 209 source files.

Band 2 slice 2H adds eleven Stop tests and a tenth architecture rule. Port
fakes prove finalized/missing channel reconciliation, homogeneous versus mixed
language without segment translation, transcript-empty preservation, staging
and final-path recovery, guarded empty-shell discard, exact initial-job policy,
commit-before-kick ordering, and engine release on every explicit outcome.
Injected first-write failure proves the atomic admission rolls back before a
no-job `needsAttention` fallback; a second failure is never reported as a
commit. A real in-memory MeetingStore case proves captured snapshot and job
visibility together. The architecture rule requires the controller to call
`ApplicationKit.StopRecording` and rejects direct snapshot or old job-factory
bypasses. Strict SwiftLint remains clean across 211 source files; no UI control
or visible behavior changed, so the existing 19-case suite remains the UI
contract.

Band 2 slice 2I adds ten Start tests and an eleventh architecture rule. Port
fakes prove preferences are sampled once, title sequence and calendar-event
override remain exact, model preparation precedes one atomic shell/asset
reservation, and sources start only afterward with the selected channels,
language hint, vocabulary, and live callbacks. Typed preparation and
reservation failures release resources without starting sources. Source-start
failures check both staging and published paths, preserve evidence as
`needsAttention`, discard only an untouched empty shell, and report a refused
or failed reconciliation without claiming it succeeded. A real in-memory
MeetingStore case proves the complete reservation is visible before the start
callback. The architecture rule requires `services.startRecording.execute` and
rejects direct `beginRecording`, `MicrophoneSource`, `RecordingSession`, or
system-tap construction in the controller. Strict SwiftLint remains clean
across 213 source files; no UI control or visible copy changed, so the existing
19-case suite remains the UI contract.

Band 2 slice 2J adds thirteen launch-recovery tests and a twelfth architecture
rule. Port fakes prove expired leases run first, the live-recording gate is
sampled per candidate, active capture defers without reading files, recovered
audio installs an explicit transcript-recovery snapshot, empty shells use only
the guarded discard, missing/ambiguous evidence keeps canonical guidance,
captured and processing meetings respect durable jobs, and publication-only
recovery never replaces existing content. Candidate-read and preservation
failures retain the released invalidation/reporting timing. A real in-memory
MeetingStore case proves ready protection and empty-shell deletion together.
The architecture rule requires app launch recovery to enter through
`RecoverInterruptedMeetings`, keeps CAF recovery in the private adapter, and
asserts worker resume remains later in launch order. Strict SwiftLint remains
clean across 215 source files; no UI control or visible copy changed, so the
existing recovery XCUITest and 19-case suite remain the UI contract.

Band 2 slice 2K adds nine bundle-import tests and a thirteenth architecture
rule. Port fakes prove that text-only import writes no files, audio stages before
the Store commit, machine-local paths are cleared, document/stage failures
cannot reach persistence, and a Store failure attempts compensation without
masking the original error. Boundary tests reject path-shaped or unknown
channels, unsupported/path-shaped extensions, and duplicate canonical
channels. Real in-memory Store cases prove every format-v1 relational child is
conserved as immutable summary version 1, foreign summary/note ownership is
rejected before writes, and a trigger rejecting the final Companion card rolls
the whole aggregate back. The architecture rule keeps bundle import behind
ApplicationKit and sequential Store writes out of the app adapter. Strict
SwiftLint remains clean across 216 source files; no interactive UI or localized
copy changed, so the existing 19-case suite remains the UI contract.

Band 2 slice 2L adds eight bundle-export tests and a fourteenth architecture
rule. Port fakes prove exact load/read/encode order, path stripping, audio
opt-in and no-directory skips, canonical channel/extension admission, complete
content handoff, typed missing/store/document failures, and no work after an
early failure. Real in-memory Store cases prove the newest summary across
recipes, cast/transcript/notes/Companion conservation, tombstone exclusion,
and the released degradable fallback for corrupt optional rows. The
architecture rule keeps MeetingBundle construction and meeting-length reads
out of Meeting Detail while preserving private IntegrationsKit and filesystem
adapters. Strict SwiftLint remains clean across 218 source files; no
interactive control or localized copy changed, and the existing 19-case suite
remains the UI contract.

Band 2 slice 2M adds eight direct `LibraryModel` tests and a fifteenth
architecture rule. A database-free client fake proves one complete latest-
version value snapshot; empty, degraded, and failed load phases; stale-version
rejection; trimmed/debounced FTS with loaded/empty/degraded/idle outcomes;
rename, action-item, delete/restore/purge actions and navigation effects;
preserved degradable mutation behavior; import progress/error routing; and
calendar/brief state. The source rule requires ContentView-owned feature state
and rejects direct Store/lifecycle/broad-invalidation mutations or local
meeting arrays in Library/Trash views. SwiftPM tests directly depend on the
`portavoz-app` executable target, which Swift 6 supports even though it contains
`@main`; no extra feature library was introduced. Strict SwiftLint remains
clean across 220 Swift files. The existing grouped-Library XCUITest now types
through `library-search-field` and observes the seeded real-FTS result, covering
the SwiftUI binding/model/client integration. No visible control or localized
copy changed, and the full 19-case XCUITest suite remains the UI contract.

Band 2 slice 2N adds three real-Store `LibraryObservationTests` and expands the
Library model suite to nine cases while retaining the fifteenth architecture
rule. Observation coverage proves that meeting/voice-mix, open-item, trash,
and active-FTS streams refresh from only their declared base-table regions;
delete/restore conservation; search refresh after segment text and meeting-title
writes; and independent projection availability when corrupt meeting data
breaks one stream. Model coverage proves that a later section failure preserves
its last healthy data while degrading the aggregate phase. The source rule now
requires ApplicationKit-owned Library contracts, explicit StorageKit regions,
app-edge stream merging, and zero StorageKit/broad-version state in
`LibraryModel` or Library views. The complete baseline is 573 package tests (13
gated), strict SwiftLint is clean across 222 Swift files, and the unchanged
19-case XCUITest suite remains the end-to-end UI contract (D54).

Band 2 slice 2O adds the sixteenth architecture rule and relocates four
already-characterized product policies without changing their APIs. The rule
requires `ChapterExtractor`, `PlaybackRanges`, `SummarySections`, and
`VoiceHue` source ownership in ApplicationKit, rejects copies in
IntegrationsKit, and requires every direct app consumer to import the inward
boundary. Their 18 existing tests remain green. The complete baseline is 574
package tests (13 gated), strict SwiftLint remains clean across 222 Swift
files, and all 19 XCUITest cases pass. The existing Meeting Detail rail and
grouped Library cases now retain named screenshots as visual evidence; no new
case, control, or localized assertion was needed (D55).

Band 2 slice 2P adds the seventeenth architecture rule and relocates three
already-characterized Insights policies without changing their APIs. The rule
requires `InsightsScope`, `LibraryStats`, and `InsightsFindings` source ownership
in ApplicationKit, rejects copies in IntegrationsKit, and prevents
`InsightsView` from regaining the broad outbound import. Their 21 existing tests
remain green. The complete baseline is 575 package tests (13 gated), strict
SwiftLint remains clean across 222 Swift files, and all 19 XCUITest cases pass.
The heatmap case now retains an app-window-only Insights screenshot in addition
to the existing Library and Meeting Detail evidence (D56).

Band 2 slice 2Q adds the eighteenth architecture rule and relocates the final
three characterized local product policies without changing their APIs. The
rule requires `BriefRelevance`, `ReminderPolicy`, and `MirrorStats` to remain in
ApplicationKit, `UpcomingEvent` to remain in Core, and EventKit mapping to
remain in IntegrationsKit. Their 14 existing tests remain green. The complete
baseline is 576 package tests (13 gated), strict SwiftLint is clean across 223
Swift files, and all 20 XCUITest cases pass. A new temp-store-only
fresh-recording case asserts the real opted-in `mirror-card` sheet and retains
app-window screenshot evidence (D57).

Band 2 slice 2R adds the nineteenth architecture rule, three direct
`InsightsReadModel` tests, four `InsightsModel` tests, and two real-Store
`InsightsObservationTests`. The source rule requires one ContentView-owned
feature model, ApplicationKit-owned projection contracts, four app-mapped
StorageKit streams, and an `InsightsView` with no StorageKit, direct Store, or
`libraryVersion` dependency. Tests prove complete/empty/degraded/failed state,
scope restarts, section-local replacement, decision/participant policy,
live-rooted delete/restore conservation, and active-scope finding bounds. The
complete baseline is 586 package tests (13 gated), strict SwiftLint is clean
across 227 Swift files, and all 20 XCUITest cases pass. The existing heatmap
case retains app-window-only Insights evidence. No control, localized copy,
schema, or visible calculation changed (D58).

Band 2 slice 2S adds the twentieth architecture rule, four direct
`MeetingDetailModel` tests, and two real-Store `MeetingDetailObservationTests`.
The source rule requires ApplicationKit-owned review contracts, one
route-owned model, three app-mapped StorageKit streams, and no return to the
`libraryVersion`-keyed sequential detail/summary/Companion read path. Tests
prove complete/degraded/missing/failed state, section-local replacement,
live-rooted delete/restore conservation, action-item and card refresh, and
newest cross-recipe selection. The complete baseline is 593 package tests (13
gated), strict SwiftLint is clean across 231 Swift files, and all 20 XCUITest
cases pass. The detail-rail case retains fresh app-window-only evidence. No
control, localized copy, schema, or visible review behavior changed (D59).

Band 2 slice 2T extends the twentieth rule so `MeetingDetailView` cannot reach
Store, lifecycle, or `libraryVersion`; its route-owned model must expose the
explicit mutation actions and the app adapter must implement their narrow
client. Two direct model tests prove title/speaker/action-item/Companion/delete
delegation, suggestion and navigation effects, exact silent versus visible
failure policy, and compatibility-reindex timing. The complete baseline is
595 package tests (13 gated), strict SwiftLint is clean across 231 Swift files,
and all 20 XCUITest cases pass. The existing tabbed-summary case now toggles a
seeded action item through the model and waits for the scoped summary stream to
publish `1/1`; the rail case retains fresh app-window-only evidence. No control,
localized copy, schema, or visible review behavior changed (D60).

Band 2 slice 2U adds the twenty-first architecture rule after a package and
public-source compatibility audit found no consumer for `ContextFeedKit` or
`SyncKit`. The two placeholder products, targets, test edges, and source files
are removed while Core's `ContextItem` and all released behavior remain. The
manifest regression test prevents either speculative boundary from silently
returning. The complete baseline is 596 package tests (13 gated), strict
SwiftLint is clean across 229 Swift files, and all 20 XCUITest cases pass. A
fresh Meeting Detail app-window attachment confirms the package simplification
does not change visible behavior (D61).

Band 3 slice 3A adds four provenance assertions/cases to the regeneration
suite: deterministic provider/model/revision/fingerprint/config/language/timing/
metrics fields; successful translation and failed-pivot/full-generation attempt
ordering; cancellation outcome; exact-cache no-run behavior; real-Store linked
lookup; rejection of orphaned success and blank summary language; and rollback
of run, summary, and actions after an injected duplicate-action failure. The
complete baseline is 600 package tests (13 gated), strict SwiftLint is clean
across 230 Swift files, and all 20 XCUITest cases pass. Fresh Meeting Detail
app-window evidence confirms no visible output or interaction changed (D62).

Band 3 slice 3B adds two direct durable-attempt tests and one late-transaction
rollback case. They prove exact provider/model/job/revision/config identity,
absence of transcript/note/glossary/summary text from provenance, aggregate-only
metrics, distinct failed/cancelled terminal outcomes, required job/run
fingerprint equality, successful summary/run linkage, and rollback of run plus
artifact when job success is rejected. The complete baseline is 603 package
tests (13 gated), strict SwiftLint is clean across 230 Swift source files, and
all 20 XCUITest cases pass. The durable processing resume case exercises the actual
worker path. Fresh Meeting Detail evidence confirms no visible behavior
changed; the retained content view is cropped only at the far-left edge because
an unrelated macOS privacy prompt repeatedly overlaid that part of the original
app-window attachment, and validation did not accept or alter that permission
(D63).

Band 3 slice 3C adds three import provenance cases around the existing import
characterization suite. They prove exact provider/model/revision/fingerprint/
language/timing/config identity, aggregate-only metrics, no meeting content in
provenance, failed and cancelled terminal attempts, and no synthetic run when
the provider is unavailable. A real-Store success links the run to the imported
summary; an injected summary insert failure rolls that optional transaction
back, persists the same attempt as failed, and leaves the previously committed
meeting/cast/transcript available. The complete baseline is 606 package tests
(13 gated), strict SwiftLint is clean across 230 Swift source files, and all 20
XCUITest cases pass. Fresh Meeting Detail evidence confirms no visible behavior
changed (D64).

Band 3 slice 3D adds two exact Refine operation-fingerprint cases and one
invalid-provenance Store case while strengthening the existing Refine suite.
The 17 Refine cases now prove one privacy-safe composite run across actual
non-silent channels, automatic/fixed language metadata, no run for silent
input, standalone failed/cancelled attempts, an ephemeral success before
review, atomic accepted run plus segment links, link retention on later segment
save, rejection of kind/language/revision mismatch, stale-draft rollback, and
rollback of generation/cast/transcript/metadata when the injected segment
trigger fires. The trigger test now reuses one draft so its relational IDs are
valid and the intended late failure is actually reached. The complete baseline
is 609 package tests (13 gated), strict SwiftLint is clean across 231 Swift
source files, and all 20 XCUITest cases pass. Fresh Meeting Detail evidence
confirms no visible behavior changed (D65).

Band 3 slice 3E adds four direct Companion provenance cases and four
real-Store cases while strengthening the existing Stop persistence and
post-Refine use-case coverage. The direct cases prove exact ordered private
material and external-provider sensitivity, no private content in config or
metrics, aggregate-only card metrics, honest external success, external failure
plus on-device fallback, and cancelled-provider attribution without output
metrics. Storage proves card/run linkage, preservation of that link through a
later generic card save, rejection of stale successful and standalone terminal
runs, and rollback of both new run and prior-card tombstones when a late card
insert fails. The captured-snapshot test installs a linked live success and a
standalone failed attempt in the same Stop transaction; Refine tests prove a
complete refresh sends artifacts and an incomplete refresh preserves cards
while exposing terminal history. The complete baseline is 617 package tests
(13 gated), strict SwiftLint is clean across 233 Swift source files, and all 20
XCUITest cases pass. Fresh Meeting Detail evidence confirms no visible behavior
changed (D66).

Band 3 slice 3F adds six offline `DataEgressGatewayTests`: only provable
loopback is local-device; remote and local Companion calls expose exact
content-free metadata; the captured JSON body contains static instructions and
the classified question but no transcript context; forged destination/provider
disclosures and non-HTTP destinations are rejected before transport; and
persisted Settings consent requires a source meeting. Companion provenance
cases now retain remote scope across success, fallback, and cancellation. The
22nd architecture test requires the
Core port, IntegrationsKit validation/transport adapter, gateway-injected
Companion client, production app composition, and no direct network call in the
adopted path. The complete baseline is 624 package tests (13 gated), strict
SwiftLint is clean across 235 Swift source files, and all 20 XCUITest cases pass.
Fresh Meeting Detail evidence confirms no visible behavior changed (D67).

Band 3 slice 3G-a adds three offline `DataEgressGatewayTests` for remote and
loopback OpenAI-compatible summaries, decoded full-summary request material,
real gateway-backed response parsing, exact provider/model/destination/scope,
and rejection of missing meeting identity or cross-operation consent before
transport. Existing Companion coverage now also rejects a summary consent
marker. The 23rd architecture test requires the public summary client and
provider to depend on `DataEgressGateway`, keeps the shared chat codec internal
and transport-free, and verifies app/CLI gateway composition. The complete
baseline is 628 package tests (13 gated), strict SwiftLint remains clean across
235 Swift source files, and all 20 XCUITest cases pass. Fresh Meeting Detail
evidence confirms no visible behavior changed (D68).

Band 3 slice 3G-b adds gateway-backed success and provider-failure runtime cases
for Gist, GitHub Issue, and Linear Issue publishing plus four direct policy cases covering accepted
canonical requests and forged operation, classification, consent,
provider/model, method, body, and fixed/dynamic endpoint metadata. The
request/response assertions retain the released body,
authorization, parsing, and failure contracts. The 24th architecture test keeps
all three publishers free of URLSession, requires app/CLI gateway composition
with real meeting identity, and prevents concrete gateway use from escaping the
composition roots. The complete baseline is 640 package tests (13 gated),
strict SwiftLint remains clean across 235 Swift source files, and all 20
XCUITest cases pass. Fresh Meeting Detail evidence confirms no visible behavior
changed (D69).

The Jul 16 audio-first stabilization adds three exact initial-transcription
fingerprint cases, one atomic recovered-transcript/dependent-job persistence
case, two Stop recovery cases for empty and partially failed live captions, and
hardens the generated-artifact and Start/architecture contracts. The suite now
proves capture starts without a resident transcriber, purely silent evidence
does not admit unusable work, generic completion cannot fake transcription
success, and model loading cannot return to the pre-capture adapter. The
complete baseline is 646 package tests (13 gated), strict SwiftLint is clean
across 238 Swift source files, and all 20 XCUITest cases pass. Fresh app-window
evidence confirms the deterministic Meeting Detail surface remains healthy
(D70).

The proactive Whisper stabilization adds a 25th architecture dependency rule:
Settings may request preparation but cannot construct a ModelStore; the app
composition root owns the background task and retained token; and
TranscriptionKit exposes an opaque verified preparation/load split. The
clean-install Settings XCUITest requires a proactive Turbo download action and
keeps a screenshot of that pane. Existing ModelStore corruption/repair cases
remain the integrity contract. The complete baseline is 647 package tests (13
gated), strict SwiftLint is clean across 240 Swift source files, and all 20
XCUITest cases pass (D71).

The capability-aware intelligence stabilization adds five pure app-policy
cases and one end-to-end UI case. They prove the deterministic Sequoia fixture,
clean-install chat-model choice, OCR-only Ollama rejection, and that selected
Ollama/MLX configurations cannot fall through to Apple. The UI case launches a
meeting without a summary, selects Apple under simulated Sequoia capability,
generates, follows the actionable alert directly into Intelligence Settings,
verifies the unavailable explanation, and then verifies that the Voice pane
explains Companion without exposing a dead enable toggle. It retains named
`sequoia-summary-actionable-settings` and `sequoia-companion-requirements`
screenshots; under Xcode's Spanish test locale it also asserts that the dynamic
hardware recommendation crosses the app localization boundary. The complete
baseline is 652 package tests (13 gated), strict
SwiftLint is clean across 244 Swift source files, and all 21 XCUITest cases pass
in both the default and forced-Spanish suites (D72).

The role-specific speech-readiness stabilization adds a 26th architecture
case. It isolates Refine preparation and proves that it requires Whisper only,
that its later attribution asks for pyannote directly, that the Parakeet loader
cannot construct pyannote (and vice versa), that external-audio Import never
loads the broad live bundle, and that durable first-pass recovery asks only for
Parakeet. Existing Refine and Import cases retain honest diarization
degradation. The complete baseline is 653 package tests (13 gated), strict
SwiftLint is clean across 244 Swift source files, and all 21 XCUITest cases pass
in both default and forced-Spanish suites (D73).

The distribution stabilization adds a 27th architecture case. It locks the
ordered boundary: archive/notarize/staple the inner app before packaging,
notarize/staple the outer DMG afterward, and run the extracted-app verifier only
after the image submission. `verify-distribution.sh` mounts the final image,
copies `Portavoz.app` to scratch exactly as a cask does, and independently
requires deep/strict codesign, a stapled ticket, and Gatekeeper acceptance. The
published v0.6.0 DMG passes the outer checks and intentionally fails this new
inner-ticket gate, which reproduces the defect. At D74 landing, the baseline
was 654 package tests (13 gated), strict SwiftLint was clean across 244 Swift
source files, and all 21 XCUITest cases passed (D74). The configured `macos-15` CI lane
must become green on the first pushed commit; it is not claimed as locally run
from a macOS 26 host.

Band 3 slice 3H adds a 28th architecture case plus direct gateway, migration,
storage, observation, model, localization, and UI coverage. The tests prove
validation-before-receipt-before-transport order, fail-closed receipt writes,
attempt retention after transport failure, zero transport/event on invalid
metadata, redirect denial, strict event ownership/host validation, v6→v7
coverage honesty, purpose-built generation projection, independent receipt
updates, and cascade-safe deletion/restoration. The seeded Meeting Detail rail
contains one deterministic remote summary attempt and retains the named
`band-3h-privacy-receipt` app-window screenshot in both supported locales
(D75). The complete current gate is 663 package tests (13 gated), strict
SwiftLint is clean across 245 Swift source files, and all 21 XCUITest cases
pass in English and Spanish.

Band 3 slice 3I adds adversarial support-report, durable retry, and scoped
processing-observation package cases plus model and localization conservation.
The redaction fixture plants secret meeting/transcript/summary/action/card
content, raw errors with a local path, full URLs, config/metrics payloads, and
raw fingerprints; the exported report must contain none of them while retaining
sanitized lifecycle, readiness, stable codes, provenance, destination host, and
privacy evidence. Persistence proves manual retry resets only failed jobs while
preserving identity, idempotency, input fingerprint, and required revision.
Observation/model coverage proves processing is a fifth failure-isolated detail
section and one retry action kicks the worker. The EN/ES UI suites add named
`band-3i-redacted-support-export` and `band-3i-actionable-processing`
app-window screenshots and inspect a real temp JSON file without opening a save
panel. The slice gate is 667 package tests (13 gated), strict SwiftLint is
clean across 249 Swift source files, and all 23 XCUITest cases pass in English
and Spanish (D76).

Band 3 slice 3J adds typed Start and Stop unit cases for preparation,
reservation, capture reconciliation, fallback persistence, critical recovery
persistence, and destructive cleanup outcomes. The 30th architecture case
locks Core's five categories, the two workflow enums, the absence of
`error.localizedDescription` in ApplicationKit Start/Stop, and app-only
localized recovery mapping. A temp-store-only failed-start fixture adds the
24th XCUITest and retains `band-3j-typed-recording-failure` app-window
screenshots in both locales. The current gate is 671 package tests (13 gated),
strict SwiftLint is clean across 250 Swift source files, and all 24 XCUITest
cases pass in English and Spanish (D77).

Band 3 slice 3K adds the 31st architecture case: the shipping entitlements must
remain explicitly non-sandboxed while D78 is active, the experimental
entitlements must enable App Sandbox, the signed runner must verify the bundle
and enforcement result, and D78 must remain present. The repeatable capability
harness runs a sandboxed probe and same-binary non-sandboxed control against a
dedicated temporary legacy folder and loopback server; it never reads Portavoz
user data. The tracked macOS 26.5.2 result proves containment, child-process
inheritance, microphone, Keychain, hotkey, network, and process-catalog
behavior. Both variants also create and start/stop the full private
tap/aggregate/IOProc graph, proving structural setup compatibility without
claiming a complete product capture. The current gate is 672 package tests (13 gated),
strict SwiftLint remains clean across 250 product Swift source files, and the
unchanged 24-case EN/ES XCUITest baseline remains authoritative (D78).
The privacy-coverage migration bracket uses the same 1 ms durable timestamp
precision as SQLite, preventing a sub-millisecond in-memory comparison flake.

Band 4 slice 4A adds the 32nd architecture case and two content-free,
reproducible performance runners. `scripts/run-scale-baseline.sh` requires a
Release CLI report with all four library and all three long-meeting points;
`scripts/run-detail-ui-baseline.sh` refuses the notarized release app and uses
only Portavoz Dev plus a disposable store. The architecture ratchet also
requires strict comma-matrix parsing, the temp-store fixture gate, the
first-content signpost, D79, both tracked JSON reports, and an explicit
limitation when Instruments returns no SwiftUI update rows. The package gate is
673 tests (13 gated) and strict SwiftLint covers 252 product Swift sources.

The 25th XCUITest launches a 2-hour/5,000-segment meeting with no audio or
models, verifies title/transcript/chapters, waits for a normal scoped summary
revision update, and retains the inspected
`band-4a-scale-detail-5000-segments` screenshot. Both EN and ES suites use the
same content fixture and stable accessibility identifiers. The tracked Release
matrix contains 20 storage/query samples and three expensive derived-policy
samples per point. At 100k library segments, exact FTS is p95 44.35 ms while
broad OR retrieval is p95 121.64 ms. At 5k/20k segments, scoped detail reads
are p95 17.22/67.70 ms, chapter extraction is p95 0.85/3.84 ms, and
`MeetingHealth` is p95 347.58/5,385.76 ms. The app baseline reaches first
content in 522.30 ms and records one 515.86 ms initial hang. Xcode 26.6 Time
Profiler records 15,908 rows and the expected symbols, but its SwiftUI template
emits `Trace file had no SwiftUI data`; D79 therefore leaves update-cause scope
open instead of treating zero rows as a pass.

Band 4 slice 4B adds two semantic characterizations and extends the 32nd
architecture case with the prefix-boundary source contract, D80, comparable
after reports, a >10× 5k health improvement, a sub-300 ms first-content gate,
and zero measured hangs. The full Release after-report records health p95
2.55/9.94/41.39 ms at 1,250/5,000/20,000 segments versus
24.25/347.58/5,385.76 ms before. The installed-app after-report records
91.87 ms first content and no hang versus 522.30 ms and one 515.86 ms hang.
The package baseline is 675 tests (13 gated); the user-visible fixture and the
25-case EN/ES UI contract are unchanged. Xcode 26.6 still reports no SwiftUI
update rows, so that limitation remains explicit.

Band 4 slice 4C adds three retrieval characterizations and extends the 32nd
architecture case with D81, hidden-rank source guards, the exact production
lexical harness, a p95 <100 ms budget, and a >25% improvement gate. Storage
proves hidden `rank` selects the same top-k IDs as explicit BM25 and keeps
hostile OR input harmless. RAG coverage proves multi-term evidence climbs
without duplicates, selected passages retain complete segment text, and a
question longer than eight terms keeps the broad-OR fallback. The comparable
Release report records exact/lexical p95 30.99/66.89 ms at 100k segments,
versus 38.38/111.19 ms after Band 4B. The package baseline is 678 tests (13
gated), 252 Swift source files remain in scope, and the unchanged 25-case EN/ES
UI contract remains authoritative.

Band 4 slice 4D extends the 32nd architecture case with the isolated semantic
CLI, per-checkpoint Release-process runner, D82, Mach-timebase CPU conversion,
physical-footprint counters, top-result validation, production dimension, and
the tracked missed target. The 20-run matrix records semantic wall/CPU p95
2.62/2.66 ms at 1k, 29.72/30.26 ms at 10k, 159.07/161.98 ms at 50k, and
325.41/328.43 ms at 100k. The 100k incremental/absolute footprint p95 is
8.50/50.05 MiB, raw vectors are 195.31 MiB, and the database is 416.54 MiB.
The package/UI case counts are 679 (13 gated) and 25 per locale; 253 Swift
source files are now linted.

Band 4 slice 4E adds three semantic characterizations: 257 deterministic
production-width vectors must match a scalar exact-ranking oracle; ties, empty
queries, and non-positive limits remain deterministic and safe; and a 501-hit
result crosses bounded SQL materialization chunks without losing rank. Existing
coverage also excludes wrong-width and non-finite vectors, preserves complete
text, and removes tombstoned meetings. The 32nd architecture case now guards
the cursor/zero-copy/Accelerate/bounded-top-k source shape, D83, and both
comparable evidence files. The after matrix records wall/CPU p95 0.51/0.55 ms
at 1k, 9.86/9.95 ms at 10k, 45.18/45.86 ms at 50k, and 90.22/91.26 ms at
100k. The package baseline is 682 tests (13 gated); the source and UI counts
remain 253 and 25 per locale.

Band 4 slice 4F adds one stereo waveform characterization whose three buckets
cross both channels and leave a final remainder. The 32nd architecture case
now guards the privacy-safe copied-scratch CLI, Release configuration, exact
before/after fingerprint, replacement invalidation, Accelerate adapter shape,
resource budgets, and D84's no-cache decision. The real 55.9-minute,
644.19 MB dual-channel CAF matrix records first wall/CPU 109.25/94.81 ms and
repeat p95 70.11/71.33 ms, down from 761.75/767.43 and 747.53/754.79 ms.
Incremental/absolute repeat footprint p95 is 0.33/5.03 MiB. The package
baseline is 683 tests (13 gated); 254 Swift sources are linted and the 25-case
UI contract per locale is unchanged. The focused player case retains a named
app-window screenshot after playback starts so EN/ES band validation also
proves the waveform surface renders without driving the desktop.

Band 4 slice 4G adds three real-Store `SpotlightProjectionTests` and four actor
`SpotlightIndexerTests`. Projection coverage proves newest cross-recipe
summary selection, deterministic first-40 transcript order, tombstone scope,
the 4,000-character cap, and the empty library. Actor coverage proves burst
coalescing, client-state no-op plus legacy cleanup, transient retry, terminal
failure, and recovery after a fresh request. The 32nd architecture case guards
the one-snapshot SQL shape, process ownership, named complete-protected index,
500-item batches, client state, retries, removal of `libraryVersion`, D85, and
the tracked Release report. Exact fingerprints match the legacy result at
1k/10k/100k meetings. At 100k, projection wall/CPU p95 is
425.64/423.58 ms instead of 22,085.35/22,720.40 ms; absolute/incremental
physical-footprint p95 is 141.14/76.03 MiB. A synthetic-only 1,000-item named
index delivery completes in 21.19 ms with complete protection and successful
cleanup. The package baseline is 690 tests (13 gated); 256 Swift sources are
linted and the 25-case UI contract per locale is unchanged.

Band 5 slice 5A adds Core normalization, real v7-to-v8 migration, duplicate
alias/candidate lookup, atomic create/link/rollback, ApplicationKit delegation,
bundle stripping, Refine non-inheritance, Meeting Detail model/effect,
architecture-source, localization, and UI characterizations. The 26th UI case
renames the seeded non-user speaker, explicitly chooses Remember, waits for the
linked accessibility value, and retains the app-window-only
`band-5a-confirmed-person-memory` screenshot in English and Spanish.

Band 5 slice 5B adds backward-compatible Core claims, exact E-tag formatting
and provider parsing, schema-v9 atomic validation and source-revision stamping,
current/stale/unavailable resolution, physical-deletion handling, portable
bundle remapping, and localized source navigation. The 27th UI case selects
the seeded overview source, verifies the exact transcript row and 0:03
playhead, and retains `band-5b-summary-evidence` in both locales. The full gate
is 708 package tests (13 gated), zero
strict-lint violations across 259 Swift source files, and 27 XCUITest cases per
locale (D86/D87).

Band 5 slice 5C adds typed Core validation, schema-v10 migration constraints,
active newest-claim write fencing, replacement and text-erasing clear,
generated-summary rejection, format-v1 bundle conservation/remapping,
privacy/diagnostics isolation, Meeting Detail model effects, catalog coverage,
and a source-level architecture rule. The 28th UI case marks the overview
unsupported, adds a Spanish correction while asserting generated Markdown is
unchanged, retains `band-5c-local-summary-feedback`, and clears the assessment
in both locales. The full gate is 714 package tests (13 gated), zero
strict-lint violations across 262 Swift source files, and 28 XCUITest cases per
locale (D86/D87/D88).

Band 5 slice 5D adds explicit built-in decision-section semantics,
backward-compatible per-bullet provider evidence, exact-shape/tag admission,
translation-coordinate preservation, a canonical Markdown outline, schema-v11
coordinate/revision/live-segment validation and rollback, physical-deletion
handling, format-v1 bundle remapping, diagnostics isolation, and a source-level
architecture rule. The 29th UI case opens the seeded decision tab, selects the
source beneath its exact bullet, verifies the selected transcript row and 0:03
playhead without autoplay, and retains `band-5d-decision-evidence` in both
locales. The full gate is 723 package tests (13 gated), zero strict-lint
violations across 266 Swift source files, and 29 XCUITest cases per locale
(D86–D89).

Band 5 slice 5E adds backward-compatible per-action provider tags, stable
task-keyed Core evidence, schema-v12 one-to-one parents and ordered nullable
links, target/revision/live-segment validation and rollback, completion-state
stability, physical-deletion handling, translation and format-v1 bundle
identity remapping, Companion/diagnostics isolation, and a source-level
architecture rule. The 30th UI case opens the seeded to-do tab, selects the
source beneath its exact checkbox, verifies the selected transcript row and
0:03 playhead without autoplay, and retains
`band-5e-action-item-evidence` in both locales. The full gate is 731 package
tests (13 gated), zero strict-lint violations across 268 Swift source files,
and 30 XCUITest cases per locale (D86–D90).

Band 5 slice 5F adds exact question-segment identity to the Companion request
fingerprint, parses only exact local-RAG citations into answer sources, and
constructs backward-compatible card evidence with independent question and
answer roles. Schema v13 persists one card-keyed parent plus ordered nullable
role links with revision/meeting/target validation, explicit unavailable
counts, clear-on-overwrite semantics, and rollback on a final link failure.
The aggregate remains transactional through Stop, generated replacement,
bundle import/export, scoped observation, and identity remapping; malformed
foreign nested evidence is dropped without losing its card. The 31st UI case
selects the seeded answer source, verifies the exact 0:03 transcript row and
player position without autoplay, and retains
`band-5f-companion-evidence` in both locales. The full gate is 740 package
tests (13 gated), zero strict-lint violations across 270 Swift source files,
and 31 XCUITest cases per locale (D86–D91).

Band 6 slice 6A adds the empty schema-v14 journal migration, 48 transactional
portable-mutation triggers, content-free state constraints, explicit initial
seeding, bounded pending reads, and generation-aware acknowledgement. Focused
tests prove aggregate rollback, unchanged whole-row filtering, device-local
path/embedding/person-link exclusion, typed-evidence-only replacement,
in-flight N/N+1 safety, soft delete/restore, purge-surviving tombstones, and
invalid-input rejection. The source-level ratchet rejects payload fields,
device-local trigger columns, meeting foreign-key deletion, CloudKit imports,
and a revived speculative SyncKit target. The full gate is 750 package tests
(13 gated), zero strict-lint violations across 272 Swift source files, and 31
unchanged XCUITest cases per locale (D92).

Band 6 slice 6B1 adds eight two-store aggregate/codec tests plus one
architecture ratchet. They prove stale generations cannot label newer content;
all live summary/evidence history survives deterministic transport; paths,
canonical people, embeddings, provenance, audio, jobs, receipts, secrets, and
voiceprints stay absent; remote replacement preserves local derivations and
settles trigger noise; live remote work waits behind unsent local work; remote
deletion wins without purge; and invalid relations or immutable identity
rewrites fail before replacement. The full gate is 759 package tests (13
gated), zero strict-lint violations across 275 Swift source files, and 31
unchanged XCUITest cases per locale (D93).

Band 6 slice 6B2A adds five CloudKit record-codec tests plus one architecture
ratchet. They prove encrypted inline payload/digest placement, protected and
backup-excluded CKAsset fallback, deterministic private-zone identity,
matching-record reuse, checksum tamper rejection, strict metadata validation,
and deletion as a saved encrypted tombstone rather than a CKRecord delete. The
source ratchet permits CloudKit only in the IntegrationsKit codec, forbids it in
StorageKit, and rejects a hidden runtime or delete path. The full gate is 765
package tests (13 gated), zero strict-lint violations across 276 Swift source
files, and 31 unchanged XCUITest cases per locale (D94).

Band 6 slice 6B2B adds nine durable-state tests, six coordinator tests, one
mixed-storage codec regression, and one architecture ratchet. They prove
account-scoped explicit consent/seed behavior, account-loss preservation,
exact attempt/retry/restart semantics, per-meeting/source replay cursors,
protected payload corruption rejection, atomic snapshot rollback, independent partial success,
deterministic bounded retry, outgoing stage/send/acknowledgement, authenticated
remote replay, checkpoint-safe fetched deferral, stale-callback protection,
physical-delete metadata-only handling, privacy tombstones, split-persistence
pending reconstruction, failure classification, and a manually driven,
automatic-sync-disabled engine factory.
The source ratchet admits CloudKit only in the dormant IntegrationsKit
codec/state/coordinator/delegate/runtime boundary, keeps StorageKit
CloudKit-free, and proves callbacks do not own domain replay. The full gate is
782 package tests (13 gated), zero strict-lint violations across 284 Swift
source files, and 31 unchanged XCUITest cases per locale (D95).

Band 6 slice 6C1 adds ten lifecycle/journal tests plus one architecture
ratchet. They prove that an unconsented launch performs zero platform calls;
enable and existing-library seed are distinct; temporary account loss retains
consent and attempts; a real switch requires another opt-in; missing capability
or account identity fails closed; status reflects journal, queue, retry, seed,
and typed failures; pause preserves transport work; remove clears only local
transport state; explicit retry preserves the exact payload/generation and
attempt history; and the StorageKit journal observation transitions from
pending to acknowledged. The full gate is 793 package tests (13 gated), zero
strict-lint violations across 286 Swift source files, and 31 unchanged
XCUITest cases per locale (D96).

Band 6 slice 6C2 adds five pure signed-capability tests, nine process-model
tests, one architecture/release ratchet, and one XCUITest Settings flow. They
prove the platform is inert until lifecycle consent, requires the exact named
container/CloudKit/environment/push/profile evidence, checks the account before
identity, uses the private database, and drives bounded manual send/fetch/send.
The process model performs no observer/APNs work in local-only state, arms and
disarms content-free wakeups with consent, coalesces journal bursts, responds to
account and silent-push wakes, preserves explicit user actions FIFO during
reentrant work, and proves an inapplicable queued sync cannot strand later
work. Release sources separate unrestricted local/test entitlements
from exact production capabilities and reject a missing, expired, or mismatched
Developer ID profile before notarization and after extraction. The Settings UI
keeps Enable and existing-library seed separate and exposes manual sync, pause,
and remove in both locales. The full gate is 808 package tests (13 gated), zero
strict-lint violations across 290 Swift source files, and 32 XCUITest cases per
locale (D97). Real production-account/two-Mac convergence remains field
evidence, not a substituted unit-test claim.

Band 6 slice 6C3 adds three database-free `MenuBarModel` cases, one real
StorageKit observation case, and one architecture ratchet. They prove that
recent meetings stay bounded to three, newest-first, and live-rooted through
delete/restore; pending counts and meetings combine behind storage-independent
updates; empty, degraded, and failed state are distinct; and a failed section
preserves the last healthy snapshot. The source ratchet forbids Store,
StorageKit, IntegrationsKit, and `CalendarAttendeeSource` reach-through from
`MenuBarView`. The full gate is 813 package tests (13 gated), zero strict-lint
violations across 294 Swift source files, and 32 unchanged XCUITest cases per
locale (D98). The menu-bar-extra window itself remains outside the deterministic
app-window XCUITest surface; package/model/observation coverage is the scoped
evidence for this behavior-neutral view refactor.

Band 6 slice 6C4 adds six application-workflow cases, one real StorageKit
snapshot case, two real filesystem-adapter cases, two process-model cases, one
architecture ratchet, and one XCUITest Settings export per locale. They prove
portable canonical collision keys and reserved-name fallbacks, existing and
late collision retry, typed source/document/publication partial results, stable
fatal boundaries, one newest-first live database snapshot, corrupt-aggregate
isolation, released General-summary selection, atomic non-replacing publication,
temporary-file cleanup, process-scoped progress, and readable Spanish seed
content in the resulting Markdown. The full gate is 825 package tests (13
gated), zero strict-lint violations across 298 Swift source files, and 33
XCUITest cases per locale (D99).

Band 6 slice 6C5 adds five application-workflow cases, three presentation-model
cases, one architecture ratchet, and two real-app XCUITest flows per locale.
They prove shared trimming/search/evidence/answer behavior, evidence-preserving
ordinary generation failure, honest cancellation, no-evidence short circuit,
stale palette search/answer rejection across close/reopen, Markdown receipts,
reliable key-panel input, instant temporary-store FTS, and exact three-second
citation navigation from both full Ask and the resident panel. The full gate is
834 package tests (13 gated), zero strict-lint violations across 302 Swift
source files, and 35 XCUITest cases per locale (D100).

Band 6 slice 6C6 adds first-run, exact local-receipt, meeting-preparation,
storage-projection, process-owner, architecture, localization, and two real-app
XCUITest cases per locale. They prove one transferable welcome decision,
model-independent launch, unavailable-versus-zero metrics, bounded live counts,
allocated audio and encrypted-voice counts, shared Ask evidence, one batched
current-General-summary projection, independent commitments, source-indexed
synthesis, agenda-route isolation, and honest local-first privacy wording. The
full gate is 856 package tests (13 gated), zero strict-lint violations across
311 Swift source files, and 37 XCUITest cases per locale (D101).

Band 6 slice 6C7's first unit adds three architecture ratchets, two pure
meeting-query cases, one async secret-workflow case, and one real StorageKit
snapshot case. They prove Core has no platform import, PlatformKit is Core-only
and owns Keychain/microphone authorization, app and CLI alone construct the
Keychain adapter, onboarding delegates permissions, invalid query input never
reaches storage, bounded live roots exclude tombstones, and one meeting detail
read returns the latest live General summary. A disposable process smoke also
preserves CLI usage/list/search/Ask output and MCP initialize/tools-list JSON-RPC.
The full gate is 863 package tests (13 gated) and zero strict-lint violations
across 318 Swift source files; the behavior-neutral app refactor retains the 37
XCUITest cases per locale (D102).

Band 6 slice 6C7's second unit adds fifteen focused workflow cases, three
persisted-refine orchestration cases, and one product-command dependency ratchet.
They prove unreadable-file short circuiting, exact engine/language/vocabulary/
threshold forwarding, stable timing, optional attribution, meeting-before-
provider persistence, voice operation isolation, catalog-order model
verification and sequential installation, coherent Markdown/PDF/Gist export,
pending-only owner-resolved action publication, post-admission credential
preparation with no Keychain work for missing/empty outcomes,
and external-audio refine load/draft/atomic-apply order. The architecture rule
requires each adopted product command to import ApplicationKit and rejects
direct capability, Store, model, or filesystem construction in command source.
The full gate is 882 package tests (13 gated) and zero strict-lint violations
across 322 Swift source files; the behavior-neutral app composition changes
retain the 37 XCUITest cases per locale (D103).

The post-capture application-boundary unit adds eight focused durable-workflow
cases and one architecture ratchet. They prove mixed-language first-pass
cleanup and attribution, exact dependent-job admission, a real StorageKit
diarization-to-summary provenance chain, unavailable-provider retry,
optional-summary exhaustion, superseded-input cancellation, publication lease
loss, typed diagnostic issues, and injected-clock scheduling without polling.
The source rule requires the process supervisor to enter
`ProcessPostCaptureJobs`, rejects direct durable-job policy in the coordinator,
and keeps concrete files, models, preferences, Shortcuts, and telemetry in the
app adapter. The full gate is 891 package tests (13 gated) and zero strict-lint
violations across 325 Swift source files; the behavior-preserving composition
change retains the 37 XCUITest cases per locale (D104).

Local: `swift test` (if it fails with "no such module": `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — xcode-select points to CommandLineTools). XCTest, not Swift Testing (D13).

## UI tests — `Tests/PortavozUITests/` (`make test-ui`, D30)

Disposable launches isolate auxiliary sensitive state as well as SQLite:
Settings and Meeting Detail never inspect the host participant-voice gallery
or its Keychain key while `-use-temp-store` is active.

XCUITest against the real app (XcodeGen generates the `.xcodeproj`, which is gitignored). `make test-ui` performs a preflight: it closes a previous Portavoz instance and warns if Gancho is running, because macOS XCUITest can fail before running tests with `Timed out while enabling automation mode` or interrupting windows. It verifies the UI through automation instead of driving the screen. The harness treats `-portavoz-open-settings` only as a runner-side hint, removes it before launch, and opens the real production Settings scene with `⌘,`; no test-only sheet or app-owned window lifecycle can leak into the following case. Every relaunch first observes the prior process terminate, crosses a bounded LaunchServices retirement delay, and receives a UUID-scoped `TMPDIR` so AppKit saved state cannot race another case. Launch args: `-NSTreatUnknownArgumentsAsOpen NO`, `-ApplePersistenceIgnoreState YES`, `-use-temp-store` (disposable DB; Settings does not touch the real Keychain or CloudKit/APNs and completion does not invoke host Shortcuts), `-seed-demo` (deterministic meeting with transcript, summary, typed overview, decision, action-item, and role-separated Companion sources, coauthorship bullet "▸", action item, audio, and a content-free remote-attempt receipt), `-seed-latest-recipe` (adds a newer Standup snapshot to prove D45 reload selection), `-seed-recovery` (a staging-only recovery fixture, allowed only with the temp store), `-seed-processing` (a model/audio/Keychain-free durable-processing fixture, also temp-store-only), `-seed-processing-failure` (converts the disposable seed's first job into an exhausted failure), `-seed-refine-running` (a model-free cancellable refine fixture, temp-store-only), `-seed-just-recorded` (marks only the disposable seed as freshly captured so the opted-in mirror can be verified), `-seed-without-summary` (omits only the disposable summary), `-seed-scale` plus optional `-scale-auto-summary-update` (a temp-store-only 5k-detail fixture), `-simulate-sequoia-capabilities` (forces the app-owned Foundation Models capability unavailable), and `-simulate-recording-start-failure` (injects one typed preparation failure and is legal only with the temp store). The runner-only Settings hint is never visible to the app process; after the main window is ready, the harness invokes the production `⌘,` command and waits for the real Settings category control. Every launch receives a unique `PORTAVOZ_AUDIO_ROOT`; tests that exercise copied real audio may explicitly override it with `PORTAVOZ_TEST_AUDIO_ROOT`. The diagnostics case additionally supplies a unique `PORTAVOZ_UI_TEST_DIAGNOSTICS_PATH`, and the backup case a unique `PORTAVOZ_UI_TEST_BACKUP_FOLDER`; production launches ignore both overrides. The throwaway main window also uses a deterministic visible frame with left clearance so agent progress panels and similar desktop overlays cannot intercept sidebar controls; production window placement remains unchanged. The seed synthesizes a two-tone clip (mic/system) or adopts only that scratch copy. Covers 37 cases in `LibraryUITests`, `InsightsUITests`, `OnboardingUITests`, `MeetingDetailUITests`, and `SettingsUITests`: library and grouping, source-grounded upcoming-meeting preparation, exact local-data receipts, full Ask and command-palette answer/citation paths, interrupted staging recovery to a playable detail, durable processing resume/retry, typed recording-start failure/retry/reference, heatmap/interlocutors, first listen, 5k-detail rendering plus scoped summary update, overview, decision, action-item, and Companion source-to-transcript/audio navigation, explicit correction/unsupported/clear review, summary/transcript/player/rail/privacy receipt/clip plus scoped action-item mutation, explicit confirmed-person memory, newest-recipe reload, refine cancellation, the post-meeting mirror sheet, Sequoia intelligence recovery, Settings navigation, explicit iCloud sync opt-in/existing-library separation, redacted support export, readable whole-library Markdown backup, independent transcript/summary language controls, custom structures, audio capture, mirror opt-in, and live locale. The palette screenshot targets its identified `NSPanel`; every other retained attachment targets an app window. The scaled detail, Ask surfaces, Meeting Detail claim review and overview/decision/action-item/Companion source/player, rail/player waveform, confirmed-person memory, grouped Library, Insights heatmap, post-meeting mirror, Sequoia capability, diagnostics, recovery, and recording-failure cases keep named app-only `XCTAttachment` screenshots, including `band-5d-decision-evidence`, `band-5e-action-item-evidence`, `band-5f-companion-evidence`, `band-6c-cloud-sync`, `band-6c4-markdown-backup`, `band-6c5-full-ask-answer`, `band-6c5-command-palette-answer`, `meeting-preparation-brief`, `durable-post-capture-recovery`, and `local-data-ledger`, so feature-band runs can export and inspect deterministic visual evidence without screen driving or exposing unrelated desktop content. `make test-ui-en` and `make test-ui-es` use Xcode's `-testLanguage`/`-testRegion` contract; a shell environment variable alone is not accepted as localization evidence. Export itself (`AudioClipExporter`) is tested as a unit test — a 15 s clip from a 30 s source exports to m4a in a fraction of a second (comfortably below the < 2 s M11 criterion).

## Measurement harnesses

- `bench-m2`: live transcript lag (p50/p95/max) with concurrent batch processing.
- `portavoz-cli der`: DER against reference RTTM (public fixture: pyannote sample.wav/rttm).
- `scripts/verify_drift.py`: drift through envelope correlation (±5 s, edge warning, multi-point).
- `scripts/run-sandbox-capability-spike.sh`: signed sandbox/control capability matrix with full private tap-graph setup and tracked JSON evidence.
- `scripts/run-scale-baseline.sh`: Release production-schema library/detail matrix with disposable databases.
- `scripts/run-detail-ui-baseline.sh`: Portavoz Dev-only 5k-detail signpost, Hangs, Time Profiler, and SwiftUI trace with a disposable store.
- `portavoz-cli bench-waveform`: Release first/repeat wall, process CPU, physical-footprint, exact-result, and replacement-invalidation evidence over source audio copied to scratch.
- `scripts/run-spotlight-scale-baseline.sh`: isolated Release legacy/snapshot projection matrix at 1k/10k/100k meetings, exact fingerprint comparison, and optional synthetic-only protected-index delivery/cleanup.

## Measured numbers (MacBook Pro M4 Max 36 GB, macOS 26, Jul 2026)

| Metric | Target | Measured |
|---|---|---|
| Live transcript lag | < 2 s | **p50 0.24 / p95 0.53 / max 0.56 s** |
| Batch Parakeet | — | ~100x real time (18 passes without degrading live processing) |
| Refine Whisper (22 real min) | > 15x | **23–42x** (1314 s in 31–56 s) |
| Mic/system drift | < 50 ms / 30 min | **4 ms / 22 min** (+4 ppm linear) |
| DER (AMI 2 speakers) | < 15% | **7.6%** (collar 0.25 s) |
| ES summary of EN meeting | < 30 s | **3.8 s** (glossary intact) |
| AEC convergence | — | **~2 s** (hence the warm-up) |
| Cold start | < 1.5 s | **0.94 s cold / ~0.26 s warm** (`--bench-startup`) |
| FTS at 1k meetings (80k segments) | < 50 ms | **p50 22.8 ms / p95 23.9 ms** (`portavoz-cli bench-fts`) |
| Exact FTS at 100k segments | p95 < 50 ms | **p50 30.25 ms / p95 30.99 ms** (`bench-scale`, D81) |
| Lexical Ask at 100k segments | p95 < 100 ms | **p50 66.45 ms / p95 66.89 ms**, down from 111.19 ms through bounded per-term RRF (D81) |
| Semantic cosine at 100k × 512 dimensions | p95 < 100 ms | ✅ **wall p50/p95 88.81/90.22 ms; CPU p50/p95 89.93/91.26 ms**, down from 307.05/325.41 and 311.46/328.43 ms; **8.42 MiB** incremental footprint p95 (D83) |
| Waveform, 55.9-minute dual channel / 600 buckets | first wall < 150 ms; repeat wall/CPU p95 < 100 ms | ✅ first wall/CPU **109.25/94.81 ms**; repeat wall/CPU p50 **69.22/70.10 ms**, p95 **70.11/71.33 ms**, down from 747.53/754.79 ms; **0.33 MiB** incremental footprint p95; exact fingerprint preserved and replacement changes it (D84) |
| Spotlight projection, 100k meetings | wall/CPU p95 < 500 ms; absolute/incremental footprint < 160/96 MiB | ✅ wall/CPU p95 **425.64/423.58 ms**, down from 22,085.35/22,720.40 ms; **141.14/76.03 MiB** absolute/incremental footprint p95; exact fingerprint preserved. Synthetic 1k protected named-index delivery: **21.19 ms**, cleanup succeeded (D85) |
| Detail core read, 2 h / 5k segments | diagnostic | **p50 16.31 ms / p95 17.22 ms** |
| Detail first content, 2 h / 5k segments | p95 < 300 ms | **91.87 ms** single signpost run, down from 522.30 ms; **zero hangs**, down from one 515.86 ms hang (D80) |
| Meeting health, 2 h / 5k → 8 h / 20k | derived-policy diagnostic | **p95 9.94 ms → 41.39 ms**, down from 347.58 ms → 5,385.76 ms |
| RAM by phase (`--bench-record 60 --bench-log <file>`, via `open -n`) | < 800 MB peak while recording / < 200 MB idle post-meeting | **20 MB without models → ~515 MB engines loaded → 569–795 MB peak while recording (LIVE diarization included) → 140–160 MB after the meeting**. The original target (500 MB) was set before adding live diarization; revised Jul 2026 |
| Embedded summary RAM (MLX) | transient, not resident | **~2.4 GB during generation**; `MLXModelCache` releases it only after 120 s idle (previously it remained resident forever) |

## Real bugs found and fixed (what an agent must know)

| Bug | Root cause | Fix |
|---|---|---|
| Meeting collapsed from 66→3 segments during refine | WhisperKit `concurrentWorkerCount` default 16 → race on shared decoder; its chunker SWALLOWS per-chunk errors | `concurrentWorkerCount: 1` + coverage retry |
| Deterministic collapse with vocabulary | promptTokens derail windows that do not mention the terms; raw coverage was misleading (valid spans, empty text) | coverage over CLEAN segments + retry without prompt + natural-language phrase |
| Silent meeting "sin voz" | WhisperKit EnergyVAD absolute threshold 0.02 | prior peak normalization |
| Repeated `Yo: .` and `Me: Thank you.` without speaking | Loose-punctuation deltas and Whisper silence boilerplate at VAD cadence | lexical hygiene + repeated-boilerplate filter on mic |
| Mic died when headphones connected (min 24/30) | AVAudioEngine stops on config-change, silent stream | restart + resample + silence gap |
| Phantom "Yo" with speakers | mic captured system audio (100% echo; text-only dedup covered only 57%) | AEC VPIO by default (D24) |
| False drift of 115 ms | real offset 2.4 s outside the script's ±2 s range | ±5 s range + edge warning |
| Speaker rename was not saved | alert-dismiss nilled the state before the Task | capture values on tap |
| "Sugerir nombres" overflowed context | blind prefix + schema + assistants > 4096 tokens | targeted NamingExcerpt + retry at half size |
| Speakers merged (AMI) | internal threshold ×1.2 (0.7→0.84) | 0.45 calibrated against real RTTM |
| 11 speakers where there were 4 | fragmentation from remote codecs; threshold cannot be raised (0.50 breaks AMI) | mergeMicroClusters < 15 s |

## Audio fixtures for testing

`say -o x.aiff` + `afconvert -f WAVE -d LEI16@16000 -c 1` generates synthetic voice; `afplay` through speakers into the mic creates a real acoustic E2E loop. **Never calibrate diarization with TTS** (spec 03). Python from python.org lacks SSL certificates — use `curl` in scripts.

## How to measure before making claims (rule)

No number enters a spec without a reproducible harness. If a claim comes from a third party (Apple benchmark, Argmax WER), cite the source and mark it "not measured here."

## Known flakes

**Environment flake — automation mode (Jul 2026):** `make test-ui` fails with
"Timed out while enabling automation mode" (0 tests run) when ANOTHER
automation/accessibility session is active on the machine — observed with
an agent's computer-use session: 3 consecutive attempts failed during init,
and the same code passed 7/7 in a cycle without that session. This is not a
code failure: run the UITests without concurrent automation clients.
