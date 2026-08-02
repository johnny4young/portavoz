# Architecture

## Purpose

Portavoz is a local-first meeting assistant for macOS. It records independent
audio channels, creates live and refined transcripts, attributes speakers,
generates reviewable intelligence, and stores the user's library on the Mac.
Remote operations are explicit, policy-gated, and recorded without copying
meeting content into diagnostics or telemetry.

This document describes only the architecture implemented in the repository.
It is intentionally independent from roadmap terminology, work-item names,
migration history, and delivery sequencing. Detailed runtime behavior belongs
in `docs/specs/`; binding trade-offs belong in `docs/DECISIONS.md`; remaining
limitations and field validation belong in `docs/GAPS.md`, with deferred Apple
platform work in `docs/IOS.md`.

## Architectural style

Portavoz is a modular monolith distributed as one macOS application and one
command-line executable from a single Swift package. Module boundaries provide
dependency direction and test seams without introducing a backend, service
mesh, event-sourcing framework, or global state-management framework.

The system combines these patterns:

- application use cases for multi-step product workflows;
- typed domain values and stable failure categories;
- GRDB transactions and query-specific read models;
- durable owner-leased jobs for restart-safe derived work;
- process managers for filesystem and database reconciliation;
- feature-scoped observable presentation models;
- injected capability and platform adapters;
- explicit, content-free policy records before meeting-content network egress.

Feature parity is a permanent constraint: audio and user-owned data remain
discoverable when transcription, diarization, generation, indexing, sync, or an
external integration fails.

## Current module graph

`portavoz-app` and `portavoz-cli` are the current composition roots. They link
the concrete capability modules needed to construct production adapters and
also enter characterized workflows through `ApplicationKit`.

```mermaid
flowchart TB
    UI["portavoz-app\nSwiftUI presentation and macOS composition"]
    CLI["portavoz-cli\ncommands and process composition"]
    APP["ApplicationKit\nuse cases, policies, read contracts"]
    CORE["PortavozCore\ndomain values and shared contracts"]
    MODEL["ModelStoreKit\npinned model catalog and verified lifecycle"]
    STORAGE["StorageKit\nGRDB persistence and scoped read models"]
    CAPTURE["AudioCaptureKit\naudio capture"]
    TRANSCRIPTION["TranscriptionKit\ntranscription engines and scheduling"]
    DIARIZATION["DiarizationKit\nspeaker separation and attribution"]
    INTELLIGENCE["IntelligenceKit\ngeneration and embeddings"]
    PLAYBACK["AudioPlaybackKit\nplayback, waveform, clips, compression"]
    INTEGRATIONS["IntegrationsKit\nexports, external systems, sync transport"]
    PLATFORM["PlatformKit\nApple platform and security adapters"]

    UI --> APP
    CLI --> APP

    UI -. composition .-> MODEL
    UI -. composition .-> STORAGE
    UI -. composition .-> CAPTURE
    UI -. composition .-> TRANSCRIPTION
    UI -. composition .-> DIARIZATION
    UI -. composition .-> INTELLIGENCE
    UI -. composition .-> PLAYBACK
    UI -. composition .-> INTEGRATIONS
    UI -. composition .-> PLATFORM

    CLI -. composition .-> MODEL
    CLI -. composition .-> STORAGE
    CLI -. composition .-> CAPTURE
    CLI -. composition .-> TRANSCRIPTION
    CLI -. composition .-> DIARIZATION
    CLI -. composition .-> INTELLIGENCE
    CLI -. composition .-> PLAYBACK
    CLI -. composition .-> INTEGRATIONS
    CLI -. composition .-> PLATFORM

    APP --> CORE
    APP --> STORAGE
    APP --> PLAYBACK
    APP --> TRANSCRIPTION
    APP --> DIARIZATION
    APP --> INTELLIGENCE

    MODEL --> CORE
    STORAGE --> CORE
    CAPTURE --> CORE
    TRANSCRIPTION --> CORE
    TRANSCRIPTION --> MODEL
    DIARIZATION --> CORE
    DIARIZATION --> MODEL
    INTELLIGENCE --> CORE
    INTEGRATIONS --> CORE
    INTEGRATIONS --> STORAGE
    INTEGRATIONS --> INTELLIGENCE
    PLATFORM --> CORE
```

Capability modules never depend back on `ApplicationKit`. Sibling capability
dependencies are limited to three declared edges: `TranscriptionKit` and
`DiarizationKit` use `ModelStoreKit` for the verified model lifecycle, and
`IntegrationsKit` uses StorageKit for persisted sync state plus
IntelligenceKit values for issue-export formatting. `AudioPlaybackKit` is
self-contained over system frameworks and carries no module dependency.

## Module responsibilities

| Module | Implemented responsibility |
|---|---|
| `PortavozCore` | Typed meeting, transcript, speaker, person, audio, processing, provenance, evidence, language, privacy, sync, immutable transcript-correction, secret-identifier, and content-free resource-workload values plus capability ports, the universal lexical transcript-content policy, and deterministic generated-card admission. Its only imports are Foundation and CryptoKit (digest values); it links no UI, persistence, media, logging, or platform-service framework. |
| `ApplicationKit` | Delete, restore, purge, summary regeneration, local summary-provider discovery and clean-install selection, external-audio import, file transcription/diarization/summarization, meeting-bundle import/export, coherent meeting-document preparation and explicit document/action publishing, whole-library Markdown backup plus publication-recovery contracts, Ask search/evidence/answer coordination, deterministic semantic-corpus indexing and speaker-safe retrieval-chunk candidate derivation, command-library reads, verified calendar-backed speaker-name suggestions, inert Meeting Detail title/structure/chapter suggestions, correction-ready Meeting Detail transcript reading snapshots, pure transcript-correction composition, focused text/speaker correction, and accepted-snapshot structural correction commands, Meeting Detail playback preparation, waveform/filter coordination, failure-safe channel compression and clip export, deterministic pre-meeting reminder resolution, local voice capture/enrollment/status/deletion, explicit participant-voice memory and privacy-safe gallery management, microphone discovery, resumable recording-root management, pinned-model management, first-run eligibility, exact local-data receipts, pre-meeting preparation, refine/apply, recording start/stop/recovery, durable post-capture execution, typed workflow failures, storage-independent Library/Insights/Meeting Detail/menu-bar contracts, and deterministic product/read policies. |
| `PlatformKit` | Concrete Apple platform and security adapters. It currently owns device-only Keychain access, microphone authorization, and regular persistent file bookmarks while depending only on `PortavozCore`. |
| `ModelStoreKit` | Task-oriented model catalog, pinned artifact metadata, streaming SHA-256 verification, atomic download repair, verified-installation evidence, and process-scoped model lifecycle. |
| `AudioCaptureKit` | Call-safe raw microphone capture, explicit nondefault voice processing for bounded nonmeeting tools, macOS process taps, dual-channel recording sessions, callback-liveness recovery, staged CAF writing, utility-priority finalization, audio validation, checksums, levels, and recovery inspection. |
| `TranscriptionKit` | Live Parakeet and quality Whisper adapters, transcript scheduling, language-aware operation fingerprints, model preparation tokens, segment mapping, and one-shot CPU fallback when a verified Whisper model cannot load on its preferred accelerator. |
| `DiarizationKit` | Pyannote/Core ML speaker turns, clustering, attribution, voice matching, and encrypted local voice-gallery support. |
| `IntelligenceKit` | Foundation Models, Ollama/OpenAI-compatible, and embedded MLX summary providers; structured summaries with deterministic action/evidence admission; Apuntador; retrieval and answer primitives; embeddings; provider fingerprints; and egress-aware clients. |
| `StorageKit` | GRDB schema, migrations, strict record conversion, transactions, FTS5, scoped observations, query-specific projections, durable jobs, generation provenance, privacy receipts, typed evidence, immutable transcript-correction history with atomic multi-lane appends, local feedback, people, sync journal, aggregate replay, support-safe snapshots, and Spotlight projections. |
| `AudioPlaybackKit` | Synchronized channel playback, reversible role-aware clear mixing, stateless task-cancellable Accelerate waveform generation, silence skipping, voice-only playback, clip export, and AAC compression. |
| `IntegrationsKit` | Canonical Markdown/PDF, identity-preserving diarized SRT/WebVTT, and issue exports; meeting bundles; EventKit mapping; MCP protocol handling; policy-checked HTTP transport; deterministic sync envelopes; protected CloudKit record/state adapters; and sync lifecycle policy. |
| `portavoz-app` | macOS scenes, navigation, localization, accessibility, observable feature owners, dependency construction, native panels, model-lifecycle composition, and background supervisors. |
| `portavoz-cli` | Command parsing, terminal and MCP-tool presentation, benchmark harnesses, and one process composition surface. |

## Application boundary

`ApplicationKit` defines asynchronous Sendable workflows over narrow ports.
Concrete storage, model, capture, filesystem, playback-codec, document,
provider, and platform implementations are injected by the executable
composition roots.

The implemented application workflows include:

- meeting delete, restore, manual purge, and expiry purge;
- summary regeneration with explicit provider availability and provenance;
- local summary-provider discovery, typed recommendation, and first-selection
  persistence without overwriting an existing choice;
- external-audio import with required transcription and degradable derivation;
- relational `.portavoz` bundle import and read-consistent bundle export;
- read-consistent staged whole-library Markdown backup with typed partial
  results and capture checkpoints;
- reviewable refinement and revision-fenced acceptance;
- pre-capture recording reservation and failure reconciliation;
- audio-first stop, durable processing admission, and terminal recovery state;
- launch recovery for interrupted capture and expired processing leases;
- serial post-capture transcription, diarization, and summary execution with
  owner leases, heartbeats, exact input fingerprints, dependency admission,
  bounded retries, supersession cancellation, and scheduled wakes;
- canonical-person lookup and explicit speaker-to-person linking;
- instant Ask search, hybrid evidence retrieval, and optional local answer
  generation with evidence-preserving degradation;
- first-run eligibility without model or permission prerequisites;
- independent exact local-data receipt metrics with per-source degradation;
- pre-meeting preparation from shared Ask evidence, batched current summaries,
  open commitments, and source-indexed optional synthesis;
- bounded nonvisual meeting list/detail/search/open-item queries used by terminal
  and local protocol interfaces;
- standalone audio transcription, diarization with optional attribution, and
  summary generation over admitted files, with model and provider work behind
  injected processors;
- persisted meeting refinement that loads one current detail, accepts optional
  external audio, creates a revision-fenced draft, and applies it atomically;
- canonical meeting-document preparation for native save surfaces, explicit
  Gist publication, and pending action-item publication from one coherent
  meeting projection;
- local voice enrollment from an admitted file, a supplied in-memory sample, or
  a bounded captured sample; typed progress, sample validation,
  status/deletion, and ordered pinned-model inspection/installation all use
  capability-neutral ports;
- microphone discovery as capability-neutral identifiers and names, resumable
  recording-root inspection and update with ordered progress, and remembered-
  voice listing/deletion through a projection that excludes embeddings;
- speaker-name suggestion from one coherent meeting projection, optional
  calendar candidates, an injected untrusted proposer, and application-owned
  whole-token verification against currently unnamed remote speakers with
  typed transcript or calendar-candidate evidence;
- optional Meeting Detail title, structure, and chapter-label suggestion with
  application-owned eligibility, bounded output admission, cancellation, and
  per-output degradation over one storage-independent review projection;
- Meeting Detail audio preparation that resolves current channels, constructs
  one synchronized playback session, derives a bounded waveform and playback
  filters, coordinates failure-safe channel compression, and re-resolves files
  before clip export;
- pre-meeting reminder resolution from one sampled clock value, one configured
  lead window, session deduplication, and an injected upcoming-event source;
- degradable participant-voice suggestions, duplicate-offer admission, and
  explicit remembered-voice persistence without automatic speaker mutation;
- asynchronous user-managed secret reads, writes, presence checks, and deletion
  over an injected device-local storage port;
- scoped Library, Insights, Meeting Detail, and resident menu-bar read contracts;
- meeting-review, brief, reminder, mirror, and Insights policies.

Application failures cross into presentation as bounded categories or stable
workflow codes. Raw filesystem paths, localized dependency errors, model
payloads, and storage implementation details do not form the UI contract.
The app maps reachable typed use-case failures to catalog strings at the
feature-model/presentation boundary; English developer descriptions remain a
CLI and diagnostic fallback rather than user-facing copy.

## Presentation and state ownership

SwiftUI renders immutable snapshots and sends explicit actions through feature
owners. Adopted read surfaces do not observe a global invalidation counter.

| Surface | State owner | Lifetime |
|---|---|---|
| Library | `LibraryModel` | one main window |
| Insights | `InsightsModel` | one main window |
| Meeting Detail | `MeetingDetailScene` + `MeetingDetailModel` | one selected meeting route |
| Ask conversation | `AskModel` | one main window |
| Command palette | `CommandPaletteModel` | application process |
| First-run welcome | `FirstRunModel` | application process |
| Local-data receipt | `LocalDataLedgerModel` | application process |
| Resident menu bar | `MenuBarModel` | menu-bar scene |
| Global dictation | `DictationController` | application process |
| Private sync | `MeetingSyncModel` | application process |
| Whole-library backup | `LibraryMarkdownBackupModel` | application process |
| Spotlight reconciliation | `SpotlightIndexer` | application process |
| Post-capture processing | `PostCaptureProcessingSupervisor` | application process |
| Whisper preparation | shared readiness owner | application process |

Library combines independently observed meeting rows, open commitments, trash,
and active FTS results. Insights combines chronology, participants,
commitments, talk balance, and bounded finding evidence. Meeting Detail merges
transcript/cast, newest summary, Apuntador, privacy receipt, and durable
processing streams. A failed stream degrades only its section and preserves
healthy state from the remaining sections.

`MeetingDetailScene` is the route/composition owner and the only Meeting Detail
presentation type that receives `AppServices`. It constructs one
`MeetingDetailModel` in `@State`; the route keys the scene by `MeetingID`, so a
different destination cannot retain the prior model. The scene projects process
observations into immutable values and exposes explicit meeting-scoped actions. The child
`MeetingDetailView` receives the model, values, actions, and one
pure `MeetingDetailPresentation`; it neither observes `AppServices` nor creates
the model. Presentation formatting receives its locale and time zone explicitly
and imports Foundation only. The composition root is not an allowed dependency
of child presentation types; scoped action values are their mutation boundary.

The child is itself a composition surface rather than the owner of every visual
section. `MeetingDetailHeaderSection` renders identity, facts, participants,
and optional suggestions. `MeetingDetailTrustSection` renders processing,
recovery, and the privacy receipt. `MeetingGeneratedDocumentSection` renders
the summary overview, decision/open-question sections, typed commitments, and
claim-adjacent proof controls. Each receives only explicit values and actions;
none can reach the route model, services, stores, or global preferences. The
generated section owns only tab selection, while the trust section owns only
retry progress. A pure Foundation projection preserves Markdown source
ordinals for evidence and suppresses a canonical `Action Items`/`Pendientes`
appendix only when equivalent typed commitments exist, so legacy content is
never discarded and the current document never renders the same task twice.
Each extracted section is an accessibility containment group: its stable
section boundary coexists with, rather than replacing, nested control
identifiers used for interaction and automation.

Meeting Detail audio uses the same route owner. `MeetingDetailModel` owns
one-shot preparation, cancellation retry, compression state, playback
invalidation, and clip-export effects. ApplicationKit owns the operation order
and exposes an observable playback-session facade plus capability-neutral
waveform values.
Playback preparation has an audio-directory-scoped task lifetime, independent
from the multi-section review revision, so unrelated initial section updates
cannot cancel and consume the only load attempt.
ApplicationKit admits one immutable waveform snapshot with 600 buckets by
default and a hard 2,000-bucket presentation ceiling. `AudioPlaybackKit`
propagates route cancellation into its off-main worker and checks it between
fixed-size file reads. An obsolete route therefore stops deriving and publishes
no partial result; the complete finalized channel files remain unchanged and
authoritative.
The app composition resolves recording paths and supplies the concrete codec
adapter. `AudioPlaybackKit` owns AVFoundation playback, waveform analysis, AAC
encoding, and clip rendering. SwiftUI owns transport controls, drawing, and the
native save panel; it neither discovers channel files nor constructs audio
capabilities. Multi-channel compression refuses to replace an existing output,
retains every original until all outputs verify, removes generated outputs on
failure or cancellation, and only then removes the raw channels.

The menu-bar scene receives bounded recent-meeting and open-commitment updates
through an app adapter. EventKit access remains in the adapter and follows the
no-prompt resident-surface rule. The SwiftUI panel owns commands and rendering,
not Store or calendar coordination.

Global dictation has one process-scoped, main-actor owner and one UUID-fenced
session task. Microphone duration starts only after the real stream opens;
finish-before-readiness cancels, one owned tail task drains an accepted finish,
and cancellation closes the transcription feed immediately while fencing every
later state mutation and delivery side effect. Audio sample reduction and feed
delivery stay off the main actor; only the observable meter update crosses back.
Failure-dismiss tasks are single-owner and cancelled on restart so an older
error cannot dismiss a newer session.
System-wide input adapters remain at the app boundary: Carbon owns the keyboard
hotkey and a session `CGEventTap` owns one explicitly configured middle or
additional mouse button. The pure `MousePTTGesture` table also remains in the app
target because it decides presentation/input ownership, not speech recognition.
The tap registration is idempotent, cancels a mouse-owned capture before
rebinding can discard its release event, and retries after the app returns from
the Accessibility permission flow. Invalid persisted button numbers normalize
to disabled; CGEvent indices 0/1 (left/right) are never eligible.
TranscriptionKit owns only the post-ASR text policy: optional bilingual filler
removal followed by one non-cascading, longest-trigger-first replacement pass.
The policy reads one canonicalized rule snapshot at delivery, never mutates a
meeting transcript, and treats the first match against the original dictation
as the user's authoritative spelling.
The last-mile `TextInserter` returns a typed result. It waits for physical
modifiers without swallowing cancellation, refuses a timed-out chord, performs
a fail-closed Accessibility inspection immediately before clipboard mutation,
posts a complete synthetic paste pair or restores synchronously, and later
restores only captured pasteboard representations when its change count still
owns the clipboard. Secure or uninspectable focus, unavailable clipboard or
event delivery, and held modifiers become visible failures rather than false
insertion success.

Live Apuntador keeps endpoint admission split across layers: the pure,
deterministic `TurnEndpointPolicy` in `IntelligenceKit` owns the remote-channel,
noise, question/name, and speculative-material rules, while
`RecordingController` owns exactly one main-actor silence deadline. Both a real
row close and a two-second silence expiry enter one shared detection dispatch;
the app never closes or rewrites the coalescer's mutable row. Every accepted
delta re-arms the deadline, and recording activation or an in-meeting opt-in
also synchronizes it so an already-visible remote question cannot be stranded
at either lifecycle boundary. Recording activation first drains every row that
closed while Start was still preparing, then arms the open tail. Disabling
Apuntador, stopping, or resetting the session cancels the pending deadline.

