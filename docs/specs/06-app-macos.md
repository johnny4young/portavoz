# Spec 06 — macOS App (portavoz-app + packaging scripts)

Status: implemented, signed with Developer ID, and used in real meetings; public release 0.7.0 independently notarizes and staples both the app bundle and DMG. D74 keeps a clean-Sequoia Homebrew install as explicit field validation instead of treating notarization as launch proof. Decisions: D20 (SPM + script, no checked-in Xcode project), D23 (packaging), D10 (distribution), D40 (evidence-first launch recovery), D43 (durable Stop), D44–D60 (application workflow, feature-state ownership/mutations, scoped Library/Insights/Meeting Detail reads, and inward product/read policy), D61 (implemented package boundaries only), D62–D73 (atomic generated artifacts, enforced meeting-content data-egress verticals, audio-first and role-specific model readiness, app-scoped Whisper preparation, and capability-driven intelligence setup), D74 (independent app/DMG notarization evidence), D75 (store-receipted egress and Meeting Detail privacy receipt), D76 (redacted support export, processing recovery, and content-free signposts), D77 (typed recording failures and app-owned recovery), D78 (measured App Sandbox defer gate), D79–D85 (measured detail, retrieval, waveform, and Spotlight scale), D86 (explicit canonical people), D87 (typed overview evidence navigation), D88 (explicit local claim feedback), D89 (decision evidence navigation), D90 (action-item evidence navigation), D91 (role-separated Apuntador evidence navigation), D97 (provisioned opt-in CloudKit composition), D98 (resident menu-bar ownership), D99 (whole-library backup ownership), D100 (shared Ask workflow and presentation state), D101 (first-run, local-receipt, and meeting-preparation ownership), D102 (PlatformKit security/permission composition and executable read convergence), D104 (application-owned post-capture policy), D105 (application-owned review documents and participant voice memory), D106 (application-owned local voice enrollment), D107 (application-owned speaker-name admission), D108 (application-owned local-provider discovery), D109 (application-owned Settings device resources), D110 (application-owned pre-meeting reminder resolution), D111 (application-owned Meeting Detail metadata suggestions), D112 (application-owned Meeting Detail audio coordination), D113 (catalog-verified model readiness), D114 (executable dependency and presentation boundaries), D115 (honest private-iCloud receipt disclosure), D121 (bounded live-transcription hot attachment and explicit translation state), D123 (long-outage Stop affordance and capture-shape support evidence), D127 (audio-priority Stop recovery), D128 (explicit live-translation lanes), D129 (reader-owned live transcript position), D130 (unhinted automatic Refine), D131/D142 (bounded temporal live-caption bleed admission and view-only paragraphs), D132 (cast-grounded summary owners), D133 (stable split lineage), D135 (regenerable enhanced notes), D143 (deterministic bilingual Library search and exact hit seeks), D144 (reversible role-aware clear playback), D145 (exact-first Library semantic augmentation), D157–D178 (pure resource policy, generation-fenced residency, one composition owner, pinned model-family leases, pressure-driven idle release, capture-exclusive Whisper/MLX admission, bounded persisted-level presentation, signal-driven bounded live translation, recording-scoped bounded live Apuntador generation, signal-driven bounded live-summary delivery, deterministic generated-intelligence admission, observational clipping evidence, policy-owned live-caption presentation bounds, route-cancellable bounded waveform delivery, one shared bounded semantic-indexing flight, capture-prioritized semantic checkpoints, and signal-driven semantic maintenance).

D147 additionally binds release admission to the content-free reliability
ledger described below.
D148 adds the process-wide content-free resource measurement described in
Composition; it observes current work without adding governor policy.
D149 adds the fail-closed multi-host baseline evidence boundary described in
the same section; it remains tooling-only and does not affect app scheduling.
D150 adds the native Release idle/recording/Stop/Refine/Summary/Ask,
standalone-indexing, recording-plus-indexing, and recording-plus-batch
collectors and their
benchmark-only storage-isolation exception; no production launch or scheduler
reads evidence. D151 gives MLX/GPU inference its own explicit single-flight lane
without coupling it to Apple Foundation Models/ANE work. D152 adds one
ApplicationKit semantic-index operation and reuses it in both indexing resource
cells without changing Ask or Library scheduling. D153 requires the
composition root to resolve microphone authorization before any recording
runtime constructs or warms an AVAudioEngine input graph.

## Structure

`portavoz-app` is an SPM `executableTarget` (SwiftUI + Observation, @MainActor). `scripts/make-app.sh [--release]` builds `dist/Portavoz.app`: Info.plist (usage descriptions in English: mic, system audio, calendar, Desktop/Documents/Downloads/removable volumes folders), embeds `Sparkle.framework` + rpath, exports `Resources/Localization/Portavoz/*.xcstrings` to `Contents/Resources/{en,es}.lproj/{Localizable,InfoPlist}.strings`, declares `CFBundleDevelopmentRegion=en` + `CFBundleLocalizations=[en, es]`, signs internal XPCs, hardened runtime (`--options runtime`) + `--timestamp` with real identity + entitlement `com.apple.security.device.audio-input` (without it, the hardened runtime blocks the mic). **No sandbox.**

- Signature: by SHA-1 of cert (`PORTAVOZ_SIGN_IDENTITY`) — there are TWO Developer IDs with the same name on the machine and the name is ambiguous.
- `make install`: renames only the freshly built bundle to `Portavoz Dev`, re-signs it with Hardened Runtime and a secure timestamp, deep/strict-verifies `dist/Portavoz.app`, copies it to `/Applications/Portavoz Dev.app`, deep/strict-verifies the installed copy, and only then launches it. It never writes `/Applications/Portavoz.app`.
- `make-dmg.sh`: with `PORTAVOZ_NOTARY_PROFILE`, first verifies the embedded CloudKit profile and exact signed production capabilities, then archives the app, notarizes/staples/validates it, creates the UDZO DMG + `/Applications` symlink, and separately signs/notarizes/staples the image. Apple-issued direct-distribution profiles may authorize iCloud services with `*`; the verifier accepts that profile form but still requires the signed app to narrow its service to exactly `CloudKit`. `verify-distribution.sh` mounts the final DMG, copies the app out like Homebrew Cask, independently requires codesign, stapler, Gatekeeper, and CloudKit-profile acceptance, and can emit a content-free distribution receipt only after every boundary passes (D147).
- `make-release.sh <v>`: requires a Developer ID identity, notary profile, and Developer ID CloudKit/APNs provisioning profile; stamps version, DMG, `generate_appcast --account portavoz` (dedicated EdDSA key — the default from Keychain is for ANOTHER project), cask with sha256 → `dist/release/`.
- Sparkle 2.9: menu "Buscar actualizaciones…" (`SPUStandardUpdaterController`); `SUFeedURL` points to GitHub release; public key in `assets/sparkle-public-key`.

### Verified model composition (D113)

`AppServices` constructs one process-wide `ModelStore` and
`VerifiedModelLifecycle`. Engine loaders, Settings inventory, MLX summary
resolution, Import, durable post-capture work, participant-voice extraction,
and support diagnostics share that composition. Readiness means every artifact
in the exact catalog revision passed SHA-256 verification; neither a model
directory, one expected filename, nor aggregate byte counts are accepted as
proof. Successful evidence is cached by descriptor ID and revision to avoid
re-hashing multi-gigabyte weights for each consumer, while missing/corrupt
results remain re-checkable and explicit install/remove/invalidate operations
fence older checks. Install and remove operations for one descriptor execute in
invocation order, and any waiter whose check was superseded resolves the current
result instead of surfacing stale readiness. Cancellation before publication
stops preparation; cancellation after verified publication remains success.

Settings performs integrity checks asynchronously and shows a localized
checking row instead of briefly offering a false download state. A disposable
XCUITest launch receives a unique empty model root, so clean-install assertions
cannot inspect or mutate host models. The initial check never gates app launch
or audio capture.

### Executable dependency and presentation boundaries (D114)

The macOS app and CLI are executable composition roots. They connect
ApplicationKit workflows to concrete StorageKit, ModelStoreKit, capture,
transcription, diarization, intelligence, playback, integration, and platform
adapters. ApplicationKit owns use cases, durable workflow coordination, policy,
and narrow capability ports; it does not import executable presentation code or
construct app-specific adapters.

SwiftUI `View` types remain presentation-only: they render observable state and
send intents through injected models or application clients. Repository-wide
source tests reject concrete capability construction, direct `MeetingStore`
calls, and imports of lower-level persistence, audio, calendar, networking, and
security frameworks from those views. Concrete construction is limited to the
two executable roots, nonvisual live capture and dictation process owners,
diagnostics, and benchmarks. A package-graph test also asserts the complete
internal production dependency graph so a new dependency cannot silently
reverse a boundary.

### CloudKit signing and launch boundary (D97)

Ordinary `make app`, `make install`, and XCUITest builds use
`packaging/portavoz-local.entitlements`: microphone and Calendar remain
available, while restricted CloudKit/APNs capabilities are absent and Sync
truthfully reports that the build is not provisioned. Supplying
`PORTAVOZ_PROVISIONING_PROFILE` selects the tracked production entitlements,
embeds the profile at `Contents/embedded.provisionprofile`, and runs
`verify-cloudkit-capabilities.sh` after signing. That gate decodes both the app
and profile, requires exact `iCloud.app.portavoz.mac`, CloudKit, Production, and
production-push values, and rejects an expired profile. Public release creation
requires that profile plus real signing and notarization credentials; the same
gate runs before notarization and against the app copied from the final DMG.

### App Sandbox capability state (D78)

The shipping bundle has Hardened Runtime but no App Sandbox entitlement. This
is a measured feature-parity decision, not an omission presented as privacy.
`scripts/run-sandbox-capability-spike.sh` compiles the same minimal probe into a
Developer-ID-signed sandboxed app and a non-sandboxed control, verifies both
signatures, runs a loopback fixture, and writes the comparison to
`docs/evidence/app-sandbox-capability-spike-20260716.json`.

On the measured macOS 26.5.2 host, the sandboxed variant writes in its
container, denies direct and child-process reads/writes of a dedicated legacy
Application Support fixture, and allows an AVAudioEngine mic graph, Keychain
round trip, Carbon hotkey, loopback network client, and Core Audio process
catalog. The spawned process runs but inherits the sandbox. Both variants create
the private tap/aggregate/IOProc and start/stop the full graph, proving
structural setup compatibility. It does not replace a real product capture
under LaunchServices/TCC. Shortcuts, Accessibility, and Calendar checks are
observational.

Current product blockers are concrete: app defaults would move into its
container while the CLI/MCP still open legacy paths; `RecordingsLocation`
persists a plain absolute folder path rather than a security-scoped bookmark;
existing model/audio/voice data need reversible migration; and `make-app.sh`
does not configure Sparkle's sandbox installer launcher and communication
requirements. A future adoption must additionally prove real process-tap
capture, cross-app dictation paste, configured post-meeting Shortcut, EventKit
permission, panels/bookmarks, model preparation, and Sparkle update install in
a separately signed product build. The production bundle remains non-sandboxed;
D97's restricted CloudKit/APNs capabilities do not change the D78 decision.

## Composition — `AppServices` (@MainActor @Observable)

DB (`MeetingStore`) + lazy shared engines: `transcriber` (Parakeet),
`diarizer` (with voiceprint if it exists; `invalidateDiarizer()` after
enroll/delete), and `whisper` (runtime loaded only for Refine/Import).
`modelsState` drives visible live-model preparation. Parakeet and pyannote each
have an independently retained, process-scoped task: concurrent callers join
the exact verified capability instead of loading another bundle. Parakeet
publication and first use are atomic, and every recording, Dictation, durable
first-pass, onboarding, or benchmark borrower receives an exact-engine
active-use lease.

Recording claims a hot lease without loading and starts audio immediately
through bounded per-channel live feeds. When Parakeet is cold, a
recording-scoped attacher joins the process-owned verified load after capture
starts and connects the active session when it completes (D121/D162). Durable
first-pass recovery and Dictation request Parakeet only; Refine/Import request
pyannote only at their attribution boundary and never acquire live Parakeet as
a side effect. Whisper Turbo/Compact preparation has its own app-scoped
serialized task and observable state. Settings can proactively
start/retry/delete a variant; the task survives that window, Refine/Import join
it, and successful completion retains only an opaque verified token until
runtime allocation. The heavyweight runtime keeps its two-minute idle-release
policy. Library, Insights, and Meeting Detail receive storage-independent
updates from query-scoped Store observations; no app feature consumes a global
`libraryVersion` counter.

### Resource workload measurement (D148)

`AppServices` owns one `AppResourceWorkloadTelemetry` adapter and injects its
Core port into application workflows, transcription, live attachment,
Spotlight, sync, waveform, and Meeting Detail projection. The process-shared
intelligence scheduler receives the same port through a narrow event relay
because provider instances are created ad hoc. The adapter begins and ends one
generic `Resource workload` Points of Interest interval using only public,
allowlisted class/kind/operation/outcome enum values. Its API cannot accept
meeting IDs, transcript, speaker data, file paths, model names, error text, or
network identity; process-local span IDs remain internal and are not logged.

Recording Start and Stop are classified as recording-critical application
transactions. Live consumers remain separate from batch queue wait and
execution. Model prepare/load/release, diarization, intelligence, Spotlight
reconciliation, sync cycles, waveform derivation, first-detail projection,
audio compression/clip export, and support export are measured at their
existing async operation boundaries. `AudioCaptureKit` contains no resource
telemetry, so realtime callbacks never acquire this adapter's lock or emit a
signpost. The existing exact `Meeting Detail First Content` interval remains
in parallel for the established 5,000-segment baseline. No admission,
deferral, priority, concurrency, model-residency, or eviction behavior changes
in this measurement slice.

### Pure resource admission policy (D157)

`PortavozCore.ResourceGovernorPolicy` is a synchronous, deterministic,
Sendable policy with no platform imports or side effects. Its snapshot
combines capture state/source health, categorical memory tier and disk state,
memory and thermal pressure, resident heavyweight model families with optional
measured footprints, foreground-action presence, durable backlog, power
source, and Low Power Mode. The request combines the existing content-free
workload descriptor with either admission or durable-checkpoint evaluation.

The result separates one admission disposition from a deterministic set of
unrelated idle model families to evict. It can admit immediately, admit with
reduced concurrency, defer until capture stops, defer until host/storage/power
conditions recover, pause after a checkpoint, or reject foreground work with
an exact recovery action. Battery and Low Power Mode use distinct deferral
conditions. Active recording-critical work is always admitted; only Start
preflight can reject failed input or critical storage. Optional post-capture
and maintenance work yields to every protected capture state, while live work
continues and sheds concurrency under pressure. Model release is always
admitted because it reduces pressure rather than adding a resident capability.

The Core policy remains pure: it does not read `ProcessInfo`, inspect storage,
schedule tasks, load or release a model, or enter `AudioCaptureKit`. The
application enforces its idle-model eviction output under platform memory or
serious thermal pressure and its capture-only semantic-maintenance
admission/checkpoint output (D177). Host-pressure, power, storage, general
scheduler, and reduced-concurrency outputs remain inactive. Optional footprint
bytes and categorical memory tier are not compared against invented limits;
accepted GOV-0 evidence must define numeric budgets before broader adapters
can enforce them.

### Pure model-residency lifecycle (D158)

