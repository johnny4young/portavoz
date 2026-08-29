# Spec 08 — Quality: tests, harnesses, and measured numbers

Status: the package inventory contains 2,788 cases (15 environment-gated) + 101
XCUITest UI cases. Supported AppKit-capable CI and release hosts require zero
failures; a non-windowed shell run is not release evidence for AppKit and
AVFoundation integration cases. CI
on GitHub Actions
(`.github/workflows/ci.yml`: macos-latest build/test, an explicit macos-15
Sequoia build/test lane, **SwiftLint `--strict`**, and a fast repository-hygiene
gate). `.github/workflows/ui-tests.yml` computes feature-level selectors from
the PR diff and allocates a macOS UI runner only when product presentation is
affected. The recording-toolbar mapping selects its external-route geometry
contract plus live-control/recovery cases rather than unrelated Library and
Meeting Detail tests. The English and Spanish release gates each cover all 101
cases and retain app-only
local-voice Settings/Onboarding, shared local-provider recommendations,
application-owned Settings device resources and Meeting Detail audio,
revision-fenced Meeting Detail metadata and explicit name suggestions, claim
review, overview/decision/action-item/Apuntador source navigation, confirmed-
person memory, 5k/20k-segment scale detail, full Ask and command-palette
answer/citation navigation, source-grounded meeting preparation, durable Skills
policy failure, status-scoped control-center, causal receipt-inspection, and
scope-failure isolation journeys, exact local-
data receipts, correction-stale Summary/Apuntador evidence and explicit
regeneration, Library/search, Insights, post-meeting mirror, proactive Whisper
Settings, Sequoia intelligence setup, explicit correction-aware Apuntador
refresh and unsupported-Sequoia preservation, private-sync opt-in/older-
library separation, whole-library Markdown backup, privacy receipt, redacted
support, durable post-capture recovery, processing recovery, and typed
recording-failure screenshots; earlier automation-mode harness failures remain
documented below.

**SwiftLint (`.swiftlint.yml`, `strict: true`)**: industry-recommended config
(default rules + correctness/clarity opt-ins, industry thresholds: line 120,
function-body 60/100, cyclomatic 12/20, type-body 400/600). CI treats every
violation as a failure. The Aug 12 acceptance run is clean across all **675
production Swift files**. The 20 violations found by the Aug 8 audit were
removed through cohesive Meeting Detail, graph, decision-query, processing,
correction, job, Skills-storage, and search owner splits rather than blanket
suppressions. Existing inherent exceptions remain suppressed inline with their
local justification.

## Test suite — `Tests/PortavozTests/`

| File | Coverage |
|---|---|
| StorageUpgradeTests | Disposable clean-install and exact v0.6.0 (`v1`–`v5`) file-library upgrade to the latest schema; every supported v1-v18 starting schema reaches typed empty v19 correction storage; bilingual transcript/cast, summary/action, note, Apuntador, and relative-audio-reference conservation; migration order, integrity, foreign keys, no implicit sync seed, and idempotent reopen |
| RestructureMeetingTranscriptTests / MeetingTranscriptContentTests / TranscriptCorrectionCompositionTests / TranscriptCorrectionRevisionTests / MeetingTranscriptGenerationMaterialTests / TranscriptCorrectionStorageTests / TranscriptCorrectionReplicaMergeTests | Exact accepted-snapshot structural commands; explicit adjacent same-speaker/channel/time-monotonic merges; complete split partitions; collision-safe generated and historical part identities; recoverable suppression; restore that releases active ownership without erasing lineage; precomputed 20k-row editor projection; timestamp-aware bidirectional split-source navigation and export-to-original-audio seeking; deterministic typed replace/speaker/split/merge/suppress/restore composition; convergent effective correction revisions and disjoint replica-lane union; immutable rewrite, divergent tombstone, competing-lane, wrong-meeting, stale, overlapping, branched, malformed, and tombstoned-terminal rejection; fail-closed artifact and document provenance; generated-to-accepted evidence projection; strict portable-envelope decoding; idempotent atomic append; source retirement; schema immutability; monotonic semantic-maintenance invalidation; accepted-only search/index exclusion and restore; summary publication fences; one journal generation per logical correction; injected semantic-generation failure proving atomic rollback; and three-device replica convergence |
| TranscriptCorrectionQualityTests / TranscriptCorrectionScaleBenchmarkTests | Sixty-four seeded permutations of replace/speaker/split/merge/suppress/restore history; stable composed readings independent of arrival order; explicit refined Spanish/English source language, source identity, and lineage preservation; deterministic dense 8,000-segment/4,000-correction output with complete content equality across permutations; content-free isolated 20,000-segment/400-correction Release measurement; and a 250 ms p95 pure-composition budget over twenty candidate runs |
| CommitmentRadarQueryTests / CommitmentRadarStorageTests / CommitmentRadarScaleBenchmarkTests | Injected seven-day calendar boundaries; strict root/related-row limits; exact self/person/unassigned ownership plus urgency/activity filters; oldest source and newest history bounds with visible totals; source-meeting navigation; projection/history corruption rejection; an at-most-four-SELECT snapshot read independent of root count; and a content-free 1,000/10,000-confirmed-commitment Release gate with a 100 ms p95 budget |
| CommitmentFieldQualityTests | Content-free rolling 90-day cohort evaluation bounded to 50,000 observations; explicit pending/deferred/withdrawn versus terminal-review denominators; dismissal-based field false-positive proxy; exact opaque-owner and millisecond due-date precision; generated-evidence, user-note, manual-origin, and intentionally missing confirmation coverage; nearest-rank confirmation-latency p50/p95; English/Spanish/mixed/other-or-unknown breakdowns; and duplicate, out-of-window, inconsistent, and empty-cohort failure semantics over the canonical 12-observation public synthetic fixture |
| CommitmentFieldQualityStorageTests | Schema-v24 content-free and immutable first-presentation evidence; no foreign-key erasure on source retirement; idempotent replay; exact canonical-owner token capture; mixed-language classification; immutable first-confirmation owner/date truth after later edits; and distinct dismissed/deferred/withdrawn current rolling assembly |
| CommitmentFieldQualityApplicationTests | One sampled rolling-window endpoint and aggregate-only scorecard composition; ApplicationKit-owned observation identity/time; and exact repository forwarding without exposing content to presentation |
| CommitmentRadarModelTests | Complete, empty, and failed presentation phases; exact owner/due/activity mapping; grouping without storage reload; stale-load rejection; retry after failure; independent Quality loading; first-successful card-presentation suppression; pre-mutation observation retry; nonblocking instrumentation failure; and database-free adapter behavior |
| CommitmentReminderModelTests | Launch authorization inspection without prompting; explicit opt-in before reconciliation; denied-state inactivity; one-active-plus-one-rerun burst coalescing; and explicit retry after a typed failure |
| CommitmentLinkObservationTests / CommitmentSourceLinkArchitectureTests | Exact open-target source/evidence projection; closed and invalid-limit exclusion; installed-assets-only semantic borrowing; existing semantic-port use; separation of semantic relevance from wrong-owner admission; typed unavailable/malformed rejection; fixed 200/20/three bounds; and absence of mutation or app composition |
| TopicContinuityTests / TopicContinuityHardeningTests | Thirteen focused cases covering deterministic alias normalization; real v24→v25 migration; inert generated proposals and explicit ApplicationKit confirmation; ambiguous and bilingual aliases; generated-candidate score/profile retention and target fencing; exact revision/correction-derived evidence freshness; correction-safe idempotent replay; source-chronological family reads; append-only merge/split identity history with active-root resolution; cross-topic foreign-key integrity and immutability triggers; and atomic rejection of invalid evidence or identity reuse |
| DecisionContinuityTests / DecisionContinuityHardeningTests | Fifteen focused cases covering a real v25→v26 migration; inert generated observations; explicit initial and multimeeting source confirmation; exact rendered wording and ordered segment evidence; submillisecond-safe confirmation time; strict source chronology with exact old-request replay; supersede/reverse terminal history; correction rejection; correction-safe exact retries; identity reuse rejection; source-purge availability; invalid relationship rejection; event replay; and schema-level source ownership, identity immutability, projection-transition, and foreign-source guards |
| ArchitectureDependencyTests | SwiftPM/XcodeGen dependency ratchets, no capability reverse dependencies, approved application imports, workflow bypass prevention including ApplicationKit-owned durable post-capture, speaker naming, Meeting Detail metadata and Meeting Detail audio coordination, an explicit route-owned Meeting Detail scene/model boundary with a Foundation-only presentation formatter and no `AppServices` in the child view, a platform-free and OSLog-free Core, Core-only PlatformKit, composition-root-only Keychain construction, onboarding permission adapters, bounded ApplicationKit CLI/MCP library reads, product-command ApplicationKit entry with presentation-only command sources, audio/model/release/privacy boundaries, scoped feature ownership including first-run/local-receipt/meeting-preparation owners, explicit canonical-people, typed overview/decision/action-item/Apuntador evidence, private-feedback boundaries, typed immutable transcript-correction history with strict migration/envelope/sync-v2 ratchets, the content-free generation-fenced sync journal, CloudKit ownership limited to the IntegrationsKit codec/state/coordinator/delegate/runtime/platform boundary with domain replay still in StorageKit, a CloudKit-free lifecycle policy outside views, one inert consent-gated container owner, capture-gated bounded existing-library seed composition over the Core maintenance boundary, exact local/Developer-ID entitlement and profile gates, one shared Ask workflow with presentation/CLI/MCP/brief bypass prevention, architecture-document vocabulary rules, no speculative SyncKit bypass, content-free resource-workload descriptors outside audio callbacks, one process residency ledger with complete pinned Whisper, MLX, live-speech, diarization, and semantic-embedding load/use/release adapters plus one pressure-to-policy bridge that dispatches only through concrete owners, one process-shared bounded semantic-index flight and one no-poll signal-driven background owner in both reliability gates, capture-aware Whisper/MLX preparation/publication checks and atomic load-ticket admission, absence of model lifecycle/release operations from AudioCaptureKit callbacks, one persisted-level PCM scan plus a generation-fenced latest-value presentation relay, one signal-driven live-translation wake relay with a one-wake buffer and eight-row framework batches in both reliability gates, one recording-scoped live-summary coordinator with row/character budgets and atomic lifecycle-fenced publication, policy-owned 150-row live-paragraph and 1,024-row talk-balance bounds, local diagnostics/signpost redaction including path/checksum-free audio and aggregate-only transcript evidence, and measured scale source/evidence gates |
| CLIArgumentValueTests | Missing, empty, next-option, malformed, negative, zero, oversized, non-finite, and out-of-range legacy CLI value rejection; index non-consumption on a missing value; and overflow-safe 1,000,000-segment FTS corpus admission |
| MeetingDetailPresentationTests | Locale/time-zone-injected meeting dates, bounded duration and segment facts, negative-time clamping, and padded/unpadded transcript clocks without storage or capability access |
| MeetingSyncStateTests | Empty v13→v14 migration, transactional rollback, portable versus device-local mutation filtering, typed-evidence-only replacement, in-flight N/N+1 acknowledgement, bounded live/deleted initial seed with durable cursor progression and idempotent crash-window replay, delete/restore/purge tombstone behavior, and fail-closed limits/acknowledgements |
| MeetingSyncAggregateTests | Exact-current-generation envelope, deterministic format-v2 codec with canonically ordered correction history, legacy format-v1 local-correction preservation, idempotent full-history replay, matching-base disjoint correction union, competing-lane and accepted-base rejection without partial writes, invalid remote-target and storage-failure propagation without misclassification, correction-tombstone convergence and immutable-collision rejection, millisecond-tied summary-version ordering, device-local path/person/embedding preservation, trigger-echo suppression, deferred live/live local-pending conflict, recoverable privacy-dominant remote deletion, invalid-relation rollback, and immutable summary-root/child collision rejection |
| CloudMeetingRecordCodecTests | Encrypted inline payload/digest placement, capability-probed private CKAsset fallback, exact `EINVAL`/`ENOTSUP` metadata downgrade classification, private-zone deterministic identity, matching-record reuse, checksum tamper rejection, strict format/type validation, and deletion as a saved tombstone envelope |
| CloudMeetingSyncStateTests | Content-free snapshot validation, account-scoped consent and explicit seed request/cursor/prepared/completion state across restart, duplicate-request idempotency, account loss/switch semantics, exact-generation attempts, bounded retries, capability-aware private payload integrity, replay cursors, correction-conflict outgoing fences, backward-compatible deferred replay decoding, restart cleanup, and atomic persistence rollback |
| CloudKitMeetingSyncPlatformTests | Exact signed container/service/environment/push/profile admission, supported development signing values, and fail-closed missing or invalid restricted capabilities without creating a container |
| MeetingSyncModelTests | Zero-observer local-only launch, explicit enable wakeup arming, journal burst coalescing, account-loss disarm, pause, silent-push/manual-cycle parity, capture-completion wake limited to an explicitly requested seed, FIFO preservation during suspended lifecycle work, continued draining after an earlier action makes a queued sync inapplicable, and automatic-versus-explicit workload classification |
| CloudMeetingSyncCoordinatorTests | Request-versus-preparation separation, bounded initial-seed cursor/prepared/completion transitions, independent partial outcomes, authenticated fetched replay and durable deferral, exact remote correction-payload retention, outgoing conflict fences across relaunch/retry/late-save callbacks, duplicate blocked-correction delivery before and after state-store relaunch without duplicate replay or attempts, compatible local restore and replay-fence release, physical-delete metadata handling, server-tombstone settlement, split-persistence reconstruction, and stale N/N+1 save re-admission |
| CloudMeetingSyncLifecycleTests | Zero-platform local-only launch, explicit enable/seed separation, capture-gate pause before storage, pause after one committed seed batch, signal-driven cursor resume, account loss and account-switch consent behavior, typed capability and identity failure, truthful retry/pause/remove-device semantics, exact-attempt readmission, and observable journal pending/acknowledged transitions |
| LibraryModelTests | Complete/empty/degraded/failed Library snapshots, reload-version and search-query fences, trimmed/debounced FTS phases, rename/action/delete/restore/purge effects, degradable mutation diagnostics, import progress/success/failure, calendar access, and on-demand brief state through a database-free client fake |
| FirstRunExperienceTests / PresentationReadModelTests | Forced/disposable/completed/existing-library welcome decisions, no unnecessary Store reads, retryable cancellation, one process-wide resolution, one restored-window presentation host, durable completion, and exact/partial local-receipt model state |
| FirstListenControllerTests / SpeechAnalyzerLifetimeTests | Caption readiness before microphone start; available/unavailable completion; cancellation during preparation without capture; cancellation-aware caption wait; exactly-once normal/cancelled microphone teardown; internal cancellation recovery; partial-sample disposal versus completed-sample reuse; stale-phase fencing; structured SpeechAnalyzer feeder cancellation/drain on normal result completion, error, and parent cancellation; and coalesced cleanup completion without installed speech assets or a real device |
| LocalDataLedgerTests / PresentationReadStorageTests | Concurrent exact meeting/audio/voice metrics, per-source unavailable-versus-zero behavior, cancellation, live-root counting, and one batched latest-live-General-summary projection with tombstone, recipe, superseded-version, and duplicate-ID filtering |
| PrepareMeetingBriefTests | Shared Ask evidence ranking, batched current-summary admission, related-only bounded commitments, source-indexed navigable synthesis, weak/missing evidence, independent failure degradation, and cancellation propagation |
| SkillsControlCenterTests | Capability-derived catalogue disclosure, durable pause and per-Skill policy, independently typed policy/receipt read failures plus receipt cancellation, bounded Recent/Waiting/Attention/Completed receipts over exact v39 unfiltered and v42 exact-Skill index plans without a temporary sort, exact filter composition/order/limits, one-row continuation probing with sentinel trimming and fail-closed `hasMoreReceipts`, pre-read rejection of unknown catalogue filters, malformed storage-filter rejection, future unknown-state attention, malformed identity and policy rejection, one read-consistent receipt audit, strict retry-state replay, unknown failure-category rejection, predecessor/tail integrity, a 256-event materialization ceiling enforced with a 257-row probe, D341 recovery classification/routing that remains inert for local subjects and verification-only for external outcomes, D369 exact policy-read laziness that preserves audit-only evidence while local recovery fails closed, and D370 read-only Settings recovery after an unverified control mutation |
| SkillActivityPresentationStateTests | Matching- and mismatched-scope/filter loading, same-selection stale-row suppression, receipt-only unavailability, mutually exclusive verified empty/receipt presentation, explicit refresh only for verified empty/receipt states, verified continuation rather than visible-count inference, the bounded 20-to-50 history-window transition, and selection reset |
| SkillProposalPresentationStateTests | Initial loading and unavailable retry isolation, verified empty/populated explicit refresh eligibility, retained verified projection during an in-flight refresh, and failable bounded one-based accessibility positions |
| SkillOfferAuthorityTests / SkillExecutionStoreTests | Content-free v40 review authority, bounded reconciliation and newest-first plan, opaque review-UUID dismissal, expired/repeated unavailable outcomes, tombstone-wins stale reconciliation, exact one-shot and reusable-offer claim relationships, claim-time dismissal fencing, byte-preserving opaque EventKit execution identity, and v41 exact execution-subject/failure-category persistence with cascade cleanup and no legacy subject inference |
| MeetingLibraryQueryTests / ManageSecretsTests | Empty and invalid request short circuits, normalized bounded list/search/open-item delegation, and async secret round-trip/delete behavior over deterministic injected ports |
| AnalyzeAudioFileUseCaseTests / ManageLocalVoiceAndModelsUseCaseTests / PublishMeetingContentUseCaseTests | File admission and policy forwarding; deterministic transcription metrics; diarization threshold/timing/optional attribution; meeting-before-provider summary persistence; file, supplied-sample, and recorded local-voice enrollment with duration/sample validation, ordered progress, status/delete isolation, and capture-mode forwarding; catalog-order verification and sequential model installation; coherent Markdown/PDF/SRT/WebVTT/Gist export, canonical format/extension parsing, subtitle rendering without a Markdown prerequisite, pending-only owner-resolved action publication, typed missing/empty states, and zero concrete model, Keychain, filesystem, or network dependency |
| MenuBarModelTests / MenuBarObservationTests | Storage-independent recent/pending composition, empty/degraded/failed phases, last-healthy-section preservation, and bounded newest-first live meeting roots through delete/restore |
| ExportLibraryMarkdownBackupUseCaseTests / BackupPublicationReconcileTests / RecoverLibraryMarkdownBackupTests / LibraryMarkdownBackupRecoveryStoreTests / LibraryMarkdownBackupStoreTests / LibraryMarkdownBackupFilesTests / LibraryMarkdownBackupModelTests | Portable canonical filename allocation, existing/concurrent collision retries, typed partial and fatal outcomes, bounded page-copy suspension with partial-stage cleanup, one immutable newest-first SQLite stage with corrupt-aggregate isolation and General-summary parity, one-at-a-time aggregate delivery, process-local suspension/resume without rerender or republish, atomic non-replacing file publication, cursor-bound reservations, no-follow exact-byte destination evidence, missing/matching/conflicting and cursor-less reconciliation, cancellation and destination-failure lease closure, publication-before-source-checkpoint ordering, idempotent and monotonic cursor persistence, checkpoint-only retry without destination inspection or republish, failure-frozen cursor advancement, catalog-before-cleanup stage preservation, ambiguous/conflicting launch fail-closed behavior, exact active continuation and completed-result reconstruction, retryable adopted-stage abandon after destination setup failure, terminal recovered-source cleanup without an implicit fresh export, and process-scoped progress/terminal state |
| AskMeetingsUseCaseTests / AskPipelineTelemetryTests | Shared trimming/search/evidence/answer behavior; lexical evidence before generation; cumulative snapshot coalescing and exact final text; typed timeout with evidence retention and zero late publication; nonmonotonic, whitespace, oversized, duplicate, or mismatched provider output failing closed; finite request/result/source/answer limits; deterministic bilingual exact retrieval before bounded generative fallback; cancellation-preserving query expansion; concurrent lexical/semantic work with partial-order telemetry invariants; no-evidence generation skip; evidence-preserving ordinary generation failure; an independent exact graph-fact bundle that cannot replace transcript evidence, distinguishes no request/domain abstention/operational unavailability, routes all three implemented fact adapters, and propagates cancellation; corpus-read-only product retrieval; cold/unavailable semantic fallback to lexical evidence; honest semantic and pipeline cancellation propagation; capability bypass for empty/invalid requests without trace creation; closed content-free Ask telemetry taxonomy; matched success/failure/cancellation intervals; and first-evidence/first-observable-token milestones |
| MeetingMemoryGraphQueryTelemetryTests | Closed six-job/four-outcome exact-graph telemetry taxonomy; facts/abstention/cancellation/failure classification without payload material; all six use-case mappings; alias-resolution timing only after one exact identity; and explicit app-observer removal without callback accumulation |
| MeetingMemoryGraphQueryRunProbeTests | Bounded explicit benchmark configuration; matched lifecycle and exact six-job sample counts; fact-only nearest-rank wall/CPU summaries; invalid host/fixture refusal; trace/content exclusion; private non-replacing JSON; and late-event failure |
| AskPresentationModelTests | Full Ask progressive finding/refinement/generation state, early citations and cumulative answer text, latest-question replacement, cancellation and stale-progress/snapshot rejection, 20-exchange retention, closed-window non-retention with an uncooperative provider, evidence fallback, process-scoped palette search/answer ownership, stale completion rejection across reset/reopen, and Markdown answer receipts |
| RetrievalChunkingTests | Deterministic single-actor turn grouping; confirmed-person continuity across observed labels; anonymous remote isolation and local-microphone continuity; mixed-language source preservation; character/duration/gap bounds; stable membership identity; representation-only retention; correction-local and per-source-text delta invalidation; source replacement; and fail-closed meeting, revision, identity, speaker, and timeline validation |
| SuggestMeetingReviewMetadataTests / MeetingDetailModelTests | Title/structure/chapter eligibility, known-recipe and bounded-label admission, independent failure degradation, cancellation propagation, route-owned one-shot state, revision/request fencing, and suggestion preservation after failed title persistence |
| MeetingLifecycleUseCaseTests | Exact Delete/Restore port delegation, failure propagation, and real-Store tombstone, aggregate, trash, and voice-mix conservation through the ApplicationKit boundary |
| MeetingPurgeUseCaseTests | Manual and expired purge ports, degradable audio failure, propagated storage failure, strict cutoff, continue-after-failure, and real scratch audio/database removal |
| SummaryRegenerationUseCaseTests | Provider override, recipe/language/glossary/notes material, direct-provider failure, Apple exact cache and translation pivot/fallback, silent Apple failure, unavailability, best-effort context/save semantics, successful/failed/cancelled provenance, exact-cache no-run semantics, correction-aware cache lineage, composed-evidence projection to accepted IDs, stale-publication rejection, validation, transactional rollback, and real MeetingStore summary/run linkage |
| SummaryCapabilityTests | Deterministic Sequoia capability and exact no-fallthrough behavior for selected but unconfigured Ollama/MLX engines |
| LocalSummaryProvidersTests | Typed Apple/Ollama/MLX discovery, deterministic Ollama model-name admission, hardware and disk guidance, explicit-preference preservation before and after asynchronous probing, and no write when no compatible provider exists |
| SettingsResourcesTests | Capability-neutral microphone choices, recording-root inspection and ordered resumable updates, unchanged location after failure, privacy-safe remembered-voice projections, and unsuppressed destructive failures |
| CompanionGenerationProvenanceTests | Exact ordered private-material fingerprints including question segment identity; external-provider sensitivity; exact local-RAG citation-to-answer-source mapping; role-separated evidence construction; content-free classifier/provider/egress configuration; aggregate-only metrics; remote success, on-device fallback, and cancelled external-provider attribution |
| DataEgressGatewayTests | Conservative loopback classification; exact remote/local Apuntador, summary, and explicit-publishing metadata; decoded question-only and full-summary request bodies; operation/classification/destination/provider/model/consent mismatch and non-HTTP rejection; required meeting identity; canonical publishing endpoint policy; content-free receipt-before-transport ordering; fail-closed recorder behavior; retained attempts on transport failure; redirect denial; and real gateway-backed summary response parsing |
| PrivacyReceiptTests | v6→latest migration and schema constraints; honest complete-versus-since coverage; content-free local/remote attempt and generation aggregation; strict missing/unknown/forged event rejection; and zero partial writes |
| CanonicalPeopleTests / CanonicalPeopleUseCaseTests | POSIX-stable alias normalization; real v7→v8 migration; duplicate aliases and exact candidates; explicit create-versus-existing delegation; atomic links; `Me`, missing, and already-linked rejection; and zero partial person/alias/speaker writes |
| ImportMeetingUseCaseTests | Required preparation/transcription order, typed progress, mixed-language preservation, best-effort diarization/summary, exact idle release, staged-audio rollback, atomic imported aggregate persistence, successful/failed/cancelled/no-provider summary provenance, privacy-safe metadata, and real MeetingStore summary linkage/rollback adaptation |
| ImportMeetingBundleUseCaseTests | Canonical attachment validation, duplicate rejection, text/audio ordering, machine-path clearing, early-failure isolation, compensation without error masking, full relational conservation including Apuntador evidence, foreign-child/evidence rejection, and rollback after an injected final evidence-link failure |
| ExportMeetingBundleUseCaseTests | Canonical attachment admission, text/audio ordering, opt-in and no-directory behavior, machine-path clearing, typed boundary failures, newest cross-recipe summary plus live-child conservation, tombstone exclusion, and degradable optional-row corruption through real MeetingStore adaptation |
| RefineMeetingUseCaseTests | Draft order/progress/language, silence/noise/bleed hygiene, exact composite transcript provenance, content-free metadata/metrics, no-attempt/failure/cancellation outcomes, revision-fenced run/segment linkage, persisted-detail/external-audio draft-and-apply ordering, fresh-speaker canonical-person non-inheritance, invalid-run rejection, Apuntador outcomes, immutable summaries, stale rejection, and injected transactional rollback through real MeetingStore adaptation |
| StartRecordingUseCaseTests | Once-sampled preferences, title/sequence and event-title policy, audio-first start with no live transcriber, preparation/reservation/source order, callback forwarding, selected-channel assets, typed preparation failures, staging/published evidence preservation, guarded empty-shell discard, reconciliation failure reporting, release, real MeetingStore atomic reservation before source invocation, and one matched recording-critical workload |
| StopRecordingUseCaseTests | Finalized/missing asset reconciliation, provisional attribution, per-turn mixed-language preservation, exact diarization/transcription initial-job policy and order, empty/partial-lane transcript recovery, truly silent/no-audio outcomes, admission and fallback failures, unconditional engine release, atomic real-Store snapshot/job adaptation, and one matched recording-critical workload |
| MeetingStoreTests summary history/evidence | Per-recipe immutable versions, newest-across-recipe selection, retained history, fingerprint cache/pivots, exact accepted-transcript/correction lineage, stale summary/Apuntador publication fencing, atomic same-meeting overview/decision/action/Apuntador validation, canonical decision coordinates, stable task/card identity, role-separated links, evidence clear-on-overwrite, revision stamping/staleness, physical-deletion unavailability, correction/unsupported replacement, active-claim fencing, text-erasing clear, and rollback on foreign evidence |
| AudioCaptureTests / LongCaptureBenchmarkTests / RecordingLevelBufferTests / RecordingLevelRelayTests | CaptureFileWriter staging CAF, reusable grow-only PCM storage, explicit idempotent close, exact frame conservation, atomic no-overwrite publication, persisted-PCM recovery measurement, complete streaming checksum/media/health evidence, accelerated bounded-heap dual-channel publication, same-pass compact per-chunk level evidence including accepted duration, drift summary, callback-liveness and two-minute Stop-nudge policy, mic-heartbeat stall/retry/recovery integration, post-close utility-queue publication with independent channel outcomes, recoverable-source invocation, one-slot 20 Hz level presentation with complete diagnostic ingestion, duration-stable sustained-ceiling hysteresis, isolated-peak rejection, clean-audio recovery, and cancellation fencing, Downmix, **Resample.linear**, startup cleanup |
| LiveTranscriptionAttacherTests / LiveTranslationRoutingTests / LiveTranslationStateTests / LiveTranslationWakeHubTests | Bounded newest-only hot attachment, shared cold-model join and failure cancellation, pre-attachment recovery requirement, matched live-consumer workload intervals, target-fenced translation state/results, growing-row source-revision refresh, eight-row chronological framework batches, one-wake broadcast buffering and cancellation, consent-driven lane wakeup, automatic failure-retry copy, unsupported-lane passthrough with later supported-lane progress, partial-support persistence, distinct recoverable-outage versus terminal-failure presentation, and explicit live-reader versus playback follow ownership |
| LiveCompanionWorkCoordinatorTests / LiveSummaryWorkCoordinatorTests / LiveSummaryWindowPolicyTests | One complete active Apuntador request plus one newest pending candidate; lifecycle cancellation and fresh-session handoff; one delayed summary cycle for burst signals, one retained wake during active work, successful bounded-backlog continuation, cancelled-worker replacement, oldest-unseen 32-row/6,000-character admission, and oversized-head progress |
| LegacyScrollInteractionTrackerTests | macOS 14.4 AppKit reader-intent observer scope, unrelated-scroll isolation, disconnect, and exact reconnect behavior |
| WaveformTests / AudioTranscoderTests / MeetingAudioWorkflowTests | Exact range-aligned Accelerate envelopes, deterministic fixed-chunk cancellation, already-cancelled caller rejection, one 600-default/2,000-maximum immutable waveform snapshot, host AAC integration, canonical-output collision preservation, all-channel verification before raw deletion, rollback after later-channel failure, live filesystem byte accounting, text-only playback degradation, role-aware reversible clear-mix ranges, injected application codec semantics, and matched waveform/media-export work |
| AudioProcessCatalogTests | direct tap scope by bundle ID: exact app/allowed helpers accepted, lookalikes and unrelated apps rejected |
| AcceleratorFallbackTests / SubtitleExportTests / ExportDocumentTypesTests | One cancellation-aware CPU retry with both Whisper load failures preserved; exact SRT/VTT timestamps, lexical filtering, rendered prefix-aware cue bounds, same-name speaker identity separation, line/arrow sanitization; and extension-preserving text-conforming macOS subtitle content types |
| DictationTextRulesTests / MousePTTGestureTests / MouseButtonSettingTests | Conservative bilingual filler seams; one-pass case-insensitive whole-trigger replacement without cascading or regex-template interpretation; canonical corrupt/duplicate storage; mouse press/release ownership; and vendor-facing Button 3+/invalid-default normalization without admitting left/right |
| UITestDefaultsTests | Disposable XCUITest launches overlay selected preferences in volatile `NSArgumentDomain`; ordinary launches and malformed payloads are ignored |
| TranscriptionTests / NemotronLatin1120Tests | Parakeet mapper/deltas, WhisperEngine helpers, anti-silence hygiene, **SpokenLanguageDetector** with automatic/fixed mixed-language policy, **VocabularyPrompt**, **AudioLevel.normalizePeak**, exact non-serving Nemotron artifact/revision/routing and filesystem-layout shape, rejection of unpinned optional bundles and missing artifacts, explicit EN/ES and no-vocabulary admission, index-based shared-timestamp deltas, cursor/non-finite/non-monotonic timing failure, bounded timing-free finalization, and no duplicate final emission |
| LiveTranscriptionBenchTests | Invalid-duration rejection before file access, exact engine-error propagation without partial evidence, and early-engine feeder cancellation/drain instead of background real-time work |
| CaptionCoalescerTests / LiveCaptionParagraphProjectorTests | 20 coalescer cases plus 6 presentation cases: merge, identity, channels, pauses, limits, punctuation, both bleed callback orders, overlapping exact-two-word and rolling-edge suppression, sequential/single-word preservation, closed-row immutability, distinct overlap, stable same-voice paragraphs, translation projection, the generic-`Them` no-merge fence, and a policy-owned 150-source-row tail |
| DiarizationTests | Catalog, SpeakerAttributor (multi-turn), SanitizeTurns, **MergeMicroClusters** (6), DiarizationEvaluation (units), live streaming (gated) |
| ProcessingOperationFingerprintTests / InitialTranscriptionOperationFingerprintTests | Length-framed SHA-256 identity; diarization segment-order stability and material/revision sensitivity; finalized audio/voiceprint/model evidence; summary provider/language/revision separation; Refine channel-order stability plus material/revision/language sensitivity and invalid-evidence rejection; and deterministic first-pass recovery identity across channel order, revision/audio changes, pending/missing/silent rejection, and canonical request policy |
| LiveSpeakerLabelerTests | 7 cases: row split with two voices, last row untouched, idempotency, mic never relabeled, "Me" by voiceprint |
| IntelligenceTests | PromptFactory, naming filters, **NamingExcerpt**, **LiveSummaryPolicy** |
| ChapterExtractorTests / PlaybackRangesTests / SummarySectionsTests / VoiceHueTests / TranscriptNoiseFilterTests | chapter boundaries/labels, safe duration-bounded voice-range complements, language-agnostic summary sections, source-ordinal-preserving generated-document projection, typed-commitment deduplication with a legacy Markdown fallback, stable speaker hues, and conservative fragment filtering without losing sentences/acronyms |
| MeetingTranscriptContentTests | Accepted-row projection, spoken-language/source-ID preservation, customized chapter labels, overlapping and gap playback semantics, split/merge-ready evidence mapping, corrected split rows seeking immutable original intervals, timestamp-route focus before playback, one-shot pending seeks, and a 20,000-row frontier lookup |
| TranscriptCorrectionCompositionTests / TranscriptCorrectionRevisionTests / MeetingTranscriptGenerationMaterialTests | Explicit raw/refined base and accepted/composed projection lineage, including identical zero-edit readings; deterministic replace, speaker, complete split, ordered merge, suppress, restore, and linear supersession behavior; convergent effective-overlay revision identity and malformed-provenance rejection; composed generation material with ordered accepted-source evidence projection; stale/missing/overlapping/branched/provisional/non-finite/ambiguous-ID edit rejection; and mixed optional language/confidence provenance preservation without invented evidence |
| InsightsScopeTests / LibraryStatsTests / InsightsFindingsTests | current/previous calendar windows, duration averages, zero-filled weekly cadence and heatmaps, streaks, no-decision evidence thresholds, recurring-topic ranking, stoplists, and participant exclusion |
| InsightsReadModelTests | complete scoped projection, current/previous totals, decision evidence from summaries/actions, recurring-topic extraction, and confirmed-participant exclusion |
| InsightsModelTests | complete/empty/degraded/failed phases, one read snapshot, section-local replacement, scope restart, and no-global-version behavior through a database-free client fake |
| InsightsObservationTests | independent live-rooted meeting/fact/voice/finding observations, delete/restore conservation, and active-scope finding bounds through real `MeetingStore` adaptation |
| MeetingDetailModelTests | complete/degraded/missing/failed review phases, one storage-independent projection, section-local replacement including privacy receipts, explicit persistence, correction-aware derived freshness and metadata reset, canonical-person, document, transcript/calendar-name, participant-voice, and playback/clip actions and effects, route-owned suggestion/audio state, exact silent versus visible failure/degradation policy, and Spotlight reconciliation requests through a database-free client fake |
| SpotlightProjectionTests / SpotlightIndexerTests | Newest correction-current summary selection, accepted/corrected transcript union, speaker/structural/restore policy, missing-state and malformed-provenance fail-closed behavior, v36 backfill, deterministic first-40 order, tombstone and 4,000-character bounds, complete entity snapshot, correction-driven client-state replacement, coalescing, retry, cleanup, mode separation, and exact App Entity attributes |
| SuggestMeetingSpeakerNamesTests / NameSuggestionFilterTests | coherent meeting admission, eligible remote-label short circuiting, attendee forwarding, complete-token verification without substring false positives, typed locally derived transcript/calendar evidence, label deduplication, typed missing meetings, and visible generation failure without EventKit or a model |
| MeetingDetailObservationTests | live-rooted transcript/cast/correction revision, newest-summary/action-item and correction provenance, Apuntador card/evidence/provenance, and privacy-receipt observations; evidence-link-only and independent event updates; lifecycle conservation; card/event cascades; and newest cross-recipe selection through real `MeetingStore` adaptation |
| BriefRelevanceTests / ReminderPolicyTests / MeetingReminderWorkflowTests / MirrorStatsTests | explainable passage ranking and weak-match rejection, order-independent reminder lead window/session deduplication/off state, disabled-source short circuit, one-sampled-time countdown, failure propagation, mirror qualification/notable delta, and factual English/Spanish synthesis |
| MeetingBundleTests | round-trip/remap of text, audio, notes, and Apuntador cards with role-separated evidence; malformed source-card target rejection; canonical-person link stripping; additive compatibility of format v1 |
| MeetingHealthTests / LiveTalkTimePolicyTests | meeting talk-time/share, ES/EN questions, thresholded interruptions, older-long-overlap conservation behind an ended neighbor, 200 dense timelines matched to the exhaustive reference, chained monologues, unattributed exclusion, closed-row-only live balance, five-minute filtering, evidence thresholds, and the 1,024-candidate presentation bound |
| VocabularyMinerTests | 6 cases: domain forms, recurrence threshold, existing-vocabulary/stoplist exclusion, form heuristics |
| MeetingTypeDetectorTests | Recipes catalog + capped excerpt; gated: classifies standup/planning/interview and leaves general alone (M13b criterion) |
| StorageTests / StorageSchemaV6Tests / RecordingPersistenceTests / ProcessingJobPersistenceTests / VoiceMixTests | Complete D4/D36–D43/D63–D66/D70/D75 contract: strict persistence, tombstones, hostile FTS, hidden-rank/BM25 top-k equivalence, complete-text plus highlighted-snippet search hits, retention, paths, migration, lifecycle/idempotency constraints, atomic recording/artifact handoffs, owner-leased durable work, provenance linkage, revision fences, and injected rollback |
| PostCaptureSummaryGenerationAttemptTests | Content-free durable provider/model/job/revision/config metadata, aggregate-only success metrics, and distinct failed/cancelled terminal attempts without invented output metrics |
| ProcessPostCaptureJobsUseCaseTests | Mixed-language first-pass cleanup/attribution and follow-up admission; real-Store diarization-to-summary publication; provider retry; optional-summary exhaustion; supersession; lease loss; typed diagnostics; and injected-clock no-poll scheduling |
| RecordingsLocationTests | 9: marker, fallback, resolve, resumable migration, and safe same-root aliases |
| CoreTypesTests | Types + **TitleTemplate** + canonical `LanguageCode`, canonical person/alias normalization, independent transcript/summary policies, and backward-compatible role-separated Apuntador evidence resolution |
| ResourceGovernorPolicyTests / ResourceGovernorCaptureExclusionTests / ResourceModelResidencyTests / AppResourceGovernorReleaseTests / ResourceWorkloadTests / IntelligenceSchedulerTests / TranscriptionSchedulerTests / SpotlightIndexerTests | Pure categorical admission/deferral/checkpoint/recovery and idle-model-eviction matrix; generation-fenced model load/use/release lifecycle, active-use exclusion, stable governor projection, and uninterpreted measured footprints; deterministic macOS memory/thermal mapping, stable idle-family dispatch, and last-use reconciliation outside the ledger lock; protected-capture state mirroring plus unknown-host idle-peer eviction, busy-peer deferral, standard-host parity, and post-release readmission for the Whisper/MLX pair; closed and stable workload taxonomy; matched success, cancellation, and relay behavior; payload-free intelligence queue versus inference; separate live/batch transcription classes with deterministic FIFO, already-cancelled rejection, and immediate queued-caller removal; and maintenance-only index reconciliation |
| SupportDiagnosticsTests / LocalizationTests / EnglishSourceTests | Path/checksum/content-free support format v2 audio-channel health and transcript-count evidence plus one matched support-export workload; EN/ES String Catalogs, placeholders, `.lproj` export, public-source English hygiene (README/top-level tooling, scripts, `.github`, packaging, app source), and English explanatory prose throughout `docs/` |
| SemanticCorpusIndexingTests / SemanticCorpusIndexingCoordinatorTests / SemanticCorpusIndexingSupervisorTests / AppResourceGovernorReleaseTests / RAGTests / MCPServerTests / VoiceIdentityTests / IntegrationsTests | Validated bounded/complete corpus persistence; admission pause without embedding; one-batch checkpoint commit, explicit policy suspension, durable missing-row resume, and protected-capture mapping across starting/active/stopping; one concurrent Library/background-maintenance flight, bounded coalescing, complete-demand precedence, last-waiter cancellation before persistence; serialized signal bursts with one rerun and no polling; disabled temporary-store ownership; capture-first runtime exclusion; installed-assets-only background preparation with no download; term-level lexical RRF, multi-term evidence, duplicate suppression, complete segment context, long-question broad-OR fallback, production-width semantic top-k, scalar-oracle equivalence, stable ties, safe limits, malformed/non-finite-vector exclusion, hybrid RAG fusion, MCP protocol, encrypted voiceprint/gallery round trips, missing/corrupt-key and unreadable-ciphertext preservation until explicit reset, and offline exporters |
| ExactPathScaleBenchmarkTests / ExactPathMatrixTests / ExactPathCrossHostTests / ExactPathBaselineTests | Test-only Accelerate/sqlite-vec exact comparison at canonical scales; separated non-comparable build lifecycles; alternating query order; content-free schema-1 observation shape; sqlite-vec exact scan beyond the 4,096 KNN window; three-observation schema-2 host receipts with externally recomputable timing/agreement state; exact scalar/aggregate validation; duplicate-key, copied-observation, mixed-host, wrong-tier, non-finite, missing-scale, instability, top-hit/top-k-set disagreement, and visible non-blocking lower-rank drift; three-profile plus two-OS coverage; source/toolchain comparability; versioned within-host query ratios with zero denominators blocked as `not-comparable`; malformed versus blocked CLI outcomes; aggregate-only stdout scorecards; and digest/source-bound, clean-checkout, ignored-destination, owner-only, atomic, non-overwriting retention whose fixed research authority cannot select a product engine |
| ParakeetIntegrationTests / NemotronLatin1120IntegrationTests + gated | Real models — Parakeet requires the canonical Release-configured `PORTAVOZ_MODEL_TESTS=1` lane; the optional non-serving challenger requires `PORTAVOZ_NEMOTRON_MODEL_TESTS=1`; both require the relevant model to be installed and `PORTAVOZ_TEST_WAV` (conversation/enrollment gates retain their existing Parakeet variables). Parakeet's arbitrary-WAV assertion and canonical runner output are content-free (D380) |

The five concrete residency adapters add architecture coverage on top of the
13 pure ledger cases. Every quality-speech, MLX-summary, live-speech,
speaker-diarization, and semantic-embedding load, failure, use, and two-phase
release transition must pass through the composition-owned ledger. Refine and
Import retain their exact `WhisperRuntimeLease`; summary generation retains its
exact `MLXSummaryRuntimeLease`; recording transfers a hot-only
`LiveSpeechRuntimeLease` to its attacher or joins a cold load only after audio
capture is active. A cold Parakeet load that completes after Stop is finalized
exactly once without attaching or delaying Stop. Every diarization operation
creates a fresh speaker session from reusable leased weights. Library, Ask, and
app indexing benchmarks share one actor-backed semantic runtime and retain a
lease through complete indexing-and-query operations. Library and Ask also
share one active backfill flight: bounded requests coalesce, complete demand
drains the durable remainder, and final-waiter cancellation cannot persist a
partial batch. Focused semantic tests prove concurrent borrowers share one
load, busy release is rejected, failed load is retryable, and preparation can
warm residency without inventing active use. Pressure-adapter tests prove
nominal/fair state is inert, warning/serious
state requests only idle families in stable order, platform mappings remain
closed, and a busy family is reconsidered exactly when its final lease ends.
Capture-exclusion tests additionally prove unknown hosts cannot start a second
Whisper/MLX load while recording is protected: the idle peer is released, the
loading or busy peer defers the new load, standard hosts retain their
established behavior, and the pre-load decision atomically reserves its ledger
generation between pre-preparation and pre-publication checks. AudioCaptureKit
remains free of model download, verification, runtime, and release references.
Direct shared-runtime reads, production loader bypasses, duplicate audio-level
PCM scans, unbounded meter publication, idle translation polling, and
unbounded Translation framework batches, plus per-turn or unbounded live
Apuntador generation wrappers, idle rolling-summary polling, unbounded summary
batches, and partially published summary cycles, are rejected (D158–D171).

`make test-recording-stress` is the deterministic reliability gate for capture
and recovery. Its 9 Aug selector run executes 221 focused tests across real capture/writer suites,
callback liveness, bounded level delivery, start/stop, crash recovery,
cold-model attachment, mixed-language preservation, bounded translation
routing/wakes, pure turn-end admission, bounded complete Apuntador generation
including overflow, cancellation, and opt-out, bounded signal-driven live-summary
coordinator/window behavior, durable jobs, recording persistence, and caption
row separation.
The first iteration builds normally and the remaining 24 reuse that build;
every iteration must execute at least 90 tests so a stale filter cannot pass
with an empty or materially incomplete corpus. Temporary logs are deleted only
after success and preserved on failure. The complete 25-iteration gate (5,525 test
executions) passes, as do focused Thread Sanitizer and Address Sanitizer runs.
This deterministic evidence does not replace the real Core Audio callback-
recovery acceptance in `docs/GAPS.md`.

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
Apuntador unavailable/incomplete/complete-empty/persistence-failure outcomes
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
rejected before writes, and a trigger rejecting the final Apuntador card rolls
the whole aggregate back. The architecture rule keeps bundle import behind
ApplicationKit and sequential Store writes out of the app adapter. Strict
SwiftLint remains clean across 216 source files; no interactive UI or localized
copy changed, so the existing 19-case suite remains the UI contract.

Band 2 slice 2L adds eight bundle-export tests and a fourteenth architecture
rule. Port fakes prove exact load/read/encode order, path stripping, audio
opt-in and no-directory skips, canonical channel/extension admission, complete
content handoff, typed missing/store/document failures, and no work after an
early failure. Real in-memory Store cases prove the newest summary across
recipes, cast/transcript/notes/Apuntador conservation, tombstone exclusion,
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
`libraryVersion`-keyed sequential detail/summary/Apuntador read path. Tests
prove complete/degraded/missing/failed state, section-local replacement,
live-rooted delete/restore conservation, action-item and card refresh, and
newest cross-recipe selection. The complete baseline is 593 package tests (13
gated), strict SwiftLint is clean across 231 Swift files, and all 20 XCUITest
cases pass. The detail-rail case retains fresh app-window-only evidence. No
control, localized copy, schema, or visible review behavior changed (D59).

Band 2 slice 2T extends the twentieth rule so `MeetingDetailView` cannot reach
Store, lifecycle, or `libraryVersion`; its route-owned model must expose the
explicit mutation actions and the app adapter must implement their narrow
client. Two direct model tests prove title/speaker/action-item/Apuntador/delete
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

Band 3 slice 3E adds four direct Apuntador provenance cases and four
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
loopback is local-device; remote and local Apuntador calls expose exact
content-free metadata; the captured JSON body contains static instructions and
the classified question but no transcript context; forged destination/provider
disclosures and non-HTTP destinations are rejected before transport; and
persisted Settings consent requires a source meeting. Apuntador provenance
cases now retain remote scope across success, fallback, and cancellation. The
22nd architecture test requires the
Core port, IntegrationsKit validation/transport adapter, gateway-injected
Apuntador client, production app composition, and no direct network call in the
adopted path. The complete baseline is 624 package tests (13 gated), strict
SwiftLint is clean across 235 Swift source files, and all 20 XCUITest cases pass.
Fresh Meeting Detail evidence confirms no visible behavior changed (D67).

Band 3 slice 3G-a adds three offline `DataEgressGatewayTests` for remote and
loopback OpenAI-compatible summaries, decoded full-summary request material,
real gateway-backed response parsing, exact provider/model/destination/scope,
and rejection of missing meeting identity or cross-operation consent before
transport. Existing Apuntador coverage now also rejects a summary consent
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

Catalog-verified readiness adds direct `VerifiedModelLifecycle` coverage and an
architecture ratchet over every production app consumer. Tests prove that
installation evidence is unavailable for missing/corrupt artifacts, successful
evidence is keyed to the exact revision, explicit forced verification detects
post-check corruption, installation repairs it, and removal invalidates it.
The app ratchet forbids one-file and size-only readiness probes and limits bare
`ModelStore()` construction to composition plus the isolated benchmark harness.
The Settings smoke retains its clean-install Turbo/Compact download controls
while disposable composition uses an empty model root (D113).

The capability-aware intelligence stabilization adds five pure app-policy
cases and one end-to-end UI case. They prove the deterministic Sequoia fixture,
clean-install chat-model choice, OCR-only Ollama rejection, and that selected
Ollama/MLX configurations cannot fall through to Apple. The UI case launches a
meeting without a summary, selects Apple under simulated Sequoia capability,
generates, follows the actionable alert directly into Intelligence Settings,
verifies the unavailable explanation, and then verifies that the Voice pane
explains Apuntador without exposing a dead enable toggle. It retains named
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
`meeting-detail-privacy-receipt` app-window screenshot in both supported locales
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
`band-3i-redacted-support-export` and `meeting-detail-processing-recovery`
app-window screenshots and inspect a real temp JSON file without opening a save
panel. The slice gate is 667 package tests (13 gated), strict SwiftLint is
clean across 249 Swift source files, and all 23 XCUITest cases pass in English
and Spanish (D76).

The real-call protocol in `docs/FIELD-VALIDATION.md` revalidates every format-2
support key and bounded value before atomically publishing a new owner-only
evidence directory. `scripts/collect-field-evidence.py` rejects unknown fields,
content-bearing additions, malformed counts/digests/timestamps, mismatched app
versions, non-Portavoz bundles, and `/Applications/Portavoz.app`. Protocol 2
selects one of six canonical call fixtures and projects only seven stable
evidence IDs with fixed subsystem ownership. A paired pre/post-Refine package
must retain the same pseudonymous meeting reference, advance export time, and
advance the transcript revision before Refine may pass. Report-derived
contradictions also fail closed: a recording lifecycle cannot pass Stop, a
missing dual-channel shape cannot pass route preservation, and missing audio
cannot pass post-capture admission. Offset-free timestamps are rejected so
paired export ordering cannot mix timezone-naive and timezone-aware values.
Protocol-1 scenarios keep their original manifest and filename for one release.
Thirteen tooling cases plus a real
StorageKit before/after-Refine export test cover both protocols, owner-only
publication, content rejection, evidence scoping, and format-2 compatibility.
No audio, transcript text, database, or screenshot enters this workflow.

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
`meeting-detail-scale-5000-segments` screenshot. Both EN and ES suites use the
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

Band 4 slice 4G adds three real-Store `SpotlightProjectionTests` and six actor
`SpotlightIndexerTests`. Projection coverage proves newest cross-recipe
summary selection, deterministic first-40 transcript order, tombstone scope,
the 4,000-character cap, and the empty library. Actor coverage proves burst
coalescing, client-state no-op plus durable legacy cleanup, cleanup retry after
failure, cleanup persistence across indexer recreation, transient replacement
retry, terminal failure, and recovery after a fresh request. The 32nd
architecture case guards
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
`meeting-detail-confirmed-person-memory` screenshot in English and Spanish.

Band 5 slice 5B adds backward-compatible Core claims, exact E-tag formatting
and provider parsing, schema-v9 atomic validation and source-revision stamping,
current/stale/unavailable resolution, physical-deletion handling, portable
bundle remapping, and localized source navigation. The 27th UI case selects
the seeded overview source, verifies the exact transcript row and 0:03
playhead, and retains `meeting-detail-summary-evidence` in both locales. The full gate
is 708 package tests (13 gated), zero
strict-lint violations across 259 Swift source files, and 27 XCUITest cases per
locale (D86/D87).

Band 5 slice 5C adds typed Core validation, schema-v10 migration constraints,
active newest-claim write fencing, replacement and text-erasing clear,
generated-summary rejection, format-v1 bundle conservation/remapping,
privacy/diagnostics isolation, Meeting Detail model effects, catalog coverage,
and a source-level architecture rule. The 28th UI case marks the overview
unsupported, adds a Spanish correction while asserting generated Markdown is
unchanged, retains `meeting-detail-summary-feedback`, and clears the assessment
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
playhead without autoplay, and retains `meeting-detail-decision-evidence` in both
locales. The full gate is 723 package tests (13 gated), zero strict-lint
violations across 266 Swift source files, and 29 XCUITest cases per locale
(D86–D89).

Band 5 slice 5E adds backward-compatible per-action provider tags, stable
task-keyed Core evidence, schema-v12 one-to-one parents and ordered nullable
links, target/revision/live-segment validation and rollback, completion-state
stability, physical-deletion handling, translation and format-v1 bundle
identity remapping, Apuntador/diagnostics isolation, and a source-level
architecture rule. The 30th UI case opens the seeded to-do tab, selects the
source beneath its exact checkbox, verifies the selected transcript row and
0:03 playhead without autoplay, and retains
`meeting-detail-action-item-evidence` in both locales. The full gate is 731 package
tests (13 gated), zero strict-lint violations across 268 Swift source files,
and 30 XCUITest cases per locale (D86–D90).

Band 5 slice 5F adds exact question-segment identity to the Apuntador request
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
`meeting-detail-apuntador-evidence` in both locales. The full gate is 740 package
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

The macOS review-workflow conformance unit adds two direct document-preparation
cases, seven participant-voice-memory cases, two feature-owner cases, one new
dependency case, and a strengthened document-publication ratchet. They
prove coherent detail/General-summary loading, released suggested filenames,
exact rendered bytes, missing-meeting short circuiting, degradable gallery and
extraction reads, one-to-one unnamed-remote suggestions, case-insensitive
duplicate admission, explicit named-remote persistence, `Me`/unnamed rejection,
visible encrypted-gallery write failure, typed insufficient audio, one-shot
suggestion state, and typed presentation effects. The source rules reject
direct canonical renderer, Gist publisher, gateway, credential, encrypted
gallery, recording-path, diarization-model, and
embedding-matcher coordination in Meeting Detail SwiftUI. The full gate is 903
package tests (13 gated) and zero strict-lint violations across 328 Swift source
files; the behavior-neutral composition change retains the 37 XCUITest cases
per locale (D105).

The local-voice application-boundary unit adds seven focused workflow cases and
one exact architecture ratchet. They prove raw/echo-cancelled capture-mode
forwarding, supplied-sample microphone bypass, capture/extraction/persistence
progress order, four-second finite-sample admission, invalid-duration short
circuiting, capture/extraction/destructive failure propagation, and zero
partial persistence after invalid audio or an earlier failure. The source rule
reads the actual Settings and Onboarding views and rejects direct microphone,
diarizer, voiceprint extraction/store, cache-invalidation, AudioCaptureKit, and
DiarizationKit access. The full gate is 911 package tests (13 gated) and zero
strict-lint violations across 329 Swift source files; the behavior-preserving
composition change passes all 38 XCUITest cases per locale (D106).

The calendar-backed speaker-naming application boundary adds five focused
workflow cases, expanded shared-filter and route-model coverage, and one exact
architecture ratchet. They prove one coherent meeting read, `Me`/named-speaker
short circuiting, exact attendee forwarding, whole-token verification without
substring false positives, typed locally derived transcript/calendar evidence,
label deduplication, typed missing meetings, visible generation and persistence
failure, route-owned loading/removal state, and zero automatic speaker mutation.
The source rule rejects EventKit, concrete name generation, identity filtering,
and suggestion state in Meeting Detail SwiftUI. The full gate is 918 package
tests (13 gated) and zero strict-lint violations across 331
Swift source files; an isolated unnamed-speaker fixture retains the explicit
action and screenshot in all 39 XCUITest cases per locale (D107).

The local summary-provider boundary adds eleven focused policy/use-case cases
and one exact architecture ratchet. They prove Apple priority, deterministic
Ollama model-name admission, blank/OCR/embedding/reranking/Whisper rejection,
MLX hardware/disk eligibility, typed low-resource guidance, one shared discovery
result, explicit-preference preservation both before and after asynchronous
probing, and no write when no compatible provider exists. The source rule
rejects direct Ollama probing, hardware recommendation, and clean-install
provider selection in Settings and Onboarding, and requires disposable
automation to avoid the host Ollama and hardware profile. The full gate is 923
package tests (13 gated) and zero strict-lint violations across 333 Swift source
files; the 39 XCUITest cases per locale retain the shared localized intelligence
recommendation and exact setup actions (D108).

The Settings device-resource boundary adds eight focused workflow cases and one
exact architecture ratchet. They prove capability-neutral microphone mapping
and failure propagation, recording-root inspection without migration, ordered
progress before a successful terminal result, unchanged application state after
migration failure, nonnegative progress, embedding-free remembered-voice
projections, and unsuppressed single/all deletion failures. The source rule
rejects direct `AudioDeviceCatalog`, `RecordingsLocation`, `VoiceGallery`, and
destructive `try?` coordination from the three SwiftUI surfaces. The full gate
also includes two storage regressions proving that normalized and symlinked
same-root destinations preserve every recording without reporting progress.
The full gate is 934 package tests (13 gated) and zero strict-lint violations
across 335 Swift source files; all 39 XCUITest cases per locale retain Settings
navigation and a `settings-recording-storage` screenshot (D109).

The pre-meeting reminder boundary adds five focused workflow cases, an
unsorted-input policy regression, and one architecture ratchet. They prove that
disabled reminders never read the calendar port, the earliest due event wins
regardless of source ordering, admission and rounded-up display minutes share
one sampled time, session deduplication remains exact, and source failures
propagate to the optional app adapter. The source rule rejects EventKit,
preferences, clock sampling, and direct policy execution from the controller.
The full gate is 940 package tests (13 gated) and zero strict-lint violations
across 337 Swift source files (D110).

Meeting Detail metadata coordination adds five focused workflow cases, three
route-model cases, and one architecture ratchet. They prove title, structure,
and chapter-label eligibility; known-recipe and bounded-label admission;
independent ordinary-failure degradation; cancellation propagation; one-shot
state; request/revision fencing; and suggestion preservation when title
persistence fails. The source rule rejects direct Foundation Models capability
checks, concrete metadata generators, and view-owned suggestion state. The full
gate is 949 package tests (13 gated) and zero strict-lint violations across 339
Swift source files (D111).

Meeting Detail audio coordination adds three application-workflow cases, two
route-model cases, four transcoder cases, and one exact dependency ratchet. The
five total transcoder cases include the pre-existing host integration. Together
the tests prove
text-only degradation, one-shot playback admission, same-directory retry after
cancellation, waveform/filter preparation, explicit clip export,
codec-capability injection, real filesystem
accounting, refusal to replace a canonical output, and all-channel rollback
without deleting any original. The direct AAC integration uses the exact mono
Int16 CAF emitted by production capture when the host encoder is available and
records a capability skip only for the system
`fmt?` failure; failure-safe batch semantics do not rely on that integration.
The full gate is 962 package tests, and strict lint is
clean across 343 Swift source files (D113).

The final macOS architecture conformance audit adds two repository-wide
ratchets. One asserts the complete internal dependency graph for every
production target, including the app and CLI composition roots. The other
inspects every SwiftUI `View` source and rejects concrete capability
construction, direct persistence calls, and imports of lower-level adapter
frameworks. The audit found no remaining boundary violation in the implemented
macOS graph. The full gate is 964 package tests (13 gated), and strict lint
remains clean across 343 Swift source files (D114).

Verified-model concurrency hardening adds four deterministic actor tests. They
prove invalidation and forced verification cannot return obsolete in-flight
evidence, a later removal waits for an earlier installation of the same
descriptor, and cancellation after the verified filesystem commit reports
success rather than a false failure. The existing repair case also rejects
leftover sibling staging files. The current full gate is 968 package tests (13
gated), with strict lint still clean across 343 Swift source files.

Private-iCloud receipt hardening adds one protected-publication persistence
case, one support-status characterization, stronger asset-protection assertions,
and an architecture ratchet for the single publication primitive. Together they
prove content-free destination probes independently apply and read back complete
protection and backup exclusion. An added classifier case proves only direct or
Foundation-wrapped `EINVAL`/`ENOTSUP` can omit an unavailable metadata key;
permission and verification failures remain closed. One POSIX descriptor still
creates each private `0600` sibling, applies supported metadata before content,
handles partial writes and `EINTR`, and synchronizes the bytes with `fsync`.
The primitive always verifies exact size and owner-only permissions, verifies
supported metadata, publishes through one same-volume rename, leaves no staging
artifacts, and does not contradict an acknowledged cloud copy with an all-
content-local status. Architecture coverage rejects reintroducing `FileHandle`
or a broad compatibility bypass. The current full gate is 973 package tests
(13 gated), with strict lint clean across 344 Swift source files (D115/D116).

The same supported Sequoia lane compiles recovery comparisons and exact Refine
fingerprint composition as bounded, explicitly typed steps. Existing operation-
fingerprint characterization pins the canonical digest and proves that this
compiler compatibility shape does not change channel-order stability or
material, revision, and language sensitivity. The same lane compiles the
focused transcript with an explicit vertical/no-indicator `ScrollView`
signature and explicitly typed visual-effect arithmetic, while the bilingual
Meeting Detail smoke exercises the unchanged fixed viewport, active transcript,
and player behavior. The RAG term-fusion fixture builds its high-cardinality
segment sets with explicit typed loops so Sequoia exercises the same ranking
evidence without exceeding its type-checking budget.

Current-SDK diagnostic closure uses `swift build -Xswiftc
-warnings-as-errors` locally and in the primary `macos-latest` CI build. The
Sequoia lane remains the oldest-runtime/toolchain compatibility proof. An
architecture characterization preserves the built-in
vertical scroll coordinate space, supported MLX memory API, narrow
lock-protected AVAudioConverter input bridge, absence of import-wide
AVFoundation concurrency suppression, current no-op/throwing call shapes, and
the CI warning gate. This leaves first-party Swift warning-free without turning
dependency package metadata warnings into product exceptions (D118).

### Meeting Memory Graph projection recovery (D273/D277)

Thirteen deterministic storage/application cases cover additive v26-to-v27,
v28-to-v29, and v29-to-v30 migration, exact authority-scope seeding, all nine
typed edge families,
canonical topic-root projection, bounded partial publication, fail-closed
readiness, correction and deletion, profile reset, governor pause/resume,
expired-owner recovery, idempotent edge replacement, independent semantic and
graph leases, capture-time admission denial, and the absence of redundant work
for lifecycle fields that cannot change topology. One later-meeting question
transition proves that only its evidence meeting gains topology while the topic
edge remains stable. A blocker case proves opening and clear evidence meetings
remain connected while active serving becomes empty, so lifecycle state cannot
erase historical topology. The tests use only
in-memory SQLite and public synthetic records; no model, user library, or graph
engine participates.

Supervisor characterization additionally proves a disabled graph owner ignores
wake signals and a coalesced semantic rerun retains one continuous `building`
phase until every queued drain finishes. Architecture ratchets keep the graph
profile in Core, storage/migrations in StorageKit, orchestration in
ApplicationKit, and the signal owner in the macOS composition root. Existing
schema-migration suites now require v27 without dropping any historical
migration. GRAPH-3 changes no SwiftUI surface, so scoped XCUITest and screenshot
evidence are intentionally not applicable to this slice.

### Evidence-backed memory timeline (D274–D277)

Eleven deterministic timeline XCTest cases characterize the bounded read over
in-memory SQLite. They prove exact topic decision/commitment facts,
explicit supersession evidence from both meetings, direct segment navigation,
current-owner-only person commitments without decision attribution, projection
readiness, exact-anchor and temporal-baseline abstention, correction-revision
staleness, current same-meeting evidence preference, deterministic newest-first
limiting and overflow, exact-evidenced typed reschedule output, refusal to
attach unrelated source evidence to legacy commitment lifecycle changes,
explicit unsupported fact disclosure, and the narrow ApplicationKit delegation
seam. The question case proves opening and resolution from separate exact
meeting evidence, stable reviewed wording, graph-selected identity, and no
Companion/Apuntador promotion. Five dedicated question policy/storage cases
cover strict resolve/reopen/dismiss transitions, additive v29 migration,
idempotent retry and identity-conflict rejection, stale/duplicate/corrected
evidence rollback, trigger-level current-evidence enforcement, and immutable
identity/history. Commitment continuity coverage separately proves the additive
v28 migration, format-3 JSON round-trip, ordered persistence, immutable event
evidence, and legacy history loading without evidence invention.
The blocker timeline case proves exact confirmation, clear, and reopen evidence
as newest-first typed facts with both endpoint identities and direct segment
navigation. Six dedicated blocker policy/storage cases cover legal transition
projection, additive v30 migration, idempotent confirmation and event retries,
pair/identity conflict rejection, stale/duplicate/missing/corrected evidence
rollback, endpoint liveness, trigger enforcement, active-only serving, and
immutable identity/history.
The fixture uses only public synthetic English material and language-neutral
identity/evidence rules; it invokes no model, network, user library, or
generated narrative. D270's separate canonical corpus remains the bilingual
query-quality authority.

This backend change does not alter SwiftUI, so XCUITest and screenshot evidence
remain not applicable. D270 corpus-to-product adapter coverage, private
anonymized field evidence, Ask
composition, and graph scale budgets remain separate gates rather than implied
by these focused tests.

### Source-backed blocker query (D278)

Twelve deterministic query cases cover invalid limits, unready projection,
unavailable commitment identity, one typed active blocker fact with exact
commitment/relation evidence and causal navigation, explicit clear/absent-link
abstention, correction-driven evidence failure without a topology rebuild,
deterministic newest-first pagination, an unavailable newer candidate followed
by a current older fact, explicit bounded-candidate exhaustion, missing exact
commitment provenance, preference for a later current commitment source over
corrected historical provenance, rejection of graph edges whose endpoints
disagree with blocker authority, and ApplicationKit port delegation. The
candidate-hydration regressions prove the visible limit is applied only after
freshness filtering and that a truncated unusable window cannot claim there are
no blockers.

One architecture ratchet keeps the query contract in Core, graph selection and
authority hydration in StorageKit, orchestration in ApplicationKit, and direct
presentation composition absent. It also pins the decision record and bounded
candidate policy. The
tests use in-memory SQLite and exact synthetic transcript rows; no model,
network, user library, SwiftUI, XCUITest, or screenshot evidence participates.
At this boundary the remaining five adapters, corpus mapping, private field
evidence, and scale budgets were intentionally not claimed; the later closure
section records their implemented status.

### Canonical blocker product conformance (D279)

One deterministic package case loads exactly the six canonical
`commitmentBlockers` examples and runs each in an isolated in-memory Store.
Five answer cases cover English-to-English, Spanish-to-Spanish,
English-to-Spanish, Spanish-to-English, and code-switched relationships. The
sixth case confirms both endpoint authorities but no causal relationship and
must return `unsupported-causal-link`.

Every case uses public Summary, commitment, decision, blocker, graph
maintenance, and ApplicationKit query boundaries. Assertions require exact
ordered result and evidence identities and reject every forbidden distractor.
The architecture ratchet prohibits IntelligenceKit, direct authority writes,
and presentation composition. No model, network, user library, SwiftUI,
XCUITest, or screenshot participates. At this boundary the other five product
mappings and relational scale budgets were still open; later slices close both.

### First-discussion query and canonical conformance (D280)

Seven focused query cases cover unready projection, unavailable exact topic,
one typed earliest fact with event time and navigation, merged-child family
resolution, stale earliest evidence that cannot be replaced by a later current
mention, unavailable earliest evidence with the same fail-closed rule, a ready
projection missing its exact authoritative edge, and ApplicationKit delegation.
Lower-level corruption fixtures may inspect the in-memory database, while the
stale-evidence regression uses the public meeting replacement boundary.

One product conformance case loads exactly the six canonical
`firstDiscussion` examples. Five answer cases span English-to-English,
Spanish-to-Spanish, both cross-language directions, and code switching; one
case requires `stale-evidence-only`. Each fresh Store receives all confirmed
topic mentions, including the forbidden distinct-topic distractor, through
public meeting, segment, create/link confirmation, graph-maintenance, and
ApplicationKit APIs. Assertions map only typed returned topic-evidence and
segment identities to the corpus and require exact results, evidence order,
and forbidden-result exclusion.

One architecture ratchet pins exact-identity input, authoritative earliest-row
selection, graph-only consistency checking, public-only product mapping, and
the absence of direct presentation composition, GRDB, `@testable`,
IntelligenceKit, or direct database writes in the conformance adapter. These
nine tests use no model, network, user library, SwiftUI, XCUITest, or
screenshot. At this boundary four product mappings remained; the later closure
covers them. Private field evidence remains external.

### Person-commitment query and canonical conformance (D281–D282)

Eleven focused cases cover invalid and unready queries, unavailable exact people,
one current typed fact with exact source navigation, completed-work exclusion,
evidenced reassignment with the assignment event as primary source, missing or
stale reassignment evidence, partial derived-ownership loss, stale original
evidence, bounded newest-first paging, and ApplicationKit delegation. The
reassignment cases also prove that current ownership cannot borrow only the
original owner's source.

Three additional focused cases prove invalid/missing alias rejection,
same-name ambiguity without a fact read, and exact-person delegation with the
requested bound. One product conformance case loads all six canonical
`personCommitments` examples through public meeting, speaker, canonical-person,
transcript, Summary, commitment lifecycle, graph-maintenance, and ApplicationKit
boundaries. Five multilingual answer cases require the exact open Mara fact and
source while excluding completed and other-person work; the two distinct Alex
identities in the sixth case must abstain before exact factual serving.

Two architecture ratchets pin exact `PersonID` input, complete current
authority-versus-projection ownership reconciliation, continuity hydration,
exact source evidence, the read-only alias candidate boundary, public-only
canonical mapping, and the absence of alias-based presentation composition.
These seventeen tests use no model, network, user library, SwiftUI, XCUITest,
or screenshot. At this boundary the remaining jobs and scale budgets stayed
open; the later closure covers them. Private evidence remains external.

### Independent Ask graph-fact evidence lane (D283)

Seven focused Ask workflow cases prove that one caller-resolved graph query is
returned beside transcript citations, no query remains explicitly not
requested, ordinary graph failure is disclosed without erasing transcript
evidence, graph facts cannot replace failed transcript retrieval, released
evidence calls never enter the graph lane implicitly, cancellation propagates,
and the local adapter routes each implemented exact fact query without
synthesis. One architecture ratchet pins the separate bundle, production-local
composition, typed adapter boundaries, transcript-only answer contract, and
absence of presentation adoption. These eight cases use no model, network,
user library, SwiftUI, XCUITest, or screenshot.

### Exact Ask graph-fact filters (D284)

Twenty-one focused cases cover finite half-open date/status filtering and
intersection, exact person/topic alias resolution, ambiguity and identity/job
compatibility, rejection of invalid resolved constraints and exact queries,
query pushdown before retrieval, absence of capability entry without a graph
job, blocker/person filtering before visible limits, earliest topic discussion
inside a requested range, and incompatible fixed-status no-match behavior. One
architecture ratchet pins the read-only candidate ports,
shared exact Core filter, local composition, pre-limit StorageKit boundaries,
absence of post-page filtering, lack of Intelligence/GRDB coupling, and no
Presentation adoption. These twenty-two cases use no model, network, user library,
SwiftUI, XCUITest, or screenshot.

### Typed graph-fact answer synthesis (D285)

Seven focused Ask workflow cases prove that typed facts, exact source segments,
and page disclosure reach a separate opt-in generation port; malformed or
abstained graph material and empty transcript evidence skip generation;
ordinary generation failure preserves both lanes; and cancellation remains
cancellation even when a provider returns late output. Five pure
synthesis-admission cases reject malformed facts,
duplicate or inconsistent exact evidence, missing transcript identity, and
cross-lane source drift. Three deterministic IntelligenceKit cases pin separate
transcript/fact/source markers, page-completeness instructions, exact source
deduplication, missing-primary rejection, and independence from the released
transcript-only prompt without executing a model. One architecture ratchet pins
the ApplicationKit and IntelligenceKit contracts, source-only citation rule,
dependency direction, and absence of Presentation adoption. These sixteen cases
use no model, network, user library, SwiftUI, XCUITest, or screenshot.

### Bounded progressive Ask reliability (D384)

Focused workflow tests stream one character at a time and require bounded
cumulative UI publications plus the exact final answer. Separate adversarial
providers exercise timeout, cancellation-ignoring late output, nonmonotonic
rewrites, whitespace, oversized answers, and fused/returned citation drift.
Request and result bounds must reject before retrieval or generation, while
oversized citation provenance must fail before generation. Telemetry
tests prove Foundation Models query-expansion cancellation cannot become an
ordinary empty fallback, and scheduler tests prove a cancelled opaque inference
cannot return its late value or retain stale cancellation bookkeeping.

Presentation tests submit a second question while the first provider remains
suspended, reject the old evidence/answer/completion, retain only 20 exchanges,
and release a closed window even when its provider ignores cancellation. The
existing real-app `LibraryUITests` Ask journey remains the single complete
conversation contract: it replaces an already-pending no-hit question, observes
lexical and fused phases, observes identified partial generated text before the
final answer, and follows the exact citation to 00:03. The disposable adapter
uses finite subsecond delays only to keep each state observable; it downloads no
model and touches no user library. Running that one journey in English and
Spanish is the minimum-safe feature gate. Complete bilingual XCUITest remains
the integration/release-candidate gate, and physical Sequoia/Tahoe plus assistive
technology remain external evidence.

The exact 2026-08-23 D384 candidate passed strict SwiftLint over 707 Swift
files with zero violations and a first-party warnings-as-errors build in
25.13 s. Its focused reliability set passed 287/287 in 5.270 s; the complete
Swift package passed 2,627/2,627 with 15 explicit environment/model skips and
zero failures in 115.127 s; and the architecture/commitment-source-link
ratchets passed 207/207. Repository hygiene retained all 105 UI
scope entries, while the socket-permitted tooling lane passed 499/499 in
12.418 s. One reused real-app build then passed the exact Ask journey once per
locale: English 1/1 in 9.853 s and Spanish 1/1 in 8.233 s, including
latest-query replacement, progressive evidence, identified partial answer,
exact final answer, and exact citation seek. Those scoped bilingual runs are
D384 feature evidence, not a substitute for the complete bilingual
integration/release-candidate gate.

### Selected local-engine manual Ask qualification (D385)

Focused provider-neutral answer tests prove final-only compatibility streaming,
bounded character and UTF-8 prompt admission before aggregate allocation,
source-injection framing, exact evidence retention, cancellation, timeout, and
typed provider failure. Composition tests sample the selected summary engine on
every request, preserve Foundation Models capability checks, require explicit
loopback Ollama configuration and consent, reuse the process-owned bounded MLX
runtime, reject duplicate resolver installation without terminating the app,
and never silently fall back to another provider. Presentation tests keep exact
citations visible when local generation is unavailable, failed, or timed out.
The durable privacy tests require a content-free receipt to finish SQLite
persistence before an Ollama request begins; cross-library Ask uses the separate
global journal rather than falsely assigning several meetings to one source.

The real-app Ask journey launches the disposable bilingual seed with simulated
Sequoia capabilities, completes the existing lexical/fused progressive journey,
retains the exact generated answer and citation seek, and rejects an unavailable
generation status. This proves that explicit manual Ask is not gated by Apple
Foundation Models on Sequoia; package tests, rather than a fake provider chooser
in the app, bind that same route to the selected Foundation Models, Ollama, or
MLX adapter. It does not claim that any real model asset was installed or that a
network provider answered.

The exact D385 candidate passed a current-SDK first-party warnings-as-errors
build, 46/46 focused D385 tests in 0.874 seconds, nine post-review migration and
architecture regressions in 0.697 seconds, and the complete 2,646-test Swift
package with 15 explicit environment/model skips and zero failures in 114.556
seconds of XCTest execution. The architecture and commitment-source-link
ratchets passed 208/208 in 4.588 seconds; all 499 deterministic tooling tests
passed in 12.750 seconds; repository hygiene retained the 105-case UI catalogue;
both localization catalogues, diff whitespace checks, and strict SwiftLint over
712 Swift files passed with zero violations.

Because localized status copy changed, the changed-file selector expanded
fail-safe to the complete catalogue in both locales instead of treating the Ask
journey alone as sufficient. One 25-second build was reused and locales ran
sequentially. Final macOS 26.5.2 (25F84), arm64 result bundles passed 105/105
English in a 1,105.167-second result interval and 105/105 Spanish in a
1,104.740-second interval, with zero failures, skips, or expected failures.
Content-free receipts also passed their budgets: English wall 1,116 seconds,
p50 7.060, p95 21.398, maximum 90.747; Spanish wall 1,118 seconds, p50 7.242,
p95 19.466, maximum 91.366.

The Release bundle was rebuilt in 92.76 seconds, deeply verified, re-identified
as `app.portavoz.mac.dev`, installed only at `/Applications/Portavoz Dev.app`,
and observed at PID 12457 running from its exact executable. The stable
`/Applications/Portavoz.app` retained its `app.portavoz.mac` identity and was
not an install target. Packaging had no production CloudKit profile and no
optional Metal Toolchain metallib, so this host supplies neither production
CloudKit nor real embedded-MLX evidence. These results are deterministic local
Tahoe-family automation, not physical Sequoia or separate Tahoe hardware,
Foundation Models/Ollama/MLX installed-asset quality, VoiceOver/Voice Control,
signing/notarization/distribution qualification, or private field evidence.

### Explicit manual Ask source qualification (D386)

Package regressions require Web to fail before retrieval or generation, an
unscoped adapter to reject exact-meeting requests, an explicitly scoped adapter
to receive only the selected identity, and graph facts to reject non-Library
authority before either evidence lane. The application boundary also rejects a
scoped adapter that returns a foreign search hit or progressive/final citation
before that material can reach presentation. Real storage coverage seeds
accepted, corrected, and structural FTS results in one meeting plus a foreign accepted
result and proves both meeting scopes remain disjoint. Lexical and semantic
retrieval separately prove that foreign hits never publish; meeting semantic
requests retain the fixed 256-candidate ceiling. Presentation coverage proves
default Library authority, Web no-fallback cancellation, exact selection before
submit, malformed/oversized catalog rejection plus bounded failure/retry,
source capture on pending/completed exchanges, and stale-publication fencing.

The existing real-app Ask journey is extended rather than duplicated. It opens
Library, proves Web visibly unavailable with submit disabled, selects one exact
seeded meeting, replaces pending work, observes meeting-scoped progressive
evidence and answer source, and follows the exact citation. The command-palette
journey also proves its visible fixed Library authority. Localization/shared
catalog changes expand the changed-file selector fail-safe; scoped journey
evidence does not replace the complete bilingual integration/release gate.

The finalized D386 tree passed the Swift 6 warnings-as-errors build in 21.50
seconds; 118/118 focused source-policy regressions in 3.606 seconds; the full
2,659-test package suite with 15 explicit environment/model skips and zero
failures in 110.364 seconds; 209 architecture/commitment-source-link ratchets;
499 tooling tests; repository hygiene; both localization catalog parses; the
complete 105-test UI catalog; exact diff checks; and strict SwiftLint across
713 Swift files with zero violations. The corrected command-palette journey
then passed one focused real-app run per locale from one build: English in
8.887 seconds and Spanish in 8.724 seconds.

The final changed-file gate reused one six-second build and passed 105/105
English plus 105/105 Spanish real-app cases on macOS 26.5.2 (25F84), with no
failures, skips, expected failures, or retries. English recorded 1,095.719
seconds of test duration, 1,112 seconds wall time, and 20.864 seconds p95;
Spanish recorded 1,101.940 seconds of test duration, 1,120 seconds wall time,
and 20.544 seconds p95. An earlier complete Spanish run exposed one incorrect
test literal—`Fuente de respuesta` did not match the catalog's `Fuente de la
respuesta`—while the rest of that answer/citation/seek journey succeeded. The
fixture was corrected, proved in both focused locales, and only then was the
complete bilingual gate rerun; a green retry did not substitute for a root
cause. This is deterministic local Tahoe-family automation, not installed-
model quality, physical Sequoia or separate Tahoe hardware, VoiceOver/Voice
Control, production CloudKit, signed/notarized distribution, or private field
evidence.

The Release bundle was rebuilt in 87.29 seconds, deeply verified, re-identified
as `app.portavoz.mac.dev`, installed only at `/Applications/Portavoz Dev.app`,
and observed at PID 59919 running from its exact executable. The notarized
`app.portavoz.mac` release remained byte-for-byte unchanged across its 184-entry
no-symlink-traversal content/metadata/hex-xattr manifest at SHA-256
`b9ee907d04eb473d803574ca4af87cc64014fc95305d3231a30ba3b0ab67a20d`;
its designated requirement and bundle ID stayed unchanged, its deep signature
remained valid, and Gatekeeper still accepted it as Notarized Developer ID.
Packaging again had no production CloudKit profile and no optional Metal
Toolchain `metallib`, so the installed Dev bundle supplies neither production
CloudKit nor real embedded-MLX evidence.

### Consented direct-Web Ask qualification (D387)

Package tests separate policy, orchestration, transport, parsing, persistence,
provider prompting, and presentation. Pure tests cover one-request consent
binding/consumption, source-change cancellation, maximum/duplicate/blank input,
ordered partial evidence, cumulative citation admission, raw-URL rejection,
timeout closure, late-output rejection, public-HTTPS versus loopback policy,
UTF-8/Unicode bounds, hidden-date exclusion, hostile boundary escaping, typed
HTTP/content/size failure mapping, and selected-engine isolation from meeting
identity. Gateway regressions prove exact body-free GET metadata, lowercase
headers, the 512 KiB boundary and first excess byte, while storage tests prove
content-free local/remote Web receipts, forged-metadata rejection, and v43 Ask
row preservation through v44. Router and Ollama-adapter cases additionally
prove Web evidence never enters a meeting passage call and uses the distinct
`public-web-answer-material` loopback classification. Corrupt provider identity
and non-finite receipt time fail closed rather than surfacing as privacy truth.

One autonomous integration case runs the real `URLSessionDataEgressGateway`,
`MeetingStore`, direct-page adapter, and parser against the canonical Python
server on an ephemeral IPv4-loopback port. Hosted package lanes use
`scripts/run-swift-tests.sh` to own that process outside XCTest and inject only
its atomic content-free descriptor; a direct local `swift test` retains the
same validated process-owning fallback. The case covers fresh EN/ES, stale,
undated, hostile prompt injection, blocked redirect, 503, partial response,
disconnect, and slow cancellation. Every attempt—including failures and
cancellation—leaves only content-free host/policy receipt evidence. It needs no
Internet, provider account, user meeting, or private transcript.

The existing Ask XCUITest journey is extended rather than duplicated. Only
when the selected scope contains that Web journey, the shell runner validates
the canonical public fixture after its shared build and forwards its exact
base64 payload. It never opens a loopback listener. The test runner and
temporary-store app independently enforce the 12 KiB encoded ceiling, exact
checksum, schema, generation, public-synthetic marker, IPv4-loopback origin,
and 14-route count. Temporary-store composition installs a fixture
`URLProtocol` only for this explicitly opted-in journey; production and every
unrelated UI-test launch cannot. The journey still crosses the
real receipt-backed `URLSession` gateway, direct-page parser, model, and UI,
then enters a localized EN/ES question and page, proves submit is disabled
before consent, asserts the cited deterministic answer plus 2026 freshness and
Web source badge, proves consent was consumed, and continues exact-meeting
answer/citation/seek. The direct Link is asserted but not opened, so the test
never launches a browser or leaves the controlled fixture.

The finalized tree passed the current-SDK first-party warnings-as-errors build,
69/69 focused D387 tests, and the complete 2,693-test Swift package with 15
explicit environment/model skips and zero failures in 129.579 seconds of XCTest
execution. All 214 architecture/commitment-source-link tests passed after
the combined cleanup literal was updated to retain the historical keyboard-
restoration invariant. All 501 tooling tests passed in 23.811 seconds, including
fixture start/no-start scope, descriptor forwarding, cleanup, UI catalog,
duplicate/orphan/unscoped selector, blind-sleep, and runtime-budget policy.
Repository hygiene, both localization catalog parses, diff whitespace checks,
and strict SwiftLint across 720 Swift files also passed.

Because localization, shared harness, and otherwise unknown production paths
changed, `make test-ui-changed UI_BASE=HEAD` expanded fail-safe to the complete
catalogue in both locales. One 12-second build was reused and the locales ran
sequentially without retries. Final macOS 26.5.2 (25F84), arm64 result bundles
passed 105/105 English plus 105/105 Spanish real-app cases. English recorded
1,103.318 seconds of test duration, 1,126 seconds wall time, 20.698 seconds p95,
and a 89.546-second maximum; Spanish recorded 1,100.502 seconds of test
duration, 1,126 seconds wall time, 20.695 seconds p95, and a 90.874-second
maximum. Both content-free receipts passed every aggregate and per-case budget,
and the fixture descriptor was absent after runner cleanup.
After the final source-change cancellation and exact-date-attribute fixes, the
minimum-safe Web journey was rerun from one shared build without retries: 1/1
English in 18.715 seconds and 1/1 Spanish in 16.523 seconds, with both runtime
budgets passing.

The Release bundle completed one clean 93.59-second build and a final
15.16-second incremental rebuild, was deeply verified, re-identified as
`app.portavoz.mac.dev`, installed only at `/Applications/Portavoz Dev.app`, and
observed at PID 25956 running from its exact executable. The notarized
`app.portavoz.mac` release remained byte-for-byte unchanged across its 184-entry
no-symlink-traversal content/metadata/hex-xattr manifest at SHA-256
`b9ee907d04eb473d803574ca4af87cc64014fc95305d3231a30ba3b0ab67a20d`;
its designated requirement stayed valid and Gatekeeper still accepted it as
Notarized Developer ID. Packaging again had no production CloudKit profile and
no optional Metal Toolchain `metallib`, so this installed Dev bundle does not
provide production CloudKit or embedded-MLX runtime evidence.

Scoped changed-file evidence remains mandatory per band; complete bilingual
XCUITest remains the integration/RC gate. Automation does not certify DNS
behavior, arbitrary Internet pages, installed-model quality, physical
Sequoia/Tahoe, VoiceOver/Voice Control, CloudKit, distribution, or field
behavior.

### Pull-based cited interview assistance (D388)

Pure policy tests cover current-question selection across delayed callbacks,
partial and microphone-only question rejection, 24-row candidate and eight-row
evidence ceilings, chronological evidence order, same-meeting ownership, finite
closed intervals, transcript-progress expiry, and character plus UTF-8 budgets.
Application tests execute the canonical public/synthetic EN/ES interview corpus
through the production use case, including supported answers and abstentions;
they reject missing, forged, partially forged, malformed, or sentence-local
missing citations before provider prose reaches presentation. Typed unavailable,
failure, timeout, cancellation, invalid injected contexts, and provider bypass
are separate regressions. Main-actor model cases prove question revision and
disable cancel work, stale completions cannot publish, and unavailable selected
engines remain visible and retryable. Router and objective tests preserve exact
selected-engine passages plus the eight-row / 280-character / 2,048-byte input
limits.

The `recording-interview` XCUITest scope owns one complete real-app journey per
selected locale rather than several overlapping microtests. It launches the
temporary store with deterministic canonical captions and a deterministic final
answer adapter, starts a disposable recording, explicitly enables Interview,
asserts the exact localized current question, adds one bounded objective,
requests an answer, and verifies both grounded prose and the exact cited source.
It uses the production start-recording workflow, question/evidence policy,
application answer use case, selected-engine bridge, presentation model, and
SwiftUI accessibility surface without a private meeting or installed model.
Changed interview sources select this one journey; recording-toolbar or generic
recording changes conservatively compose it with their other owned journeys,
while localization/shared-harness changes still expand fail-safe. The catalogue
and runtime-budget policy expect 106 cases and reject an unscoped or orphaned
interview journey.

The final package gate executed 2,707 tests with 15 environment-gated skips and
zero failures in 117.041 seconds of test time (117.204 seconds wall time).
Current-SDK first-party warnings-as-errors built cleanly in 28.21 seconds; the
only emitted warning was FluidAudio's dependency-owned unhandled
`benchmark.md`. Strict SwiftLint passed across all 724 production Swift files,
the complete tooling gate passed 502 tests in 23.091 seconds, repository
hygiene and String Catalog validation passed, and the changed-file selector
validated a fail-safe 106-case English plus Spanish expansion before XCUITest.

The final post-hardening Interview Assist real-app journey passed 1/1 English
in 15.700 seconds and 1/1 Spanish in 14.936 seconds, with one shared build and
no retry.
The complete integration gate then reused one build and ran locales
sequentially: 106/106 English passed in 1,114.763 seconds of test time (1,138
seconds wall, 7.088-second p50, 19.758-second p95, 91.601-second maximum), and
106/106 Spanish passed in 1,113.266 seconds of test time (1,139 seconds wall,
7.160-second p50, 20.143-second p95, 89.924-second maximum). Both content-free
runtime receipts passed their budgets with zero failures, skips, expected
failures, or retries. This deterministic macOS 26.5.2 Tahoe-family evidence is
not physical Sequoia/Tahoe, assistive-technology, installed-model, private-
meeting, CloudKit, distribution, or field evidence.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was then rebuilt, deeply
verified, installed only at `/Applications/Portavoz Dev.app`, and observed at
PID 85448 running from its exact executable. A fresh before/after comparison
kept the notarized `app.portavoz.mac` release bundle byte-for-byte unchanged
under the same 184-entry no-symlink-traversal lstat/content/hex-xattr manifest
schema at SHA-256
`b77ec3a0c28a2fec10a1be83990b950fac0dd450fffad17f8f26318805cf4dc0`;
its bundle ID and designated requirement also stayed unchanged, its deep
signature remained valid, and Gatekeeper still reported Notarized Developer
ID. The Dev bundle is local-only because no CloudKit profile was supplied, and
the absent optional Metal Toolchain means this install contains no MLX
`metallib`; neither limitation was silently converted into release evidence.

### Typed raw-note Ask (D389)

Storage integration tests create a clean v45 library, migrate a file-backed
v44 library with an existing note, reopen it, and prove exact backfill. They
exercise insert/update/tombstone triggers, meeting tombstones, raw-note-only
kind filtering, structural exclusion of `enhancedNote`, hostile FTS input,
corrupt UUID and offset rejection, deterministic limits, 2,000-note search,
and 32 concurrent bounded reads. A real retrieval case proves early English
lexical evidence can be followed by the Spanish bilingual variant in the one
fused set rather than ending search after the first hit.

Application tests cover exact cited-answer subsets, marker stripping,
answer/abstention through the canonical public-synthetic English and Spanish
note corpus, no evidence, unavailable provider, failure, timeout, caller
cancellation, forged or missing sentence markers, evidence mismatch, duplicate
identity, invalid time/title/provenance budgets, 40 concurrent cancellations,
and zero late success. Prompt/provider tests preserve typed author/time/meeting
material, isolate escaped prompt-like note text inside untrusted-data elements,
enforce aggregate character/byte limits, and prove the selected MLX/Ollama
adapters receive only `RAGNotePassage`. Presentation and router tests prove
Notes never calls transcript/Web methods and that source changes fence late
evidence and completion.

The existing full-Ask XCUITest journey now exercises Web, Notes, and one exact
meeting in the same disposable real-app launch. It verifies the raw-note-only
disclosure, pending and final Notes source badges, localized `You`/`Tú` authorship,
the exact `Test meeting · 00:12` source, and a generated answer with markers
removed before continuing the released exact-meeting replacement/citation-seek
journey. No duplicate UI case or launch was added. Typed Notes lower layers map
only to the consolidated Ask scope; shared citation/provider files additionally
map to Interview Assist. Localization and shared seed changes retain the
complete bilingual fail-safe.

The final package gate executed 2,734 tests with 15 environment-gated real-
asset skips and zero failures in 121.198 seconds. Current-SDK first-party
warnings-as-errors built cleanly, strict SwiftLint reported zero violations
across 729 Swift files, the complete tooling discovery passed 504/504 tests in
23.490 seconds, and repository hygiene, String Catalog validation, and diff
checks passed. The changed-file catalogue was complete at 106/106 cases and
selected the required English-plus-Spanish fail-safe expansion.

The consolidated Ask journey passed 1/1 English in 21.306 seconds and 1/1
Spanish in 19.358 seconds with one shared build and no retry. The complete
real-app integration gate then reused one build and ran locales sequentially:
106/106 English passed in 1,117.181 seconds of test time (1,141 seconds wall,
7.036-second p50, 20.549-second p95, 90.149-second maximum), and 106/106
Spanish passed in 1,118.177 seconds of test time (1,144 seconds wall,
7.354-second p50, 20.707-second p95, 91.341-second maximum). Both content-free
runtime receipts passed their budgets with zero retries.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was then rebuilt, deeply
verified, installed only at `/Applications/Portavoz Dev.app`, and observed
running from its exact executable at PID 37737. A fresh before/after comparison
kept the notarized `app.portavoz.mac` release bundle unchanged across its 184-
entry no-symlink-traversal lstat/content/hex-xattr manifest at SHA-256
`7c0fc2e97f0dbe5894d2b2d082f65c3e76ab8b549fd33aed2356f5adef1c98c8`;
its bundle identifier and designated requirement stayed unchanged, its deep
signature remained valid, and Gatekeeper still reported Notarized Developer
ID. The Dev bundle remains local-only because no CloudKit provisioning profile
was supplied, and the absent optional Metal Toolchain means this install has no
MLX `metallib`; neither limitation is release or real-model evidence.

This autonomous evidence uses no private meeting, Internet, account, or
installed model and does not certify physical Sequoia/Tahoe, VoiceOver/Voice
Control, production CloudKit, notarized distribution, real model
quality/latency/memory, or field-note behavior.

### Bounded proactive assistance qualification (D390)

Nine pure policy cases cover exact objective evidence, the measured talk-
balance threshold, insufficient conversation, signal deduplication plus the
global interval, objective-to-balance priority, malformed/cross-meeting/
duplicate/noncanonical/non-final/invalid-time/oversized caption rejection,
unique bounded canonical same-meeting mutable-tail and presentation-safe
timeline/duration authority, invalid objective and throttle authority, and
bounded work over a 2,000-row meeting.
Three main-actor model cases cover explicit opt-in, pause/resume,
disable clearing, reset, dismissal without replay, the three-card cap, and
objective-card retraction while paused. The implementation contains no task,
model, URLSession, Web, persistence, or external-effect path.

The existing objectives/next-question/talk-balance XCUITest journey is extended
rather than duplicated. One deterministic real-app capture mode preserves the
same 18-row bilingual fixture while giving finalized turns realistic elapsed
spacing. The journey proves the panel is absent before explicit opt-in, an open
Spanish objective produces one exact 16-turn `00:40–05:45` source, pause keeps
the card visible, resume restores observation, disable clears the panel, and
re-enabling the same recording does not replay the emitted signal. The existing
objective, next-question, translation, HUD, and talk-balance assertions remain
in the same launch.

Architecture ratchets pin the two declared signals, 64-row source bound,
three-card presentation bound, 180-second throttle, same-meeting identity
checks, synchronous lifecycle ownership, Start/Stop/next-session reset paths,
stable accessibility identifiers, deterministic and repeated recording/release
gate membership, and durable D390 truth. Changed-file scope
maps the policy/model only to the consolidated recording-recovery feature;
localization or shared harness changes still expand fail-safe to complete
bilingual XCUITest.

The post-review deterministic gates pass 2,747 Swift tests with 15 explicit
installed-asset/environment skips and zero failures, 507 tooling cases, strict
SwiftLint with zero violations across 731 files, repository hygiene, and 25/25
recording-stress iterations with 237 focused cases each. The consolidated real-
app journey passed once in English in 14.884 seconds and once in Spanish in
12.926 seconds from one build, sequentially, with no retry.

The complete bilingual gate initially produced honest red host and runtime
evidence rather than a green retry. One invocation passed 36 of 106 cases,
including the D390 journey, before macOS revoked UI-test accessibility authority;
the remaining 70 launches failed uniformly as unauthorized without a Portavoz
crash. A fresh diagnostic received authorization and later lost it, and another
invocation lost authorization during its first unrelated case. Once the host was
authorized and clean, the first complete English product catalogue passed all
106 assertions but the runtime policy rejected two Skills journeys: confirmed-
receipt control took 81.529 seconds against 80.796, and Waiting source review
took 39.086 seconds against 24.924. That result bundle and receipt remain
preserved as red evidence.

The correction did not raise either budget or weaken stable activation. Async
Skills projections now prove accessibility-tree existence before geometry,
assert the bounded scroll result, and retain a stable-frame gate only for the
controls that are clicked. A one-build focused rerun then passed both routes in
English at 62.390/15.749 seconds and Spanish at 59.449/15.580 seconds. The final
uncontaminated complete gate reused one build and ran locales sequentially with
no retry: 106/106 English passed in 1,118.415 seconds of test time (1,131 seconds
wall, 7.320-second p50, 19.414-second p95, 93.138-second maximum) and 106/106
Spanish passed in 1,120.285 seconds (1,140 seconds wall, 7.280-second p50,
19.764-second p95, 92.327-second maximum). Both content-free receipts report
`budgetStatus: passed` with no violations. The formerly red routes remained
inside policy in the complete catalogues at 60.346/14.720 seconds in English and
59.611/15.497 seconds in Spanish.

The read-only D344 preflight rejects public process-agnostic Secure Input state
before paying the build, while still reading no prompt, exposing no owner,
terminating no process, and changing no TCC or test service. It cannot reserve
the host after its final sample, so any later system authorization change still
invalidates that run rather than becoming product evidence.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was then rebuilt with its
MLX Metal library, deeply verified, installed, registered, and opened only at
`/Applications/Portavoz Dev.app`. A before/after comparison kept the notarized
`app.portavoz.mac` release bundle identical across its 184-entry no-symlink-
traversal metadata/content/hex-xattr manifest at SHA-256
`22ff1d9adfc20206c96c0e75c886dba1d031a94e0dff399a102c3ea266a20adb`;
its bundle identifier and designated requirement stayed unchanged, its deep
signature remained valid, and Gatekeeper still reported Notarized Developer
ID. The Dev bundle remains local-only because no CloudKit provisioning profile
was supplied; neither the successful Metal build nor local Developer ID signing
is installed-model, production CloudKit, notarized-distribution, or model-
quality evidence.

This repeatable lane needs no private meeting, Internet, account, Foundation
Models asset, or provider. It does not certify physical Sequoia/Tahoe,
VoiceOver/Voice Control/Full Keyboard Access, production CloudKit,
signed/notarized distribution, installed-model or ASR quality, long-call memory,
or real-meeting usefulness; those remain separate 1.0 admission evidence.

### Bounded post-RRF fact-aware selection (D286)

Seven pure selector cases prove the fixed 6-transcript/4-fact/8-additional-
source production bounds, transcript-prefix and graph-prefix order, facts never
outnumbering transcript citations, zero-cost exact overlap, whole-fact source
atomicity, typed budget exhaustion, disclosure matching, policy validation,
and idempotent reselection. One workflow case proves only the bounded input
reaches generation while the answer retains the full evidence bundle. Two
IntelligenceKit cases prove exact transcript-marker reuse without duplicate
source material and fail-closed forged disclosure; the existing typed-prompt
case also pins selection and omission disclosure. One architecture ratchet
pins post-RRF ownership, production bounds, dependency direction, source-marker
reuse, typed exhaustion, and absence of Presentation adoption. These eleven
cases use no model, network, user library, SwiftUI, XCUITest, or screenshot.

### Complete graph product truth, scale, and profile recovery (D308–D314/D360)

The decision-history, decision-conflict, and change-since adapters
have deterministic focused tests plus all 18 canonical product mappings. The
local graph-fact route switch and exact filter suite exercise all six job kinds;
decision queries derive aboutness only from confirmed decision-topic links and
never from meeting co-occurrence. Paging tests prove candidate counting stays
bounded before evidence hydration, and mutation tests break if current-only or
temporal-anchor rules are removed.

Meeting Detail package tests cover composed confirmation and topic retraction.
The real-app bilingual journey confirms a decision, observes the topic-bearing
badge, withdraws that exact link through its stable accessibility identifier,
and verifies that the decision remains confirmed without the topic. This is UI
evidence for the shipped authority gesture, not proof of VoiceOver quality on a
physical Sequoia or Tahoe host.

The Release scale harness executes every job for 30 samples at 10,000 meetings:
2.3...76.1 ms p95 against 250 ms, recursive family/chain probes under 6 ms,
119 MB database size, and under 6 MB physical-footprint delta. Full-reset
throughput was then fixed from 17.6 minutes to 27.2 seconds on the same
deterministic fixture. Always-on tests preserve edge provenance, correction
awareness, bidirectional same-generation profile-reset determinism,
checkpoint/resume, and recursive-family behavior. D360 adds focused regressions
for a previously succeeded canonical profile, a cancelled target, and terminal
failure exclusion: the same durable operation becomes pending only while the
graph still requires it, attempt state restarts bounded, the source generation
does not change, all authority-keyed edge sets reproduce exactly in both
directions, the first partial reset clears later decision-topic edges, and a
failed row cannot bypass its attempt ceiling. These results select SQLite and
reject a specialized graph-engine migration; they do not supply private owner-
reviewed field evidence, accepted supported-host timing receipts, free-form
graph-aware Ask, sync/export, or CLI/MCP adoption. D361–D366 separately release
all six exact query surfaces, and D367 observes their local runtime timing.

### First released exact graph query surface (D361)

Five presentation-model cases prove that canonical-person search rejects a
stale generation, requests 21 rows, publishes at most 20 plus overflow, fails
closed if its client exceeds that bound, and selects only an exact current
candidate; that a selected person maps one
validated active commitment and its primary citation without losing typed page
disclosure; that a wrong-person fact fails closed while `projectionNotReady`
remains a typed abstention; and that a pending local read cannot retain a
closed per-window model. One architecture ratchet pins
the protected ApplicationKit composition, exact `PersonID`, maximum 100-fact
read, synthesis-page validation, absence of a model/bundle/filter dependency,
stable accessibility identifiers, disposable real graph fixture, honest docs,
and remaining product/field gaps.

One real-app XCUITest per locale launches a temporary store, confirms an exact
Ana commitment through the real authority, projects the disposable graph,
opens full Ask, selects **By person**, loads the exact typed fact, and follows
its exact evidence to 00:03. The journey does not touch the user library or
invoke Foundation Models. It proves the released Sequoia/Tahoe-compatible code
path and localization contract, not physical VoiceOver, clean-install
Sequoia, separate-hardware Tahoe, private-corpus quality, or accepted
supported-host graph performance evidence.

### Second released exact graph query surface (D362)

Three catalog cases prove normalized/bounded request validation, exact
ApplicationKit delegation, literal wildcard escaping, stable limiting, and
merged-alias resolution to one live root without whole-catalog Swift
hydration. Five presentation-model cases prove 21-to-20 overflow, stale-search
fencing, oversized-response fail-closure, exact topic selection, maximum
100-row decision serving, synthesis and typed-relationship validation,
wrong-topic/unready handling, and non-retention of a closed model. A dedicated
architecture ratchet pins the catalog/application/storage boundary, exact
`TopicID`, absence of model inference, stable accessibility identifiers, real
confirmation fixture, honest docs, and remaining product/field gaps.

One real-app XCUITest per locale launches a temporary store, saves the fixed
summary observation, confirms it about the exact `model rollout` topic through
`ConfirmDecisionAboutTopic`, projects the disposable graph, opens **By topic**,
loads the current decision, and follows its exact evidence to 00:03. It uses no
user library, network, or Foundation Models. This proves the executable
localized Sequoia/Tahoe-compatible code path, not physical VoiceOver,
clean-install Sequoia, separate-hardware Tahoe, private-corpus quality, or
accepted supported-host graph performance evidence.

### Third released exact graph query surface (D363)

Four presentation-model cases prove that the exact selected `TopicID` crosses
the first-discussion boundary; that the one returned topic-to-meeting fact,
meeting identity, single primary source, and meeting-relative occurrence time
are preserved; that pagination, wrong-topic, wrong-meeting, and inconsistent-
time responses fail closed; that changing jobs fences a late response; and
that a pending first-discussion read cannot retain a closed window model.
The existing topic-search cases continue to cover bounded selection and closed-
window non-retention. One architecture ratchet pins production composition,
job-specific completeness validation, stable accessibility identifiers,
fixture reuse, bilingual XCUITest, and honest remaining gaps.

One additional real-app XCUITest per locale launches the temporary store,
confirms and projects the same exact `model rollout` topic evidence, opens **By
topic**, switches to **First confirmed discussion**, and follows its only exact
source to 00:03. It uses no user library, network, Foundation Models, or Tahoe-
only API. This is executable bilingual regression evidence on the local host,
not physical VoiceOver, clean-install Sequoia, separate-hardware Tahoe, private-
corpus quality, or accepted supported-host graph performance evidence.

### Fourth released exact graph query surface (D364)

Three new presentation-model cases prove that the selected `TopicID` crosses
the decision-conflict boundary at the existing 100-fact maximum; that one
confirmed successor-to-replaced relationship preserves both endpoint
identities, statements, ordered source evidence, and successor primary source;
that oversized, wrong-kind, self-referential, one-source, missing-primary,
blank-statement, wrong-status, and wrong-identity pages fail closed; and that
changing jobs fences a late conflict result. Existing topic-search,
first-discussion, and closed-window tests keep their cancellation and retention
contracts load-bearing.

One architecture ratchet pins the existing ApplicationKit/StorageKit query,
exact topic-only app composition, two-source presentation boundary, stable
accessibility identities, real confirmed-relationship fixture, UI-impact scope,
tracked documentation, and remaining gaps. One additional real-app XCUITest per
locale opens **By topic**, selects **Decision changes**, verifies the successor
and replaced Spanish statements plus both exact evidence actions, and follows
the successor source to 00:03. It uses a disposable temporary store, no network,
no user library, no Foundation Models, and no Tahoe-only API. This is local
bilingual regression evidence, not physical VoiceOver, clean-install Sequoia,
separate-hardware Tahoe, private-corpus quality, or accepted supported-host
graph performance evidence.

### Fifth released exact graph query surface (D365)

Four new presentation-model cases prove that only one current commitment from
the selected person's validated result can cross the blocker boundary at the
existing 100-fact maximum. They preserve exact decision/blocker/commitment
identities, authoritative text, disclosure, all current sources, and the
blocker primary source; accept one source when authority deduplicates to that
same segment; reject oversized, wrong-kind, wrong-entity, wrong-commitment,
wrong-title, wrong-status, and missing-primary pages; start no read for an
unknown commitment; and fence a late result after commitment selection changes.

One architecture ratchet pins the existing ApplicationKit/StorageKit query,
exact current-commitment app composition, no unconditional two-source rule,
stable leaf accessibility identifiers, temporary-store-only explicit
authority fixture, UI-impact scope, tracked documentation, and the remaining
product/field gaps. One additional real-app XCUITest per locale
opens **By person**, loads one exact commitment, loads its active blocker,
verifies the Spanish decision and commitment plus both exact evidence actions,
and follows the blocker-confirmation source to 00:04. It uses disposable
synthetic audio, no network, no user library, no Foundation Models, and no
Tahoe-only API. This is local bilingual regression evidence, not physical
VoiceOver, clean-install Sequoia, separate-hardware Tahoe, private-corpus
quality, or accepted supported-host graph performance evidence.

### Sixth released exact graph query surface (D366)

Five new presentation-model cases prove that the meeting-anchor catalogue
requests 21 newest-first rows, publishes at most 20 plus overflow, ignores stale
search generations, and fails closed on oversized or invalid temporal data.
They prove only the selected exact `MeetingID` crosses `ChangeSinceQuery` beside
the selected exact `TopicID` at the existing 100-fact maximum; the shared strict
relationship synthesis preserves both endpoints, both exact sources, and the
successor primary source. Anchor changes fence late fact pages, and an in-flight
catalogue read cannot retain a closed Ask window.

One architecture ratchet pins reuse of the protected `LoadAutomationEntities`
meeting catalogue and existing `LoadChangeSince`, the 21-to-20 bound, exact
topic/meeting identities, four-dimensional publication fence, shared strict
relationship validation, native radio-group UX, unique speakable accessibility
labels, stable leaf identifiers, temporary-store fixture, UI-impact scope,
tracked documentation, and honest remaining broader product/field gaps.

One additional real-app XCUITest per locale opens **By topic**, selects
**Changes since**, searches and selects the exact **Planning baseline** meeting,
verifies both Spanish decision statements and both exact source actions, and
follows the successor source to 00:03. It uses a disposable store, no network,
no user library, no Foundation Models, and no Tahoe-only API. This is local
bilingual regression evidence, not physical VoiceOver, clean-install Sequoia,
separate-hardware Tahoe, private-corpus quality, or accepted supported-host
graph performance evidence.

### Content-free exact graph query telemetry (D367)

Six focused package tests pin the closed six-job taxonomy and four terminal
outcomes, distinguish fact pages from typed abstention, classify cancellation
separately from operational failure, and inspect only random trace identity,
job, and outcome. A fixed repository proves that all six released use cases
emit their stable job. Alias tests prove zero query events for missing or
ambiguous candidates and exactly one interval only after one exact person is
resolved. The app-adapter test registers and removes an observer explicitly,
then proves later events cannot reach the removed callback.

One architecture ratchet keeps the taxonomy closed and content-free, pins all
six use-case measurement boundaries plus exact-identity alias fencing, verifies
one app composition injection per released graph read, and restricts the
Points of Interest messages to job and outcome. It also binds implemented
architecture, intelligence, app, quality, decision, and gap truth so a future
payload, missing query, double wrapper, stale telemetry gap, or undocumented
composition change fails development tests.

D367 changes no UI, localization, accessibility identifier, schema, query
result, or graph authority, so it adds no new UI test case. The mandatory full
English and Spanish 101-case XCUITest gates still qualify the existing product
journeys after composition changes. Local signposts and synthetic relational
budgets do not certify clean-install Sequoia, separate-hardware Tahoe, physical
VoiceOver, private-corpus behavior, or accepted supported-host latency receipts.

### Product-path graph query timing receipt (D368)

Seven focused package tests pin explicit output/run/iteration bounds, stable
six-job order, nearest-rank wall and CPU p50/p95/maximum arithmetic, and absence
of trace UUIDs or fixture text. Duplicate, unmatched, incomplete, late,
non-factful, missing, and incorrectly counted events fail closed. Unsupported
host readiness and fixture generations are rejected, while output is mode 0600,
atomic, and non-replacing.

Seven deterministic tooling tests validate the assembled receipt and runner:
bounded required shell arguments, real-identity forwarding plus ad-hoc
rejection, exactly three or more contiguous runs,
identical host and iteration evidence, exact closed
objects, duplicate-key and non-finite rejection, monotonic summaries, fact-only
jobs, lowercase full source SHA, and private non-replacing publication. One
architecture ratchet binds process isolation, public fixture flags, disabled
post-seed search reconciliation, production ApplicationKit use cases, the
six-minute deadline, clean-worktree Release collection, separate bundle
identity, strict assembler, documentation, and honest evidence limits.

D368 changes no product UI, copy, localization, accessibility identity, schema,
graph authority, or query behavior. The mandatory full English and Spanish
101-case XCUITest gates therefore remain regression qualification rather than a
new journey. A local Tahoe collection is only one-host evidence; accepted
Sequoia plus Tahoe and cross-hardware receipts, physical VoiceOver, private
owner-reviewed behavior, and any latency-policy decision remain external.

Local: `swift build -Xswiftc -warnings-as-errors` then `swift test` (if it fails
with "no such module": `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test` — xcode-select points to CommandLineTools). XCTest, not Swift
Testing (D13/D118).

## UI tests — `Tests/PortavozUITests/` (`make test-ui`, D30)

Disposable launches isolate auxiliary sensitive state as well as SQLite:
Settings and Meeting Detail never inspect the host participant-voice gallery
or its Keychain key while `-use-temp-store` is active.

`scripts/ui_test_scope.py` is the executable PR-impact policy for all 105 UI
tests. Each test belongs to a feature scope. Known app and application files
select only the scopes they can affect; a changed UI-test file selects its own
class; localization and shared-harness changes select the complete bilingual
catalogue; the
macOS 14 transcript-scroll bridge selects only recording-recovery evidence; and
an unknown production Swift path selects the complete English suite. Docs,
governance, site, CLI, and package-test-only diffs select no UI runner. Catalog
validation fails for an added or renamed unscoped test, empty or duplicate
scope, missing production owner, retired known-overlap journey, or missing/stale
runtime budget. The selector never truncates tests or locales. Only its
diagnostic reason summary is bounded to 16 KiB at complete-entry boundaries;
an omitted count and SHA-256 preserve deterministic identity without passing a
historical integration diff as one oversized Linux environment string.
Standard-library unit tests characterize skip, targeted,
bilingual, harness, and conservative-fallback behavior. `make test-ui-changed` consumes that
policy locally against committed, staged, unstaged, and untracked paths, so a
pre-commit smoke cannot silently select nothing; `UI_HEAD` remains an explicit
committed-range override. Pull-request `synchronize` events use the immediately
previous PR head as their base; opened or reopened PRs keep the repository base,
an unavailable force-pushed previous object expands safely from that base, and
manual integration dispatches still select the full catalogue.
`scripts/run-ui-tests.sh` performs one `build-for-testing` and
reuses it with `test-without-building` for each selected locale, retaining an
xcresult and a content-free runtime receipt per locale under ignored
`dist/ui-test-results/`. The receipt contains only test identity, result,
duration distribution, build/wall duration, and budget verdict. It rejects a
scoped result whose case count differs from its selector count, a full result
that differs from the 105-case catalogue, an explicitly selected 105-case run
that violates aggregate gates, duplicate/missing-budget cases, non-finite or
negative timings/budgets, unreadable inputs, and per-journey or full-suite
runtime regressions. A failed XCTest pass still attempts a content-free receipt
without masking XCTest's exit status. Each explicit locale
is also forwarded into the test-runner process so localized assertions and app
launch arguments stay aligned with `-testLanguage`. An empty selector is an
explicit complete-suite request. Optional selector and locale arguments are
assembled without expanding empty arrays under macOS Bash 3.2; tooling tests
cover complete, scoped, and default-locale runner arguments. Full
`make test-ui-bilingual` remains mandatory for release and architecture
closure. Feature work uses the minimum-safe `make test-ui-changed` or explicit
scope; the complete bilingual lane is reserved for integration, RC, release,
localization, or shared-harness qualification. Locales remain sequential because
naive parallel XCUITest contends for host-wide services and corrupts the timing
signal. An unchanged green retry never replaces diagnosis of an initial red run.

The shared UI support evaluates bounded state immediately and then polls through
the main run loop at short intervals, avoiding XCTest's roughly one-second first
predicate poll and every fixed sleep. Inequality and negative-label waits also
require existence, so a missing accessibility element cannot satisfy them.
Moving controls must keep a stable hittable frame before activation. Skills
Settings scrolls according to the target's measured distance from the real form
viewport in at most six bounded gestures. An asynchronously projected target
must first prove accessibility-tree existence before the geometry helper reads
its frame; callers assert that the bounded scroll succeeded, retain the stable-
frame gate for controls they activate, and use existence alone for a
noninteractive navigation destination. Three proven launch overlaps were
removed without deleting their assertions: two Insights microtests became one
dashboard journey, three sequential onboarding microtests became one journey,
and the exact-Skill filter assertions joined the existing period/filter/reset
journey. The 105-case catalogue is therefore smaller while behavior coverage is
retained. An atomic seed snapshot was evaluated but not introduced: current
measurement showed repeated accessibility waits and fixed scrolling, not seed
construction, as the dominant cost, and duplicating SQLite fixture authority
would add migration risk without measured justification.

Feature fixtures with a required intermediate state do not simulate slowness.
Ask cancellable empty retrieval, lexical evidence, and partial answers plus
Skills receipt/proposal refreshes use UUID-scoped ready/continue files only
under `-use-temp-store`. The app
accepts them only as direct children of the process temporary directory,
removes both files after each release, checks cancellation every 50 ms, and
fails after 600 probes instead of falling back to a timer. XCUITest owns each
release only after asserting the corresponding visible state. Ordinary
temporary-store journeys omit the handshake argument and therefore pay no
artificial delay. Signal construction uses the app's private launch `TMPDIR`;
the test-runner process has a different temporary root. The validator reads
that exact process environment value rather than Foundation's independently
resolved default, requires the launch directory to exist, and resolves its
symlink (for example `/private/tmp` versus `/tmp`) before requiring an exact
parent match. The runner fails immediately instead of silently falling back to
its own temporary directory when the app launch root is absent.

The D382 local macOS 26.5.2 (25F84), arm64, Xcode 26.6 comparison reduced the
like-for-like complete-catalogue duration from 2,591.999 to 1,108.209 seconds
in English and from 2,607.498 to 1,114.714 seconds in Spanish (57.2% per
locale). p95 fell from 51.218/50.210 to 20.265/20.678 seconds. The complete
English pass was 105/105; the first complete Spanish pass retained one genuine
asynchronous assertion failure, and the exact four changed journeys passed
4/4 in both locales after the bounded-disappearance fix. The checked-in gates
are 1,300 seconds per locale, 30 seconds p95, exact per-journey budgets, and a
60-minute sequential bilingual CI timeout. A later integration/RC gate still
runs a fresh complete bilingual catalogue; this one-host measurement is not
physical Sequoia/Tahoe or assistive-technology evidence.

## Autonomous Apuntador scenario authority

Routine assistant regression does not require private meetings. The canonical
`Fixtures/ApuntadorValidation/public-bilingual-v1.json` corpus contains exactly
one English and one Spanish source for each typed domain: meeting, interview,
and explicit user-authored note. Spoken passages preserve timestamps and
participants; notes preserve author/time and cannot invent audio timestamps or
participants; interviews additionally preserve one declared objective. Each
source has one supported fact and one adversarial rejected/negated distractor.
The fixture then freezes 24 scenarios: answer and abstention for every
kind/language pair, plus bilingual cancel-before-evidence, timeout, offline,
provider-down, corrupt-state, and relaunch outcomes.

`scripts/apuntador_validation.py` binds the exact fixture digest to
`docs/evidence/apuntador-validation-budget.json`. A runtime adapter must cover
every scenario exactly once and may retain only adapter/build/host identity,
stable claim/evidence identities, typed outcome, first-evidence/completion
timing, and a late-publication count. Non-answer terminal outcomes cannot carry
claims, citations, or a first-evidence timestamp. The aggregate scorecard gates
outcome accuracy, citation precision/evidence recall, claim precision/recall,
hard-negative and forbidden-claim exclusion, zero late publication, and exact
latency ceilings. It never contains source, question, transcript, note, or
answer text; prose quality, measured memory/leaks, real models, physical hosts,
and field behavior stay explicitly unevaluated until their separate lanes
supply evidence.

The canonical `Fixtures/ApuntadorWeb/public-local-v1.json` fixture and
`scripts/apuntador_web_fixture.py` make web behavior repeatable without the
Internet. The server binds only `127.0.0.1` on an ephemeral or declared port and
serves 14 strict routes: direct local citations; fresh, stale, and missing-date
documents; redirect; slow response; truncated body; 503 with Retry-After;
connection drop; fixed non-reflecting 404; and bilingual hostile prompt-
injection pages marked as untrusted data. Both cited bilingual fresh pages use
the fixture's bounded observable delay so the real-app journey can prove the
pending Web-source state before the final cited answer replaces it; the delay
is deterministic test authority, not a product sleep. Tests additionally prove
a closed listener produces the offline transport case. Canonical checksum
validation, strict route/status/date/link policy, no-store headers, atomic
content-free ready files, and deterministic teardown are part of `make
test-apuntador-validation`. The package shell owner retains a 30-second
failure-only startup ceiling, returns immediately on readiness, and closes the
child process, log, and temporary descriptor on success, failure, or
interruption. The package test validates exact generation/checksum, a 4 KiB
descriptor ceiling, positive process ID, and credential-free IPv4-loopback
HTTP origin before using that externally owned fixture; an invalid inherited
descriptor never falls back. XCUITest does not start this server: the runner
validates the same tracked fixture and forwards only its exact bounded payload
to a temporary-store-only `URLProtocol`. This avoids macOS 15 Local Network
Privacy prompts on launch-agent-owned hosted runners without granting,
dismissing, or automating a user permission. Real socket, partial-response,
disconnect, cancellation, and receipt behavior remains independently covered
by the package integration lane. This fixture is test infrastructure, not
product web authority or evidence that a real provider behaves the same way.

Sequoia's Xcode 26.3 image carries Swift 6.2.4, whose XCTest synchronous-test
teardown can abort while releasing a `@MainActor` value with `isolated deinit`
([swiftlang/swift#87316](https://github.com/swiftlang/swift/issues/87316)).
Every method in an `@MainActor XCTestCase` therefore uses XCTest's async method
convention even when its assertions are synchronous. This preserves production
cancellation deinitializers rather than weakening them for a test-runner defect;
a repository-wide architecture ratchet rejects new synchronous methods in those
test classes while Sequoia remains on the affected runtime.

Tests for delayed recording-level delivery and post-sheet focus restoration do
not sleep past a guessed host deadline. Their production owners inject a
structured sleep operation with the real continuous-clock behavior as the
default; tests use one cancellation-aware controlled suspension, observe the
exact requested duration, and resume or cancel the exact pending call. This
retains the real scheduling boundary while removing runner-load assumptions.

The local closure passed the current-SDK warnings-as-errors build, all 2,777
Swift tests with 15 explicit environment/model skips and zero failures in
115.571 seconds, all 688 tooling tests in 26.343 seconds, strict SwiftLint over
740 files, repository hygiene, and the 106-case scope catalog. The minimum-safe
real-app Web journey passed once in English (19.421 seconds) and once in Spanish
(19.870 seconds) from one shared build; both runtime receipts remained inside
budget and no Local Network permission was requested. This is local
Tahoe-family evidence. Because the repaired symptom existed only under a
launch-agent-owned hosted runner, exact-head hosted XCUITest remains required
before the repair is considered cross-host qualified.

The first hosted CI attempt for that exact local-network repair passed lint,
repository hygiene, and the complete current-SDK build/test lane. Its Sequoia
build also passed, but the Swift 6.2 process later exited with signal 11 after
all `MeetingDetailObservationTests` assertions had reported green. There was no
assertion failure or crash stack, so this evidence does not prove a GRDB leak.
It did expose a redundant shared forwarding `Task` around GRDB's
`AsyncValueObservation`, whose documented cancellation lifetime belongs to its
iterator. StorageKit now uses one pull-through `AsyncThrowingStream` adapter:
dropping a consumer releases the sole upstream iterator and cancellable. A
focused lifecycle test observes the actual GRDB cancellation callback and
released fetch closure, while an architecture ratchet rejects the former
task/continuation bridge. Local Swift 6.3 also released the old bridge, so the
runtime association remains explicitly unclaimed until a fresh exact-head
Sequoia lane judges the structured implementation. The structured closure
passed the current-SDK warnings-as-errors build in 20.21 seconds, all 2,779
Swift tests with 15 explicit environment/model skips and zero failures in
128.195 seconds, strict SwiftLint over 741 files, repository hygiene, and all
21 affected observation tests. Because the shared StorageKit path expands the
minimum-safe UI scope fail-safe, the mandatory real-app gate exercised all
106 English journeys from one build: 106 passed with zero failures, skips, or
expected failures in 1,095.145 seconds of test time and 1,119 seconds wall
(7.227-second p50, 19.541-second p95, 91.389-second maximum), with the runtime
budget passing. This remains local Tahoe-family evidence rather than proof that
the hosted Sequoia signal is closed.

Raw first-attempt logs from both `841045c` and `a7bebfe7` later corrected the
initial location: XCTest stdout had drained after the signal line. In both
independent Sequoia runs, all four observation tests completed and the final
started case without a pass record was
`MeetingMaterialPromptGuardTests.testTypedRAGContextKeepsFactsAndExactSourcesInSeparateMarkers`.
That test lived in a class annotated for macOS 26 and called a pure static
formatter on `RAGAnswerer`, yet SwiftPM/XCTest still discovered and ran it on
macOS 15 because `canImport(FoundationModels)` described the selected SDK, not
the host runtime. With no crash report, the exact Swift-runtime mechanism is
not claimed. The repeated location does prove that the GRDB observation bridge
was not the failing test and remains an independent structural hardening.

D406 moves all deterministic prompt instructions used by this guard, plus the
complete fact-aware formatter, below the Foundation Models import/availability
boundary. The production adapters consume those same pure values; the package
test contains no Foundation Models conditional or macOS-26 adapter reference.
One architecture ratchet pins both directions. Focused prompt coverage passed
6/6 and both affected architecture cases passed on the local macOS 26.6 Swift
6.3.3 toolchain. Moving the two intentional Spanish few-shot lines also moved
their English-source policy identity; the first full run correctly rejected the
stale path exceptions. The exception now admits only those exact lines at
`PromptFactory`, its focused policy regression passes, and the post-fix package
run passes 2,780 tests with 15 explicit skips and zero failures in 116.988
seconds of test time (117.188 seconds total). This is a reasoned portability
repair, not a claim that the hosted signal is closed; one first-attempt
exact-head Sequoia run remains the required proof.

The minimum-safe feature selector mapped the six changed IntelligenceKit
adapters/authorities to 39 real-app English journeys. One shared build passed
39/39 with zero failures, skips, or expected failures in 297.832 seconds of
test time; the content-free runtime receipt reported a 19.561-second p95 and
passed its scoped budget. The read-only preflight stayed clear for both samples.
This is local Tahoe-family evidence, not hosted Sequoia proof.

The independently running hosted UI gate for the preceding `a7bebfe7` head
completed its 106-case English catalogue rather than crashing. It failed four
unique journeys with nine assertion/follow-on failures: Interview Assist
objective visibility, Commitment Inbox evidence/review visibility, transcript-
correction sheet controls, and structural-correction split controls. The same
run took 1,637.884 seconds with a 37.295-second p95, exceeding both the
1,300-second suite budget and the 30-second p95 budget. These are exact
launch-agent-host accessibility/viewport and runtime findings; local green
evidence does not erase them, retries are not acceptance, and a separate
bounded portability repair remains required.

Full suites and the dedicated receipt-focus journey snapshot the host's global
`AppleKeyboardUIMode`, enable Keyboard Navigation for the test process, and
restore either the exact prior integer or the absence of the key through a
shell trap, including an ordinary test failure. Unrelated scoped runs never
mutate the preference. The receipt regression dismisses its native sheet with
Escape, then uses Space reopening the exact identified row as the observable
focus contract because macOS XCUI does not expose that SwiftUI row's focus
state reliably. Its sufficient-description accessibility audit rejects only
findings under identified Skills and receipt controls; hidden application
windows and unidentified native SwiftUI internals are outside that focused
gate.

`scripts/check-repository-hygiene.sh` independently rejects tracked agent,
design-sync, planning, ticket, report, generated-project, result-bundle, and
local screenshot state. It also rejects private tracker-key patterns in
implementation/test/tooling files while preserving public durable decision
references such as D116 and accepted architecture/specification truth under
`docs/`. The local `docs/ROADMAP.md` planning file — and the retired
`docs/refactor-20260714.md` and `docs/STRATEGY-20260716.md` it consolidated —
are ignored and rejected if tracked (D119).

The recording-recovery scope includes deterministic cold-model hot attachment:
`-simulate-live-transcription-attach` emits preparing, then available, and one
caption without loading a real model or touching host audio. Its bilingual UI
case proves the deferred notice clears and the same recording gains live text;
package tests independently prove newest-only buffer bounds, event order,
resident/cold/failure attachment, durable-recovery retention, and translation-
target cache invalidation.

The field-reliability scope injects a transient full-snapshot rejection, every
ordered Stop degradation rung, an exhausted projection path, invalid generated
Apuntador provenance, and both probe/real-Store same-pass recovery of a
content-bearing recording shell. Translation tests cover explicit mixed
Spanish/English lanes, same-target and uncertain rows, pair-scoped consent,
target switches, and stale publication fences. Caption-coalescer tests cover
both callback orders for speaker bleed plus distinct overlap and short
acknowledgements, including exact short copies versus sequential replies, and
the presentation projector proves generic `Them` rows never hide two unresolved
voices. Refine tests prove stale aggregate language never constrains
automatic recognition. Intelligence tests prove unknown action owners cannot
reach Markdown or typed projection. Pure visual-policy tests separate playback,
live follow, and fully sharp history. The temp-store-only
`-simulate-live-transcript-browsing` case appends six rows while the user
remains in earlier history, retains
`recording-live-transcript-history-paused`, then uses
`recording-jump-to-live` and observes the latest row.

Release reliability is evaluated separately from individual test success
(D147). `scripts/run-release-reliability-gates.sh` runs repository hygiene,
warnings-as-errors build, the complete package suite, strict SwiftLint, the 25-iteration
recording/recovery stress corpus, the exact mixed-language policy corpus, and
seven focused bilingual XCUITest journeys. It writes a deterministic receipt
only after every gate succeeds and binds it to the requested version, build,
and Git commit. `verify-distribution.sh --receipt` writes the signed-build
receipt only after the DMG and independently extracted app pass signature,
notarization, stapling, Gatekeeper, and production CloudKit capability checks.

`docs/evidence/reliability-gates.json` now requires 29 proofs across eight
classes. The original deterministic, signed-build, real-hardware, and user-field
cells remain. Schema 2 adds complete candidate automation, reviewed source
integration plus hosted CI, production-sync admission, and physical
assistive-technology cells for VoiceOver and Voice Control on Sequoia and
Tahoe. Candidate automation explicitly separates frozen scope, autonomous
Apuntador validation, installed-model coverage, authoritative performance,
resource/memory, synthetic long capture, upgrade/recovery, and complete
bilingual XCUITest.

`scripts/release_reliability.py evaluate` accepts only exact receipts and
protocol-2 field manifests for the same release identity. A qualification
receipt has one closed scope, every proof for that scope exactly once, no extra
keys, and the exact version/build/commit. Missing, failed, incomplete, or
not-observed evidence produces a blocking scorecard; only all-pass evidence
exits successfully. The distribution receipt additionally requires the commit
stamped into the app copied from the DMG, with a clean exact-source recheck
after the app build, and exposes that exact artifact digest on the final
scorecard. The owner-only JSON/Markdown output contains no meeting
reference or support payload. The field packager's production CLI reads exact
Mac product/build identity only from `/usr/bin/sw_vers` and accepts no version
override. Its in-process Python composition boundary admits an injected system
observer solely so Linux tooling tests can exercise complete privacy, shape,
and publication behavior without fabricating a command-line field receipt.
Twenty-four tooling tests cover complete,
omitted/missing-path, failed, incomplete, stale deterministic or qualification
commit, duplicate qualification scope/platform, content-bearing input,
authority-pair ownership including assistive evidence, distribution commit,
and invalid-contract behavior. The repository-hygiene
gate always runs them. An architecture ratchet pins the schema, 29 proofs,
eight classes, fail-closed predicate, exact artifact stamp, distribution
receipt ordering, D147, and D391.

**Reviewed source-integration owner (D402).**
`docs/evidence/source-integration-qualification.json` freezes one read-only
GitHub authority: `johnny4young/portavoz`, `main`, the versioned REST API, one
current independent human approval, the hosted `CI` push workflow, and the
`build-and-test`, `sequoia-compatibility`, `lint`, and
`repository-hygiene` jobs. `.github/workflows/source-integration-evidence.yml`
is manual-dispatch only and grants `actions`, `contents`, and `pull-requests`
read permissions. It accepts dispatch only from `main`, checks out trusted
`main`, and calls `scripts/source_integration_qualification.py`; it never runs
a caller-selected side branch with that token. The runner requires dispatch
ref, checked-out HEAD, `GITHUB_SHA`, requested release commit, and current
GitHub `main` head to be identical. Neither the workflow nor the script accepts
caller-supplied proof states or a replacement contract.

The runner queries the commit-to-PR, commit ancestry, PR-review, exact-SHA
workflow-run, and workflow-job REST authorities. Admission requires exactly
one non-draft PR merged to `main` as the release commit, at least one latest
human approval of the PR's exact head from an owner/member/collaborator, no
latest change request, one successful first-attempt `CI` push run, and exactly
one passing instance of each required job. Self/bot/outsider/stale/dismissed
reviews, any commit other than the exact current `main` head, multiple
unchanged runs, reruns, missing jobs, cancellation, or any metadata mismatch
fails before output. The
producer separately queries its own exact commit-titled dispatch and requires
the current in-progress run to be the only matching first attempt, preventing
a second dispatch from replacing the observation.
Successful output is a new mode-0700 directory containing mode-0600
`authority.json` and `qualification.json`. The authority report is
content-free: release identity, PR/review numeric IDs, CI run identity, and
fixed job names only. The qualification receipt carries its canonical digest,
and release evaluation rejects a copied-alone, renamed, missing, or drifted
sibling pair. Tooling and architecture tests pin output permissions,
review reduction, no-green-rerun policy, workflow permissions, immutable
action pins, and absence of a generic recorder. This producer proves neither
distribution nor CloudKit, hardware, assistive-technology, or field behavior.

**Production-sync exact-identity packaging (D403).**
The capability verifier reads the final app's Info.plist as well as signed
entitlements and the embedded profile. It requires `app.portavoz.mac`, one
nonempty `ApplicationIdentifierPrefix`, and a profile application-identifier
equal to `<prefix>.<bundle identifier>`. The build materializes the profile's
native macOS App ID and developer-team identity into the manual signing input;
the final signature, profile entitlements, prefix list, team list, and
Info.plist must agree. The legacy and namespaced profile
application-identifier keys may coexist only with the same value. The existing
single-container, exact signed CloudKit service, Production, production APNs,
profile-wildcard service, and expiry rules remain. Eighteen isolated verifier
cases plus four materializer cases cover the accepted direct-distribution
shapes and reject Dev identity,
missing Info.plist, foreign/missing/conflicting App IDs, missing prefixes,
expired profiles, malformed plist roots, missing CloudKit authorization, and
signed wildcard service, missing or foreign signed identity, team mismatch,
and hard-coded base identity without leaking a Python traceback.

`make-production-sync-qualification-app.sh` requires one clean exact
version/build/commit checkout, real identity, and profile. It invokes the real
release app builder, confirms profile-materialized production entitlements,
changes only display metadata, re-signs, and re-verifies the final exact-ID
artifact under `dist/`.
Four hermetic packaging tests use a temporary Git repository, fake signing
boundary, and strict `plutil`/BSD `sed` command adapters to prove the exact
metadata mutations on Linux as well as macOS. They cover exact stamping, final
verification, adjacent-commit rejection before build, failed-signature cleanup,
and the ordinary Dev install's profile rejection. Architecture
tests additionally forbid `/Applications`, LaunchServices registration, or
ordinary opening from this script. This evidence validates packaging behavior;
it does not execute CloudKit, prove a second Mac/account/push path, or create the
release qualification receipt.

**Staged production-sync owner (D404).**
`ProductionSyncQualificationTests` exercises exact hidden-mode argument admission,
proves the ordinary `AppServices` factory is never invoked, and covers the
tracked 27-stage contract, the public bilingual corpus through portable replay
and tombstone, explicit existing-library admission, role-separated device
identity, and the closed receipt vocabulary. The Python owner suite adds
contract graph/corpus checks, app-bound manifest creation, mode-0600 and exact-
shape enforcement, mode-0700 workspace admission, inherited-environment
sanitization, typed external-action acknowledgment, prerequisite admission,
same-stage concurrent-process rejection, complete cross-version finalization
across two host scopes and two accounts, atomic pair publication, and negative
cases for symlinked scratch roots, missing/extra or malformed receipts, broken
chains, reused processes, false-green offline work,
zero-wake push, a missing/foreign/reused live waiter, host/account substitution,
OS drift or same-generation pairing, a changed code-resource seal or embedded
profile, private content keys, unexpected evidence, and unsupported macOS
majors. Hermetic packaging tests also require the bundled
contract bytes to equal the tracked contract before final signing.
The published qualification receipt binds the canonical authority digest, and
generic release evaluation requires the unchanged sibling pair.
The changed-file UI selector owns exactly one English real-app canary for these
hidden sources: the existing Sync Settings journey that separates opt-in from
including an existing library. Complete bilingual XCUITest remains the RC gate.

The physical lane is intentionally not automated away. Each Mac keeps its role
database local and exchanges only the owner-only manifest and required receipt
files. Every stage launches the exact app once; `b.await-push` starts first and
must write its live marker and print `READY`. That marker is copied to role A,
which must consume it before `a.push-source` runs while the same B process stays
waiting. The delegate bridge keeps only a contract-sized newest-event buffer,
so a notification burst cannot grow process memory without bound. The app uses
real Foundation CloudKit account, engine, and notification paths against the
production container, but only the fixed public corpus.
Finalization requires one exact OS per role, distinct run-scoped host hashes,
and a cross-version pair with one Sequoia Mac and one Tahoe-or-newer Mac; it also
rejects a fake account switch.
No deterministic test, XCUITest, packaging check, or locally shaped JSON file
can replace this authorized two-Mac/account/APNs observation.

**Physical assistive-technology owner (D405).**
`docs/evidence/assistive-technology-qualification.json` freezes VoiceOver and
Voice Control on Sequoia and Tahoe-or-newer, English then Spanish, and six
ordered checkpoints backed by nine existing real-app XCUITest selectors. The
fixed disposable launch includes the public meeting, duplicate Skills
proposals, one Waiting receipt, and synthetic Interview Assist. It uses the
temporary-store Ask adapters and synthetic recording runtime, so routine
qualification needs no private meeting, external Web source, microphone,
installed model, account, or network.

`scripts/assistive_technology_qualification.py` requires a clean exact commit,
the exact-byte complete candidate-automation receipt, and the matching
Developer-ID-signed `Portavoz Dev` bundle before it writes a run manifest. The
stable app path is forbidden. The manifest binds version/build/commit,
contract, candidate receipt, executable, Info.plist, CodeResources, Developer
ID kind, and a run-salted signing-team scope. A cell binds the technology,
platform, exact arm64 OS build, a run-salted IOPlatformUUID host scope, and a
unique nonce. A locale session binds a unique exact process, empty seed-ready
marker, and fixed activation authority.

VoiceOver requires the explicit human acknowledgment plus
`NSWorkspace.isVoiceOverEnabled`; Voice Control is explicitly human-observed
because the owner uses no undocumented active-state mechanism. Each fixed
observation requires a separately typed checkpoint/outcome acknowledgment and
extends one immutable SHA-256 chain. A fail remains in the chain, gracefully
terminates only the identity-checked owned app, removes its disposable runtime
only after confirmed exit, and blocks the cell. A cleanup timeout retains
scratch state and fails explicitly. The next attempt must initialize a new run;
the tool has no receipt-edit, delete, arbitrary-proof, or retry-to-green
command. Starting a later locale also validates the complete immutable
authority for every earlier contract locale, so Spanish cannot launch before
English has finished successfully.

Finalization requires all and only four cells, two complete passing locale
chains per cell, unique cell/process nonces, one shared host/build for the two
technologies within each platform, and distinct host scopes across platforms.
Every file and directory must retain its owner-only mode and exact inventory;
symlinks, special or extra entries, broken chains, candidate drift, and copied
sessions fail. Publication uses an owner-only new directory, atomic no-clobber
files, and an authority-digest-bound generic receipt. Release evaluation now
requires that receipt beside the unchanged
`assistive-technology-authority`. Twenty-four tooling cases cover the fixed
matrix and selector existence, weakened or duplicated contracts, candidate
receipt/app/signature identity, path and publication permissions, environment
sanitization, activation authority, host scoping, global launch serialization,
failed-launch cleanup, strict English-before-Spanish admission, ordered
content-free chains, immutable observation failure cleanup, fail-closed
status/completion digests,
complete finalization, host separation, exact inventory, and process reuse.

The mandatory D405 XCUITest is a minimum-safe deterministic accessibility
canary, not physical assistive evidence. The full bilingual suite remains the
candidate/RC gate. Real VoiceOver and Voice Control observations still require
trusted operators and physical hosts under
`docs/ASSISTIVE-VALIDATION.md`; run-scoped host inequality alone is not
hardware attestation.

Final local D405 preflight passed the current-SDK warnings-as-errors build,
2,769 package tests with 15 explicit environment/model skips and zero failures,
strict SwiftLint with zero violations across 739 Swift files, all 24 focused
assistive-owner tooling cases, all 24 generic release-reliability cases, and
repository hygiene. The read-only UI host preflight stayed clear; 33 stale
LaunchServices claimants remained warning-only and were not reset. The
minimum-safe English real-app Skills receipt focus/accessibility journey passed
1/1 in an 18.004-second test interval. This automation validates the stable
accessibility contract only; it does not fill any physical VoiceOver or Voice
Control cell.

**Candidate automation owner (D392–D401).**
`docs/evidence/candidate-automation.json` is the finite executable contract for
the eight candidate proofs. `scripts/candidate_automation.py` runs every gate
sequentially on one completely clean full commit and rechecks the source before
and after each command. It directly owns deterministic reliability, public
bilingual Apuntador validation, six installed-model Release classes, the
authoritative performance ledger and its finite PERF-008 confirmation, one
current-host Release resource receipt, the
canonical synthetic three-hour capture, seven upgrade/recovery classes, and
the complete bilingual real-app XCUITest catalog. It has no arbitrary proof
recorder; only the successful in-process sequence writes the schema-1
`candidate-automation` qualification receipt with mode 0600.

The model lane renders
`Fixtures/CandidateAutomation/public-model-lane-en-v1.txt` as one Samantha
scratch AIFF. It separately renders the four long alternating Daniel/Paulina
turns in
`Fixtures/CandidateAutomation/public-diarization-en-es-v1.txt` through four
explicit `say -v` processes, validates every segment, and deterministically
joins mono 16 kHz Int16 PCM with three exact 700 ms silence intervals into one
owner-only scratch WAV. Embedded voice markup is never trusted as audio
identity. `afinfo` must prove bounded PCM frames and at least 60 seconds in the
joined conversation rather than merely trusting `say`'s exit status or a file
header. The lane sets the real-model opt-in and both fixture paths explicitly,
withholds captured model logs, and deletes the final audio plus every segment
in `finally` boundaries. Diarization tests verify installed files and cannot
download during this lane. Inherited private ASR, real-UI-audio, and waveform
paths are removed; resource collection forces ad-hoc scratch signing. The
disposable resource copy alone carries the standard hardened-runtime
library-validation exception required to load its separately ad-hoc-signed
embedded Sparkle framework. The tracked local/developer and distribution
entitlements retain library validation. Before any scenario, LaunchServices
must reach a process-owning app probe that publishes one fresh, owner-only,
fixed content-free marker; `open -W` success without that marker is a launch
failure rather than evidence. This is autonomous public-fixture evidence, not a
read of the user's library, network, or distribution identity.
The post-signing assertion treats the dotted entitlement name as one literal
plist key: ad-hoc evidence requires exact `true`, while real-identity evidence
requires the key to be absent. Decode failures and non-boolean values are not
treated as absence.
The recording cells do not request a fresh microphone grant for that ad-hoc
identity. They require the hidden `public-synthetic-dual-channel-v1` input,
admitted only with the disposable store and resource-output boundary, and run
it at real time through the production recording session, writers, live-model
feeds, Stop, indexing, and batch concurrency. Resource receipt schema 4 records
the exact 16 kHz/1,600-frame input contract and the completed
`refine-runtime-preparation-v1` prerequisite. No physical capture source, TCC
prompt, or user audio participates, so physical capture and permissions remain
external evidence. Every copied-app invocation also arms a bounded process
watchdog before database composition; expiration emits no passing fragment or
qualification receipt.

Specialized validation is fail closed. The performance ledger must be
authoritative, contain its exact 25-metric inventory, measure all twelve
scale/semantic/Spotlight metrics in `pass` or budgetless `diagnostic` state,
and retain exactly thirteen declared non-autonomous metrics as
`not-measured`. Candidate contract schema 2 also pins PERF-008's three-run
authority. One clean first ledger proceeds without repetition. A first
`regression-candidate` runs exactly two additional sequential non-strict
ledgers on the identical host and toolchain; every ledger and its SHA-256 is
retained. A metric present in all three candidate sets is a confirmed blocker.
Different candidates with no clean run are inconclusive and block. Otherwise
the last clean run is atomically copied to the canonical performance directory,
alongside a validated content-free confirmation receipt. Exit-state mismatch,
tampering, hard budget failure, instability, unresolved evidence, identity
drift, or a non-authoritative ledger blocks before qualification. This fixed
set is not an arbitrary green retry and never changes a baseline.

The resource receipt must match version/build/full commit,
Release configuration, and the automatically selected host profile; all nine
scenarios and the Ask pipeline must pass with exactly three samples. The long
capture must conserve the canonical three logical hours with zero drift and
bounded heap. The two UI receipts must name the exact 106-case budget catalog,
zero budget violations, only passed cases, EN and ES, selector count zero, and
one shared build duration. Runtime UI receipts are now published atomically as
owner-only files so interruption cannot leave a partially accepted JSON file.

Thirty-one adversarial tooling cases cover contract/order drift, content-bearing
or duplicate keys, incomplete performance partitions, non-authoritative and
regressed ledgers, silent omissions, fixed-set confirmation, confirmed and
inconclusive regressions, exit/host/toolchain mismatch, retained-ledger
tampering, resource identity/sample/Ask failures,
stale long-capture commits, incomplete or over-budget bilingual UI receipts,
profile gaps, non-empty bounded public speech audio, scratch-audio cleanup,
long distinct alternating conversation turns, exact private PCM joining,
explicit per-turn voice processes, XCTest discovery, owner-only output,
process-umask restoration, and the rule
that a failed gate cannot emit qualification.
The repository-hygiene suite runs them, and an
architecture ratchet pins D392, the exact eight proofs, 12/13 performance
partition, specialized validators, clean-source fence, Make target, and the
absence of a generic proof-state CLI. This automation does not close physical
Sequoia/Tahoe, additional resource hosts, assistive technology, distribution,
CloudKit, hosted integration, account, or user-field evidence.

D392 implementation preflight on macOS 26.5.2 (25F84), arm64 passed the full
2,748-case package suite with 15 explicit environment/model skips and zero
failures in 155.035 seconds of XCTest execution. The current-SDK
warnings-as-errors build passed in 21.34 seconds, strict SwiftLint reported zero
violations across 731 files, all 539 tooling cases passed in 24.103 seconds,
and repository hygiene passed with the exact 106-case UI catalog. After the
final Make phony-target ratchet, its focused Swift architecture case passed
1/1. The mandatory minimum-safe real-app XCUITest passed the existing Settings
navigation journey 1/1 in English in 16.683 seconds, with an 8-second reused
build observation, a passing runtime budget, and mode-0600 atomic receipt in a
mode-0700 directory. No production UI changed, so this scoped harness proof
does not replace the complete bilingual candidate gate and did not require a
Dev-app reinstall.

The first clean candidate after the package-inventory ratchet repair, source
`97e0339792ea27fce19f50920b4558b6fc2766d8`, completed deterministic and
public-Apuntador validation but stopped at the first installed-model class.
Both real `DiarizationIntegrationTests` executed with zero skips and failed
because the former Samantha/Paulina fixture produced only `S1` in batch and
live paths; no `qualification.json` was written. A controlled reproduction
showed that longer separately rendered Samantha/Paulina audio still formed one
cluster, while explicit Daniel/Paulina PCM passed both paths. This is retained
as candidate-discovered red evidence rather than hidden by an unchanged retry.

D393 preflight then rendered the tracked four-turn fixture through the new
owner into a 101.420-second, mono 16 kHz Int16 WAV with mode 0600. The installed
model passed both batch and live integration cases 2/2 in 0.945 seconds. All 24
focused candidate tooling cases passed, followed by all 542 tooling cases in
24.107 seconds outside the filesystem sandbox; the sandboxed run's only six
errors were denied loopback binds. The full package passed 2,748 cases with 15
explicit environment/model skips and zero failures in 133.806 seconds. The
current-SDK warnings-as-errors build passed in 21.54 seconds, strict SwiftLint
remained clean across 731 files, repository hygiene passed, and the focused
architecture ratchet passed 1/1. Mandatory minimum-safe real-app XCUITest
passed the Settings navigation journey 1/1 in English in 16.619 seconds with a
7-second build observation, a passing budget, and a mode-0600 atomic receipt
inside its mode-0700 directory. No production UI changed, so this scoped proof
does not replace the candidate's complete bilingual gate and no Dev-app
reinstall was required.

The following clean candidate on
`93ffd2074bedafb48db685d29f70d672f618095d` failed closed in its first full
package lane with exactly one failure across 2,748 tests and 15 skips. Its
output directory remained empty and neither deterministic nor candidate
qualification was emitted. The streamed failure identity was not recoverable
after orchestration output truncation. One immediate private-log run and three
more sequential full-suite runs then passed in 123.201, 124.505, 128.128, and
150.630 seconds; they are retained only as diagnostic evidence and do not
replace the red candidate. The toolchain's `--xunit-output` files contained
only the zero-case Swift Testing projection, not the XCTest inventory.

**Content-free deterministic failure diagnosis (D394).** The deterministic
runner now captures the complete package stream in one mode-0600 file under a
mode-0700 temporary directory and a mode-077 umask. It preserves the Swift
pipeline status, fails if capture itself fails, never retries, and removes the
private log after pass, failure, or signal. Its bounded 16 MiB parser emits only
stable, deduplicated XCTest identifiers; malformed, missing, empty, oversized,
or unrecognized input returns an unavailable marker without reflecting any
log payload. Five focused tooling cases cover order, deduplication, malformed
content withholding, input bounds, and exact CLI disclosure. Repository
hygiene runs those cases and syntax-checks the Bash owner. A future candidate
must still pass the original package execution before either receipt exists.

D394 preflight passed the synthetic failure-path harness with the original
status 37, mode-0700 directory, mode-0600 log, exactly one content-free failed
identifier, no repeated payload, and complete cleanup. The five focused parser
cases and the architecture ratchet passed. The complete tooling inventory
passed 547/547, the package passed 2,748 tests with 15 explicit skips and zero
failures in 220.640 seconds, the current-SDK warnings-as-errors build passed in
47.06 seconds, strict SwiftLint remained clean across 731 production files,
and repository hygiene passed.

The mandatory Settings real-app canary initially passed every assertion but
correctly failed its runtime budget at 25.272 seconds against 24.352 seconds.
The trace exposed up to twenty fixed 18-point wheel events rather than a product
regression. The test now derives the target-to-viewport distance and permits at
most three direction-aware bounded corrections; a tooling ratchet rejects the
old micro-scroll loop. The changed test then passed 1/1 English in 14.121
seconds with one 240-point scroll and a passing owner-only runtime receipt, a
44.1% reduction from the red run without raising its budget. No production UI
changed, so no Dev-app reinstall was required; this scoped canary does not
replace the complete bilingual candidate gate.

The next clean candidate on
`83634dec14bd01a12657f8434287ddfc260c43bb` again failed closed after 2,748
tests and 15 skips, with no deterministic or candidate qualification receipt.
D394 reduced the result to the dense correction-history budget case in
`PortavozTests.TranscriptCorrectionScaleBenchmarkTests`. That default Debug
case measured five 8,000-segment/4,000-correction permutations, making
nearest-rank p95 equal the maximum while the rest of the package shared the
host. The intended isolated Release authority on the unchanged source passed
twenty 20,000-segment/400-correction samples at 91.311 ms p50, 92.774 ms p95,
and 93.702 ms maximum against the existing 250 ms budget. This proves D394's
diagnostic path and distinguishes a misplaced timing owner from a product-path
regression; it is not an unchanged candidate retry.

**Isolated correction-composition admission (D395).** The ordinary package
suite now keeps five shuffled dense semantic compositions and requires the
exact 4,000-correction/6,667-row output plus complete composed-content equality
without using elapsed time as a pass condition. A fail-closed unit pins the
250 ms boundary itself, and an architecture ratchet requires exactly the
validation and projection domain indexes while forbidding the per-event
whole-history convenience path from the composer. The hard performance
authority remains the same payload-free
20,000-segment/400-correction Release harness and unchanged 250 ms p95 budget,
but the default and candidate runners now use twenty prebuilt permutations.
Direct environment activation also fails safe to twenty when a diagnostic run
count is not supplied. The deterministic release owner executes it sequentially
after the package suite, before later gates, and still writes no receipt if it
fails. No budget, fixture size, semantic assertion, privacy boundary, or final
bilingual UI gate was removed.

D395's focused class passed 5/5 in 0.790 seconds. Its isolated current-host
Release execution passed all twenty samples at 55.281 ms p50, 56.485 ms p95,
and 56.786 ms maximum against the unchanged 250 ms budget. The complete
package then passed 2,749 tests with 15 explicit skips and zero failures in
130.577 seconds; the private diagnostic log was deleted after preserving the
original pipeline statuses. The complete architecture ratchet passed 205/205,
the tooling inventory passed 547/547, the current-SDK warnings-as-errors build
passed in 23.47 seconds, strict SwiftLint remained clean across 731 production
files, and repository hygiene passed. These are local deterministic and
current-host synthetic proofs, not a candidate receipt or evidence for a clean
install, physical Sequoia/Tahoe coverage, accessibility, distribution,
CloudKit production, or field behavior. The mandatory real-app Settings
category-navigation journey then passed 1/1 in English in 11.822 seconds with
its owner-only runtime receipt and unchanged budget green. No production UI
changed, so no Dev-app reinstall was required; this scoped journey does not
replace the complete bilingual candidate gate.

The 11 Aug 2026 development inventory is 2,377 XCTest package cases (14
environment-gated), zero strict-lint violations across 656 production Swift
files, a 221-case recording/recovery selector passing 25 consecutive iterations
(5,525 executions), 355 deterministic tooling cases, and 80 XCUITest cases per
locale. This inventory is local automation evidence, not a release reliability
receipt or physical Sequoia/Tahoe field evidence.
The generic stress runner refuses fewer than 90 tests and the release wrapper
raises that floor to 108. Release evidence requires the package inventory to
pass without failures on a supported AppKit-capable host and strict lint to
return to zero. Package
tests include real-Store Stop/recovery invariants,
explicit Whisper language detection, split-lineage identity, full-pair
translation fences, unsupported-lane progress, user-only macOS 14 scroll
ownership, deterministic unique cast-grounded summary admission, the SDK-only
App Intents packaging contract, and a model root outside the replaceable app
bundle.

The temp-store-only `-seed-commitment-inbox` fixture adds an exact canonical
person link for the disposable Ana speaker and one evidence-backed pending
candidate without changing the default seed. Its focused bilingual journey
proves exact source seek, owner display, edit/confirm, dismiss/defer reachability,
and removal after explicit confirmation. It retains the app-only
`meeting-detail-commitment-inbox` attachment for visual inspection.

The temp-store-only `-seed-commitment-radar` fixture adds four deterministic
confirmed commitments covering self, a canonical person, and unassigned
ownership plus new, overdue, reopened, unchanged, and completed lifecycle
states. Its focused bilingual journey proves the global Library route, bounded
owner/due/activity filters, owner grouping without a storage reload, exact
meeting-source navigation, and a retained `commitment-radar` app-window
attachment for visual inspection.

D269 extends that same disposable Radar fixture with one real generated review
card. Its scoped bilingual journey opens **To review**, dismisses the visible
candidate after the production appearance hook records it, then opens the
independently loaded **Quality** mode. The retained
`commitment-field-quality` app-window attachment proves the empty-owner and
dismissal-derived aggregate without exposing an owner token, observation ID,
source ID, or meeting content. Architecture guards keep raw observations and
StorageKit out of SwiftUI, require ApplicationKit-owned identity/time, and pin
the explicit advisory-only copy; model tests prove observation failure never
blocks dismiss/defer.

D256 extends the same focused boundary with one ApplicationKit mapping test,
model success/failure characterization, and a real-app Radar journey that opens
the due-date editor, completes one seeded commitment, observes the durable
restore action after reload, and still opens its exact source. Named
`commitment-radar-due-date` and `commitment-radar-completed` attachments make the
new controls inspectable without broad UI-suite execution; the intermediate
`commitment-radar-rescheduled` attachment proves the saved due-date removal.
Architecture source guards require the narrow use case and prohibit snooze from
being represented as a due-date mutation.

D257 adds six focused reminder-history cases and one architecture ratchet.
They prove the pure schedule/present/snooze/dismiss lifecycle, malformed and
illegal transition rejection, an additive empty v23 migration, atomic storage
projection/history, unchanged commitment due dates after snooze, stale due-date
fencing, explicit cancellation, and rejection after completion. The source
guard keeps snooze out of Radar mutations and the new storage transition out of
app composition until a later notification workflow owns delivery.

D258 adds seven focused reconciliation cases and one architecture ratchet. They
prove initial future and overdue scheduling, relaunch reassertion without
history growth, atomic replacement after due-date changes, cancellation after
completion or soft deletion, terminal-dismissal exclusion, fail-closed
partial-page handling, and compensating scheduler cancellation after initial
persistence failure. The source guard requires the complete-count query,
content-free idempotent scheduler port, atomic replacement transaction, and
continued absence of `UserNotifications` or app composition.

D259 adds three reconciliation recovery cases, six macOS adapter cases, and one
architecture ratchet. They prove that an exact delivered request appends
schedule/present history without re-alerting, partial persistence never removes
an already-observed delivery, matching pending requests are idempotent, stale
delivered requests are removed before replacement, cancellation clears pending
and delivered copies, and not-determined/denied authorization never triggers a
prompt from reconciliation. The adapter test double receives only stable
identity/date metadata and generic copy. The source guard requires the
delivery-aware outcome, stable identifier, explicit authorization capability,
and continued absence from `AppServices` composition.

D260 adds five process-model cases and one architecture ratchet. They prove
that launch checks authorization without requesting it, only the explicit
Radar action asks, enabled state reconciles, denied state remains inert,
mutation bursts coalesce to one active pass plus one rerun, and a failed pass
can be retried. The source guard requires process-wide composition, launch and
successful commitment-mutation signals, absence of polling, the explicit Radar
permission controls, and a disposable notification center for UI tests. The
existing bilingual Radar journey now enables reminders and retains a named
`commitment-radar-reminders-enabled` app-window attachment without increasing
the 62-case UI inventory.

D261 adds five focused presentation/model/adapter cases and one architecture
ratchet. They prove exact schedule/due fencing, one durable `present`
transition, idempotent repeat handling, stale/terminal rejection, malformed
chronology rejection, metadata identity verification, and forwarding without
changing authorization state. A 63rd XCUITest uses only a disposable launch
route and retains a `commitment-reminder-open-radar` English/Spanish app-window
attachment. The source guard requires early delegate registration,
ApplicationKit ownership, content-free metadata, and default-tap routing to
Radar.

D263 adds four focused workflow/storage cases, one process-model case, one
native-category classification case, and one architecture ratchet. They prove
that exact delivery and snooze append once, the confirmed commitment due date
does not change, repeated/replaced responses are stale no-ops, malformed
chronology fails closed, the custom action has no foreground option, and a
successful background action signals the existing reconciliation owner without
requesting authorization. No additional XCUITest is required because D263 adds
no app-window UI and the platform callback is characterized below SwiftUI.

D264 adds four focused dismissal workflow/storage cases, one process-model
case, extends the native-category classifier case, and adds one architecture
ratchet. They prove that clearing a delivered alert appends exact presentation
plus terminal dismiss once, preserves commitment `dueAt`, rejects repeated,
replaced, and malformed responses, opts the category into the documented macOS
custom-dismiss callback, and neither prompts, reconciles, nor opens an app
window. A presentation-race case also proves that concurrent delivery/response
callbacks accept only an exact already-persisted winner and append one present
fact. No additional XCUITest is required because Notification Center owns the
gesture and the callback remains below SwiftUI.

D265 adds five focused query/application/storage cases plus one architecture
ratchet. They prove invalid date and bound rejection, one sampled review time,
duplicate-free exact meeting scope, newest-summary selection across recipes,
confirmed/dismissed/future-deferred exclusion, due-before-new ordering, exact
canonical-owner suggestions, fail-closed stale evidence, bounded evidence and
root truncation metadata, empty-scope short-circuiting, and a fixed two-SELECT
shape independent of root count. The source guard keeps confirmation mutations,
per-row Meeting Detail hydration, app composition, bundle, and meeting-sync
contracts outside this foundation. No XCUITest or screenshot is added because
D265 installs no app-window presentation.

D266 adds three focused window-model cases, evolves the D265 architecture
ratchet, and adds one bilingual XCUITest over the real disposable app. The
model cases prove that confirmed and review pages survive mode changes
independently, review mutations reuse the existing inbox request exactly, and
review failures do not replace confirmed Radar state. The UI journey proves a
generated action item appears only under **To review**, retains suggestion
styling, and reopens the complete source meeting at the exact current evidence
timestamp before any confirmation can occur.

Meeting Detail layout characterization keeps generated artifacts in a
noncollapsible bounded scroll region, the synchronized transcript in its actual
clipped viewport, and playback in a separate dock. Correction controls must
remain external 28-point accessories instead of inheriting focus blur/scale.
The architecture ratchet protects that composition, while the existing
summary, decision, action-item, commitment-review, correction, stale-artifact,
export, Sequoia-recovery, and generated-document XCUITest journeys prove the
controls remain hittable in English and Spanish.

XCUITest runs against the real app; XcodeGen generates the ignored
`.xcodeproj`. Before `build-for-testing`, `make test-ui` quits only a previous
Portavoz Dev instance and requires two clean host snapshots one second apart.
The read-only process inventory rejects an active `xcodebuild test` or
`test-without-building` action and any UI-test runner, while allowing an
ordinary build, unit-only `xctest`, idle XcodeBuildMCP server, and the persistent
`testmanagerd`. A current-toolchain Swift 6 probe uses CoreGraphics/HIToolbox to
inspect only on-screen, non-desktop window owner/layer metadata and the public
process-agnostic Secure Input state; visible SecurityAgent or Notification
Center windows and any other keyboard-protection owner block the run. It never
reports the owning PID or asks for a window title, bounds, dialog text, control,
or credential, and negative-layer Notification Center desktop surfaces do not
count. Both probes have explicit timeouts and exact-shape validation;
unavailable or malformed evidence fails
closed. The preflight never dismisses a prompt or terminates another process,
and the UI-test bundle installs no external-prompt interruption handler. A
privacy or authentication prompt raised after preflight therefore invalidates
the host run without allowing automation to answer the user's decision.
It cannot prevent unrelated automation from starting after its second sample,
so later connection invalidation remains a result-bundle/host classification,
not automatically a Portavoz crash.

The preflight also warns (via `scripts/check-url-scheme-handlers.sh`) when LaunchServices holds stale claimants of the `portavoz:` scheme: every build product that ever registered stays in that database, including temp copies whose paths are long gone, and `testRecordingAutomationRoutesStartAndStopThroughVisibleApp` can resolve to one — the launch fails silently and the test reports whichever app happened to be frontmost, which reads as a code regression and is not one. Observed on this machine: 21 of 31 claimants pointed at paths that no longer exist, and the test passed 4/4 in isolation on the same commit. A warning rather than a gate, because rebuilding the database is a system-wide action with its own side effects. **No UI gate asserts generated text** (D306): `testCommandPaletteSearchAnswerAndCitationSurviveNoStaleState` used to pin an exact `RAGAnswerer` sentence and failed 3 of 6 runs on a quiet machine, because the workflow honestly falls back to "Closest passages from your meetings:" whenever the on-device model is unavailable or throttled. It now asserts `palette-answer`, which renders only from `state.answer` and therefore proves Enter ran the full Ask workflow, plus the citation that proves the receipt reaches the exact second — 6 of 6 after the change. A model's availability is not a property of this repository, and a gate that fails for it teaches the team to ignore red. It verifies the UI through automation instead of driving the screen. The harness treats `-portavoz-open-settings` only as a runner-side hint, removes it before launch, and opens the real production Settings scene with `⌘,`; no test-only sheet or app-owned window lifecycle can leak into the following case. Every relaunch first observes the prior process terminate, waits on the content-free running-process inventory to clear, and receives a UUID-scoped `TMPDIR` so AppKit saved state cannot race another case. Launch args: `-NSTreatUnknownArgumentsAsOpen NO`, `-ApplePersistenceIgnoreState YES`, `-use-temp-store` (disposable DB; Settings does not touch the real Keychain, local voice identity, or CloudKit/APNs and completion does not invoke host Shortcuts), `-simulate-reminder-open` (routes one content-free stale reminder response through the production delegate path to Radar and is legal only with the disposable store), `-simulate-app-entity-route meeting|person|commitment` (invokes the production SDK-only open-action logic shared with each `OpenIntent` after the bounded disposable catalog is seeded), `-seed-demo` (deterministic meeting with transcript, summary, typed overview, decision, action-item, and role-separated Apuntador sources, coauthorship bullet "▸", action item, audio, and a content-free remote-attempt receipt), `-seed-stale-derived` (appends one deterministic correction after seeded Summary and Apuntador provenance so stale presentation is exercised without a model), `-seed-commitment-inbox` (links the disposable Ana speaker to one exact canonical person and exposes an evidence-backed pending candidate), `-seed-commitment-radar` (adds four bounded confirmed commitments across owner, due, and lifecycle states), `-seed-showcase` (fictional bilingual library used only by the public screenshot contract), `-seed-unnamed-speaker` (leaves the disposable remote speaker unnamed so the explicit name-suggestion action can be verified without invoking a real model), `-seed-ai-suggestions` (adds deterministic title, recipe, and speaker-name recommendations so each dismiss path can be verified without invoking a real model), `-seed-live-translation-ui` (adds a deterministic translated row so the labeled translation rail can be verified without language assets), `-seed-latest-recipe` (adds a newer Standup snapshot to prove D45 reload selection), `-seed-recovery` (a staging-only recovery fixture, allowed only with the temp store), `-seed-processing` (a model-free durable-processing fixture, also temp-store-only), `-seed-processing-failure` (converts the disposable seed's first job into an exhausted failure), `-seed-refine-running` (a model-free cancellable refine fixture, temp-store-only), `-seed-just-recorded` (marks only the disposable seed as freshly captured so the opted-in mirror can be verified), `-seed-without-summary` (omits only the disposable summary), `-seed-scale` plus optional `-scale-auto-summary-update` (a temp-store-only 5k-detail fixture), `-simulate-sequoia-capabilities` (forces the app-owned Foundation Models capability unavailable), `-simulate-apuntador-refresh-success` (replaces a disposable stale snapshot through the production refresh action without invoking a real model), `-simulate-ask-progressive-handshake` (holds disposable lexical evidence and the partial local answer at two finite XCUITest-owned boundaries), `-simulate-semantic-assets-missing` (substitutes a disposable embedding model only with temporary storage so the explicit Settings transition cannot touch host assets), `-simulate-voice-storage-unavailable` (returns a typed missing key to both voice stores only with temporary storage so the recovery UI cannot touch host biometric data), `-simulate-recording-start-failure` (injects one typed preparation failure), `-simulate-system-capture-stall` (injects a prolonged content-free stall, the two-minute Stop affordance, and recovery), `-simulate-system-audio-clipping` (feeds only compact persisted-level evidence for a sustained ceiling warning), `-simulate-live-transcription-attach` (moves one active recording from preparing to a live caption), `-simulate-live-transcript-browsing` (emits an initial caption history, pauses, then appends rows while the reader owns scroll position), `-simulate-skill-receipt-scope-unavailable` (returns unavailable only for non-Recent Skill activity loads so verified durable controls and explicit retry remain testable), `-simulate-skill-control-mutation-unavailable` (commits only a temporary-store policy mutation and then fails its response while the following durable read remains healthy, so recovery must adopt durable truth without replaying the ambiguous write), `-simulate-skill-receipt-refresh-handshake` (holds only non-Recent temporary-store receipt refreshes at a finite XCUITest-owned boundary so stale-row transitions and explicit refresh remain observable without a fixed delay), `-simulate-skill-receipt-policy-unavailable` (fails only the receipt inspector’s optional policy port so audit-only source review remains testable), `-simulate-skill-proposal-refresh-handshake` (holds each temporary-store proposal read at a finite XCUITest-owned boundary so retained inert actions and explicit refresh remain observable without a fixed delay), `-simulate-skill-proposal-unavailable` (fails only the content-free proposed-offer read so independently verified policy remains usable), `-simulate-skill-proposal-review-unavailable` (fails only the opaque review-to-context read while retaining the verified row and retry), `-simulate-skill-proposal-dismiss-unavailable` (fails only one opaque proposal-dismissal write while retaining the verified row and retry), `-seed-duplicate-skill-proposals` (uses the real meeting-offer producer for two disposable meetings so same-Skill assistive names must stay unique), `-seed-skill-history` (adds 25 content-free confirmed executions only to prove explicit 20-to-50 history expansion and same-scope refresh), `-seed-skill-exact-page-history` (adds exactly 20 matching executions so a full visible page cannot invent continuation), `-seed-skill-waiting` (adds one content-free confirmed execution that stops before begin), `-simulate-skill-receipt-revoke-unavailable` (fails only the waiting-revocation write while retaining its receipt and retry), `-seed-skill-failed-recoverable` (adds one failed local execution with an exact meeting subject), and `-simulate-skill-receipt-recovery-unavailable` (fails only the opaque receipt-to-context resolution while retaining its evidence and retry); all are legal only with the temp store. The runner-only Settings hint is never visible to the app process; after the main window is ready, the harness invokes the production `⌘,` command and waits for the real Settings category control. Every launch receives a unique `PORTAVOZ_AUDIO_ROOT`; tests that exercise copied real audio may explicitly override it with `PORTAVOZ_TEST_AUDIO_ROOT`. The diagnostics case additionally supplies a unique `PORTAVOZ_UI_TEST_DIAGNOSTICS_PATH`, and the backup case a unique `PORTAVOZ_UI_TEST_BACKUP_FOLDER`; production launches ignore both overrides. Only disposable `-use-temp-store` launches place the throwaway main window and real Settings scene on AppKit's zero screen. The main frame retains left clearance for desktop overlays; Settings is constrained inside the same screen's visible frame, and the harness requires its navigation anchor to have nonnegative global coordinates before continuing. Production multi-display placement remains unchanged. Localized, asynchronously populated controls that can still reflow must hold a stable hittable frame before XCUITest activates them; existence alone does not make a cached click coordinate reliable. The native recording-route case additionally proves the elapsed clock remains wider than it is tall and Stop stays hittable inside the minimum-width window, protecting the responsive two-row recording bar without screenshot pixel matching. The seed synthesizes a two-tone clip (mic/system) or adopts only that scratch copy. Covers 106 cases in `AutomationUITests`, `LibraryUITests`, `InterviewAssistUITests`, `InsightsUITests`, `OnboardingUITests`, `MeetingDetailUITests`, `CommitmentRadarUITests`, `PublicShowcaseUITests`, `SettingsUITests`, and `SkillsSettingsUITests`: the targeted production `portavoz://record` handoff into a visible disposable recording, exact meeting/person/commitment App Entity routes, library and grouping, the global bounded Commitment Radar with separate generated-review triage and exact source navigation, exact Library result-to-timestamp seek, return from a browsed meeting to the still-active recording, source-grounded upcoming-meeting preparation, exact local-data receipts, full Ask and command-palette answer/citation paths (the palette case begins with its destination detail already open so it proves same-route delivery), interrupted staging recovery to a playable detail, durable processing resume/retry, typed recording-start failure/retry/reference, cold-model live-caption attachment, reader-owned live-caption history with an explicit Jump to live, visible prolonged system-callback outage, sustained incoming-clipping warning and dismissal, explicit Stop exit into the guarded typed no-audio Retry state, one complete heatmap/interlocutors journey, one sequential first-listen-to-local-voice enrollment journey, 5k-detail rendering plus scoped summary update, overview, decision, action-item, and Apuntador source-to-transcript/audio navigation, explicit summary-claim correction/unsupported/clear review, focused transcript text/speaker correction with original evidence and durable undo, explicit merge/hide/restore structural correction with hidden accepted evidence, correction-stale Summary/Apuntador evidence with explicit regeneration plus simulated-Sequoia preservation, summary/transcript/player/rail/privacy receipt/clip plus scoped action-item mutation, dismissible AI recommendations, reversible clear playback, a visually distinct live-translation rail, correction-aware SRT/WebVTT export-menu availability, explicit transcript/calendar name-suggestion entry, confirmed-person memory, newest-recipe reload, refine cancellation, the post-meeting mirror sheet, Sequoia intelligence recovery, Settings navigation, explicit iCloud sync opt-in/existing-library separation, redacted support export, readable whole-library Markdown backup, independent transcript/summary language controls, explicit semantic-asset preparation, custom structures, audio capture, local-voice enrollment, unreadable voice-storage recovery, mirror opt-in, live locale, truthful Skills activity transitions, distinct positional assistive names for repeated same-Skill proposals, read-only control recovery after an unverified committed mutation, bounded explicit Skills history expansion, same-selection explicit Skills refresh, exact query-level Skill and rolling-period filtering with 20/50 reset, exact-page continuation suppression, and the three public showcase surfaces. The palette screenshot targets its identified `NSPanel`; every other retained attachment targets an app window. The automation route retains `automation-visible-recording`; the App Entity route retains `app-entity-commitment-route`; the scaled detail, Ask surfaces, Meeting Detail claim review and overview/decision/action-item/Apuntador source/player, rail/player waveform, confirmed-person memory, grouped Library, global Commitment Radar, `commitment-review-queue`, `commitment-review-exact-source`, `commitment-reminder-open-radar`, Insights heatmap, post-meeting mirror, Sequoia capability, semantic-search preparation, diagnostics, recovery, recording-failure, remote-audio-recovery, remote-audio-stop-recovery, system-audio-clipping, live-transcript-hot-attach, live-transcript-history-paused, live-translation-rail, transcript-correction-original-evidence, transcript-structural-correction-evidence, meeting-detail-stale-derived-artifacts, meeting-detail-apuntador-refreshed, meeting-detail-correction-aware-export, transcript/calendar-name, local-voice, voice-storage-recovery, dismissible-AI, Skills activity transition, `skills-activity-expanded-history`, `skills-activity-explicit-refresh`, `skills-activity-period-filter`, `skills-activity-exact-page`, and public showcase cases keep named app-only `XCTAttachment` screenshots, including `public-meeting-detail`, `public-live-translation`, and `public-insights`, so feature-band runs can export and inspect deterministic visual evidence without screen driving or exposing unrelated desktop content. `make public-screenshots` runs only those three showcase cases, exports their attachments, and replaces the synchronized README/site assets. `make test-ui-en` and `make test-ui-es` use Xcode's `-testLanguage`/`-testRegion` contract; a shell environment variable alone is not accepted as localization evidence. Export itself (`AudioClipExporter`) is tested as a unit test — a 15 s clip from a 30 s source exports to m4a in a fraction of a second (comfortably below the < 2 s M11 criterion).

## Measurement harnesses

- `make test-meeting-memory-graph-quality` runs seventeen deterministic tooling
  tests and canonical verification over D270's 36-case public-synthetic query
  corpus. The fixture is the exact cross-product of six longitudinal jobs and
  six English, Spanish, cross-language, code-switched, or abstention
  relationships. Every answer names typed result and exact evidence identities;
  every abstention has a job-specific reason, isolated evidence, and forbidden
  temptations. Validation rejects schema/provenance drift, duplicate or unknown
  identities, stale/generated required truth, wrong evidence ownership,
  incomplete distribution, language-relation drift, and source/oracle
  disagreement. The harness invokes no model, database, network, user library,
  or product graph and chooses no engine or serving threshold.
- `make test-commitment-quality` validates the canonical 48-case public-
  synthetic commitment fixture and runs twelve deterministic tooling tests.
  The corpus is balanced across English, Spanish, and mixed speech and
  distinguishes 12 commitments from nine suggestions, nine hypotheticals,
  nine status reports, and nine questions. `make commitment-quality-
  deterministic` emits the transparent research control;
  `make commitment-quality-model PORTAVOZ_COMMITMENT_MODEL=<local-model>` uses
  only an explicit loopback-IP OpenAI-compatible endpoint; and
  `make commitment-quality-compare` validates two same-fixture scorecards and
  reports deltas without a winner. Candidates lacking evidence shared by the
  transcript and generated action item fail closed. Aggregate scorecards
  measure owner/deadline false positives; optional per-case details are mode
  `0600`, non-overwriting, and untracked. The initial aggregate development
  observation is retained in
  `docs/evidence/commitment-quality-research-20260802.json`; its local-model
  result remains `review-required` and its product decision remains
  `not-evaluated` (D236).
- `make test-commitment-link-quality` validates D245's reproducible 36-case
  cross-meeting fixture and runs thirty-one evaluator/contract tests without a
  model, database, or user library. The corpus is balanced across English,
  Spanish, and mixed speech and across 18 linkable and 18 mandatory-abstention
  cases. It labels semantic-relevant targets separately from legally linkable
  targets, including ambiguous, wrong-person, no-overlap, same-meeting,
  inactive, dismissed, and unknown-owner cases. Observations are fixture-
  digest-bound and enforce D244's 20-hit/three-suggestion limits. Aggregate
  scorecards report semantic Hit@1/Recall@20, link precision/recall/F1,
  Hit@1/Recall@3, abstention accuracy, false-suggestion rate, and exact policy-
  explanation support overall and per language/class. `make commitment-link-
  quality-control` emits a perfect synthetic control only to prove evaluator
  arithmetic; it remains `review-required`, makes no product decision, and
  selects no threshold or engine. Optional case details are mode `0600`, non-
  overwriting, and untracked.
- Twenty-three focused package cases cover D246–D255's non-serving product seam:
  six observer/storage behaviors, nine source-link architecture contracts, and
  eight product-runner cases.
  The real in-memory Store path proves exact open source/evidence identities,
  installed-assets-only borrowing, and semantic-hit versus legal-admission
  separation. Exact semantic search now proves that it retains profile-local
  cosine evidence while lexical search retains none. The observer proves the
  profile fingerprint and exact score, and rejects missing, non-finite, or
  ascending similarity evidence before measurement. Source inspection keeps it
  behind the existing semantic port and Core policy, enforces bounded ranked
  reads, prohibits the confirmation mutation, and proves no app composition.
  The runner cases add
  canonical digest parity, strict CLI options, all-36-case isolated scratch
  mapping, installed-assets-only observation, exact external-identity output,
  and owner-only non-overwriting publication. D249 additionally proves a
  separate score-bearing document with exact fixture, full profile, build, and
  source-commit provenance; known external identities; bounded descending
  cosine values; and literal non-evaluated/non-approved states. The Python
  authority rejects schema drift, unsafe provenance, unknown/duplicate rows,
  non-finite or out-of-range scores, and rank inversion. The
  `commitment-link-similarity-product` target requires an ignored output path,
  build identity, and full source commit; it captures and validates that owner-
  only receipt without evaluating or serving it. The
  `commitment-link-similarity-replay` target then derives one inclusive
  threshold representative for every behaviorally distinct admission outcome
  present in that receipt. It keeps semantic hits fixed, refuses unsupported
  baseline proposals, binds the exact scored-input digest and provenance, and
  writes one owner-only non-overwriting candidate matrix. Four focused tooling
  cases prove deterministic outcome enumeration, fail-closed legal support,
  all-abstaining input, exact recomputation, tamper rejection, source-drift
  rejection, and literal
  review-required/not-selected/not-approved states. No candidate is selected
  and no product quality floor or serving policy is created (D250). The
  separate `validate-commitment-link-private-pack` target accepts one regular
  non-symlink mode-`0600` private companion pack. It requires the same exact
  36-case language/class/link balance as the public authority, a literal owner-
  reviewed redaction attestation, negative audio/path/account/direct-identifier
  claims, and gitignored storage when the file is repository-local. Three
  focused cases cover the balanced contract, attestation and distribution
  failure, obvious email/URL/path/phone/UUID rejection, file mode, and symlink
  refusal. These pattern checks are only a backstop and make no automatic de-
  identification claim; no private fixture is tracked (D251). D252 adds a
  separate `commitment-link-private-similarity-product` target that validates
  the private pack before collection, runs all 36 cases through isolated
  scratch stores and the same non-serving observer, and validates a distinct
  owner-only receipt afterward. Swift independently enforces the private root,
  exact balance, redaction attestation, obvious-identifier backstops, and
  regular non-symlink mode-`0600` input. The receipt binds the private fixture,
  anonymization/content-source, profile, build, and commit while emitting no
  fixture source text. Three tooling cases cover private receipt provenance,
  drift, destination preflight, owner-only input/output, and CLI validation;
  four package cases cover
  loader separation, isolated scored collection, no-text publication, and the
  app-composition ratchet. The public product command remains canonical-digest-
  only. D253 adds the separate `commitment-link-private-similarity-replay`
  target. It validates owner-only fixture and scored inputs, preflights an
  owner-only ignored output, and emits a distinct private candidate matrix
  bound to fixture, anonymization, scored-observation, profile, build, and
  commit provenance. The candidate arithmetic is shared with the public replay
  but exact recomputation cannot confuse the two receipt kinds. Three focused
  tooling cases prove deterministic private outcomes, public/private
  separation, tamper and source-drift rejection, CLI validation, and mode-
  `0600` non-overwriting publication; one package architecture ratchet keeps
  the private replay out of app composition. No candidate is selected and no
  threshold is product-evaluated or serving-approved. D254 adds the clean-head
  `commitment-link-profile-matrix` target. It builds the Release CLI once,
  disables asset downloads, captures and validates both scored authorities and
  both replays, requires one exact profile/build/commit, and publishes five
  mode-`0600` files atomically inside one ignored mode-`0700` bundle. Public and
  private metrics are recomputed at the union of observed thresholds instead of
  comparing potentially unaligned replay candidates. Four tooling cases cover
  deterministic alignment, provenance mismatch, tamper rejection, owner-only
  non-overwriting CLI publication, shell syntax, clean-head checks, single-build
  reuse, download prohibition, and staged publication; one package architecture
  ratchet keeps the matrix out of app composition. No real private pack or
  accepted matrix is retained, and every result remains review-required,
  unselected, non-evaluated, and non-approved. D255 adds the separate
  `test-commitment-link-policy-review` and `commitment-link-policy-review`
  targets. Five deterministic tooling cases prove exact candidate/floor
  retention, matrix/source/acknowledgement/candidate drift rejection,
  owner-only atomic non-overwriting publication, exact revalidation, contract
  fail-closure, and withdrawal after a checkout change. One package ratchet
  requires the explicit inputs and keeps the receipt outside app composition.
  The admission gate revalidates the private fixture and all five D254
  artifacts, requires a clean checkout at the matrix commit, and stores the
  selected candidate's complete public/private metrics only after explicit
  digest, commit, candidate, and review acknowledgement. Synthetic tests create
  no real receipt; retained authority remains private calibration-only, product
  not-evaluated, and serving not-approved. The
  `commitment-link-quality-product` target runs the real
  Storage/Application path and immediately validates it with the D245
  evaluator; downloads remain disabled unless the caller explicitly selects
  `if-needed`. One dirty-head development smoke over the installed Apple
  profile completed the pack with semantic Hit@1 0.969697, Recall@20 1.0, link
  precision 0.777778, link recall 1.0, abstention accuracy 0.666667, and six
  explanation-supported false suggestions. This is not a retained clean-head
  baseline or accepted quality floor, and no result is served.
- `make test-ask-quality`: verifies both canonical public-synthetic Ask fixture
  generations and runs 43 deterministic evaluator/comparator/runner cases without
  loading models or user data. Each fixture has exactly 240 judged queries: 60
  Spanish-to-Spanish, 60
  English-to-English, 40 English-to-Spanish, 40 Spanish-to-English, 20
  code-switched, and 20 isolated robustness cases. Evaluation reports Hit@1,
  Recall@10, reciprocal rank, nDCG@10, factuality, citation coverage, answer
  policy, hard negatives, unsupported claims, and canonical citation integrity
  overall and per relationship. Exact facts, declared quality floors,
  abstention, citation identity, hard-negative exclusion, and zero unsupported
  claims fail closed. The owner-only scorecard retains aggregate metrics plus
  fixture, adapter, build, and commit identity, never source payloads. This
  adapter-neutral harness is the fail-closed quality boundary.
  `public-synthetic-v1` stays reproducible for historical evidence;
  `public-synthetic-v2` interleaves relationships
  into sixty four-segment meetings with two exact two-segment same-actor turns
  per meeting, multilingual turns, and hard negatives from another meeting.
- `portavoz-cli bench-ask-quality` accepts fixture, output, build, commit, an
  optional `segment|speaker-turn|conversation-window` retrieval-unit argument,
  and an explicit
  `never|if-needed` asset-download policy that defaults to `never`. It seeds and
  explicitly indexes a disposable database outside query observation and runs
  the real corpus-read-only `LocalAskMeetingRetrieval` path without opening the
  user library. Eight Swift tests cover product retrieval provenance,
  multilingual same-actor turn projection, bounded conversation-window
  projection, exact source membership, and owner-only atomic non-overwriting
  publication. Observation schema 2 records
  one ranked unit ID and every ordered source segment ID. The evaluator still
  admits historical schema 1 as a one-source unit, rejects repeated, unknown,
  unordered, cross-meeting, or stale source evidence, and counts a hard
  negative even when it shares a chunk with relevant evidence. Both current
  adapters intentionally emit `notEvaluated` answer fields, so retrieval can
  be scored while answer-quality and answer-policy gates remain blocked until
  a separate versioned judge exists.
- `make ask-quality-pair`: requires a receipt-safe build identity, explicit
  private output, a registered `speaker-turn|conversation-window` candidate,
  and a clean worktree. It verifies `public-synthetic-v2`,
  derives the full HEAD identity, builds the Release CLI once, and runs both
  retrieval units with asset download fixed to `never`. Evaluation exit 1 is
  admitted only when its owner-only scorecard exists, because answer evidence
  is intentionally absent; malformed evaluation remains a contract error. A
  `candidate-parity` comparison exits 0, a valid blocked comparison exits 1,
  and setup/contract failure exits 64. The five artifacts are mode 0600 inside
  one mode-0700, non-overwriting directory. A hidden sibling stage and
  exclusive lock prevent partial publication; failure removes both. Output
  inside the repository must already be ignored. The runner never opens the
  user library and never turns host/model unavailability into a quality score.
- `scripts/ask_quality.py compare` accepts one canonical fixture plus segment
  control and one allowlisted speaker-turn or conversation-window candidate
  scorecard. It validates their complete
  scorecard shape, canonical quality floors, adapter roles, fixture checksum,
  build, commit, and observation schema before publishing an owner-only,
  non-overwriting, payload-free comparison receipt. The candidate must match
  or improve every aggregate and per-relationship retrieval metric, retain
  canonical citations, and introduce no hard-negative regression. A
  `candidate-parity` result is quality evidence only and cannot select the
  product adapter without the separate resource and correction-cost matrix.
- Six semantic-readiness package tests cover the shared `ready`, `partial`,
  `building`, `unsupported`, and `failed` contract, complete-corpus precedence
  over stale process failure, Library reads that cannot advance the durable
  cursor or download assets, and background-supervisor failure recovery.
- `bench-m2`: live transcript lag (p50/p95/max) with concurrent batch processing.
- `portavoz-cli der`: DER against reference RTTM (public fixture: pyannote sample.wav/rttm).
- `scripts/verify_drift.py`: drift through envelope correlation (±5 s, edge warning, multi-point).
- `scripts/run-sandbox-capability-spike.sh`: signed sandbox/control capability matrix with full private tap-graph setup and tracked JSON evidence.
- `scripts/run-scale-baseline.sh`: Release production-schema library/detail matrix with disposable databases.
- `make exact-path-mutation-matrix`: test-only Release mutation/correction-cost
  observations at 1k/10k/50k/100k exact corpora. Each fresh process measures
  one lifecycle-labelled full reconstruction and lifecycle-labelled add/update/
  delete batches of 1, 10, and 100 against the scratch-store Accelerate control
  and disposable sqlite-vec candidate. Control timings include authoritative
  source and embedding publication; candidate timings receive prepared vectors,
  so the report defines no cross-engine ratio. Every operation verifies top-hit
  and top-k-set source identity, while schema-1 stdout retains only host/
  configuration, counts, bytes, timings, and aggregate agreement. No
  observation is retained or accepted automatically.
- `make exact-path-mutation-host PORTAVOZ_EXACT_PATH_PROFILE=memory-16gb`:
  collect three complete mutation matrices from one unchanged clean Release
  checkout and emit one threshold-free, content-free schema-1 host receipt.
  Exact shape, supported host/OS, lifecycle labels, finite distributions,
  coverage, top-hit parity, and top-k-set parity are mandatory. Complete
  evidence is `review-required`, never an automatic performance pass; timing
  variability remains visible for explicit human review. The collector accepts
  no output destination and removes raw observations. Use
  `make test-exact-path-mutation-host` for the synthetic fail-closed contract
  suite without running the expensive Release matrix.
- `make exact-path-mutation-cross-host
  PORTAVOZ_EXACT_PATH_MUTATION_RECEIPTS=/private/path/receipts.jsonl`:
  revalidate exactly one mutation host receipt per 8 GB, 16 GB, and reference
  profile, require Sequoia/Tahoe coverage plus one source commit/toolchain, and
  emit a detached, exactly recomputable schema-1 review scorecard. Complete
  comparable evidence remains `review-required`; missing, blocked, or
  identity-divergent evidence is blocked, while malformed/repeated evidence
  emits nothing. No timing ratio, threshold, automatic pass, retention, or
  engine decision is derived. Use `make test-exact-path-mutation-cross-host`
  for the synthetic contract suite.
- `make exact-path-mutation-baseline`: retain one canonical mutation review
  scorecard only after supplying its three receipts, exact scorecard SHA-256,
  sole source commit, explicit
  `timings-reviewed-no-engine-decision-v1` acknowledgement, and a private
  output path. The matching checkout must stay clean before and after
  owner-only atomic publication; repository-local output must already be
  ignored and existing output is never replaced. The retained scorecard stays
  `review-required`, with research-only correction-cost authority and no engine
  or performance decision. Use `make test-exact-path-mutation-baseline` for the
  synthetic fail-closed suite; no real baseline is committed.
- `make correction-composition-benchmark`: run the content-free correction
  composition benchmark in Release mode for twenty iterations by default; the
  diagnostic CLI accepts three to twenty, while release admission requires all
  twenty. The benchmark prepares deterministic mixed-language 20,000-segment and
  400-correction permutations before timing, verifies complete composed-content
  equality and identical visible-row counts across every run, and fails when
  nearest-rank p95 exceeds 250 ms. Its stdout contains one aggregate JSON
  document and its stderr retains test
  progress; neither carries meeting, segment, correction, text, or path data.
  The 2 Aug 2026 reference in
  `docs/evidence/correction-composition-20260802.json` measured p50 168.85 ms
  and p95/max 175.20 ms over five runs on the named arm64 host. This gate owns
  pure composition only; Meeting Detail rendering and corrected-search latency
  remain separate authorities.
- `make commitment-radar-benchmark`: run the real bounded StorageKit Radar read
  in Release mode over fresh synthetic 1,000- and 10,000-confirmed-commitment
  stores for three to twenty iterations (five by default). Fixture insertion
  and one warm read occur before timing. Every measured page must return the
  same 100 roots through exactly four SELECT/WITH statements, and nearest-rank
  p95 must not exceed 100 ms. Stdout contains one content-free schema-v1 JSON
  observation; build progress remains on stderr and no report is persisted.
  The 2 Aug 2026 five-run arm64 reference measured 4.06/4.25 ms p50/p95 at
  1,000 and 25.10/25.27 ms at 10,000. This is Store-read authority only; UI
  rendering, candidate extraction, and cross-meeting linking remain separate.
- `make long-capture-baseline`: clean-commit Release proof that accelerates
  three hours of bounded synthetic microphone/system PCM through the production
  session and requires exact frames, healthy publication, zero drift, and no
  more than 16 MiB incremental heap. Existing output and mid-run source changes
  fail closed before destination-local atomic publication. It deliberately does
  not substitute for the real-time physical-footprint or route matrix.
- `make test-meeting-detail-baseline`: verifies the canonical source-derived
  interaction/feature-owner contract and the fail-closed Instruments parser.
  The contract currently covers 371 interaction signals across 31 source
  files, twelve owners, and all 27 Meeting Detail UI journeys; both missing and
  duplicate ownership fail. Architecture ratchets also cap the route
  composition view at 500 lines; reject direct model sends, route bindings,
  app preferences, and global recipe access there; keep AppKit copy/open
  effects outside the modal host; and require every extracted source to map to
  a feature-scoped UI selector.
- `make meeting-detail-baseline`: Portavoz Dev-only, disposable 5k playback-
  seek and 20k transcript-scroll profiles. Each interaction must produce
  exactly five positive payload-free intervals. The Aug 2026 Xcode 26.6
  evidence records first content at 111.25/197.35 ms, seek/scroll p95 at
  0.52/331.94 ms, no app hitch, and no potential hang. The SwiftUI lane is
  explicitly `unavailable-toolchain` for both scales rather than zero. The
  runner refuses the notarized app and never reads the user library.
- Instruments Points of Interest can filter the generic `Resource workload`
  intervals by the allowlisted class, kind, operation, and outcome fields.
  These intervals carry no meeting, transcript, path, model, span, or error
  identity and never execute from AudioCaptureKit callbacks.
- `make resource-baseline`: requires a clean commit, builds one
  Release bundle, re-signs a uniquely identified scratch app, and captures at
  least three steady-idle, active-recording, Stop, Refine, Summary, Ask,
  standalone semantic-indexing, recording-plus-indexing, and
  recording-plus-batch runs.
  The original `make resource-recording-baseline` target is a compatibility
  alias. After a five-second launch-settling interval, the benchmark measures
  idle before loading models. Before the repeated Refine samples, one bounded
  unmeasured scratch-app process verifies installed artifacts, loads and
  releases the production Whisper runtime, then loads and releases the
  production diarization runtime. It must publish the exact owner-only
  mode-0600 `refine-runtime-preparation-v1` marker. Refine runs separately
  against a fixed non-silent English AIFF synthesized from public text; it
  verifies the installed Whisper, tokenizer, and diarization artifacts again
  before every sample and never downloads models. Each measured sample remains
  an independent app process without a resident runtime. This excludes one-time
  host/Core ML compilation from the repeated-sample stability calculation; it
  does not measure or certify first-ever Refine activation latency, disk cost,
  or UX. Summary runs in another cold
  process, verifies the pinned Qwen3.5 MLX model, creates a fixed public English
  meeting/cast/transcript only in the disposable database, and measures the
  real ApplicationKit regeneration transaction. Ask runs in another cold
  process, requires already-installed Apple Latin embedding assets plus
  available Foundation Models, and measures the real `AskMeetings.local`
  workflow over the same fixed transcript. Before measurement, the disposable
  fixture is explicitly indexed through the shared maintenance coordinator
  without downloading assets. Its measured window includes bilingual
  expansion, corpus-read-only hybrid retrieval, and generated answer, and
  requires citations plus nonempty text.
  The same run must emit a content-free pipeline sidecar with exact operation,
  first-evidence, first-observable-token, seven stage, schema-2
  pending-at-seed/ready-before/ready-after corpus evidence, and validated
  citation-digest evidence. The native probe refuses malformed
  lifecycle, digest, milestone order, duplicate output, or incomplete success.
  Standalone indexing prepares already-installed Apple embedding assets and a
  fixed 1,024-segment corpus before measurement, then drains it through the
  real ApplicationKit operation. Recording plus indexing prepares that same
  workload, starts the real product recording lifecycle over the tracked
  public synthetic dual-channel input, runs indexing only after Start succeeds,
  and keeps recording active until the operation completes. Its process metrics
  freeze before Stop while already-active live-transcription spans may still
  publish their terminal outcome. Recording plus batch resolves the shared
  Parakeet runtime before measurement, starts the fixed public AIFF through the
  production post-capture batch scheduler only after Start, and requires a
  nonempty result while capture remains active. It deliberately excludes
  diarization and summary from that cell. Every bounded Refine, Summary, Ask,
  indexing, and concurrent operation enforces the same configurable hard timeout. The runner
  uses a disposable meeting database and audio root plus process-local secrets
  and a unique temporary participant-identity root. It never reads or writes
  the host Keychain, voiceprint, or participant-voice gallery; production
  retains the Keychain-backed secret adapter and durable identity root. It
  reuses the verified installed Portavoz model cache only where required and
  never targets the notarized installed app. Resource-mode app initialization
  returns before sync, recovery, provider discovery, or dictation registration
  can contaminate a measured operation; the AppKit delegate remains detached
  from product services. The windowed recording runner requires the exact
  deterministic real-time microphone/system fixture before it arms a resource
  probe. It exercises product recording, live transcription, and Stop without
  constructing a physical input graph. Real TCC, device-route churn, and
  48 kHz → 24 kHz hardware transitions remain physical field gates and are not
  certified by this matrix. Native app
  probes begin only after two nominal thermal observations five seconds apart;
  inherited pressure fails closed after five minutes, while pressure produced
  after counters start remains part of the sample. The probes sample process
  CPU, physical footprint, energy, disk I/O/free capacity,
  thermal, low-power, and invariant power-source state while aggregating the
  closed workload descriptors. Behavioral unit tests inject an immediate
  readiness gate so host thermal pressure cannot delay or invalidate their
  scenario assertions; production benchmark processes retain the real gate.
  Ad-hoc candidate collection uses a dedicated scratch-only entitlement for
  `com.apple.security.cs.disable-library-validation`, because current macOS
  rejects the separately ad-hoc-signed embedded Sparkle framework under the
  hardened runtime. A real Developer-ID collection keeps library validation
  and fails if that exception is present. The embedded-signature check uses a
  literal plist-key lookup because `plutil -extract` interprets periods as
  key-path separators. Parser or type failures block both signing paths rather
  than becoming false absence. Before the first scenario, a minimal
  process-owning launch probe must create one exact mode-0600 marker with
  exclusive creation and durable write; this catches dyld/LaunchServices
  failures that `open -W` can otherwise report as success. All seven measured
  app invocations per round use the copied signed bundle through
  LaunchServices—never the inner SwiftUI/AppKit
  executable—so each scenario receives the same application resource policy,
  bundle identity, and environment. An in-app watchdog is armed before
  database composition and makes AppKit, TCC, model, or teardown stalls
  finite. Its bound exceeds both the tighter model-operation timeout and the
  longest idle-plus-recording phase by 420 seconds. An outer shell guard ends
  only the disposable app and its `open -W` wait after a further 30-second
  grace if LaunchServices itself does not return. The Stop probe atomically
  replays active spans
  before recording metrics freeze, preventing a boundary finish from falling
  between collectors. A timeout or partial lifecycle emits no passing sample.
- `scripts/resource_baseline.py assemble/evaluate`: assembles exact native
  fragments into one schema-4 host receipt whose required recording-input
  provenance is `public-synthetic-dual-channel-v1` at 16 kHz with 1,600-frame
  chunks and whose required runtime preparation is
  `refine-runtime-preparation-v1`. The assembler requires one regular,
  non-symlinked, current-owner, exact-mode-0600 marker with fixed content,
  validates exact-shaped Release
  receipts against `docs/evidence/resource-baseline-matrix.json` and always
  projects the 3-profile × 9-scenario matrix. Each passing cell requires three
  stable runs and its contracted workload descriptors. Output is owner-only
  JSON/Markdown with nearest-rank p50/p95, peak footprint, energy, free-disk,
  thermal, and power summaries. Wall or CPU timing marks the row unstable only
  when both p95/p50 is above 1.25 and p95 minus p50 is at least 100
  milliseconds; a zero median blocks only when p95 reaches that floor. The
  tracked contract cannot raise the floor, and raw aggregates remain visible
  without clipping. Missing, failed, not-observed, under-sampled, or unstable
  rows block without disappearing; malformed or payload-bearing evidence is an
  error. Thirty deterministic tooling tests cover completeness,
  blocking states, assembly, native host metadata, runner isolation,
  identity/memory-tier mismatches, exact privacy shape, non-finite metrics,
  duplicate keys/runs/profiles, required workloads, contract weakening, output
  permissions, absolute GUI output roots, source-path omission,
  canonical-runner delegation, and
  synthetic Refine, Summary, Ask, indexing, concurrent-indexing, and
  concurrent-batch fixture/sample admission. Ask-specific coverage additionally
  rejects content-bearing fields, invalid citations, and nondeterministic
  citation digests while proving one-to-one broad/pipeline run assembly. The
  scorecard reports separate first-evidence and post-evidence generation timing
  plus every stage's p50/p95 wall and CPU, and requires stable corpus/result
  identity across profiles. This proves collector completeness
  for all nine scenarios, not a resource budget or governor decision; accepted
  multi-host evidence remains required.
- `portavoz-cli bench-waveform`: Release first/repeat wall, process CPU, physical-footprint, exact-result, and replacement-invalidation evidence over source audio copied to scratch.
- `scripts/run-spotlight-scale-baseline.sh`: isolated Release legacy/snapshot projection matrix at 1k/10k/100k meetings, exact fingerprint comparison, and optional synthetic-only protected-index delivery/cleanup.
- `make perf-ledger` (`scripts/run-perf-ledger.sh` + `scripts/perf_ledger.py`): the release gate (PERF-001/PERF-008). It runs the unattended harnesses, resolves every metric declared in `docs/evidence/perf-thresholds.json` out of their reports, and answers with one JSON + Markdown scorecard and one exit code. Budgets come from the Target column below; nothing is invented in the contract. An absolute miss fails the run; a regression beyond 15% (latency) or 20% (footprint) against the committed baseline is reported as a candidate, because PERF-008 requires three stable runs before a regression counts. The standalone `PORTAVOZ_PERF_STRICT=1` switch still turns one candidate into an operator-requested blocker; candidate automation instead owns the fixed three-run D401 confirmation and never treats a single candidate as a final regression. A metric whose harness did not run is printed as **not measured** rather than omitted, and the run claims `authoritative` only when every report comes from one release build on one Apple Silicon machine matching the baseline — hosted CI and mixed hosts stay informational. The gate also refuses to convict on a measurement that disagrees with itself: when a timed metric's p95 exceeds its own p50 by more than 1.25x, the 20 iterations did not agree, so a budget miss is reported as **verdict withheld** rather than a failure, and the run drops to informational because PERF-001's "stable machine" is a claim about the machine's state, not only its identity. The rule applies only to timed units with enough samples for p95 to differ from the maximum — byte deltas move with page granularity rather than with scheduling, and a three-run distribution has no tail to speak of. Each run also stamps the Swift/Xcode toolchain onto every report it produces, because a shift in the numbers is otherwise indistinguishable from a codegen change: when the baseline was measured with a different toolchain — or, like the July 2026 evidence, predates the stamp entirely — the scorecard prints a **Comparability** caveat. That caveat qualifies what a delta can be attributed to; it never costs the run its authority, which PERF-001 grants on the machine alone. `Tests/Tooling/test_perf_ledger.py` covers the budget, regression, honesty, authority, toolchain, selector, and contract rules.

The 8 Aug 2026 audit run on the authoritative reference host passed exact FTS
(23.33 ms), lexical Ask (47.59 ms), and Spotlight at 100k (394.13 ms wall,
136.69 MiB peak), but failed exact semantic cosine at 100k × 512 dimensions:
139.64 ms wall and 141.98 ms CPU against the 100 ms budget. Incremental semantic
footprint remained 8.42 MiB. Detail core read was +18.6% against its comparison
reference, which is only a PERF-008 candidate until three stable runs agree.
Waveform, detail UI, launch, and model/hardware journeys were not measured in
that invocation and therefore received no claim.

D318 profiled the current exact path before changing it: 5,535 of 6,330 sampled
search frames were inside `sqlite3_step`, with 2,997 top-stack `pread` samples
and only 117 in `vDSP_dotpr`. Two stable clean-parent runs still missed at
128.16/129.30 ms and 126.44/127.29 ms wall/CPU p95; a third was visibly
contended. After enabling a local-internal-only 512 MiB `main.mmap_size`, three
independently seeded 20-query Release runs measured wall p95
67.25/63.98/63.49 ms and CPU p95 68.07/64.90/64.30 ms. Incremental process
footprint p95 was 0.16–0.19 MiB because the pages remain file-backed and
demand-paged. The 9 Aug canonical ledger on the same 36 GiB Tahoe reference
host then measured 63.53/64.54 ms wall/CPU p95 and 0.17 MiB incremental
footprint; exact FTS, lexical Ask, and Spotlight also passed their declared
budgets. These same-host synthetic runs prove the implementation effect;
Sequoia and the required 8/16 GiB profiles remain separate gates.

The comparison reference moved forward on 26 Jul 2026 to
`docs/evidence/{scale-baseline,semantic-scale,spotlight-scale}-20260726.json`:
one authoritative run of the same machine, in release, with the toolchain
stamped and every journey inside its budget. The 16-17 Jul files remain
tracked as the D79-D85 optimization record — they are no longer the
reference, and the numbers below still describe what those optimizations
achieved. Adopting a baseline never relaxes a budget: the Target column
is the release contract regardless of which run the deltas are measured
against.

D345 makes future semantic-scale evidence comparable before another baseline
can move. `bench-semantic` schema 2 carries the exact embedding compatibility
profile and asset state, canonical public-synthetic fixture/query-pack
identities, and separate store-open, corpus-seed, warmup-query, and
measured-query wall/CPU distributions. The wrapper snapshots source before the
Release build with a twice-collected digest of the tracked diff plus untracked
path/mode/content, hashes the built CLI, records the Apple toolchain and exact
host, isolates every scale in a fresh process, then revalidates that all identity
surfaces stayed unchanged before atomically publishing an owner-only manifest.
Only a clean 1k/10k/50k/100k matrix with 20 measured queries per scale is
retention eligible. Custom or dirty matrices are labelled development-only.

The single-run and repeated-control wrappers select disposable workspaces from
a validated writable `TMPDIR`, with `/tmp` as the portable fallback. An invalid
temporary root fails with usage status before source collection, and allocation
failure returns the explicit unavailable-workspace status before the Release
build. Neither runner depends on macOS-only `/private/tmp`; output manifests,
comparability identity, and retention rules are unchanged.

`scripts/semantic_scale_manifest.py compare` validates exact JSON shape,
scalar types, finite and monotonic distributions, sample counts, corpus/result
arithmetic, profile dimensions, top-k completeness, host agreement, stage
duplication, and the recomputable comparability digest. Matching schema-2
identities may produce an aggregate comparison with decision authority `none`;
unlike identities produce no timing aggregate. The tracked reconciliation of
the 17 and 26 July schema-1 observations retains their exact 90.218/92.850 ms
wall and 91.257/94.252 ms CPU p95 values but classifies the pair
`not-comparable`, because those legacy artifacts cannot prove source, binary,
profile, asset, fixture, query-pack, and stage identity. This closes the
historical ambiguity honestly; it does not create a current baseline, prove
natural-language quality, or choose an engine.

The D345 implementation preflight passed 396 Python tooling tests, repository
hygiene, a first-party `swift build -Xswiftc -warnings-as-errors`, 2,453 Swift
tests with 14 explicit model/environment skips and zero failures, and strict
SwiftLint across 675 production files with zero violations. A disposable dirty
1k/three-run Release smoke also passed the complete schema-2 assembler and was
correctly marked custom, development-only, and not retention eligible. These
are implementation checks, not a clean canonical performance baseline. The
mandatory real-app bilingual gate also passed 92/92 English and 92/92 Spanish
XCUITests on macOS 26.5.2 (25F84), with zero failures, skips, or expected
failures in either finalized result bundle; the runner restored
`AppleKeyboardUIMode` from 0 to 0. The final Developer ID-signed Dev install
also passed deep strict signature verification while a complete 184-entry
path/metadata/content/xattr manifest proved `/Applications/Portavoz.app`
byte-for-byte unchanged. This host still has no Metal Toolchain, so the Dev
bundle contains no MLX metallib and its built-in MLX engine remains disabled;
that environment limit is separate from the semantic runner's Apple Natural
Language compatibility profile.

D346 retains repeated current-control evidence without retaining raw
manifests. `scripts/run-semantic-control-baseline.sh` fails fast on a dirty
checkout, alternates three one-vector and three three-vector matrices, fences
source before publication, validates both receipts, and publishes them
owner-only. `scripts/semantic_scale_manifest.py baseline` requires exactly three
unique clean same-identity observations, canonical scales, 20 measured queries
per scale, and either one canonical query vector or the separately scoped
three-vector diagnostic. It rejects copied or missing observations, dirty
source, identity/configuration drift, unsupported variants, and measured-query
wall/CPU instability. The established 1.25 limit applies both within each
20-sample distribution and across the maximum/minimum p95 observations. The
100k one-vector receipt evaluates the existing 100 ms wall-and-CPU target.

The aggregate receipt preserves the full content-free comparability payload,
three raw-observation SHA-256 digests, three distinct measurement-payload
digests, all four scales, and the three content-free timing/footprint
distribution rows needed to recompute every summary and stability ratio. Its
own SHA-256 covers the complete retained result. Only
`measuredQueries` has enough samples for a stability verdict. Store-open and
corpus-seed have one sample per process and warmup has two, so their variability
is disclosed but diagnostic. In this collection the 100k corpus-seed wall ratio
was 1.413 for one variant and 1.636 for three variants; neither is silently
called stable and neither invalidates a stable query-latency receipt.

Three alternating clean D345 observations on the Mac16,6 reference host under
macOS 26.5.2 produced the following p95-across-observation p95 values:

| Segments | 1 variant wall / CPU | 3 variants wall / CPU |
|---:|---:|---:|
| 1,000 | 1.169 / 1.193 ms | 1.399 / 1.426 ms |
| 10,000 | 7.105 / 7.244 ms | 7.958 / 8.087 ms |
| 50,000 | 37.185 / 37.895 ms | 43.067 / 41.517 ms |
| 100,000 | **73.921 / 74.503 ms** | **80.374 / 81.627 ms** |

The canonical 100k measured-query maximum is under the 100 ms target. Its
maximum within-run wall/CPU ratios were 1.028/1.025 and across-run ratios were
1.038/1.033. The three-variant diagnostic ratios were 1.026/1.025 and
1.024/1.027 respectively. The tracked receipts are
`docs/evidence/semantic-scale-current-control-20260813.json` and
`docs/evidence/semantic-scale-three-variant-diagnostic-20260813.json`; they have
different identities and are never combined into a delta. The canonical
receipt owns only a one-host current-control budget result. Cross-host,
Sequoia, other memory profiles, retrieval/answer quality, real meetings, and
engine selection remain unproved.

The final D346 gate passed 406 Python tooling tests, repository hygiene, the
strict current-SDK warnings-as-errors build, 2,453 package tests with 14
explicit model/environment skips and zero failures, ShellCheck/shfmt for the
semantic runners, and strict SwiftLint with zero violations across 675 files.
Finalized macOS 26.5.2 (25F84) result bundles passed 92/92 English plus 92/92
Spanish XCUITest cases with no failures, skips, or expected failures;
`AppleKeyboardUIMode` returned to `0` and no Portavoz crash report appeared.
The Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled and
deeply verified. An exact before/after comparison kept the notarized release
app's 184-entry content/metadata/xattr/identity manifest unchanged at SHA-256
`8192f7b9b61c321c93e8b4d273b578779c7753aee1fb17f4badff4ae6de49b53`.
The host still lacks the optional Metal Toolchain, so the Dev bundle has no
MLX metallib; that does not change the synthetic semantic-control result.

D347 adds the fail-closed cross-host qualification layer without inventing
field evidence. `scripts/semantic_scale_manifest.py cross-host` revalidates and
embeds every supplied D346 receipt, rejects diagnostics, duplicate profiles,
unsupported memory/OS identities, incoherent host target triples, and any
source, Swift/Xcode, profile, fixture, query-pack, stage-policy, scale, or
configuration drift. Only Apple-Silicon hosts qualify. The required set is one
receipt for each shared resource profile: 7–10 GiB (`memory-8gb`), 14–18 GiB
(`memory-16gb`), and at least
32 GiB (`reference`). Those three receipts must collectively cover Sequoia
(major 15) and Tahoe (major 26). This is the established three-profile/two-OS
contract, not an unapproved six-cell Cartesian expansion.

The host-derived Swift target may differ only when its architecture and macOS
major match the sealed host; Swift and Xcode version/build identity must remain
exact. Each host's Release binary stays distinct and fully retained. The
matrix embeds the complete aggregate receipts, recomputes every coverage,
comparability, outcome, reason, and authority surface, and seals the result
with its own SHA-256. Missing profiles or an OS family produce
`incomplete-required-matrix` with cross-host authority `none`. A complete set
reports either a current-control budget pass or fail; even a pass has no
cross-host regression, retrieval quality, answer quality, or engine-selection
authority.

The tracked
`docs/evidence/semantic-scale-cross-host-readiness-20260819.json` contains the
only real receipt currently available: Tahoe on the 36 GiB reference host. It
is therefore an explicit 1/3 incomplete result, naming the missing 8 GiB,
16 GiB, and Sequoia evidence rather than synthesizing it. Both semantic
collectors accept `PORTAVOZ_SEMANTIC_SOURCE_ROOT`, so the current validation
tool can build and measure a separate clean worktree at the exact D345 source
commit named by that receipt. Tool and source roots never become one dirty
identity by accident.

The final D347 gate passed 416 Python tooling tests, repository hygiene, the
strict current-SDK warnings-as-errors build, 2,453 package tests with 14
explicit model/environment skips and zero failures, ShellCheck/shfmt for both
semantic runners, and strict SwiftLint with zero violations across 675 files.
Finalized macOS 26.5.2 (25F84) result bundles independently report 92/92
English plus 92/92 Spanish XCUITest cases, with no failures, skips, or expected
failures; `AppleKeyboardUIMode` returned to `0` and no Portavoz crash report
appeared. The Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled
and deeply verified. An exact before/after comparison kept the notarized
release app's 184-entry content/metadata/xattr/identity manifest unchanged at
SHA-256 `008b0ffee8537125c66bfd8b5e3a45deb9744d064215318e717aa0dbc06ed33f`.
The host still lacks the optional Metal Toolchain, so the local Dev bundle has
no MLX metallib; that does not change the D347 evidence contract or its honest
1/3 outcome.

D348 characterizes and hardens the already-existing speaker-turn retrieval
candidate without changing the live index. Unit coverage requires every
derived chunk to carry the exact accepted correction revision, rejects the
presentation-only unavailable sentinel, and proves revision-only publication
changes retain stable chunk/source identity while returning current fence
values. Architecture policy keeps the source contract mandatory at the
chunker and explicit in the public synthetic benchmark.

The final D348 gate passed 416 Python tooling tests, repository hygiene, the
strict current-SDK warnings-as-errors build, 2,455 package tests with 14
explicit model/environment skips and zero failures, the 176-case architecture
subset, and strict SwiftLint with zero violations across 675 files. Finalized
macOS 26.5.2 (25F84) result bundles independently report 92/92 English plus
92/92 Spanish XCUITest cases, with no failures, skips, or expected failures;
`AppleKeyboardUIMode` returned to `0` and no Portavoz crash report appeared.
The Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled and
deeply verified. An exact before/after comparison kept the notarized release
app's 184-entry content/metadata/xattr/identity manifest byte-for-byte
unchanged at SHA-256
`008b0ffee8537125c66bfd8b5e3a45deb9744d064215318e717aa0dbc06ed33f`.
This remains local Tahoe-family automation rather than physical Sequoia,
separate Tahoe hardware, private-corpus answer quality, or a live retrieval
cutover.

D349 adds a deterministic short conversation-window retrieval candidate
without changing product serving. Nine focused chunking tests cover exact turn
topology, three-turn/non-overlap bounds, inherited character/duration/gap
append budgets, indivisible over-budget source isolation, anonymous actor
handling, text-correction locality, explicit resource-bound and topology-change
reflow, and fail-closed revision validation. The Ask benchmark
adds one canonical-v2 projection test:
the two same-actor turns in each meeting become one four-source unit, and
queries matching either half retain the same ordered canonical membership.
Tooling coverage proves the paired runner publishes candidate-specific
owner-only artifacts, defaults compatibly to speaker-turn, admits the exact
conversation-window adapter, and rejects unregistered candidates before source
inspection. Architecture policy keeps the candidate out of product
composition. Clean paired quality, resource, and correction-cost evidence is
still uncollected, so D349 conveys no parity or serving claim.

The final D349 gate passed 421 Python tooling tests, repository hygiene, the
strict current-SDK warnings-as-errors build, 2,466 package tests with 14
explicit model/environment skips and zero failures, the 177-case architecture
subset, and strict SwiftLint with zero violations across 676 files. Finalized
macOS 26.5.2 (25F84) result bundles independently report 92/92 English plus
92/92 Spanish XCUITest cases, with no failures, skips, or expected failures;
`AppleKeyboardUIMode` returned to `0` and no recent Portavoz crash report
appeared. The Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled
and deeply verified alongside the signed `app.portavoz.mac` release bundle. An
exact before/after comparison kept the notarized release app's 184-entry
content/metadata/xattr/identity manifest byte-for-byte unchanged at SHA-256
`008b0ffee8537125c66bfd8b5e3a45deb9744d064215318e717aa0dbc06ed33f`.
This is local Tahoe-family automation, not physical Sequoia evidence, a clean
paired candidate-quality result, or authority to change product retrieval.

D350 adds a fail-closed semantic-boundary proposal preflight without adding a
chunker, model runtime, storage, or product composition. Eleven focused cases
cover canonical shared and language-partitioned English/Spanish identity,
order-independent fingerprints, behavioral-fence changes, canonical signed
zero, scope/source/actor refusals, bounded resources, stable candidate identity,
unversioned tokenizer refusal, embedding-profile and cosine validation,
language ambiguity, and prevention of one profile impersonating two isolated
spaces. One architecture ratchet requires the benchmark-only, complete-turn,
non-overlap, actor-preserving, model-profile, bilingual, and content-free
fingerprint fences while keeping NaturalLanguage, StorageKit, and product
composition outside this boundary. Admission proves proposal shape only; no
semantic-boundary quality, model suitability, asset availability, correction
cost, or serving claim exists.

The final D350 gate passed the current-SDK warnings-as-errors build, 2,478
package tests with 14 explicit environment/model skips and zero failures, 421
tooling tests, repository hygiene, the 178-case architecture subset, and strict
SwiftLint with zero violations across 677 Swift files. Independently inspected
macOS 26.5.2 (25F84) result bundles passed the complete 92/92 English and 92/92
Spanish real-app XCUITest catalogues with no failures, skips, or expected
failures. Keyboard Navigation returned to `0`, and no recent Portavoz crash
report appeared. The signed local-only `app.portavoz.mac.dev` bundle was
reinstalled and deeply verified; an exact before/after comparison kept the
notarized `app.portavoz.mac` release bundle's 184-entry recursive
content/metadata/hex-xattr manifest, designated requirement, and bundle ID
unchanged at SHA-256
`29a860424136cfb5f398012de8dce16a1e8305e883fb99223602d75f501f51f3`, and
its deep signature remained valid. The Dev build still lacks the optional Metal
Toolchain and MLX metallib. This is Tahoe-family local automation, not physical
Sequoia, independent Tahoe hardware, model-quality, or serving evidence.

D351 implements the first D350-admitted semantic-boundary candidate without
changing product serving. Eleven focused chunker cases cover adjacent join and
similarity split behavior, exact ordered actor/source topology, distinct
English/Spanish spaces, forced language transitions, unknown/mixed-language
isolation without vectorization, shared-space refusal, wrong
language/profile/dimension and invalid numeric vectors, the three-turn resource
and append-only oversized-turn ceilings, cancellation propagation, correction
reflow and delta identity, and a 10,000-turn
characterization. The scale case proves one vector request per supported turn,
at most three turns per output, and complete non-repeated source membership; it
does not claim total constant memory because the canonical turn projection and
output remain materialized.

Twelve Ask benchmark cases include static profile/proposal validation, a live
current-host `NLEmbedding` English/Spanish vector smoke, deterministic semantic
corpus projection with exact ordered sources, dynamic adapter identity, and a
retrieval-unit/adapter mismatch refusal. The paired Python tools accept only
`semantic-v1.` followed by one lowercase 64-hex proposal fingerprint, publish
candidate-specific owner-only artifacts, and reject malformed or spoofed
semantic identities. An architecture ratchet keeps NaturalLanguage in the CLI
adapter and keeps the chunker out of the app and StorageKit. The 0.60 English
and 0.75 Spanish thresholds came from a tiny current-host diagnostic probe and
remain provisional fingerprinted benchmark inputs. No accepted paired quality,
resource, correction-cost, private-corpus, physical Sequoia, or independent
Tahoe evidence exists yet.

The final D351 gate passed the current-SDK warnings-as-errors build, 2,494
package tests with 14 explicit environment/model skips and zero failures, 425
tooling tests, repository hygiene, the 179-case architecture subset, and strict
SwiftLint with zero violations across 679 production Swift files. Independently
inspected macOS 26.5.2 (25F84) result bundles passed the complete 92/92 English
and 92/92 Spanish real-app XCUITest catalogues with no failures, skips, or
expected failures. Keyboard Navigation returned to `0`, and no Portavoz crash
report appeared during the gate. The signed local-only `app.portavoz.mac.dev`
bundle was reinstalled and deeply verified; an exact before/after comparison
kept the signed `app.portavoz.mac` release bundle's 184-entry recursive
content/metadata/hex-xattr manifest and bundle ID byte-for-byte unchanged at
SHA-256
`3c7c15fa935b3034d0145ebb1c019e668c704ee80bb4224a42469cc40f2f8c0f`, and
its deep signature remained valid. The Dev build still lacks the optional Metal
Toolchain and MLX metallib. This is Tahoe-family local automation and a live
current-host vector smoke, not physical Sequoia, independent Tahoe hardware,
accepted semantic quality/resource/correction evidence, or product-serving
authority.

D352 closes a determinism hole found while collecting the first clean D351
pair. Three fresh Release processes on the same commit, build, host, fixture,
control, and dynamic candidate produced the same blocked gates, Recall@10,
hard-negative counts, and zero invalid/stale citations, but equal-best-rank
semantic hits exchanged adjacent positions. The segment-control Hit@1 varied
from 0.510638 to 0.514894; candidate Hit@1 varied from 0.719149 to 0.723404.
The root was not vector or citation drift: `LocalAskMeetingRetrieval` sorted a
best-rank dictionary by rank alone, allowing Swift's process-randomized key
iteration to decide equal ranks.

Ask now breaks equal semantic best ranks by earliest deterministic query
variant and then stable result UUID before RRF. A 256-identity regression proves
rank-first/variant-second/UUID-third order regardless of dictionary insertion.
The clean-pair runner alternates three fresh Release CLI processes per role and
requires each role's complete schema-2 observations to be byte-identical before
evaluation. A forged repeat causes complete staging
cleanup and no output; a valid pair adds one owner-only, content-free
`ask-quality-determinism` receipt with the repetition count and SHA-256 digests
of both observations and the comparison. Runs below three or above five fail
before source inspection. This is a user-visible stability correction and an
evidence gate, not a relevance improvement or semantic-candidate selection.
The D351 diagnostic remains blocked because the candidate added 39 hard-
negative hits and lost code-switched and same-language relationship parity;
resource and correction-cost characterization remain open.

The final D352 gate passed the Swift 6 warnings-as-errors build, 2,496 package
tests with 14 explicit environment/model skips, 427 tooling tests, the 180-case
architecture subset, repository hygiene, and strict SwiftLint with zero
violations across 679 files. Independently inspected macOS 26.5.2 (25F84)
result bundles passed the complete 92/92 English and 92/92 Spanish XCUITest
catalogues with no failures, skips, or expected failures. Keyboard Navigation
returned to `0`, and no Portavoz diagnostic appeared during the gate. The
signed `app.portavoz.mac.dev` bundle was reinstalled and deeply verified while
the notarized `app.portavoz.mac` release retained its exact 184-entry structured
manifest (`008b0ffee8537125c66bfd8b5e3a45deb9744d064215318e717aa0dbc06ed33f`)
and JSONL manifest (`3c7c15fa935b3034d0145ebb1c019e668c704ee80bb4224a42469cc40f2f8c0f`),
plus a valid deep signature. The local Dev app remains unnotarized and lacks the
optional Metal Toolchain/MLX metallib. This is Tahoe-family host automation,
not physical Sequoia, independent Tahoe hardware, accepted model quality,
resource/correction cost, or product-serving authority.

D353 adds a threshold-free, content-free construction and correction-cost
matrix for all four SEARCH-4b unit roles. `make retrieval-chunk-evidence`
requires one clean commit, verifies the canonical public fixture, builds one
Release CLI, fingerprints the fixture and Swift toolchain, and rotates segment,
speaker-turn, conversation-window, and semantic-boundary roles through three
to five fresh processes. Every observation is also bound to an explicit host
profile, runtime OS/hardware, build identity, and exact dynamic semantic
adapter. Non-resource structure must agree exactly across repetitions; any
drift removes staging and publishes nothing.

The measured lifecycle is deliberately narrow. Apple model preparation occurs
before sampling and asset download is forbidden. Full-corpus candidate
construction records wall/CPU time, baseline/peak/ending physical footprint,
resulting unit/source/turn counts, and semantic boundary counters. Seven
one-meeting scenarios cover publication fences, normalization-equivalent text,
replacement text, actor reassignment, language change, structural split, and
structural merge. Each records retained/upsert/removed units plus resource and
semantic vector-call counts. These values do not include a persistent index
write, query, answer, asset download, or product maintenance lifecycle.

The validator rejects unexpected fields and explicit text, meeting/source/unit
identities, vectors, model names, queries, and paths. Complete observations and
their aggregate receipt are atomically published with directory mode 0700 and
file mode 0600. The receipt remains research-only with selection/performance
`not-evaluated`. The public fixture exposes a material evidence gap: its 120
complete turns are mixed-language, so the partitioned candidate correctly
performs zero baseline vector calls. The receipt is therefore blocked for
semantic resource coverage until a truthful homogeneous-turn bilingual
resource fixture exists. This result cannot be promoted to physical Sequoia,
independent Tahoe hardware, private-corpus, model-quality, or serving evidence.

D354 supplies that missing public resource fixture without changing the judged
quality pack. `scripts/retrieval_chunk_resource_fixture.py` deterministically
generates and verifies 60 meetings, 480 segments, and four two-segment turns per
meeting: exactly 120 homogeneous English and 120 homogeneous Spanish turns. It
rejects duplicate keys, unexpected fields, noncanonical content, order drift,
and mixed-language complete turns. The Swift loader independently checks
bounded identities, meeting consistency, strict timestamps, homogeneous turns,
and nonzero bilingual coverage. Both loaders cap input reads before decoding so
the 8 MiB limit does not require loading an oversized fixture first.

Resource observations are now schema 2. Before semantic sampling, one fixed
public English phrase and one fixed public Spanish phrase must successfully
vectorize through the admitted exact profiles; content-free preparation counts
prove those calls occurred outside resource samples. The canonical fixture
generation, digest, exact language coverage, clean source, Release toolchain,
host profile, and one cross-role host identity are receipt-bound. Duplicate-key
or nonstandard observation JSON fails closed. Fixture validation and digesting
share one byte snapshot, and source cleanliness is checked before compilation,
after the Release build, and before receipt publication. A complete 240/240
semantic turn count produces only `review-required`; incomplete coverage
remains blocked.
This closes the public-fixture coverage defect, not model quality, performance,
private-corpus, cross-host, physical Sequoia, independent Tahoe, or product
serving acceptance.

D357 makes existing encrypted voice identity authoritative until the user
explicitly resets it. Store regressions cover a missing or malformed key,
authentication/ciphertext corruption, decode failure, preservation before a
refused save or gallery mutation, encrypted round trips, and successful
re-enrollment only after deletion. Architecture policy rejects silent empty
gallery fallbacks and force-unwrapped sealed representations. The dedicated
real-app Settings journey reaches both independent unavailable states through
the temporary-store-only fixture, verifies their error, Retry, and destructive
recovery controls, exercises both resets, and observes a usable empty state.
Its first focused run exposed that an empty conditional SwiftUI group provided
no reliable lifecycle anchor for the gallery's initial task; a rendered loading
state now owns that first load.

The final D357 gate passed the current-SDK Swift 6 warnings-as-errors build,
2,532 package tests with 15 explicit environment/model skips and zero failures,
repository hygiene, the complete 93-test UI scope catalogue, localization JSON
validation, abrupt-exit/source-policy checks, and strict SwiftLint with zero
violations across 684 production Swift files. Independently inspected macOS
26.5.2 (25F84) result bundles passed all 93 English and all 93 Spanish real-app
XCUITest cases with no failures, skips, or expected failures; no new Portavoz,
XCTRunner, or xctest diagnostic report appeared during the run. The signed
local-only `app.portavoz.mac.dev` bundle was reinstalled and passed deep strict
verification. An exact before/after comparison kept the signed
`app.portavoz.mac` release bundle's 184-entry recursive
content/metadata/hex-xattr/bundle-ID/designated-requirement manifest unchanged
at SHA-256
`518bb2cc99f225d7a712221125a29729e15356c7c6d2fe3ece96b3c8d029a3a3`, and
its deep signature remained valid. The host still lacks the optional Metal
Toolchain, so this Dev bundle has no MLX metallib. This is Tahoe-family local
automation, not physical Sequoia, separate Tahoe hardware, VoiceOver, real
Keychain-loss recovery, or recovery of an actual unreadable biometric store.

## Measured numbers (MacBook Pro M4 Max 36 GB, macOS 26, Jul 2026)

| Metric | Target | Measured |
|---|---|---|
| Live transcript lag | < 2 s | **p50 0.24 / p95 0.53 / max 0.56 s** |
| Batch Parakeet | — | ~100x real time (18 passes without degrading live processing) |
| Refine Whisper (22 real min) | > 15x | **23–42x** (1314 s in 31–56 s) |
| Mic/system drift | < 50 ms / 30 min | **4 ms / 22 min** (+4 ppm linear) |
| DER (AMI 2 speakers) | < 15% | **7.6%** (collar 0.25 s) |
| ES summary of EN meeting | < 30 s | **3.8 s** (glossary intact) |
| Former VPIO AEC convergence | historical only | **~2 s**; D125 removes VPIO from meeting capture because call coexistence is the higher-order requirement |
| Cold start | < 1.5 s | **0.94 s cold / ~0.26 s warm** (`--bench-startup`) |
| FTS at 1k meetings (80k segments) | < 50 ms | **p50 22.8 ms / p95 23.9 ms** (`portavoz-cli bench-fts`) |
| Exact FTS at 100k segments | p95 < 50 ms | **p50 30.25 ms / p95 30.99 ms** (`bench-scale`, D81) |
| Lexical Ask at 100k segments | p95 < 100 ms | **p50 66.45 ms / p95 66.89 ms**, down from 111.19 ms through bounded per-term RRF (D81) |
| Semantic cosine at 100k × 512 dimensions | p95 < 100 ms | ✅ **wall p50/p95 88.81/90.22 ms; CPU p50/p95 89.93/91.26 ms**, down from 307.05/325.41 and 311.46/328.43 ms; **8.42 MiB** incremental footprint p95 (D83) |
| Semantic cosine with bounded local mapping at 100k × 512 dimensions | p95 < 100 ms | ✅ 9 Aug canonical Release ledger: **wall/CPU p95 63.53/64.54 ms; 0.17 MiB incremental process footprint**; three independent A/B runs also held wall p95 63.49–67.25 ms and CPU p95 64.30–68.07 ms (D318) |
| D330 accepted-only semantic regression check at 100k × 512 dimensions | p95 < 100 ms | ✅ 11 Aug 20-sample Release development check: **wall/CPU p95 77.09/78.29 ms; 0.16 MiB incremental process footprint; 12/12 results**. This preserves the accepted fast-path budget but is not a correction-heavy or multi-host field baseline. |
| D346 clean repeated schema-2 semantic current control at 100k × 512 dimensions | p95 < 100 ms | ✅ 13 Aug one-vector wall/CPU p95 maximum **73.92/74.50 ms** across three stable same-identity observations; separate three-vector diagnostic **80.37/81.63 ms**, no cross-identity delta or budget authority |
| D347 cross-host semantic current-control matrix | 8 GiB + 16 GiB + reference; Sequoia + Tahoe | **Incomplete 1/3**: Tahoe/reference present; 8 GiB, 16 GiB, and Sequoia receipts missing; cross-host authority `none` |
| Waveform, 55.9-minute dual channel / 600 buckets | first wall < 150 ms; repeat wall/CPU p95 < 100 ms | ✅ first wall/CPU **109.25/94.81 ms**; repeat wall/CPU p50 **69.22/70.10 ms**, p95 **70.11/71.33 ms**, down from 747.53/754.79 ms; **0.33 MiB** incremental footprint p95; exact fingerprint preserved and replacement changes it (D84) |
| Spotlight projection, 100k meetings | wall/CPU p95 < 500 ms; absolute/incremental footprint < 160/96 MiB | ✅ wall/CPU p95 **425.64/423.58 ms**, down from 22,085.35/22,720.40 ms; **141.14/76.03 MiB** absolute/incremental footprint p95; exact fingerprint preserved. Synthetic 1k protected named-index delivery: **21.19 ms**, cleanup succeeded (D85) |
| Detail core read, 2 h / 5k segments | diagnostic | **p50 16.31 ms / p95 17.22 ms** |
| Detail first content, 2 h / 5k segments | p95 < 300 ms | **91.87 ms** single signpost run, down from 522.30 ms; **zero hangs**, down from one 515.86 ms hang (D80) |
| Meeting health, 2 h / 5k → 8 h / 20k | derived-policy diagnostic | **p95 9.94 ms → 41.39 ms**, down from 347.58 ms → 5,385.76 ms |
| RAM by phase (`--bench-record 60 --bench-log <file>`, via `open -n`) | < 800 MB peak while recording / < 200 MB idle post-meeting | **20 MB without models → ~515 MB engines loaded → 569–795 MB peak while recording (LIVE diarization included) → 140–160 MB after the meeting**. The original target (500 MB) was set before adding live diarization; revised Jul 2026 |
| Embedded summary RAM (MLX) | transient, not resident | **~2.4 GB during generation**; the AppServices-owned `MLXSummaryRuntime` releases it only after 120 s idle (previously it remained resident forever) |

## Real bugs found and fixed (what an agent must know)

| Bug | Root cause | Fix |
|---|---|---|
| Meeting collapsed from 66→3 segments during refine | WhisperKit `concurrentWorkerCount` default 16 → race on shared decoder; its chunker SWALLOWS per-chunk errors | `concurrentWorkerCount: 1` + coverage retry |
| Deterministic collapse with vocabulary | promptTokens derail windows that do not mention the terms; raw coverage was misleading (valid spans, empty text) | coverage over CLEAN segments + retry without prompt + natural-language phrase |
| Silent meeting "sin voz" | WhisperKit EnergyVAD absolute threshold 0.02 | prior peak normalization |
| Repeated `Yo: .` and `Me: Thank you.` without speaking | Loose-punctuation deltas and Whisper silence boilerplate at VAD cadence | lexical hygiene + repeated-boilerplate filter on mic |
| Mic died when headphones connected (min 24/30) | AVAudioEngine stops on config-change, silent stream | restart + resample + silence gap |
| Phantom "Yo" with speakers | mic captured system audio (100% echo; early text-only dedup covered only 57%) | Refined microphone/system overlap filtering after capture; VPIO removed from meetings by D125 after it interfered with live calls |
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
code failure. The host preflight now rejects already-visible SecurityAgent or
Notification Center alerts plus active Xcode test commands and UI runners, but
it cannot identify every generic accessibility client or reserve the host after
its final sample. Run the UITests without concurrent automation clients and
classify any later invalidation from the result bundle.

**Environment flake — foreground ownership (Aug 2026):** an unrelated app can
raise a window after Portavoz has activated but before XCUITest synthesizes its
next event. The result bundle then names that external window as an
interrupting element; Command-comma or the pending click can be consumed
without exercising the intended Portavoz control. Shared Settings helpers
reassert foreground ownership and make one bounded retry, verifying the exact
destination before continuing. They defer the assertion until both attempts
are exhausted so a recovered interaction can actually recover the test. This
does not make concurrent automation supported: classify the result from its
activity tree and rerun with other UI-test clients idle.

## UI-suite cost model and the journey pattern (Aug 2026)

Measured on the full bilingual run of Aug 7 (132 cases, ~1,940 s of test
time): the per-case cost is dominated by a fixed launch-and-settle overhead
of roughly 12–15 s — app launch, temp-store seeding, library settle,
navigation — while each additional verified stage inside a running case costs
only ~1–2 s. The most expensive cases (structural corrections at ~41 s,
commitment inbox at ~33 s) are already multi-stage journeys; the waste
concentrates in single-assertion cases that pay the full launch for one
check.

**Default new coverage to single-launch journeys.** The reference is
`testSkillProposalJourneyFromBannerToReceipt` (D316): banner → exact preview
→ confirm → clipboard artifact byte-for-byte equal to that preview → durable
receipt → offer retirement →
durable dismissal — six verified stages in one ~16 s launch, where four
separate cases would spend ~60 s. Split into separate cases only when stages
genuinely need different seed flags or launch arguments; never merge cases
across different launch configurations, because a shared launch that half
the assertions must un-do stops being evidence.

The current inventory is 92 cases per locale (184 bilingual). The Aug 7 cost
sample above predates twenty-six cases per locale (fifty-two executions) and
remains a timing model, not a claim that the smaller 132-execution inventory is
current.

**D321 retry gate.** Three package cases pin the proposal UUID across model
routing, resolve the exact durable idempotency-key owner after presentation
reconstruction, and ratchet the as-built decision; the existing proposal
factory case also verifies that an injected UUID is preserved. The routing
case pins the original `proposedAt` across retries and the architecture ratchet
forbids rebuilding it from `Date()` at Confirm time, composing with the existing
admission tests that reject a proposal after 15 minutes. One real-app
journey per locale uses a disposable-store-only fail-once pasteboard boundary:
the first handoff must leave the exact preview open with a visible failure, the
second must reuse the original claim, settle a receipt, dismiss the sheet, and
place the byte-for-byte approved artifact on the system pasteboard. Normal
application construction cannot enable the fixture. This is retry evidence,
not a claim about external egress, schema migration, or a real-device failure.

**D322 resident brief gate.** Eight new package cases cover bounded opaque event
identity, pause/disable/dismiss/settled offer policy, failed retry, exact
proposal arguments, exact approved-material delivery, cancellation-fenced
resident state, and the disposable event source; one architecture case ratchets
no-prompt EventKit lookup, exact re-resolution, ExecuteSkill handoff, and the
two-flag UI fixture boundary. One new real-app journey per locale mounts the
production menu-bar content/model in a disposable main-window host, asserts the
exact cited preview and local capabilities, confirms it, compares the result,
requires offer retirement, and follows the receipt into Skills Settings. This
does not automate the SystemUIServer-owned status item or prove Calendar/TCC
behavior on a physical Sequoia or Tahoe Mac; that shell remains field evidence.

**D323 Reminder Draft gate.** Twenty-one package cases cover the bounded batch
surface, pause/disable/dismiss/receipt policy, exact canonical proposal,
durable retry ownership, per-window permission state machine, target bounds,
success and ambiguous-outcome verification, adapter authorization, exact
destination drift, and one same-store save. One architecture ratchet pins
platform isolation, the 200-row
ceiling, explicit permission control, exact target, purpose strings in both app
bundle paths, and D323. One new real-app journey per locale starts with the
disposable permission state undetermined, proves no confirm action exists
before the explicit access control, shows the exact fake Reminders list,
confirms one seeded commitment, requires subject offer retirement and receipt,
then verifies the same durable receipt in Skills Settings. The fake never
touches host TCC or Reminders; physical Sequoia/Tahoe permission and save
behavior are a separate field gate.

The exact D323 closure passed all 74 real-app cases in English and all 74 in
Spanish with zero failures or skips on Apple Silicon macOS 26.5.2. This host
evidence covers Tahoe only; it does not close the physical Sequoia field gate.

**D324 native Stop gate.** Three new package cases cover cold request
republishing, synchronous one-shot resolution, every recording-phase
disposition, and the in-flight duplicate fence; the two existing Start cases
remain green. The architecture ratchet pins the exact two-action metadata set,
the dual availability-safe foreground declarations, the SDK-only boundary,
and the dedicated non-starting recovery route. Metadata extraction produced
exactly `StartRecordingIntent` and `StopRecordingIntent`. The conservative
changed-file selector passed 24/24 real-app journeys in English and 24/24 in
Spanish, including URL entry, native Start, native Stop after `.recording`,
typed no-audio recovery, launch recovery, recording failures, main-shell,
localization, Commitment Radar, and Settings canaries. This local Tahoe-host
evidence does not invoke a physical Siri phrase or saved Shortcut and does not
close Stop registration on Sequoia; those remain field gates.

**D325 App Entity gate.** Eleven package cases add bounded lookup validation,
literal `%`/`_` handling, exact identifier order, canonical-person and
confirmed-commitment exclusion rules, app-value mapping, navigation buffering,
typed malformed-ID recovery, exact Radar filter precedence, and model focus
restore behavior. The architecture ratchet pins the SDK-only import boundary,
standard dependency injection, three entities/queries/open actions, five-action
metadata contract, availability-gated `IndexedEntity`, and explicit absence of
entity publication. Metadata extraction must report exactly five actions,
three entities, and three queries. One real-app case per locale performs three
isolated disposable launches through the same production SDK-only open-action
logic used by each `OpenIntent`: meeting
opens exact Detail, person shows only the canonical owner's commitments, and
commitment opens one exact item before **Show all** restores unrelated Radar
content. This is D325 app/navigation evidence; D326 below closes the local
entity-publication implementation. Physical Shortcuts/Siri registration,
system picker/search presentation, cold database recovery, and Sequoia/Tahoe
parity remain separate gates.

**D326 protected entity-publication gate.** The Spotlight package boundary now
adds one consistent meeting/person/commitment projection case, two client-state
mode and coverage cases, one production App-Entity mapping/attribute case, and
the existing coalescing, unchanged-state, retry-exhaustion, recovery, cleanup-
relaunch, and content-free telemetry cases. App Entity attributes separately
prove meeting title/date/capped body, canonical-person name, and commitment
title/due date. The source compiles under strict Swift 6 with the 14.4 target;
the macOS 15 backend is availability-gated and keeps the non-Sendable
AppIntents index receiver task-local. Metadata must remain exactly five actions,
three entities, and three queries. Bilingual XCUITest reuses the exact entity
open-route journey because temporary stores deliberately suppress host Spotlight
publication. Feature-owner tests also require successful commitment confirmation
and Radar mutations to wake search reconciliation while failed writes stay
silent. This proves app handoff and invalidation without contaminating the
user's index; physical results, picker registration, Siri disambiguation, and
cold recovery remain Sequoia/Tahoe field gates.

**D329 correction-fenced Spotlight gate.** Five new real-Store projection cases
require an active text replacement to remove the accepted wording, publish its
current corrected text, and drop a stale summary; a regenerated summary with
the exact correction revision becomes eligible. Structural targets remain
absent and allow later accepted rows to fill the 40-row budget; restore returns
the accepted summary/text. Deleting the sparse v36 state makes both correction
lanes fail closed until a transactional rebuild, and reopening a simulated
pre-v36 corrected library backfills that state before the first Spotlight read.
Malformed generation JSON is omitted without failing the library snapshot.
One actor/backend case proves the corrected body changes client state and
causes replacement, while Meeting Detail model cases require successful text
and structural writes—but not failed writes—to request reconciliation. The
architecture ratchet retains the snapshot-local bounded probe and selected
set-based CTE, caps, D313 lane reuse, sparse content-free state, and absence of
ApplicationKit composition or per-meeting reads. Bilingual XCUITest reuses the
exact App Entity route because
temporary stores suppress host indexing; physical result matching and cold
recovery on Sequoia/Tahoe remain field evidence.

**D330 correction-aware semantic gate.** Seven package cases cover the additive
v37 corrected-vector migration, correction-source candidate identity, exact
text and revision fencing, superseded-source rejection, profile invalidation,
non-positive limit bounds, background maintenance, readiness degradation and
recovery, accepted-vector reuse after restore, and the deliberate exclusion of
actively corrected segments from the older identity-only research shadow lane.
The direct exact semantic path reads rank and source-grounded corrected text in
one database snapshot; accepted-only queries retain their sparse probe and
single-table scan. The complete package gate is 2,353 cases (14 environment-
gated), the deterministic tooling gate is 353 cases, and strict SwiftLint is
clean across 652 production Swift files. A 20-sample 100k × 512 Release check
kept the accepted-only path below its 100 ms budget at 77.09/78.29 ms wall/CPU
p95 with 0.16 MiB incremental peak footprint and 12/12 results. That run does
not characterize a correction-heavy corpus, physical Sequoia/Tahoe hosts, or
8/16 GiB memory profiles; those remain explicit field and performance gaps.
Bilingual XCUITest reuses all 77 real-app journeys because D330 changes no
interactive control or presentation structure. The final gate passed 77/77
English cases in one finalized result bundle and the exact duplicate-free
25 + 33 + 19 Spanish catalog partition in three finalized bundles, with zero
failed, skipped, or expected-failure cases in either locale.

**D331 explicit corrected Apuntador review gate.** Package coverage binds the
version-3 operation fingerprint to every generated-row/accepted-source mapping,
preserves first-use evidence order, requires one complete terminal-free pass,
records terminal provenance best effort, rejects contradictory completed passes,
and preserves the snapshot on unavailability, cancellation, incomplete work,
missing evidence, correction drift, or transaction failure. Real-Store cases
verify fixed post-Refine versus meeting-review workflow ownership and prove an
unevidenced reviewed card cannot mutate cards or run history. The adapter's
prior-context lookup uses lower-bound search over sorted segments and
materializes at most 14 rows, with boundary and long-prefix regressions that do
not require macOS 26.

The final static gate passed a Swift 6 warnings-as-errors build, 2,365 package
cases with 14 environment-gated skips, 168 architecture ratchets, 354 tooling
cases, repository hygiene, and strict SwiftLint with zero violations across 654
production files. The complete real-app gate passed 79/79 English and 79/79
Spanish cases in finalized macOS 26.5.2 result bundles, with no failed, skipped,
or expected-failure cases. The signed `app.portavoz.mac.dev` bundle was then
reinstalled with deep strict signature verification; exact bundle metadata,
executable hash, recursive manifest, counts, sizes, and signature prove the
notarized release app remained unchanged. Those runs prove the corrected
refresh and simulated Sequoia preservation against disposable state; they do
not prove Foundation Models assets on a physical Sequoia host, a separate Tahoe
machine, or correction-heavy semantic performance.

**D332 explicit semantic-asset preparation gate.** Five ApplicationKit cases
separate side-effect-free readiness inspection from the sole explicit workflow
that may authorize a download; six presentation cases cover refresh,
single-flight clicks, retryable capture/ordinary failure, terminal readiness,
and the temp-store-only fake. Architecture ratchets keep `requestAssets()` in
the NaturalLanguage adapter, `allowAssetDownload: true` in one ApplicationKit
workflow, concrete model construction in the process runtime, resource
admission before preparation, and stable Settings identifiers. The changed-file
selector maps both new production owners to the Intelligence journey.

The final static gate passed the Swift 6 warnings-as-errors build, 2,377 package
cases with 14 environment-gated skips, 169 architecture ratchets, 355 tooling
cases, repository hygiene, and strict SwiftLint with zero violations across 656
production files. The first complete English UI pass correctly found that the
new section moved the existing Whisper action outside the structural journey's
bounded viewport; after increasing its viewport-aware wheel step, the full
real-app rerun passed 80/80 English and 80/80 Spanish cases with no failures.
The Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled and
deeply verified. An exact 183-entry recursive manifest plus root metadata and
signature comparison kept `/Applications/Portavoz.app` unchanged. The current
host lacks Xcode's optional Metal Toolchain, so that Dev build omits the MLX
metallib and disables the embedded summary engine; this does not affect the
Apple NaturalLanguage semantic-preparation path and is not evidence for MLX.
Physical clean-install asset behavior and disk deltas on Sequoia and separate
Tahoe hosts remain field evidence.

**D333 capability-derived Skills disclosure gate.** ApplicationKit coverage
requires the four definitions without `sendRemote` to project the bounded
no-direct-network statement and the email/Gist definitions to project an
external-handoff statement, while all current catalogue rows retain explicit
per-proposal approval. The architecture ratchet requires the projection to read
`SkillDefinition.declaresExternalEffect` and `confirmationPolicy`, rejects the
former universal `On this Mac` label, and pins the decision. The existing
single-launch Skills Settings XCUITest journey now asserts one local row, both
external rows, and the per-run approval disclosure in English and Spanish.
This changes no capability, consent, destination, retry, or execution behavior;
physical email/GitHub/Reminders and synced-destination behavior remains field
evidence rather than inferred from labels.

The final static gate passed the Swift 6 warnings-as-errors build, 2,378
package cases with 14 environment-gated skips, 169 architecture ratchets, 355
tooling cases, repository hygiene, and strict SwiftLint with zero violations
across 656 production files. The first complete package run also exposed a
date-dependent graph-projection fixture whose fixed deletion timestamp became
older than its real persisted creation timestamp; deriving the lifecycle from
that persisted value passed ten repeated focused runs before the complete suite
passed. Finalized macOS 26.5.2 result bundles then passed the complete 80/80
English and 80/80 Spanish real-app catalogues with no failures or skips. The
Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled and deeply
verified, while an identical 183-descendant-plus-root release manifest and
signature proved `/Applications/Portavoz.app` unchanged. This host evidence is
Tahoe-only and does not replace physical Sequoia or provider/destination field
validation.

**D327 review-first email gate.** Eleven package cases pin the separate external
registry and intact local no-egress invariant, irreversible explicit capability
contract, exact-one-meeting arguments and keys, existing recap-composer reuse,
missing-summary degradation, proposal shape, egress refusal before any durable
claim/effect, successful retirement/receipt, email-specific preview fencing,
verbatim subject/body delivery, recoverable composer rejection, and the AppKit
boundary's empty recipients plus absence of transport or AppleScript. A shared
one-shot interruption case requires both recap and email offers to remain
absent while their ambiguous `executing` receipts stay visible. A query-shape
case requires one bounded exact-key read for both one-shot offers and only one
additional literal-prefix read when projecting package receipts. The
control-center cases also require the external Skill to be independently
disableable without turning its Settings switch into consent. One real-app
journey per locale opens the exact seeded-summary preview, verifies the
no-recipient and possible-sync disclosures plus localized handoff action,
requires the disposable adapter to leave both clipboard and foreground app
ownership unchanged, then observes the content-free receipt and independent
offer retirement. `meeting-skills` selectors include that journey, and catalog
validation reports 77 complete cases. The disposable adapter cannot prove the
system email client opened; default-client composition on physical Sequoia and
Tahoe remains field evidence.

**D328 review-first Secret Gist gate.** Package coverage pins the separate
external definition, explicit meeting-read/remote-send capabilities, exact
one-meeting argument and one-shot key, canonical Markdown/title/filename
preview, preview-drift refusal before claim or egress, publisher delivery of
the exact approved draft, and an integration journey through disposable
`AppServices`. That journey requires the data-egress event UUID to equal the
Skill proposal UUID, records exactly one `publish-github-gist` event for
`api.github.com`, returns the stable provider-shaped URL, and proves replay
cannot emit a second event. A lower gateway/store case forces the first
transport to fail after its durable attempt, retries the same event UUID, and
requires the primary-key collision to occur before a second URLProtocol start.
Model coverage distinguishes success, retryable
pre-egress setup failure, and outcome unknown with an optional transient URL.
Architecture ratchets require canonical `GistPublisher` and
`URLSessionDataEgressGateway` reuse, deterministic event identity, no direct
`URLSession.shared`/AppleScript path in the Skill adapter, no Gist endpoint
force unwrap, a read-only selectable TextKit long-document viewport, exact
confirmation identifiers, and D328.

One real-app journey per locale opens the complete seeded canonical Markdown,
verifies its slugged filename, `api.github.com` destination, transcript bytes,
and unlisted-link disclosure, then confirms through the no-network disposable
gateway. It requires the returned URL, content-free Skill receipt, visible
privacy egress receipt, independent offer retirement, and the matching Skills
Settings receipt. The fake runs the real request codec, metadata checks,
execution state machine, and disposable store; it cannot prove Keychain access,
GitHub authentication, physical network interruption, browser behavior, or
provider state on Sequoia or Tahoe.

**D335 content-free Skill receipt inspection gate.** Sixteen Skills control
center cases, including six D335 cases, cover a valid retry timeline plus
missing, overlong, malformed, unknown-category, broken-predecessor,
impossible-transition, and stale-tail histories. Storage must read state and at
most 257 event rows in one SQLite
snapshot, enforce a 256-event materialization ceiling, and validate the exact
causal predecessor chain before ApplicationKit replays the typed state machine.
Architecture ratchets keep the audit content-free, bounded, snapshot-consistent,
and separate from execution or retry. The real-app journey opens a recent
receipt from Skills Settings, verifies its privacy disclosure and three-event
localized timeline, closes it, and returns to the same control center row.

The final gate passed the Swift 6 warnings-as-errors build, 2,397 package cases
with 14 environment/model-gated skips, 170 architecture ratchets, 355 tooling
cases, repository hygiene, and strict SwiftLint with zero violations across 660
production files. Finalized macOS 26.5.2 result bundles passed the complete
80/80 English and 80/80 Spanish XCUITest catalogues with no failures or skips.
The Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled and deeply
verified. Exact before/after comparison of the notarized release app's 184-entry
recursive content/metadata manifest, hexadecimal xattrs, signing requirements,
and deep signature kept `/Applications/Portavoz.app` unchanged. This is
Tahoe-family host evidence only; physical Sequoia behavior, separate Tahoe
hardware, VoiceOver review, and provider/destination effects remain field
evidence.

**D336 status-scoped Skill activity gate.** Eighteen Skills control-center
cases cover exact Recent, confirmed-and-Waiting, Attention, and terminal
Completed membership; future unknown states fail closed into Attention. Every
bounded newest-first query is pinned to its direction-matched v39 partial index,
and `EXPLAIN QUERY PLAN` regressions reject a temporary B-tree. Application
coverage pins scope forwarding, while architecture ratchets require a matching
request/snapshot scope and UUID load fence so a cancelled SwiftUI task cannot
publish stale rows. One real-app journey per locale traverses all four scopes
before inspecting the causal receipt; another injects only a non-Recent read
failure and proves stale rows disappear, verified policy controls remain usable,
and retry stays independently accessible.

The final D336 gate passed the Swift 6 warnings-as-errors build, 2,399 package
cases with 14 environment/model-gated skips, 170 architecture ratchets, 355
tooling cases, repository hygiene, and strict SwiftLint with zero violations
across 662 production files. Finalized macOS 26.5.2 result bundles passed the
complete 81/81 English and 81/81 Spanish XCUITest catalogues with no failures or
skips. The Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled and
deeply verified. Exact before/after comparisons kept the notarized release
app's recursive content/metadata manifest, hexadecimal xattrs, and designated
requirement unchanged, and its deep signature remained valid. This remains
Tahoe-family host evidence only; physical Sequoia behavior, separate Tahoe
hardware, VoiceOver review, and the central durable proposal authority remain
open field/product evidence.

**D337 content-free Skill proposal authority gate.** Core and storage coverage
pins nonempty declared/requested input-data classes, reason/subject compatibility,
bounded unique reconciliation, same-version explanation immutability, cascade
cleanup, exact dismissal/confirmation retirement, expiry pruning, catalogue and
policy revalidation, and a newest-first query plan without a temporary B-tree.
The v39→v40 migration preserves existing dismissals and proves that a valid
2,000-byte opaque EventKit identity—including trailing whitespace—can be
durably dismissed without normalization. Architecture ratchets require all
three released producer families to reconcile through the central authority,
keep review identity unrelated to subject/offer identity, exclude content from
the application projection, and retain independent SwiftUI request fencing.
One main real-app journey per locale checks producer-derived why/input rows and
their privacy disclosure; a separate injected proposal-read failure proves no
row is invented and independently verified policy remains usable. Exact preview
and confirmation stay on the original subject surface; workflow actions,
standing rules, physical Sequoia, separate-hardware Tahoe, and VoiceOver review
remain outside this code gate.

The final D337 gate passed the Swift 6 warnings-as-errors build, 2,412 package
cases with 14 environment/model-gated skips, 171 architecture ratchets, 355
tooling cases, repository hygiene, and strict SwiftLint with zero violations
across 668 production files. Finalized macOS 26.5.2 result bundles passed the
complete 82/82 English and 82/82 Spanish XCUITest catalogues with no failures
or skips. The Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled
and deeply verified. Exact before/after comparisons kept the notarized release
app's 184-entry recursive content/metadata manifest, hexadecimal xattrs,
designated requirement, and root metadata unchanged, and its deep signature
remained valid. This is Tahoe-family host evidence only; physical Sequoia,
separate Tahoe hardware, VoiceOver review, and workflow usability remain open.

**D338 central Proposed dismissal gate.** Focused storage/application cases
prove that a random review UUID atomically resolves to the existing
stable-intent tombstone, expired and repeated UUIDs share one unavailable
outcome, a stale reconciliation cannot recreate dismissed authority, and a
claim after dismissal neither writes history nor reaches its effect. Execution
coverage distinguishes one-shot equality from reusable package-offer prefixes,
rejects an unrelated effect slot, fences a new dismissed destination, preserves
an exact owner that committed before dismissal, and keeps opaque EventKit
identity bytes through claim and owner resolution. Architecture
ratchets keep stable offer/subject identity out of SwiftUI, require the bounded
tombstone read in reconciliation and the dismissal check in the claim, and keep
confirmation on its original surface.

Two additional real-app cases per locale use the real Meeting Detail producer.
The success journey dismisses Email Recap by its accessibility-identified
opaque row, reloads Meeting Detail, proves that email remains absent, and keeps
the unrelated recap offer. The failure journey injects only the temp-store
dismissal write, requires the original row plus inline retry to remain, and
proves the subject surface still offers email. These are application and
SQLite concurrency-contract evidence; physical VoiceOver behavior and
cross-process timing on Sequoia/separate Tahoe hardware remain field gates.

The final D338 gate passed the Swift 6 warnings-as-errors build, 2,418 package
cases with 14 environment/model-gated skips, 171 architecture ratchets, 355
tooling cases, repository hygiene, and strict SwiftLint with zero violations
across 668 production files. Finalized macOS 26.5.2 result bundles passed the
complete 84/84 English and 84/84 Spanish XCUITest catalogues with no failures
or skips. The Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled
and deeply verified. Exact before/after comparisons kept the notarized release
app's 184-entry recursive content/metadata manifest, hexadecimal xattrs,
designated requirement, and root metadata unchanged, and its deep signature
remained valid. This is Tahoe-family host evidence only; physical Sequoia,
separate Tahoe hardware, VoiceOver review, and cross-process race timing remain
open field evidence.

**D339 Waiting approval revocation gate.** Three focused use-case tests prove a
verified `confirmed` execution becomes terminal `dismissed` with exactly one
content-free cancel event, a repeated revocation is unavailable, and a run
past begin cannot be cancelled. A real-Store concurrency regression launches
begin and revocation together and accepts only the two legal linearized
histories: confirm/begin with revocation unavailable, or confirm/cancel with
begin observing the settled record. The architecture ratchet keeps proposal
content, idempotency identity, and effect authority outside both the narrow use
case and SwiftUI, and requires every fixture/failure switch to remain behind
the temporary-store boundary.

Two additional real-app cases per locale seed one content-free confirmed run
without calling begin or an adapter. The success journey opens Waiting,
revokes, verifies the localized cancellation event, closes inspection, and
requires the selected Waiting scope to reload empty. The injected write-failure
journey requires the one-event receipt and inline retry to remain without an
invented cancellation event. These tests prove repository and real-app
contracts, not physical VoiceOver behavior or cross-process timing on Sequoia
and separate Tahoe hardware.

The final D339 gate passed the Swift 6 warnings-as-errors build, 2,423 package
cases with 14 environment/model-gated skips, 172 architecture ratchets, 355
tooling cases, repository hygiene, and strict SwiftLint with zero violations
across 669 production files. Finalized macOS 26.5.2 result bundles passed the
complete 86/86 English and 86/86 Spanish XCUITest catalogues with no failures
or skips. The Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled
and deeply verified. Exact before/after comparisons kept the notarized release
app's 184-entry recursive content/identity/metadata manifest, hexadecimal
xattrs, designated requirement, bundle ID, and root metadata unchanged, and
its deep signature remained valid. This is Tahoe-family host evidence only;
physical Sequoia, separate Tahoe hardware, VoiceOver review, and cross-process
race timing remain open field evidence.

**D340 Proposed review-in-context gate.** Application and storage coverage
prove that Settings resolves only an opaque review UUID, revalidates live
proposal authority and policy in one bounded snapshot, and returns an inert
meeting, commitment, or resident-menu-bar destination without claiming or
executing the offer. Missing, expired, dismissed, disabled, malformed, and
concurrently retired proposals share one unavailable result. Real-app journeys
per locale return from Settings to the existing primary meeting window, keep
the original surface responsible for preview and confirmation, and retain the
proposal plus an explicit retry when resolution fails.

The final D340 gate passed the Swift 6 warnings-as-errors build, 2,428 package
cases with 14 environment/model-gated skips, 355 tooling cases, repository
hygiene, and strict SwiftLint with zero violations across 670 production files.
Finalized macOS 26.5.2 result bundles passed the complete 88/88 English and
88/88 Spanish XCUITest catalogues with no failures or skips. The signed
`app.portavoz.mac.dev` bundle was reinstalled while the notarized release app's
recursive manifest remained unchanged. This is Tahoe-family host evidence
only; physical Sequoia, separate Tahoe hardware, VoiceOver, and window
restoration remain field gates.

**D341 failed-receipt recovery gate.** Core, admission, storage, and application
coverage pin one typed subject per executable Skill, exact v41 subject and
failure-category persistence, subject-swap rejection, cascade revocation of
navigation authority, no legacy inference, causal receipt replay, and repeated
catalogue/policy validation. Local meeting and commitment failures may resolve
only to inert review context; calendar work remains resident-menu-bar guidance,
and external or destructive outcomes remain verification-only. Missing,
deleted, legacy, stale, disabled, malformed, and unknown recovery authority
fails closed without executing or retrying an effect.

Two real-app journeys per locale exercise a recoverable failed local receipt
and an injected resolution failure. They prove Settings routes to the existing
subject window without running the Skill, and that an unavailable resolution
keeps the receipt, evidence, and retry. The broader catalogue also proves that
a successful Waiting revocation refreshes its causal receipt before the
mutation releases UI ownership, and that a replaced SwiftUI offer menu can be
opened through a bounded re-resolved AppKit event without weakening content
assertions.

The final D341 gate passed the Swift 6 warnings-as-errors build, 2,439 package
cases with 14 environment/model-gated skips, 355 tooling cases, repository
hygiene, and strict SwiftLint with zero violations across 674 production files.
Finalized macOS 26.5.2 result bundles passed the complete 90/90 English and
90/90 Spanish XCUITest catalogues with no failures, skips, or expected
failures. The signed `app.portavoz.mac.dev` bundle was reinstalled while exact
before/after evidence kept the notarized release app unchanged. This remains
Tahoe-family host evidence only; physical Sequoia, separate Tahoe hardware,
VoiceOver, real external reconciliation, and resident-menu-bar recovery remain
field gates.

**D342 receipt-focus and accessibility gate.** An ordinary native-sheet
dismissal retains only the exact proposal UUID and returns both keyboard and
accessibility focus to its row-owned SwiftUI scope. The Settings owner stores
one cancelable, generation-fenced delay; recovery navigation clears it, and a
changed pane, replacement sheet, superseding request, or cancellation cannot
publish stale focus. The dedicated real-app journey audits sufficient element
descriptions under identified Skills controls, closes inspection with Escape,
and proves Space reopens the same receipt.

The final D342 gate passed the Swift 6 warnings-as-errors build, 2,444 package
cases with 14 environment/model-gated skips, 358 tooling cases, repository
hygiene, and strict SwiftLint with zero violations across 675 production files.
Finalized macOS 26.5.2 result bundles passed the complete 91/91 English and
91/91 Spanish XCUITest catalogues with no failures, skips, or expected
failures. The runner restored the host's exact Keyboard Navigation preference
after both catalogues. The Developer-ID-signed `app.portavoz.mac.dev` bundle
was reinstalled and deeply verified while an exact 184-entry before/after
manifest plus designated requirement kept the notarized release app unchanged.
This remains Tahoe-family host automation; physical VoiceOver, Sequoia, and
separate Tahoe hardware remain field evidence.

**D343 truthful Skills activity-transition gate.** Three application cases pin
the asymmetric load contract and cancellation: a receipt failure returns
verified policy with no rows and an unavailable marker, while a policy failure
still rejects the whole snapshot. Six pure presentation cases require loading
to hide a same-scope snapshot, reject relabeling a mismatched snapshot,
distinguish unavailable from verified empty, and expose rows only from verified
receipt authority. The architecture ratchet keeps the mutation UUID fence,
temporary-store fixture, typed availability, and public AppKit announcement
path visible.

One delayed real-app journey per locale changes from Recent to Waiting, proves
the prior row disappears while independently verified policy and proposal
controls remain enabled, opens and revokes the Waiting receipt, and observes the
same-scope row disappear again before the exact localized empty state arrives.
The existing injected receipt-only failure journey still proves no policy error
is invented and Retry remains separate. Automated labels and announcement API
use do not replace physical VoiceOver review.

The final gate passed the strict current-SDK build, 2,453 package tests with 14
explicit skips and zero failures, SwiftLint with zero violations across 675
files, 358 tooling tests, repository hygiene, and finalized real-app XCUITest
bundles with 92/92 English plus 92/92 Spanish cases on macOS 26.5.2. Keyboard
Navigation returned to its exact prior value after each locale. The signed
local-only `app.portavoz.mac.dev` bundle was reinstalled and deeply verified;
an exact 184-entry manifest and designated-requirement comparison kept the
notarized release app byte-for-byte unchanged. This is local Tahoe-family
automation, not physical VoiceOver, Sequoia, or separate Tahoe hardware
evidence.

**D344 read-only shared-host preflight gate.** Every XCUITest entry gives only
Portavoz Dev a three-second bounded quit request, then takes two host snapshots
one second apart before building. A bounded process probe
rejects only active `xcodebuild test`/`test-without-building` actions and
recognizable UI-test runners. A Swift 6 CoreGraphics probe rejects visible
SecurityAgent or Notification Center surfaces and another process's Secure
Input ownership while reading only window owner/layer plus public content-free
global state; negative-layer desktop surfaces do not count and the owning
process is not exposed. Probe timeout, malformed output, or unreadable process
state fails closed. The Swift probe is compiled once inside a private temporary
workspace with a 60-second cold-toolchain ceiling, its executable output is
validated, and the same binary performs both three-second observations; a
build or workspace failure also fails closed before XCUITest. The gate
never reads a window title or bounds, dismisses a prompt, resets LaunchServices,
or terminates another process. Persistent `testmanagerd`, unit-test processes,
`build-for-testing`, and idle `xcodebuildmcp` helpers are not evidence of an
active UI run. Eighteen injectable tooling cases and source-policy ratchets pin
those classifications. The hosted bilingual job keeps an 85-minute fail-safe
ceiling; the current 106-case-per-locale local evidence needs about 38 minutes
together after one shared build, without parallel locale contention.

The final gate passed the strict current-SDK build, 2,453 package tests with 14
explicit skips and zero failures, SwiftLint with zero violations across 675
files, 373 tooling tests, repository hygiene, and live read-only preflight.
Finalized macOS 26.5.2 (25F84) result bundles passed 92/92 English plus 92/92
Spanish XCUITest cases with no failures; Keyboard Navigation returned to its
exact prior value of `0`. The Developer-ID-signed `app.portavoz.mac.dev` bundle
was reinstalled and deeply verified. The notarized release app retained an
identical 184-entry recursive content, metadata, hexadecimal-xattr, bundle-ID,
and designated-requirement manifest (`8192f7b9b61c321c93e8b4d273b578779c7753aee1fb17f4badff4ae6de49b53`),
and its deep signature remained valid. The local Dev app is intentionally
unnotarized and this host still lacks the optional Metal Toolchain, so its MLX
metallib is absent. The two-sample check cannot prevent unrelated automation
from starting afterward; physical Sequoia, separate Tahoe hardware, and
cross-process contention remain external evidence.

**D369 policy-on-demand receipt inspection gate.** Three application regressions
count the exact execution-policy reads for a successful receipt, an
external-failure receipt, and an otherwise-valid failed local recovery. The
first two remain inspectable with zero policy reads while the local recovery
reads once and propagates an unavailable policy rather than inventing
authority. The real-app Waiting journey additionally forces only that optional
policy port unavailable, preserves its independent revocation action, and
returns to the exact meeting source without executing.

The final D369 gate passed the strict current-SDK build, 2,597 package tests
with 15 explicit environment/model skips and zero failures, all 194 architecture
ratchets, 456 tooling tests, repository hygiene, and strict SwiftLint with zero
violations across 702 production Swift files. Finalized macOS 26.5.2 (25F84)
result bundles passed 101/101 English plus 101/101 Spanish real-app XCUITest
cases with no failures or skips. The Developer-ID-signed
`app.portavoz.mac.dev` bundle was reinstalled, deeply verified, and launched;
an exact before/after comparison kept the notarized `app.portavoz.mac` release
bundle's 254-entry recursive content/metadata/hex-xattr manifest, designated
requirement, and bundle ID unchanged at SHA-256
`93183dea64039bf7b52ae357643ed61cbe2afbd7ac6eb3c41117c5f7b8218617`,
and Gatekeeper still accepted it as Notarized Developer ID. This is local
Tahoe-family automation, not physical Sequoia, separate Tahoe hardware,
VoiceOver, real external-effect reconciliation, or MLX evidence; this host has
no optional Metal Toolchain, so the local Dev bundle contains no MLX metallib.

**D370 read-only Skill-control recovery gate.** The real-app regression commits
one temporary-store pause mutation and then fails its response. Settings keeps
the old value visibly stale, disables every policy control, and exposes the
identified **Reload controls** action. That action performs only the
generation-fenced durable read: it adopts the already-committed value, clears
the error, re-enables controls, and keeps the same Settings pane open. The
fixture makes every mutation response fail, so a replay cannot satisfy the
journey. Architecture ratchets also keep all simulation arguments behind the
temporary-store boundary.

The first full closure run passed 102/102 English cases in 2,024.392 seconds,
then the Spanish catalogue passed 101 cases and failed the pre-existing Voice
storage-recovery journey after all product assertions had succeeded. XCTest
reported `Unable to find hit point for ScrollView` at
`{{-1435.0, 192.0}, {535.0, 620.0}}`: the real Settings scene had inherited a
secondary display with negative global coordinates. A focused Spanish retry
on the unchanged code passed in 23.357 seconds after the host foreground
changed, confirming a placement-dependent harness defect rather than a product
failure. The read-only preflight also conservatively observed a benign Weather
Notification Center window; no notification or permission choice was
dismissed, and the preflight policy was not weakened.

The fix adds one `@MainActor`, temporary-store-only AppKit placement boundary.
It uses `NSScreen.screens.first`, documented by the current SDK as the zero
screen, preserves the main window's existing left clearance, centers and
constrains the real Settings window to that screen, and makes every Settings
journey reject a negative navigation-anchor frame. Production launches never
enter the boundary, no observer or retained window was added, and the existing
Settings reference remains weak. The formerly failing Spanish journey then
passed in 25.871 seconds.

The final D370 gate passed the strict current-SDK build, 2,598 package tests
with 15 explicit environment/model skips and zero failures, all 195 architecture
ratchets, 457 tooling tests, repository hygiene, localization validation, and
strict SwiftLint with zero violations across 703 production Swift files. The
first complete package run exposed one stale inventory assertion that expected
2,597 cases while already expecting 102 UI cases; advancing both dimensions
restored the executable project-truth contract before the clean final run.
Finalized macOS 26.5.2 (25F84) result bundles passed 102/102 English in
2,407.443 seconds plus 102/102 Spanish in 2,400.954 seconds, with no failures,
skips, or expected failures.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled, deeply
verified, and launched from `/Applications/Portavoz Dev.app`. Exact
before/after comparison kept the notarized `app.portavoz.mac` release bundle's
254-entry recursive content/metadata/hex-xattr manifest unchanged at SHA-256
`93183dea64039bf7b52ae357643ed61cbe2afbd7ac6eb3c41117c5f7b8218617`;
its deep signature remained valid and Gatekeeper still reported Notarized
Developer ID. This is local Tahoe-family automation, not physical VoiceOver,
Sequoia, or separate Tahoe hardware evidence. The host lacks the optional Metal
Toolchain, so the local Dev bundle contains no MLX metallib.

**D371 bounded Skill-activity history gate.** Settings initially read at most
20 receipts for the selected lifecycle scope and originally exposed the
identified **Show more runs** action whenever that verified page was full;
D375 replaces that visible-count proxy with explicit successor evidence.
Activation replaces the page with one bounded 50-receipt read; changing scope
resets the requested
window to 20, while same-scope refreshes and mutations preserve the current
window. Scope, limit, and generation must all still match before a response can
publish. The slice adds no cursor, infinite scroll, prefetch, append-only view
array, schema change, or broader storage query. Pure presentation coverage pins
the 20/50 state transitions, and architecture ratchets keep the constants,
replacement-read contract, accessibility identifiers, and temporary-store-only
fixture visible.

The real-app fixture creates 25 content-free confirmed Meeting Package Export
executions under one reusable offer and 25 distinct destination/effect slots,
preserving idempotency while making the visible 20-to-25 transition exact. The
focused English run first reached the correct 25-row product state after the
click but failed its preceding stable-frame assertion: sixteen 40-point Form
scrolls did not make the distant action hittable. The harness fix removed an
unnecessary scroll to an offscreen-but-queryable limit label and used bounded
120-point steps for the action and expanded limit, without weakening the
stable-hittable-frame requirement. The corrected focused journey passed 1/1 in
English in a 47.152-second result interval and 1/1 in Spanish in 45.802 seconds,
with no failures, skips, or expected failures.

The final D371 gate passed the strict current-SDK build, 2,600 package tests
with 15 explicit environment/model skips and zero failures, all 195 architecture
ratchets, 457 tooling tests, repository hygiene, localization validation, and
strict SwiftLint with zero violations across 703 production Swift files. The
read-only host preflight initially stopped for a visible user-owned Notification
Center alert and read or dismissed no prompt; after the user removed that
surface, it passed while reporting 24 stale LaunchServices claimants as
warning-only. Finalized macOS 26.5.2 (25F84) result bundles passed 103/103
English plus 103/103 Spanish XCUITest cases, with no failures, skips, or
expected failures. The xcresult wall intervals were 2,167.206 seconds English
and 2,173.336 seconds Spanish; XCTest execution was 2,155.708 and 2,163.258
seconds respectively.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled, deeply
verified, and launched from `/Applications/Portavoz Dev.app`. Exact
before/after comparison kept the notarized `app.portavoz.mac` release bundle's
254-entry recursive content/metadata/hex-xattr manifest unchanged at SHA-256
`93183dea64039bf7b52ae357643ed61cbe2afbd7ac6eb3c41117c5f7b8218617`;
its deep signature remained valid and Gatekeeper still reported Notarized
Developer ID. This is local Tahoe-family automation, not physical VoiceOver,
Sequoia, separate Tahoe hardware, real external-effect reconciliation, or MLX
evidence. The host lacks the optional Metal Toolchain, so the local Dev bundle
contains no MLX metallib.

**D372 explicit Skill-activity refresh gate.** Settings exposes the identified
**Refresh activity** action only after the selected lifecycle scope has produced
a verified empty or populated presentation. Activation preserves that scope and
its current 20- or 50-receipt window, replaces any visible rows with the normal
loading state, and reuses the existing scope/limit/generation fence before a
response can publish. The MainActor entry point rejects loading and control or
proposal mutation, so rapid repeated activation cannot enqueue duplicate reads.
Unavailable and loading states expose no refresh action. The slice adds no timer,
polling, observer, mutation, effect authority, cursor, or unbounded receipt read.

The real-app fixture delays the refresh response in the waiting scope. The
focused journey verifies the initial 20 rows, explicitly expands to the fixture's
25 rows, refreshes, rejects stale visible rows during loading, and receives the
same 25 rows with the 50-receipt request preserved. It passed 1/1 in English in
57.491 seconds and 1/1 in Spanish in 55.906 seconds, with no failures. The final
D372 gate passed the strict current-SDK build in 28.06 seconds, 2,601 package
tests with 15 explicit environment/model skips and zero failures, all 195
architecture ratchets, 457 tooling tests, repository hygiene, localization JSON
validation, diff whitespace validation, and strict SwiftLint with zero violations
across 703 production Swift files. The read-only host preflight passed without
reading or dismissing any prompt and reported 24 stale LaunchServices claimants
as warning-only. Finalized macOS 26.5.2 (25F84) result bundles passed 104/104
English cases in 2,210.764 seconds of XCTest execution and 104/104 Spanish cases
in 2,239.864 seconds, with zero failures.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled, deeply
verified, and launched from `/Applications/Portavoz Dev.app`; the host's missing
optional Metal Toolchain left that Dev bundle with no MLX metallib. Exact
before/after comparison kept the notarized `app.portavoz.mac` release bundle's
254-entry recursive content/metadata/hex-xattr manifest unchanged at SHA-256
`93183dea64039bf7b52ae357643ed61cbe2afbd7ac6eb3c41117c5f7b8218617`;
its bundle ID and designated requirement stayed unchanged, its deep signature
remained valid, and Gatekeeper still reported Notarized Developer ID. This is
local Tahoe-family automation, not physical Sequoia, separate Tahoe hardware,
VoiceOver, real external-effect reconciliation, or MLX runtime evidence.

**D373 exact Skill-activity filter gate.** The control-center request and
snapshot carry one optional exact catalogue Skill identity. Application tests
require an unknown identity to fail before any store read; storage tests compose
the identity with all four lifecycle scopes before ordering and limiting,
reject malformed identities, preserve exact newest-first order, and prove the
v42 migration creates four direction-matched indexes. Filtered and unfiltered
`EXPLAIN QUERY PLAN` cases pin their intended indexes and reject a temporary
B-tree. Pure presentation coverage rejects a retained snapshot whose filter no
longer matches, while architecture ratchets require scope/filter/limit/load
generation fencing and the accessible menu identifiers.

The temporary-store journey seeds 25 Waiting package-export receipts and adds a
four-second non-Recent delay. It observes 20 unfiltered rows, selects Recap and
sees no stale package rows plus the localized exact empty state, selects package
export and receives its exact 20-row page, expands to all 25, then returns to
**All skills** and verifies the window reset to 20. The focused real-app case
passed 1/1 in English in 80.972 seconds and 1/1 in Spanish in 77.746 seconds,
with zero failures. The final D373 gate passed `swift build` in 18.14 seconds,
the strict current-SDK build in 20.92 seconds, 2,605 package tests with 15
explicit environment/model skips and zero failures, all 195 architecture
ratchets, 457 tooling tests, repository hygiene, localization JSON validation,
diff whitespace validation, and strict SwiftLint with zero violations across
704 production Swift files. The read-only host preflight passed without reading
or dismissing any prompt and reported 24 stale LaunchServices claimants as
warning-only. Finalized macOS 26.5.2 (25F84) result bundles passed 105/105
English cases in a 2,316.739-second result interval and 105/105 Spanish cases in
a 2,339.001-second result interval, with zero failures, skips, or expected
failures. This evidence proves bounded query/result behavior on the local
Tahoe-family host; it is not a measured latency/disk budget, physical VoiceOver,
Sequoia, or separate-hardware Tahoe evidence.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was reinstalled, deeply
verified, and launched from `/Applications/Portavoz Dev.app`; the running
executable resolved to that bundle. The host's missing optional Metal Toolchain
left the Dev bundle with no MLX metallib. Exact before/after comparison kept the
notarized `app.portavoz.mac` release bundle's 254-entry recursive
content/metadata/hex-xattr manifest unchanged at SHA-256
`93183dea64039bf7b52ae357643ed61cbe2afbd7ac6eb3c41117c5f7b8218617`;
its bundle ID and designated requirement stayed unchanged, its deep signature
remained valid, and Gatekeeper still reported Notarized Developer ID. This is
local Tahoe-family automation, not physical Sequoia, separate Tahoe hardware,
VoiceOver, real external-effect reconciliation, or MLX runtime evidence.

**D374 rolling Skill-activity update-period gate.** The control-center request
and snapshot carry one explicit update period plus an injected reference date.
Application regressions pin all four mappings: **Any time** has no cutoff,
while the other choices resolve to the preceding 24 hours, 7 days, or 30 days.
Every explicit reference must be finite before either the policy or receipt
store is read, including **Any time**. Storage applies the absolute cutoff as an
inclusive `updatedAt >= ?` predicate and remains clock-free. Exact boundary
tests and `EXPLAIN QUERY PLAN` coverage compose the cutoff with every lifecycle
scope and the optional exact Skill, require the intended existing indexes, and
reject temporary ordering B-trees. Presentation tests reject a snapshot whose
period no longer matches the selection.

The temporary-store journey makes exactly five of 25 Waiting package-export
receipts recent. It verifies the initial 20-row page and explicit 25-row
expansion, hides every old row under **Past 24 hours**, composes that period with
an exact Skill and an empty Skill result, and proves that changing scope, Skill,
or period resets 50 to 20. The focused case passed 1/1 in English in 93.948
seconds and 1/1 in Spanish in 93.800 seconds. It also pins the localized menu,
value, and empty-state accessibility surface rather than relying only on source
or pure state tests.

The final D374 gate passed `swift build` in 13.43 seconds, the current-SDK
warnings-as-errors build in 22.45 seconds, and 2,607 package tests with 15
explicit environment/model skips and zero failures in 119.541 seconds of
XCTest execution. All 195 architecture ratchets, 457 tooling tests, repository
hygiene, localization JSON validation, UI-catalog validation, diff whitespace
validation, and strict SwiftLint across 705 production Swift files also passed.
The read-only host preflight passed without reading or dismissing a prompt and
left 24 stale LaunchServices claimants warning-only. Final macOS 26.5.2 (25F84)
result bundles passed 106/106 English plus 106/106 Spanish real-app XCUITest
cases, with zero failures, skips, or expected failures; their result intervals
were 2,441.170 seconds and 2,449.264 seconds respectively.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was rebuilt, deeply
verified, installed only at `/Applications/Portavoz Dev.app`, and observed
running from its exact executable. A fresh deterministic before/after check
kept the notarized `app.portavoz.mac` release bundle unchanged across its
184-entry no-symlink-traversal content/metadata/hex-xattr manifest at SHA-256
`9f42e6c828e2330467c28539265df6aa2b46814df17f5cf0966e623501a4dfe2`;
its bundle ID and designated requirement stayed unchanged, its deep signature
remained valid, and Gatekeeper still reported Notarized Developer ID. The host
can resolve a `metal` compiler from a MobileAsset cryptex, but the packaging
gate still cannot resolve the optional Metal Toolchain's `metallib`; the Dev
bundle therefore contains no MLX metallib. Query-plan evidence proves bounded
access strategy, not a latency or disk budget. This remains local Tahoe-family
automation, not physical Sequoia, separate Tahoe hardware, VoiceOver, real
external-effect reconciliation, or MLX runtime evidence.

**D375 truthful Skill-activity continuation gate.** ApplicationKit now requests
one receipt beyond the clamped 20- or 50-row visible window, publishes only the
requested prefix, and sets `hasMoreReceipts` only when a successful durable read
contains that successor sentinel. Receipt unavailability clears both rows and
continuation. SwiftUI no longer infers availability from a full visible page:
exactly 20 matches expose all 20 without **Show more runs**, while 21 or more
allow the single replacement read and the 50-row product ceiling remains
absolute even when a 51st sentinel exists. The slice adds no count query,
cursor, schema, prefetch, observer, timer, receipt mutation, or execution
authority.

Focused Swift coverage passed 49 control-center, presentation, and architecture
tests with zero failures in 2.408 seconds. The dedicated temporary-store fixture
creates exactly 20 content-free package-export receipts; its real-app journey
passed 1/1 English in 14.319 seconds and 1/1 Spanish in 12.659 seconds, requiring
20 visible rows and no expansion action. Final preflight passed `swift build`
in 9.11 seconds, the current-SDK warnings-as-errors build in 21.76 seconds,
2,607 package tests with 15 explicit environment/model skips and zero failures
in 119.574 seconds of XCTest execution, all 195 architecture ratchets, 457
tooling tests, repository hygiene, both localization catalog validations, the
107-case UI-catalog check, diff whitespace validation, and strict SwiftLint with
zero violations across 705 production Swift files.

The read-only host preflight passed without reading or dismissing a prompt and
left 24 stale LaunchServices claimants warning-only. Final macOS 26.5.2 (25F84),
arm64 result bundles passed 107/107 English plus 107/107 Spanish real-app
XCUITest cases with zero failures, skips, or expected failures; their result
intervals were 2,437.438 seconds and 2,454.014 seconds respectively.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was rebuilt, deeply
verified, installed only at `/Applications/Portavoz Dev.app`, and observed at
PID 56366 running from its exact executable. A deterministic before/after check
kept the notarized `app.portavoz.mac` release bundle byte-for-byte unchanged
across its 184-entry no-symlink-traversal content/metadata/hex-xattr manifest at
SHA-256
`9f42e6c828e2330467c28539265df6aa2b46814df17f5cf0966e623501a4dfe2`;
its deep signature remained valid and Gatekeeper still reported Notarized
Developer ID. Packaging again lacked the optional Metal Toolchain's `metallib`,
so the Dev bundle contains no MLX metallib. Sentinel and indexed-plan evidence
prove bounded access shape, not a measured latency/disk budget. This remains
local Tahoe-family automation, not physical Sequoia, separate Tahoe hardware,
VoiceOver, real external-effect reconciliation, or MLX runtime evidence.

**D376 verified-empty Skill-filter recovery gate.** SwiftUI offers one identified
**Clear activity filters** action only when the selected lifecycle scope has a
matching, verified, empty snapshot and an exact Skill and/or update-period
filter is active. The parent revalidates that same scope, Skill, period,
receipt authority, empty result, and absence of all control/proposal mutation
before it clears only the Skill and period. The lifecycle scope stays intact;
the existing selection task resets the bounded window to 20 and owns the
replacement read. The action remains a sibling of the combined empty
explanation and is absent from unfiltered empty, receipt, loading, and
unavailable states. No query shape, store, schema, index, cursor, timer,
observer, receipt mutation, execution authority, or second state machine was
added.

Focused presentation and architecture coverage passed 13/13 tests with zero
failures in 0.188 seconds. The composed temporary-store journey starts from a
Waiting-scope Skill/time no-match, clears the two narrowing filters, requires
loading plus the first 20 matching rows, verifies localized **All skills** and
**Any time**, requires the reset action to disappear, and then reapplies the
existing composition regression. It passed 1/1 in English in 114.746 seconds
and 1/1 in Spanish in 116.375 seconds.

Final preflight passed `swift build` in 3.19 seconds, the current-SDK
warnings-as-errors build in 21.26 seconds, and 2,608 package tests with 15
explicit environment/model skips and zero failures in 118.939 seconds of
XCTest execution. All 195 architecture ratchets, 457 tooling tests, repository
hygiene and its embedded policy suites, both localization-catalog validations,
the complete 107-case UI-catalog check, diff whitespace validation, and strict
SwiftLint with zero violations across 705 production Swift files also passed.
The read-only host preflight passed without reading or dismissing a prompt and
left 24 stale LaunchServices claimants warning-only. Final macOS 26.5.2
(25F84), arm64 result bundles passed 107/107 English plus 107/107 Spanish
real-app XCUITest cases with zero failures, skips, or expected failures; their
result intervals were 2,464.124 seconds and 2,479.835 seconds respectively.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was rebuilt, deeply
verified, installed only at `/Applications/Portavoz Dev.app`, and observed at
PID 87935 running from its exact executable. A deterministic before/after
comparison kept the notarized `app.portavoz.mac` release bundle unchanged
across its 184-entry no-symlink-traversal content/metadata/hex-xattr manifest
at SHA-256
`9f42e6c828e2330467c28539265df6aa2b46814df17f5cf0966e623501a4dfe2`;
its deep signature remained valid and Gatekeeper still reported Notarized
Developer ID. Packaging again lacked the optional Metal Toolchain's `metallib`,
so the Dev bundle contains no MLX metallib. This is deterministic local
Tahoe-family automation, not physical Sequoia, separate Tahoe hardware,
VoiceOver, real external-effect reconciliation, or MLX runtime evidence.

**D377 explicit Proposed Skills refresh gate.** A verified empty or populated
proposal projection exposes one identified **Refresh proposed Skills** action.
Settings revalidates the verified snapshot and every proposal/policy mutation
fence before reusing the existing bounded `LoadSkillOfferReview` read. During
that read, an identified progress state replaces refresh; the last verified
rows remain visible but inert. Initial loading and unavailable states retain
their existing loading or retry authority, and receipt loading stays
independent. The existing proposal load UUID still owns adoption. No polling,
timer, observer, new store, proposal producer, mutation, execution authority,
query shape, schema, index, cursor, clock, adapter, egress consent, or
deployment-floor change was added.

Focused presentation and architecture coverage passed 3/3 tests with zero
failures in 0.062 seconds. The existing temporary-store transition journey adds
a four-second proposal-read delay and verifies the localized refresh action,
identified progress, retained verified row, inert row action, and successful
re-enablement before continuing through the existing activity transitions. It
passed 1/1 in English in 74.654 seconds and 1/1 in Spanish in 74.753 seconds.

Final preflight passed `swift build` in 4.49 seconds, the current-SDK
warnings-as-errors build in 21.60 seconds, and 2,609 package tests with 15
explicit environment/model skips and zero failures in 124.988 seconds of
XCTest execution. All 195 architecture ratchets, 457 tooling tests in 9.006
seconds, repository hygiene and its embedded policy suites, both localization-
catalog validations, the complete 107-case UI-catalog check, diff whitespace
validation, and strict SwiftLint with zero violations across 705 production
Swift files also passed. The read-only host preflight passed without reading or
dismissing a prompt and left 24 stale LaunchServices claimants warning-only.
Final macOS 26.5.2 (25F84), arm64 result bundles passed 107/107 English plus
107/107 Spanish real-app XCUITest cases with zero failures, skips, or expected
failures; their result intervals were 2,495.248 seconds and 2,509.207 seconds
respectively.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was rebuilt, deeply
verified, installed only at `/Applications/Portavoz Dev.app`, and observed at
PID 21021 running from its exact executable. A deterministic before/after
comparison kept the notarized `app.portavoz.mac` release bundle unchanged
across its 184-entry no-symlink-traversal content/metadata/hex-xattr manifest
at SHA-256
`9f42e6c828e2330467c28539265df6aa2b46814df17f5cf0966e623501a4dfe2`;
its deep signature and designated requirement remained valid, and Gatekeeper
still reported Notarized Developer ID. Packaging again lacked the optional
Metal Toolchain's `metallib`, so the Dev bundle contains no MLX metallib. This
is deterministic local Tahoe-family automation, not physical Sequoia,
separate Tahoe hardware, VoiceOver, real external-effect reconciliation, or
MLX runtime evidence.

**D378 unique Proposed Skill accessibility-position gate.** Every proposal row
and its review, dismiss, retry, and resident review actions append the same
localized, one-based position within the verified ordered snapshot. The
position contains no subject, title, transcript, preview, destination,
recipient, argument, UUID, or stable offer key; the existing offer UUID remains
the SwiftUI identity. The projection is already capped at 50, so SwiftUI keeps
the tiny compatibility `Array(offers.enumerated())`: the current SDK makes
direct `EnumeratedSequence` random-access conformance available only on macOS
26, which would violate the macOS 14.4 deployment floor. No proposal producer,
store, schema, query, timer, observer, mutation, execution authority, egress
consent, or deployment floor changed.

Focused presentation and architecture coverage passed 5/5 tests with zero
failures in 0.104 seconds. A disposable, temporary-store-only fixture creates a
second summarized meeting and obtains both meetings' offers through the real
bounded producer. The dedicated real-app journey requires two same-Skill rows,
two review actions, and two dismiss actions; it pins unique localized positions
1 and 5 of 8 across all three surfaces. It passed 1/1 in English in 17.097
seconds and 1/1 in Spanish in 16.532 seconds; after a test-only hardening tied
each label to at most one recognized position, the strengthened case passed
again in 16.885 seconds and 16.320 seconds respectively.

Final preflight passed `swift build` in 8.74 seconds, the current-SDK
warnings-as-errors build in 21.94 seconds, and 2,610 package tests with 15
explicit environment/model skips and zero failures in 115.658 seconds of
XCTest execution. All architecture ratchets, 457 tooling tests in 9.053
seconds, repository hygiene and its embedded policy suites, both localization-
catalog validations, the complete 108-case UI-catalog check, diff whitespace
validation, and strict SwiftLint with zero violations across 706 production
Swift files also passed. The read-only host preflight passed without reading or
dismissing a prompt and left 24 stale LaunchServices claimants warning-only.
The complete macOS 26.5.2 (25F84), arm64 catalogue run on the finalized
production source passed 108/108 English plus 108/108 Spanish real-app
XCUITest cases with zero failures, skips, or expected failures; its result
intervals were 2,569.993 seconds and 2,572.710 seconds respectively. The later
per-label test-only assertion hardening changed no app source and is covered by
the final focused bilingual rerun above.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was rebuilt, deeply
verified, installed only at `/Applications/Portavoz Dev.app`, and observed at
PID 76411 running from its exact executable. A deterministic before/after
comparison kept the notarized `app.portavoz.mac` release bundle unchanged
across its 184-entry no-symlink-traversal content/metadata/hex-xattr manifest
at SHA-256
`9f42e6c828e2330467c28539265df6aa2b46814df17f5cf0966e623501a4dfe2`;
its bundle ID and designated requirement stayed unchanged, its deep signature
remained valid, and Gatekeeper still reported Notarized Developer ID. The Dev
build is local-only because no CloudKit profile was supplied, and packaging
again lacked the optional Metal Toolchain's `metallib`, so the bundle contains
no MLX metallib. This is deterministic local Tahoe-family automation, not
physical Sequoia, separate Tahoe hardware, VoiceOver, real external-effect
reconciliation, provisioned CloudKit, or MLX runtime evidence.

**D379 finite Suggested-actions comprehension gate.** The 0.8.0 candidate
keeps the six registered review-first actions and six structured graph Ask
jobs, while the public presentation now calls the former **Suggested actions**
or **Acciones sugeridas**. Settings explains that suggestions come from meeting
evidence and that nothing runs until the user reviews and confirms it. Proposal,
history, receipt, recovery, menu, and detail copy use the same action vocabulary.
Internal `Skill` types, identifiers, persistence, migrations, telemetry, and
stable accessibility identifiers remain unchanged. No action producer, action
kind, standing rule, graph job, search/model authority, store, schema, query,
timer, observer, mutation, execution authority, egress consent, or deployment
floor changed.

The dedicated comprehension journey initially found that the visible global
pause `Toggle` exposed an empty accessibility label and title on the real app.
The production control now supplies one explicit localized accessibility label;
the regression requires the localized pane title, review-first safety sentence,
and pause-control name. The strengthened focused case passed 1/1 English in
15.632 seconds and 1/1 Spanish in 14.606 seconds. The new journey is registered
in the fail-closed feature catalog, which now contains 109 tests.

Final preflight passed both debug builds, including current-SDK first-party
warnings-as-errors, and 2,611 package tests with 15 explicit environment/model
skips and zero failures in 125.164 seconds of XCTest execution. All architecture
ratchets, 457 tooling tests in 9.427 seconds, repository hygiene and its embedded
policy suites, both localization-catalog validations, the complete 109-case UI
catalog check, diff whitespace validation, and strict SwiftLint with zero
violations across 706 production Swift files also passed. The read-only host
preflight passed without reading or dismissing a prompt and left 24 stale
LaunchServices claimants warning-only. Final macOS 26.5.2 (25F84), arm64 result
bundles passed 109/109 English plus 109/109 Spanish real-app XCUITest cases with
zero failures, skips, or expected failures; their result intervals were
2,602.917 seconds and 2,618.289 seconds respectively.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was rebuilt, deeply
verified, installed only at `/Applications/Portavoz Dev.app`, and observed at
PID 23333 running from its exact executable. A deterministic before/after
comparison kept the notarized `app.portavoz.mac` release bundle unchanged
across its 184-entry no-symlink-traversal content/metadata/hex-xattr manifest
at SHA-256
`9f42e6c828e2330467c28539265df6aa2b46814df17f5cf0966e623501a4dfe2`;
its bundle ID and designated requirement stayed unchanged, its deep signature
remained valid, and Gatekeeper still reported Notarized Developer ID. The Dev
build is local-only because no CloudKit profile was supplied, and packaging
again lacked the optional Metal Toolchain's `metallib`, so the bundle contains
no MLX metallib. This is deterministic local Tahoe-family automation, not
physical Sequoia, separate Tahoe hardware, VoiceOver/Voice Control, provisioned
CloudKit, real external-effect reconciliation, or MLX runtime evidence.

**D380 private real-model and context-headroom gate.** Foundation Models map
chunks are capped at 4,000 characters while the final structured material
remains capped at 3,000 characters and each map response at 250 tokens. The
regression came from a real macOS 26.5.2 long-transcript request reaching
4,089/4,096 tokens under the former 4,500-character boundary. Focused
Foundation Models integration passed 4/4 twice after the correction, including
the incremental long-transcript path. Pure coverage also proves that one
10,050-character oversized utterance is preserved in bounded chunks through a
single forward traversal and cannot bypass the character budget. The
production map path retries only an actual `exceededContextWindowSize` chunk
at successively smaller fresh-session budgets with a finite 500-character floor; cancellation
and all other generation errors propagate unchanged.

The canonical six-class model gate now compiles and runs in Release. Its
Parakeet case accepts any spoken WAV through segment count, lexical-character
count, and timestamp bounds only. DEBUG builds skip before opening that
fixture because FluidAudio 0.15.5 has no public log-level control and mirrors
partial transcript diagnostics to stderr. The runner assigns captured logs
mode 0600, rejects any FluidAudio DEBUG line, withholds raw failure output, and
removes each log after normal completion or shell interruption. Signal
handlers exit nonzero after shared EXIT cleanup, so an interruption is
never swallowed into a continuing green lane. The fixture
must expose valid bounded PCM metadata, fit the 10-minute allocation ceiling,
and its producer is canceled on every exit. A focused Release Parakeet rehearsal passed 1/1 over a
160.683-second scratch-only 16 kHz mono fixture with zero FluidAudio console or
transcript-bearing lines. The fixture and its transcript never enter tracked
files. The complete canonical Release gate then executed all six declared
classes—11 tests total—with zero skips and zero failures; any FluidAudio DEBUG
line would have failed the run without being echoed.

Final preflight passed both debug builds, including current-SDK first-party
warnings-as-errors, and 2,614 package tests with 15 explicit environment/model
skips and zero failures in 113.529 seconds of XCTest execution. All 197
architecture ratchets and the six focused formatter cases passed after the
final durable-vocabulary correction. All 457 tooling tests passed in 9.625
seconds; repository hygiene
and its embedded policy suites, both localization-catalog validations, the
complete 109-case UI-catalog check, diff whitespace validation, and strict
SwiftLint with zero violations across 706 production Swift files also passed.
The read-only UI host preflight passed without reading or dismissing a prompt
and left 24 stale LaunchServices claimants warning-only.

The fail-safe changed-file selector chose 40 journeys because the two
IntelligenceKit sources affect Ask, summary, evidence, correction, processing,
library, brief, Insights, Settings, and public-showcase surfaces, while the
Makefile is currently classified as shared UI harness. One build was reused and
the locales ran sequentially. Final macOS 26.5.2 (25F84), arm64 result bundles
passed 40/40 English in a 701.825-second interval plus 40/40 Spanish in a
701.524-second interval, with zero failures, skips, or expected failures. This
is the mandatory minimum safe D380 scope, not the complete 109-case bilingual
integration/release gate. Each result bundle reports one duration outlier,
which is retained as input to the next measured XCUITest-optimization band.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was rebuilt, deeply
verified, installed only at `/Applications/Portavoz Dev.app`, and observed at
PID 96283 running from its exact executable. A deterministic before/after
comparison kept the notarized `app.portavoz.mac` release bundle unchanged
across its 184-entry no-symlink-traversal content/metadata/hex-xattr manifest
at SHA-256
`9f42e6c828e2330467c28539265df6aa2b46814df17f5cf0966e623501a4dfe2`;
its bundle ID and designated requirement stayed unchanged, its deep signature
remained valid, and Gatekeeper still reported Notarized Developer ID. The Dev
build is local-only because no CloudKit profile was supplied, and packaging
again lacked the optional Metal Toolchain's `metallib`, so the bundle contains
no MLX metallib. This deterministic local Tahoe-family automation does not
certify physical Sequoia, separate Tahoe hardware, VoiceOver/Voice Control,
provisioned CloudKit, real external-effect reconciliation, a private-meeting
quality claim, or MLX runtime behavior.

**D408 viewport-contained compact-review activation.** XCUITest no longer
equates a clipped descendant's `isHittable` value with an activatable control.
The Meeting Detail helper requires a nonempty target frame fully contained by
the identified scroll viewport, then rechecks containment and hittability after
the frame settles. Both transcript renderers expose the same
`detail-transcript-scroll` boundary, correction actions are revealed before
every activation, and Commitment review uses the same bounded rule inside the
artifacts viewport. Live interview objectives publish their stable UUID-derived
identity and exact label from the containing accessibility row rather than a
leaf `Text`. No timeout, sleep, click retry, persistence, correction target,
generation, egress, or deployment-floor behavior changed.

The four formerly failing compact-window journeys passed 4/4 locally in 68.470
seconds. Final preflight passed the current-SDK warnings-as-errors build and
2,783 package tests with 15 explicit environment/model skips and zero failures
in 119.795 seconds of XCTest execution. All 217 architecture ratchets, 629
deterministic tooling tests through repository hygiene, both localization-
catalog validations, the complete 106-case UI catalog, diff whitespace
validation, and strict SwiftLint with zero violations across 741 production
Swift files also passed.

Host evidence remained fail closed. A first 48-journey selector left one
window-visibility timeout after 47 distinct journeys had passed; its exact Clip
journey then passed in 8.238 seconds. A later selector was discarded after the
macOS Unified Log proved that AutomationModeUI received its explicit stop
gesture and disabled Automation Mode; the resulting lost AX connection and
subsequent `Not authorized for performing UI testing actions` cases are host
cascade evidence, not product results. No TCC reset, prompt dismissal, or green
retry was used. After a clean preflight, a one-journey Library canary passed in
5.609 seconds. The final macOS 26.5.2 (25F84), arm64 minimum-safe selector then
passed 48/48 English real-app XCUITest journeys with zero failures, skips, or
expected failures in 403.513 seconds of test time; its content-free receipt
reported p95 16.499 seconds and passed every per-journey and scoped-run budget
from one shared build. This is local Tahoe-family automation; exact-head hosted
Sequoia UI evidence and physical Sequoia/Tahoe plus VoiceOver/Voice Control
qualification remain separate gates.

**D409 deterministic feature synchronization and PR scoping.** Hosted run
`33092974838` on exact D408 head `600a46ec` completed the 106-case English
catalogue with 104 passes, two failures, 1,699.537 seconds of summed XCTest,
p95 38.424 seconds, and 552 seconds of build time. The Interview admission and
later grounded answer were correct, but its newly inserted objective row was
outside the compact lazy scroll when queried. The Ask answer and exact citation
were also correct, but an evidence screenshot consumed the fixed 500/350 ms
refinement and partial-answer windows before their assertions. Skills journeys
additionally paid repeated fixed four-second fixture delays.

The Interview journey now waits for the admitted objective count, performs one
bounded scroll, and only then queries the UUID-identified row. Ask and Skills
remove those fixed waits. Their disposable-store fixtures publish UUID-scoped
ready files, suspend with cancellation checks, and resume only after XCUITest
has asserted the exact intermediate state and created the matching continue
file. The runner gives every prefix-constrained signal pair a UUID scope, and
the app accepts those files only as direct children of its process temporary
directory. Configuration, signal creation, cancellation, and a
30-second exhaustion all fail explicitly; production composition never supplies
the arguments. App and runner both use the explicit isolated launch `TMPDIR`;
the runner has no fallback to its own process root. The no-evidence Ask
retrieval has its own boundary: the next
submission cancels it and XCUITest requires the ready file to disappear before
judging the replacement. Interview activation also requires the complete action frame
inside the assist viewport; XCTest's `isHittable` can remain true for a clipped
control.

Pull-request synchronization now scopes from the immediately previous PR head
instead of replaying the whole accumulated branch diff. Initial PR evaluation
still compares with the target branch, shared/localization/unknown paths retain
their fail-safe expansion, and a previous object absent after force push falls
back to the target branch rather than selecting an unjustified narrow set.
Manual integration dispatch remains full. This
changes feature-band cost, not the release contract: a fresh complete bilingual
106-case run and its aggregate/per-case budgets remain mandatory before final
integration. The retained hosted red run is diagnosis, not evidence erased by
retry or narrower selection.

The final local D409 code state passed the direct launch-directory validation
suite 3/3, the focused Ask plus three affected Skills journeys 4/4 in 113.595
seconds, and the complete minimum-safe selection 56/56 English journeys from
one build with no retry. The content-free runtime receipt reports 668.084
seconds of summed XCTest, 683 seconds wall, six seconds of build reuse, p50
9.122 seconds, p95 28.095 seconds, maximum 60.262 seconds, and no aggregate or
per-journey budget violation. Interview Assist passed in 11.412 seconds. This
is local Tahoe-family automation on the changed code; exact-head hosted scope,
the complete bilingual integration catalogue, and physical accessibility and
supported-hardware evidence remain pending.

Exact-head hosted run `33106386007` then selected the intended 56 English
journeys and passed 55. Interview admission, answer, and evidence were correct,
but one fixed negative 240-point scroll moved the newly inserted objective
toward the pruned side of the compact accessibility viewport; the following
five-second existence and label waits both failed. The same run kept all 23
Skills journeys functionally green, while seven exceeded their unchanged
per-case runtime budgets; the broad control-to-receipt journey measured 121.265
seconds. This result is retained as causal red evidence and was not rerun
unchanged.

The follow-up removes both measured sources of wasted work without increasing
any budget. Interview now queries the stable objective prefix together with its
exact accepted label and performs a bounded geometry-aware reveal that can move
toward earlier content while an offscreen row is absent from the accessibility
tree. Stable-frame waiting starts its unchanged interval at the first valid
hittable frame and resets on movement, avoiding one redundant accessibility
snapshot per activation. The broad Skills journey still proves the six-action
live catalogue, representative local/external disclosure, pause, durable window
reconstruction, resume, explicit confirmation, receipt projection, privacy,
and the complete three-event timeline. It no longer repeats action-specific
copy already exercised by Reminder/Brief/Email/Gist journeys, receipt-scope
transitions owned by the activity journeys, Gist input classes owned by pure
catalogue tests plus its own real-app journey, or a first accessibility audit
that the later all-open-window audit necessarily includes. Fresh local and
hosted runtime evidence must remain separate; a local pass cannot replace the
independent runner.

The final local run used one build and passed the complete 106-case catalogue
in both locales without a retry or budget change. English summed XCTest was
951.857 seconds (976 seconds wall, p95 19.141, maximum 47.456); Spanish was
949.262 seconds (974 seconds wall, p95 17.802, maximum 45.953). Compared with
the prior documented 105-case local candidate, summed XCTest fell 14.1% and
14.8% while adding one catalogue case. Interview passed in 11.564/12.738
seconds and the broad Skills journey in 45.101/43.439 seconds. All seven Skills
journeys that exceeded their hosted D409 ceilings now pass those unchanged
ceilings locally. This closes local D410 qualification; the exact-head hosted
runner remains independent evidence, and this Tahoe-family result does not
certify physical Sequoia, another Tahoe machine, or assistive technology.

Exact-head D410 CI run `33114439386` passed current-SDK, Sequoia, lint, and
repository-hygiene jobs. Scoped UI run `33114439299` expanded to all 106
English journeys because the shared support file changed; it retained 104
passes, but Interview Assist could not reveal its admitted objective and the
ordinary correction journey overscrolled its action above the transcript
viewport. The receipt measured 1,375.478 seconds of summed XCTest against the
unchanged 1,300-second ceiling. The hierarchy and scroll timeline established
deterministic geometry defects, so the same head was not rerun.

**D411 settling and risk ownership.** Interview now treats the inserted
objective as later content and caps every missing-target step at 48 points.
Interview and Meeting Detail both derive direction from current target and
viewport geometry, then use one predicate that waits for a nonempty, hittable,
fully contained frame to remain stable. An already-contained target waits
without another scroll. This removes the immediate precheck that could observe
an old accessibility frame and overscroll before layout settled.

The disposable scale fixture also replaces its three-second summary delay with
the existing finite file handshake. The 20,000-segment journey observes
revision 1, releases revision 2, and verifies the live update plus chapters;
the 5,000-segment journey alone owns the representative screenshot. Structural
correction UI retains split, merge, durable restore, suppression, visible-row
removal, and hidden-evidence recovery. Real-store tests own merge-boundary
search, restored accepted identity, and suppressed-row exclusion, while the
seeded Library journey owns real-app search navigation. Email retains its
complete preview, handoff, local receipt, privacy, and offer-retirement chain;
Gist and central Skills journeys own cross-window Settings receipt projection.
Source ratchets preserve every replacement owner and reject the removed
duplicate work. No timeout or runtime budget increased. A fresh six-case
causal slice passed 6/6 in 106.080 seconds with p95 26.521. The changed-file
selector then selected 36/106 English Interview and Meeting Detail journeys;
the real app used disposable seeded state, reused one 13-second build, and
passed 36/36 in 320.085 summed XCTest seconds (341 seconds test wall, p95
23.262, maximum 26.792). Interview measured 11.975 seconds, ordinary correction
15.325, structural correction 26.792, Commitment 23.262, email 11.359, and the
20,000-segment observed update 15.765. The receipt has no aggregate,
percentile, or per-case violation.

Local build, current-SDK first-party diagnostics-as-errors, strict SwiftLint
over 742 files, repository hygiene, and 25/25 independent recording/recovery
stress iterations are green; each stress iteration executed 237 tests. The
first complete package run executed 2,787 tests with 15 explicit model-gated
skips and found one documentation-only violation: the architecture document
named decision/sequencing vocabulary instead of durable as-built facts. That
prose was corrected, its focused ratchet passed, and a fresh canonical run
then passed all 2,787 tests with the same 15 skips in 121.050 seconds. This
closes local D411 qualification. Exact-head hosted receipts are still required;
the final complete bilingual gate and physical Sequoia/Tahoe plus
assistive-technology evidence remain separate.

**D412 hosted-failure ownership.** Exact D411 head `2e00e18a` passed hosted
current-SDK, Sequoia, lint, and repository-hygiene run `33122838333`. Scoped UI
run `33122838235` selected 36 English journeys and passed 33/36. Its retained
result bundle showed three independent owner defects: Interview guessed six
scroll moves before the accepted objective row existed in the accessibility
tree; the Commitment editor's SwiftUI Picker projected its selected option's
dynamic identifier onto the native pop-up; and the 20,000-segment detail
fixture launched three unrelated search-reconciliation lanes before its first
detail projection. The red run measured 690.209 summed XCTest seconds and p95
55.350 seconds. It was diagnosed rather than blindly retried or admitted by a
larger budget.

Interview now reveals the already-published objective-count anchor before it
resolves the exact identifier-plus-label row, and its bounded geometry helper
fails rather than guessing when a target has not materialized. The Commitment
journey requires the single native pop-up inside the stable editor boundary;
the exact menu-item identifier still proves the selected owner. Disposable
detail-scale launches publish a terminal seed marker when their attempt
returns; successful seeds have completed persistence and routing, while failed
seeds proceed to an exact missing-content failure instead of a blind timeout.
Spotlight, semantic-index, and memory-graph reconciliation stay with their
independent product and scale gates. Both scale journeys wait for that marker,
and the 20,000-segment revision handshake remains unchanged. No timeout or
runtime budget increased.

The final fresh local causal slice passed the three formerly hosted-red
journeys 3/3 without retry in 53.481 summed XCTest seconds, p95 24.260 seconds:
Interview exact evidence, Commitment evidence review, and 20,000-segment
initial detail plus live summary. The accepted canonical package run passed all
2,787 tests with 15 explicit model-gated skips in 121.371 seconds. Swift build,
first-party current-SDK warnings-as-errors, strict SwiftLint over 742 files, and
repository hygiene also passed.

The shared-harness fallback retained all 106 cases per locale. One complete
English run was functionally green but withheld by an unchanged Skills runtime
budget after a 26.503-second host accessibility delay; the same owner measured
15.320 seconds in one controlled focused remeasurement, so no budget changed.
The next complete English receipt passed 106/106 in 984.522 summed XCTest
seconds (999-second test wall, p50 6.766, p95 18.997, maximum 47.438) with a
five-second build and no violation.

That invocation's Spanish result was invalid shared-host evidence rather than
a product red. Across the failing interval, XCTest repeatedly named a
foreground `com.github.Electron` window; its retained crash report identifies
the ChatGPT/Codex coalition and a fault inside `XCTAutomationSupport`. A second
attempt was stopped after the same external window appeared from a concurrent
Puntovivo Electron lane, instead of consuming the rest of the catalogue. Once
that lane finished, the exact interrupted Spanish journey passed in 4.464
seconds. The controlled complete Spanish receipt then passed 106/106 in
1,048.014 summed XCTest seconds (1,062-second test wall, p50 7.025, p95 25.170,
maximum 55.292) with a five-second build and no violation. Code and budgets
were unchanged between the accepted English and Spanish receipts. This closes
the D412 local bilingual boundary without treating retries as proof; exact-head
hosted, a final single-invocation candidate run, physical Sequoia/Tahoe,
assistive-technology, distribution, CloudKit, and field evidence remain
separate authorities.

The Developer-ID-signed `app.portavoz.mac.dev` bundle was then rebuilt and
deeply verified before `make install` copied, registered, and opened it only at
`/Applications/Portavoz Dev.app`. An independent deep-strict verification after
quitting the Dev process passed for both that installed bundle and the
`app.portavoz.mac` release bundle; their identities remained distinct. The
build reported no CloudKit provisioning profile, so this is local Dev-install
evidence rather than production-sync or distribution evidence.

**D413 hosted first-attempt ownership and harness repair.** Exact D412 commit
`35c76f9f` is published. Hosted CI run `33132928134` passed all four jobs. The
first hosted Scoped UI run `33132928108` expanded to the full bilingual
catalogue because the shared harness changed. English executed all 106 cases,
passed 105, and failed only
`testInterviewAssistGroundsTheCurrentQuestionInExactEvidence`; Spanish did not
start. The retained receipt reports 1,425.288 summed XCTest seconds, p95 30.584,
and eight individual-budget violations against unchanged limits. That red run
is retained as evidence and was not converted into an unchanged retry.

The activity tree shows the admitted-objective count publishing before the
exact objective row appeared in the accessibility tree. Interview therefore
now waits for the exact identifier-plus-label row before reveal. Interview and
Meeting Detail also use one shared bounded reveal: it caches the viewport,
caps steps at 48 points, observes only a target-frame change while the target
remains outside, and pays stable hittable containment once the frame is inside.
This removes repeated one-second impossible containment probes without adding
a sleep, retry, timeout, or larger budget.

Startup and interaction preparation retain explicit activation. On macOS,
`.runningForeground` proves process state but not frontmost key-window
ownership throughout a long catalogue. The three over-budget Skills owners use
the geometry helper's full containment plus a hittability wait instead of
repeating stable-frame polling. An instrumented AppKit termination request did
not reduce the roughly one-second clean process-exit interval recorded by
XCTest, so ordinary teardown deliberately retains the official
`XCUIApplication.terminate()` path and the existing next-launch process fence.

The first diagnostic nine-case English run passed 9/9 in 159.921 summed XCTest
seconds (p50 17.225, p95/maximum 29.573) with every unchanged individual budget
green; build time was 16 seconds and test wall time 185 seconds. Because that
build still included the rejected teardown experiment, the exact same selector
set ran again after restoring official teardown. That run passed 9/9 in 137.181
summed seconds (p50 15.255, p95/maximum 24.003), with an 8-second reused build,
153-second test wall, and every unchanged individual budget green.

The later complete English attempt exposed why activation cannot be inferred
from `.runningForeground`. It executed 106 cases, passed 96, and failed five
owners with ten assertions: Summary and custom-structure interactions produced
no mutation or route, Showcase did not leave Library, one Settings placement
proof failed while the rest of its journey passed, and structural undo resolved
against non-terminal text inside its editor. The retained receipt measured
1,130.824 summed seconds and p95 26.295; Spanish did not start. D413 restores
explicit activation and adds the exact structural-editor dismissal proof. The
changed-code causal English run of those five owners then passed 5/5 in 51.271
summed seconds with p95 24.543 and every unchanged individual budget green.
Architecture tests reject duplicated reveal helpers, removal of the exact
objective-row publication wait, activation elision, or structurally ambiguous
undo completion. The final local gate reused one build and passed the complete
106-case catalogue in both locales without retry: English measured 1,001.211
summed seconds (p50 6.724, p95 18.849, wall 1,017), and Spanish measured
977.724 summed seconds (p50 7.381, p95 19.048, wall 1,003). Both aggregate and
individual unchanged budgets passed. Exact-head hosted runtime evidence remains
pending; local automation does not claim physical, distribution, CloudKit, or
field authority.

**D414 hosted first-attempt ownership.** Exact D413 commit `b0650928` is
published. Hosted CI run `33168727132` passed all four jobs. The first hosted
Scoped UI run `33168727155` expanded to 106 English cases, passed 104, failed
Interview Assist and Commitment evidence review, and did not start Spanish.
The retained receipt records 1,374.951 summed XCTest seconds, p50 9.418, p95
25.261, maximum 77.134, build 518 seconds, and wall 1,429 seconds; the unchanged
1,300-second aggregate budget failed. Passing individual overages were the
Automation App Entity, Ask conversation, and 20,000-segment detail owners. The
functional failures are retained as evidence rather than retried unchanged.

Interview's exact objective is clipped immediately above its visible count
anchor and therefore absent from SwiftUI's accessibility tree until scrolling
materializes it. The anchor-aware reveal now moves in that known direction
before requiring existence, then transfers only its remaining bounded attempts
to ordinary stable containment. The Commitment hierarchy and the retained D412
pass establish that AppKit can coalesce one synthesized wheel event: a single
no-movement observation now consumes an attempt instead of terminating the
journey. The shared helper refreshes live viewport geometry and compares raw
frames with raw frames, while stable-frame waiting uses one combined nonempty-
frame/hittability deadline instead of a duplicate existence preflight. Step
size, waits, aggregate and individual budgets, selectors, assertions, and
locales are unchanged.

The initial causal repair passed the exact two hosted-red English journeys 2/2
without retry in 33.579 summed XCTest seconds. Adversarial review then fixed an
inset/raw viewport comparison and the anchor handoff's total attempt accounting
before final qualification. The accepted package run passed all 2,788 tests
with 15 explicit model-gated skips; warnings-as-errors, strict SwiftLint,
repository hygiene, and diff checks are green.

The final candidate reused one eight-second build and passed 106/106 in both
locales without retry or budget change. English measured 939.336 summed XCTest
seconds (p50 6.564, p95 17.090, maximum 46.836, wall 961); Spanish measured
975.360 (p50 6.669, p95 17.355, maximum 49.792, wall 994). Interview passed in
12.107/13.042 seconds and Commitment in 14.711/15.413 seconds. Every aggregate
and individual budget is green. Fresh exact-head hosted receipts remain
required. These automated results do not certify physical Sequoia/Tahoe,
assistive technology, distribution, CloudKit, or field behavior.

**D415 product-owned materialization and postcondition activation.** Exact D414
commit `70ca33ab` is published, and hosted CI run `33175667643` passed all four
jobs. Scoped UI run `33175667674` executed 106 English journeys, passed 104,
failed Interview Assist and Commitment evidence review, and did not start
Spanish. It measured 1,687.208 summed XCTest seconds and p95 34.501 seconds
against unchanged budgets. Retained video proves Interview entered the exact
objective, then six positive 48-point wheel events produced no visible content
or scrollbar movement. Commitment's Review action became fully visible, but AX
geometry/hittability still rejected it; the one subsequent native click opened
the exact editor.

The production recording scroll now identifies every objective row by its
domain UUID, observes only a one-row insertion, and centers that accepted row.
The Interview journey waits for the identifier-plus-exact-label element and
proves stable viewport containment with `maxScrolls: 0`; it cannot synthesize
the state it asserts. Commitment waits only for exact action existence,
activates once, and requires the exact editor postcondition. Geometry-aware
reveal remains for transcript corrections and the Interview answer action.
Source ratchets reject reintroducing objective-count scrolling, an anchor-owned
Interview reveal, repeated Commitment activation, or loss of the production
scroll target. No timeout, selector, locale requirement, aggregate budget, or
individual budget changed. The focused architecture contract compiles and
passes. The first causal English XCUITest passed both formerly hosted-red
owners without retry in 21.844 summed seconds: Interview 12.099 and Commitment
9.745, with p95 12.099 and every unchanged budget green.

The accepted complete package run passed 2,788 tests with 15 explicit
model-gated skips and no failure in 131.417 seconds. Current-SDK first-party
warnings-as-errors, strict SwiftLint across 742 files, repository hygiene, and
diff checks are green. The final local UI gate reused one build and passed the
complete 106-case catalogue in both locales without retry or budget change:
English measured 932.267 summed XCTest seconds with p95 17.428, and Spanish
measured 931.961 with p95 18.164. Every aggregate and individual budget
passed. Fresh exact-head hosted receipts remain required; these automated
results do not certify physical Sequoia/Tahoe, assistive technology,
distribution, CloudKit, or field behavior.

**D416 admission-first Interview evidence.** Exact D415 commit `b63010bf`
passed all four hosted CI jobs in run `33184784185`. First-attempt Scoped UI run
`33184784215` selected and executed 48 English journeys, passed 47, and failed
only Interview Assist; Spanish did not start. The retained receipt measured
894.906 summed XCTest seconds and p95 49.019 seconds. Interview measured 30.672
against 20.000 and reported both a missing exact UUID row and failed zero-scroll
containment.

The exported activity tree and recording prove the plus-control click was a
visible no-op at the compact viewport boundary: the typed text never cleared.
The count element was already present before the click, so its existence did
not prove a successful add. D415's UUID insertion observer was never exercised.
The later grounded-answer and citation assertions passed, isolating the failure
to objective admission rather than Interview inference.

The corrected journey submits through the focused field's visible Return
contract, requires the exact localized one-of-eight count, then proves the exact
UUID-prefix plus label row and zero-gesture containment. The consolidated live-
assist journey still covers the plus control, so coverage is not removed or
duplicated. Exact label/content predicates replace redundant preceding
existence probes. No sleep, retry, timeout increase, selector change, budget
change, or product-only test switch was introduced. The first focused English
real-app run passed without retry in 12.745 seconds under the unchanged
20-second budget; its exact one-of-eight count and UUID row passed zero-scroll
containment. D416 alone maps to that one Interview selector, but D417 changes
shared UI support and therefore expands the combined correction fail-safe to
complete bilingual hosted evidence. The post-D417 local gate passed all 106
English journeys in 968.202 summed XCTest seconds with p95 18.543 and all 106
Spanish journeys in 964.891 seconds with p95 18.746. Interview measured 11.544
and 11.704 seconds, respectively. Fresh exact-head hosted receipts remain
pending.

**D417 absent-query-safe stable frames.** D416's first complete English attempt
passed 106/106 functionally, including Interview at 12.657 seconds, but retained
a red runtime receipt after an unrelated Brave crash made one meeting-row click
consume 14.483 seconds. Its Decision journey measured 25.007 against 20.000.
After the external browser relaunched, one replacement attempt restored p95 to
17.837 seconds and uncovered a separate tabbed-summary failure during seeded
library navigation.

The second xcresult shows the fixture-ready and foreground boundaries had
completed and the seeded row had already been observed. During the sidebar's
one-time identity replacement the dynamic row query temporarily had no match.
`waitForStableFrame` accessed `frame` first, which makes XCTest raise an abrupt
`Failed to get matching snapshot` failure instead of returning an unsatisfied
predicate. Stable-frame polling now checks `exists` before reading geometry;
absence resets both the candidate frame and stability clock. The original
timeout, stable interval, selectors, gestures, assertions, and runtime budgets
remain unchanged, and the source contract enforces the safe ordering. The first
focused post-change real-app gate passed Interview in 11.742 seconds and the
formerly failing tabbed-summary journey in 8.567 seconds, for 20.310 summed
seconds and p95 11.742. The complete post-change bilingual gate then passed
106/106 English journeys in 968.202 summed seconds with p95 18.543 and 106/106
Spanish journeys in 964.891 seconds with p95 18.746; every aggregate and
individual budget passed. The warnings-as-errors build passed in 22.35 seconds,
and the full Swift suite passed 2,788 tests with 15 expected model-gated skips
and zero failures in 119.718 test seconds. Fresh exact-head hosted evidence
remains pending. The 106-test selector catalogue, its 56 policy tests, both
focused source-order ratchets, strict SwiftLint across 742 files, repository
hygiene, and diff whitespace checks also passed. The shared-support delta
selects the complete bilingual suite rather than a feature-only subset. Neither
retained red receipt is presented as a green retry.

**D418 endpoint-owned stable-frame queries.** Exact D416/D417 commit `4bc23129`
passed hosted current-SDK, Sequoia, strict-lint, and repository-hygiene run
`33195622267`. The first exact-head Scoped UI run `33195622246` selected all
106 journeys and both locales. Every English journey passed functionally,
including Interview in 16.156 seconds and tabbed summary in 11.826 seconds, but
Spanish did not start because the unchanged runtime gate failed. The retained
English receipt measured 1,458.192 summed XCTest seconds, p50 11.335, p95
28.187, and maximum 66.325; the aggregate budget is 1,300 seconds and six
individual budgets also failed.

This was a broad host-cost signal rather than one product failure. The accepted
local English receipt measured 968.202 summed seconds, and the median ratio over
all 106 hosted/local owners was 1.472. The exact Interview activity sequence had
67 top-level operations in both environments but spanned 16.124 seconds hosted
versus 11.469 locally. The 48 journeys shared with the preceding hosted run also
improved from 894.904 to 619.765 summed seconds. The first hosted receipt is
retained and is not retried unchanged.

The endpoint-only implementation first passed the five high-risk English
journeys 5/5 in 109.506 summed seconds. A second changed-code slice also passed
5/5 in 112.854 seconds but did not reduce the sampled queries: the activity log
still showed six existence/frame evaluations inside one nominal 0.25-second
window. `RunLoop.run(mode:before:)` is allowed to return after an ordinary
source is handled, so `waitForUITestCondition` had treated `pollInterval` as a
latest wake rather than a minimum probe cadence.

The shared `waitForStableFrame` path is used at 77 activation boundaries. It
continues to check query existence before geometry, reject an empty frame, and
admit a new candidate only while hittable. The next run-loop-driven sample now
occurs at the requested stable interval instead of repeating remote existence,
geometry, and hittability queries every 50 milliseconds. At that acceptance
edge, a different frame restarts the existing clock; the same frame must still
be hittable, or both candidate and clock reset. The default 0.25-second stable
interval and every timeout, selector, gesture, assertion, locale, and runtime
budget are unchanged. A source contract requires the stable interval to own the
probe cadence, exactly two ordered hittability evaluations, and D417's
absence-before-frame rule. The contained-scroll helper remains outside this
bounded slice.

The common condition primitive uses `RunLoop.run(until:)` through each declared
probe boundary. Application and accessibility events remain serviced; unlike a
fixed sleep, the main run loop stays live. Handled sources can no longer cause
an early repeated AX condition evaluation. The initial probe, final deadline
probe, declared 50-millisecond cadence for other predicates, and all wait
deadlines remain intact. A failed final deadline probe returns false without a
duplicate post-deadline query. The source contract rejects both that redundant
evaluation and the previous one-source `run(mode:before:)` call.

After enforcing that boundary, the third changed-code focused slice passed the
same five high-risk journeys 5/5 in 111.179 summed seconds. Final complete
real-app evidence reused one build and passed 106/106 English journeys in
981.113 summed seconds (p50 6.920, p95 18.761, maximum 51.068) and 106/106
Spanish journeys in 1,003.552 seconds (p50 7.012, p95 18.930, maximum 53.432).
All aggregate and individual runtime budgets passed. Warnings-as-errors build,
2,788 Swift tests with 15 expected model-gated skips, strict lint over 742
files, repository hygiene, catalogue/scope policy, and diff checks also passed.
The normal UI preflight reported only Notification Center; the explicitly
authorized exception was bounded to that signal, and two read-only samples
excluded SecurityAgent, Secure Input, `xcodebuild test`, and a UI test runner.

The final local runtime is intentionally not called an optimization win.
Compared with D417, English increased by 12.911 seconds (1.33%), Spanish by
38.661 seconds (4.01%), and the English median per-owner ratio was 1.011. All
six owners that exceeded unchanged budgets only on the hosted D417 runner
passed locally; four were modestly faster, while ordinary per-run variance
dominated the complete-suite total. The first exact-head hosted receipt remains
required to close D418. It is now retained as red: exact D418 commit `a1199bee`
passed all four hosted CI jobs in run `33203798869`, then Scoped UI run
`33203798892` passed 106/106 English journeys functionally but stopped before
Spanish on 1,771.372 summed seconds, p50 11.712, p95 32.243, maximum 109.240,
20 individual overages, and failed aggregate plus p95 gates. D418 did not
deliver a hosted end-to-end runtime improvement. Physical Sequoia/Tahoe,
assistive-technology, distribution, CloudKit, and field evidence remain
separate authorities.

**D419 actionable-edge and contained-Skills query compaction.** Exact activity
comparison keeps the D418 diagnosis causal. The consolidated Skills
period/filter journey had 341/342 top-level and 522/523 recursive activities in
D417/D418, with 337 aligned operations and the same 151 existence plus 184
find activities. It rose from 63.732 to 109.240 seconds because the same remote
operations became slower: aligned existence gaps added 16.537 seconds and find
gaps added 19.122 seconds. Interview saved one existence activity but retained
all 44 finds. The retained first attempt is not rerun unchanged.

Stable-frame samples now use `isHittable` as their safe absent/disabled/
occluded gate before reading `frame`. The same source guard executes at
candidate admission and the declared acceptance edge, clearing candidate state
before a frame read whenever actionability is lost. This preserves absence
safety, nonempty geometry, frame equality, the 0.25-second default interval,
and final actionability while removing the separate `exists` property from
both edges. The enforced run-loop cadence and every deadline remain unchanged.

Twenty-one Skills controls already proven contained by the bounded
`scrollToVisible` helper use one bounded `waitForHittable` before their click
rather than paying a second stable-frame proof. Controls without that geometry
owner are unchanged. The same helper now reuses one target-frame snapshot for
both containment and scroll-distance calculation on each of its six bounded
attempts, returns as soon as containment is true, and takes a final snapshot
only if all attempts are exhausted. A source contract requires hittability
before frame, rejects the separate stable-helper existence query, rejects
containment-then-stability duplication, and prevents the prior visibility
closure from reintroducing duplicate frame reads. Selectors, launches, gesture
direction and clamp, assertions, timeouts, locales, aggregate budgets, and
individual budgets are unchanged. Focused, complete bilingual local, and first
exact-head hosted evidence remain required before D419 closes.

The first same-eight-owner English real-app slice passed 8/8 in 180.340 summed
seconds after actionable-edge and contained-control compaction. A second run
was justified by the subsequent scroll-helper code change and passed the same
8/8 in 150.734 seconds (p50 13.976, p95/maximum 38.395), 29.606 seconds or
16.42% faster, with every individual budget green. The six affected Skills
owners all improved; the two non-Skills controls varied by +0.630 and -0.157
seconds. The consolidated filter journey's activity tree fell from 287 to 173
top-level and 468 to 354 recursive activities, including 127 to 73 existence
and 154 to 94 find operations, while six gestures and ten match-count queries
remained unchanged. Interview retained 65 top-level, 107 recursive, 15
existence, and 44 find activities. These exact count changes demonstrate
code-owned query reduction; they do not predict the final complete-suite or
hosted runtime result.

The final complete real-app gate reused one build and passed 106/106 English
journeys in 905.317 summed seconds (p50 6.721, p95 18.695, maximum 38.083) and
106/106 Spanish journeys in 905.670 seconds (p50 6.603, p95 18.594, maximum
37.976), with no aggregate or individual budget violation. Relative to D418's
local complete receipts, English improved by 75.796 seconds (7.73%) and Spanish
by 97.882 seconds (9.75%). A warnings-as-errors build completed in 20.71
seconds; all 2,788 Swift tests passed with 15 expected model-gated skips in
131.183 test seconds; strict lint covered 742 files with zero violations; and
repository hygiene, the 106-test scope catalogue and policy suite, fail-safe
bilingual selection, and diff checks passed.

Exact D419 commit `9707b9b5` passed hosted current-SDK, Sequoia, strict-lint,
and repository-hygiene run `33215973171`. The first exact-head Scoped UI run
`33215972156` passed all 106 English journeys functionally and did not start
Spanish because the unchanged runtime policy failed: 1,482.123 summed seconds,
p50 10.603, p95 28.231, maximum 69.725, nine individual overages, and the
1,300-second aggregate violation. D419 reduced D418 by 289.249 seconds and
eleven individual overages, but the retained first attempt remains red.

**D420 static-boundary query ownership.** The retained D419 activity trees
attribute 710.945 seconds to 1,922 find plus 1,659 existence activities.
Main-window readiness contributes 110 existence and 440 find operations
because each of 110 launches pays a separate existence poll plus two
actionable geometry samples. The window itself is not clicked. Launch now
retains the foreground wait and explicit activation, then uses one bounded
hittability predicate for that static shell; every interactive product control
continues to own its stable or contained precondition.

The seeded meeting's hittability proof subsumes its preceding existence poll.
Settings establishes one 100-millisecond stable General anchor per window;
static category clicks then retain explicit activation, a bounded hittability
gate, and exact destination publication rather than repeating window geometry.
Skills caches only the open window's immutable scroll viewport, invalidates it
on open/close, and still samples every target frame and bounded wheel gesture.
Contained-frame sampling now honors its existing 100-millisecond stability
interval, and positive Skills text waits short-circuit label before value and
title. Static evidence capture relies on the screenshot operation's own
fail-closed snapshot rather than a duplicate existence preflight after product
assertions. Source policy rejects activation elision, repeated main-window/category
stability, missing cache invalidation, stale target geometry, or a shortened
containment boundary.

No selector, assertion, timeout, retry, gesture, case count, locale, aggregate
budget, or individual budget changes in this slice. The focused English
boundary suite passed 11/11 without retry in 177.026 summed XCTest seconds with
all unchanged individual budgets green. Complete bilingual qualification is
recorded with D421 below; first exact-head hosted authority remains required.
Automated receipts do not certify physical Sequoia/Tahoe, assistive-
technology, distribution, CloudKit, or field behavior.

**D421 same-fixture journey consolidation.** Seven Meeting Detail microtests
used the same disposable meeting and repeated five unnecessary app launches.
They now form two bounded journeys while retaining every original assertion and
all eight screenshot attachments. The review journey proves raw notes, privacy/
health/sync/chapter/Apuntador rail content, then the generated-document tabs and
action-item mutation. Static surfaces and their evidence are captured before
that mutation, so later state cannot satisfy an earlier check.

The evidence journey proves summary, decision, action-item, and Apuntador
citations. Because all four cite the same row at 00:03, each source after the
first is preceded by an explicit click on the transcript's 00:00 row and a
bounded assertion that the cited row is no longer selected and playback has
left 00:03. The subsequent source must reselect the exact row and restore the
exact time; consolidation therefore cannot reuse prior state as evidence.

The scope catalogue, Meeting Detail ownership contract, physical assistive-
technology checkpoint, real-audio lane, and runtime catalog use the new
selectors. The complete catalogue is 101 cases per locale. Both consolidated
journeys retain 20-second individual budgets, and the 30-second p95 plus
1,300-second aggregate ceilings are unchanged. Catalogue validation passes;
the two focused English journeys passed 2/2 without retry in 28.538 summed
seconds. Their seven predecessors measured 44.455 seconds on the same host, a
15.917-second (35.80%) reduction for the exact retained behavior.

The accepted complete package run passed all 2,788 tests with 15 explicit
model-gated skips and zero failures in 121.980 XCTest seconds. The complete
real-app gate reused one 13-second build and passed without retry: 101/101
English journeys in 837.187 summed seconds (p50 6.655, p95 17.505, maximum
36.449) and 101/101 Spanish journeys in 841.151 seconds (p50 6.692, p95
18.092, maximum 36.805). Every unchanged aggregate and individual budget
passed. Against D419's last pre-consolidation local receipt, English improved
by 68.130 seconds (7.53%) and Spanish by 64.519 seconds (7.12%).
Warnings-as-errors, strict SwiftLint across 742 files, repository hygiene,
catalogue/contract policy, and diff checks are green. Fresh exact-head hosted
evidence remains required.

**D422 hosted reset and scale-query correction.** Exact D420/D421 commit
`2a4f9823` passed the four hosted CI owners. Its first Scoped UI run completed
all 101 English journeys and brought the unchanged global gates under budget at
1,073.362 summed seconds and 25.181 seconds p95. It retained a narrower red
receipt: three reset assertions failed in the consolidated evidence journey,
that owner took 31.715 seconds, and the otherwise passing 20,000-segment owner
took 25.181 seconds against its 23.817-second budget. Spanish did not start.

The retained result bundle and synthesized events showed that the lazy
transcript's text-labelled `00:00` button reported hittable but every reset
landed at the same non-timestamp pointer coordinate. Playback remained at
`0:03` and the cited row remained selected, so three five-second polling windows
expired. Resets now activate the already identified `chapter-0` button, pause
through `player-play-pause`, then independently require a non-`0:03` playhead
and deselected cited row. Every following source still has to reselect that
exact row and restore `0:03`; all source values and screenshots are unchanged.

The scale activity log separately showed application-wide summary-text lookup
traversing the 20,000-row accessibility tree. Both revision assertions are now
scoped below `detail-generated-document`; the typed file handshake, fixture,
chapter assertion, and observed live revision remain unchanged. The first
corrected focused English run passed 2/2 without retry: evidence navigation in
17.364 seconds and the 20,000-segment owner in 16.211 seconds, with every
unchanged individual and aggregate budget green. The final complete bilingual
head passed evidence navigation in 16.073/15.620 seconds and the 20,000-segment
owner in 15.222/14.612 seconds for English/Spanish. First replacement-head
hosted authority remains required.

**Real recording fragments.** `make test-ui-real-audio` drives the player
journeys (skip, only-my-voice, clip export, evidence seek) against a scratch
COPY of a real recording: point `PORTAVOZ_TEST_AUDIO_ROOT` at a folder shaped
`Audio/<uuid>/…` and the seeded meeting adopts that audio instead of the
synthetic two-tone clip. The target refuses paths that look like the release
app's live data, and `run-ui-tests.sh` exports the override in both plain and
`TEST_RUNNER_`-prefixed forms so it reaches the runner process regardless of
how xcodebuild spawns it. This lane is owner-run evidence — real recordings
never enter the repository.

**Launch-recovery publication artifacts.** The real-app recovery journey treats
`.portavoz-recovery-*` as a private staging namespace that must be empty after
publication. It identifies published copies only as visible directories,
requires exactly one after one button activation, safely unwraps that result,
and verifies its `portavoz.sqlite` before comparing the failed source bytes.
Hidden filesystem metadata in a user-selected destination is not a published
copy and must not create a false failure. This classification is source-
ratcheted so future test refactors cannot replace it with an unordered raw
directory count. The complete bilingual gate passed this owner in 3.791 seconds
English and 3.960 seconds Spanish.

**Consolidated review-query ownership.** The Meeting Detail review journey
resolves its notes, secondary rail, and generated document once, then limits
child assertions and interactions to the owning accessibility subtree. An
action item is admitted by one stable-and-hittable proof rather than an
existence query followed by the stronger proof. When two retained evidence
names represent the same unchanged window state, the harness captures one
immutable screenshot and creates both attachments from it. Policy ratchets
preserve the semantic boundaries, the two names, the single capture, the
strong interaction gate, and the unchanged 20-second owner budget. The
ownership parser accepts only literal multi-name arrays and fails closed on a
dynamic alias list; the canonical ownership document therefore remains exact.
The first corrected focused English run passed without retry in 12.992 seconds,
down from the retained 21.400-second complete-suite observation while keeping
the 20-second ceiling unchanged. The complete bilingual gate passed it in
13.126 seconds English and 13.709 seconds Spanish. Across the full catalogue,
English passed 101/101 in 851.326 summed seconds (p50 6.720, p95 18.533,
maximum 35.965) and Spanish passed 101/101 in 848.513 seconds (p50 6.795, p95
18.094, maximum 36.213), with every unchanged budget green. The package suite
passed 2,788 tests with 15 explicit skips, warnings-as-errors and strict lint
were green, and repository hygiene accepted the literal multi-name ownership
contract.