Bounded recording-scoped live Apuntador owns generation separately from that
deadline. One coordinator admits at most one active generation and one newest
not-yet-started candidate. Additional candidates replace only that pending
slot; they never create wrapper tasks or an unbounded queue. Disabling
Apuntador, stopping, resetting, or advancing to another recording clears the
pending candidate and cancels the active worker. A result may publish only
while its worker remains uncancelled, and a new lifecycle waits behind an
uncooperative older generator until it unwinds, preserving the one-active
invariant. Visible cards remain unlimited user history and are independent of
this ephemeral work bound. Generated cards cross a separate deterministic
last-mile boundary before presentation or persistence. Overlapping question
segment identities establish one source-turn lineage; a short time-bounded,
negation-safe lexical fallback handles adjacent captions that were split before
evidence identities converged. A more complete result replaces the prior card,
while an older or weaker result is discarded. The intelligence boundary also
repairs only pathological every-word title casing, preserving configured names
and common technical acronyms.

The pre-meeting reminder controller owns only its periodic task, session-local
deduplication, floating panel, and recording route. It requests a typed notice
from an application workflow. The app adapter samples preferences and time once
and performs the EventKit projection away from the main actor. Disabled
reminders do not query the calendar; due-event selection is independent of
source order and uses the same sampled time for admission and displayed
minutes.

The full Ask route and the command palette share one `AskMeetings` application
workflow. Its public request and response values carry meeting identity,
timestamps, snippets, complete evidence, and optional generated text without
exposing StorageKit records or IntelligenceKit passages to presentation.
The same boundary can emit lexical and final fused evidence while preserving
its final-result API. `AskModel` owns each window's draft, conversation,
finding/refinement/generation progress, early citations, cancellation, and
stale-result fence. `CommandPaletteModel` owns process-scoped instant results,
answer state, cancellation, and generation fencing so closing one panel cannot
publish work into a later invocation. SwiftUI and AppKit retain rendering,
clipboard access, panel lifecycle, route selection, and exact evidence seeking.
The CLI command and local MCP tool enter the same workflow before formatting
their terminal or protocol responses.

The CLI has one process-wide platform composition and one database composition
surface. Meeting list, detail, search, open-item, Ask, and MCP reads enter
`QueryMeetingLibrary` or `AskMeetings`; the application values expose no GRDB
records. Detail plus the latest live General summary comes from one SQLite read
snapshot. File transcription, diarization, summarization, persisted refinement,
document export/publication, action-item publication, local voice management,
and pinned-model lifecycle also enter ApplicationKit workflows. Command files
retain argument parsing and terminal/protocol formatting. Concrete filesystem,
model, storage, voice, provider, integration, hashing, and platform behavior is
confined to `CLIComposition` and `CLIProductAdapters`. Capture diagnostics and
benchmark harnesses retain isolated direct capability construction.

The post-capture supervisor coalesces producer notifications, starts one
application workflow drain, and schedules the next persisted wake without
polling. `ProcessPostCaptureJobs` owns job order, lease maintenance, operation
identity, transcript cleanup and attribution policy, dependency admission,
summary provenance, retries, cancellations, lifecycle outcomes, and
post-meeting action timing. The app adapter owns concrete recording paths,
filesystem checks, model loading, user preferences, Shortcut invocation, idle
engine release, deterministic UI fixtures, and content-free signposts.

Meeting Detail document actions also enter the application boundary. One
workflow loads the selected meeting and latest General summary coherently,
then renders only the requested representation: canonical Markdown, PDF
derived from that Markdown, or SRT/WebVTT directly from the diarized
transcript. The typed subtitle port cannot receive a Markdown/PDF request,
speaker identity—not display-name equality—controls cue merging, and the
native save surface receives an extension-specific content type plus the
released title-based suggested filename. Explicit secret-Gist publication
uses the same coherent source and Markdown renderer. The app adapter owns
utility-priority rendering, lazy credential resolution, gateway-backed
publisher construction, and native platform presentation. The route-owned
`MeetingDetailModel` owns document actions and typed effects; SwiftUI owns the
user gesture, off-device confirmation, save panel state, and localized result.

Meeting Detail voice memory enters a separate application workflow. It reads
one coherent meeting projection, limits candidates to unnamed remote speakers,
loads the encrypted gallery through an injected port, asks an injected
extractor only for relevant labels, applies one-to-one voice matching, and
returns suggestions without mutating the cast. Remembering a voice requires a
separate explicit request for a currently named remote speaker. The app adapter
owns recording-path resolution, model loading, transient embedding extraction,
encrypted gallery access, and disposable-test isolation. `MeetingDetailModel`
owns one-shot loading, suggestion state, duplicate-offer checks, and explicit
remember effects; SwiftUI never calls those adapters directly.

Meeting Detail transcript/calendar naming enters another application workflow.
It reads one coherent meeting projection, excludes the local and already named
speakers before using optional capabilities, asks an injected calendar source
for candidates around the meeting, and treats every generated proposal as
untrusted. A proposal is returned only when its label is still eligible and its
normalized name appears as complete tokens in a real transcript line or
calendar candidate. The workflow derives typed evidence from that source,
deduplicates labels, and never exposes generator-authored evidence prose. The
app adapter owns EventKit authorization and the concrete on-device proposer.
The route-owned `MeetingDetailModel` owns loading and suggestion state, removes
a chip only after its explicit rename persists, and keeps a failed confirmation
visible. SwiftUI renders inert chips, labels transcript versus calendar
evidence, and sends explicit actions. Calendar-backed confirmations retain
calendar provenance when the user later creates a canonical-person alias. No
suggestion names or links a person automatically.

Meeting Detail's optional title, summary-structure, and chapter labels enter a
single application workflow. It admits only template-like meeting titles,
General summaries, and still-untitled chapters; bounds generated labels; maps
recipes back to the known catalog; and preserves literal chapter excerpts when
generation is unavailable or fails. Cancellation remains cancellation so a
newer read revision can retry rather than publish stale suggestions. The app
adapter owns Foundation Models capability and the concrete title, meeting-type,
and chapter generators. The route-owned model owns one-shot state, revision
fencing, retry admission, and inert suggestions. SwiftUI renders suggestions
and sends explicit acceptance actions; no title or structure is applied
automatically. A failed title save keeps its chip visible and reports the
existing localized rename error.

The user's own voice enrollment also enters an application workflow. The
workflow bounds requested capture time, requires at least four seconds of
finite sample data, orders capture, extraction, and encrypted persistence, and emits typed progress without
importing audio or diarization implementations. The app adapter owns the exact
microphone mode, guarantees capture shutdown on success, failure, and
cancellation, loads the verified diarization capability, extracts the transient
embedding, and invalidates the cached diarizer only after a successful save or
delete. A destructive failure remains visible and does not clear presentation
state. Settings requests a twelve-second echo-cancelled capture. Onboarding
either reuses its already captured first-listen sample or requests a fresh
twelve-second raw capture. Neither SwiftUI surface constructs a microphone,
loads a model, extracts an embedding, or reads the encrypted voice store.
Disposable UI composition never reads or writes the host voice identity.

Settings obtains microphone choices, recording-root state, and remembered-
voice summaries through application workflows. The macOS adapter retains Core
Audio enumeration, marker-file and filesystem migration behavior, and the
encrypted gallery. Recording-root progress is drained in order before the
workflow returns, and the active marker changes only after migration succeeds.
A destination that resolves to the active root, including a symlink alias, is
a no-op and cannot enter resumable cleanup against its own source.
The gallery projection contains identity, display name, and creation time but
never an embedding. SwiftUI owns the folder panel and localized state; failed
destructive gallery actions remain visible and preserve the current list.

Whole-library backup survives Settings-window closure because progress and
terminal state belong to a process-scoped owner. Settings retains only the
native folder picker and localized presentation.

The first-run owner resolves one process-wide presentation decision so restored
windows cannot compete to show setup. It tracks active main-window hosts and
hands the single sheet to another active host if its current window closes.
Existing-library detection uses only a live-meeting count, and model readiness
never blocks launch or recording. The
Settings data receipt loads meeting count, allocated audio bytes, and encrypted
voice count concurrently; an unavailable source affects only its own tile and
is never rendered as a verified zero. Network behavior is presented separately
as an explicit-transfer and opt-in policy backed by local receipts.

Upcoming-meeting preparation belongs to the Library owner and enters
`PrepareMeetingBrief`. EventKit remains at the macOS adapter and is queried only
after access already exists. The workflow ranks shared Ask evidence, loads
current live summaries in one bounded database projection, overlaps commitment
loading, and admits generated context only when its source index resolves to a
navigable related meeting. Agenda buttons explicitly opt out of selectable
meeting-row behavior, so opening a brief cannot race the sidebar's meeting
route. Persistent privacy seals use local-first and explicit opt-in language;
feature-specific on-device claims remain limited to operations that cannot use
a remote provider.

## Verified model lifecycle

`ModelStoreKit` is the only source of local-model installation truth. Every
catalog descriptor fixes its revision and enumerates every artifact with an
expected byte count and SHA-256 digest. `ModelStore` streams each digest,
downloads only missing or corrupt artifacts into a same-directory sibling,
verifies the staged bytes, publishes them with one atomic rename or replacement,
and performs a complete verification pass before returning a loadable directory.

`VerifiedModelLifecycle` wraps the process's shared `ModelStore`. It emits an
installation value only after the complete descriptor passes verification,
keys successful evidence by descriptor identity and revision, coalesces
concurrent checks, and caches only successful results. Missing or corrupt
results remain re-checkable. Mutating operations for one descriptor execute in
invocation order, while explicit installation, deletion, invalidation, or
forced verification supersedes older checks; an awaiting consumer loops to the
current result instead of receiving stale evidence. Cancellation remains
effective before publication but cannot report false failure after a verified
installation crosses its filesystem commit point. This avoids hashing
multi-gigabyte weights for every consumer without treating a directory, one
expected filename, or aggregate file size as proof.

The macOS composition root owns one store and lifecycle for Settings, summary
provider resolution, import, durable post-capture work, support diagnostics,
live transcription, diarization, refinement, and voice-memory extraction.
Production model artifacts live in the stable user-domain
`~/Library/Application Support/Portavoz/Models` root, outside both
`Portavoz.app` and `Portavoz Dev.app`. Replacing either application bundle
therefore does not remove a verified model; only the explicit model-delete
workflow mutates that installation. Refine, Import, Settings, and CLI describe
the operation as local verification until `ModelStore` reports missing or
corrupt artifacts; only that latter activity is labeled as a download. Download
percentage is never synthesized for a checksum-only pass.
Disposable automation receives an isolated empty model root and never inspects
host installations. Settings verifies in the background and renders a checking
state until evidence exists; it never exposes a partial installation as
downloaded. Recording remains audio-first and does not await any of these
checks.

## Persistence and aggregate integrity

Storage uses GRDB over SQLite with additive migrations and strict conversion.
Persisted identifiers are never replaced with random fallback values. Deleted
meetings are excluded from live aggregate reads, and child records cannot make
a tombstoned root visible again.

The current schema version is 22. It includes:

- meetings with lifecycle state and transcript revision;
- audio assets with capture/publication/health metadata;
- meeting-local speakers and explicitly confirmed canonical people/aliases;
- transcript segments, FTS5 search, and compatibility-fingerprinted local
  semantic-vector derivations;
- immutable summary versions and action items;
- Apuntador cards and role-separated source evidence;
- generated overview, decision, and action-item evidence;
- reversible current-claim feedback stored separately from generated output;
- explicitly confirmed commitment continuity, typed ownership, immutable
  source/history evidence, and reversible generated-source review treatment;
- immutable generation-run provenance;
- one regenerable enhanced-notes document per meeting (raw notes stay
  untouched; provenance commits atomically with the artifact);
- content-free meeting egress attempts and receipt coverage;
- owner-leased durable processing jobs;
- a content-free derived-maintenance source generation and independently
  leased scheduling ledger;
- a content-free per-meeting sync generation journal;
- meeting preferences and the generic outbox schema retained for compatible
  persistence even where runtime delivery uses another mechanism.

Aggregate writes that must remain consistent execute in one transaction.
Summary, Apuntador, transcript, evidence, provenance, and durable-job commits
use source-revision or owner-lease fences where applicable. Stale work is
discarded rather than overwriting newer truth.

Query-specific projections use explicit scope and ordering. Whole-library
backup first copies one immutable SQLite stage through bounded GRDB backup
pages, then uses the copied live-root ordering index to load one newest-first
aggregate at a time from that stage without offset rescans.
Spotlight uses a bounded projection and client-state reconciliation. Library,
Insights, Meeting Detail, and the menu bar use independent GRDB observations
sized to their surface.
Library search expands a small deterministic English/Spanish meeting lexicon
locally, then groups each complete language variant under FTS5 `OR` rather
than weakening every token into a broad union. FTS5 `unicode61` provides
case- and Latin-diacritic-insensitive exact matching without changing stored
transcript text. Exact hits publish immediately. When Apple's Latin contextual
embedding assets are already installed and capture is inactive, Library
appends bounded cross-language semantic results from vectors already published
by maintenance. Typing never requests an asset download or writes the corpus,
semantic failure never invalidates exact results, and no additional vector
dependency is loaded. A selected hit emits the same one-shot
meeting/timestamp seek request used by Ask evidence before routing.

Ask and Library share one typed ApplicationKit readiness resolver. It combines
installed query-vector capability, a valid active embedding profile, one
profile-aware durable maintenance probe, and the process maintenance status
into `ready`, `partial`, `building`, `unsupported`, or `failed`. Exact search
remains available in every state. `partial`,
`building`, and `failed` may still query published vectors; `unsupported`
means no query vector can be produced. A complete durable corpus resolves
`ready` even after an older process failure.

All product corpus backfill belongs to the signal-driven background owner. It
delegates complete drains to `ProcessSemanticCorpusMaintenance`, which owns a
content-free scheduling lease around `IndexSemanticCorpus` behind one
process-shared semantic-indexing coordinator. Explicit disposable benchmark
preparation may use the indexing operation outside product requests. There is
no pending-request array and never more than one embedding flight.

Schema v18 triggers advance one semantic source generation when authoritative
segment text, identity, tombstones, or meeting transcript revision changes.
Embedding publication does not advance it. The application idempotently admits
one operation for the active compatibility profile and generation, cancels
superseded pending operations, and claims at most one kind-wide lease. The
lease receives a bounded heartbeat; expected capture suspension returns the
operation to pending and refunds the claim attempt. Ordinary failures retry
after 5 and 30 seconds, then become terminal. The supervisor schedules one
future wake for the earliest retry or still-live predecessor lease expiration;
it never polls. Launch recovery reclaims expired ownership and continues from
the existing vector cursor.
Cancelling the final waiter cancels the worker before persistence; another
borrower keeps shared work alive. The writer obtains one valid compatibility
profile from the prepared embedder, resets incompatible derived vectors to the
existing `NULL` cursor, marks micro-segments with an empty vector, validates
the result count and every non-empty vector against that profile before
persistence, and emits content-free maintenance/search-index intervals.
Missing or invalidated embeddings remain durable `NULL` rows, so coalescing,
profile changes, policy suspension, bounded retry, or process death lose no
authoritative corpus evidence. Source generation identifies an admitted
mutation set but never counts progress; meeting lifecycle remains independent,
and the dormant meeting-processing `.index` kind is not activated.

Ask and Library are read-only with respect to that corpus. After bounded
deterministic bilingual expansion, every Ask request starts exact FTS and
optional semantic augmentation concurrently. Exact citations publish as soon
as FTS completes; the fused citation set is fenced before answer generation.
Semantic work resolves the shared state without downloading assets and searches
only embeddings already published by the maintenance owner. Ask never invokes
`IndexSemanticCorpus` or persists an embedding. Missing assets and ordinary
semantic preparation/query failures degrade to lexical evidence; cancellation
still cancels the complete request. Foundation Models query expansion is a
bounded late fallback only when deterministic lexical plus available semantic
retrieval found no citation, not a prerequisite for first evidence. The
resource and quality harnesses prepare their disposable corpus before the
measured query, so benchmark setup does not weaken this product invariant.

PortavozCore owns one reusable `DurableMaintenanceGate`. The macOS composition
root maps its lock-protected capture mirror through the pure resource policy
and injects the gate into both ApplicationKit semantic indexing and
whole-library Markdown backup plus IntegrationsKit's existing-library sync
seed. Starting, active, and stopping capture defer a new maintenance pass.
Semantic indexing and sync already admitted finish their current bounded
database batch, publish an explicit policy-pause result, and do not fetch the
next batch. Ask then continues with lexical and already-indexed semantic
evidence instead of turning expected suspension into an error. Semantic
indexing resumes from remaining `NULL` rows; the sync seed resumes from its
protected opaque meeting cursor.

Whole-library backup uses one private on-disk SQLite stage instead of retaining
the complete library in Swift memory. The stage copy checkpoints after bounded
GRDB page groups; an arriving protected capture aborts and removes a partial
copy. Once the coherent stage exists, the process-owned use case checkpoints
before each staged aggregate read, after loading one aggregate, after rendering
one document, and after atomic publication. Suspension retains the stage cursor,
filename allocator, completed results, and at most one pending
aggregate/document. Capture completion resumes the same request without
rereading the live database or republishing completed files. The stage is
owner-only and excluded from backup. A newly prepared stage is removed after
completion or ordinary process-local failure; an adopted stage can instead
release its lease without deletion when recovery setup fails so a later launch
can retry it. Each current-format workspace holds a kernel-owned exclusive lease;
creation and cleanup share one root coordination lock, closing the race between
directory creation and owner acquisition. Before process-launch cleanup,
ApplicationKit catalogs every canonical recovery-operation UUID. StorageKit
then preserves those matching workspaces and removes only an unprotected
workspace whose valid owner lease can be acquired, which proves that a crash
released it. A live second Portavoz instance and an unknown legacy or malformed
workspace are preserved fail-closed. Disposable test composition never scans
the host staging root.

After staging admission, ApplicationKit asks a destination-access port to
prepare opaque bookmark identity and acquire one bounded lease. Each execution
interval resolves that identity, uses the resolved directory for inspection
and publication, refreshes stale identity in the active run, and closes the
lease on completion, suspension, or failure. The current non-App-Sandbox macOS
adapter uses a regular Foundation bookmark with
`withoutImplicitSecurityScope`; it follows a moved directory without inventing
a security-scoped entitlement or keeping access open while capture has paused
maintenance. A future sandbox composition can implement the same lease
contract with balanced security-scope acquisition and release.