`PortavozCore.ResourceModelResidencyLedger` is the deterministic lifecycle
contract between resource policy and concrete model owners. For each closed
heavyweight family it records unloaded, loading, resident, or releasing state;
an exact active-use count; and optional measured footprint bytes. Load, use,
and release operations receive opaque generation-fenced tickets. A late load
completion cannot publish over a newer attempt, duplicate use completion cannot
reduce another consumer's count, and stale release completion cannot remove a
newer resident runtime.

Only an idle resident family can enter releasing. It remains in the
`ResourceGovernorSnapshot` projection until the capability owner confirms that
the concrete runtime is gone; a cancelled release restores resident state.
Records and resident projections preserve the closed family order for stable
diagnostics and tests.

The ledger performs no loading, caching, scheduling, sleeping, model download,
checksum verification, pressure observation, or runtime release. It stores no
model/provider identity, file path, prompt, or transcript content and never
enters `AudioCaptureKit`. The macOS `AppServices` composition root owns exactly
one lock-protected ledger adapter for the process, so MainActor capability
owners and the semantic runtime actor submit atomic transitions to the same
pure Core value. Live speech, Whisper, MLX, diarization, and semantic embedding
now submit complete family lifecycles. Numeric TTL and memory-budget
enforcement require accepted resource evidence rather than constants in this
contract.

#### Characterized runtime topology

The migration surface is locked by an architecture test before adapter changes:

| Family | Current owner and acquisition | Current release |
|---|---|---|
| Live speech | `AppServices+LiveSpeechModels` coalesces one verified Parakeet load; recording, Dictation, durable post-capture work, onboarding, and benchmarks retain exact-engine active-use leases | The ledger rejects release while leased; AppServices confirms concrete release after the existing 600-second generation fence |
| Speaker diarization | `AppServices+DiarizationModels` coalesces one verified reusable Core ML model pair; every live/batch meeting and voice extraction creates a fresh stateful `PyannoteDiarizer` under an exact active-use lease | The ledger rejects release while any session is leased; AppServices confirms concrete model-pair release after the existing 600-second generation fence |
| Quality speech | `AppServices+WhisperModels` coalesces one runtime load and returns exact-engine active-use leases to Refine/Import | The ledger rejects release and deletion while leased; AppServices confirms concrete release after the existing 120-second generation fence |
| Language intelligence | `AppServices+MLXModels` injects one process-owned `IntelligenceKit.MLXSummaryRuntime` into every production MLX provider and returns active-use leases around exact-directory generation | The ledger rejects release and verified-file deletion while active; AppServices confirms concrete release after the existing 120-second generation fence |
| Semantic embedding | `AppSemanticEmbeddingRuntime` coalesces one Apple Latin contextual-model load; one `SemanticCorpusIndexingCoordinator` admits Library/Ask backfill flights; Library, Ask, and app resource benchmarks retain an exact active-use lease around their full indexing-and-query operation | One app backfill task runs at a time; release is explicit and rejected while leased; no evidence-free idle timer is introduced; CLI and standalone benchmark processes own isolated runtimes |

The ratchet also proves there is one process ledger construction, five fully
integrated runtime adapters, and no production semantic constructor outside
the dedicated app adapter. This is not approval of the current idle constants;
semantic embedding intentionally has no timer. The pressure adapter can release
any idle family immediately, while delayed TTL replacement still requires
accepted evidence.

### Whisper residency adapter (D160)

`AppServices+WhisperModels` is the first concrete residency adapter. Verified
preparation remains app-scoped asset work. Runtime acquisition then coalesces
concurrent callers for the same selected descriptor behind one load task and
one `.qualitySpeech` load ticket. A current success publishes the exact
generation as resident and claims the first use lease in the same synchronous
MainActor step; failure returns only that generation to unloaded. A different
descriptor never waits in the unleased publication window: it is rejected
while the first runtime load is active.

Acquisition returns `WhisperRuntimeLease`, which binds the concrete
`WhisperEngine` to one active-use token. Refine freezes its descriptor when the
use case is composed, and both Refine and Import transcribe only through their
retained lease instead of reading mutable shared state after an await. Their
existing `scheduleIdleRelease` application hook ends that lease on success,
failure, or cancellation before arming the two-minute timer. Another caller
may join the same runtime, but a different variant cannot replace or delete it
while any lease is active.

Release is two-phase: the ledger first admits only an idle resident family,
AppServices detaches the concrete reference, and the exact ticket confirms the
unloaded state. A rejected confirmation restores the retained engine and
cancels the release transition. Model files are never deleted by runtime
release, and no download, verification sweep, timer, or wait enters an audio
callback. The 120-second delay is deliberately unchanged pending accepted
per-family evidence.

### MLX residency adapter (D161)

`IntelligenceKit.MLXSummaryRuntime` replaces the hidden static cache with an
injectable actor that owns only concrete `ModelContainer` mechanics.
AppServices constructs the one production instance and every manual, Import,
and durable post-capture provider receives a narrow runtime client. The
isolated `--mlx-smoke` runner constructs its own explicit runtime because it
terminates after benchmark evidence and is not application composition.

Acquisition coalesces the same standardized verified directory behind one
`.languageIntelligence` load ticket. A current success publishes resident
state and claims the first active-use token in the same MainActor continuation.
A different directory is rejected while a load or lease is active. The client
holds that token through `respondPrepared` and ends it on success, failure, or
cancellation before arming the existing two-minute timer. The independent MLX
scheduler still owns GPU priority and single-flight inference.

Release begins only for an idle resident family, drops the concrete container,
then confirms the exact ledger ticket. Settings refuses verified model removal
during load or active generation. Runtime release never removes verified files,
and asset preparation remains outside generation and every audio callback. The
120-second delay and unknown measured footprint remain unchanged until accepted
per-family evidence defines replacements.

### Live-speech residency adapter (D162)

`AppServices+LiveSpeechModels` owns the one production Parakeet runtime and its
complete `.liveSpeech` ledger lifecycle. Same-process callers join one verified
load task. A current success publishes the runtime and claims the first use in
one synchronous MainActor continuation; every joiner receives its own
`LiveSpeechRuntimeLease`. Cancellation after a shared load finishes ends the
new token before propagating, so a cancelled waiter cannot strand active use.

Recording preparation uses a separate resident-only acquisition and therefore
never starts model work before audio. `LiveTranscriptionAttacher` receives an
opaque runtime handle whose completion ends the AppServices lease. It owns the
handle through every channel consumer and releases it only after their streams
drain. A cold load may outlive the recording waiter; Stop does not await it, and
the inactive attacher releases any later result without attaching captions.
Failed source start and cancelled preparation release a previously claimed hot
runtime as well.

Dictation and durable first-pass transcription hold the same exact-engine lease
for their complete stream/file operation. The recording resource benchmark
preloads through a short lease outside its metric window, then acquires a fresh
lease for measured batch work. Onboarding intentionally borrows both live
families and ends the Parakeet token after readiness resolves. Concrete release
is two-phase and restores the runtime if ledger confirmation fails. The
existing 600-second generation fence remains unchanged, but it can no longer
drop Parakeet while any production borrower is active.

### Diarization residency adapter (D164)

`DiarizationKit.PyannoteDiarizationRuntime` separates process-reusable Core ML
weights from the stateful `DiarizerManager` speaker database. AppServices owns
one runtime, joins concurrent verified preparation behind one
`.speakerDiarization` load ticket, and claims the first active-use token in the
same MainActor publication step. Each joiner receives a distinct
`DiarizationRuntimeLease`; cancellation after a shared load ends that token
before propagating.

No meeting reuses a `PyannoteDiarizer`. Live recording, durable post-capture
attribution, Refine, Import, local-voice enrollment, and participant-memory
extraction create fresh sessions from the retained weights and hold their
leases through inference. Identity is sampled separately for each operation,
and durable post-capture execution receives the exact sample already included
in its operation fingerprint. Saving or deleting the encrypted voiceprint does
not require dropping the model pair, cannot alter admitted durable work, and
cannot leave stale identity inside a later session. The CLI remains a separate
short-lived composition.

Release is two-phase and accepted only when every operation has ended.
AppServices detaches the reusable model pair, confirms the exact ledger
generation, and restores the retained value if confirmation fails. Verified
assets remain installed, degradable diarization still produces honest
unattributed transcript, live hints remain optional, and no model operation
enters an audio callback. The shared 600-second fence is deliberately
unchanged pending accepted per-family evidence.

### Semantic embedding residency adapter (D165)

`AppSemanticEmbeddingRuntime` is the process-owned actor behind
ApplicationKit's `SemanticEmbeddingRuntimeClient`. It constructs at most one
`SentenceEmbedder`, coalesces concurrent preparation, and records the complete
`.semanticEmbedding` load/use/release lifecycle through the same
`AppModelResidencyLedger` used by the MainActor model adapters. Load completion
and the first active-use acquisition are one atomic ledger operation; failure
clears the current load generation and permits a later retry.

Library and Ask receive the runtime and one semantic-indexing coordinator by
dependency injection. Library first checks already-installed assets and never
requests a download while typing. Its bounded backfill coalesces when another
flight is active. Ask may request Apple's OS-managed assets, joins any active
bounded flight, then keeps one active-use token while it drains the durable
remainder, expands the query, generates vectors, and performs hybrid retrieval.
The standalone indexing and recording-plus-indexing resource workloads use the
same app runtime but remain isolated benchmark owners of their operation; the
CLI owns one equivalent process-local runtime and the scale-only CLI benchmark
remains isolated.

Explicit release begins only for an idle resident family, drops the retained
model, and confirms the exact release generation. It never deletes macOS
assets, waits in an audio callback, or introduces an unmeasured TTL.

### Pressure-driven residency release (D166)

`AppResourcePressureMonitor` is a process-scoped macOS bridge over
`DispatchSourceMemoryPressure` and
`ProcessInfo.thermalStateDidChangeNotification`. It stores only the latest
closed memory/thermal enums and publishes a content-free snapshot to
AppServices. Disposable `-use-temp-store` launches and isolated resource
benchmarks install no observer, preserving deterministic UI and benchmark
evidence.

`AppServices+ResourceGovernor` submits a release workload plus the real
residency projection and capture phase to the existing pure policy. It applies
only the returned stable list of idle families, routing each request back to
its concrete release owner: live speech, quality speech, diarization, MLX, or
semantic embedding. Every release retains its family-specific two-step ledger
transition and cannot detach a leased runtime or delete verified assets.

When pressure first arrives while a family is active, the ledger does not
queue a stale release ticket. Instead, ending the final exact-use lease invokes
one composition observer after the ledger lock is released. The MainActor
adapter re-reads the monitor's current state and latest residency snapshot,
then asks the pure policy again. This provides eventual release under
persistent pressure without executing async work under the lock.

The adapter changes no idle TTL, scheduler, admission/deferral behavior, model
download lifecycle, or AudioCaptureKit callback. It does not wait on capture
and carries no meeting IDs, text, paths, model names, or raw errors.

### Capture-exclusive heavy-model admission (D167)

RecordingController publishes every phase transition to AppServices, which
maps it to the closed `ResourceCaptureState` enum and stores it in one
lock-protected, content-free mirror. The mirror lets the residency ledger's
non-MainActor final-use observer decide whether reconciliation is relevant
without reading observable UI state. Starting, active, and stopping phases
request a governor pass even under nominal host pressure; inactive phases do
not.

The app submits only `.load` requests for the quality-speech and
language-intelligence families. Its memory tier remains `.unknown` until
accepted hardware evidence supports classification. On an unknown host during
protected capture, the pure policy requests release of an idle peer and defers
a second pair-member load if that peer is loading or still has an active lease.
The adapter projects a loading ledger record as non-idle governor occupancy,
without making it releasable, so concurrent cross-family acquisitions cannot
both pass. Two tasks already active before Start are never interrupted; their
final-use callbacks make each newly idle member eligible for reconciliation.
The existing constrained policy remains stricter; standard and large tiers are
unchanged. The adapter executes only the pair's release/defer contract and does
not activate broader policy dispositions.

Whisper checks before verified preparation, atomically rechecks and reserves
its load ticket immediately before engine loading, and checks before publishing
the loaded engine. MLX uses the same atomic admission-and-reservation step
after any prior-runtime release and immediately before loading, then checks
before publishing residency. The repeated checks are required because either
capture or the peer runtime can start while asynchronous work is suspended.
Every rejection rolls back the exact load ticket; MLX additionally releases
the prepared container. The user receives one localized instruction to finish
the recording before starting the competing large on-device AI task.

Architecture coverage proves preparation and publication checks plus one
atomic load-admission reservation in each adapter, phase-mirror publication,
pure-policy dispatch, concrete-owner release, and the absence of model
lifecycle, model stores, Whisper, MLX, or their release methods from
`AudioCaptureKit`. Verified files stay installed; capture callbacks perform no
model download, checksum sweep, or release wait.

### Capture-prioritized semantic maintenance (D177)

AppServices builds one `DurableMaintenanceGate` from its content-free capture
mirror and the pure `ResourceGovernorPolicy`, then injects it into the
process-owned `IndexSemanticCorpus`. The gate receives only a closed workload
descriptor and admission/checkpoint phase. Its snapshot deliberately keeps
memory tier, disk, pressure, thermal, power, and model residency at their
neutral or unknown values; this first adapter enforces only the
threshold-independent protected-capture rule.

Starting, active, and stopping capture prevent a new semantic pass. Work
admitted before capture finishes its current bounded database batch and pauses
before fetching another. The operation reports policy suspension separately
from cancellation/failure and leaves every remaining embedding row `NULL`, so
the next Library or Ask demand resumes from storage with no polling loop or
ephemeral retry owner. Exact Library search continues independently. Ask may
continue with lexical and already-indexed semantic evidence.

The gate is synchronous, lock-bounded, and outside `AudioCaptureKit`; capture
never waits for it. D178 wakes maintenance when capture stops; moving Ask's
drain entirely off the request path and activating host-pressure, power,
storage, lease, or heartbeat policy remain later resource-governor extensions.

### Signal-driven semantic maintenance (D178)

`AppServices` owns one `SemanticCorpusIndexingSupervisor` for the process and
routes app launch, searchable mutations, and capture returning inactive through
`requestSearchReconciliation()`. That funnel keeps Core Spotlight and semantic
maintenance aligned while preserving separate implementations. During
protected capture it still requests Spotlight reconciliation but defers the
semantic wake until the capture-state transition publishes inactive.

The supervisor serializes one complete drain and collapses every concurrent
wake into one later rerun. It never schedules a timer. Its production adapter
checks one pending database row before borrowing the app-owned semantic
runtime, uses only already-installed Apple assets, and cannot request an asset
download. The D177 gate remains the final admission/checkpoint authority if
capture changes after wake admission.

Temporary/UI stores and isolated resource benchmarks disable the owner. A
failed drain logs only an ordinary content-free operational message; durable
`NULL` rows survive and the next mutation, capture completion, or launch
retries them. Ask keeps the released synchronous complete-drain path until a
separate measured migration proves lower request latency without recall loss.

### Bounded recording-level relay (D168)

The StartRecording callback contract carries compact
`PersistedAudioLevel` values measured only after the writer accepts each audio
chunk. `RecordingController` submits them to one recording-scoped,
lock-protected relay. Submission is synchronous O(1), retains one newest
snapshot, and schedules at most one MainActor delivery per 50 ms display
window. The controller never scans PCM to update its meter.