ApplicationKit assigns the stage UUID to the recovery operation and persists
one versioned, content-minimized publication journal under the app's private
Application Support root. Small metadata retains the regular bookmark and
lifecycle status; one pending record carries the exact filename, meeting
identity, SHA-256, byte count, contiguous sequence, and optional content-free
source cursor. The cursor is present only while durable source advancement
remains safe and is bound to the same meeting identity. A separate immutable
failure sequence carries the exact source cursor, optional matching meeting
identity, a title normalized to at most 4 KiB of UTF-8, and the typed
source/document/publication stage needed to reconstruct a partial result.
Transcript, summary, and rendered Markdown bytes never enter this journal. The app reserves a
filename before the atomic destination move, then moves the pending record atomically into the
immutable completed-record directory. Steady-state journal I/O is O(1) per
meeting rather than repeatedly rewriting a growing manifest. A post-move
journal failure records the published result in process memory before
surfacing failure, then retries the exact pending completion before any next
document, so it cannot republish that document in the same process. Bookmark
refresh, failed-publication reservation clearing, and immutable completion each
update durable state before their in-memory transition advances.

Recovery directories are owner-only and excluded from backup. Launch cataloging
trusts only a canonical lowercase UUID child name, not its shape or content: a
canonical symlink or malformed operation therefore still protects the matching
immutable stage until strict loading rejects the journal. Metadata and
pending files are atomically replaced, completed records are immutable, and
each JSON record is bounded to 1 MiB. Symlinks, malformed/oversized records,
noncontiguous sequences, unknown versions, and filename/operation-ID mismatches
fail closed. Current-format stage
directories must use Portavoz's canonical lowercase UUID name; cleanup returns
the exact UUIDs it proved abandoned, and the app removes only the matching
recovery documents. Active, noncanonical, and unknown work are preserved.

StorageKit exposes the immutable stage's content-free keyset cursor
(`startedAt`, raw staged record identity) and can reopen one exact UUID stage
after the prior process has released its kernel lease. Reopening holds the root
coordination lock through ownership acquisition, rejects active work, opens the
SQLite copy read-only, and requires a supplied cursor to match one exact live
row before continuing after it. The stage root, owner file, and SQLite file
must all be regular non-symlink entries of the expected shape. Missing work is
reported as unavailable; malformed work and cursor mismatches fail closed and
remain untouched.

ApplicationKit maps that position into optional format-versioned recovery metadata
only after the corresponding destination publication has become an immutable
completed record. The recovery adapter rejects a checkpoint while a pending
reservation exists, rejects malformed or regressive positions, and accepts an
equal position as an idempotent retry. If checkpoint persistence fails after
publication completion, the process-owned actor retries only that metadata
mutation before any next source read; it never repeats the destination move.
Source, document, and publication failures become immutable recovery records
before their source cursor advances. A failed record write leaves the row
pending; a failed checkpoint retries only metadata and cannot duplicate the
failure. Later healthy publications therefore keep carrying their exact cursor.
If termination occurs before a publication reservation or failure record exists,
the durable cursor remains behind that row and a future adopted immutable stage
can safely reload and rerender it; rendered Markdown is never journaled.

ApplicationKit also owns a bounded pending-publication reconciliation operation.
It reacquires the stored destination lease, persists refreshed bookmark identity,
and asks the filesystem port for exact evidence about the reserved filename. The
macOS adapter opens the acquired directory without following a symlink, opens
the final component relative to that descriptor with `O_NOFOLLOW` and
`O_NONBLOCK`, requires a regular file with the reserved byte count, and streams
its SHA-256 at utility priority while checking cancellation between bounded
reads. A missing file clears only the reservation so the adopted source can
retry the same row. Matching bytes with a bound cursor promote the reservation
and then checkpoint that cursor. A
conflicting file or any matching reservation without a safe cursor remains
blocked and untouched; cursor-less records include old journals and new
publications created before durable failure outcomes. If publication or failure
evidence persisted but checkpointing did not, the next reconciliation repairs
only the furthest durable outcome cursor; it neither reacquires the destination
nor rehashes, rerenders, or republishes a file.

Completion and source-read failure enter an explicit terminal
state. Terminal retry marks completion when needed, removes the recovery
journal, and only then closes the staged source. It does not reacquire the
destination because no publication capability is needed after terminal work.

`ApplicationKit.RecoverLibraryMarkdownBackup` owns launch continuation. It
catalogs recovery operation IDs before cleanup, preserves every matching stage,
and refuses to choose when more than one operation exists. For one operation it
checks the shared maintenance gate before destination access, reconciles any
pending publication or lagging checkpoint, and adopts only the exact stage UUID
at the exact durable cursor. Active recovered state must have contiguous,
cursor-bound publication and failure evidence, unique destination filenames and
source positions, no pending reservation, a checkpoint equal to the furthest
durable outcome, and no more outcomes than the immutable stage's meeting count.
Completed state additionally requires the outcome count to equal that total.

After validation, the exporter rebuilds the collision allocator from the union
of current destination names and durable completed filenames, reconstructs the
typed exported-name and failure result, and continues strictly after the adopted
cursor. A completed journal reconstructs the final result without reacquiring
the destination, removes the journal, and then deletes the stage. Missing,
malformed, conflicting, cursor-less, multiply cataloged, or unavailable evidence
remains untouched and blocks a second backup rather than guessing. Capture can
suspend launch recovery before reconciliation or adoption; the existing
capture-stop signal retries it. A destination setup failure abandons only the
adopted lease and preserves both journal and immutable source for the next
attempt. If a recovered source terminates fatally after its journal and stage
are removed, the coordinator clears launch ownership; a later maintenance wake
cannot reinterpret the destination URL as permission to start a fresh backup.
None of these paths adds a timer, heartbeat, PID heuristic, or polling task.

Durable ownership follows the smallest recovery boundary that can prove exact
progress. Semantic corpus maintenance uses an independent content-free lease
only for admission, retry, and worker-death recovery; `NULL` vector rows remain
its sole progress cursor. The existing-library sync seed uses an idempotent
database cursor and needs no claimed-worker lease. Whole-library backup owns an
immutable SQLite stage through a kernel lease and journals every safe source
advance.
Post-capture transcription, diarization, and summary are different: each is an
exclusive claimed job whose generated publication must remain owner-fenced, so
the worker renews a durable lease. Intentional suspension explicitly returns an
owned job to pending, clears the lease, refunds that claim attempt, and ends the
current drain invocation so it cannot immediately reclaim pending work; an
expired running lease remains the distinct worker-death path consumed by launch
recovery. A semantic heartbeat protects scheduling ownership but never replaces
the replay-safe vector cursor.

Both paths also borrow one process-owned semantic runtime through an injected
ApplicationKit contract. The exact residency lease covers corpus maintenance,
query embedding, and semantic retrieval as one operation, so Library and Ask
cannot release or replace the model midway through a query. Corpus drains are
owned exclusively by signal-driven durable background maintenance; Ask and
Library only read compatible vectors already published by that owner.

## Durable recording lifecycle

The app persists a meeting shell and pending capture assets before audio
sources start. Capture therefore does not depend on model availability.

```mermaid
stateDiagram-v2
    [*] --> recording: shell and pending assets committed
    recording --> captured: channel files finalized and snapshot installed
    recording --> needsAttention: interrupted or incomplete capture
    needsAttention --> captured: usable audio recovered
    captured --> processing: required durable work admitted
    processing --> ready: required work completed
    processing --> needsAttention: required work exhausted retries
    needsAttention --> processing: explicit retry
    ready --> processing: new refine or generation fingerprint
```

Each channel writes `<channel>.partial.caf`, validates non-empty audio, computes
its checksum and level/health evidence, and performs a same-directory
non-overwriting move to `<channel>.caf`. Stop then installs finalized assets,
provisional live content, and initial durable work atomically. File inspection,
streamed SHA-256, and publication execute on a dedicated serial utility
`DispatchQueue` after every writer handle closes; Stop still awaits that
evidence, but blocking proportional file work cannot occupy Swift's cooperative
executor. One channel's publication failure preserves its staging file and
does not block a healthy peer from publishing.

If the atomic captured snapshot is rejected, ApplicationKit retries that exact
payload once to preserve every released feature after a transient Store
failure. A repeated rejection enters one bounded audio-priority ladder: core
transcript/cast/notes with only provenance-valid Apuntador cards; finalized
audio/notes plus exact durable transcription; then canonical `capture.*`
needs-attention projections. Every rung remains an ordinary StorageKit atomic
request. Generated content is never downgraded into provenance-free content,
and healthy finalized audio is never deleted because an optional projection is
invalid.

System-audio callback liveness is monitored independently from acoustic
silence. Monitoring begins only after the first system frame, then persisted
microphone frames provide a recording heartbeat. Eight seconds without another
system frame emits a content-free health event and requests a best-effort,
in-place `ProcessTapSource` graph rebuild; retries remain bounded to one request
per eight seconds until frames return. Capture, the microphone writer, and the
recording lifecycle never stop for this degradable recovery. A lock-protected
state machine keeps the per-chunk check off the `RecordingSession` actor hot
path, while source recovery remains actor-isolated. The application presents a
non-dismissible warning and an explicit recovered state; callback or stream
health events contain no audio or transcript content. After two uninterrupted
minutes without remote callbacks, Core policy makes Stop prominent in both the
full recording surface and compact HUD because the call may have ended; it
never stops automatically or interrupts microphone capture.

At launch, expired leases are recovered before the application workflow
resumes. It claims supported work serially, renews each lease, recomputes the
input fingerprint before capability work, publishes through owner- and
revision-fenced StorageKit transactions, and derives the next dependency or
terminal lifecycle outcome. Failed required work receives bounded persisted
retry dates; superseded work and exhausted optional summaries are cancelled
without hiding the captured meeting. Intentional workflow cancellation releases
the unexpired owner lease through an explicit StorageKit transition, resets
non-resumable progress, and refunds the claim attempt before returning the job
to pending. The current drain invocation then stops rather than reclaiming the
same or later pending work. Suspension therefore cannot be misclassified as
worker death or exhaust the retry budget; only an actually expired running
lease enters launch recovery.

The private macOS filesystem adapter
revalidates staged/final files and reconciles them with persisted lifecycle
state. Usable audio remains playable and exportable when derived work fails.
A stale `recording` shell that already contains recovered transcript content is
repairable in the same launch pass: recovery marks it with canonical
`capture.publication.failed`, installs only revalidated asset evidence, and
lets StorageKit derive `ready` when the existing content and complete assets
satisfy the aggregate invariant. Recovery never replaces existing transcript
children or depends on a second restart.

## Audio, transcription, and attribution

Microphone and system/process audio remain separate through capture,
transcription, diarization, playback, and refinement. The microphone channel is
structurally the local user; system audio requires speaker attribution.

Meeting capture obeys an observational passivity invariant: production
recording and global dictation never enable AVAudioEngine voice processing,
other-audio ducking, or a system mute/volume mutation. The conferencing app
retains ownership of its microphone processing and playback graph. Raw
microphone spill is handled after capture by transcript bleed filtering rather
than by modifying the live call. `MicrophoneSource` keeps an explicit
voice-processing option only for bounded nonmeeting tools such as local voice
enrollment and the CLI diagnostic flag. Microphone graph preparation is also
fail-closed. The app resolves microphone authorization through `PlatformKit`
before constructing `MicrophoneSource` or touching `AVAudioEngine`; a
user-initiated Start may issue the one-time macOS prompt, while denied or
restricted access returns through the typed preparation failure. Warm-up and
device-restart paths then validate a finite positive hardware sample rate and
at least one input channel before calling `AVAudioEngine.prepare()`, while one
serial queue owns warm-up, start, stop, and device-restart graph mutation.
Input taps never request a cached hardware format: they leave the input bus
unchanged and derive the resampling source rate from each delivered buffer.
This prevents a route transition between format inspection and tap installation
from raising AVFAudio's Objective-C format-mismatch exception. Capture also
awaits its explicit warm-up task before entering that owner. An unavailable
route crosses the existing typed recording-start boundary instead of escaping
as an Objective-C exception.

Audio-route recovery is a graph handoff, not an in-place mutation. An
`AVAudioEngineConfigurationChange` callback only requests delayed work and
returns from AVFAudio's internal queue. A generation gate admits only the
newest request while capture is active, invalidates every pending request at
Stop, retires the old microphone engine, and installs exactly one noncoercing
tap on a fresh engine. The system-output source applies the same admission rule
while one rebuild queue exclusively owns process-tap Start, graph replacement,
recovery, and Stop. Burst input/output notifications therefore cannot install
two microphone taps or let a delayed Core Audio rebuild resurrect a stopped
session; both channels preserve their original stream and pad the bounded
handoff gap.

```mermaid
flowchart LR
    MIC[MicrophoneSource] --> SESSION[RecordingSession actor]
    SYSTEM[ProcessTapSource] --> SESSION
    SESSION --> STAGED[per-channel staged CAF]
    SESSION -. persisted-frame heartbeat .-> HEALTH[System callback liveness]
    HEALTH -. rebuild request .-> SYSTEM
    HEALTH --> NOTICE[Recording health UI]
    STAGED --> FINAL[validated final CAF]
    SESSION -. nonblocking newest-only frames .-> BUFFER[Bounded live feeds]
    RESIDENT[Resident or asynchronously verified Parakeet] --> ATTACH[Live attacher]
    ATTACH --> BUFFER
    BUFFER --> LIVE[Parakeet live transcription]
    FINAL --> DURABLE[Parakeet durable first pass]
    FINAL --> REFINE[Whisper quality refinement]
    SYSTEM --> DIARIZE[Pyannote diarization]
    DIARIZE --> ATTRIBUTE[Speaker attribution]
    LIVE --> ATTRIBUTE
    DURABLE --> ATTRIBUTE
    REFINE --> ATTRIBUTE
```

Live transcription and batch work use separate scheduler capacity. One model
role cannot block another. A recording creates bounded per-channel live feeds
before it starts writing. A resident Parakeet attaches immediately; otherwise
the recording-scoped attacher joins the process-owned verified load and begins
consuming only the newest buffered context when it completes. Capture never
awaits that load and the cold-start session retains its durable transcription
recovery bit because earlier audio was not live-transcribed. Preparing,
available, and failed states cross ApplicationKit without raw model errors.

Intelligence inference also preserves capability ownership. One process-owned
single-flight `IntelligenceScheduler` lane governs Apple Foundation Models on
the ANE, while a second independent lane governs embedded MLX work on the GPU.
Both lanes use the same interactive/live/background priority policy and emit
the same content-free queue/execution telemetry, but they never serialize each
other. Manual and imported MLX summaries default to interactive work; durable
post-capture MLX generation is explicitly background. IntelligenceKit owns
the concrete `MLXSummaryRuntime` actor and container mechanics; AppServices
owns its single process instance, active-use lifecycle, and idle-release
boundary. The runtime remains separate from scheduling policy.

Resource measurement preserves those owners rather than introducing another
queue. Core defines a closed content-free descriptor with five scheduling
classes, eleven resource families, five operations, and three terminal
outcomes. Recording Start and Stop, live and quality transcription,
diarization, intelligence, verified-model preparation/load/release, Spotlight
indexing, private-library sync, waveform generation, Meeting Detail first
projection, media export, and support export emit matched intervals at existing
application or async-task boundaries. The macOS composition root maps only
those enum values and terminal outcome to one generic Points of Interest
interval. It cannot receive meeting IDs, text, file paths, model names, raw
errors, or other content. The established exact Meeting Detail first-content
interval remains in parallel for its benchmark. AudioCaptureKit contains no
resource instrumentation, so capture callbacks never log, lock this telemetry,
or wait for it. Measurement currently changes no admission, queueing,
priority, eviction, residency, or concurrency policy.

Meeting Detail decomposition is also preceded by a frozen presentation
boundary. A generated contract inventories 371 interaction signals across
31 source files,
assigns all 27 detail XCUITest journeys to exactly one of twelve feature owners,
and digest-binds the reviewed performance harness and evidence. Hidden
payload-free scroll and seek signposts activate only when a disposable temp
store, the scale fixture, and the explicit detail-profile flag are present.
The Aug 2026 Xcode 26.6 baseline measures first content at 111.25 ms for 5,000
segments and 197.35 ms for 20,000; five playback seeks have p95 0.52 ms and
five transcript scrolls have p95 331.94 ms. Both profiles record zero app
hitches and zero potential hangs. Xcode emitted no SwiftUI update rows, so
body invalidation counts remain unavailable rather than being reported as
zero. This contract is a refactor-parity guard, not product telemetry or a
performance budget.

The reviewed interaction boundary includes the scene shell and extracted
header, actions, trust, generated-document, transcript, chapter, player,
secondary-rail, and Companion sections. It
preserves every journey, owner, control, sheet, keyboard shortcut, and
performance fixture while adding stable section identifiers. Scene/presentation
changes conservatively select all Meeting Detail journeys; each section and its
pure ApplicationKit projection select only the feature journeys they own.

Meeting Detail reads transcript presentation through one immutable
`MeetingTranscriptContent` snapshot. Stable visible rows retain ordered
source-segment identities plus speaker, channel, spoken language, timing,
confidence, and finality. `ComposeTranscript` can now deterministically replace
text, change a speaker, split, merge, suppress, or restore rows over an explicit
raw or refined base revision without mutating accepted evidence. It rejects
stale, missing, overlapping, branched, nonadjacent, and otherwise invalid
operations before producing anything. Stable final base rows, finite event
ordering, complete split partitions, ordered merges/supersession targets, and
globally unambiguous composed-row identities are enforced at the pure boundary.
Accepted and composed readings share the same snapshot type but carry an
explicit projection even when their rows are identical. `TranscriptReadingPolicy`
keeps direct projection choices constrained to the pure composer. Meeting
Detail is the first explicit product adopter: its application read-model
extension composes only corrections for the observed accepted revision and
falls back to accepted material if the retained history cannot be composed.
Rows and chapters in Meeting Detail derive from the same selected snapshot.
Source-ID routes focus evidence; timestamp routes from Library, Ask, and Spotlight focus
the nearest visible row and retain an exact seek until audio is ready. A start-
time binary search plus maximum-end segment tree keeps
active-row resolution logarithmic while preserving released overlap and gap
semantics. SwiftUI receives only the snapshot and explicit actions; the generic
focused viewport owns its pure live-versus-playback follow policy, never
correction authority.

Schema v19 persists that correction contract as immutable typed events instead
of opaque JSON. `PortavozCore` owns the portable event, payload, canonical
ordering, strict history validation, and transport-neutral format-1 envelope.
`StorageKit` owns normalized parent, ordered-target, scalar-payload, and split-
part tables; one transaction validates the current meeting/revision, accepted
targets, meeting-local speakers, split partition, merge adjacency, linear
supersession, and generated identities before appending all rows. Exact retries
are idempotent after millisecond timestamp canonicalization. Undo appends a
superseding event; tombstoning is the only allowed parent update and exists for
privacy or malformed-event removal. Complete history reads retain tombstones so
removing a terminal event cannot reactivate its predecessor. Target identities
deliberately have no segment foreign key because later Refine replacement or
source retirement must not erase what the correction originally addressed.
Every schema v1-v18 library migrates through the empty additive v19 tables, and
legacy meetings remain valid without synthetic corrections.

Schema v20 adds a separate confirmed-continuity aggregate without promoting
generated tasks. `commitment` stores only `confirmed`, `done`, or `dismissed`
current state; `commitmentSource` records whether the user confirmed an existing
evidence-linked action item, one live note, or a manual entry; ordered evidence
and append-only events preserve the source and every reassign, reschedule,
complete, reopen, or dismiss transition. The title and creation identity plus
all history rows are database-immutable. Current owner and due date are derived
from the event sequence and updated atomically with each appended event. An
existing action item can cross the boundary only when its immutable evidence is
nonempty, current-revision, live, and from the same meeting. A participant owner
is accepted only by exact live `PersonID`; the structural local speaker is
represented independently as `me`, and an absent owner as `unassigned`.
Aliases and display-name similarity never assign continuity state.

`PortavozCore` owns the strict lifecycle and a canonical format-2 continuity
envelope. Its decoder still accepts format 1, which can represent only an exact
person or an unassigned owner. `StorageKit` exports and replays the current
representation idempotently,
requiring exact local source, meeting, evidence, and person identities before
writing anything. It is a transport-neutral backup/sync contract, not yet part
of the per-meeting `.portavoz` bundle, meeting CloudKit replica, CLI, MCP, or
SwiftUI. This keeps generated candidates and the candidate benchmark separate
from confirmed user truth; the visual surface crosses the aggregate boundary
only after explicit evidence review and does not select a candidate engine.

Schema v21 adds only reversible review feedback for generated action-item
sources. `commitmentReviewDecision` is keyed by the immutable `ActionItem` and
stores `dismissed` or future-dated `deferred` treatment plus timestamps and a
tombstone; it never copies generated text, owner, due date, or evidence. One
bounded read reconciles those rows and any confirmed commitment against the
newest live summary. The ApplicationKit confirmation-inbox candidate remains a
transient projection over typed action-item evidence. It can suggest an owner
only through an exact linked `Speaker.personID`, and it suggests no deadline
because no production extractor has passed the quality gate.

Local confirmation and exact portable replay tombstone review feedback in the
same transaction that publishes confirmed continuity. A unique partial source
index prevents one generated action item from backing multiple commitments.
Summary regeneration creates fresh action-item identities and therefore does
not inherit prior feedback.

Schema v22 types commitment ownership as `me`, `person`, or `unassigned` on
both the current projection and assignment events. Existing rows migrate to
`person` only when an exact `PersonID` already exists and otherwise to
`unassigned`; migration never guesses that a legacy nil owner meant the local
user. Database triggers reject mismatched kind/person payloads, and the portable
format-2 envelope preserves explicit self-assignment while retaining format-1
read compatibility.

Meeting Detail renders that reconciliation as an independent evidence-first
section. Presentation receives immutable candidates and sends explicit intents
through `MeetingDetailModel` to `ManageMeetingCommitmentInbox`; SwiftUI never
opens StorageKit or constructs persistence. Confirmation stays disabled unless
the source resolves to current live transcript evidence. The editor may change
wording, explicitly choose the local user, choose an exact canonical person,
leave the owner unassigned, and add a user-entered date; it never infers
ownership or a deadline. Dismiss and defer remain
source-bound review feedback, and each candidate keeps its own evidence seek
before any action. Confirmation still adds no candidate-admission engine,
bundle field, CloudKit transport, CLI, or MCP contract.

The library-global Commitment Radar is a separate bounded read model over only
confirmed continuity. `LoadCommitmentRadar` owns the injected calendar and
clock that define start-of-day, the seven-day due-soon interval, and the
seven-day new-activity interval. StorageKit receives those concrete boundaries
and executes one snapshot-consistent read with an upper bound of four set-based
SELECT statements: roots, oldest source material, newest lifecycle history,
and any exact referenced people. Root pages stop at 200 rows; source and
history material stop at 20 rows per root and carry exact total counts so
truncation is visible. No Radar row hydrates Meeting Detail, invokes a model,
or infers an owner or date.

Owner filters distinguish the local user, exact people, and unassigned work.
Urgency filters include only open confirmed commitments and classify overdue
before the injected day boundary, due soon inside the half-open seven-day
window, or no date. Activity is derived from the latest immutable event:
completed requires `done` plus `complete`, reopened requires `confirmed` plus
`reopen`, and new requires a latest `confirm` inside the injected activity
window. Any current projection that disagrees with its latest event fails the
read instead of publishing misleading activity. Every item carries bounded
source and history rows plus source-meeting navigation metadata; deleted or
dismissed commitments never enter the result.

The focused correction command is the first product adoption of this durability
boundary. It validates the complete retained history, treats text and speaker
attribution as independent lanes that may coexist on one accepted source row,
and appends both changes atomically. Structural corrections remain exclusive.
Returning either lane to its exact original value appends a lane-specific
restore event; it never deletes or rewrites history. The editor exposes immutable
original evidence and correction history, and speaker-only edits preserve the
current text exactly.

The structural correction command extends the same boundary without mutating
accepted evidence. Every request carries the exact accepted projection and
revision observed by Meeting Detail. Split requires two lexical parts and a
strictly interior boundary that partitions the source interval. Merge accepts
only an explicit, ordered, contiguous selection from one meeting, speaker, and
audio channel whose accepted intervals remain time-monotonic; the current UI
deliberately offers pairwise previous/next
candidates rather than inferring a group. Suppress appends a typed event and
removes only the composed row. Hidden-line review retains the exact accepted
text and a durable restore action. Split and merge rows preserve every ordered
source ID, so later playback/export adoption can still resolve original audio.
Generated correction and split-part identities retry only within a bounded
budget and may not reuse accepted rows, correction events, or historical split
parts. A bidirectional source map uses the evidence timestamp to select the
right visible split part while retaining reverse access to all immutable source
IDs.
Restore remains in immutable lineage but is neither a visible edit nor an
active lane owner, allowing a later explicit correction over restored evidence.
Meeting Detail precomputes one immutable structural-editor projection per
accepted/composed snapshot pair, so row rendering performs constant-time
context lookups instead of repeatedly scanning transcript and correction
history while the user scrolls.

Meeting Detail observes correction history and composes current-revision text
and speaker changes. Malformed or stale composition falls back to accepted
material. Correction inserts and tombstones advance the meeting journal exactly
once per logical event. Meeting aggregate format 2 carries the canonically
ordered typed history; replay rejects immutable rewrites and tombstone
regression, replaces v2 history atomically, and preserves local corrections when
a legacy format-1 peer has no correction field. Trigger echoes created while
replaying the aggregate are acknowledged in the same transaction.

Every accepted transcript projection now has one convergent
`TranscriptCorrectionRevision`: the literal `accepted` value when no effective
event is active, otherwise a SHA-256 identity over the meeting, accepted
transcript revision, and canonically ordered effective correction IDs. Local
append/tombstone and private-sync replay compare the revision before and after
their complete transaction. A real change cancels only pending or running
accepted-only summary/index jobs, advances the independent semantic-corpus
source generation once, and leaves transcription and diarization work intact.
The invalidation timestamp is monotonic across the correction event, meeting,
affected jobs, and existing semantic-maintenance source, so delayed sync replay
cannot move maintenance metadata backward.
Late work cannot publish across the boundary: summary and Apuntador generation
runs carry both transcript and correction revisions, and StorageKit admits the
artifact only when both still match the current meeting. Summary cache reuse
also requires a linked run with matching lineage; malformed metadata fails
closed, while legacy metadata is current only for an uncorrected revision-zero
meeting.

Accepted-only retrieval uses one shared SQL predicate. A source row with an
active correction is removed from FTS candidates, semantic reads, embedding
candidates, and vector publication, while unaffected rows remain searchable.
Restore makes the accepted row eligible again and the semantic source-generation
wake lets background maintenance reconsider it. Corrected text is not yet
materialized into either index, so search never presents stale accepted text but
does not claim the corrected row is searchable.

Explicit summary regeneration and review-metadata suggestions consume the
composed transcript. Generated row evidence is projected back to ordered,
immutable accepted segment IDs before persistence. Existing immutable summaries
and Apuntador cards are retained but resolve as stale in Meeting Detail; their
evidence controls are disabled, a stale summary offers an explicit Regenerate
action, and correction changes clear route-local generated chapter/title/recipe
suggestions before recomputation. No correction transaction starts model work
or rewrites an artifact automatically. Automatic Apuntador refresh remains a
separate future adoption.

Every Markdown, PDF, SRT, VTT, CLI, and Gist document now enters one
ApplicationKit correction-aware projection built from the same coherent Library
snapshot. It composes only current-revision history, preserves original audio
intervals and accepted source IDs, omits a summary whose correction lineage is
stale, and fails closed when the snapshot revision disagrees with its history.
Correction provenance is explicit opt-in metadata: Markdown/PDF append a local-
overlay disclosure and stable source map; VTT adds a standards-compatible NOTE
plus visible corrected-cue markers; SRT keeps strict cue grammar and uses only
the visible marker. Meeting Detail owns only a route-local option and forwards
it through typed application effects; CLI exposes the same policy as
`--correction-provenance`. The accepted transcript and audio remain unchanged.

Private sync now treats correction history as convergent user-authored truth
rather than applying the previous blanket local-wins rule. With an unsent local
generation, a format-2 remote aggregate may union disjoint correction lanes only
when its accepted transcript revision and complete segment material match.
Competing lanes preserve both exact payloads and install a protected outgoing
send fence that survives relaunch, explicit retry, and late CloudKit callbacks.
An explicit restore/tombstone can make the histories compatible; replay then
merges them, removes only the obsolete blocked attempt, and publishes the newest
local generation. Remote deletion remains privacy-dominant, legacy format-1
peers remain local-wins, and IntegrationsKit still owns no correction policy.
Only deterministic replica-merge and correction-history validation failures
become the user-visible correction conflict. Unrelated database or storage
failures propagate through the typed storage boundary and roll back instead of
being misclassified as a competing edit.

Correction quality closes at the same pure and transactional boundaries rather
than through UI-only examples. Sixty-four seeded input permutations exercise
text, speaker, split, merge, suppression, restore, refined lineage, and
Spanish/English preservation without changing the composed result. An injected
SQLite abort between event insertion and semantic-source invalidation proves
that correction history, journal generation, accepted-only jobs, FTS
eligibility, and semantic generation roll back together. Private-sync fixtures
prove duplicate blocked delivery is idempotent across relaunch and three
compatible device histories converge independently of merge association.

The test-only Release composition harness owns a synthetic mixed-language
20,000-segment/400-correction fixture. It prebuilds five deterministic input
permutations, emits only host/configuration/count/timing aggregates, and fails
when p95 exceeds 250 ms. The Aug 2026 reference observation records p50
168.85 ms and p95/max 175.20 ms, with 19,867 visible rows. This is a pure
composition budget, not a claim about combined Meeting Detail rendering or a
reason to materialize corrected text in search. Exact and semantic retrieval
remain unchanged because actively corrected accepted rows still fail closed
until a later correction-local indexing decision.

The complete docked playback surface enters SwiftUI through
`MeetingDetailPlayerSection`. The section receives the current application-
prepared playback session, immutable waveform buckets, compression state, and
explicit clip-export and compression actions. It owns no model, service,
storage, audio adapter, or local state. `MeetingPlayerBar` retains only focused
transport/clip interaction and the native save-panel state required to choose a
clip destination; playback preparation, compression, file re-resolution, and
pending seek coordination remain above the section in the route model and
ApplicationKit workflows.

Secondary Meeting Detail flows use the same rule. `MeetingDetailActionSection`
renders Refine, recap, export, Gist, and delete capabilities from immutable
values and explicit intents. `MeetingDetailRailSection` owns the independently
scrolling recovery, privacy, health, chapter, and persisted Companion
presentation without reaching the model or composition root; the coordinator
projects health availability once rather than making the rail rescan every
segment during presentation. One
scene-owned `MeetingDetailFlowState` represents mutually exclusive sheet,
dialog, alert, and file-export routes; route payloads replace the previous
collection of unrelated booleans. Refine drafts and the post-meeting mirror
remain source-derived presentations because their lifetimes are owned by their
dedicated service and recording state rather than by a UI toggle.

The resulting composition keeps `MeetingDetailView` as a compact route
projection and observation-lifecycle surface. A short-lived
`MeetingDetailCoordinator` value translates explicit feature intents into the
route model and scene actions; identity and document workflows live in focused
extensions. The coordinator owns no observable state and is never passed to a
presentation child. The scene retains route mutation and the mirror preference;
the child receives only the corresponding explicit actions and immutable
value. `MeetingDetailFlowHost` presents sheets, dialogs, alerts,
and file export from scene-owned flow routes while receiving platform actions
explicitly. Notes and Refine review have their own immutable values/actions
sections. `MeetingDetailPlaybackNavigation` is the sole view-lifetime owner of
cross-section transcript focus, pending seeks, and disposable seek profiling;
it receives an already prepared playback session and cannot construct audio,
storage, model, or provider capabilities. Architecture tests cap the root at
500 lines and reject model effects or broad composition dependencies in these
presentation children.

Core also owns one pure resource-admission policy, separate from both
measurement and runtime scheduling. Its immutable snapshot contains the
capture lifecycle and source health, categorical hardware memory tier, disk
state, memory pressure, thermal state, resident heavyweight model families
with optional measured footprints, foreground-action presence, durable
backlog, power source, and Low Power Mode. A request adds the existing
content-free workload descriptor plus an admission-versus-checkpoint mode.
The deterministic result contains one disposition—admit, reduce concurrency,
defer for a typed condition, pause at a durable checkpoint, or reject with a
typed recovery action—and a stable list of unrelated idle model families to
evict. Admission and eviction are deliberately orthogonal.

The policy preserves recording-critical work once Start has entered its
protected lifecycle. Before that lifecycle, a failed audio input or critical
disk state rejects Start with an exact recovery action. While capture is
protected, optional post-capture and maintenance work defers or pauses; live
interactive work remains admitted and reduces concurrency under pressure.
Heavy user-requested model work also waits on constrained or pressured capture
hosts. Model release remains admitted because it reduces pressure. Outside
capture, critical storage or severe host pressure defers durable work, pauses
it only at a checkpoint, and gives heavyweight foreground work a typed
recovery; live-interactive work remains admitted with reduced concurrency.
Battery defers maintenance until external power is available; Low Power Mode
has a separate disablement condition so an already plugged-in Mac never waits
for an impossible transition. The policy performs no I/O, model operation,
task creation, scheduling, or eviction. Numeric memory and disk thresholds are
intentionally absent until accepted multi-host evidence exists. Application
composition applies the policy's idle-model eviction output when macOS reports
memory or serious thermal pressure. It also applies one threshold-free
capture-only adapter to semantic-index maintenance: protected capture defers
admission or pauses after a committed batch. Host-pressure, power, storage,
general scheduler, and reduced-concurrency outputs remain inactive until
accepted multi-host evidence defines their adapters.

Core additionally owns a pure model-residency lifecycle ledger. It records the
closed heavyweight families as unloaded, loading, resident, or releasing;
tracks exact active-use counts; carries optional measured footprints; and
projects only genuinely resident runtimes into the governor snapshot. Opaque
load, use, and release generations reject stale asynchronous completions. A
release transition is accepted only for an idle resident family, and a runtime
remains in the resident projection until its owner confirms that release
finished.

The ledger holds no model instance, provider identity, asset path, timer,
scheduler, or platform observer. The macOS composition root owns exactly one
ledger for the process through a lock-protected adapter. Main-actor model
owners and the independent semantic actor therefore share one coherent ledger
without moving synchronization or platform scheduling into Core. Capability
owners still retain their concrete runtimes.
Whisper is the first fully integrated residency family: `AppServices` records
one coalesced quality-speech load, hands Refine and Import a lease containing
that exact engine plus its active-use token, and confirms release only after
the concrete reference has been detached. Publishing a completed load and
claiming its first use are one synchronous MainActor step, so a competing
variant cannot enter between residency and ownership. A load failure returns
only the current generation to unloaded; a rejected release restores the
retained runtime and cancels the release transition.

Refine and Import hold their leases from preparation through the existing
application-owned idle-release hook. They never re-read mutable
`AppServices.whisper` after an asynchronous boundary, so changing the selected
variant cannot replace an in-flight engine and an actively leased variant
cannot be deleted or released. Verified files remain a separate asset
lifecycle, and the existing 120-second idle fence remains unchanged until
accepted residency evidence defines a replacement.

MLX is the second fully integrated residency family. Every manual, imported,
and durable MLX provider receives an injected runtime client instead of
reaching a static cache. AppServices owns one `MLXSummaryRuntime`, coalesces an
exact verified-directory load, publishes that load and its first active-use
token in one MainActor continuation, and holds the token across
`respondPrepared`. The independent GPU scheduler still owns priority and
single-flight inference; residency does not introduce another queue.

On every success, failure, or cancellation the client ends the exact use token
before arming the unchanged 120-second idle fence. Release drops the concrete
container before confirming the matching ledger generation. Settings cannot
remove verified MLX assets while a load or generation is active. The isolated
`--mlx-smoke` runner constructs its own runtime explicitly and keeps
IntelligenceKit's standalone idle policy; it is benchmark evidence, not
production residency.

Parakeet is the third fully integrated residency family. AppServices coalesces
one verified live-speech load and returns a lease that binds the concrete
engine to one active-use token. Recording preparation can claim only an
already-resident runtime; a cold load still begins after durable capture is
active. The recording attacher owns that lease through every live consumer and
ends it after their streams drain. A load that completes after Stop sees the
inactive attachment and ends its lease without delaying Stop or attaching
captions to the closed session.

Dictation, durable post-capture transcription, onboarding readiness, and the
recording resource benchmark also hold explicit leases for their complete
operations. Runtime release remains behind the existing 600-second generation
fence, but the ledger now rejects that release while any live or batch consumer
is active. Verified assets remain independent, and no model wait or residency
transition enters the audio writer callback.

Diarization is the fourth fully integrated residency family. AppServices
coalesces one verified pyannote/WeSpeaker Core ML model-pair load and binds each
consumer to an active-use token. The retained value contains only reusable
weights: every live meeting, durable pass, Refine, Import, enrollment, and
participant-memory operation creates a fresh `PyannoteDiarizer`, so its
stateful speaker database cannot cross an operation boundary. The current
encrypted voiceprint is sampled into that fresh session rather than cached in
the weights; durable post-capture work carries its fingerprinted sample through
execution instead of re-reading mutable identity. Cancellation after shared
loading releases the newly claimed token, and the existing 600-second fence can
detach the model pair only when all sessions have ended.

Semantic embedding is the fifth fully integrated residency family.
`AppSemanticEmbeddingRuntime` is one process-owned actor shared by Library,
Ask, and the app resource benchmarks through an injected ApplicationKit
contract. It coalesces Apple's Latin contextual-model preparation, publishes a
successful load and claims its first borrower atomically, and retains one exact
use token across each indexing or query operation. Library preserves its
no-download-on-typing rule; Ask borrows the runtime only when assets are already
available and never requests a download. The CLI owns a separate process
runtime, while standalone benchmark constructors remain explicitly isolated.