Every compact sample still updates the established voiced-microphone and
system-channel diagnostic EMAs before presentation is coalesced, so the
low-input and missing-remote-audio thresholds see the complete stream.
A constant-space ceiling detector consumes the same values and measures
accepted audio duration rather than callback count. After sustained
system-channel ceiling exposure, the controller publishes a dismissible
transcript-quality warning. Clean audio clears the underlying state with
hysteresis. The control only dismisses presentation; it does not attenuate
audio, alter capture, or mark transcript rows as invalid.
Reset, failed Start, and Stop cancel the relay; a generation fence rejects
scheduled and late callbacks from that session. Only obsolete visual states
are latest-value-wins. Audio writing, live-transcription feeds, capture-health
events, and final transcript evidence retain their existing durability and
overflow contracts.

### Bounded translation wake relay (D169)

`RecordingController` owns one content-free `LiveTranslationWakeHub` for the
recording. Caption/coalescing changes, live-speaker relabeling, target and
source transitions, download consent, and unsupported-passthrough updates
broadcast to the currently active Translation framework lane. Subscribers
retain at most one invalidation and recompute from observable controller state;
they do not enqueue transcript rows. Canceling a lane finishes and unregisters
its stream.

Idle, download-gated, and unsupported lanes await the wake stream instead of
scheduling a permanent MainActor poll. The live routing policy examines the
newest 60 rows and sends at most eight chronological rows per framework call.
Successful calls drain the next bounded batch immediately, while actual
preparation and execution errors retain bounded retry backoff. Pair fencing and
source-revision checks reject obsolete responses. Durable captions, audio,
Stop, and Refine never depend on this optional presentation relay.

### Recording-scoped Apuntador coordinator (D170)

`RecordingController` owns one `LiveCompanionWorkCoordinator` beside its
silence-endpoint task. Accepted turns no longer create independent wrapper
tasks. The coordinator starts one complete generation and retains at most one
newest pending request while it runs. When the active generation completes, it
publishes only if the worker remains uncancelled, then starts the retained
candidate. The result receiver still applies the existing meeting/phase fence.

Turning Apuntador off, preparing a new recording, advancing from a completed
session, and Stop all call the same coordinator cancellation path. Cancellation
clears pending work immediately and fences the active result. If a provider
does not unwind synchronously, a request from the next lifecycle waits behind
it rather than creating concurrent model work. The coordinator owns no Store
state, carries no durable queue, and never blocks capture or Stop.

### Recording-scoped live-summary coordinator (D171)

`RecordingController` owns one `LiveSummaryWorkCoordinator` for optional
Foundation Models rolling intelligence. Initial recording state, each newly
closed caption row, late live-speaker relabeling, and note additions/removals
request a refresh. Requests carry no content and collapse into one pending bit.
The coordinator waits for the 40-second minimum cadence, allows one complete
cycle, and retains one later invalidation or successful backlog signal.

`LiveSummaryWindowPolicy` selects the oldest unseen closed rows, capped at 32
rows and 6,000 characters. One oversized head row still advances alone.
Candidate notes and row IDs remain local until condense, optional note-stack
collapse, and structured reduction all succeed. After each suspension the
controller checks task cancellation, recording phase, and meeting identity
before publishing all candidate state atomically. Failure preserves the
existing summary and cursor and waits for another input signal; it does not
create an outage poll.

Preparing another recording, advancing from a completed session, and Stop all
cancel the same coordinator. A fresh request that arrives while a cancelled
provider unwinds waits for that worker to exit, preserving the one-active
invariant. The coordinator never owns durable work, and final summary
generation remains in the post-capture application workflow.

Recording Start is also the single authorization boundary for meeting capture.
Its explicit user action asks `MicrophonePermissionClient` to resolve an
undetermined microphone grant before `MicrophoneSource` exists. Existing
authorization proceeds without another prompt; denied or restricted access
returns the localized typed preparation failure without entering Core Audio.
The isolated resource app performs the same preflight before any measured
window, so one-time TCC interaction is never counted as runtime workload.

The tracked `docs/evidence/resource-baseline-matrix.json` contract and
`scripts/resource_baseline.py` sit outside the executable. They require three
stable Release runs for every combination of 8 GB, 16 GB, and reference-memory
profiles with idle, recording, Stop, Refine, summary, Ask, indexing,
recording-plus-indexing, and recording-plus-batch scenarios. Receipts accept
only aggregate process resource metrics and bounded summaries of the same
closed workload enums. Wall or CPU p95/p50 above 1.25 marks a cell unstable.
The evaluator rejects extra/content-bearing fields, unknown enums, non-finite
values, duplicate JSON keys/runs/profiles, wrong memory tiers, and build
mismatches. Missing, incomplete, or unstable hardware evidence still produces
all 27 rows as a blocking owner-only scorecard. The app never reads this
contract or scorecard, and matrix completion does not enable resource
admission, deferral, residency, or eviction behavior.

The hidden Release resource benchmarks install an observer on
`AppResourceWorkloadTelemetry` only while evidence is being captured.
`ResourceRunProbe` combines those closed events with native process counters
(`proc_pid_rusage`), current volume capacity, thermal/low-power state, and
IOKit power source. It exports exact-shaped owner-only samples without content,
paths, model names, span IDs, or raw errors. The Stop probe is armed first and
atomically replays active spans before recording metrics freeze. Boundary spans
may finish into the recording sample while Stop measures them independently;
new spans enter only the Stop probe. Counter failure, changed power source,
incomplete lifecycle, Stop beyond 30 seconds, or an existing output blocks the
run. A reusable single-scenario probe owns the same observer/sample lifecycle
for Refine and later model-heavy scenarios.

`make resource-baseline` builds the exact Release bundle once, clones and
re-signs a scratch app with the separate
`app.portavoz.mac.resource-bench` identity, and runs at least three
idle/recording/Stop/Refine/Summary/Ask/indexing/recording-plus-indexing
and recording-plus-batch samples. The original
`make resource-recording-baseline` target delegates to this canonical command.
A five-second launch-settling interval precedes the model-free idle window.
Refine runs as a draft-only cold-runtime operation in a separate process against
one host-generated, non-silent English AIFF containing only fixed public text.
The runner verifies the selected Whisper model, tokenizer, and diarization
model before sampling and bounds execution to 60–3,600 seconds; model download
is not part of the scenario. Summary runs in another cold process, verifies
the pinned Qwen3.5 MLX descriptor before sampling, inserts a fixed public
English meeting/cast/transcript into the disposable database, and measures the
real `RegenerateSummary` ApplicationKit workflow through successful
transactional persistence. Ask runs in a third cold process, requires
already-installed Apple Latin embedding assets and available Foundation Models,
and measures the real `AskMeetings.local` workflow over the same fixed corpus,
including its current synchronous embedding backfill, bilingual query
expansion, hybrid retrieval, and generated answer. It emits no sample without
citations and nonempty generated text. Indexing runs in a fourth cold process,
prepares already-installed Apple Latin assets before sampling, inserts 1,024
fixed public English segments into the disposable database, and measures
`IndexSemanticCorpus` until every row is embedded or deliberately excluded.
Recording plus indexing runs in a second real windowed recording process. It
prepares the same indexing workload before measurement, arms its probe before
Start, and begins indexing only after Start succeeds. The recording stays
active until indexing validates. Process metrics freeze before Stop, while the
observer remains long enough to retain terminal outcomes for spans already
active in the measured window and rejects Stop-only spans. Every bounded model
operation shares one configurable hard timeout, and the concurrent sample
requires both successful indexing validation and successful Stop. Recording
plus batch runs in another real recording process. It resolves the shared
Parakeet runtime before measurement, starts the fixed public AIFF through the
production post-capture batch lane only after Start, retains capture until the
bounded file transcription returns nonempty speech, then applies the same
freeze-before-Stop and fail-closed publication boundary. Diarization and
summary are intentionally outside this independently attributable cell.
Every launch requires `-use-temp-store`, so the benchmark meeting database and
audio stay disposable. The same policy composes a process-local secret store
and a unique temporary participant-identity root, so resource and UI
automation never inspect or mutate the host Keychain, voiceprint, or
participant-voice gallery. Production keeps the Keychain-backed store and
durable identity root. `AppStorageIsolationPolicy` allows only hidden
recording/recording-plus-indexing/recording-plus-batch/Refine/Summary
benchmarks to reuse the normal verified Portavoz model cache. Ask and indexing
use OS-managed assets and keep the disposable model root. Regular
`-use-temp-store` automation still receives an empty model root.
The resource
dispatcher also returns from app initialization before normal sync,
recovery, provider discovery, or dictation registration can start; it detaches
the AppKit delegate from product services. The runner refuses a dirty worktree,
never targets the notarized installed app, removes the private
fragments/fixture on failure, and publishes the receipt only after all
fragments validate.

Local voice enrollment is composed in `AppServices+LocalVoiceIdentity` and
enters `ApplicationKit.ManageLocalVoiceIdentity`. The use case bounds requested
duration, requires at least four seconds of finite samples, and owns
capture/extraction/persistence order. The app
adapter owns `MicrophoneSource`, raw versus echo-cancelled capture, guaranteed
stop on success/failure/cancellation, shared verified diarizer loading,
transient voiceprint extraction, utility-priority encrypted storage, and
diarizer invalidation after successful mutation. Settings changes its enrolled
state only after deletion succeeds. It preserves its fresh
twelve-second echo-cancelled path. Onboarding preserves both first-listen sample
reuse and fresh twelve-second raw capture. These views render progress/results
without importing AudioCaptureKit or DiarizationKit. Temporary-store launches
return no enrolled identity and never inspect or mutate host biometric state.

Local summary-provider discovery is composed in
`AppServices+LocalSummaryProviders` and enters
`ApplicationKit.DiscoverLocalSummaryProviders`. One typed profile describes
Apple Foundation Models availability, the running Ollama models, physical
memory, and available disk. The pure policy admits Ollama only when at least
one nonempty model name is not classified as OCR, embedding, reranking, or
Whisper work; models in those categories are not presented as summary-ready.
`ConfigureInitialSummaryProvider` writes only when the preference is absent.
Its main-actor UserDefaults adapter re-checks at the guarded write and reports
whether the write won, preserving an explicit user choice made during startup.
The app adapter retains Foundation Models checks, content-free localhost
requests, hardware/disk facts, model DTO mapping, and UserDefaults persistence.
Settings and Onboarding consume the same typed recommendation and localize its
headline, reasons, and setup action; neither surface probes providers or owns
clean-install policy (D108).
Disposable UI-test composition never probes host Ollama, memory, or disk; it
uses a bounded profile while preserving the explicitly simulated Apple
capability, so provider guidance and screenshots are reproducible.

Settings device resources are composed in `AppServices+SettingsResources` and
enter three capability-neutral ApplicationKit workflows (D109). Microphone
enumeration exposes stable UIDs and display names while the app adapter retains
`AudioDeviceCatalog`. Recording-root inspection and updates expose current and
default locations plus ordered progress while the adapter retains
`RecordingsLocation`, resumable filesystem migration, and marker publication
only after success. Remembered-voice management exposes summaries without
embeddings while the adapter retains encrypted `VoiceGallery` access on a
utility executor. Destructive failures remain visible, and disposable test
composition never reads or mutates the host gallery. SwiftUI keeps only native
folder selection, preferences, localized progress, and result presentation.

Pre-meeting reminders are composed in `AppServices+MeetingReminder` and enter
`ApplicationKit.ResolveMeetingReminder` (D110). The workflow receives one
sampled time, the configured lead, and the session's reminded identifiers. It
short-circuits before calendar access when disabled, selects the deterministic
earliest due event independent of source order, and returns display minutes
from the same sampled time. The private app adapter retains UserDefaults,
`Date`, and `CalendarAttendeeSource`; the EventKit projection runs on a utility
task. `MeetingReminderController` retains only minute scheduling, session
deduplication, floating-panel lifecycle, and the recording route. Optional
calendar failures remain a silent no-notice result, matching the released UX.

`AppServices` also owns one process-scoped `SpotlightIndexer` actor (D85).
Launch and every searchable mutation call `requestSpotlightReindex()`; requests
coalesce for 250 ms and are not tied to a `ContentView` lifecycle. The actor
loads one consistent StorageKit projection, hashes its exact documents into a
compact client state, skips unchanged publication, and retries failures after
one and five seconds. Its private backend serializes access to the named
`app.portavoz.meetings.v2` index, uses complete file protection and 500-item
batches, and removes the released default-index domain only after the protected
index is ready. A failed legacy cleanup remains retryable; the first success
records a versioned local migration marker instead of issuing the same delete
on every unchanged reconciliation or future app launch. Temporary UI-test
stores disable OS indexing. Internal status
and content-free OSLog attempts are diagnostic only; no meeting content is
logged. A new request after terminal retry exhaustion starts a fresh recovery.

`AppServices` also owns one process-scoped `MeetingSyncModel` (D97). Production
composition creates the platform-neutral D96 lifecycle and an inert
`CloudKitMeetingSyncPlatform`; no container or account request occurs until
stored account-scoped consent or explicit Enable permits it. The model
serializes manual lifecycle work, preserves explicit actions FIFO while an
operation is suspended (including draining past actions made inapplicable by an
earlier Pause), and coalesces content-free StorageKit journal,
`CKAccountChanged`, retry-clock, and silent-push wakeups into the same bounded
cycle. It registers for remote notifications only while sync is enabled.
Temporary-store/XCUITest composition injects a deterministic in-memory client,
never probes the host signature/account/APNs/transport root, and exercises the
same bilingual Settings states and actions.

`AppServices` also owns one process-scoped `LibraryMarkdownBackupModel` (D99).
It submits one destination to `ExportLibraryMarkdownBackup`, maps typed progress
and fatal/partial completion into localized state, rejects a competing run, and
outlives the Settings scene that started it. Private app adapters render the
canonical `MeetingExporter` document at utility priority and publish it through
an atomic UUID temporary file plus a same-directory non-replacing move. The
filesystem adapter returns a collision instead of replacing disk content, so
the application allocator advances its portable suffix. Temporary-store UI
tests may inject only the destination path; production always uses the native
folder panel.

`AppServices` composes one `AskMeetings` workflow and exposes it through one
main-actor app client. Each `ContentView` owns a per-window `AskModel`; the
resident command palette owns one process-scoped `CommandPaletteModel`. The
models own answer/search tasks and generations, and the palette resets both on
close/reopen. AppKit owns panel lifetime, keyboard activation, clipboard, and
window navigation only. Full Ask and palette citations publish the same exact,
meeting-scoped seek request before opening Meeting Detail. The destination
consumes it after playback is ready; if that meeting is already open, its
detail observes the identity-bearing request directly instead of depending on
a no-op route assignment to reconstruct the view (D100).

`AppServices` owns one process-scoped `FirstRunModel` and one process-scoped
`LocalDataLedgerModel` (D101). `ResolveFirstRunExperience` decides whether one
restored main window presents setup from force/automation/completion flags and
an efficient live-meeting count; model downloads and permission readiness are
not eligibility inputs. Existing-library suppression is remembered, a failed
read keeps guidance available, and cancellation leaves resolution retryable.
The local-data receipt loads meeting count, allocated audio bytes, and local
encrypted-voice count concurrently through independent ports. A failed source
renders unavailable only for that tile, while a measured zero remains zero.
Its network tile states explicit-action/opt-in policy rather than claiming an
unmeasured byte count.