Semantic runtime release is an explicit begin/confirm operation. It is rejected
while a borrower is active, drops only loaded model state, and never removes
the OS-managed assets. No speculative idle TTL is introduced: a governor
adapter may request immediate release, and any delayed policy still
requires accepted per-family evidence. The ledger interprets neither measured
footprint bytes nor elapsed idle time.

Pressure-driven residency release is the first narrow application adapter for
the pure governor. One process-scoped macOS monitor maps
`DispatchSourceMemoryPressure` and `ProcessInfo` thermal notifications to the
closed Core pressure enums, then asks the existing policy for its stable list
of idle families. The adapter carries no meeting, model, path, prompt, or audio
payload. It is disabled for disposable UI stores and isolated resource
benchmarks so their evidence remains deterministic.

Each requested family still releases through its concrete capability owner:
AppServices detaches Parakeet, Whisper, diarization weights, or the MLX
container, while the semantic actor drops its prepared embedding state. Every
owner keeps the existing two-step ledger transition, so a family with an
active lease is never detached. If pressure arrives while a model is busy, the
composition ledger publishes one last-use notification after releasing its
lock; the MainActor adapter then re-evaluates the monitor's current state and
releases the now-idle family if pressure persists. No pressure callback or
ledger observer enters `AudioCaptureKit`, waits on capture, deletes verified
assets, changes an idle TTL, or replaces either existing scheduler.

Capture-exclusive heavy-model admission is the second narrow application
adapter. Recording state is mirrored as one lock-protected, content-free Core
enum so model-residency callbacks can observe capture protection without
reading the observable controller or carrying meeting identity. Entering
starting, active, or stopping capture asks the pure policy to release an idle
Whisper/MLX pair even when macOS has not reported pressure. A final-use
notification repeats that reconciliation if one member was still busy.

The production adapter intentionally supplies `.unknown` memory tier until the
accepted multi-host baseline defines stable hardware classification. During
protected capture, that unknown tier fails closed only for the
quality-speech/language-intelligence pair: loading a second member evicts the
idle peer or defers until capture stops if the peer is loading or has an active
lease. Loading ledger records are projected as non-idle governor occupancy, so
two concurrent cross-family acquisitions cannot both pass before either
runtime becomes resident. If both already had active leases before Start,
capture remains audio-first and releases a member only after its final borrower
finishes. The existing constrained-tier rule remains stricter, while standard
and large tiers retain the pure policy's existing behavior. This categorical
protection invents no RAM threshold and does not activate broader scheduler,
power, or storage admission. Semantic maintenance independently consumes the
same protected-capture mirror through its ApplicationKit checkpoint gate; it
does not change the Whisper/MLX pair rule.

Whisper checks admission before verified preparation, so a blocked Refine or
Import does not start a model download or checksum sweep. After preparation,
Whisper atomically rechecks admission and reserves its loading generation in
one MainActor turn; MLX does the same after any prior-runtime release and
immediately before its load task starts. Both adapters check once more before
generation-fenced residency publication. These three boundaries close
suspension and concurrent acquisition races. A failed publication gate rolls
the loading generation back through the existing owner, and MLX also drops the
prepared container.
Architecture ratchets keep `VerifiedModelLifecycle`, model stores, Whisper,
MLX, and their release owners outside `AudioCaptureKit`; capture callbacks
continue to write audio without model I/O or waits.

Bounded persisted-level presentation is the first bounded live-pipeline
boundary. After a writer accepts one PCM chunk, `RecordingSession` computes its
peak and RMS in the same scan that accumulates final media-health evidence. It
emits a compact `PersistedAudioLevel` with channel, timestamp, and accepted
chunk duration after durable append; optional app presentation never scans that
full sample array again.

Capture duration is conserved as integer PCM frames before it is projected as
seconds. Each channel writer reuses one grow-only `AVAudioPCMBuffer` instead of
allocating per callback, and Stop explicitly closes every native file before
validation rather than waiting for completed task contexts to deinitialize.
The utility publication worker still hashes in 1 MiB blocks, but each
`FileHandle` read and hash update owns a short autorelease pool. Multi-hour
finalization therefore remains streaming in both algorithm and retained heap;
an Objective-C `Data` backing cannot accumulate once per block on the
long-lived queue.

The recording controller submits those compact values synchronously to one
lock-protected latest-value slot. Every value still updates the exact low-mic
and missing-system-audio diagnostic state in O(1). A constant-space
duration-based hysteresis policy also observes sustained system-channel
ceiling exposure. It is stable across route-specific callback sizes and
publishes only a transcript-quality warning; it never applies gain, changes the
call graph, or rewrites captured evidence. At most one MainActor delivery is
scheduled per 50 ms display window. The delivery contains the newest complete
snapshot; cancellation advances a generation and permanently fences late
callbacks from the closed session. This coalescing can discard only obsolete
visual meter states. Durable audio, health events, live-transcription feeds,
and final transcript evidence remain on their existing lossless or explicitly
bounded paths and cannot be backpressured by the meter.

Signal-driven bounded live translation is the second bounded live-pipeline
boundary. One recording-scoped broadcast hub wakes the active Apple
Translation lane only when caption, speaker-attribution, source/target, consent,
or unsupported-passthrough state changes. Each subscriber buffers one wake at
most: a burst means "recompute from the newest controller state," never one
queued unit per caption. Idle and download-gated lanes suspend on that stream
instead of polling the MainActor. Timed sleeps remain only as bounded retry
backoff after a framework preparation or execution error.

Routing still examines at most the newest 60 transcript rows, but each
framework request now admits at most eight chronological rows. Successful
requests drain another bounded batch immediately, so backlog cannot inflate one
framework call and the first translated result can publish sooner. Target and
source changes retain their full pair fence between calls. If translation is
unavailable long enough for a row to leave the live window, that row remains
honestly visible in its spoken language; source captions and durable recording
evidence never enter or depend on the wake path.

Bounded signal-driven live summary is the third bounded live-pipeline
boundary. Closed caption rows, late live-speaker splits, and user-note changes
invalidate one recording-scoped coordinator. The coordinator retains one
pending bit, waits for the established 40-second minimum cadence, and executes
at most one complete map-reduce cycle at a time. Silence creates no permanent
timer loop, and a burst never creates one task per caption.

Each cycle admits the oldest unseen closed rows up to 32 rows and 6,000
characters. One oversized oldest row is admitted alone so the cursor cannot
stall. A successful cycle retains any remaining backlog for a later bounded
pass; a provider failure leaves the cursor untouched and waits for the next
caption or note signal instead of recreating an outage poll. Notes, processed
row identities, and the visible summary publish together only after every
provider step succeeds and the active recording identity, lifecycle state, and
task cancellation fences still match. Reset, next-session, and Stop cancel the
same worker.
Durable captions, audio, final post-capture summaries, and Stop never depend on
this optional live intelligence.

Resource evidence has a separate fail-closed boundary. One tracked contract
requires idle, recording, Stop, Refine, summary, Ask, indexing,
recording-plus-indexing, and recording-plus-batch observations on 8 GB, 16 GB,
and reference-memory Macs. A receipt is exact-shaped and release-build-bound;
it may contain only host/toolchain identity, aggregate process resource
metrics, and summaries of the closed workload enums. Three stable runs are
required for each matrix cell; the existing measurement-stability rule marks
wall or CPU timing with p95/p50 above 1.25 as unstable. The evaluator emits
owner-only JSON and Markdown with nearest-rank p50/p95 and peak/thermal
summaries. Missing, failed, not-observed, under-sampled, or unstable cells
produce a complete blocked scorecard, while malformed, duplicate,
mismatched-build, wrong-memory-tier, non-finite, or payload-bearing evidence
fails validation. A complete matrix proves measurement coverage only: it does
not define budgets or authorize governor policy.

Accelerated long-capture conservation is a separate contract, not a tenth
resource-matrix scenario. `make long-capture-baseline` requires a clean commit,
refuses to replace an existing receipt, builds the CLI in Release, and
revalidates the unchanged commit/worktree before atomically publishing from the
destination filesystem. It drives exactly three logical hours of 16 kHz PCM
through the production dual-channel `RecordingSession`. Its producer admits
one chunk pair and waits for both post-persistence acknowledgements before
admitting the next, so the fixture cannot hide loss behind an unbounded stream.
The exact-shaped, source-commit-bound report requires 172,800,000 accepted and
published frames per channel, healthy CAF evidence, zero frame drift, and no
more than 16 MiB incremental allocator heap. The limit is a duration-invariance
safety fence for this synthetic process, not a hardware memory tier. The
accelerated process intentionally does not use physical footprint as an idle
budget: writing 691 MiB in seconds creates dirty file-page pressure unlike a
real three-hour clock. Real-time 90-minute and call-route runs remain the
authority for physical footprint, thermal, power, and device interference.

The native Release collector covers steady idle, active recording, Stop,
Refine, Summary, Ask, standalone semantic indexing, and both concurrent
recording scenarios without making Instruments XML part of the evidence
contract. The indexing cell prepares
already-installed Apple Latin embedding assets before its measured window,
then drains 1,024 fixed public English segments in four bounded batches inside
a disposable database. Completion requires every segment to carry an embedding
or deliberate micro-segment marker. A benchmark-only observer receives the same
closed telemetry events while
`proc_pid_rusage(RUSAGE_INFO_CURRENT)`, `ProcessInfo`, volume capacity, and
IOKit power-source APIs sample CPU time, peak physical footprint, energy, disk
I/O, minimum free disk, thermal state, low-power mode, and invariant power
source. The Stop probe is armed before the active-recording metric window
freezes and atomically replays spans already open at that boundary, so their
later finishes cannot fall between collectors. Those spans may still drain into
the bounded recording summary while Stop measures them independently from the
boundary. New spans enter only the Stop probe. A power-source
change, malformed lifecycle, timeout, duplicate output, or unavailable native
counter fails the run without producing passing evidence.

`scripts/run-resource-baseline.sh` requires a clean worktree, builds one exact
Release version/build/commit, copies it to a uniquely identified scratch app,
and records at least three runs into owner-only fragments before atomically
publishing a host receipt. User-supplied output roots are normalized to
absolute repository paths before crossing into the GUI benchmark process, so
relative Make overrides cannot escape to that process's read-only working
volume. Each run uses a disposable meeting database, scratch audio,
process-local secret storage, and a unique temporary participant-identity
root. It never reads or writes the host Keychain,
voiceprint, or participant-voice gallery. Production composition continues to
use the Keychain and its durable identity root. Resource scenarios reuse the
normal SHA-256-verified model cache only when their measured operation requires
it. After scenario assets are prepared but before counters start, a
benchmark-only readiness gate requires two consecutive nominal thermal
observations five seconds apart and fails closed after five minutes. This
excludes pressure inherited from an earlier scenario while preserving pressure
created by the measured work itself. A five-second launch-settling interval
also precedes the model-free idle gate, and ordinary XCUITest launches keep
their existing empty temporary model root. Every scenario launches the copied,
signed application bundle through LaunchServices; no SwiftUI/AppKit benchmark
executes the inner Mach-O directly. This keeps application resource policy,
bundle identity, environment inheritance, and TCC behavior aligned across
recording and non-recording evidence.
Once a resource benchmark dispatcher is armed, app initialization returns
before sync, recovery, provider discovery, or dictation registration can start;
the AppKit delegate remains detached from product services. The benchmark owns
the process rather than sharing its measured operation with normal launch
orchestration.
Refine, Summary, Ask, and indexing run in separate cold processes behind the
same bounded first-result timeout. Summary verifies the pinned Qwen3.5 MLX descriptor before
sampling and executes the real ApplicationKit regeneration workflow over a
fixed public English transcript stored only in the disposable database. Ask
requires already-installed Apple Latin embedding assets and available
Foundation Models, then measures the real `AskMeetings.local` workflow over the
same fixed corpus. Before measurement, the benchmark explicitly indexes its
disposable fixture through the shared maintenance coordinator without
downloading assets. The measured window includes deterministic bilingual
expansion, corpus-read-only progressive hybrid retrieval, and generated answer.
It admits a sample
only when both citations and nonempty generated text exist.

Each passing Ask resource run also publishes one separate, exact-shaped
`ask-pipeline-<run>.json` receipt. A benchmark-only observer consumes the
same closed ApplicationKit events as the Points of Interest adapter and records
wall plus process-CPU time for the complete operation, first evidence, first
observable answer token, and every declared Ask stage. The receipt contains no
question, transcript, generated answer, durable identity, path, model name, or
runtime correlation token. It binds measurements to a fixed corpus generation,
SHA-256 corpus checksum, pending-at-seed plus ready-before/ready-after counts,
and validated citation ordinal digest. Native collection rejects duplicate,
foreign, incomplete, failed, post-completion, malformed-digest, or misordered
milestone evidence.

The assembler pairs these sidecars with the exact Ask resource run numbers and
the evaluator reports p50/p95 wall and CPU distributions per milestone and
stage. A passing matrix requires the same corpus and citations within and
across memory profiles; invalid citations, changed result identity, insufficient
samples, or unstable timings block the scorecard. The current contract uses
schema 2 and proves the ten-segment corpus was entirely pending when seeded,
entirely ready before the measured request, and unchanged afterward. Schema-1
cold-backfill receipts remain historical and are not comparable with schema 2.
These reports remain benchmark evidence only; product scheduling and storage
never read them.

A separate adapter-neutral Ask quality boundary owns versioned canonical
tracked public-synthetic corpora with exactly 240 judged queries each: 60 Spanish-to-Spanish,
60 English-to-English, 40 English-to-Spanish, 40 Spanish-to-English, 20
code-switched, and 20 isolated robustness cases. The strict evaluator admits
only complete observations bound to one fixture generation, adapter, build,
and commit. It scores Hit@1, Recall@10, reciprocal rank, nDCG@10, factuality,
citation coverage, answer-versus-abstention policy, hard negatives, unsupported
claims, and canonical meeting/timestamp/revision evidence both overall and per
language relationship. Exact facts must rank first; declared quality floors,
canonical citations, abstention policy, hard-negative exclusion, and zero
unsupported claims all fail closed. Public fixture text stays synthetic; an
optional private fixture may remain anonymized and untracked. Published
scorecards retain only aggregate metrics and source-control identity, never
queries, transcripts, answers, owners, or citation identifiers. This tooling is
not linked into the application and does not choose or configure a retrieval
engine.

The historical `public-synthetic-v1` corpus remains reproducible by checksum.
The current `public-synthetic-v2` corpus preserves the same query distribution
but interleaves relationships into sixty four-segment meetings. Each meeting
contains two exact two-segment same-actor turns, including multilingual turns,
and assigns hard negatives from another meeting. This makes segment and
speaker-turn topology materially different without hiding a hard negative
inside every relevant turn.

The CLI production-observation adapter loads that fixture into a disposable,
owner-only database and executes the real `LocalAskMeetingRetrieval` hybrid
path with deterministic no-expansion control. It never opens the user library.
The current observation schema records one ranked retrieval-unit ID plus every
ordered canonical source segment ID, meeting, first-source timestamp, and
transcript revision. Historical schema-1 single-segment observations remain
readable, while schema 2 lets the same evaluator score segment and
speaker-turn candidates without disguising a chunk as one segment. Invalid,
repeated, unordered, cross-meeting, stale-revision, and hard-negative sources
fail the canonical citation gate. The adapter does not run or judge a
generative answer: it emits explicit `notEvaluated` answer fields, preserving
retrieval metrics while forcing the complete quality gate to remain blocked
until a separately versioned answer judge supplies evidence. Observation
publication is owner-only, atomic, non-overwriting, and remains outside the
application dependency graph. The offline comparator accepts only canonical
fixture-bound scorecards, exact segment-control and speaker-turn adapter roles,
one build and commit, and observation schema 2. Its owner-only, payload-free
receipt reports aggregate and per-relationship retrieval deltas and blocks on
any citation, hard-negative, identity, aggregate, or language-relationship regression.
Candidate parity is quality evidence only; it cannot select product storage,
indexing, or retrieval and does not replace the still-required resource and
correction-cost matrix.

The paired quality runner is the only accepted orchestration path for that
comparison. It requires a clean worktree, derives one full commit identity,
verifies the canonical public fixture, builds the Release CLI once, and runs
the segment control and speaker-turn candidate with OS embedding downloads
disabled. Both blocked source scorecards remain valid because answer evidence
is deliberately unevaluated; the final comparator exit status alone reports
retrieval parity. Artifacts are assembled in an owner-only staging directory
and published as one non-overwriting directory only after every observation,
scorecard, and comparison receipt is complete. Host/model unavailability
removes the staging state and produces no comparable evidence. Direct CLI
experiments may explicitly opt into an OS asset request, but such preparation
is not admitted inside a paired evidence run.

Indexing prepares
the already-installed embedding runtime before sampling, drains 1,024 fixed
public segments through the real ApplicationKit operation, and requires no
missing rows afterward. Recording plus indexing runs in another real windowed
recording process. It prepares the same fixture and embedding assets before
measurement, arms one probe before Start, executes `IndexSemanticCorpus` only
after recording succeeds, and freezes process metrics before Stop. The probe
remains subscribed until Stop closes spans that were active inside the window,
so live-transcription finishes are retained without admitting Stop-only work.
Recording plus batch prepares the same fixed public non-silent audio fixture
and shared Parakeet runtime before measurement, starts utility-priority file
transcription through the production batch scheduler only after recording
succeeds, and keeps capture active until a bounded nonempty result exists.
It then uses the same freeze-before-Stop and fail-closed publication boundary.
The runner never launches or changes `/Applications/Portavoz.app`. All nine
scenarios now have reproducible collectors, but no host receipt is accepted.
The pure categorical policy contract exists; measured thresholds and runtime
enforcement remain blocked.