The per-window `LibraryModel` submits an upcoming event to
`PrepareMeetingBrief` (D101). The workflow reuses Ask evidence, ranks related
meetings, overlaps one batched latest-live-General-summary projection with the
open-commitment query, and accepts optional synthesis only when its source
index maps to a related meeting. The app adapter retains Foundation Models and
already-authorized EventKit access; opening or refreshing the Library never
prompts for Calendar access on its own.

Meeting Detail document actions enter ApplicationKit (D105). The in-memory
preparation workflow loads one coherent detail and latest General summary,
renders canonical Markdown once through an injected adapter, and returns
Markdown/PDF bytes with the released title-based suggested filename to the
native save surface.
Secret-Gist publication reuses the explicit document publication workflow.
The app adapter performs utility-priority rendering, resolves the GitHub token
only after local document admission, and constructs the gateway-backed secret
publisher. The view retains only the user gesture, off-device confirmation,
native panel state, and localized success or failure presentation;
`MeetingDetailModel` owns the request and typed result effects.

Participant voice-memory actions also enter ApplicationKit (D105). The workflow
loads one coherent detail, limits suggestions to unnamed non-user speakers,
degrades optional gallery or extraction failure, applies one-to-one matching,
and accepts persistence only for an explicitly requested currently named
non-user speaker. The app adapter owns recording paths, transient embeddings,
pyannote/ModelStore loading, encrypted gallery access, utility scheduling, and
disposable-test isolation. Meeting Detail retains suggestion chips, explicit
acceptance and remember gestures, and localized results without handling
biometric storage or model policy. The route-owned model keeps one-shot
suggestion state and every voice-memory action/effect.

Transcript/calendar speaker naming enters ApplicationKit (D107). The workflow
loads one coherent meeting detail, excludes `Me` and already named speakers,
requests optional attendee candidates through a port, invokes an untrusted
proposer, and independently verifies each normalized name as complete tokens in
a real transcript line or calendar candidate. The workflow derives typed
evidence from that source, not model-authored prose. The app adapter owns
EventKit authorization and the Foundation Models proposer. The route-owned
model owns loading, suggestions, removal only after successful explicit
persistence, and visible failure effects. Meeting Detail retains only inert
chips, typed evidence presentation, and the explicit acceptance gesture;
calendar-backed confirmations retain calendar alias provenance.

Meeting Detail title, summary-structure, and chapter-label suggestions enter
ApplicationKit (D111). One workflow admits only template-like meeting titles,
General summaries, and untitled chapters; maps proposed structures to the known
recipe catalog; and trims, bounds, or rejects generated labels before they
reach presentation. Ordinary generator failures degrade independently, while
cancellation propagates so a newer meeting revision can retry. The private app
adapter owns Foundation Models availability and the concrete title,
meeting-type, and chapter generators. `MeetingDetailModel` owns one-shot state,
request identity, revision fencing, cancellation retry, and explicit
dismissal. Title, text-name, remembered-voice, recipe, and thin-summary
suggestions each expose a separate minimal dismiss action; dismissal mutates
only route-local presentation state. SwiftUI renders inert suggestions and
sends acceptance actions only.
A failed title rename preserves the suggestion and visible error, and requests
Spotlight reindexing only after persistence succeeds.

Meeting Detail audio enters ApplicationKit (D112/D144). Playback preparation
resolves the current canonical system and microphone files through an injected
port, constructs one synchronized observable application facade, derives a
bounded capability-neutral waveform away from the main actor, and installs
silence and microphone-turn filters before publication. The application policy
admits 600 buckets by default and never publishes more than 2,000. The
AudioPlaybackKit worker reads the complete finalized channels, propagates route
cancellation into its detached task, and checks cancellation between 65,536-
frame chunks. Cancellation publishes no partial waveform and never edits,
truncates, or caches the authoritative audio. If both channel roles load, the
default `Clear playback` mix leaves direct system audio unchanged and admits
the microphone only around merged transcript-confirmed local turns. The toggle
restores the original mix without rewriting audio; mic-only recordings never
receive channel attenuation, and clip export follows the selected mix.
Compression uses an injected codec
port and treats every raw channel as one failure-safe batch: an existing AAC
output fails closed, all generated files must verify before any original is
removed, and failures or cancellation remove only generated work. Clip export
re-resolves current files after compression. The private app adapter retains
`RecordingsLocation`, `MeetingAudioLayout`, and the concrete `AudioTranscoder`;
`MeetingDetailModel` owns one-shot preparation, invalidation, compression
state, player reconstruction, and typed export effects. Its playback task is
keyed to the audio directory rather than review revisions, so cancellation by
independent initial section updates cannot consume the only attempt. SwiftUI
retains only transport controls, drawing, and the native save panel.

SwiftPM and the XcodeGen UI-test project link `ApplicationKit`. It exposes the
Sendable async `ApplicationUseCase<Request, Response>` contract and admits
capability dependencies only with characterized vertical workflows.
`DeleteMeeting` and `RestoreMeeting` use a narrow `MeetingLifecycleStore` port;
manual and launch-time purge coordinate a pure storage projection with the
private app `MeetingAudioFiles` adapter over RecordingsLocation and the local
filesystem. `RegenerateSummary` receives storage, glossary-preference, and
provider-resolution adapters; Meeting Detail submits one request and maps its
typed completion/cache/unavailability/failure result. Regeneration reuse is
recipe-scoped, reload selects the newest immutable snapshot across structures,
and all older per-recipe versions remain stored (D44/D45). Each direct model or
Apple translation-pivot attempt now carries provider/model metadata and creates
content-free terminal provenance. Exact cache hits create no run; successful
run + immutable summary + action items commit atomically, while failed/cancelled
attempts remain best-effort diagnostics. The app still presents the same silent
versus visible provider and persistence outcomes (D62).

Slice 2F moves external audio import through `ApplicationKit.ImportMeeting`.
`AppServices` now only samples platform preferences, constructs private
filesystem/model/provider adapters, localizes typed progress, requests
Spotlight reconciliation after success, and returns the ID used by the existing
Library navigation. The use case owns required transcription, degradable
diarization and summary, independent transcript/summary languages, idle
release, staged-audio rollback, and atomic meeting/cast/transcript installation.
File copy and compensating deletion run at utility priority instead of on the
MainActor. Its import-specific provider resolver exposes the configured
provider/model/revision without leaking engine construction into ApplicationKit.
After the required aggregate commits, each real summary call records one
content-free attempt. Success links run + immutable summary/actions atomically;
provider failure, cancellation, or publish failure remains best effort and can
never discard the meeting or copied audio. An unavailable provider creates no
synthetic run. Existing progress, navigation, and idle-release timing stay
unchanged (D46/D64).

Slice 2G moves quality re-passes through `ApplicationKit.RefineMeeting` and
`ApplyRefinedMeeting`. `AppServices` composes private audio, preference,
processor, Store, and Apuntador adapters; `RefineService` retains only
per-meeting presentation/task state, explicit cancellation, and run-identity
fencing. D65 freezes the selected Whisper descriptor for that use-case
instance and supplies each non-silent channel with exact local content
evidence. One composite successful transcript run stays inside the review
draft until Apply commits it with accepted language, cast, transcript, segment
links, and next revision. A stale/discarded draft writes no success; a begun
failed/cancelled attempt is standalone best-effort diagnostics. Summaries remain
immutable and Apuntador refresh is post-commit optional work. D66 passes the
accepted revision into that refresh, accumulates successful card/run artifacts
and terminal attempts, stores current failed/cancelled attempts best effort,
and atomically replaces cards plus links only for a complete pass. An incomplete
pass keeps the prior cards, and a card persistence failure still cannot fail the
accepted transcript (D47/D65/D66).

D73 narrows the private processor adapter without changing that application
contract. `prepare` loads only the selected verified Whisper runtime. After
all required channel transcription succeeds, `diarize` joins or starts only
the pyannote task. ApplicationKit already treats that stage as degradable, so
an unavailable diarizer yields a reviewable unattributed draft rather than a
failed quality pass. The same per-capability coordinator keeps external-audio
Import independent from Parakeet and keeps durable transcript recovery
independent from pyannote.

D160 makes that runtime ownership explicit. Refine and Import retain the exact
engine returned during preparation together with a residency use lease, use it
for every channel, and end the lease at the application-owned release hook.
Neither workflow reads `AppServices.whisper` after an asynchronous boundary.

D67 makes app composition explicit for the first migrated egress vertical.
`RecordingController` and `CompanionRefresh` each inject IntegrationsKit's
`URLSessionDataEgressGateway` when assembling the optional Apuntador client.
The client exists only when endpoint/model/Keychain key and the persisted
Apuntador opt-in are present. Production generation supplies its source
`MeetingID`; the adapter validates content-free operation, an HTTP(S)-only exact
destination, conservative local-device/remote scope, question-only
classification, consent, and provider/model disclosure before URLSession. No
SwiftUI control or visible fallback changed.

D68 applies the same composition rule to every app-owned OpenAI-compatible
summary path. Meeting Detail regeneration, external-audio import, and the
durable post-capture worker construct Ollama providers only with an injected
`URLSessionDataEgressGateway` and persisted summary-engine Settings consent.
Each provider receives the real source `MeetingID`; the adapter validates full
summary-material classification, exact provider/model/destination, conservative
local/remote scope, and a non-empty POST before transport. Ollama summary calls
therefore cross the policy point as `local-device`, while health/model discovery
remains direct because it carries no meeting content.

D69 moves Meeting Detail's secret-Gist publication through the same composition
point. The view still requires the existing explicit off-device confirmation,
then constructs `GistPublisher` with `URLSessionDataEgressGateway` and passes the
selected meeting's real identity. The publisher declares the complete exported
meeting document, GitHub Gist destination, and explicit Gist consent before the
adapter can send. Request shape, secret-by-default behavior, response parsing,
and user-visible failure presentation remain unchanged. GitHub/Linear issue
publishing is CLI-only today and follows the parallel contract in spec 07.

D75 makes `AppServices.dataEgressGateway` the single store-receipted production
adapter for Apuntador, summaries, and Gist publication. The Store records the
validated content-free attempt before URLSession; a recorder error fails the
operation before transport. Meeting Detail receives a fourth independently
merged receipt stream and shows a compact right-rail card. Complete new history
without remote attempts or acknowledged sync reads “No remote service used”; an upgraded legacy
meeting shows the tracking start date; any remote attempt shows purpose, host,
and time plus the conservative warning that content may have left the Mac.
D115 adds the orthogonal journal disclosure: once iCloud acknowledges any text
generation, the headline becomes “No third-party service used” when applicable
and `detail-privacy-receipt-sync` states that encrypted fields in the user's
private iCloud database hold a copy. The copy remains disclosed after later
edits or pause. It never says end-to-end because that depends on the user's
Advanced Data Protection setting. Accessibility boundaries are
`detail-privacy-receipt`, `detail-privacy-receipt-sync`, and
`privacy-remote-event-<index>`. English and Spanish catalog entries preserve
the same evidence meaning. The sync element exposes its localized status as
the accessibility label and the complete encryption disclosure as its value,
so assistive technology receives the same evidence as the visual card.

D76/D123 compose one `ExportSupportDiagnostics` use case above StorageKit's atomic
support projection. `AppServices` contributes app/build/OS identity and
readiness for Parakeet, pyannote, Whisper, Foundation Models, MLX, and Ollama;
it contributes no endpoint, model secret, Keychain value, or meeting content.
Format 2 also carries current per-channel codec/health/duration/size/signal
shape and aggregate transcript channel/attribution counts. Neither layer reads
audio paths, checksums, text, speaker identities, or timestamps for that shape.
Settings → Your data exposes the explicit `settings-export-diagnostics`
action, writes the returned JSON through `NSSavePanel`, and confirms that the
file remains on the Mac unless the user chooses to share it. The app never
uploads the report. A deterministic temp-store destination lets XCUITest prove
the file was created and contains no seeded transcript.

The same slice adds processing as Meeting Detail's fifth independent update.
The right rail distinguishes pending/running local recovery, exhausted durable
jobs, and a `needsAttention` shell without a job. Exhausted work exposes one
`detail-retry-processing` action through the route-owned model; retry preserves
the job's identity/idempotency/input evidence and then kicks the normal worker.
A recoverable audio shell instead offers Refine, while a shell without audio
routes to support diagnostics. `OSSignposter` wraps durable execution with
job-kind, attempt, and outcome metadata only; it never records meeting/job IDs,
paths, provider secrets, or transcript material.