The live merged projection performs bounded cross-channel admission: a new
microphone row is compared with the newest twelve direct system/room captions,
while a delayed direct row may replace only the newest still-open matching
microphone row. Closed rows remain immutable for translation and rolling-summary
cursors. Single-word acknowledgements and sequential turns remain conservative;
exact two-word copies require real channel overlap, while three-word contiguous
rolling edges can reject a longer noisy microphone copy. Distinct overlapping
speech remains. A separate view-only projector groups consecutive microphone
rows or rows from the same stable live voice within bounded gap/size limits.
It never groups generic `Them`, never mutates raw caption IDs, and projects
translation text alongside the visible paragraph. The projector itself owns a
150-source-row tail; the view does not duplicate this invariant. The
five-minute talk-balance policy similarly evaluates no more than 1,024 closed
candidate rows before its time filter. These are presentation-only bounds:
`RecordingController` retains the complete admitted caption sequence through
Stop and recovery, and translation, generated-evidence, rolling-summary, and
Refine consumers keep their own durable identities and cursors.
Live diarization may still project one closed source row into multiple
speaker-labeled pieces. That transformation preserves the source ID on the
first non-empty piece and assigns fresh IDs only to additional pieces, so
Companion evidence retains a valid lineage anchor and translation caches do not
lose the original turn. The rolling summary tracks admitted caption IDs rather
than an array offset, admitting new split pieces without skipping later speech.
Refine requires Whisper. Loading a verified model first uses the selected
accelerator configuration; a failure triggers one cancellation-aware CPU-only
retry before both underlying causes are surfaced. Attribution is degradable.
Import requests its required transcriber and optional diarizer independently.
Durable first-pass recovery and dictation request Parakeet without acquiring
unrelated models. `ProcessPostCaptureJobs` keeps automatic recognition
unhinted, removes nonlexical microphone fragments and periodic mic bleed,
preserves each segment's detected language, and sets meeting-level language
only when the attributed transcript is homogeneous. Diarization failure
degrades to an unattributed system channel; missing finalized audio remains a
durable failure.

On-demand live intelligence is an ephemeral sidecar, never part of capture or
durable stop. "Catch me up" snapshots only closed caption rows, submits a
bounded recent clip at interactive priority, and owns one replaceable task.
Dismiss and Stop synchronously cancel and clear that task before the recording
crosses the durable application boundary; late model output cannot become
visible or persisted after recording ends.

Live translation treats that transcript as a sequence of language-tagged
turns, not as one meeting-level source language. Persisted segment language is
authoritative; a conservative local recognizer may classify only sufficiently
long, high-confidence unknown text. Closed rows already spoken in the target
language and short or uncertain rows remain unchanged. Eligible rows run
through an explicit source-to-target Apple Translation lane; source
auto-detection is never delegated to the framework, and download consent
belongs to that exact pair. Rows in an unsupported pair stay in their original
language and are recorded as handled passthrough, so they cannot starve later
supported language lanes; presentation retains an honest partial-support state.
A target switch cancels and fences prior work and clears all translated and
unsupported-passthrough state before new lanes are resolved. The newest
still-growing row becomes eligible after enough local language evidence and is
retranslated only after meaningful text growth or a sentence boundary. Each
translation stores the exact source revision that produced it. A
recording-scoped wake relay reacts to caption and lane-state changes without an
idle poll; each Apple request admits no more than eight chronological rows from
the existing 60-row live lookback. Batch responses publish as their
asynchronous sequence arrives, and the UI renders them in a labeled indigo rail
rather than as another spoken transcript row.

`TranscriptContentPolicy` is the channel-neutral minimum boundary: text with no
letter or digit is not speech. Whisper applies it while mapping model output;
ApplicationKit applies it again to both Refine channels before microphone-only
confidence and bleed rules; StorageKit rejects any accepted Refine aggregate
that still contains a nonlexical row. Intelligence formatting independently
filters legacy rows and assigns contiguous evidence tags only to admitted
speech. This defense in depth prevents punctuation-only rows from becoming UI
noise, search material, generated facts, or navigable evidence without using a
language-specific word list.

Transcript recognition language and generated-output language are independent.
Automatic durable transcription and Refine never pin a complete channel to an
aggregate meeting language, even when existing metadata appears homogeneous;
WhisperKit language detection is explicitly enabled because a nil language
alone would keep prefill's English fallback. The decoder stays in transcription
mode, and each segment retains the language recognized for its VAD result.
Fixed transcript language is an explicit per-meeting recovery choice.
Meeting-level language is derived only after attribution when the completed
transcript is homogeneous. Summary language either follows homogeneous speech
or uses an explicit English/Spanish setting, with app locale as the fallback
for mixed or unknown speech.

Standalone terminal analysis follows the same boundary: ApplicationKit admits
the input file and owns operation order, elapsed-time policy, speaker identity,
optional attribution, summary persistence, and progress values. CLI adapters
construct the pinned local engines. Download callbacks are serialized and
drained before workflow completion so terminal progress cannot arrive after a
success result.

## Generated intelligence and evidence

Generated success is one atomic fact: an immutable output and its successful
generation record commit together. Provenance stores provider/model identity,
operation fingerprint, configuration, language, timing, outcome, and aggregate
metrics without meeting text.

Summary and Apuntador sources are typed rather than inferred from rendered
text:

- overview evidence points to ordered transcript segments;
- decision evidence uses canonical section and bullet coordinates;
- action-item evidence follows durable task identity;
- Apuntador evidence separates the triggering question from answer support;
- answer sources exist only for exact local-retrieval citations;
- feedback remains a separate reversible human assessment and never rewrites
  generated Markdown.

Every evidence write validates current transcript revision and live
same-meeting sources. Missing, stale, deleted, ambiguous, or partially resolved
evidence fails closed and disables navigation. Portable bundles remap every
identity explicitly.

Provider-authored tags establish source identity but not semantic support.
Before a generated draft can reach persistence, IntelligenceKit retains each
overview, decision, or action citation only when the rendered statement and
cited transcript row share distinctive case/diacritic-folded lexical material;
unsupported and cross-language-unverifiable links disappear while the summary
text remains usable. The same admission stage removes empty/duplicate tasks
and compares the attribution-independent claim body of every action against
the recipe's explicitly typed decision section. A decision rendered as
`S2: "Use X"` is therefore still the same statement as an action rendered as
`"Use X" — S2`. Provider prompts require concrete future commitments or
assigned next steps and allow an empty task set. An action owner is admitted
only when it uniquely matches an existing speaker label or confirmed display
name. A unique exact label takes precedence; display-name matches are admitted
only when unique. Drafting carries the resolved `SpeakerID` beside the
canonical rendered owner instead of resolving that text a second time, and
removes any duplicated leading owner prefix. Unknown or ambiguous generated
names become unassigned rather than visible identity claims.
Translation pivots carry only evidence and tasks that already passed this
source-language gate.

Commitment candidate extraction has a benchmark authority, while durable
continuity is a separate confirmed-only aggregate. A canonical 48-case
public-synthetic fixture balances English,
Spanish, and mixed speech and explicitly separates commitments from
suggestions, hypotheticals, status reports, and questions. The fixture starts
from the existing generated `ActionItem` observation, but a candidate is
admitted for scoring only when its evidence IDs refer directly to both that
action item and its transcript turns. Unsupported model output therefore
fails closed rather than becoming a commitment. One adapter-neutral runner
scores a transparent deterministic research control and explicitly local
OpenAI-compatible models against the same fixture, including candidate
precision/recall/F1, false-positive rate, exact evidence, and exact/false-
positive owner and deadline metrics. Comparison reports deltas only; it cannot
choose an engine or make a product decision. Per-case observations are optional
owner-only local artifacts, while tracked evidence is aggregate public-fixture
research. The benchmark still chooses no engine and cannot write confirmed
continuity. The confirmation inbox derives a transient, newest-summary
projection from already generated action items and stores only source-bound
dismiss/defer feedback until an explicit user confirmation enters the separate
confirmed aggregate. It is not a candidate-admission engine. The shipped
Meeting Detail surface requires current evidence, offers exact source seek and
an editable confirmation sheet, suggests only an already linked canonical
person, and produces no deadline suggestion. The bounded Radar reads only that
confirmed aggregate and adds no deadline extractor or automatic commitment
promotion.

Meeting-derived text is untrusted input at every model boundary. Summary,
map-note, finished-summary translation, speaker naming, chapter title,
pre-meeting brief, meeting-type detection, retrieval answer, and meeting-title
instructions all include the same quoted-source guard: participant speech,
retrieved passages, and generated meeting material can be reported or
transformed but cannot redefine the model's role, output shape, or governing
instructions. Live Apuntador applies the equivalent rule to its classifier and
knowledge paths. Trusted user questions remain separate from untrusted
retrieved passages, and deterministic admission still validates generated
identity, evidence, and display output after generation.

## Search, playback, and derived indexes

Local lexical search uses FTS5 and query-specific bounded reads. One
ApplicationKit Ask workflow serves full Ask, the command palette, CLI, MCP, and
meeting-brief retrieval. Its local adapter combines bounded per-term lexical
candidates, deterministic bilingual expansion, exact semantic ranking, and
reciprocal-rank fusion. Lexical and semantic candidates execute concurrently;
the workflow publishes lexical evidence before fusion and fences final
citations before optional generation. Foundation Models expansion is bounded
and used only after both deterministic paths return no citation. Ordinary model
failure preserves exact citations, while caller cancellation propagates.
Embeddings are device-local derivation and do not mark a meeting for sync.

One ApplicationKit trace spans each Ask search, evidence, or answer operation.
The closed stage vocabulary covers corpus readiness, query expansion, lexical
retrieval, query embedding, semantic scan, rank fusion, and citation materialization;
separate milestones identify first evidence, the first answer token observable
by the application, and terminal outcome. Concurrent lexical and semantic
stages have a partial order: expansion begins first, first evidence follows
lexical completion, and fusion begins only after both candidate paths settle.
The trace admits only operation,
stage, milestone, outcome, and random process-local correlation values. The
macOS adapter converts them into Points of Interest intervals without logging a
question, meeting, citation, path, model, or error. The current answer provider
returns one complete string, so first-token observation currently coincides
with that string crossing the ApplicationKit boundary. CLI distribution and
quality aggregation remain separate benchmark work; this trace changes no
storage persistence or model preparation. The late evidence-empty generative
fallback contributes to total operation duration but does not create a second
primary expansion interval; a dedicated stage requires a versioned receipt.

Meeting Detail
seeks exact transcript evidence only after its audio player is ready; early
source selections remain queued until waveform preparation completes. Ask and
command-palette citation seeks are meeting-scoped, identity-bearing navigation
requests: only the matching detail consumes them, and an already-open detail
observes a new request without depending on route reconstruction.

The instant Library path is an exact-first hybrid distinct from Ask. Its FTS
observation always publishes before optional semantic augmentation. It reuses
the same device-local Apple embedding representation and the injected
ApplicationKit semantic-index query port, skips semantic work during capture,
refuses asset downloads as a
side-effect of typing, and treats cancellation or embedding failure as an empty
augmentation.

Ask and Library no longer call StorageKit's cosine scan directly. Both receive
the same read-only `SemanticIndexSearching` port after readiness and query-vector
creation. Its shipped `AccelerateExactSemanticIndex` adapter delegates to the
unchanged SQLite-streamed, bounded Accelerate top-k implementation and returns
current `SearchHit` projections with segment identity and transcript revision.
The default composition remains exact control, so ranking, fusion, corpus
maintenance, storage schema, asset policy, and UI behavior are unchanged. This
is the Strangler seam for later shadow candidates; it does not authorize a
second product writer, serve candidate results, or select another engine.

The first shadow boundary is also implemented without changing composition.
`ShadowComparingSemanticIndex` obtains the authoritative exact result first,
launches one explicitly injected research candidate without awaiting it, and
always returns the control result. Its telemetry reduces current citation
identity to aggregate count, overlap, same-rank, top-hit, outcome, dimension,
limit, and duration fields before emission. The closed adapter vocabulary and
event schema cannot carry queries, vectors, meeting or segment identifiers,
titles, transcript text, model names, paths, or raw errors. Construction
requires an explicit telemetry receiver and executor; there is no inert
accidental mode. Candidate failures and cancellation are observations only; a
control failure schedules no shadow work. Every research implementation must
conform to `SemanticIndexShadowCandidateSearching`; its closed adapter identity
travels with the implementation and is the only identity emitted for its work.
The wrapper accepts no independent call-site label that could misattribute
comparison evidence. Benchmark composition may route the explicit executor
through `SemanticIndexShadowCoordinator`. The actor asks the existing durable
maintenance gate for `.maintenance` / `.searchIndex` / `.execute` admission,
allows one candidate flight without a backlog, records policy, busy, and
capture skips as closed payload-free outcomes, and cooperatively cancels the
active candidate when capture starts. Resume waits for that cancelled flight
to finish before allowing another candidate. Neither Ask nor Library composes
this wrapper or coordinator. Research engines enter through
`SemanticIndexShadowRanking` and return only bounded, ordered segment/revision
identities. `ProjectedSemanticIndexShadowCandidate` resolves those ranks back
through `MeetingStore`, which drops duplicate, missing, deleted, negative-
revision, and stale evidence before producing current `SearchHit` values. A
derived index can therefore rank but cannot author citation text or bypass the
authoritative transcript-revision fence. No product ranker, schema, index
writer, app wiring, or production scheduler exists yet. The first research
engine is sqlite-vec v0.1.9 exact full-scan.
`scripts/vendor-sqlite-vec.sh` pins the official amalgamation archive by
SHA-256 and stages only static C/header material plus the separately reviewed,
checksum-pinned upstream MIT text; dynamic SQLite extension loading is
forbidden. `Vendor/sqlite-vec` now retains the byte-identical tagged C blob, a
deterministically rendered tagged header, license, and provenance.
`CSQLiteVecResearch` textually compiles that amalgamation with
`SQLITE_CORE`, `SQLITE_VEC_STATIC`, and `SQLITE_VEC_OMIT_FS`.
`SQLiteVecResearchKit` owns `SQLiteVecExactShadowRanker`, a disposable actor
over one in-memory `vec0` index. Construction accepts one valid embedding
profile, unique current-source identities, finite fixed-dimension vectors, and
no text. Queries require that same profile and dimension, use cosine distance,
and run an exact scalar `vec_distance_cosine` scan ordered by distance then
source row. The deterministic secondary order avoids sqlite-vec's 4,096-result
KNN window while preserving bounded top-k output at larger corpus sizes.
Cancellation is checked before and after the native call and signalled through
a native token plus SQLite progress handler.

The ranker depends only on the native research target, `PortavozCore`, and
`StorageKit`; it does not depend back on `ApplicationKit`. A test-owned
`SemanticIndexShadowRanking` adapter exposes its ordered segment/revision
identities to the research seam. A characterization composes that adapter through
`ProjectedSemanticIndexShadowCandidate` and `ShadowComparingSemanticIndex`,
proving that current StorageKit evidence remains citation authority and only
aggregate agreement crosses the shadow boundary. Both research targets are
reachable only from `PortavozTests`; neither app, CLI, nor `ApplicationKit`
depends on them. The native query remains an exact full scan and returns only
the bounded deterministic top-k, so no resource result is accepted yet. There
is still no product schema, writer, app composition, durable receipt, or
user-visible authority. ANN sqlite-vec
prereleases and USearch remain later comparison candidates rather than hidden
variables in the first exact-parity experiment.

The first exact-path scale harness is likewise test-owned. It creates one
`synthetic-exact-path-v1` corpus and sends the same normalized vectors and
top-k queries through the real scratch-`MeetingStore`
`AccelerateExactSemanticIndex` control and the disposable sqlite-vec ranker.
The fixed canonical profile is 512 dimensions, eight queries, top 10, and
1k/10k/50k/100k corpus sizes. Fixture preparation, authoritative control-store
construction, candidate-index construction, and query wall time are measured
separately. Control-store build cost includes source-row, FTS, and embedding
publication work, whereas candidate build cost begins from already available
vectors; those build figures describe different lifecycle boundaries and are
not a direct engine-speed comparison. Query order alternates under
`alternating-query-order-v1` to reduce cache-order bias.

`scripts/run-exact-path-shadow-benchmark.sh` launches one fresh Release XCTest
process per selected scale. Its schema-1 stdout observation contains only
host/configuration, byte/count, timing-distribution, and aggregate agreement
fields. The schema cannot carry query vectors, source identities, transcript
text, model identity, database paths, or raw errors, and the runner has no
durable-output option. The harness therefore establishes reproducible
development measurement only: it accepts no baseline, selects no engine, adds
no product schema or composition, and leaves Accelerate exact as the sole
product authority.

Host acceptance is a separate tooling-only boundary. The tracked
`exact-path-shadow-matrix.json` contract requires one Release build, the fixed
fixture and measurement policies, five runs per query, three observations at
each canonical scale, Apple Silicon, supported Sequoia/Tahoe majors, and one
of the existing 8 GB, 16 GB, or reference-memory profiles.
`exact_path_matrix.py` rejects duplicate JSON keys, extra fields, non-finite or
inconsistent measurements, mixed hosts, noncanonical engine order, incomplete
result counts, and copied observations. Valid but missing, unstable, or
top-hit/top-k-set-divergent evidence produces a complete blocked scorecard
rather than a passing receipt. Lower-rank ordering agreement remains visible
but does not invalidate an otherwise identical top-k set; graded MRR/nDCG
quality remains a separate corpus gate. Timing stability reuses nearest-rank
p95/p50 no greater than 1.25 both inside each query observation and across
repeated fixture, build, and query measurements.

`scripts/run-exact-path-shadow-matrix.sh` admits only a clean committed
checkout, runs three complete matrices through ephemeral owner-only files,
binds the aggregate to the unchanged commit and Swift toolchain, and emits one
`exact-path-shadow-host-receipt` to stdout. The receipt contains host identity,
closed configuration, aggregate byte/count/timing distributions, agreement,
and per-scale pass/block state only. It neither stores raw observations nor
compares the unlike control/candidate build lifecycles. One receipt proves one
host matrix; cross-host acceptance and engine authority remain separate.

Host receipts use schema 2 so a later consumer can validate their aggregate
state without raw observations. Each engine row retains the maximum
within-observation p95/p50 query ratio; `null` means an unbounded zero-median
ratio and therefore an unstable row. `validate_host_receipt` independently
checks exact scalar types, timestamp and source identity, host/profile fit,
canonical scale order, aggregate distribution counts and monotonicity, result
agreement, the internal-ratio lower bound implied by the aggregate timing
distributions, timing stability, scale state, and final outcome. A zero control
query denominator is never reported as equal candidate performance in the
cross-host scorecard; that scale is explicitly not comparable.

Cross-host acceptance is another tooling-only boundary. The tracked
`exact-path-cross-host-matrix.json` contract requires exactly one valid host
receipt for each 8 GB, 16 GB, and reference-memory profile, with Sequoia and
Tahoe each represented at least once. `exact_path_cross_host.py` rejects
malformed, payload-bearing, duplicate, or repeated-profile receipts and emits
one `exact-path-shadow-cross-host-scorecard` to stdout. Missing profile or OS
coverage, a blocked host receipt, or different source commits or Swift
toolchains produces a complete blocked scorecard rather than comparable
evidence.

Passing profile rows expose only closed host/configuration data, per-engine
query p50/p95, candidate-to-control query ratios, build p50 values kept as
separate lifecycle observations, byte counts, and exact-rank agreement. The
versioned comparison policy normalizes candidate query timing against the
control on the same host; a zero control denominator is `not-comparable`, never
invented as equal performance. The scorecard accepts no output destination and
sets no cross-host performance threshold, engine verdict, product schema,
writer, app composition, or user-visible authority.

Durable research evidence crosses a separate maintainer-only admission
boundary. The tracked `exact-path-baseline-admission.json` contract accepts
only the canonical stdout file for one passing cross-host scorecard and the
three aggregate host receipts from which that scorecard recomputes exactly.
The maintainer must supply both the scorecard file's lowercase SHA-256 and its
single source commit. The active checkout must be clean at that commit before
validation, immediately before publication, and immediately after publication;
a final mismatch withdraws the new file.

`exact_path_baseline.py` revalidates every receipt and scorecard predicate,
canonicalizes receipts into profile order, and publishes one owner-only file
of kind `exact-path-shadow-cross-host-research-baseline` atomically without
replacing an existing path. Repository-local destinations must already be
ignored. The retained envelope binds the scorecard file digest,
canonical receipt-set digest, source commit, active review policy, and complete
aggregate evidence. Its fixed authority is `research-comparison-only` and its
engine decision is `not-evaluated`. Digest/source acknowledgement identifies
the exact artifact the maintainer accepted; it is not reviewer authentication,
a quality verdict, a numeric budget, or permission to change serving behavior.
Accelerate exact remains the only serving adapter.

Correction-cost measurement is also isolated from product composition. The
test-only `SQLiteVecExactShadowRanker` now accepts atomic add, update, and
delete batches under its fixed embedding profile. Existing identities retain
their original deterministic tie slot, deleted slots are not reused, and new
identities append. The native wrapper validates the entire batch before one
`BEGIN IMMEDIATE` transaction; failure rolls back both the `vec0` table and the
Swift actor's identity map. No mutation API is exposed by a shipping target.

`ExactPathMutationBenchmarkTests` drives a
`synthetic-exact-path-mutation-v1` corpus through the real scratch-store
`AccelerateExactSemanticIndex` and the disposable sqlite-vec ranker. It measures
add, update, and delete batches of 1, 10, and 100 over the canonical
1k/10k/50k/100k exact corpora, alternates engine order under
`alternating-mutation-engine-order-v1`, verifies top-hit and top-k-set agreement
after every mutation, and labels one complete reconstruction for each engine.
The control reconstruction includes authoritative rows, FTS, and embedding
publication; the candidate reconstruction begins with prepared vectors, so
those values remain separate lifecycle observations rather than a direct speed
ratio. Mutation timing is labelled with the same boundary: control add/update/
delete includes authoritative source and embedding publication, while the
candidate receives prepared vectors. Cross-engine timing ratios are therefore
not valid; only within-engine, same-scale stability is directly comparable.

`scripts/run-exact-path-mutation-benchmark.sh` starts one fresh Release XCTest
process per scale and emits one schema-1 observation to stdout. The report
contains only closed operation names, host/configuration, counts, bytes,
timings, and aggregate agreement. It cannot carry source identities, vectors,
transcript text, model identity, database paths, or raw errors and accepts no
output destination. This is development evidence only: resource acceptance,
interruption/recovery, a cross-host mutation receipt, and engine selection
remain later SEARCH-5 boundaries.

The next evidence boundary is deliberately threshold-free. The versioned
`exact-path-mutation-matrix.json` contract requires three complete mutation
benchmark observations at every canonical scale from one clean Release checkout
and one declared 8 GB, 16 GB, or reference host on supported Sequoia/Tahoe. The
`exact_path_mutation_matrix.py` validator rejects unknown fields, duplicate
JSON keys or observations, mixed hosts, invalid lifecycle labels, incomplete
batch/engine order, non-finite or non-monotonic distributions, and malformed
agreement counts. Complete top-hit and top-k-set parity produces the explicit
`review-required` outcome under
`human-threshold-free-mutation-review-v1`; missing coverage or rank-set drift
produces a complete `blocked` receipt. Timing variability never becomes an
automatic pass or block in this contract. Instead, rebuild and each operation/
batch retain nearest-rank observation distributions plus within-observation
p95/p50 diagnostics for later human resource review.

`scripts/run-exact-path-mutation-host-matrix.sh` collects the three matrices,
binds the receipt to the unchanged source commit, Apple Swift toolchain, host
profile, OS, and unlike control/candidate lifecycle labels, then emits only the
schema-1 aggregate receipt to stdout. It accepts no output destination and
deletes raw observations. No real receipt has been collected, reviewed, or
retained; `review-required` is evidence completeness, not a performance
threshold, accepted baseline, engine verdict, or product authority.

The cross-host mutation boundary is also a review protocol, not a benchmark
verdict. `exact-path-mutation-cross-host-matrix.json` requires exactly one
revalidated one-host mutation receipt for the 8 GB, 16 GB, and reference
profiles, coverage of both supported OS majors, and one source commit plus
Apple Swift toolchain.
`exact_path_mutation_cross_host.py` rejects duplicate keys, repeated receipts
or profiles, tampered nested host evidence, unsupported contract identity, and
non-canonical scorecards. It detaches the derived document from its inputs and
can recompute every nested value from the three receipts. Missing coverage,
blocked host evidence, or source/toolchain divergence produces a complete
`blocked` scorecard; a complete comparable matrix remains `review-required`
under `human-threshold-free-mutation-cross-host-review-v1`.

The scorecard preserves per-host aggregate rebuild and mutation timing
distributions for human review but derives no candidate/control ratio,
performance threshold, or automatic pass. The CLI reads aggregate JSONL and
emits only the recomputable scorecard to stdout. No real cross-host mutation
scorecard has been collected or retained, and this boundary grants no product
schema, adapter selection, migration, or rollback authority.

Private retention adds an explicit maintainer-review boundary without changing
that scorecard outcome. The
`explicit-human-review-digest-and-source-v1` contract in
`exact-path-mutation-baseline-admission.json` requires
the exact canonical scorecard file, its three revalidated receipts, the file's
lowercase SHA-256, the sole source commit, and the fixed human acknowledgement
`timings-reviewed-no-engine-decision-v1`. A blocked scorecard cannot be
retained, while complete evidence must still say `review-required`; admission
does not rewrite it as a performance pass.

`exact_path_mutation_baseline.py` recomputes the scorecard from receipts in
canonical profile order, binds both evidence digests, and publishes one
`exact-path-mutation-cross-host-research-baseline` through the shared
`private_research_baseline.py` boundary. The checkout must be clean at the
accepted commit before reading, before publication, and after publication.
Publication is owner-only, atomic, non-overwriting, bounded, and allowed inside
the repository only at an already ignored destination; a final checkout change
withdraws the new file. Its permanent authority is
`research-correction-cost-only`; engine and performance decisions both remain
`not-evaluated`. It stores no reviewer identity or free-form note, and no real
mutation baseline is tracked or accepted yet.

App composition owns one signal-driven semantic-maintenance supervisor over
the shared corpus-indexing coordinator. App launch, searchable mutations, and
capture returning inactive are wake signals. Bursts collapse to at most one
rerun behind the active drain; no polling loop or in-memory work queue exists.
One cancellable future wake may represent a durable retry or predecessor lease
expiration. Before borrowing the semantic runtime, the background adapter
checks capture state, whether the live corpus has any searchable row, installed
Apple embedding assets, a valid active profile, and whether any row lacks that
exact profile. It never downloads assets in the background. Temporary and
isolated benchmark stores disable the supervisor.

The `NULL` embedding rows remain the durable cursor across suspension, failure,
and process termination. A later signal, scheduled retry, or lease-expiry wake
therefore resumes work without a second progress cursor. Ask and Library are
corpus-read-only: both publish exact FTS first and may augment it only with
vectors already committed by background maintenance.

Every selected semantic row carries its segment ID, meeting ID, transcript
revision, and exact source text through embedding. StorageKit accepts the
result only when the same live row is still unembedded, its meeting remains
live at that revision, and its text is unchanged. A concurrent correction,
replacement, deletion, or duplicate publication is therefore a content-free
skip; it cannot attach a stale vector to a reused identity, and the current
live row remains on the `NULL` cursor for a later pass.

Every persisted semantic vector also carries one SHA-256 compatibility
fingerprint derived from the concrete model identifier and revision, vector
dimension, Portavoz pooling-pipeline identifier and revision, and binary
vector-schema version. Semantic reads require the exact active fingerprint.
Maintenance atomically resets incompatible derived vectors to `NULL` before
rebuilding them, while transcript text and FTS rows remain untouched. Schema
v17 performs that same fail-closed reset for legacy vectors whose compatibility
cannot be proven.

ApplicationKit also owns a storage-independent `RetrievalChunk` derivation
contract for evaluating speaker-turn retrieval without changing the live
index. The deterministic `speaker-turn-v1` chunker groups only adjacent rows
that resolve to the same confirmed person, the same observed speaker, or the
local microphone. Unattributed system and room rows remain isolated; different
actors are never merged to satisfy a length target. Every chunk retains its
ordered segment identities, timestamps, meeting-local speaker and confirmed
person identities, channel, and per-source spoken language. Its stable ID is
derived from meeting, chunker version, and source membership, while a separate
source fingerprint detects per-source text, attribution, language, or timing
changes.
The meeting transcript revision remains a publication fence but does not force
unrelated chunks to rebuild. This is a pure candidate boundary only: schema
v18, segment-level embeddings, FTS, Library, and Ask remain unchanged until a
versioned quality and resource comparison proves a replacement.
The CLI quality adapter may project either canonical segments or these
speaker-turn chunks into its disposable database. Both candidates run through
the same production retrieval implementation, but every ranked unit is mapped
back to its complete ordered source membership in observation schema 2. The
benchmark projection does not create product storage, maintenance, or query
lanes and cannot select the product default by itself.
The current public corpus exercises two real same-actor turns per meeting, and
the paired comparator requires the candidate to match or improve every overall
and relationship retrieval metric while retaining canonical source evidence.
Historical fixture generations remain verifiable rather than being rewritten
when corpus topology evolves.

Semantic maintenance does not publish `.index` work into the owner-leased
processing ledger. That ledger continues to control the visible meeting
lifecycle, while degradable derived-index failure remains outside
`needsAttention`; the exact `NULL` embedding rows are its only replay cursor.

Waveform generation is stateless and uses Accelerate over range-aligned channel
spans. The application publishes one bounded snapshot, while route cancellation
stops obsolete whole-file derivation between fixed-size reads; no waveform
cache, partial result, or media mutation is introduced. Playback supports
synchronized channels, silence skipping, local-voice filtering, clips, AAC
compression, and a reversible clear mix. When both direct
system and microphone tracks exist, the direct system track remains unchanged
while microphone audio is admitted only around transcript-confirmed local
turns with short boundary ramps. Mic-only recordings never receive that mix,
and the original flat mix remains one click away. Meeting Detail receives only
the application-owned playback facade and capability-neutral waveform values.
Compression verifies every generated channel before removing raw inputs,
refuses to overwrite an existing canonical AAC file, and reports live
post-publication disk savings. Clip export resolves the current channel set for
each request and applies the currently selected clear/original mix, so a
completed compression cannot leave stale URLs behind.

Spotlight indexing is a process-scoped, protected, coalescing reconciler. It
compares compact client state, publishes bounded batches to a named index,
retries transient failures, and repairs missed work at launch without exposing
meeting content to logs. Removal of the obsolete default-index domain retries
until successful, then records a versioned local migration marker so neither
later reconciliations nor future app launches wake Core Spotlight for the same
one-way cleanup.

## Open-format export and backup

Canonical Markdown, PDF, and diarized SRT/WebVTT rendering live in
`IntegrationsKit`. Subtitle cues use millisecond-accurate format-specific
timestamps, normalize line-oriented fields, neutralize timestamp arrows, keep
same-name speakers separate by `SpeakerID`, and merge consecutive rows only
within the rendered six-second/84-character budget. Meeting bundles carry a
versioned relational aggregate with canonical identity remapping and optional
audio. Machine-local paths, canonical-person links, voiceprints, secrets,
embeddings, and transport state are not portable.

Single-meeting rendering and explicit publication enter ApplicationKit. The
macOS detail workflow loads one coherent detail projection, renders through an
injected document port, and returns Markdown, PDF, SRT, or WebVTT bytes plus
the released title-based suggested filename for the native save surface.
Subtitle rendering reads the diarized transcript directly and cannot fail
because of unrelated Markdown preparation. Secret-Gist publication and
terminal export use the same coherent projection and canonical renderer;
terminal export may return Markdown, write Markdown/PDF/SRT/WebVTT through an
injected filesystem port, or invoke an explicit publisher. Pending action-item publication
similarly reads one current detail and summary, resolves owners from that
snapshot, and publishes only unfinished items in stable order. Remote paths
complete local admission and no-op checks before the publisher prepares its
credential; only a prepared destination emits presentation progress and
proceeds to transport. Missing meetings and empty pending-item sets therefore
do not touch Keychain or announce egress.

Whole-library Markdown backup is coordinated by the
`ApplicationKit.ExportLibraryMarkdownBackup` actor. StorageKit creates one
read-consistent transient SQLite stage through bounded GRDB backup pages. The
stage session then loads one healthy live meeting, cast, ordered transcript,
and latest General summary at a time in newest-first order. Corrupt required
aggregates become typed per-meeting failures while healthy meetings continue;
corrupt optional summaries degrade to absent.

After the user chooses a destination, the expensive process-owned backup is a
maintenance/media-export workload. A protected recording returns an explicit
suspension before or during bounded stage creation, before the next staged
aggregate read, after one aggregate load or render, or after publication.
`LibraryMarkdownBackupModel` keeps the request in its preparing state and
resumes it from the capture-stop signal. The destination is never rerequested,
suspension is not reported as failure, and a stop signal racing with admission
is remembered rather than lost. The use-case actor retains the immutable stage,
cursor, collision allocator, completed results, and at most one pending
aggregate or rendered document; atomic publication is the commit point, so
resume never duplicates a completed file.

The selected destination becomes opaque bookmark identity only after source
staging and the final admission checkpoint. The actor acquires a fresh
destination lease for each execution interval and closes it before returning,
including process-local capture suspension. The current macOS adapter resolves
a regular non-implicit Foundation bookmark because Portavoz does not yet adopt
App Sandbox. This preserves folder identity across a move during the active
process without retaining a filesystem capability between intervals; bookmark
persistence and sandbox-scoped recovery remain separate work.

Filename allocation accounts for existing Markdown files, Unicode
normalization, case and width equivalence, hidden/empty titles, reserved device
names, and concurrent collisions. The macOS filesystem adapter writes a UUID
temporary file in the destination directory and then moves it to the final name
without replacement. Existing files are never overwritten.

## Privacy and network boundaries

Meeting content stays on-device unless the user initiates or explicitly enables
an operation that requires transport. Every adopted meeting-content HTTP path
crosses a shared `DataEgressGateway` and declares content-free metadata before
transport:

- operation and purpose;
- destination host and scope;
- local-device or remote classification;
- consent source;
- meeting and provider identity.

The immutable attempt is persisted before URLSession runs. Persistence failure
fails closed, redirects are rejected, and transport failure remains visible in
the meeting privacy receipt. The receipt also reports the meeting's
private-sync standing, so an unqualified all-local claim can never coexist
with an acknowledged iCloud copy (see Private text sync). The gateway requires its recorder by type — a
gateway that cannot record an attempt cannot be constructed. One scoped
exception exists for standalone terminal analysis, which has no library
meeting to own a durable receipt: after its explicit interactive warning, the
CLI records the same content-free attempt on the terminal before transport
instead of in the database. Support diagnostics format 2 adds only active audio
channel/role/codec, health, finite duration/size/signal metadata, and aggregate
transcript/attribution counts so truncated and empty captures are diagnosable.
It never includes meeting text, generated output, prompts, secrets, checksums,
full URLs, paths, stable database IDs, raw failure payloads, or reusable
fingerprints.

The field-validation adapter keeps that shipped format unchanged and packages
it behind a separate protocol-2 manifest. Six canonical hardware/conversation
fixtures report only seven stable evidence IDs owned by recording start,
capture route, callback recovery, Stop durability, post-capture admission, live
translation, and Refine. A paired Refine run carries the same pseudonymous
meeting reference and two independently validated format-2 snapshots; the
collector requires monotonic export time and transcript revision without
reading spoken text. Protocol-1 scenario output remains available for one
release, so field tooling evolves without turning support JSON into a second
application schema or invalidating existing evidence.

Release admission consumes this evidence through a separate, fail-closed
ledger. `docs/evidence/reliability-gates.json` declares every required proof
and classifies it as deterministic automation, signed-build verification,
real-hardware validation, or user-field validation. Deterministic gates write
one receipt bound to the exact version, build, and Git commit; distribution
verification writes one receipt bound to the extracted app identity and DMG
SHA-256; protocol-2 field packages remain the only source for real-device and
conversation claims. `scripts/release_reliability.py` validates those inputs
against the contract and writes an owner-only JSON/Markdown scorecard. A gate
passes only when every declared proof is `pass`; missing, failed, incomplete,
or not-observed evidence blocks release. The scorecard projects only proof
IDs, classes, states, artifact digest prefix, macOS version, fixture, and
collection time. It never copies meeting references, support reports, paths,
audio, transcripts, or generated content.

`PortavozCore` defines stable secret identifiers and the `SecretStoring` port.
`PlatformKit.KeychainSecretStore` is the concrete device-only adapter and is
constructed only by the app and CLI composition roots. `ApplicationKit` exposes
asynchronous user-managed credential operations, so Settings credential and
publishing-command paths do not block their actor on Security.framework calls.
CLI publishing adapters resolve a credential lazily only after ApplicationKit
has admitted the local document or pending work, preserving local errors and
no-op behavior before any device-secret read.
The macOS meeting-document adapter follows the same ordering: local
Markdown/PDF/SRT/WebVTT preparation never reads a credential, and secret-Gist
publication resolves the GitHub token only after the coherent meeting document
exists.
Encrypted voice stores receive the Core port directly; other capability clients
receive resolved credential values, and no capability module constructs
Keychain. SQLite and UserDefaults do not store secrets. Voiceprints are
encrypted, local, erasable biometric data and never enter bundles or sync.

Microphone authorization is queried and requested by a `PlatformKit` adapter.
Onboarding renders only the resulting stable state and delegates calendar
authorization to the app's EventKit integration adapter.

## Private text sync

StorageKit owns portable aggregate semantics and a content-free per-meeting
generation fence. Portable mutations advance the local generation; device-local
audio, paths, embeddings, jobs, receipts, model links, canonical people,
secrets, and voiceprints do not.

The per-meeting privacy receipt reads this journal: an acknowledged generation
is durable proof of a private-cloud copy and is disclosed permanently, even
after sync is disabled. An unacknowledged entry cannot distinguish disabled
sync from an in-flight first upload, so it changes nothing in the receipt. The
receipt says that CloudKit fields or assets are encrypted; it does not claim
end-to-end encryption because Apple guarantees that stronger property for
third-party CloudKit data only when the user enables Advanced Data Protection,
and Portavoz cannot inspect that account setting.