NOTES-001 adds the user's notes as Meeting Detail's sixth independent update.
`observeMeetingReviewNotes` projects the raw `contextItem` rows plus the
optional enhanced document over its own tracked regions, so a notes failure
degrades only the "My notes" section and never the transcript root. The
section renders the raw timestamped notes until an enhanced document exists,
then the document itself (`MarkdownText`, the user's words in bold per D135);
the header offers `detail-enhance-notes` — a language menu (plus the
alternative engine when one is truly available) that submits one
`EnhanceMeetingNotesRequest` through `services.enhanceMeetingNotes`, mirroring
regeneration's setup-issue mapping and reporting `.unchanged`/`.noNotes`
honestly inline. Generation stays view-side like summary regeneration; the raw
notes are never modified.

Native App Intents (D139): `openAppWhenRun` foregrounds the bundle that owns
`StartRecordingIntent`, which publishes a buffered process-local request
consumed by `PortavozAppDelegate`; it does not reopen the public
`portavoz://record` adapter through LaunchServices. Portavoz publishes no
`AppShortcutsProvider` on macOS: the unsupported automatic shortcut duplicated
the raw action in the picker, while reliable Spotlight and Siri invocation
already comes from a user-created Shortcut. The metadata Xcode would extract
during its build is produced out of band by
`scripts/build-appintents-metadata.sh` — a standalone compile of the SDK-only
`PortavozAppIntents.swift` under the shipping module name, then
`appintentsmetadataprocessor`, then `Metadata.appintents` into
`Contents/Resources` — and `make-app.sh` fails rather than ship without exactly
the native action and without automatic App Shortcuts.
The intents file's SDK-only import diet is pinned by
`ArchitectureDependencyTests`, because a project import would break the
release pipeline at packaging time instead of test time.

D77 keeps recording lifecycle error identity stable until presentation. Core's
`FailureCategory` and `CodedFailure` define the small shared taxonomy;
`ApplicationKit.StartRecordingFailure` and `StopRecordingFailure` classify the
exact workflow stage without transporting a dependency-localized description.
`RecordingController` maps each typed case to localized copy plus one recovery:
retry, return to the Library when durable audio exists, or open Your data for
local support diagnostics when state is uncertain. `RecordingView` shows the
stable code as selectable “Error reference” text and exposes identifiers for
the failure, reference, retry, Library, diagnostics, and Back controls. The
`-simulate-recording-start-failure` fixture is accepted only with
`-use-temp-store`, so production launches cannot synthesize a failure.

Slice 2H moves durable Stop policy through `ApplicationKit.StopRecording`.
`RecordingController` still flushes `RecordingSession`, closes live feeds, and
maps typed outcomes into the same navigation/failure phases. The use case owns
publication/reservation reconciliation, provisional attribution and language,
transcript/no-audio recovery, atomic captured snapshot plus exact first-job
admission, worker kick, and recording-engine release through private filesystem
and lifecycle adapters plus `MeetingStore`. The durable worker still owns
diarization, optional summary, and terminal-aware Shortcut timing. At that
slice, recording start and launch recovery remained later extractions. D66 adds
retained successful Apuntador artifacts and terminal attempts completed before
Stop to the same captured snapshot; dismissed/deduplicated/no-card work creates
no orphaned success (D48/D66).

Slice 2I moves start policy through `ApplicationKit.StartRecording`.
`AppServices` composes private preference, filesystem, Store, and capture
runtime adapters. The use case owns once-sampled preferences, title/sequence,
atomic pre-source shell/asset reservation, source-start invocation,
staging/published evidence reconciliation, guarded discard or
`needsAttention`, and failure-time release. The private runtime owns preferred
mic fallback, call-safe raw input warm-up, meeting-app/global process-tap selection, concrete
`RecordingSession`, direct per-channel live Parakeet streams, and one
recording-scoped voiceprint future. `RecordingController` receives only live
callbacks and an opaque active session; it retains visual state, caption
filtering, live diarization, rolling summary, exact localized result mapping,
session Stop, and synchronous mic mute. Launch recovery remains the next Band
2 extraction (D49).

Slice 2K moves `.portavoz` import through
`ApplicationKit.ImportMeetingBundle`. `AppServices` invokes one use case,
requests Spotlight reconciliation only after success, and returns the fresh ID;
Library and app-delegate callers preserve their existing navigation order.
The private document adapter reads, decodes, and remaps through IntegrationsKit
on a detached utility task. Before files are created, ApplicationKit accepts
only unique canonical system/microphone attachments and m4a/caf/wav
extensions, clears any incoming machine-local directory, and coordinates a
staged audio directory with one full Store commit. The private file adapter
constructs only `Audio/<fresh-id>/<channel>.<extension>`, cleans partial writes,
and compensates a persistence failure without masking it. No interactive UI
control or localized copy changed (D51).

Slice 2L moves `.portavoz` export through
`ApplicationKit.ExportMeetingBundle`. Meeting Detail now submits only the
meeting ID and audio opt-in, then maps returned bytes to its existing
`ExportDocument`. The use case owns a read-consistent aggregate, clears the
machine-local path, and assembles a format-neutral document. Private app
adapters resolve the configured/fallback recordings root, load only available
system/microphone m4a/caf/wav channels, and map to IntegrationsKit format v1.
Complete audio reads and JSON/base64 encoding run in detached utility tasks.
The native file exporter, title-based filename, UTI, dismissal state, and
localized failure alert are unchanged (D52).

Slice 2M gives each `ContentView` window one `@MainActor` `@Observable`
`LibraryModel`. Its private-write value `State` snapshot plus enum
`Action`/`Effect` contracts own complete/empty/degraded/failed loading, version-
fenced reloads, debounced and query-fenced FTS, meetings/voice mixes/open items,
rename and mutation outcomes, trash, import progress/errors, calendar agenda,
on-demand briefs, and navigation effects. `LibraryView` and `TrashSection`
render the snapshot, retain native AppKit panels and SwiftUI presentation, and
send actions instead of invoking Store, lifecycle, import, or EventKit-backed
services. `ContentView` creates a fresh model per `WindowGroup` instance, so
transient search/rename/import state is not global. The sidebar's native List
binds only to meeting routes: transient `nil` writes and non-meeting routes are
ignored, while tagged meeting/search rows retain native selection and deletion
updates the broader route explicitly. This keeps Meeting Detail, Ask, Insights,
and Recording stable through feedback writes and independent Library refreshes
without sacrificing native sidebar selection during row rebuilds.

Slice 2N replaces the temporary Library read seam. ApplicationKit defines the
storage-independent meeting-row/voice-mix, open-item, trash, search, section,
and update types consumed by `LibraryModel`; the model and Library views no
longer import StorageKit. `AppServices+Library` maps and merges independent
Store observations for meeting rows/voice mix, open items, and trash, while
active FTS remains its own debounced query stream. A failed section preserves
the most recent healthy data and degrades the load phase without stopping the
other observations. Search continues to fence stale queries and now also
updates while the same query remains active. Library no longer reads
`libraryVersion`; at that slice mutation adapters still incremented it for
Meeting Detail, Insights, and Spotlight until those consumers migrated. D85
later removed the counter after Spotlight gained its process owner. No
visible control, navigation behavior, or localized copy changed (D54).

Slice 2O moves the deterministic meeting-review policy cluster into
ApplicationKit. `ChapterExtractor`, `PlaybackRanges`, `SummarySections`, and
`VoiceHue` retain their exact public APIs and algorithms; Meeting Detail,
Insights, recording captions, and `PVDesign` now consume them through the
inward application boundary. The move adds no capability dependency, schema,
control, or localized copy. Eighteen direct policy tests plus a source-ownership
and consumer-import architecture rule guard the boundary (D55).

Slice 2P moves the deterministic Insights read-policy cluster into
ApplicationKit. `InsightsScope`, `LibraryStats`, and `InsightsFindings` retain
their exact public APIs and calculations; `InsightsView` now imports only the
inward boundary for those decisions. Store-backed facts, voice balance, and the
then-existing broad refresh were unchanged. Twenty-one direct policy tests,
a source-ownership/import architecture rule, and the retained heatmap screenshot
guard behavior and the visible dashboard (D56).

Slice 2Q completes the local product-policy move. ApplicationKit owns
`BriefRelevance`, `ReminderPolicy`, and `MirrorStats`; PortavozCore owns the
calendar-neutral `UpcomingEvent`; and IntegrationsKit retains EventKit access
and mapping plus RAG/external adapters. Brief ranking and visible reasons,
lead-window/session-deduplicated reminders, and the mirror's qualification plus
bilingual factual synthesis are unchanged. Fourteen direct policy tests and an
eighteenth architecture rule guard the split. The disposable UI fixture can
mark the seed as freshly recorded, opt into the mirror, assert `mirror-card`,
and retain app-window evidence without capture hardware or user data (D57).

Slice 2R gives Insights one per-window read owner. `ContentView` stores an
`@MainActor @Observable InsightsModel`; `InsightsView` receives that model and
restarts its observation only when the selected `InsightsScope` changes. The
model samples one reference date, merges meetings, participant/commitment
facts, voice balance, and scope-bounded finding updates, rejects stale
observation IDs, preserves healthy sections after a source failure, and
computes one storage-independent `InsightsReadModel`. `AppServices+Insights`
maps the four Store streams at composition. The view no longer imports
StorageKit, calls `services.store`, or reads `libraryVersion`; Meeting Detail
and Spotlight retained the broad compatibility counter at that slice (D58),
before D59 and D85 removed the final consumers.

Slice 2S gives each selected meeting one read owner. `MeetingDetailView` owns
an `@MainActor @Observable MeetingDetailModel` for the route identity and
renders one storage-independent `MeetingReviewReadModel`. The model merges
independent transcript/cast, newest cross-recipe summary/action-item, Apuntador,
privacy-receipt, and durable-processing streams; distinguishes missing from failed state; rejects stale
observation instances; and preserves healthy sections after a partial failure.
`AppServices+MeetingDetail` maps the five StorageKit streams at composition.
The view no longer performs sequential detail/Apuntador/summary reads or keys
its task to `libraryVersion`; player loading, two-column review, chapters,
newest summary, exports, and visible errors remain unchanged. Accepted Refine
regenerates from the accepted draft's speakers/segments, avoiding a race with
observation delivery (D59).

Slice 2T routes Meeting Detail persistence through the same route-owned model.
Explicit actions/effects cover title and speaker rename, name/voice suggestion
acceptance, action-item completion, Apuntador removal, meeting deletion, and
searchable-content changes. `AppServices+MeetingDetail` adapts Store, the
ApplicationKit lifecycle use case, and the Spotlight reconciliation request;
`MeetingDetailView` reaches none of them directly. The model preserves silent
best-effort operations, visible manual-rename/Apuntador errors, explicit
remember-voice consent, and delete navigation. Scoped observations, not
optimistic duplicate arrays, return post-write state. The adapter maps the
stale-refine persistence error before presentation. The remaining playback
path helpers later moved behind the D112 application audio workflows. SwiftUI
no longer imports StorageKit or AudioPlaybackKit for Meeting Detail playback,
compression, or clip export. Voice-memory extraction uses its separate app
adapter and application workflow (D105).

Band 6C3 applies the same scoped-state rule to the resident menu-bar scene.
`MenuBarContent` owns one `@MainActor @Observable MenuBarModel` and renders only
its private-write value snapshot. ApplicationKit defines recent-meeting,
pending-count, section, and update contracts without StorageKit. A private app
adapter merges a three-row live-meeting observation with the independently
scoped latest-open-item observation and keeps `CalendarAttendeeSource` outside
SwiftUI. Meeting-root writes refresh recents; latest-summary/action completion
refreshes pending badges; delete/restore remains live-rooted. If either query
fails, the other section and its last healthy state remain visible. The panel's
record/dictate/ask commands, no-prompt calendar rule, ordering, relative dates,
launch-at-login control, and layout are unchanged (D98).

Band 5F keeps Apuntador provenance inside that scoped read model without
conflating the question with the answer. Each evidenced card renders one
localized **Question source** control and zero or more ordered **Answer
sources**. The former identifies the exact transcript turn that produced the
question or directed ping; the latter appears only for context answers and
follows exact local-RAG citations. Selecting either role focuses the cited
transcript row and seeks the shared player without autoplay. Stale or
physically unavailable evidence remains explicit instead of navigating to a
nearby guess. Stable card/role/index accessibility identifiers make both paths
deterministic under XCUITest (D91).

**Idle release (Jul 2026)**: engines do NOT stay resident forever. Generation pattern (new use cancels scheduled release): `scheduleWhisperRelease()` (120 s after refine/import; Whisper weighs 1.6 GB) and `scheduleRecordingEnginesRelease()` (600 s after stop/refine/import; doesn't trigger if refine is running or a speech-model load is in flight). `ApplicationKit.RefineMeeting` schedules both policies on every success, failure, or cancellation after model ownership begins; its processor and Import end their pinned Whisper use leases before arming the timer. `ApplicationKit.StartRecording` schedules the recording-engine policy after every failed mic/channel/reservation/source-start attempt, while a successful audio-first start either transfers a resident live-speech lease to the attacher or starts one shared cold load after capture is active; `ApplicationKit.StopRecording` schedules the policy after every accepted Stop request outcome without waiting for that load, and the recovery worker refreshes it after publishing. `AppServices+MLXModels` does the same with the AppServices-owned Qwen3.5 runtime (2.4 GB resident measured) at 120 s. Consumers NEVER trust a shared reference after a long await: durable first-pass recovery, dictation, onboarding, and benchmark work hold the exact live-speech lease they acquired; Refine and Import hold their exact Whisper lease; durable attribution and Import still request the degradable diarizer through its current owner. A cold live-speech load that completes after Stop cannot attach to the inactive session and immediately finishes its lease. Note measurement (bench by phases): CoreML weights are file-backed and macOS reclaims them only when no longer used — post-stop footprint drops to ~160 MB without help; explicit release guarantees floor (~140 MB) and releases non-purgeable state.

## Design system in app (Jul 2026) — tokens + voices B + accent

Font: `docs/design/ds/` (authored in Claude Design, pine project). (1) `PVDesign` (app): Swift mirror of `tokens/*.css` — spacing 12/16/24, radios 8/10/12/14, tints 0.14/0.08, brand amber/violet/slate. When a value changes in the DS, it changes THERE and nowhere else. (2) **Voice B direction «el color ES la voz»**: `VoiceHue.index` (ApplicationKit, pure, FNV-1a — Swift hashValue is randomized by launch and DOESN'T work; 3 tests) assigns stable hue: named by hash of normalized name (same person = same color in all meetings), S-labels by appearance order; `VoicePalette` (app) maps to DS light/dark colors. Applied in: SpeakerPill (Me = solid amber + amber-contrast text; others hue 0.26), MeetingHealth bars (0.85), transcript pills, mic channel of waveform player (amber) and live recording labels. Indigo reserved for interaction (chips ✦, links, selection). (3) **App accent**: `assets/Assets.xcassets/AccentColor` (indigo #5856D6/#5E5CE6) compiled with `xcrun actool` in make-app.sh + `NSAccentColorName` — resolves system-accent debt for multicolor users (macOS gives priority to user who chose explicit color). **DS batch Jul 11 (2nd night — pull 9f11623 + implementation)**: (1) **Icon «La P que habla»**: assets/AppIcon.icns regenerated from DS SVG — the P is Fraunces (NOT installed locally): rendered in browser with Google Fonts via `scripts/icon-p.html` (canvas 1024, macOS grid: square 824 + radius 185) and `scripts/make-icns.sh` builds .icns; menu bar = `assets/icon/pv-menubar-32.png` pre-rendered as NSImage template (MenuBarIcon.swift) — the P adapts to appearance; recording follows record.circle.fill red (the «asta que pulsa» of DS remains flourish web). scripts/make-icon.swift (old icon) removed. (2) **Chips by evidence** (tokens --chip-* new): ChipLabel.swift (ai/voice/offer) + dynamic light/dark tokens in PVDesign (NSColor(name:dynamicProvider:)) — AI = violet tint + spark ✦ AMBER, voice = cyan + waveform, offer = neutral; applied to suggested title, S→name, voice matches, «Summarize as X?» and voice reminder offer. CONTROLS ✦ (Suggest names) follow indigo — deliberate distinction suggestion≠button. (3) **Settings 2a**: NavigationSplitView with 7 categories (SettingsCategories.swift) + search (.searchable filters by title and keyword bags EN/ES — ES live in catalog because EnglishSourceTests scans strings in code) + banner «100% local» → ledger; LedgerSection = real numbers (du of recordings root in Task.detached, count of meetings, enrolled+recorded voices) + honesty line of what actually goes out. gitHubSection extracted to GitHubSection.swift (file_length 700). (4) **Live lyrics 4a**: captionRow with colored voice pills (hash of label — S1/S2 stable, names = canonical hue), active line .title3, YOUR card in amber (me 0.12 + ring 0.35); FocusedTranscriptView already had fade/shrink/blur cylinder. **DS batch Jul 11 (3rd — pull 35264fb: Settings/Menubar/Dictation.jsx + menu bar implementation + mix)**: (1) **Menu bar 2b**: MenuBarContent rewritten as panel `.menuBarExtraStyle(.window)` (previously flat menu) — status header (mini waveform with amber/red peak when recording + a green local-first/opt-in-transfer policy), quick actions grid (Record red / Dictate indigo / Ask), next meeting card (only if calendar access — never prompt here) with «grabar al empezar» → route .recording(event), recent with relative dates, footer (Open / Launch at login / Quit). Panel closes only on focus loss (opening window closes it). (2) **Voice mix in sidebar** (kit signature): `MeetingStore.voiceMixes(for:)` (StorageKit) — ONE added query that sums segment durations by (meeting, speaker), normalizes to assigned voice of each meeting and returns ordered slices by talk-time (isMe/displayName/fraction/order); 3 tests (fractions sum to 1 + order, empty input, meeting without attributed speech absent). `VoiceMixBar` under each meeting row colors each slice with `VoicePalette.color(for slice:)` — amber = you, stable hue by name, order for S-labels. Meetings without attributed segments simply don't show bar (honest).

**Catch me up (Jul 2026)**: a standing pull control in the recording bar (`recording-catch-up`) on EVERY platform. On macOS 26 with the on-device model available it renders a 2-4 bullet recap of the last five minutes of CLOSED captions (`CatchUpPolicy.clip` — window and minimum rows pinned by tests; the growing coalescer row is excluded) via `FoundationModelSummaryProvider.catchUp` at interactive priority with the injection guard; the formatted clip keeps its TAIL when over budget because newest speech wins. On Sequoia or without Apple Intelligence the same button answers with the honest capability explanation — visible and truthful, never a hidden control. The card (`recording-catch-up-panel`) never persists anywhere; dismiss cancels any in-flight generation, and Stop synchronously cancels and clears the ephemeral card before capture crosses the durable boundary.

**Objectives with live check-off (APUN-003/D134, Jul 2026)**: `RecordingObjectivesModel` owns the checklist (`recording-objectives-panel`, add via `recording-objective-field`/`recording-objective-add`); adding trims and de-duplicates case-insensitively, manual toggling is always available and clears the model mark. The AUTOMATIC pass rides the signal-driven live-summary cycle behind the Apuntador opt-in: `ObjectiveCheckPolicy` (pure, tested) clips a 150-second window of closed rows and only runs with pending objectives plus enough conversation; `ObjectiveCheckDetector` (few-shot, `.background`, greedy) returns addressed indexes through a deterministic gate — out-of-range indexes drop, doubt leaves objectives pending, announced-but-not-discussed is explicitly NOT covered, and the model can never uncheck. At Stop the objectives join `contextItems` as `ContextItem.Kind.objective` rows ("✓ " prefix + check-off timestamp for covered ones), so the D28 notes block reports coverage to every summary without any schema change. Brief seeding is deferred (the `MeetingBrief` dies at the recording route boundary today).

**Next question + talk balance (APUN-004/D134/D174, Jul 2026)**: `RecordingNextQuestionModel` is the exact catch-up sibling (`recording-next-question` button, `recording-next-question-panel` card): pull-based, `.interactive`, capability-honest, stale-fenced on every exit, dismissed synchronously at Stop; its prompt carries the still-open objectives so a suggestion can steer back to them, and `PromptFactory.nextQuestionInstructions` pins one-or-two grounded questions, no filler. The talk-balance cue (`recording-talk-balance`, next to the mic meter) is `LiveTalkTimePolicy` — pure channel math over closed rows in a five-minute window, no model call, so it does NOT ride the Apuntador opt-in; it evaluates at most 1,024 closed candidates before the time filter, renders only once closed captions exist, and shifts to amber emphasis only past 60 seconds of attributed speech and a two-thirds share, with the exact percentage in accessibility value and help.

**Dictation 4b (pull DS 4 — Jul 11)**: the dictation strip gains the three traits of exploration 4b. (1) **Visible target chip**: `DictationController.targetApp` = `NSWorkspace.frontmostApplication.localizedName` captured in `start()` BEFORE showing non-activating panel (frontmost still is destination app); strip shows `✎ <app>` — never dictate «a ciegas». (2) **Partial in gray**: `confirmedText` in `.primary` + `partialText` in `.tertiary` concatenated (previously joined into one string) — volatility shown in gray and affirmed on confirmation. (3) **Inserted state**: new `Phase.inserted(Int)` — after `TextInserter.insert`, strip shows «N palabras insertadas en <app> — nada se guardó» for 1.6 s before closing (previously closed abruptly). Privacy ledger does NOT adopt the mock DS tile «0 B a la red»: would be an unmeasurable metric (no network log); real LedgerSection says what CAN go out (gists, external model, update check) — more honest («Measured, not promised»).

**Real DS features (Jul 12 — «construyelas»): chapters + only-my-voice + summary tabs + menu-bar pending.** (1) **Summary tabs** (MeetingDetailView): SummarySections (ApplicationKit, pure, 3 tests) splits markdown by headers `## ` (language-agnostic) → intro + sections with bullet count; tab bar Summary/«Heading·N»/«To-dos·done/total» (active tab indigo filters). (2) **✦ Chapters** (chaptersSection): ChapterExtractor (ApplicationKit, pure, 6 tests) derives chapters LOCAL from transcript — boundary by pause ≥10s (with minimum spacing of 120s to avoid over-segmenting spaced seeds) or length ≥300s; label = first real sentence of chapter, with fallback search limited to that same chapter; ≤1 chapter → hidden rail. Rendered after MeetingHealth, click seeks+plays (disabled without audio). (3) **Only my voice** (MeetingPlayer + MeetingPlayerBar): `onlyMyVoice` + `nonVoiceRanges` — time-observer skips non-voice ranges like skipSilence; PlaybackRanges.complement (ApplicationKit, pure, 6 tests) computes complement of .microphone channel ranges within [0,duration] (merge with padding 0.25s); amber-tinted toggle in player bar. (4) **Pending menu bar**: recent shows «✦ N» = openActionItems grouped by meetingID. **2-column layout of detail (Jul 12)**: DONE. loadedBody: header + speakers + refineStatus full-width, then HStack(alignment:.top) — left VStack (summaryOrGenerate + transcriptSection with player, maxWidth infinity) + `detailRail` right (width 260: MeetingHealthView + chaptersSection + Apuntador persisted). Rail has own scroll and is HIDDEN entirely if no content (doesn't leave 260pt gap). maxWidth of content bumped to 1060. Matches MeetingDetail.jsx from DS.

**Pixel-perfect refinement (Jul 12 — user feedback: app fell short vs DS)**: (1) **Settings** (SettingsSidebar.swift): native one-line nav becomes custom — icon + title + single-line subtitle per category (SettingsCategory.subtitle), selection with indigo→violet gradient, own search field and green «Todo local» badge below, over AuroraSidebarBackground. LedgerSection: 3 rows → 4 tiles (allocated audio/live meetings/opt-in network policy/encrypted voices); exact local metrics come from D101 and the network tile makes no synthetic byte claim. (2) **Insights** (InsightsView): Swift Charts bar chart replaced by rhythm HEATMAP — LibraryStats.heatmap[week][day] (pure grid, 2 tests) rendered as 12 columns × 7 rows of day with relative indigo intensity to peak; meetings tile gains mini-waveform amber + real week-over-week delta. NO «hallazgos ✦» (no engine, no invention). (3) **Library sidebar** (LibraryView): «New recording» = gradient indigo→violet pill + mini-waveform (amber peak); Import/Ask/Insights = 3 vertical icon+label chips grid; search with keycap ⌘K; footer «100% local — nada sale de tu Mac» with green dot. `accessibilityIdentifier` preserved for XCUITest. **Refinement 2 (Jul 12 — DS screenshots): sidebar timeline + indigo selection + buttons under title.** (1) **MeetingDetail**: the 3 action buttons (refine/export/delete) MOVE from `.toolbar` (top-right) to a ROUND BUTTON ROW under title (actionRow/roundButton) — export tinted accent, delete red; matches DS (buttons live with meeting, not window chrome). (2) **Library sidebar timeline**: meetings grouped by recency (meetingGroups: Today/This week/Last week/Earlier, empty buckets dropped) instead of flat «Meetings». (3) **Indigo selection**: `.tint` does NOT override native sidebar highlight (which follows user's system accent — green on their Mac); solution: `.listRowBackground` with indigo→violet gradient when `route == .meeting(id)` + white text, which beats native highlight. Helpers moved to `extension LibraryView` (type_body_length). Menu bar and detail tabs/chapters/player-chips: DONE (see below).

**Recording 4a (Jul 12)**: RecordingView restructured to DS mockup. `RecordingToolbar` owns the live command surface and uses `ViewThatFits`: a wide window keeps red dot + single-line 24 pt timer + compact mic meter, Translate, Apuntador, HUD, and **Stop red** in one row; the 900 pt minimum window switches to two rows, pins Stop beside the timer, and uses icon-only secondary actions instead of clipping or wrapping the clock. The component boundary keeps rendering policy separate from `RecordingView`'s session-state composition. The meter publishes at most 20 Hz inside its own observation boundary, while low-mic and missing-system-audio flags publish only on transitions. Caption projection owns a separate bounded observation boundary, so audio chunks do not rebuild translation, Apuntador, notes, and window controls. `recording-elapsed-time` and `recording-stop` are geometry-checked by the external-recording XCUITest. SINGLE column (previously two): live captions (`maxHeight:.infinity`) + ScrollView bounded (260) with companion cards + notes + live summary. `micLowBanner` is separate (only when level is low). Translations render as labeled indigo rails under their spoken row; amber remains reserved for the user's voice.

**Recording/review polish (Jul 14)**: local mic mute in bar (zeros aligned, doesn't control call); floating HUD that grows with current utterance and returns to compact on speaker change/pause; unlimited Apuntador cards newest-first, persisted and reviewable; refine re-derives them; chapter titles with Foundation Models and literal fallback bounded to chapter. `MeetingDetailView` invalidates player/waveform and discards canceled loads when switching meetings so nothing from previous detail leaks into next.

**Aurora shell (Jul 2026)**: `Aurora.swift` — the `--aurora-*` doses of tokens, ONLY in dark appearance (icon world is dark; light stays native). `AuroraDetailBackground` (detail pane, wired in ContentView): 140° gradient #1C1A2E→#262626 + elliptical radial violet with center OUTSIDE screen (x=20%, y=-104pt, 1400×520) — only glow tail touches content; GeometryReader with `ignoresSafeArea` to bleed under toolbar and `.clipped()` to not spill over sidebar. `AuroraSidebarBackground`: brandSlate 0.6 over native vibrancy (deep glass, desktop breathes). Detail views are ScrollView with quaternary translucent fills — gradient breathes through cards without touching them. `--aurora-selection` NOT adopted: macOS draws sidebar selection natively and repainting fights platform.

**Unified accent (same batch)**: `PVDesign.accent = Color.indigo` (system indigo IS exactly the DS hex, adaptive). ALL usage of `Color.accentColor` in app target swept to `PVDesign.accent` — `Color.accentColor` follows user's system accent (not root `.tint`), and produced green/indigo mixes in same view when user has explicit accent. Root `.tint(.indigo)` also reads `PVDesign.accent`. What macOS paints natively (list selection, focus rings) follows user — correct platform behavior.

## Palette ⌘K «Pregúntale a tu semana» (Jul 2026 — design system 6a-1)

`CommandPaletteController` is process-scoped in `AppServices` and works with
the main window closed. Its borderless 620 pt `NSPanel` remains a real key
window for text input, closes on key loss, and has a stable window identifier
for app-only visual evidence. ⌘K is registered through `CommandGroup`, so it
also works without a main window. `CommandPaletteModel` owns query, instant
results, answer state, search/answer tasks, and a generation fence; every close
or new query cancels old work, so a result from a prior panel cannot publish
into a later invocation. `AskModel` separately owns the full Ask route's draft,
conversation, progress, and answer task for one main window.

Both surfaces use `ApplicationKit.AskMeetings`. Typing requests up to six FTS
results with snippet, title, and timestamp; Enter requests hybrid local evidence
and an optional on-device answer. Missing generation degrades to complete
evidence rather than losing citations. Citation controls pass storage-
independent identity and time to composition, then set the one-shot,
meeting-scoped detail seek; the palette reopens a main window only when none is
visible. ⌘C copies the
answer and citations through `ApplicationKit.AskMarkdown`. The views and panel
import no StorageKit, IntegrationsKit, or IntelligenceKit. Disposable bilingual
UI coverage verifies the full Ask answer, instant palette results, generated
answer, app-panel-only screenshot, and exact three-second citation seek (D100).

## Insights (Jul 2026) — library dashboard

`Route.insights` (button in sidebar): tiles (meetings, hours, average duration, weekly streak, most active day), a 12-week × 7-day rhythm heatmap with zero weeks retained, frequent people, pending gauge, and local findings. ApplicationKit owns `InsightsScope`, `LibraryStats`, `InsightsFindings`, and the complete storage-independent `InsightsReadModel`; calculations inject calendar/now. A per-window `InsightsModel` combines four app-mapped Store observations: live meeting chronology, participant/commitment facts, voice balance, and finding evidence for at most the 60 newest live meetings in the selected scope. Meetings without `endedAt` count but do not drag the average; no-decision findings require summarized evidence, and recurring topics exclude participant names. Everything remains 100% local. Writes refresh only the query families whose explicit base-table regions changed; scope changes restart the bounded finding observation without a process-wide reload.

## Resident menu bar (Jul 2026)

`MenuBarExtra(isInserted:)` bound to `@AppStorage("menuBarEnabled")` (toggle in Settings → Menu bar, on by default): template icon `waveform.and.mic` that changes to `record.circle.fill` while recording — the "¿estoy grabando?" at a glance. Menu: Start/Stop (Start opens window via `openWindow(id: "main")` + `pendingRoute = .recording(nil)`; Stop calls shared controller), Dictate (only with dictation enabled), Open Portavoz, Launch at login (`SMAppService.mainApp` — requires /Applications, which is the installation story), Quit. **Architectural precondition**: `RecordingController` moved from `@State` of RecordingView to `AppServices.recording` (shared) — view, HUD and menu bar observe THE SAME session and navigation never can orphan a recording (same fix as RefineService).

## Global dictation (Jul 2026)

**Hold-to-talk (Jul 2026)**: `GlobalHotkey` listens to kEventHotKeyPressed AND kEventHotKeyReleased (`GetEventKind` in same handler). Gesture without setting: a TAP (release < 0.5 s) preserves toggle; HOLD combination while speaking and release delivers at release — walkie-talkie. Verified E2E: hold of 2.5 s opens panel on press and closes only on release.

**Configurable hotkey (Jul 2026)**: `HotkeySetting` (keyCode + Carbon mask + label, AppStorage; default ⌥⌘D) + `HotkeyRecorder` in Settings (NSEvent local monitor captures next combo; Esc cancels; combos WITHOUT ⌘/⌥ rejected with beep — single letter as global hotkey would hijack typing). `syncHotkey` now always unregister-first so new combo applies live. Verified E2E: record ⌃⌥⌘M and trigger opens panel.
 — ⌥⌘D in any app

Surface validated by MacParakeet: global hotkey → speak → hotkey again → text written where cursor is. `GlobalHotkey` uses Carbon `RegisterEventHotKey` — the only API consuming the keystroke without Accessibility permission — and is registered from app initialization so it survives without a window. `DictationController` owns one process-scoped, UUID-fenced session: mic → Parakeet streaming with custom vocabulary → the shared `CaptionCoalescer`; no meeting, database row, or audio file is created. The non-activating `DictationPanel` shows live text and offers explicit cancellation.

`TextInserter` implements the fail-closed delivery boundary. It waits up to one second for all physical modifiers to lift and refuses delivery rather than posting a combined shortcut when they remain held or cancellation arrives. It then inspects the focused Accessibility element immediately before touching the clipboard: `AXSecureTextField`, lost trust, missing role, malformed values, and transient inspection errors all block insertion with localized feedback; an explicitly absent/unsupported subrole on an otherwise valid ordinary text control remains admissible. Only after that check does it snapshot every pasteboard representation it can actually capture, write the dictation, and post a complete layout-aware ⌘V pair. Clipboard-write or event-construction failure restores immediately. Successful delivery restores captured representations after 1.5 seconds only if `changeCount` still identifies Portavoz's write, preserving rich content without overwriting a clipboard manager.

Capture timing starts when the microphone stream actually opens, not when model preparation or the panel starts. A finish before readiness or before 0.75 seconds of real audio cancels silently; one owned 250 ms tail task preserves the last phoneme and suppresses duplicate finish gestures. Session cancellation closes the transcription feed immediately, stops local resources, fences stale state, and prevents later insertion. Audio feeding and peak calculation run off the main actor; only the meter mutation crosses back. A single cancellable failure-dismiss task prevents an older error from closing a restarted session. `DictationAssembler` joins confirmed plus partial text and requires lexical content, so punctuation-only noise never pastes. A pre-transcription VAD is deliberately absent because live Parakeet silence yields no segment; the batch-Whisper hallucination class is handled elsewhere. The Settings toggle remains off by default. Verified E2E: the hotkey triggers with the app in the background, the panel transcribes live audio, and final insertion works in the field.

**Mouse-button push-to-talk (Jul 2026)**: `MouseButtonPTT` owns one session `CGEventTap` over `otherMouseDown`/`otherMouseUp` that CONSUMES the configured button (the app under the cursor never sees the click) and passes every other button through; a tap disabled by timeout is always re-armed. CGEvent index 2+ is eligible — vendor-facing Button 3+ means middle click or an additional button — while indices 0/1 (left/right) can never become a trigger. Invalid persisted values normalize to Off. The tap needs the same Accessibility trust as the paste path: choosing a button prompts once, a denied/pending prompt leaves the keyboard trigger working, and returning from System Settings retries registration. Rebinding first cancels any mouse-owned capture so its consumed release cannot strand the session. `MousePTTGesture` (app input boundary, pure, 3 tests) is the decision table: press starts when idle and finishes a listening session whoever started it; release delivers only when the button itself started the session, so a stray release can never double-finish a hotkey session. There is no tap-vs-hold discriminator on the mouse — the capture minimum already cancels an accidental click. `MouseButtonRecorder` in Settings captures the next middle/additional-button click (`settings-dictation-mouse-recorder`; Esc cancels) with an explicit clear control; both mouse and keyboard recorders remove their local monitors when their Settings row disappears.

**Two-tier dictionary, filler filter, and constrained language (Jul 2026)**: `DictationTextRules` (TranscriptionKit, pure, 10 tests) is the deterministic tier — one non-cascading pass of user-defined whole-word, case-insensitive replacements applied longest-trigger-first with punctuation-aware lookaround boundaries (regex-metacharacter triggers like "c++" match literally; replacement strings including `$` and `\` stay literal). Matching is computed against the original text, so a preferred spelling can never become input to a later rule. The codec trims triggers, drops empty rules, and keeps the newest case-insensitive duplicate before the Settings list or matcher consumes it. A conservative bilingual hesitation-filler pass (only tokens meaningless in BOTH languages: um/uh/er/hmm/eh/ehm…, on by default via `dictationFillerFilter`) runs first and repairs seams (collapsed spaces, no space stranded before closing punctuation). The other tier remains the existing vocabulary prompt, which biases the model DURING transcription. Rules persist as one JSON string (`dictationReplacements`, codec in the same type) edited by `DictationDictionaryEditor` in Settings (quick-add row `settings-dictation-dict-add`; re-adding a trigger updates it instead of stacking an unreachable duplicate). Both passes run in `deliver` on the final dictation text only — meeting transcripts stay verbatim records. `dictationLanguage` constrains dictation to {es, en}: any stored value outside the pair means auto-detect (`settings-dictation-language`); the engine-level candidate-set restriction the strategy imagined does not exist in the Parakeet API, so "Automatic" delegates to the engine's multilingual detection.

## Views and flows

**LibraryView + LibraryModel**: `New recording` (⌘N), FTS search with snippets, **"To-dos" section** (open action items from ALL meetings; click navigates to the meeting), recency-grouped meetings with `Rename`/`Delete`, Recently Deleted restore/permanent purge, import progress/errors, and calendar briefs. The per-window model owns data, debounce, mutations, and effects through its narrow client; the SwiftUI views own rendering, native presentation, AppStorage disclosure state, file picking/drop acceptance, and route binding. Library and Meeting Detail deletion plus Recently Deleted restore/permanent purge still enter through ApplicationKit use cases; launch cleanup uses the same purge boundary for tombstones strictly older than 30 days. Existing controls, navigation, and degradable filesystem behavior remain while scoped observations update only their owning sections. `library-search-field` provides a stable automation boundary for the real FTS/model wiring. The query adapter expands a deterministic local English/Spanish meeting lexicon and StorageKit ORs complete language variants while keeping terms inside each variant conjunctive; `unicode61` folds Latin accents. Exact rows publish first. When Apple Latin embedding assets are already installed and capture is inactive, a shared ApplicationKit search actor appends bounded semantic paraphrase/cross-language hits without downloading assets or replacing exact rank (D145). Its backfill enters the same process coordinator as Ask, so repeated typing cannot start duplicate embedding work (D176). Launch, searchable mutations, and capture completion also wake one no-poll background owner that uses the same coordinator and installed assets (D178). Search rows publish their exact timestamp through the shared one-shot seek channel before routing. While capture is preparing, recording, or processing, the main action becomes identified `Return to recording`; browsing history cannot hide the live timer and Stop control or create a second session. UITests use `firstMatch` for to-dos because a meeting title also appears as the row caption.

**RecordingView + RecordingController** (full live pipeline):
1. `start`: `RecordingController` resets live visual state and sends callbacks
   to `ApplicationKit.StartRecording`. The use case samples settings, asks the
   private runtime to warm the mic while engines load, atomically calls
   `MeetingStore.beginRecording` for the `recording` shell and pending
   `<channel>.partial.caf` assets, then invokes source start. The runtime owns
   the concrete mic (+system tap on 14.4+), `RecordingSession`, bounded live
   feeds, and recording-scoped Parakeet attachment per channel; captions return through the callback to
   **CaptionCoalescer**. A no-file startup failure rolls back only the empty
   shell; staging or published evidence preserves it as `needsAttention`
   (D37/D49).
2. Live: captions in LazyVStack with **reader-owned live follow** (direct scroll pauses indefinitely; incoming rows preserve the reader position and remain fully sharp; only the identified "Jump to live" action resumes follow); **live voice pills** (S1/S2 — streaming diarization with dedicated instance + `LiveSpeakerLabeler`, spec 03: closed rows split/label by voice as each 10 s window arrives; the first child preserves the source ID, later children are fresh; "Ellos" while no coverage; "Me"→"Yo" via voiceprint); translation picker →es/→en (Translation framework, macOS 15+; only translates closed rows); **signal-driven rolling monotonic summary** (one 40-second-minimum coordinator; ≤32 oldest unseen closed rows and ≤6,000 characters per cycle → stack → collapse >6,000 characters → atomic render; never shrinks — `LiveSummaryPolicy`) using the independent summary-output policy, never the transcript hint. D120 callback health crosses the same application callback boundary: if remote frames stop while mic frames continue, the full view and compact HUD show a non-dismissible reconnecting warning, the tap rebuilds in place without stopping the microphone, and a recovered confirmation clears after five seconds. D123 promotes a localized Stop action only after two continuous stalled/recovering outage minutes because the call may have ended, but never stops capture automatically; a terminal tap failure instead tells the user to stop and start a new recording on both surfaces. D121 adds dynamic preparing/available/failure state: a cold model hot-attaches during the same recording, then enables captions and speaker hints without replaying an unbounded backlog. D131/D142 keep the live merged projection clean when speaker output returns through the mic: within a bounded twelve-row window, direct system/room speech replaces matching microphone bleed in either callback order; one-word and sequential acknowledgements remain, while overlapping exact two-word and contiguous rolling-edge copies are rejected. D174 makes the separate presentation-only projector own a 150-source-row tail before it forms readable paragraphs for microphone or stable same-voice rows, but never generic `Them`; raw IDs and downstream consumers remain unchanged, and the controller still retains the complete transcript through Stop. D133 keeps split lineage stable for Companion evidence, translation caches, and rolling-summary admission. Live translation exposes waiting, deliberate-download, unsupported-pair, and execution-failure states; the waiting banner yields to the terminal live-caption failure banner when captions cannot arrive, execution errors stay visible during the automatic retry backoff, and late framework responses are fenced to the task's full source-target pair. D128 resolves every closed row to an explicit source-target pair from persisted per-turn language or a conservative local fallback, leaves target-language and uncertain rows as spoken, never asks Apple Translation to auto-detect the source, scopes consent to the pair, and clears all target-dependent state on a picker change.
   On macOS 15+, SwiftUI scroll phases are the reader-intent signal. On the
   minimum macOS 14.4 runtime, a zero-size bridge inside the scroll document
   observes user-initiated live-scroll events only for its enclosing
   `NSScrollView`, including legacy mouse wheels without a start/end pair;
   programmatic recentering does not emit that signal. Unsupported translation
   lanes remain original-language handled passthrough, so later supported lanes
   continue while the banner reports partial support.
3. `stop`: flush and close writers → validate/hash/measure each CAF → atomically
   rename staging files without overwrite → one `installCapturedSnapshot`
   transaction for `captured` + finalized/missing assets + provisional live
   cast/transcript/context/Apuntador + the exact initial diarization job →
   enter `done` and open detail → process-scoped worker diarizes and atomically
   replaces the provisional cast → optional summary in the independently
   configured language → persist `ready`. The title (configurable
   `TitleTemplate`: `{date} {time} {seq} {weekday}`, ISO-first) is assigned at
   start, so sequence follows start order. `Meeting.language` is set only when
   all segments are homogeneous; mixed/unknown remains nil. Audio with no
   captions, a failed job admission, or later required-work failure remains
   discoverable as `needsAttention` rather than being deleted. A publication
   collision keeps its staging file and also becomes `needsAttention` for
   launch recovery. If the first full snapshot is rejected, D127 repeats it
   exactly once, then degrades through core live content, finalized audio plus
   durable transcription, and canonical needs-attention projections. Every
   accepted path keeps the meeting discoverable and never invents Companion
   provenance.

Normal Stop now uses the durable process path (D39–D43). The active Start
session owns one utility-priority voiceprint future after reservation and feeds
that same value to both live diarization and the exact initial operation. After files publish,
`installCapturedSnapshot(..., enqueue:)` atomically installs captured
assets/live transcript/notes/cards and that first job. Stop enters `done`
immediately after the commit and kicks `PostCaptureProcessingSupervisor`, so
the detail opens while attribution and optional summary continue. A failed job
insert rolls back the snapshot. `ApplicationKit.StopRecording`, not the view or
controller, owns D127's exact retry and bounded degradation ladder and never
deletes finalized audio.

Process launch creates `RecordingRecoveryCoordinator` outside the view
hierarchy. It seeds only the temp-store UI fixture and enters
`ApplicationKit.RecoverInterruptedMeetings`, which recovers expired leases,
filters non-ready meetings, rechecks live-capture activity per candidate, and
owns recovered-asset/lifecycle/failure policy. The private app filesystem
adapter scans configured and fallback roots and revalidates staging-only or
final-only CAF evidence off the main actor. Missing files are explicit;
staging plus final or duplicate-root evidence is preserved as
`capture.recovery.ambiguous` without overwrite or deletion. The coordinator
also repairs a stale content-bearing `recording` shell in one pass: it marks the
shell with canonical `capture.publication.failed`, installs only validated
asset evidence, and lets StorageKit derive `ready` when the existing transcript
and complete assets satisfy the aggregate invariant. It never replaces that
transcript or waits for a second launch (D127). The coordinator
maps typed issues to OSLog and one broad invalidation. Only after the awaited pass does `PostCaptureProcessingSupervisor` invoke
`ApplicationKit.ProcessPostCaptureJobs`. The workflow serially owns
transcription, diarization, and summary claims; lease heartbeats; exact input
fingerprints; cleanup, attribution, and dependency admission; provenance;
retry/cancellation outcomes; terminal action and engine-release timing; and
the next scheduled wake. `AppPostCaptureProcessingCapabilities` retains
recording-path resolution, filesystem checks, concrete Parakeet/pyannote and
summary-provider construction, language/vocabulary preferences, Shortcut
invocation, and idle engine release. The supervisor only coalesces kicks,
schedules the returned wake without polling, and maps content-free events to
telemetry. Optional initial summary-provider discovery runs only after recovery
and durable workflow resume, so a local Ollama probe cannot delay finalized
audio or transcript recovery. The user's post-meeting Shortcut runs after terminal
derived work, including
transcript-only completion when summary is unavailable; temp-store launches
suppress real host Shortcuts (D50).

Each actual durable summary model attempt begins only after the workflow has
validated its meeting, request, provider, and recomputed operation fingerprint.
Immediately before the provider call it snapshots content-free provider/model,
job ID/attempt, recipe, output-language, and transcript-revision metadata. Its
successful `GenerationRun` is required by `SummaryArtifact` and commits with the
summary/actions, job success, and lifecycle reconciliation under the existing
lease/revision fence. Post-attempt provider/publish failures are recorded as
failed runs; task cancellation, lease loss, and superseded input are cancelled
runs. Both are best effort so diagnostics cannot mask durable retry policy.
Provider unavailability and pre-attempt supersession create no run. The
temp-store processing fixture identifies its deterministic provider/model and
exercises this same production path in the durable-resume XCUITest (D63).

**MeetingDetailView**: header with editable title (pencil), editable speaker pills (capture values on tap — alert-dismiss niled state and rename was lost), chips "Sugerir nombres ✦" with evidence and independent dismiss controls, versioned summary with regenerate (explicit es/en choices persist in the new immutable snapshot), lazy transcript, checkable action items. Summary setup failures are typed: unavailable Apple, missing Ollama selection, missing MLX download, and local-engine failure open an actionable alert whose recovery button opens the native Settings scene at the exact Intelligence category instead of ending in a generic error (D72). The `Recording needs recovery` card states that finalized audio is safe and sends the user to `Refine saved audio`; Refine creates a reviewable draft and never replaces the current transcript until explicit Apply.
- **Summary sources (D87):** the overview tab renders compact localized
  timestamp buttons only when its typed claim matches the current transcript
  revision and every ordered segment link remains live. Selecting a source
  focuses that exact transcript row and seeks retained audio without starting
  playback; when waveform preparation is still running, the view retains the
  exact pending seek and applies it as soon as the player is ready. Text-only
  transcripts own a `ScrollViewReader` so the same action focuses without
  moving the header or summary. Revision mismatch shows a stale explanation;
  any missing/tombstoned/null link shows unavailable and exposes no partial
  jump. Stable source, transcript-row, and current-playhead accessibility
  identifiers protect the navigation in both app languages.
- **Claim review (D88):** beneath a current evidenced overview, direct
  Add/Edit correction and Mark unsupported controls keep the user's assessment
  visibly separate from generated Markdown. The correction sheet explains that
  text stays on this Mac unless the user explicitly exports a `.portavoz`
  bundle, enforces the 2,000-scalar bound, and saves through a
  `MeetingDetailModel` action/effect instead of touching StorageKit from the
  view. Clear removes the visible assessment and physically erases correction
  text while retaining its nonsensitive tombstone. Native selected state and
  distinct editor/status/value accessibility elements preserve keyboard,
  VoiceOver, and EN/ES XCUITest reachability.
- **Decision sources (D89):** when a rendered summary section owns typed
  decision evidence, each Markdown bullet remains visually intact and its
  compact source timestamps render directly beneath that bullet. The source
  uses the same revision/current/unavailable resolver and focus-without-autoplay
  behavior as the overview. Stable section/bullet/evidence accessibility IDs
  make the exact relationship testable without matching localized headings;
  sections without typed evidence keep the original whole-body renderer.
- **Action-item sources (D90):** each to-do keeps a separate immutable
  evidence aggregate keyed to its checkbox identity. Compact source timestamps
  render beneath the matching task and reuse the same revision,
  current/unavailable, transcript focus, and no-autoplay behavior as overview
  and decisions. Toggling completion does not move or rewrite the source.
  Stable task/evidence accessibility IDs keep this relationship testable in
  both app languages without matching generated task text.
- **Confirmed people (D86):** accepting a manual, transcript/calendar, or
  encrypted-voice name may surface a separate `person-remember-offer`; neither
  the name action nor its evidence auto-links a human. `MeetingDetailModel`
  first sends `findCanonicalPeople`. With no exact normalized candidates, the
  user's Remember click atomically creates a distinct person and links the
  observed non-user speaker. Any candidate opens a second confirmation dialog
  with one explicit existing-person choice per match plus “Create a separate
  person.” Successful links reconcile Spotlight and render a checkmark plus
  the localized “Linked to a remembered person” accessibility value. The
  app does not expose this action for `Me`, never couples it to VoiceGallery,
  and requires a new confirmation for fresh Refine speakers. Existing
  VoiceGallery checks run off MainActor; disposable UI launches treat that
  sensitive store as empty rather than reading the host file or Keychain.
- **Refine (D7/D35/D47/D73/D130 in-app)**: `ApplicationKit.RefineMeeting` prepares only required Whisper and re-transcribes retained non-silent channels (+vocabulary), then applies microphone noise/bleed filtering and requests only best-effort pyannote diarization; live Parakeet is never a prerequisite. `TranscriptLanguagePolicy.automatic` never supplies a complete-channel hint, even when previous aggregate metadata appears homogeneous, so every actor/segment keeps the language Whisper recognizes. The per-meeting "Re-transcribe in Spanish/English" choices are explicit fixed recovery operations, and neither stale meeting metadata, app UI, nor summary language is ever a transcript fallback. The use case returns a **DRAFT with comparison sheet** (segments/speakers/speech coverage/sample + red warning if it covers < 50% of current speech) and its source revision — **nothing is applied without "Apply"**. The running control becomes an explicit cancel action; cancellation leaves the current transcript untouched and does not permit a replacement heavy run until the old engine exits. `RefineService` is keyed by MeetingID outside the view hierarchy, so switching meetings does not lose a running pass or draft, and run IDs prevent stale completion from overwriting newer state. The app freezes the selected Whisper descriptor for the run and derives content evidence from finalized v6 checksums after a size check or by locally hashing legacy audio. One content-free composite transcript attempt covers every non-silent channel. On acceptance, `ApplyRefinedMeeting` atomically installs that successful run, links every new segment, installs homogeneous language (including `nil` for mixed/unknown), cast, transcript, and next revision; a stale/discarded draft creates no success record. Begun transcription failure/cancellation is standalone best-effort provenance. Apuntador refresh runs only afterward with the accepted revision. It derives per-turn language, creates exact card/run artifacts, persists current terminal attempts best effort, preserves prior cards on incomplete work, and replaces a complete snapshot plus links atomically; persistence failure warns without failing the transcript. Meeting Detail submits the accepted draft's exact speakers/segments to the existing `RegenerateSummary` use case under the independent current recipe/output policy, while scoped observations publish the committed transcript and preserve older immutable summaries. **Chip "Summary looks thin"** (`ThinSummaryPolicy`, pure): meeting ≥ 20 min with summary < 900 chars, or ≥ 40 min with 0 action items → offers regeneration with MLX in one click (only if MLX is downloaded and was not the generator; FM contract: suggestion, never automatic).
- **Share a recap** (FEATURE-003/D136): the first item of the export menu,
  enabled only with a summary. `ApplicationKit.RecapComposer` builds the
  draft purely from meeting, cast, and summary — it never receives transcript
  segments — and `MeetingRecapSheet` opens it for review: audience (everyone
  or one participant, whose own commitments lead), channel (email plain text,
  Slack mrkdwn, or Markdown), an editable subject and body, `recap-copy`, and
  a `ShareLink`. Picker changes never overwrite edited text; they are held
  until `recap-redraft`. Open commitments are re-rendered from the library's
  real done state with owners from the cast, and section labels follow the
  SUMMARY's language rather than the interface's. Nothing is sent from the
  sheet: no credential, no gateway, no egress event.
- Export (D105): Markdown / PDF (pure CoreText, compiles for iOS) / **Secret
  Gist** with explicit off-device confirmation and gateway-enforced
  meeting/document metadata. All three load one coherent meeting snapshot
  through ApplicationKit; SwiftUI does not render the canonical document, read
  the publishing credential, or construct the publisher/network gateway.

**SettingsView (⌘,)**: Language (use system language or force English/Spanish, saved in `@AppStorage("app-language")`, applies `\.locale` live to `ContentView` and `SettingsView`) · Intelligence language policies (`transcriptionLanguage`: "Auto-detect" / "English" / "Español" for recognition only; `summaryLanguage`: "Meeting language" / "English" / "Español" for generated output only) · capability-aware Summary engine selection whose localized recommendation action is prominent and whose unavailable Apple state names Ollama/MLX recovery · proactive Whisper Turbo/Compact rows with select/download/retry/delete, background preparation progress that says download occurs only when needed, stable `settings-whisper-*` accessibility identifiers, and full catalog-integrity verification before any model is shown as downloaded (D71/D113). Whisper artifacts live under user Application Support rather than either app bundle, so Dev reinstall and normal application updates preserve them · Audio (always-on call-safe raw capture status, preferred mic with visible fallback, capture mode auto/app/system and disclosure of scope; no VPIO/AEC recording toggle, D125) · Recordings (configurable folder with migration and progress) · Titles (template with help popover of tokens, insertable chips, `Reset` button, and live preview) · Vocabulary (list editor: Enter adds, − removes) · My voice (enroll 12 s / delete — destroys file+key) · Apuntador activation/status (enabled here or from recording only when the macOS 26 Apple classifier is available; Sequoia explains the requirement while retaining Mirror) · External model BYOK (endpoint/model in defaults, key through the async application secret boundary into this-device-only Keychain, answer-provider opt-in disabled until everything and the Apuntador classifier are available; deleting key turns it off — spec 04) · GitHub (same injected secret boundary) · explicit local redacted support export in Your data (`settings-export-diagnostics`, D76) · whole-library Markdown backup with the native `NSOpenPanel`, visible progress, localized complete/partial/fatal status, and no Store or IntegrationsKit coordination in SwiftUI (`settings-export-all-button`, `settings-backup-progress`, `settings-backup-status`, D99). A one-shot app route lets any feature open an existing or new Settings window at an exact category (D72). `AppServices` is the sole app constructor of `PlatformKit.KeychainSecretStore`, encrypted voice stores, and `MicrophonePermissionClient`; onboarding renders permission state and invokes app adapters rather than importing AVFoundation or EventKit.

## Verified in real world (Jul 2026)

Multiple real meetings retained audio and stable TCC permissions between
updates; a 30-minute recording survived a device change and a Refine incident
recovered without loss. The former VPIO/AEC path reduced speaker echo but later
interfered with real Sequoia and Tahoe calls; D125 replaces it with raw
call-safe capture, pending the explicit cross-OS A/B in `docs/GAPS.md`.

## Additional as-built note

**Audio-first Meeting Detail:** the synchronized player drives the
**Spotify-style lyrics transcript** (`FocusedTranscriptView`: the spoken line
stays centered in a fixed-height viewport while surrounding lines fade,
shrink, and blur; its explicit vertical/no-indicator initializer and built-in
vertical scroll-view coordinate space preserve the same behavior across the
supported Sequoia and latest SwiftUI SDK signatures without sharing a generic
named key with the visual-effect closure, and its fade/scale/blur values cross
`CGFloat`/`Double` boundaries explicitly),
click-to-jump, the channel-colored waveform scrubber, clip marks, skip-silence,
and microphone-only playback. `MeetingDetailModel` owns
one playback-preparation attempt per recording directory, cancellation retry,
compression state, session invalidation, and clip-export effects.
`ApplicationKit.PrepareMeetingPlayback` resolves current channels through an
injected port, constructs one `MeetingPlaybackSession`, derives the bounded
waveform off the main actor, and configures silence and microphone-turn ranges.
The app adapter owns the configured recording root and canonical channel-file
lookup. `AudioPlaybackKit` retains AVFoundation playback, Accelerate waveform
analysis, AAC encoding, and mixed-range export. SwiftUI owns the transport
controls, waveform drawing, and native save panel only. Compression operates
on every raw channel as one failure-safe batch: existing canonical outputs are
never replaced, generated outputs are removed on failure or cancellation, and
no original is removed until all outputs verify. A successful conversion
invalidates and rebuilds the session from current files. Without readable
audio, the healthy transcript remains a normal text-only list. The same
carousel also runs during live recording, but D129 gives it a separate visual
policy and reader-owned follow state: direct user scroll disables automatic
following indefinitely, browsing rows stay fully opaque/unscaled/unblurred,
and only `recording-jump-to-live` resumes the wider, gently bounded live focus
treatment. SwiftUI scroll phases detect reader intent on macOS 15+; the
minimum macOS 14.4 runtime uses a zero-size AppKit bridge inside the scroll
document that observes user-initiated live-scroll events only for its enclosing
`NSScrollView`, including legacy mouse wheels without a start/end pair.
Programmatic recentering does not claim reader intent. Audio
import remains the `ApplicationKit.ImportMeeting` path and preserves automatic
mixed-language recognition. `make test-ui` covers the player, highlight,
compression action, and clip-export button; preflight closes stale app
instances before XCUITest.

**Stateless waveform derivation (Band 4F/D84, Jul 2026):**
`Waveform.generate` reads the available microphone/system sources, partitions
their shared timeline into the requested bucket count, and computes each
range-aligned channel peak with Accelerate `vDSP_maxmgv`; the final bucket
consumes the exact remainder. It returns one normalized bucket sequence with
the dominant source but writes no cache or sidecar. On a copied real 55.9-minute
dual-channel CAF source, first wall/CPU is 109.25/94.81 ms and 20-run repeat p95
is 70.11/71.33 ms, down from 761.75/767.43 and 747.53/754.79 ms while preserving
the exact result fingerprint. Replacing the source changes the result without
an invalidation protocol. D84 therefore rejects a persisted cache at the
measured scale.


## Meeting Detail scale baseline (Band 4A, Jul 2026)

`AppServices+ScaleBenchmark` admits `-seed-scale` only together with
`-use-temp-store`. It creates one deterministic 2-hour meeting with 5,000
segments, four speakers, a versioned summary, no audio, and no model or user
preference access, then routes to the real Meeting Detail. The fixture skips
automatic chapter retitling so model work cannot contaminate a projection
baseline. An optional `-scale-auto-summary-update` writes summary revision 2
after three seconds through the normal scoped Store observation.

`MeetingDetailModel` starts the content-free `Meeting Detail First Content`
`OSSignposter` interval at model creation; the loaded view ends it once on its
first appearance. The signpost contains no meeting identity, title, transcript,
speaker, path, or generated text. `scripts/run-detail-ui-baseline.sh` refuses
the notarized `/Applications/Portavoz.app`, launches only Portavoz Dev with the
disposable fixture, and records Logging plus SwiftUI/Time Profiler/Hangs. The
tracked Xcode 26.6 result reaches content in 522.30 ms and reports one 515.86 ms
initial hang. Time Profiler captures 15,908 samples with Meeting Detail and
transcript symbols. The SwiftUI template emits `Trace file had no SwiftUI data`
and zero update rows on this toolchain, so exact view-body invalidation remains
unmeasured rather than being represented as zero (D79).

Band 4B reruns the same installed Dev fixture after changing only the pure
`MeetingHealth` scan. `docs/evidence/detail-ui-baseline-20260716-after-health.json`
records first content at 91.87 ms instead of 522.30 ms and zero potential hangs
instead of one 515.86 ms hang. Time Profiler remains populated; the Xcode 26.6
SwiftUI lane retains the same explicit no-data limitation. The detail now
passes its 300 ms budget without view decomposition, a cache, or broader state,
so D80 leaves those structures unchanged.

The 25th XCUITest waits for the 5,000-segment title, transcript, chapter rail,
and delayed summary revision 2, then retains the
`band-4a-scale-detail-5000-segments` app-window screenshot. This proves that
the scoped summary stream remains functional at scale; it does not substitute
for the unavailable SwiftUI update-cause lane.

## UI verification — XCUITest first (Jul 12)

`make test-ui` (XcodeGen → `Portavoz.xcodeproj` → `xcodebuild test`)
defines 55 XCUITest cases in `Tests/PortavozUITests`: Automation (the
production `portavoz://record` route enters a visible disposable recording
whose `app.portavoz.mac.uitest-host` identity cannot shadow either installed
app),
Library (record button +
chips + time grouping + full Ask and command-palette answer/citation paths +
interrupted staging recovery + durable post-capture resume + typed recording-
start recovery + visible system-callback recovery + reader-owned live-caption
history and explicit Jump to live), Insights (heatmap + interlocutors), Onboarding (first listen +
advance), MeetingDetail (summary tabs reveal ▸, typed overview/decision/action-item and role-separated Apuntador source transcript/audio navigation, explicit correction/unsupported/clear review, explicit confirmed-person
memory, SRT/WebVTT export-menu availability, newest-recipe reload, right
rail health+chapters, post-meeting mirror, processing failure/retry, player skip+only-my-voice, compression, clip export, refine cancel, Sequoia summary setup routing and Apuntador requirements), and Settings (all categories,
independent transcript/summary language controls, proactive clean-install
Whisper preparation, explicit iCloud sync opt-in/existing-library separation,
custom structures, capture
controls, redacted support export, readable whole-library Markdown backup,
mirror, and live language switch via ⌘,). Every launch receives a
unique disposable `PORTAVOZ_AUDIO_ROOT` in addition to `-use-temp-store`, so
neither SQLite, audio, nor the encrypted participant-voice gallery can touch
the user's library or Keychain. `-seed-recovery`,
`-seed-processing`, `-seed-refine-running`, `-seed-just-recorded`,
`-seed-scale` with optional `-scale-auto-summary-update`,
`-simulate-recording-start-failure`, `-simulate-system-capture-stall`, and
`-simulate-live-transcript-browsing`, and
`-seed-without-summary` are
accepted only with the temp
store. `-simulate-sequoia-capabilities` makes the Foundation Models adapter
deterministically unavailable without depending on the XCUITest host. The processing
fixture uses a deterministic fake local provider and no real audio, models,
biometric files, Keychain, or host Shortcut; it uses the normal exact request
factory and observes the original transcript and dependent summary after launch
resume. Seed-demo includes deterministic question and answer sources plus a
third segment at 200 s (mic channel) so there are two chapters and solo audio. Convention: all new
interactive controls carry `accessibilityIdentifier` (`area-cosa`) plus an
assertion in the corresponding `*UITests.swift`; computer-use is the last
resort. Feature-band evidence retains app-only screenshots at asserted
Library, the identified command-palette panel, Insights, Meeting Detail,
Apuntador evidence, confirmed-person memory, and post-meeting mirror checkpoints
so unrelated desktop content is never captured. `make test-ui-en` and
`make test-ui-es` use Xcode's explicit test language and region flags; the
complete 55-case suite remains the bilingual release gate. **Real bug caught
by XCUITest (not computer-use):**
`PlaybackRanges.complement` built an inverted `ClosedRange` (`200...6`) and
crashed when a voice segment started after audio duration; the fix clamps
before forming the range and has unit coverage.