IntegrationsKit encodes deterministic text-first envelopes and maps them to one
private-zone record per meeting. Small payloads use encrypted record values;
large payloads use private CKAsset staging files. Content-free `0600` probes in
the destination directory test complete-protection and backup-exclusion
metadata independently. When supported, that metadata is applied while the
staging sibling is empty and verified before publication. Only `EINVAL` or
`ENOTSUP` marks one metadata capability unavailable; every other application or
verification failure fails closed. Regardless of optional metadata support,
one POSIX descriptor creates and writes a private `0600` sibling, handles
partial writes and `EINTR`, synchronizes with `fsync`, and closes without a
Foundation reopen. Size and owner-only permissions are always verified before
one same-volume atomic rename, so partial content never occupies the final path.
Deletion is an encrypted tombstone, not a physical record deletion.

Transport state is separate from the meeting database and includes hashed
account identity, explicit consent/seed policy, opaque engine state, system
fields, exact attempts, retries, replay cursors, and protected deferred
payloads. A platform-neutral lifecycle owns enable, existing-library seed,
retry, pause, remove-this-device, and account transitions.

The existing-library choice first persists account-scoped intent, then admits
the library through deterministic bounded StorageKit batches. Each batch
commits before IntegrationsKit advances an opaque meeting cursor in its
protected state. Replaying the cross-store crash window is idempotent: a row
whose generation is already pending is updated in place rather than incremented
again. A separate prepared marker proves that every meeting was admitted before
the normal journal/attempt drain can declare the seed complete. Protected
capture blocks the first batch and pauses between committed batches; capture
completion emits one content-free wake that resumes from the cursor. This gate
applies only to the explicit whole-library seed, not ordinary future-change
delivery. It introduces no polling task, lease, or meeting-database migration.

The macOS CloudKit adapter is inert until explicit consent and signed capability
admission. It checks the exact private container, environment, CloudKit, and
push entitlements before constructing the container. Account status precedes
private-database identity. Local and UI-test builds use a no-cloud composition.
Audio never syncs.

## Concurrency and failure handling

- The package compiles under strict Swift 6 concurrency.
- Long-lived mutable workflow state is actor-isolated or `@MainActor`-isolated.
- Live transcription never waits behind batch transcription.
- Potentially blocking database-independent work runs at utility priority.
- Synchronous download callbacks are relayed in order to async presentation and
  drained before their owning workflow returns.
- Durable jobs are idempotent, fingerprinted, owner-leased, heartbeat-driven,
  and retryable without polling.
- Compiler-dense deterministic collections, including operation fingerprints
  and high-cardinality characterization fixtures, are assembled in explicitly
  typed steps. This preserves order and coverage while keeping the supported
  Sequoia Swift 6.2 compiler path bounded.
- Cancellation is explicit and cannot convert partial success into false
  completion.
- Optional derivation cannot roll back required captured/imported data.
- One failed scoped observation preserves healthy sections.
- Model availability is sampled by app-owned adapters and never silently
  changes the selected provider.
- Every critical workflow exposes a typed recovery route.

## Packaging and platform operation

The package minimum is macOS 14.4 because system-audio process taps require it.
Newer OS capabilities degrade through explicit availability checks. The app is
built from SwiftPM and wrapped by `scripts/make-app.sh`; `project.yml` exists for
XCUITest generation. Generated projects, result bundles, local screenshots,
agent state, scratch plans, and local work-item files remain outside version control;
`scripts/check-repository-hygiene.sh` rejects both tracked local state and
private work-item identifier leakage in implementation files. SwiftUI APIs with SDK-
overloaded defaults and presentation math that crosses `CGFloat`/`Double`
boundaries use explicit signatures and types so both the Sequoia and latest
compiler lanes resolve the same behavior. The focused transcript measures rows
in SwiftUI's built-in vertical scroll-view coordinate space instead of sharing
a generic named coordinate key with a concurrent visual-effect closure.
Current dependency APIs are used without deprecated compatibility shims. The
AVAudioConverter input callback receives its immutable source through one
lock-protected, one-shot Sendable bridge; unchecked conformance is confined to
that bridge and no import-wide concurrency suppression is used. First-party
Swift sources compile against the current SDK with warnings treated as errors
both locally and in the primary GitHub Actions build lane; the Sequoia lane
continues to prove compatibility with the oldest supported runtime/toolchain.
Third-party GitHub Actions are pinned to immutable full commit SHAs with their
human-readable versions in comments; repository hygiene rejects mutable tags.

Pull-request UI evidence is selected deterministically from changed paths.
Known presentation and application files map to feature-level XCUITest
selectors; localization and shared-harness changes expand to bilingual
canaries; unknown production Swift paths fall back to the complete English
suite. `RecordingToolbar` maps specifically to the external-recording geometry
case plus the live recording-control/recovery cases, without paying for
unrelated Library grouping or Meeting Detail. The local selector compares the
base with committed, staged, unstaged, and untracked paths by default,
preventing an uncommitted pre-commit smoke from becoming an accidental no-op.
An empty selector explicitly means every test; optional selector and locale
arguments are assembled without empty-array expansion on the system Bash
runtime. One `build-for-testing` result is reused across selected locales.
The runner preserves an explicit `DEVELOPER_DIR`, otherwise follows the active
`xcode-select` toolchain chosen by CI, and falls back to the conventional local
Xcode path only when Command Line Tools is active. Visual-only screenshot
assertions use visible-frame intersection rather than conflating visibility
with a control's temporary enabled or hittable state, and their bounded scroll
budgets cover the smallest GitHub-hosted Settings viewport. Assertions after
asynchronous navigation synchronize on the final observable value rather than
treating the destination element's first frame as completion. The production
navigation contract, not a UI-test retry, guarantees that same-meeting citation
requests are applied; the palette regression explicitly starts from an already-
open destination so a no-op route assignment cannot satisfy it accidentally.
The complete 55-case English and Spanish suites remain the
release/architecture closure gate rather than the default cost for
documentation or isolated surface changes.

The live recording command surface is isolated in `RecordingToolbar` rather
than growing the already state-heavy `RecordingView`. It is responsive by
construction rather than by control truncation. Its wide layout is one row; at
the 900 pt minimum window, `ViewThatFits` moves secondary actions to an
icon-only second row while keeping the elapsed clock horizontal and Stop
visible beside it. The focused external-recording XCUITest enforces those
geometric invariants in both locales.

The live transcript has reader-owned scroll state independent from the
playback lyrics treatment. Direct interaction pauses following indefinitely,
incoming rows preserve that position, and browsing rows render without
fade/scale/blur. Only the identified Jump to live action resumes following;
macOS 15+ uses SwiftUI scroll phases; macOS 14.4 uses a document-scoped AppKit
bridge that observes user-initiated live-scroll events from the enclosing
`NSScrollView`, including legacy mouse-wheel events without a start/end pair.
Programmatic `scrollTo` does not emit either reader-intent signal. Live-follow
mode uses a wider sharp zone and tighter visual bounds than playback.

The shipping app is Developer ID signed, notarized, and stapled. The DMG has an
independent signature/notarization/stapling boundary. Release verification
extracts and checks the inner application rather than trusting the mounted DMG.
After those checks succeed, it can atomically emit the signed-build receipt
consumed by the reliability ledger; it never emits a receipt for a
partially verified artifact.
The script-built app also carries native App Intents metadata extracted
separately from one SDK-only source under the shipping module name. Packaging
fails if the metadata declares no action. `openAppWhenRun` foregrounds the
intent-owning bundle; `perform()` therefore uses a buffered process-local
handoff consumed by `PortavozAppDelegate`, never a LaunchServices URL lookup.
The delegate routes through the same process-scoped pending route used by other
external entry points. macOS publishes only that native action in the Shortcuts
action picker: it deliberately omits `AppShortcutsProvider`, because automatic
App Shortcuts are not a supported macOS product surface and otherwise duplicate
the identically titled action. Spotlight and Siri use a user-created Shortcut
containing the Portavoz-icon action. The XcodeGen-only test app registers the
public `portavoz://record` adapter, and one focused XCUITest directs that URL to
the exact disposable app bundle and proves the handoff enters a visible
recording.
App Intent source changes select only this boundary case instead of the broad
recording-recovery suite; shared harness changes retain three bilingual
canaries. `make-app.sh` also verifies the complete nested signature before it
reports a successful package, so a malformed Sparkle component or application
seal fails at the packaging boundary rather than during installation.
Production remains non-sandboxed because capture, CLI/MCP visibility, custom
folders, Sparkle, and local automation do not yet have a proven parity-preserving
sandbox composition.

`/Applications/Portavoz.app` is the user's release installation and is never
modified by development commands. `make install` builds, signs, verifies, and
installs `/Applications/Portavoz Dev.app`, rewrites both base and localized
names, gives it the distinct `app.portavoz.mac.dev` identity, and force-registers
that exact bundle after signature verification. The XcodeGen host uses
`app.portavoz.mac.uitest-host`. Production, development, and disposable
DerivedData bundles therefore cannot compete for one LaunchServices/App Intents
record. The separate Dev identity requires its own one-time macOS permissions
and preferences; the stable installation remains untouched. UI tests use
disposable SQLite, audio, saved-state, and voice-gallery locations and never
touch the real library or Keychain.

## Enforced engineering rules

1. Meeting content does not leave the device without explicit, visible policy.
2. Portavoz remains MIT-compatible; GPL code is reference-only.
3. Strict Swift concurrency is mandatory; unchecked Sendable requires a
   confinement explanation.
4. Live work has independent scheduling capacity from batch work.
5. Downloaded models are pinned and SHA-256 verified before loading.
6. Persisted identity conversion is strict and never invents replacements.
7. Captured audio outranks every derived artifact and remains recoverable.
8. Application workflows own cross-capability policy; views do not coordinate
   persistence or long-running capability work once a surface is adopted.
9. Capability modules never depend back on the application layer.
10. Generated success and its immutable artifact share one atomic boundary.
11. Evidence is typed, same-meeting, revision-fenced, and fail-closed.
12. Human identity and feedback require explicit gestures and remain distinct
    from generated output.
13. Meeting-content network transport crosses one content-free policy gateway.
14. Support evidence is bounded and redacted by construction.
15. Selected providers and capabilities never change silently.
16. Distribution boundaries carry independently verified trust evidence.
17. Performance changes require comparable disposable measurements before and
    after implementation.
18. Every commit preserves released behavior and leaves build/tests green.
19. Every interactive control has a stable accessibility identifier and UI
    coverage appropriate to its surface. Diff scoping may reduce redundant UI
    execution but must fall back conservatively when ownership is unknown.
20. Every architecture-changing commit updates this document and every other
    source of truth whose current facts changed.
21. Internal tracker keys and ephemeral planning/tool state do not enter source
    identifiers, comments, or tracked files; durable accepted project truth
    remains in the reviewed `docs/` sources of truth.
22. SDK concurrency gaps are isolated in the narrowest lock-protected bridge
    with an explicit safety proof; broad import-level suppression is forbidden.
23. Resource policy begins from content-free matched measurements at workflow
    boundaries; realtime audio callbacks remain outside telemetry and policy.

## Runtime composition facts

The following facts are part of the implemented architecture and are not hidden
behind aspirational diagrams:

- `PortavozCore` contains no Security, AVFoundation, EventKit, SwiftUI, AppKit,
  GRDB, CloudKit, CoreML, or OSLog import.
- `PlatformKit` depends only on `PortavozCore`; its Keychain, microphone, and
  persistent-bookmark adapters are created only by executable composition
  roots.
- `portavoz-app` combines SwiftUI presentation and concrete macOS composition
  in one executable target, so the target links every capability module.
- `portavoz-cli` links every capability module for product commands and
  benchmark harnesses. Adopted product commands enter ApplicationKit through
  one composition surface and keep concrete integrations in executable
  adapters; command implementations contain parsing and presentation only.
  Capture diagnostics and benchmark harnesses keep direct capability access so
  their measurement construction remains explicit and disposable.
- The SwiftPM production graph is asserted exactly, including both executable
  composition roots, every inward Kit edge, and the absence of capability-to-
  application back edges. SwiftUI `View` types do not construct concrete
  storage, model, capture, playback, calendar, egress, or security adapters;
  call `MeetingStore`; or import database and platform-adapter frameworks.
  Concrete construction remains in executable composition, nonvisual live
  capability owners, diagnostics, and disposable benchmark harnesses.
- IntegrationsKit's CloudKit capability probe imports Security only to inspect
  signed entitlements; it does not own or store secrets.
- Durable post-capture product policy enters
  `ApplicationKit.ProcessPostCaptureJobs`. The app composes its StorageKit port
  and concrete audio/model/preference/automation capabilities, supervises the
  process lifetime, and maps content-free events to OSLog/signposts; it does
  not claim jobs or decide retries, fingerprints, dependencies, publication,
  or terminal outcomes.
- One process-owned app telemetry adapter receives only Core's closed resource
  workload events and records generic Points of Interest intervals. Capability
  schedulers and ApplicationKit workflows receive the port through composition;
  both independent intelligence scheduler lanes use one event-only relay. The
  adapter has no content-bearing API, and AudioCaptureKit has no dependency on
  it.
- One tracked resource evidence contract and a separate tooling evaluator own
  multi-host measurement completeness. Application and capability packages do
  not read receipts, choose memory tiers, aggregate baselines, or derive
  runtime policy from this evidence.
- The macOS composition root owns benchmark-only native resource probes for
  idle, recording, Stop, Refine, Summary, Ask, and standalone indexing. One
  canonical Release runner uses disposable meeting/audio state, verified
  installed or OS-managed model assets, and fixed public synthetic
  speech/transcript fixtures; it publishes only exact content-free fragments to
  the tooling evaluator. Production launches and schedulers never read these
  fragments or the resulting receipt.
- Meeting Detail Markdown/PDF/SRT/WebVTT preparation and secret-Gist
  publication enter ApplicationKit. The SwiftUI view does not construct the
  canonical renderer, publisher, or network gateway and does not read the
  publishing credential. Subtitle adapters receive only the narrowed
  `MeetingSubtitleFormat`; native presentation uses extension-specific subtitle
  content types.
- Meeting Detail participant-voice suggestions and explicit memory enter
  ApplicationKit. The SwiftUI view does not read the encrypted gallery,
  resolve recording files, load a diarization model, or match embeddings.
- Meeting Detail transcript/calendar name suggestions enter ApplicationKit.
  The SwiftUI view does not request calendar access, construct a name proposer,
  trust generator-authored evidence, or verify generated identity claims.
- Meeting Detail title, structure, and chapter-label suggestions enter
  ApplicationKit. The SwiftUI view does not inspect model availability,
  construct concrete generators, coordinate one-shot state, or publish stale
  output after a newer review projection arrives.
- Meeting Detail playback preparation, waveform/filter policy, all-channel
  compression, and clip export enter ApplicationKit. The app adapter owns
  recording-root/channel resolution and the concrete AAC compressor; SwiftUI
  imports neither AudioPlaybackKit nor StorageKit and does not retain channel
  URLs or coordinate destructive publication.
- Settings and Onboarding local-voice enrollment enter ApplicationKit. Their
  SwiftUI views do not construct microphone, model, embedding, or encrypted
  identity capabilities; those remain in app composition adapters.
- Settings and Onboarding local summary-provider discovery enters
  ApplicationKit as one coherent typed profile and deterministic
  recommendation. A running Ollama service is eligible only when it exposes a
  nonempty model whose normalized name is not classified as OCR, embedding,
  reranking, or Whisper work. A separate use case persists a clean-install
  recommendation only while no selection exists; the main-actor adapter
  rechecks UserDefaults at the guarded write and reports whether that write won.
  Existing choices remain authoritative. The app adapter retains Foundation
  Models capability checks, content-free localhost requests,
  process/filesystem facts, provider DTO mapping, and UserDefaults persistence.
  SwiftUI localizes typed reasons and renders explicit actions without probing
  providers or recomputing policy. Discovery downloads nothing and never
  substitutes the configured engine. Disposable automation substitutes a
  bounded profile and never probes the host's Ollama models, memory, or disk.
- Settings microphone enumeration, recording-root changes, and remembered-
  voice management enter ApplicationKit. Their SwiftUI views do not construct
  Core Audio, storage-location, or encrypted-gallery capabilities and do not
  discard destructive failures.
- The pre-meeting reminder controller does not read EventKit, preferences, or
  clocks and does not apply reminder policy. Those concerns enter one
  ApplicationKit workflow through a private app adapter; AppKit retains only
  panel and route presentation.
- Model readiness comes only from `ModelStoreKit.VerifiedModelLifecycle`
  evidence over the full pinned descriptor. App consumers share one process
  lifecycle; Settings does not inspect filenames or byte counts, and summary
  providers do not receive a model directory without verified evidence.

Architecture dependency tests ratchet these exceptions so they cannot spread
silently.

## Quality evidence

The current local acceptance baseline is:

- `swift build` succeeds;
- `swift build -Xswiftc -warnings-as-errors` succeeds for first-party Swift;
- 1,735 XCTest package cases pass, with 13 real-model/environment cases gated;
- disposable clean-install and exact v0.6.0-to-current file-library upgrade
  rehearsals preserve user content, verify SQLite integrity/foreign keys, avoid
  an implicit sync seed, and pass an idempotent reopen;
- the 108-test recording/recovery corpus has a fail-closed 25-iteration stress
  gate and passes both Thread Sanitizer and Address Sanitizer;
- strict SwiftLint reports zero violations across 502 Swift source files;
- 61 XCUITest cases define the English and Spanish release gate;
- pull requests run only their selected feature-level UI evidence, while shared
  localization/harness changes and release closure expand to bilingual gates;
- deterministic UI runs use the real application with disposable storage and
  app-window or identified-panel screenshot attachments;
- measured scale fixtures cover 5,000-segment detail, 100,000-segment search,
  100,000-meeting Spotlight projection, semantic retrieval, and long-duration
  waveform generation.

Run the standard gates with:

```sh
swift build
swift build -Xswiftc -warnings-as-errors
swift test
make test-recording-stress
swiftlint lint --strict --no-cache
scripts/check-repository-hygiene.sh
make test-ui-changed UI_BASE=origin/main
make test-ui-bilingual # explicit release/architecture closure
make release-reliability-deterministic # exact version/build required
make release-reliability # missing field or distribution evidence blocks
make install
```

## Documentation maintenance

- `docs/ARCHITECTURE.md` describes only current structure and invariants.
- `docs/specs/` describes current runtime behavior by domain.
- `docs/DECISIONS.md` records binding trade-offs and their reasons.
- `docs/GAPS.md` records unresolved limitations and field-validation needs.
- `docs/IOS.md` records deferred iOS platform constraints and direction.
- `README.md` is public product and contributor truth.
- `CHANGELOG.md` contains user-visible benefits, not internal restructuring.

The repository delivery ledger and completed migration execution ledger are
local maintainer state.
`docs/ROADMAP.md` and `docs/refactor-20260714.md` remain on developer machines
but are gitignored and must not be cited as public project truth.

All explanatory documentation under `docs/` is written in English. Literal
localized UI copy and bilingual transcript fixtures may remain quoted as test
evidence.
