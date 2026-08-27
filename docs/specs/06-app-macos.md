# Spec 06 — macOS App (portavoz-app + packaging scripts)

Status: implemented, signed with Developer ID, and used in real meetings; public release 0.7.0 independently notarizes and staples both the app bundle and DMG. D74 keeps a clean-Sequoia Homebrew install as explicit field validation instead of treating notarization as launch proof. Decisions: D20 (SPM + script, no checked-in Xcode project), D23 (packaging), D10 (distribution), D40 (evidence-first launch recovery), D43 (atomic Stop handoff), D44–D60 (application workflow, feature-state ownership/mutations, scoped Library/Insights/Meeting Detail reads, and inward product/read policy), D61 (implemented package boundaries only), D62–D73 (atomic generated artifacts, enforced meeting-content data-egress verticals, audio-first and role-specific model readiness, app-scoped Whisper preparation, and capability-driven intelligence setup), D74 (independent app/DMG notarization evidence), D75 (store-receipted egress and Meeting Detail privacy receipt), D76 (redacted support export, processing recovery, and content-free signposts), D77 (typed recording failures and app-owned recovery), D78 (measured App Sandbox defer gate), D79–D85 (measured detail, retrieval, waveform, and Spotlight scale), D86 (explicit canonical people), D87 (typed overview evidence navigation), D88 (explicit local claim feedback), D89 (decision evidence navigation), D90 (action-item evidence navigation), D91 (role-separated Apuntador evidence navigation), D97 (provisioned opt-in CloudKit composition), D98 (resident menu-bar ownership), D99 (whole-library backup ownership), D100 (shared Ask workflow and presentation state), D101 (first-run, local-receipt, and meeting-preparation ownership), D102 (PlatformKit security/permission composition and executable read convergence), D104 (application-owned post-capture policy), D105 (application-owned review documents and participant voice memory), D106 (application-owned local voice enrollment), D107 (application-owned speaker-name admission), D108 (application-owned local-provider discovery), D109 (application-owned Settings device resources), D110 (application-owned pre-meeting reminder resolution), D111 (application-owned Meeting Detail metadata suggestions), D112 (application-owned Meeting Detail audio coordination), D113 (catalog-verified model readiness), D114 (executable dependency and presentation boundaries), D115 (honest private-iCloud receipt disclosure), D121 (bounded live-transcription hot attachment and explicit translation state), D123 (long-outage Stop affordance and capture-shape support evidence), D127 (audio-priority Stop recovery), D128 (explicit live-translation lanes), D129 (reader-owned live transcript position), D130 (unhinted automatic Refine), D131/D142 (bounded temporal live-caption bleed admission and view-only paragraphs), D132 (cast-grounded summary owners), D133 (stable split lineage), D135 (regenerable enhanced notes), D143 (deterministic bilingual Library search and exact hit seeks), D144 (reversible role-aware clear playback), D287/D302 (pure clear-playback volume schedule, ordered on the timescale it is delivered on), D145 (exact-first Library semantic augmentation), D157–D189 (pure resource policy, generation-fenced residency, one composition owner, pinned model-family leases, pressure-driven idle release, capture-exclusive Whisper/MLX admission, bounded persisted-level presentation, signal-driven bounded live translation, recording-scoped bounded live Apuntador generation, signal-driven bounded live-summary delivery, deterministic generated-intelligence admission, observational clipping evidence, policy-owned live-caption presentation bounds, route-cancellable bounded waveform delivery, one shared bounded semantic-indexing flight, capture-prioritized semantic checkpoints, signal-driven semantic maintenance, capture-safe existing-library sync admission, staged whole-library backup checkpoints, crash-safe stage ownership, bounded backup-destination identity, durable publication evidence, strict staged-source adoption, successful-publication source checkpoints, fail-closed pending-publication reconciliation, durable typed backup failure outcomes, and fail-closed launch continuation), D224–D234 (Meeting Detail decomposition, correction editing, derived-artifact lineage, correction-aware export, and protected private-sync convergence), D238 (source-bound commitment-review read foundation), D273 (signal-driven typed memory-graph projection), D319 (fail-closed database launch recovery), D331 (explicit correction-aware Apuntador refresh), D332 (explicit semantic asset preparation), D357 (fail-closed encrypted voice identity recovery), D384 (bounded progressive Ask UI), D385 (selected local-engine manual Ask), D386 (explicit Ask source UI and ownership), D387 (one-request direct-Web Ask UI), D388 (pull-based cited interview assistance), D389 (typed raw-note Ask UI).

D403 additionally owns exact-ID production-sync qualification packaging.
D190 distinguishes intentional cancellation from owner-leased worker death.
Additional decisions: D320 (structured First Listen and SpeechAnalyzer
lifetime), D321 (durable Skill retry identity and visible recovery), and D322
(event-scoped resident pre-meeting brief proposals), D323 (exact Reminder Draft
permission/effect), D324 (honest Start/Stop App Intents), and D325 (bounded App
Entities with exact reversible routes), and D326 (one availability-shaped
protected Spotlight generation).
D327 adds a review-first system email-composer handoff; D328 adds exact
one-shot secret-Gist publication with a pre-transport duplicate fence; D333
derives Skills privacy disclosure from the executable capability contract.
D373/D374 compose exact-Skill and rolling update-time activity filters at query
time while keeping the Settings window bounded and generation-fenced.
D384 makes full Ask latest-submission-wins, displays bounded cumulative answer
snapshots, caps per-window conversation retention, and uses an isolated Swift 6
deinitializer so a closed window cancels without unsafe actor access.
D385 late-binds manual Ask only after `AppServices` finishes initialization.
The router samples the current explicit local engine for each request and maps
the same exact citations into a provider-neutral grounded answer. Apple
Foundation Models remains macOS-26-only; configured loopback Ollama and a
verified embedded MLX installation work on Sequoia and Tahoe. MLX reuses the
single process-owned runtime and resource ledger. Duplicate router installation
is inert rather than process-fatal. Ask and the command palette share outcome
presentation: unavailable, failed, and timed-out generation have distinct
localized guidance while the exact passages stay navigable. Automatic live
Apuntador remains on its existing capability policy.
D386 gives the full Ask conversation an explicit Library / one Meeting / Web
source selector. Meeting selection comes from one bounded 20-row local catalog,
is never inferred, and is captured with each pending and completed exchange.
Oversized, duplicate-identity, or blank-title catalog responses fail closed.
Changing source or exact meeting cancels and generation-fences pending work.
Web never falls back to Library. The command palette stays visibly Library-only.
D387 makes that Web choice a direct-page surface. The question and URL fields
jointly authorize one toggle; editing either invalidates consent, submit consumes
it, and changing source cancels the in-flight request. Production presentation
accepts remote HTTPS only, while temporary-store real-app tests accept the
loopback fixture. That disposable identity installs a checksum-validated
canonical `URLProtocol` only when the Web journey explicitly forwards the
runner's public fixture payload; it opens no loopback listener, while the
package integration lane retains real HTTP coverage. Pending/completed Web
exchanges retain a host badge, direct links, observed date/freshness,
truncation, and typed source failures separately from meeting citations. Every
new control and evidence row has a stable
`ask-web-*` or `ask-*-source-web` accessibility identifier. The Web-specific
state, view, and client contracts are split from the bounded core Ask model;
window closure still cancels both meeting and Web work.
D388 adds **Interview** to the toolbar only while the visible recording surface
is active. Enabling it does not change capture; it exposes the exact current
system/room question and relabels the existing finite objectives panel. The
recording-scoped `RecordingInterviewAssistModel` owns question revision,
generation, typed unavailable/insufficient/failure/timeout presentation, and
cancellation. **Find grounded answer** is the only generation trigger. The
panel renders exact transcript citations with speaker role and timestamp, and
keeps the question/evidence readable when the selected local engine cannot
answer. Stable `recording-interview-*` identifiers cover the toggle, panel,
question, action, lifecycle states, answer, and numbered evidence. Stop and
recording reset disable the mode and clear all ephemeral answer state; nothing
is promoted to a user note or external action.
D389 adds **Notes** as a fourth explicit source in the full Ask
conversation. `AskModel` keeps pending and completed note citations in a
separate typed collection, cancels and generation-fences them on source or
question change, and never calls the transcript or Web client method. Pending
and final note rows display localized local authorship plus exact meeting and
offset, and select the owning meeting at that timestamp. The source status
discloses that only explicit local raw notes are searched and AI-enhanced notes
are excluded. Stable `ask-source-notes`, `ask-*-source-notes`,
`ask-pending-note-citation-*`, and `ask-note-citation-*` identifiers extend the
existing Ask journey without another app launch. Temporary-store composition
uses the production v45 FTS adapter and a delayed deterministic answerer;
production samples the same Foundation Models/Ollama/MLX resolver as other
manual Ask lanes without provider fallback.
D390 adds an independent per-recording **Proactive** toggle and pause/resume
control on every supported macOS version. `RecordingProactiveAssistModel` owns
only ephemeral enablement, deduplication, throttle, and inert cards produced by
the pure source-closed policy; it creates no model, Web, persistence, or effect
work.
D192 records closed Ask operation/stage/milestone/outcome values through one
content-free Points of Interest adapter.
D193 lets only the resource-benchmark process observe that same closed stream
and publish a strict content-free Ask pipeline sidecar per measured run.
D196 keeps product Ask corpus-read-only and moves disposable benchmark corpus
preparation outside the measured request.
D197 gives Ask and Library one typed semantic-readiness view and makes the
signal-driven supervisor the sole product corpus writer.
D198 prevents that writer from publishing across a concurrent transcript
correction, replacement, or deletion.
D199 requires one valid embedding compatibility profile before semantic
maintenance or reads and rebuilds incompatible derived vectors through the
existing `NULL` cursor.
D200 adds independent durable semantic-maintenance scheduling, bounded retry,
and lease-expiry relaunch recovery without changing meeting lifecycle.
D238 adds an independently observed, source-bound commitment-review projection
without adding a user-facing confirmation surface. D239 adopts that projection
as a separate evidence-first Meeting Detail confirmation surface routed through
one ApplicationKit use case and narrow repository.
D243 extends that same repository with an explicit source-link command. The app
composition adapter can append a later meeting's active evidence to an existing
open commitment without exposing StorageKit to presentation. No current SwiftUI
action invokes it. D244 adds only a pure Core suggestion policy; app target
loading, semantic-query composition, confirmation affordance, and chronology
presentation remain unimplemented. D245 adds a public review-only
quality pack. D246 adds a bounded, non-serving ApplicationKit observation
adapter over installed semantic assets and the existing query port, but the
`portavoz-app` composition root does not construct or invoke it. There is still
no scene state, SwiftUI affordance, automatic link, model download, or visible
commitment-link behavior.
D247 composes the observer only in the development CLI against per-case
scratch stores. It does not add an app service, menu command, background job,
SwiftUI state, model download, or user-library access, so macOS product
behavior remains unchanged.
D201 lets full Ask publish exact citations while semantic refinement and local
generation continue, with generation-fenced progress and cancellation.
D222 freezes Meeting Detail interactions and measured behavior before
decomposition. D223 makes `MeetingDetailScene` the sole route composition
owner. D224 extracts explicit header, trust, and generated-document sections
without giving child presentation types model, service, or store access. D225
adds one correction-ready transcript reading snapshot and extracts transcript
and chapter presentation without moving correction policy into SwiftUI. D226
extracts playback behind immutable values and explicit audio intents. D227
extracts secondary actions, the review rail, and Companion behind the same
boundary, then replaces unrelated modal booleans with scene-owned typed
presentation routes. D228 completes the decomposition with a short-lived
route-level effect coordinator, a modal host, focused notes and Refine review
sections, and one cross-section playback-navigation owner; the compact root
retains only route projection and observation lifecycle while the scene keeps
route and preference mutation. D229 adds the pure correction composer behind
the same ApplicationKit snapshot while keeping current Meeting Detail reads on
accepted content. D230 adds typed durable correction history behind that same
boundary without changing any visible Meeting Detail row, product consumer,
or correction-editing capability; private meeting aggregate v2 transports the
history without changing the accepted-only presentation policy. D231 adopts
current-revision text and speaker corrections only in Meeting Detail through
one focused, accessible editor with immutable original evidence, append-only
history, and durable Undo; every other transcript consumer remains
accepted-only. D232 adds explicit split, pairwise adjacent merge, hide-as-noise,
hidden evidence review, and durable restore to that same value/action boundary.
It does not let SwiftUI infer targets or mutate accepted transcript rows.
D233 carries the effective correction revision through the same application
snapshot. Meeting Detail marks older summaries and Apuntador cards stale,
disables their evidence as current proof, clears generated chapter/title/recipe
suggestions when the overlay changes, and offers an explicit summary Regenerate
action. Regeneration composes corrected rows and maps evidence back to immutable
accepted source IDs. The correction action itself starts no model or indexing
work, and the UI does not pretend corrected text is already searchable.
D331 adds one section-level refresh beside stale Apuntador cards. The route sends
the corrected generation material through a typed ApplicationKit action and
shows bounded progress without letting the rail reach AppServices or StorageKit.
A successful complete pass replaces the observed card snapshot; unavailable,
cancelled, incomplete, lineage-stale, and persistence-failed passes retain the
old cards and publish localized recovery text through the existing detail error
surface. The stable `detail-apuntador-refresh` identifier and a disposable-only
success adapter exercise the real storage observation in XCUITest.
D234 routes every explicit meeting-document action through one correction-aware
ApplicationKit projection. Meeting Detail exposes a disabled-until-relevant,
opt-in provenance control in its export menu; the choice is route-local and is
forwarded as an immutable document option to Markdown, PDF, SRT, WebVTT, and
Gist preparation. SwiftUI does not compose corrections or inspect storage.

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

### Database launch state (D319)

`PortavozApp` owns one `AppLaunchModel`, not an eagerly infallible
`AppServices`. The model attempts the throwing service factory synchronously so
normal startup remains deterministic, but `AppServices` opens `MeetingStore`
before installing telemetry or constructing any other owner. The root renders
`ContentView`, commands, Settings, and the live menu-bar model only from a
complete ready graph. Opening and database-unavailable states render no normal
feature control; only readiness starts pressure/search/reminder/sync/backup,
recording/job recovery, provider discovery, and dictation work, once.

The database-unavailable view is one bilingual, keyboard-accessible SwiftUI
surface available on both the Sequoia deployment floor and Tahoe. Its stable
identifiers are `launch-recovery-retry`, `launch-recovery-save-copy`, and
`launch-recovery-export-diagnostics`. Native panels choose the output
directory/file. Diagnostics omit paths and raw errors; recovery reads the
source without modification and publishes only a verified non-overwriting
copy. A temp-store-only simulation drives the complete English/Spanish
XCUITest journey and cannot redirect or fail a production authority.

- Signature: by SHA-1 of cert (`PORTAVOZ_SIGN_IDENTITY`) — there are TWO Developer IDs with the same name on the machine and the name is ambiguous.
- `make install`: rejects a production provisioning profile, renames only a local-entitlement bundle to `Portavoz Dev`, re-signs it with Hardened Runtime and a secure timestamp, deep/strict-verifies `dist/Portavoz.app`, copies it to `/Applications/Portavoz Dev.app`, deep/strict-verifies the installed copy, and only then launches it. It never writes `/Applications/Portavoz.app`.
- `make production-sync-qualification-app`: requires one clean exact version/build/commit checkout, a real signing identity, and the matching production profile. It materializes the profile-owned macOS App ID and developer-team entitlements, preserves `app.portavoz.mac`, changes only the display name, re-signs and re-verifies the bundle, then leaves `dist/Portavoz Sync Qualification.app` uninstalled and unregistered for direct execution by the isolated two-Mac evidence workflow (D403).
- The **real-app production-sync qualification** mode (D404) admits only the wrapper's two inert AppKit key/value pairs, one `-use-temp-store`, and one exact hidden manifest/workspace/role/stage/timeout tuple; every additional or reordered argument fails closed. Its synchronous watchdog also requires the wrapper-sanitized environment to contain no inherited `PORTAVOZ_*` override and exactly one UUID-named role-local shell database path. The manifest and each stage bind the main executable, outer code-resource seal, embedded production provisioning profile, and contract digests, so either Mac rejects a copied or post-initialization variant before app launch. It starts from an inert SwiftUI shell without installing notification/App Intent launch plumbing or constructing ordinary `AppServices`, then uses the real CloudKit lifecycle/platform over role-local scratch stores and the fixed public EN/ES corpus before exiting after one owner-written receipt. Role B's push stage registers for APNs, writes a content-free live-stage marker, and waits without polling; role A must consume that marker before publishing, and only the delegate's remote-notification path initiates the qualifying synchronization. Normal app launches never parse a manifest, construct this scratch lifecycle, or write qualification evidence.
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
truthfully reports that the build is not provisioned. `make install` rejects a
production profile because it deliberately changes the bundle identifier to
`app.portavoz.mac.dev`. Provisioned release or qualification construction
selects the tracked production entitlements, embeds the profile at
`Contents/embedded.provisionprofile`, and runs
`verify-cloudkit-capabilities.sh` after signing. That gate decodes the signed
app, profile, and Info.plist; requires exact `app.portavoz.mac`, the profile's
matching `<application-identifier prefix>.<bundle identifier>`, matching native
macOS App ID and developer-team entitlements in the final signature, exact
`iCloud.app.portavoz.mac`, CloudKit, Production, and production-push values;
and rejects an expired or conflicting profile. Public release creation requires
that profile plus real signing and notarization credentials; the same gate runs
before notarization and against the app copied from the final DMG. The separate
D403 sync-qualification artifact keeps the exact production identifier under
`dist/`, is never installed or registered beside the stable app, and creates no
sync receipt merely by building.

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

Meeting Detail now merges a seventh independently observed section for current
commitment-review reconciliation. Storage publishes only review state for
action items in the newest live summary; ApplicationKit derives transient
presentation candidates from those action items and their typed evidence.
Suggested ownership exists only for an exact linked `Speaker.personID`, and the
due-date suggestion is empty until a production extractor passes its quality
gate. The section is present in the route model so confirmation, dismiss, defer,
and evidence-seek actions can arrive without widening the core transcript or
summary observations. Meeting Detail renders the inbox as an independent,
evidence-first review section; generated candidates still cannot enter Radar or
notification scheduling until the user confirms them.

The route model does not keep seven independent observation fields. A pure
`MeetingDetailReviewAccumulator` owns the current observation token, per-section
delivery/failure accounting, last healthy values, phase derivation, and read-model
assembly. Restarting observation resets delivery accounting but deliberately
retains healthy section values; a failed replacement stream therefore degrades
instead of blanking already rendered content. The accumulator returns explicit
correction-revision and audio-directory changes, and only `MeetingDetailModel`
invalidates suggestion or playback presentation state. Optional metadata
one-shot/request identity is separately scoped in
`MeetingDetailMetadataSuggestionState`, so unrelated section delivery can fence
stale generation without coupling it to playback attempts.

Meeting Detail routing enters `MeetingDetailScene` (D223). The scene owns the
route's observable `MeetingDetailModel`, is keyed by `MeetingID`, and is the
only detail presentation
type allowed to receive `AppServices`. It projects current refine, navigation,
summary-provider, mirror, and disposable-performance values plus explicit
meeting-scoped actions into `MeetingDetailView`; the view does not create its
model or observe the process composition root. Locale and time-zone rendering
uses a pure Foundation-only `MeetingDetailPresentation` value. This shell
changes no released control or workflow and is the seam for later section
extraction.

D224 uses that seam for three focused SwiftUI sections. The header receives
formatted identity/facts, participants, inert recommendation values, and
explicit rename/accept/dismiss actions. The trust section receives durable
processing and privacy values plus retry/recovery/navigation actions; retry
progress is its only local state. The generated-document section receives one
summary snapshot, typed action items and evidence, available recipes/engines,
and explicit copy/regenerate/feedback/seek actions; tab selection is its only
local state. It shares one content-free evidence control with Apuntador, so
current/stale/unavailable proof remains adjacent to the claim and navigation
still returns through the route owner. A Foundation-only projection retains
original Markdown section ordinals and removes `Action Items`/`Pendientes`
from visual tabs only when typed action items already represent that appendix.
Legacy summaries without typed commitments retain their Markdown section.
The three section roots use accessibility containment so their stable section
identifiers do not overwrite the nested controls exposed to Voice Control,
assistive technologies, or XCUITest.

D288 adds a fourth child on the same boundary. `MeetingDetailSummaryPlaceholder`
receives the meeting's durable jobs plus one generation action and owns what a
meeting without a summary offers. When the newest `summary` job ended
`cancelled` it states why above **Generate summary** (`detail-summary-abandoned`),
distinguishing a superseded input from an unavailable engine. This is the only
surface that can say so: a cancelled job is not a failure, so the meeting stays
`ready`, `lastProcessingError` stays cleared, and neither the trust section nor
the library row mentions it. `needsAttention` is deliberately not reused —
it offers recording recovery for something that was never a recording problem.
The reviewed boundary advances to 372 interaction signals, twelve owners, and 28
UI journeys.

D225 adds `MeetingTranscriptContent` as the Foundation/ApplicationKit value
between accepted transcript evidence and review presentation. The accepted
factory projects each source segment to one stable row and carries source
segment IDs, speaker, channel, per-turn spoken language, timing, confidence,
and finality. D229 adds a pure `ComposeTranscript` policy that can replace,
reassign, split, merge, suppress, or restore visible rows while retaining every
source ID. Lineage separately records raw/refined base material and the
accepted/composed projection, including a composed reading with no active edit.
Stable final base rows, exact split partitions, ordered merge/supersession
targets, and unique generated row identities fail closed before presentation.
Neither `MeetingDetailView` nor its row renderer decides which correction wins.
At the D225 boundary the app had not opted into composed rows yet; D231 later
adopted them for Meeting Detail. Chapters derive from the same snapshot as the
visible rows, preventing independent projections from drifting.

`MeetingTranscriptNavigationState` resolves generated evidence through source
IDs and timestamp-only Library/Ask/Spotlight routes through the visible-row
timeline. It keeps an exact pending seek while waveform/player construction is
still in flight. Playback synchronization performs a start-time upper-bound
search plus a maximum-end segment-tree lookup, retaining the released overlap
and gap behavior without scanning up to 20,000 rows every 200 ms. The extracted
transcript and chapter sections receive only immutable values and explicit seek
or rename actions. Row rendering remains a stable-ID `LazyVStack`, while the
generic focused viewport keeps live reader ownership and playback following in
a separately tested pure policy.

D226 composes the docked player through `MeetingDetailPlayerSection`. It
receives the application-prepared playback session, waveform buckets,
compression capability/progress/message values, and explicit clip-export and
compression actions. It imports no playback capability module, owns no model
or local state, and cannot resolve files or perform audio work itself.
`MeetingPlayerBar` retains focused transport/clip interaction plus the native
save-panel state needed to choose a clip destination. The route model and
ApplicationKit continue to own playback preparation, compression, file re-
resolution, and pending seeks.

`MeetingDetailActionSection` separately renders Refine, recap, export, Gist,
and delete capabilities. `MeetingDetailRailSection` renders recovery, privacy,
health, chapters, and persisted Companion cards in one independently scrolling
column. Neither section can reach the model, services, store, or preferences.
`MeetingDetailScene` owns one observable `MeetingDetailFlowState`; its typed
sheet, dialog, alert, and export routes replace independent modal flags while
preserving Refine and mirror presentations owned by their source services.

D228 removes the remaining presentation monolith without introducing another
observable feature owner. `MeetingDetailView` projects one short-lived
`MeetingDetailCoordinator` from the route model, scene actions, and typed flow
state. Focused coordinator extensions translate identity and document intents
into existing model/application effects; they own no state and are never
passed to child views. The scene owns route mutation and the
`mirrorAfterMeeting` preference, exposing only explicit actions and an
immutable preference value to the child. `MeetingDetailFlowHost` owns native modal and exporter
presentation through explicit values/actions, while
`MeetingDetailNotesSection` and `MeetingDetailRefineReviewSheet` own their
focused rendering only. `MeetingDetailPlaybackNavigation` retains evidence
focus and pending seeks across transcript and player sections but receives an
already prepared session and cannot resolve audio or storage. Architecture
tests keep the root at 500 lines or fewer and reject model effects or broad
composition dependencies in presentation children.

The composed primary column assigns generated material to a bounded
180-to-240-point scroll region, gives the transcript the remaining flexible
height, clips its focused viewport to that exact allocation, and keeps the
player as a separate dock below it. Transcript correction buttons are
28-point accessories outside focus blur and scale effects. Long summaries,
notes, or commitment review can therefore scroll without collapsing their own
controls, covering transcript corrections, or allowing the player to intercept
transcript input.

D231 adds the first correction adopter without reopening that composition
boundary. Meeting Detail observes correction history and asks an ApplicationKit
projection for the current-revision composed snapshot, falling back to accepted
material on malformed history. One focused editor owns text and speaker
presentation only; the application command validates history and atomically
persists independent lanes. Original evidence and append-only history remain
available, durable Undo restores each active lane, structural rows fail closed
with guidance, and every control has keyboard and accessibility reachability.
At that decision boundary, search, summaries, exports, and generated evidence
remained accepted-only. The
reviewed boundary now covers 371 signals across twelve owners and 27 UI
journeys. D232 keeps structural policy in ApplicationKit: the focused surface
offers only validated explicit merge neighbors, split inputs and timing, and
recoverable hide-as-noise. Hidden accepted evidence remains reachable after the
composed row disappears, and restore appends history rather than deleting it.
One immutable structural projection precomputes row contexts and hidden evidence
for each observed detail snapshot, avoiding transcript-wide work per rendered
row.

D407 makes correction presentation a scene-flow invariant rather than a
transcript-viewport side effect. Activating a visible correction accessory
captures its text context, structural context, exact accepted reading, and base
revision before setting one typed sheet route. `MeetingDetailFlowHost` renders
from that immutable target and passes the same revision/reading back to the
application commands; a missing target produces an explicit unavailable sheet
instead of conditionally empty native content. The transcript section retains
only reading, seek, rename, correction-presentation, and hidden-evidence intents.
This preserves immutable evidence and fail-closed command validation while
keeping correction controls reachable in compact supported macOS windows.

D408 closes the remaining cross-version compact-window activation gap. SwiftUI
can expose a descendant clipped below a `ScrollView` as hittable even though a
synthesized click lands outside the viewport. The playback and text-only
transcript readers therefore expose the same stable
`detail-transcript-scroll` boundary, and XCUITest reveals correction and
commitment actions until their complete frames are contained by the exact
viewport. The traversal is bounded and still requires a stable hittable frame.
Saved live objectives attach their UUID identifier and exact text label to the
containing accessibility row rather than a leaf `Text`, whose representation
varies across supported macOS versions; its toggle and removal actions remain
contained children.

D233 extends the route projection with derived-artifact freshness rather than
deleting immutable history. A correction clears route-local generated metadata,
renders the prior summary and Apuntador cards with localized stale guidance, and
makes their evidence nonactionable as current proof. The summary action builds
generation material from composed rows, persists evidence against accepted
source IDs, and relies on StorageKit's final lineage fence. D313/D330 serve
current replacement text through lexical and semantic lanes while structural
rows stay excluded pending a shared result identity. D331 makes Apuntador
regeneration explicit and whole-snapshot: it reuses the composed reading,
preserves stale cards on every incomplete or failed outcome, and never starts
from the correction itself. Automatic regeneration remains deliberately
absent. D234 adopts the composed reading
for explicit document export without changing that retrieval policy. One
route-local provenance option is enabled only when corrections exist, persists
while the detail route stays open, and travels through typed model effects; the
native menu remains a presentation surface, not an export-policy owner.

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
| Semantic embedding | `AppSemanticEmbeddingRuntime` coalesces one Apple Latin contextual-model load; Ask and Library borrow it only for query embedding and published-vector reads; one `SemanticCorpusIndexingCoordinator` admits background-maintenance writes; one shared resolver combines installed capability, durable pending rows, and supervisor phase | One app backfill task runs at a time; product queries never download assets or write the corpus; release is explicit and rejected while leased; no evidence-free idle timer is introduced; CLI and standalone benchmark processes own isolated runtimes |

The ratchet also proves there is one process ledger construction, five fully
integrated runtime adapters, and no production semantic constructor outside
the dedicated app adapter. This is not approval of the current idle constants;
semantic embedding intentionally has no residency idle-release timer. Its
separate persisted retry or lease-expiry wake owns maintenance scheduling only.
The pressure adapter can release any idle family immediately, while delayed TTL
replacement still requires accepted evidence.

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

Library, Ask, and background maintenance receive the runtime by dependency
injection; only maintenance receives the semantic-indexing coordinator.
Library and Ask share one `ResolveSemanticCorpusReadiness`, never request a
download, never join an indexing flight, and hold an active-use token only
while embedding queries and reading already-published vectors. The standalone indexing
and recording-plus-indexing resource workloads use the same app runtime but
remain isolated benchmark owners of their operation; the CLI owns one
equivalent process-local runtime and the scale-only CLI benchmark remains
isolated.

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
the next background signal resumes from storage with no polling loop or
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
wake into one later rerun. It never polls; D200 permits one cancellable future
wake for a persisted retry or predecessor lease expiration. Its production
adapter first uses a profile-free row-existence probe so an empty library never
touches the model runtime. For a nonempty corpus it requires already-installed
Apple assets and a valid active embedding profile before durable admission and
runtime borrowing; it cannot request an asset download. The D177 gate remains
the final admission/checkpoint authority if capture changes after wake
admission.

Temporary/UI stores and isolated resource benchmarks disable the owner. A
failed drain logs only an ordinary content-free operational message; durable
`NULL` rows survive and the next bounded retry, mutation, capture completion,
or launch retries them. Ask never joins the maintenance flight: exact FTS remains
authoritative, semantic lookup uses only already-published rows, and ordinary
runtime failure degrades to lexical evidence. The supervisor publishes a
payload-free process phase (`building`, `idle`, or `failed`) to the shared
ApplicationKit readiness resolver. Combined with installed assets, a valid
active profile, and one profile-aware durable maintenance probe, Ask and
Library observe `ready`, `partial`, `building`, `unsupported`, or `failed`
without preparing or writing anything.

The drain's selected rows retain segment, meeting, transcript-revision, and
exact-text identity across the model call. StorageKit conditionally publishes
only still-current rows (D198); a concurrent transcript mutation or deletion
is a skipped checkpoint, not a failed meeting or stale vector. The replacement
row remains pending and the existing coalesced mutation signal schedules the
next pass. Every accepted vector also publishes the D199 compatibility
fingerprint for its concrete model, dimension, pooling pipeline, and vector
schema. A profile change resets only incompatible derived rows to `NULL` before
the drain rebuilds them; exact FTS remains available throughout. The dormant
processing-job `.index` kind remains inactive because D200 owns derived
scheduling independently from meeting lifecycle.

### Durable semantic maintenance scheduling (D200)

The production adapter delegates one pass to
`ProcessSemanticCorpusMaintenance`. After the profile-free empty-library and
installed-asset checks, the use case recovers expired ownership, idempotently
admits the current profile/source operation, and claims one kind-wide lease.
The prepared runtime still forbids asset download and the D177 checkpoint gate
still protects capture between committed batches.

The operation heartbeats only while it owns the runtime pass. Capture policy
suspension returns it to pending and refunds the attempt. Ordinary failures
retry after bounded delays; `SemanticCorpusIndexingSupervisor` owns one
cancellable future wake for either that delay or a predecessor lease expiry,
with no polling loop. A mutation or explicit app signal cancels the stale wake
and drains immediately. After process death, launch either recovers an expired
lease or waits once until it can do so, then resumes from remaining `NULL`
vectors. Exact FTS, already-published compatible vectors, and meeting lifecycle
remain available throughout; `.index` is not activated in `processingJob`.

### Semantic search preparation in Settings (D332)

The Intelligence pane presents one explicit semantic-search status and prepare
action. `AppServices.semanticSearchPreparation` is a lazy process-scoped
observable owner, so closing Settings or opening another Settings scene cannot
start a competing request or lose the terminal state. Its client first routes
the semantic model family through `admitModelRuntimeLoad`; protected capture
therefore produces a retryable finish-recording state instead of loading a
competing model. Ordinary asset failure is also retryable, unsupported models
are terminal for the current host, and cancellation refreshes the read-only
state rather than inventing success.

Only a successful explicit request kicks `SemanticCorpusIndexingSupervisor`.
The Settings task does not scan or write the library, and the supervisor stays
disabled for temporary stores. UI automation substitutes a two-dimensional
model only when both `-use-temp-store` and
`-simulate-semantic-assets-missing` are present; the real control changes its
state from missing to ready without requesting host assets. Stable identifiers
cover the prepare button and every status. The bilingual journey asserts the
real Settings window, explicit click, ready transition, and disappearance of
the redundant action.

The copy states that macOS manages the assets, that storage can be a few
hundred MB based on the bounded Tahoe observation, that corpus updates continue
in the background, and that exact search remains available through every
state. It does not present the measured host cache as a universal download
size or conflate installed assets with complete corpus readiness.

### Signal-driven Meeting Memory Graph projection (D273)

The composition root owns a second derived-maintenance supervisor for the
disposable typed Meeting Memory Graph. It reuses the same generic signal
coalescing, durable lease, retry wake, and capture-state boundary as semantic
maintenance, but it has an independent `meeting-memory-graph` job kind and
borrows no embedding or language-model runtime. Temporary-store automation
disables the owner.

Launch/search reconciliation, post-capture publication, explicit Meeting
Detail topology changes, and capture returning inactive wake the projector.
Mutation triggers persist the
bounded cursor even when capture prevents execution; no view owns maintenance
and no task polls SQLite. A burst while one drain runs schedules at most one
coalesced rerun, and the supervisor reports completion only after that rerun is
fully drained.

`ProcessMeetingMemoryGraphMaintenance` recovers expired leases, admits the
current profile/source generation, claims one kind-wide owner, heartbeats the
run, and delegates bounded transactions to `ProjectMeetingMemoryGraph`.
Capture or governor pressure suspends only between committed batches and
refunds the attempt. Relaunch resumes the remaining cursor. The app does not
yet read this projection for Ask, Meeting Detail, Insights, or Library; GRAPH-4
must add a bounded evidence-preserving read boundary before any presentation
can depend on it.


### Capture-safe existing-library sync admission (D179)

The existing Settings action persists the user's account-scoped request before
doing library work. `CloudMeetingSyncCoordinator` then admits UUID-ordered
StorageKit batches through the same capture-derived
`DurableMaintenanceGate`. A protected capture blocks the first database read;
capture beginning during the pass lets the current transaction finish and
pauses before the next batch or transport construction.

IntegrationsKit persists the last committed meeting identity and a separate
prepared marker in its owner-only state. The meeting batch commits first; a
crash before cursor publication safely replays that batch without incrementing
an already-pending generation. AppServices sends one content-free resume signal
when capture returns inactive, and `MeetingSyncModel` wakes only for an enabled,
explicitly requested seed. Relaunch and ordinary sync requests use the same
durable cursor. There is no timer, polling task, in-memory retry queue, or new
meeting-database schema. Ordinary future-change CloudKit delivery remains
outside this initial-seed-only gate.

### Capture-safe staged whole-library backup (D180–D189)

After the user chooses a destination, the whole-library Markdown backup enters
the shared maintenance gate as a media-export workload. Admission happens
before destination inspection or source staging. StorageKit copies one
coherent SQLite stage through bounded page groups and abandons a partial copy
when protected capture arrives. Protected capture returns a typed suspended
outcome rather than an error.

`LibraryMarkdownBackupModel` retains the process-scoped destination and keeps
the request in its preparing state while suspended. AppServices sends the same
content-free capture-inactive signal used by other maintenance owners, and the
model automatically retries the retained request after Stop. One pending bit
remembers a capture-stop signal that races with admission, while actor
serialization prevents duplicate exports.

`ExportLibraryMarkdownBackup` is one process-owned actor. After staging, it
loads one aggregate at a time and checkpoints before the next staged read,
after loading one aggregate, after rendering one document, and after atomic
publication. Its active run retains the immutable stage cursor, filename
allocator, typed results, and at most one pending aggregate or document.
Resume therefore continues from the same database moment and never republishes
a completed file.

A newly prepared stage is removed on completion or ordinary process-local
failure. Each current-format stage holds an exclusive kernel lease. An adopted
stage can instead abandon only its lease after recovery setup failure, leaving
the immutable source available for a later exact attempt. Process launch
performs one utility-priority scan serialized with stage creation by a root
lock, but only after cataloging every canonical recovery-operation UUID. The
scan preserves all matching stages and removes only an unprotected stage whose
owner lease can be acquired. Active work from another app instance and
lockless or malformed legacy directories remain untouched; disposable test
composition never scans the host root.

After staging and the final capture checkpoint, the application destination
adapter creates opaque Foundation bookmark identity and acquires one bounded
lease. Every execution interval resolves the bookmark, performs destination
inspection/publication through that URL, refreshes stale identity, and closes
the lease before returning. Resume reacquires identity without asking the user
for the folder. Portavoz currently uses a regular bookmark with
`withoutImplicitSecurityScope`: the hardened-runtime app is not sandboxed, so
there is no security-scope resource to hold or balance. The port and lease are
ready for a future sandbox adapter without changing the workflow.

The app also owns one versioned recovery journal per stage under
`Application Support/Portavoz/LibraryMarkdownBackupRecovery`. The owner-only,
backup-excluded operation directory persists regular bookmark bytes, immutable
completed publication records, and at most one exact pending
filename/SHA-256/byte-count
reservation; it never stores transcript, summary, or rendered Markdown bytes.
Each destination name is reserved before the atomic move and marked complete
afterward. If the post-move save fails, the actor retains the advanced
process-local run before reporting failure, so retry in the same process cannot
publish the document again.

Same-process retry persists a refreshed bookmark before adopting it, completes
or clears the exact pending reservation before advancing, and retains explicit
terminal intent when journal removal fails. Terminal retry removes the journal
before closing the staged SQLite source and does not reacquire the destination.

Metadata and pending records are atomically replaced as format-v1 JSON; the
pending record becomes one immutable, sequence-named completed record through
a same-directory atomic move. Steady-state journal I/O is therefore O(1) per
meeting instead of rewriting a growing manifest. Loading or removing a
symlink, malformed/oversized record, noncontiguous sequence, mismatched
operation UUID, or unknown version fails closed. Launch cleanup removes a
journal only when
StorageKit returns that exact UUID after proving its stage abandoned; active
and unknown work remain untouched. Disposable test composition receives a
unique recovery root.

Each new pending publication also carries its exact source cursor when durable
advancement is still safe. The recovery adapter validates that the cursor row
identity matches the reserved meeting. Cursor-less format-v1 publications
remain readable for compatibility but cannot be adopted as successful work.

After each immutable completion, ApplicationKit persists the staged source's
content-free keyset cursor in optional format-versioned metadata. The cursor mutation
is rejected while a reservation is pending, accepts an equal retry, and rejects
malformed or backward positions. A failed post-completion checkpoint is retried
before any next source read without moving the destination file again. Each
source, render, or publication failure is written as an immutable bounded
record with its exact cursor before that cursor advances. The released partial
result can therefore be reconstructed without freezing later healthy work.
Failure-record retry is idempotent, and checkpoint retry does not rerender or
duplicate the failed outcome. Rendered Markdown remains absent from recovery:
before reservation, the cursor stays behind the row so adoption can rerender it.

`ReconcileBackupPublication` narrows the remaining atomic-move crash window
without entering SwiftUI or launch orchestration. It reacquires and refreshes
the bounded destination lease, then inspects only the exact reserved final name.
The macOS adapter opens the destination directory and final component without
following symlinks or blocking on a special file, requires a regular file and
exact byte count, and streams SHA-256 while checking cancellation between
bounded reads. Missing bytes clear the reservation so the source row can retry.
Matching bytes with a bound cursor complete and checkpoint the
publication. Conflicting bytes and every matching cursor-less reservation
remain blocked; this includes old journals created before durable failure
outcomes. A checkpoint-only retry uses the furthest
immutable publication or failure evidence and does not reacquire, rehash,
rerender, or republish the destination.

`RecoverLibraryMarkdownBackup` runs once from app launch. It catalogs journal
UUIDs before stage cleanup, preserving even a matching canonical stage whose
journal child is a symlink or malformed. Zero journals performs ordinary
unprotected-stage cleanup. More than one journal is ambiguous and blocks
without adopting or deleting any candidate. One journal enters the shared
maintenance gate before destination access, reconciles pending publication and
checkpoint evidence, then adopts only the exact stage UUID and durable cursor.

Recovered state must have contiguous immutable publication/failure sequences,
cursor-bound publications, unique filenames and source positions, no pending
reservation, and a checkpoint equal to its furthest durable outcome. Active
outcomes cannot exceed the immutable stage total; completed outcomes must equal
it. The exporter rebuilds filename allocation from both current destination
names and durable completed names, reconstructs typed results, and continues
strictly after the adopted cursor. A completed operation reconstructs its final
result without destination access, removes the journal, and then closes the
stage. Missing, malformed, conflicting, cursor-less, unavailable, or ambiguous
evidence stays untouched and blocks a second backup. Capture suspension retains
the unresolved operation and retries through the existing capture-stop signal;
destination setup failure releases the adopted lease without deleting its
source. A terminal recovered-source failure clears launch ownership only after
its journal and stage are gone; a later maintenance signal cannot start a fresh
backup from the remembered destination. No launch path adds a timer, polling
task, PID heuristic, or meeting content to recovery state.

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

### Recording-scoped proactive assistance (D390)

`RecordingController` owns one `RecordingProactiveAssistModel` independently of
the Foundation Models Companion coordinator. The control is off at each
recording start. Enabling it evaluates the currently finalized caption window
and open objectives synchronously; each later closed-row signal and objective
mutation reevaluates the same pure policy. There is no timer, asynchronous task,
provider, network callback, or Store observation to retain the recording.

Pause preserves current cards and stops admission. Resume may admit only a
newly due signal. Disabling clears visible cards but deliberately keeps the
recording's emitted-signal set, so toggling cannot replay the same evidence.
Start reset, Stop, and the next-session transition clear all state. Completing
or removing an objective retracts its card immediately, including while paused.
At most three cards remain visible; each card exposes the exact bounded caption
range and can only be dismissed.

The recording toolbar uses `recording-proactive-assist` and
`recording-proactive-pause`. The panel, status, suggestion, dismiss, and source
rows use stable `recording-proactive-*` identifiers. Copy states explicitly
that only open objectives and measured talk balance are watched and that no
model, Web request, or automatic action occurs. The system controls remain
keyboard- and assistive-technology reachable; physical VoiceOver, Voice
Control, and Full Keyboard Access evidence remains an external release gate.

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
The legacy direct physical recording benchmark performs the same preflight.
The candidate resource matrix deliberately does not: its exact disposable
admission selects the public synthetic runtime described below and constructs
no physical capture source. Therefore it proves the product recording
lifecycle without claiming microphone/system TCC, device-route, or acoustic
behavior.

The tracked `docs/evidence/resource-baseline-matrix.json` contract and
`scripts/resource_baseline.py` sit outside the executable. They require three
stable Release runs for every combination of 8 GB, 16 GB, and reference-memory
profiles with idle, recording, Stop, Refine, summary, Ask, indexing,
recording-plus-indexing, and recording-plus-batch scenarios. Receipts accept
only aggregate process resource metrics and bounded summaries of the same
closed workload enums. Schema 4 marks a wall or CPU distribution unstable only
when p95/p50 is above 1.25 and p95 minus p50 is at least 100 milliseconds; a
zero median blocks only when p95 reaches that floor. The contract cannot raise
the absolute floor, and raw aggregates remain visible without clipping. The
evaluator rejects extra/content-bearing fields, unknown enums, non-finite
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
A minimal process-owning launch probe runs first and writes one fixed,
owner-only, non-replacing marker before `AppServices` exists. This is required
because LaunchServices can return success even when dyld aborts the app before
the benchmark writes its normal log or fragments. Ad-hoc candidate collection
keeps the hardened runtime but gives only this disposable scratch identity the
library-validation exception needed for its separately ad-hoc-signed embedded
Sparkle framework. Real Developer-ID resource evidence and every ordinary or
distribution app retain library validation.
A recording resource process is admitted only by one each of
`-use-temp-store`, `--bench-record`, `--bench-resource-output`, and
`--bench-resource-synthetic-capture`. It emits the fixed
`public-synthetic-dual-channel-v1` signal as 1,600-frame microphone/system
chunks at 16 kHz. The signal crosses the production `RecordingSession`, CAF
writers, live-transcription feeds, Stop workflow, and concurrent indexing or
batch scheduler while avoiding AVAudioEngine, process taps, TCC, and user
audio. The schema-4 host receipt records this input identity; physical capture
remains a separate field gate.

Every invocation also carries a 60–7,200-second in-app watchdog armed before
app composition. The shell requires its value to exceed both the configured
model timeout and the longest idle-plus-recording phase by 420 seconds, then
adds a 30-second outer LaunchServices grace guard. Expiry terminates only the
disposable scratch process/wait and leaves no passing sample or receipt.
A five-second launch-settling interval precedes the model-free idle window.
Before repeated Refine measurement, one bounded unmeasured scratch-app process
verifies the selected Whisper model, tokenizer, and diarization artifacts,
acquires and finishes the real Whisper runtime, and only then acquires and
finishes the real diarization runtime. It publishes one exact owner-only
mode-0600 marker that the schema-4 receipt binds as
`refine-runtime-preparation-v1`. The three measured Refine processes remain
independent and start without an app-resident runtime. This isolates one-time
host/Core ML compilation from the repeated-sample stability rule without
claiming first-ever activation latency, disk cost, or UX. Refine then runs as a
draft-only operation in a separate process against one host-generated,
non-silent English AIFF containing only fixed public text. The runner verifies
the models again before sampling and bounds execution to 60–3,600 seconds;
model download is not part of either preparation or measurement. Summary runs
in another cold process, verifies
the pinned Qwen3.5 MLX descriptor before sampling, inserts a fixed public
English meeting/cast/transcript into the disposable database, and measures the
real `RegenerateSummary` ApplicationKit workflow through successful
transactional persistence. Ask runs in a third cold process, requires
already-installed Apple Latin embedding assets and available Foundation Models,
and measures the real `AskMeetings.local` workflow over the same fixed corpus,
after explicitly indexing that disposable corpus outside measurement. The
measured request includes deterministic bilingual expansion, corpus-read-only
progressive hybrid retrieval, and generated answer. It emits no sample without citations and
nonempty generated text. Indexing runs in a fourth cold process,
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
recording/recording-plus-indexing/recording-plus-batch/Refine-preparation/
Refine/Summary
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
An existing encrypted identity with missing or malformed Keychain material now
fails closed before status or enrollment can replace it. Settings keeps that
state visible, offers Retry and an explicit destructive reset, and changes the
enrolled state only after a reported success. The deterministic unavailable
fixture is active only with temporary storage, so its status and reset journey
cannot reach the host identity.

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
utility executor. Every mutation first reads the authoritative gallery and
propagates key, authentication, and decoding failures before any overwrite.
SwiftUI renders an initial loading anchor so the first gallery read cannot be
lost with an empty conditional section, retains verified rows on a failed
reload, and keeps Retry plus explicit reset visible. Disposable test
composition never reads or mutates the host gallery; its unavailable fixture
is legal only behind temporary storage. SwiftUI keeps only native folder
selection, preferences, localized progress, and result presentation.

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

`AppServices` also owns one process-scoped `SpotlightIndexer` actor
(D85/D326/D329). Launch and every searchable mutation call
`requestSearchReconciliation()`; requests
coalesce for 250 ms and are not tied to a `ContentView` lifecycle. The actor
loads one consistent StorageKit projection, hashes every published field into
a compact mode-versioned client state, skips unchanged publication, and retries
failures after one and five seconds. Its private backend replaces the named
`app.portavoz.search.v3` index under complete protection in 500-value batches.
On macOS 15+ those values are native meeting/person/commitment App Entities; on
14.4 they are released meeting documents. The distinct state prefixes make an
OS capability transition repair the representation instead of accepting stale
state, while one index avoids duplicate meeting results. The entity adapter
uses task-local Core Spotlight references to satisfy strict Swift 6 isolation.
It removes the older named/default indexes only after v3 is ready. Failed
cleanup remains retryable; the first success records a versioned marker instead
of issuing the same delete on every unchanged reconciliation or future launch.
Temporary UI-test stores disable OS indexing. Internal status and content-free
OSLog attempts are diagnostic only; no meeting content is logged. A new request
after terminal retry exhaustion starts a fresh recovery.

Meeting bodies are correction-fenced before they reach either backend (D329).
StorageKit contributes accepted text only when no active text-affecting edit
owns that source row and substitutes current `replaceText` material through the
same D313 projection used by Library search. Speaker-only edits preserve text;
split/merge/suppress targets remain absent until structural search identity is
defined; restore makes accepted text eligible again. Summaries publish only
when their generation provenance matches the effective overlay, so a known-
stale or malformed summary cannot remain findable after a transcript edit.
Successful text and structural correction actions wake reconciliation only
after persistence; failed actions do not. The index attributes and availability
boundary do not change, and the existing client-state digest observes the
resulting body without retaining correction metadata.

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
app client also composes the protected canonical-person catalogue and
`LoadPersonCommitments`. Each full Ask model may therefore own one subordinate
`AskMemoryModel` without giving SwiftUI a store or graph adapter. The models
own answer/search tasks and generations, and the palette resets both on
close/reopen. Full Ask additionally owns the pending question, lexical/fused
citations, cumulative generated text, and distinct finding/refinement/generation
presentation phases. Submitting a nonempty draft while another answer is
pending cancels and replaces it instead of disabling the input. Every
progressive update crosses the same request-generation fence; cancel or
navigation clears pending state and rejects late work. Completed conversation
state retains only the newest 20 exchanges, and the task captures its model
weakly so an uncooperative provider cannot retain a closed window. The command palette and
other consumers retain final-result behavior. The full Ask model additionally
owns a bounded source-meeting catalog task and explicit selected identity. It
does not auto-select a meeting; failed or empty catalogs remain visible and
retryable. The source and exact-meeting controls have stable `ask-source-*`
identifiers, and menu choices include the localized start date so repeated
meeting titles remain distinguishable. AppKit owns panel lifetime,
keyboard activation, clipboard, and window navigation only. The composition
root also injects one
`AppAskPipelineTelemetry` adapter (D192). It maps only the closed Ask operation,
stage, milestone, and outcome enums to Points of Interest intervals and exposes
an explicit observer seam for benchmark processes; user text and durable
identity cannot enter the adapter. Full Ask and palette citations publish the same exact,
meeting-scoped seek request before opening Meeting Detail. The destination
consumes it after playback is ready; if that meeting is already open, its
detail observes the identity-bearing request directly instead of depending on
a no-op route assignment to reconstruct the view (D100).

D361 adds a segmented **By person** surface only to the full Ask window. Its
per-window owner requests 21 canonical people, displays 20 plus overflow, and
accepts only an exact currently displayed `PersonID`. It loads at most 100
current commitment facts, validates every typed relationship and exact source,
and routes evidence through the existing meeting seek. Person search and graph
loading keep independent tasks and generation fences; switching surfaces or
closing the window cancels hidden work. Typed abstention, malformed evidence,
and an operational read failure remain separate states with explicit retry.
The existing free-form Ask, command palette, CLI, MCP, and meeting briefs do
not inherit this query, and no Foundation Models capability is required on
Sequoia or Tahoe.

## Exact decisions by topic in Ask (D362)

Full Ask adds **By topic** as a third segmented surface. Its subordinate
`AskTopicMemoryModel` owns a 21-row confirmed-topic request, 20 visible choices,
overflow disclosure, an exact selected `TopicID`, and a maximum 100-row current
decision read. Topic search and decision loading have independent task and
generation fences; surface changes and window teardown cancel hidden work, and
late results must still match the selected identity before publication.

The view renders only synthesis-validated confirmed decision-about-topic facts
and exact evidence buttons. Typed abstention, malformed evidence, and an
operational read failure remain distinct with retry; no state silently falls
back to free-form Ask. Every interactive control has an `ask-topic-*`
accessibility identifier, uses localized English/Spanish copy, and reuses the
existing meeting-and-timestamp navigation. The surface needs neither
Foundation Models nor Tahoe-only APIs, so the deployment floor and Sequoia
behavior remain unchanged; physical VoiceOver and independent Sequoia/Tahoe
validation are still external evidence.

## First confirmed discussion by topic in Ask (D363)

The existing **By topic** surface now exposes a subordinate native memory-view
selector, initially **Current decisions** or **First confirmed discussion**. The
selected job is retained while changing exact topics, but changing the job
cancels any in-flight fact read and clears its visible result. Search remains a
separate bounded task, and closing or leaving Ask cancels both lanes.

First-discussion presentation accepts only one complete, source-backed
topic-to-meeting fact for the selected `TopicID`. The card names the exact
meeting and confirmed occurrence date, uses deliberately narrower wording than
“first ever”, and provides one evidence action through the existing exact seek
route. Partial pages, extra facts or sources, mismatched topic/meeting identity,
and inconsistent occurrence time render an explicit verification failure.

The picker, both segments, load action, card, and evidence action have stable
`ask-topic-*` accessibility identifiers and localized English/Spanish copy.
The temporary-store graph fixture drives an independent bilingual XCUITest that
switches jobs, loads the first discussion, and follows its source to 00:03.
No Foundation Models or Tahoe-only API is involved; physical VoiceOver and
independent Sequoia/Tahoe validation remain external.

## Confirmed decision changes by topic in Ask (D364)

The **By topic** memory picker now has three localized jobs: **Current
decisions**, **First confirmed discussion**, and **Decision changes**. The third
job reuses the exact selected `TopicID`, the existing load button, and the same
per-window generation-fenced fact task. Switching jobs clears the previous
result and cancels its read; a late conflict page must still match both the
request generation and selected job before it can render.

Each conflict card shows the successor statement as **Changed to** above the
replaced statement and retains the confirmed relationship time. It exposes
every exact source while moving the fact's successor primary source to the first action;
both successor and earlier evidence remain independently navigable. Stable leaf-
level `ask-topic-conflict-*` and button-level
`ask-topic-conflict-evidence-*` identifiers avoid the macOS SwiftUI container-
identifier propagation that can hide nested controls.

The temporary-store fixture creates a separate source-backed earlier decision,
leaves it unlinked to the topic, confirms the existing linked decision as its
successor, confirms their supersession, and projects the real disposable graph.
An independent bilingual XCUITest verifies both statements, both exact source
actions, and the successor seek to 00:03. The app path adds no Foundation
Models or Tahoe-only dependency; physical VoiceOver and independent
Sequoia/Tahoe validation remain external.

## Active blockers for one exact commitment in Ask (D365)

Each validated current-commitment card in **By person** now has a localized
**Show active blockers** action. The presentation model accepts only a
`CommitmentID` still present in the currently displayed exact-person result;
unknown, stale, or previously selected identities start no read. Its nested
task is weak, cancellable, and independently generation-fenced so selecting a
different commitment, changing person, reloading commitments, leaving Ask, or
closing the window rejects late publication.

The inline result shows each confirmed blocking decision, the exact commitment
it blocks, confirmation time, and every current transcript source with the
blocker-confirmation source first. Stable leaf identifiers use
`ask-memory-blocker-*`; every evidence action uses
`ask-memory-blocker-evidence-*`, and retry remains a separate accessible
control. Honest no-blocker, unavailable commitment, preparing projection,
invalid evidence, and operational failure states never collapse into an empty
success.

The temporary-store fixture confirms the existing exact commitment, creates
and confirms a separate Spanish security-review decision, explicitly confirms
the causal blocker, and projects the real disposable graph. Its evidence
meeting reuses only the fixture's synthetic audio so the independent bilingual
XCUITest can verify both exact sources and follow the blocker source to 00:04.
No user library, model, inferred causality, network, or Tahoe-only API is
involved; physical VoiceOver and independent Sequoia/Tahoe validation remain
external.

## Confirmed changes since one exact meeting in Ask (D366)

The **By topic** memory picker now has four jobs and uses a native radio group so
the localized choices remain legible instead of compressing into four segments.
**Changes since** appears only after one exact canonical topic is selected and
requires a second exact selection from a bounded title-only meeting catalogue.
The catalogue requests 21 newest-first meetings, renders 20 plus overflow, and
uses title search only for discovery; the load control stays disabled until one
currently visible `MeetingID` is selected.

Each candidate shows the actual temporal boundary used by the query: **Ended**
for completed meetings, or **Started** when no end exists. Empty titles,
duplicate identities, non-finite dates, end-before-start aggregates, and
oversized responses fail closed. Search and fact work use weak cancellable
tasks; topic, job, query, or anchor changes clear visible results, and a late
relationship page must still match the captured topic, anchor, job, and
generation before it can publish.

Result cards use the same strict relationship component as **Decision changes**
while keeping independent `ask-topic-change-since-*` identifiers. The selected
baseline remains visible, both successor and replaced statements remain visible,
and every exact source remains independently navigable with the successor
primary source first. Meeting search, options, selection, change, retry, result,
and evidence actions all have stable identifiers and localized speakable labels.

The temporary-store fixture reuses **Planning baseline** as the exact earlier
anchor and the real projected relationship already confirmed for `model
rollout`. The bilingual XCUITest searches and selects that exact meeting,
verifies both Spanish statements and both evidence paths, then follows the
successor source to 00:03. It touches no user library, network, Foundation
Models, new storage authority, or Tahoe-only API; physical VoiceOver and
independent Sequoia/Tahoe validation remain external.

## Exact graph query timing in the app (D367)

The app composition root injects one process-scoped
`AppMeetingMemoryGraphQueryTelemetry` into every direct exact graph use case:
person commitments, commitment blockers, decision history, first discussion,
decision changes, and changes since. All released UI reads therefore reach the
same adapter through their use cases. The optional ApplicationKit graph-fact
workflow can compose those measured boundaries explicitly instead of adding an
outer interval; ordinary Ask, palette, CLI, MCP, and meeting-brief behavior
remains unchanged.

The adapter maps the ApplicationKit trace to a Points of Interest interval
named **Memory graph query**. Its begin message contains only the closed job;
its end message contains only the closed terminal outcome. A lock protects the
process-local active-interval and observer dictionaries, and callbacks execute
only after that lock is released. Observation uses explicit add/remove tokens,
so a controlled performance probe cannot leave an accumulating callback after
its lifetime ends.

No SwiftUI state, copy, accessibility identity, graph authority, database
schema, model, or support export changes. No identity, text, source, count,
abstention reason, or error description reaches OSLog, persistence, or a
network. The signposts make local Instruments runs possible; they are not an
accepted Sequoia/Tahoe performance receipt by themselves.

## Isolated graph query timing runner (D368)

`--bench-graph-queries` owns the app process before normal background services
start. It is admitted only with `-use-temp-store` plus the complete public
`-seed-demo`, `-seed-ask-memory`, and `-seed-ask-topic-memory` fixture. Fixture
seeding disables its normal search-reconciliation wake, so Spotlight, semantic
indexing, graph maintenance, sync, recovery, provider discovery, and resource
monitoring do not compete with the measured window. The runner waits for two
nominal thermal observations, requires AC power and Low Power Mode off, performs
one unmeasured warmup, and has a six-minute process deadline.

One removable observer surrounds only the measured six-query rounds. Exact
fixture lookup must resolve one person, commitment, topic, and baseline meeting;
every use case must return a non-empty fact page. The strict probe rejects
duplicate, unmatched, incomplete, late, failed, cancelled, abstaining, missing,
or excess events. It writes one mode-0600 fragment without replacing an existing
file and exits; it never opens the real library.

`run-meeting-memory-graph-query-receipt.sh` refuses a dirty worktree, requires
one real Developer ID identity, builds one isolated Release app, gives it a
separate bundle identity, verifies that its app and embedded frameworks share
the signing team, and collects at least three fresh app processes. It rejects
ad-hoc signing because hardened-runtime library validation cannot load a
separately ad-hoc-signed embedded Sparkle framework. The Python assembler
accepts only the exact fragment schema, rejects duplicate JSON keys and
non-finite/non-monotonic durations, requires identical host/iteration evidence,
and atomically publishes a content-free receipt bound to source commit, version,
and build. This is a field-evidence input, not a product feature, UI control,
latency threshold, or supported-host certification.

The hidden Ask resource mode installs one observer only around its disposable
`AskMeetings.local` call (D193). `AskPipelineRunProbe` accepts exactly one
answer trace, one completion for every declared stage, first evidence, first
observable token, and successful terminal completion. It samples process CPU
and monotonic wall time at event boundaries, rejects invalid lifecycle or
digest evidence, and atomically writes an owner-only, non-overwriting sidecar
beside the broad resource sample. Fixed-corpus identity and citation validity
are resolved locally after the operation. D196 explicitly indexes the
disposable fixture through the shared coordinator before the observer and
measured Ask window begin; schema-2 evidence proves pending-at-seed, ready-
before, and ready-after counts. No product window, normal Ask model, or
persisted meeting ever reads benchmark state.

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

First Listen owns a separate generation-fenced microphone/caption session.
On Tahoe it resolves the optional SpeechAnalyzer asset before microphone start;
on Sequoia the caption capability resolves unavailable without changing the
same capture cleanup contract. Continue, Skip, root dismissal, retry, and task
cancellation invalidate the session, cancel the caption consumer, and await the
microphone and analyzer teardown before any stale result can publish. This
ordering prevents a cold framework wait from buffering live microphone chunks
without a consumer and prevents a departed onboarding step from continuing to
listen.

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

Native App Intents (D139/D324/D325): Start and Stop foreground the exact bundle
that owns the action and publish buffered process-local requests consumed by
`PortavozAppDelegate`; neither reopens the public `portavoz://record` adapter
through LaunchServices. On macOS 26+ both use immediate foreground modes; the
documented compatibility property preserves foreground behavior on the macOS
14.4/15 deployment range. Portavoz publishes no `AppShortcutsProvider` on
macOS: the unsupported automatic shortcut duplicated the raw action in the
picker, while reliable Spotlight and Siri invocation already comes from a
user-created Shortcut. The metadata Xcode would extract during its build is
produced out of band by
`scripts/build-appintents-metadata.sh` — a standalone compile of the SDK-only
`PortavozAppIntents.swift` under the shipping module name, then
`appintentsmetadataprocessor`, then `Metadata.appintents` into
`Contents/Resources` — and `make-app.sh` fails rather than ship without exactly
five native actions, three entities, three queries, or without the deliberate
absence of automatic App Shortcuts.
The intents file's SDK-only import diet is pinned by
`ArchitectureDependencyTests`, because a project import would break the
release pipeline at packaging time instead of test time.

D325 adds meeting, canonical-person, and confirmed-commitment `AppEntity`
snapshots with bounded string queries. `AppServices` installs their standard
`AppDependencyManager` catalog only after the database opens. Every open action
revalidates its identity and uses one latest-wins process route: meeting opens
Detail, person opens a visible reversible canonical-owner Radar focus, and
commitment opens only the exact live Radar item. Exact focus temporarily
overrides stale window filters; **Show all** restores them. Malformed/missing
identity and read failure take one explicit Library/Radar recovery route.
`IndexedEntity` conformance is available only on macOS 15+, and this slice does
not publish entity-native Core Spotlight records; the D85 meeting-document
index stays separate.

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

**Objectives with live check-off (D134, Jul 2026)**: `RecordingObjectivesModel` owns the checklist (`recording-objectives-panel`, add via `recording-objective-field`/`recording-objective-add`); adding trims and de-duplicates case-insensitively, manual toggling is always available and clears the model mark. The AUTOMATIC pass rides the signal-driven live-summary cycle behind the Apuntador opt-in: `ObjectiveCheckPolicy` (pure, tested) clips a 150-second window of closed rows and only runs with pending objectives plus enough conversation; `ObjectiveCheckDetector` (few-shot, `.background`, greedy) returns addressed indexes through a deterministic gate — out-of-range indexes drop, doubt leaves objectives pending, announced-but-not-discussed is explicitly NOT covered, and the model can never uncheck. At Stop the objectives join `contextItems` as `ContextItem.Kind.objective` rows ("✓ " prefix + check-off timestamp for covered ones), so the D28 notes block reports coverage to every summary without any schema change. Brief seeding is deferred (the `MeetingBrief` dies at the recording route boundary today).

**Next question + talk balance (D134/D174, Jul 2026)**: `RecordingNextQuestionModel` is the exact catch-up sibling (`recording-next-question` button, `recording-next-question-panel` card): pull-based, `.interactive`, capability-honest, stale-fenced on every exit, dismissed synchronously at Stop; its prompt carries the still-open objectives so a suggestion can steer back to them, and `PromptFactory.nextQuestionInstructions` pins one-or-two grounded questions, no filler. The talk-balance cue (`recording-talk-balance`, next to the mic meter) is `LiveTalkTimePolicy` — pure channel math over closed rows in a five-minute window, no model call, so it does NOT ride the Apuntador opt-in; it evaluates at most 1,024 closed candidates before the time filter, renders only once closed captions exist, and shifts to amber emphasis only past 60 seconds of attributed speech and a two-thirds share, with the exact percentage in accessibility value and help.

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

`MenuBarExtra(isInserted:)` bound to `@AppStorage("menuBarEnabled")` (toggle in Settings → Menu bar, on by default): template icon `waveform.and.mic` that changes to `record.circle.fill` while recording — the "¿estoy grabando?" at a glance. Menu: Start/Stop (Start fronts the value-scoped primary window via `openWindow(id: "main", value: .primary)` + `pendingRoute = .recording(nil)`; Stop calls shared controller), Dictate (only with dictation enabled), Open Portavoz, Launch at login (`SMAppService.mainApp` — requires /Applications, which is the installation story), Quit. **Architectural precondition**: `RecordingController` moved from `@State` of RecordingView to `AppServices.recording` (shared) — view, HUD and menu bar observe THE SAME session and navigation never can orphan a recording (same fix as RefineService).

## Global dictation (Jul 2026)

**Hold-to-talk (Jul 2026)**: `GlobalHotkey` listens to kEventHotKeyPressed AND kEventHotKeyReleased (`GetEventKind` in same handler). Gesture without setting: a TAP (release < 0.5 s) preserves toggle; HOLD combination while speaking and release delivers at release — walkie-talkie. Verified E2E: hold of 2.5 s opens panel on press and closes only on release.

**Configurable hotkey (Jul 2026)**: `HotkeySetting` (keyCode + Carbon mask + label, AppStorage; default ⌥⌘D) + `HotkeyRecorder` in Settings (NSEvent local monitor captures next combo; Esc cancels; combos WITHOUT ⌘/⌥ rejected with beep — single letter as global hotkey would hijack typing). `syncHotkey` now always unregister-first so new combo applies live. Verified E2E: record ⌃⌥⌘M and trigger opens panel.
 — ⌥⌘D in any app

Surface validated by MacParakeet: global hotkey → speak → hotkey again → text written where cursor is. `GlobalHotkey` uses Carbon `RegisterEventHotKey` — the only API consuming the keystroke without Accessibility permission — and is registered from app initialization so it survives without a window. `DictationController` owns one process-scoped, UUID-fenced session: mic → Parakeet streaming with custom vocabulary → the shared `CaptionCoalescer`; no meeting, database row, or audio file is created. The non-activating `DictationPanel` shows live text and offers explicit cancellation.

`TextInserter` implements the fail-closed delivery boundary. It waits up to one second for all physical modifiers to lift and refuses delivery rather than posting a combined shortcut when they remain held or cancellation arrives. It then inspects the focused Accessibility element immediately before touching the clipboard: `AXSecureTextField`, lost trust, missing role, malformed values, and transient inspection errors all block insertion with localized feedback; an explicitly absent/unsupported subrole on an otherwise valid ordinary text control remains admissible. Only after that check does it snapshot every pasteboard representation it can actually capture, write the dictation, and post a complete layout-aware ⌘V pair. Borrowed Text Input Source properties are promoted while their owning source remains alive, must match their declared Core Foundation runtime type, and must contain a complete keyboard-layout header; a missing, wrong-typed, or truncated value falls back to the standard QWERTY shortcut instead of reaching typed Carbon translation. Clipboard-write or event-construction failure restores immediately. Successful delivery restores captured representations after 1.5 seconds only if `changeCount` still identifies Portavoz's write, preserving rich content without overwriting a clipboard manager.

Capture timing starts when the microphone stream actually opens, not when model preparation or the panel starts. A finish before readiness or before 0.75 seconds of real audio cancels silently; one owned 250 ms tail task preserves the last phoneme and suppresses duplicate finish gestures. Session cancellation closes the transcription feed immediately, stops local resources, fences stale state, and prevents later insertion. Audio feeding and peak calculation run off the main actor; only the meter mutation crosses back. A single cancellable failure-dismiss task prevents an older error from closing a restarted session. `DictationAssembler` joins confirmed plus partial text and requires lexical content, so punctuation-only noise never pastes. A pre-transcription VAD is deliberately absent because live Parakeet silence yields no segment; the batch-Whisper hallucination class is handled elsewhere. The Settings toggle remains off by default. Verified E2E: the hotkey triggers with the app in the background, the panel transcribes live audio, and final insertion works in the field.

**Mouse-button push-to-talk (Jul 2026)**: `MouseButtonPTT` owns one session `CGEventTap` over `otherMouseDown`/`otherMouseUp` that CONSUMES the configured button (the app under the cursor never sees the click) and passes every other button through; a tap disabled by timeout is always re-armed. CGEvent index 2+ is eligible — vendor-facing Button 3+ means middle click or an additional button — while indices 0/1 (left/right) can never become a trigger. Invalid persisted values normalize to Off. The tap needs the same Accessibility trust as the paste path: choosing a button prompts once, a denied/pending prompt leaves the keyboard trigger working, and returning from System Settings retries registration. Rebinding first cancels any mouse-owned capture so its consumed release cannot strand the session. `MousePTTGesture` (app input boundary, pure, 3 tests) is the decision table: press starts when idle and finishes a listening session whoever started it; release delivers only when the button itself started the session, so a stray release can never double-finish a hotkey session. There is no tap-vs-hold discriminator on the mouse — the capture minimum already cancels an accidental click. `MouseButtonRecorder` in Settings captures the next middle/additional-button click (`settings-dictation-mouse-recorder`; Esc cancels) with an explicit clear control; both mouse and keyboard recorders remove their local monitors when their Settings row disappears.

**Two-tier dictionary, filler filter, and constrained language (Jul 2026)**: `DictationTextRules` (TranscriptionKit, pure, 10 tests) is the deterministic tier — one non-cascading pass of user-defined whole-word, case-insensitive replacements applied longest-trigger-first with punctuation-aware lookaround boundaries (regex-metacharacter triggers like "c++" match literally; replacement strings including `$` and `\` stay literal). Matching is computed against the original text, so a preferred spelling can never become input to a later rule. The codec trims triggers, drops empty rules, and keeps the newest case-insensitive duplicate before the Settings list or matcher consumes it. A conservative bilingual hesitation-filler pass (only tokens meaningless in BOTH languages: um/uh/er/hmm/eh/ehm…, on by default via `dictationFillerFilter`) runs first and repairs seams (collapsed spaces, no space stranded before closing punctuation). The other tier remains the existing vocabulary prompt, which biases the model DURING transcription. Rules persist as one JSON string (`dictationReplacements`, codec in the same type) edited by `DictationDictionaryEditor` in Settings (quick-add row `settings-dictation-dict-add`; re-adding a trigger updates it instead of stacking an unreachable duplicate). Both passes run in `deliver` on the final dictation text only — meeting transcripts stay verbatim records. `dictationLanguage` constrains dictation to {es, en}: any stored value outside the pair means auto-detect (`settings-dictation-language`); the engine-level candidate-set restriction the strategy imagined does not exist in the Parakeet API, so "Automatic" delegates to the engine's multilingual detection.

## Views and flows

**LibraryView + LibraryModel**: `New recording` (⌘N), FTS search with snippets, **"To-dos" section** (open action items from ALL meetings; click navigates to the meeting), recency-grouped meetings with `Rename`/`Delete`, Recently Deleted restore/permanent purge, import progress/errors, and calendar briefs. The per-window model owns data, debounce, mutations, and effects through its narrow client; the SwiftUI views own rendering, native presentation, AppStorage disclosure state, file picking/drop acceptance, and route binding. Library and Meeting Detail deletion plus Recently Deleted restore/permanent purge still enter through ApplicationKit use cases; launch cleanup uses the same purge boundary for tombstones strictly older than 30 days. Existing controls, navigation, and degradable filesystem behavior remain while scoped observations update only their owning sections. `library-search-field` provides a stable automation boundary for the real FTS/model wiring. The query adapter expands a deterministic local English/Spanish meeting lexicon and StorageKit ORs complete language variants while keeping terms inside each variant conjunctive; `unicode61` folds Latin accents. Exact rows publish first. When Apple Latin embedding assets are already installed and capture is inactive, a shared ApplicationKit search actor appends bounded semantic paraphrase/cross-language hits from already-published vectors without downloading assets, writing the corpus, or replacing exact rank (D145/D197). Ask and Library share one typed readiness resolver; launch, searchable mutations, and capture completion wake the sole no-poll product writer, which uses the process coordinator and installed assets (D176/D178/D197). Search rows publish their exact timestamp through the shared one-shot seek channel before routing. While capture is preparing, recording, or processing, the main action becomes identified `Return to recording`; browsing history cannot hide the live timer and Stop control or create a second session. UITests use `firstMatch` for to-dos because a meeting title also appears as the row caption.

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
the next scheduled wake. Its public store/capability ports, configuration
snapshots, progress events, issues, and request/result envelopes live in a
separate ApplicationKit contract owner; executable policy retains private
dependencies in the workflow implementation. Intentional workflow cancellation
returns the owned job to pending through the ApplicationKit store
port before emitting a `suspended` telemetry outcome. StorageKit clears its
lease and refunds the claim attempt, and the current drain invocation stops
before claiming more
work; a crashed or otherwise lost worker instead leaves `running` evidence
whose lease expiration is recovered at launch. This preserves the bounded
retry budget and makes suspension distinguishable from worker death
without adding a poll. `AppPostCaptureProcessingCapabilities` retains
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
- **Commitment confirmation (D239):** a separate section renders only pending
  newest-summary candidates with current source evidence. Every candidate has
  its own source seek, dismiss, and bounded defer choices; bulk actions cannot
  hide evidence. `Review and confirm…` opens an editor for wording, the local
  user, one exact canonical participant, or no owner, plus an optional user-
  entered date. The action is disabled for stale or missing evidence. The
  section owns transient editor and progress state only; its immutable values
  and explicit intents route through `MeetingDetailModel`,
  `MeetingDetailCoordinator`, and
  `ManageMeetingCommitmentInbox`. The UI neither imports StorageKit nor infers a
  person or deadline. The three ownership states remain distinct after
  persistence and portable replay. All controls have stable accessibility
  identifiers and a dedicated disposable `-seed-commitment-inbox` fixture
  verifies the English and Spanish journey without changing the default seed's
  identity behavior.
- **Global Commitment Radar (D241/D266/D269):** Library exposes one dedicated
  Radar route with explicitly separate **Confirmed**, **To review**, and
  **Quality** modes. A
  per-window `CommitmentRadarModel` maps owner,
  due-date, and activity filters to a narrow ApplicationKit client, fences stale
  async responses, and switches presentation-only grouping between canonical
  owner and exact source meeting without reloading. Cards expose bounded source
  and lifecycle counts, optional details, and the first exact meeting link; the
  shared typed route opens that durable source. Generated candidates remain
  suggestions until explicit confirmation in Meeting Detail; the separate
  **To review** mode only adds a bounded library-wide route back to that source.
  The view imports neither StorageKit nor Intelligence, and project/topic
  grouping is unavailable until a canonical entity exists. Stable identifiers
  and the disposable
  `-seed-commitment-radar` fixture verify filtering and exact source navigation
  in English and Spanish. D266 preserves that confirmed page while loading the
  D265 generated-work queue into independent state. Suggestion cards can only
  dismiss, defer, or reopen the complete source meeting; current evidence seeks
  to its exact transcript time, while stale/unavailable evidence opens without
  a false exact-focus claim. Direct confirmation remains in Meeting Detail.
  D269 observes the first real review-card appearance through an idempotent
  ApplicationKit use case; dismiss/defer retries that observation first, but a
  failed advisory write never blocks review. The independent Quality request
  returns only aggregate rolling 90-day scorecard values to SwiftUI—never owner
  tokens, observation identities, source IDs, or meeting content—and explicitly
  labels them private and advisory. No metric can mutate a candidate, schedule
  a reminder, automate a decision, or approve a serving threshold.
- **External App Entity focus (D325):** the same per-window Radar model accepts
  a typed canonical-person or exact-commitment focus without turning it into a
  durable filter. Person focus temporarily uses that exact owner across all
  due/activity states; commitment identity takes precedence over all prior
  filters. A visible banner names the current item/person when available and
  exposes identified **Show all** to restore the window's preserved owner,
  due, and activity selections. The focused storage read remains bounded and
  does not hydrate unrelated Radar roots.
- **Durable Radar actions (D256):** each confirmed card can change its due date
  or be completed, and each completed card can be restored. The window model
  serializes one mutation, preserves the visible page on failure, and reloads
  its bounded query after success. `ManageCommitmentRadar` owns event identity,
  timestamp, and the append-only transition; SwiftUI never writes StorageKit or
  invents source history. Reminder snooze remains outside this surface because
  it must not alter the commitment due date.
- **Commitment review queue (D265–D266):** ApplicationKit exposes one
  read-only, clock-sampled request for either the whole library or an exact
  bounded meeting set. It returns only pending evidence-backed generated work,
  carries explicit root/evidence truncation, and may suggest an owner only from
  an exact canonical person link. This is not a second confirmation surface:
  the evidence rows are a preview, direct confirmation remains in Meeting
  Detail. The whole-library read is composed only in Radar's visually distinct
  **To review** mode through the existing inbox mutation manager; it does not
  add pre-meeting composition, reminders, sync, export, CLI, or MCP behavior.
- **Commitment reminder delivery (D257–D264):** the lower layers
  distinguish commitment truth from local delivery state through a due-date-
  fenced current projection and immutable schedule/present/snooze/dismiss/
  cancel history. ApplicationKit now owns one fail-closed reconciliation over
  a complete-count bounded page and a content-free idempotent scheduler port.
  Matching schedules are reasserted after relaunch, stale active delivery is
  cancelled, changed due dates replace the schedule atomically, and terminal
  user decisions never rearm themselves. The macOS executable now provides a
  `UserNotifications` adapter that distinguishes pending from already-delivered
  requests before upsert, removes both locations on cancellation, uses generic
  localized copy plus content-free identity/date metadata, and exposes an
  explicit authorization request without invoking it during reconciliation.
  Already-delivered requests append durable presentation history rather than
  alerting again. `AppServices` now owns one process-wide reminder model. Launch
  checks authorization without prompting; only the explicit Radar **Enable
  reminders** action requests it. Authorized state reconciles on launch and
  after successful Meeting Detail confirmation or Radar lifecycle/due-date
  mutations. Bursts coalesce into one active pass plus one rerun, with no
  polling timer. Radar presents not-determined, denied, active, reconciling, and
  failed/retry states. Disposable UI-test stores use an in-memory notification
  center, so the real Mac permission and Notification Center remain untouched.
  The native notification category and delegate are installed before launch
  finishes. Foreground delivery and a default alert tap decode only stable
  identity/date metadata and call an ApplicationKit workflow that records one
  `present` transition only when both the active scheduled time and source due
  date still match. Repeated delivery is idempotent; replaced, terminal,
  missing, malformed, and chronologically impossible input cannot revive work.
  A default alert tap then follows the shared process route to Commitment Radar
  and activates Portavoz. The category additionally offers one background
  **Remind me in 15 minutes** action. It forwards only the same opaque metadata
  to an ApplicationKit workflow, which records exact presentation plus snooze,
  preserves the confirmed due date, ignores stale/repeated responses, and
  signals process-owned reconciliation without opening the app. Clearing a
  native alert is also observed through the category's custom-dismiss callback.
  ApplicationKit records its exact delivery plus terminal dismiss while the
  schedule and due-date fences still match, so relaunch cannot silently rearm
  it; the delegate neither activates Portavoz nor accesses StorageKit. Review
  queue composition is limited to post-meeting global review; external-sync
  mutation signals remain absent.
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

**SettingsView (⌘,)**: Language (use system language or force English/Spanish, saved in `@AppStorage("app-language")`, applies `\.locale` live to `ContentView` and `SettingsView`) · Intelligence language policies (`transcriptionLanguage`: "Auto-detect" / "English" / "Español" for recognition only; `summaryLanguage`: "Meeting language" / "English" / "Español" for generated output only) · capability-aware Summary engine selection whose localized recommendation action is prominent and whose unavailable Apple state names Ollama/MLX recovery · proactive Whisper Turbo/Compact rows with select/download/retry/delete, background preparation progress that says download occurs only when needed, stable `settings-whisper-*` accessibility identifiers, and full catalog-integrity verification before any model is shown as downloaded (D71/D113). Whisper artifacts live under user Application Support rather than either app bundle, so Dev reinstall and normal application updates preserve them · Audio (always-on call-safe raw capture status, preferred mic with visible fallback, capture mode auto/app/system and disclosure of scope; no VPIO/AEC recording toggle, D125) · Recordings (configurable folder with migration and progress) · Titles (template with help popover of tokens, insertable chips, `Reset` button, and live preview) · Vocabulary (list editor: Enter adds, − removes) · My voice (enroll 12 s / delete — destroys file+key) · Apuntador activation/status (enabled here or from recording only when the macOS 26 Apple classifier is available; Sequoia explains the requirement while retaining Mirror) · External model BYOK (endpoint/model in defaults, key through the async application secret boundary into this-device-only Keychain, answer-provider opt-in disabled until everything and the Apuntador classifier are available; deleting key turns it off — spec 04) · GitHub (same injected secret boundary) · explicit local redacted support export in Your data (`settings-export-diagnostics`, D76) · whole-library Markdown backup with the native `NSOpenPanel`, visible progress, localized complete/partial/fatal status, bounded bookmark access plus a private publication/failure journal, and no Store or IntegrationsKit coordination in SwiftUI (`settings-export-all-button`, `settings-backup-progress`, `settings-backup-status`, D99/D180–D189). A one-shot app route lets any feature open an existing or new Settings window at an exact category (D72). `AppServices` is the sole app constructor of PlatformKit security and permission adapters; onboarding renders permission state and invokes app adapters rather than importing AVFoundation or EventKit.

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
`meeting-detail-scale-5000-segments` app-window screenshot. This proves that
the scoped summary stream remains functional at scale; it does not substitute
for the unavailable SwiftUI update-cause lane.

The characterization baseline freezes the complete surface before decomposition. The generated
`meeting-detail-interaction-contract.json` snapshots 262 state/control/
presentation/keyboard/identifier/navigation signals across twenty reviewed
detail files and assigns all 23 `MeetingDetailUITests` journeys to exactly one
of ten feature owners. Screenshot names are derived from their test bodies;
changing a control, route, owner, screenshot, or reviewed evidence digest
requires an explicit snapshot update.

The scale fixture now accepts an explicit bounded segment count. Performance
automation additionally requires `-detail-performance-profile` together with
`-use-temp-store` and `-seed-scale`; playback uses a generated six-second
two-channel clip, while the 20k scroll profile has no audio. Production
launches cannot activate these journeys. The Aug 2026 Xcode 26.6 baseline
records 5k/20k first content at 111.25/197.35 ms, exactly five playback seeks
at p95 0.52 ms, exactly five transcript scrolls at p95 331.94 ms, and zero app
hitches or potential hangs. Time Profiler contains both detail and transcript
symbols. SwiftUI emitted no update rows for either profile, so exact body
invalidation counts remain explicitly unavailable (D222).

## UI verification — XCUITest first (Jul 12)

`make test-ui` (XcodeGen → `Portavoz.xcodeproj` → `xcodebuild test`)
defines 57 XCUITest cases in `Tests/PortavozUITests`: Automation (the
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
**Real bug caught by local crash reports (D287, Aug 2026):** clear playback
emitted one attack ramp per local turn and one release ramp after it, but
`CleanPlaybackPolicy` merged only *overlapping* ranges. Two turns separated by
less than `attack + release` therefore produced overlapping ramps — observed as
a release of `[262.680, 262.800]` followed by an attack of `[262.700, 262.760]`
nested inside it — and `AVMutableAudioMixInputParameters` answered with an
Objective-C exception, aborting the app as soon as Meeting Detail prepared
playback. Nine of 39 real local meetings were unopenable, and Refine could
introduce the condition by rewriting turn timings. `volumeSchedule` now returns
the complete typed event timeline as pure policy and the composition only
replays it; ranges stay separate only when `canDuckBetween` proves the earlier
release ends no later than the later attack starts, using the same arithmetic
the schedule emits. `isStrictlyOrdered` revalidates at the AVFoundation
boundary and returns no mix rather than aborting.

**The same crash through the gap the check did not cover (D302, Aug 2026):**
that validation ran on `TimeInterval` seconds while the schedule is delivered as
`CMTime` at timescale 600. Two events ordered by microseconds are one instant
there, so a ramp proven non-empty in seconds could still reach AVFoundation
empty. The timescale now belongs to the policy: `CleanPlaybackPolicy.tick`
quantizes, `isStrictlyOrdered` compares ticks, and the composition builds
`CMTime` from that same tick. `audibleRanges` refuses a bound with no tick at
all — a non-finite or astronomically large time would make the ordering check
reject the whole schedule — and drops a turn shorter than one tick because such
a turn raises and lowers the microphone at the same instant, so its instructions
do nothing. (Keeping it would still pass the check; only the representable
guard is load-bearing.)

## Skill proposals in Meeting Detail (D316/D327/D328, Aug 2026)

The skill tier's first surface anchors proposals to their subject at zero
vertical cost. `SkillOfferMenu` (in `SkillOfferBanner.swift`) renders a badged
sparkles menu beside the document actions once the meeting has a summary,
offering four meeting-scoped skills: local recap draft, review-first email
recap draft, secret GitHub Gist publication, and text-only package export. The
placement is load-bearing:
Meeting Detail's column is
deliberately packed — a banner inside the height-ratcheted artifacts viewport
pushed the document's own controls out of the box (seven gates failed), and a
banner above it displaced the sections below (four more) — so proposals
occupy a slot that exists whether or not they do. Each row opens `SkillConfirmSheet`, which shows the exact
artifact — the composed recap verbatim, complete Gist Markdown/filename/host,
or the meeting title plus the destination already chosen in the native save
panel — and the declared capability chips. Confirming runs `ExecuteSkill`
(claim before effect, typed failure categories); the durable receipts render in
`MeetingDetailTrustSection` beside the privacy receipt as
`skill-receipt-<skillID>` rows.

Offer policy is durable state, never session memory: dismissal writes
`skillOfferDismissal` (v34) keyed by the stable intent identity, a succeeded
recap retires its offer, an interrupted one-shot draft whose effect may have
started stays out rather than inviting a duplicate, export keeps offering per
destination, and a failed run keeps offering because retry is legitimate.
Recap delivery is the pasteboard — the same act as the manual sheet's Copy —
and the export writes
one atomic text-only `.portavoz` file. The local, email, and Gist one-shot execution
keys are read in one bounded exact-key batch; meeting receipts reuse that batch
plus one literal package-prefix read instead of one query per Skill.

The exact preview owns one proposal UUID and one proposal timestamp for its
complete presentation lifetime. A failed Confirm leaves the sheet on both, so
retry advances the same durable attempt without renewing the 15-minute
confirmation window or colliding with its idempotency key. If the
sheet is reconstructed after failure, the app looks up the exact key and
reattaches to its original proposal owner; it never transfers a claim between
UUIDs. The fail-once XCUITest adapter exists only with disposable storage and
hands the second attempt to the real pasteboard boundary. A recoverable reason
is rendered inside the still-open confirmation sheet beside the retry control,
not only on Meeting Detail behind the modal.

The preview remains load-bearing until handoff. Confirmation re-composes the
current durable recap and compares it with the approved subject/body before it
writes a claim; changed material returns a stale-proposal failure and requires
a fresh sheet. The accepted material is then captured for the effect, so no
second store read can change the clipboard artifact. `NSPasteboard.setString`
returning false settles the run as a typed recoverable failure. Once execution
starts, Cancel and interactive sheet dismissal are disabled; cancellation in
the smaller confirmed-before-begin gap records a visible terminal no-effect
receipt instead of stranding the run.

One SwiftUI constraint is load-bearing here: an empty ViewBuilder branch is
never installed, so the menu renders a hidden 1×1 anchor while empty —
otherwise the `onAppear` that triggers the offers load (through the
coordinator; the view file stays effect-free) could never fire, and the
menu could never learn it has offers to show.
XCUITest covers the whole journey in one launch
(`testSkillProposalJourneyFromBannerToReceipt`, EN+ES): offer menu → exact
preview → confirm → clipboard artifact → receipt → offer retirement →
durable dismissal. D321 adds a second bilingual journey that refuses the first
pasteboard handoff, retries the unchanged preview, and requires the successful
receipt plus byte-for-byte clipboard artifact.

## Review-first email recap handoff (D327, Aug 2026)

The first external Skill is deliberately a draft handoff, not an email sender.
`EmailRecapDraftSkill` lives in `ExternalSkills`, separate from the four local
definitions whose no-egress invariant remains executable. It declares
`readMeetingMaterial` plus `sendRemote`, is irreversible, and requires explicit
confirmation for every proposal. The meeting UUID is its only typed argument
and its stable idempotency key; recipients never enter the proposal because
Portavoz does not infer an audience.

Preview and execution reuse the existing summary-only `RecapComposer`. The app
captures one durable meeting/speaker/summary snapshot, renders the subject and
plain-text body, and tags the preview as email-specific so approval of a local
clipboard recap cannot authorize this boundary. Confirmation re-reads and
recomposes current material before the durable claim. Any subject/body or
surface mismatch fails stale with no handoff. The sheet displays the entire
subject and body, states that there are no recipients, and warns that the email
app may save or sync the text while Portavoz never sends it. The longer
capability labels adapt vertically when the localized row does not fit.

Only that sheet's **Open email draft** action supplies egress permission to
`ExecuteSkill`. Production creates `NSSharingService(.composeEmail)` inside
one main-actor operation, verifies that it can accept the body, explicitly
sets an empty recipient list and the approved subject, then performs the
handoff. No email SDK, network request, credential, AppleScript, recipient
lookup, or Send command exists. AppKit offers no synchronous proof that the
user saved or sent the draft, so success and its content-free receipt mean only
that the composer handoff was requested. An unavailable service settles as a
recoverable failure and keeps the original proposal retryable. A successful
handoff retires this meeting-scoped offer independently of local recap and
package export. An interrupted `executing` owner also keeps the offer absent:
the system composer may already have opened, so a duplicate cannot be proved
safe; its content-free receipt remains the recovery evidence instead.
That ambiguous receipt is labeled **handoff status unknown**, never **did not
open**.

Disposable XCUITest composition selects an inert opener that accepts non-empty
approved material but cannot launch the host email client. The bilingual
journey proves exact seeded-summary content, recipient and sync disclosures,
the localized submit boundary, unchanged clipboard, foreground app ownership,
receipt, and per-offer retirement. Physical default-client presentation and
handoff behavior on Sequoia and Tahoe remain field evidence.

## Review-first secret Gist publication (D328, Aug 2026)

`SecretGistPublishSkill` is a separate external definition with
`readMeetingMaterial`, `sendRemote`, and explicit per-proposal confirmation.
Its one typed argument and stable one-shot key are the meeting UUID. Meeting
Detail uses `PrepareMeetingDocument` to render the current canonical Markdown,
then previews the complete bytes, slugged filename, title description, and
fixed `api.github.com` host in a `SecretGistDraft`. The sheet explicitly says
that GitHub's secret Gist is unlisted rather than access-controlled: anyone
with the link can read it. Confirmation re-renders and compares the entire
draft before any claim, so changed meeting material requires a fresh review.
The potentially long exact body uses a selectable, read-only TextKit viewport
instead of a monolithic SwiftUI `Text`; the optimization does not truncate the
approved document.

The app prepares the existing Keychain-backed `AppGistDocumentPublisher`
before `ExecuteSkill`; a missing GitHub token is therefore a pre-egress
recoverable setup error. The exact proposal UUID becomes the
`DataEgressEventID` used by `URLSessionDataEgressGateway`. That event is
inserted before `URLSession`, so replaying the same stable proposal after an
ambiguous attempt hits the local primary key before a second request. GitHub
does not provide a create-Gist idempotency key, so every failure after publisher
preparation is intentionally shown as **outcome unknown**. Failed, interrupted,
or executing Gist receipts suppress re-offer and expose no retry action; the
user is directed to inspect GitHub first.

A successful 201 and local settlement shows the returned URL and leaves both
the content-free `publish-github-gist` privacy event and the ordinary Skill
receipt. If the URL arrived but settlement failed, it remains available only
in the confirmation sheet's terminal unknown-outcome surface; durable state
never stores the URL, token, or document. Disposable XCUITest composition
executes the same renderer, request codec, egress metadata validation,
proposal, effect, settlement, and store receipts but replaces network
transport with a stable
provider-shaped response. That proves app behavior, not physical GitHub,
browser, Keychain, or network behavior on Sequoia or Tahoe.

## Suggested-actions control center in Settings (D317/D333/D335–D343/D359/D369–D379, Aug 2026)

Settings includes a dedicated **Suggested actions** / **Acciones sugeridas**
pane driven by
`LoadSkillControlCenter`, not preferences or view-owned policy. Its central
catalogue marks recap draft, review-first email recap, secret Gist publication,
text-only package export, resident pre-meeting brief, and confirmed-commitment
reminder draft as available. The pane exposes an independent
global pause, per-available-skill enablement, and a segmented content-free
history view. A localized explanation states that Portavoz derives these
review-first actions from meeting evidence and that nothing runs before review
and confirmation. **Recent** contains every newest durable execution, **Waiting**
contains confirmed runs that have not begun, **Attention** contains executing,
failed, and any unknown future state, and **Completed** contains succeeded and
pre-handoff cancelled runs. It never executes a skill and does not invent egress
consent or standing rules; enabling an external row is not permission to hand
off content, because that authority exists only on the exact confirmation
sheet.

A separate **Suggestions to review** section reviews offers that the real Meeting Detail,
resident calendar, and Commitment Radar producers successfully reconciled into
schema v40. It is not reconstructed by scanning meeting, transcript, commitment,
or calendar content. Each row receives only an unrelated review UUID, current
Skill identity/version, one typed reason, the exact declared input-data classes,
and first/last observed times. It explains why the offer appeared and lists the
categories it may use without receiving the stable offer key, opaque subject,
title, transcript, preview, arguments, destination, or recipient. The privacy
copy keeps the exact preview and confirmation on the original surface.
**Review in context** sends only that unrelated review UUID; a transient typed
resolution can route meeting rows to Meeting Detail and commitment rows to the
focused Commitment Radar, while the bounded list itself remains subject-free.
Calendar rows show **Review in menu bar** because SwiftUI has no public action
for programmatically opening `MenuBarExtra`. **Dismiss** independently sends the
same unrelated UUID and never receives the stable offer identity.

Every built-in `SkillDefinition` declares a nonempty input-data ceiling in
addition to effect capabilities, and every exact `SkillProposal` requests a
nonempty subset before admission. Reconciliation is bounded to 200 candidate
intents, central review to 100 storage rows and 50 application rows. The review
prunes expired calendar offers, revalidates every record against the current
catalogue version/reason/data contract, and honors both the global pause and
individual disablements. Subject deletion cascades meeting and commitment rows;
calendar rows expire at the original event start because EventKit identity stays
opaque. Dismissal and one-shot execution admission retire the exact offer
authority atomically. Package export remains intentionally reusable: its offer
is destination-free, while every approved destination owns a separate exact
execution claim.

Central dismissal resolves a still-live review UUID, writes the existing
stable-intent tombstone, and deletes its authority row in one storage
transaction. An expired, concurrently retired, or repeated UUID returns one
content-free unavailable result and the app reloads authoritative rows. A
storage failure retains the original row, shows an inline retry, and leaves
verified pause/enablement usable. No optimistic removal is accepted. A stale
producer reconciliation skips already-dismissed active keys in the same write,
so it cannot recreate the row after reading subject state earlier.

A verified empty or populated proposal projection exposes **Refresh suggested
actions**. The action performs only the existing bounded content-free review
read, so offers created, retired, paused, or disabled from another product
surface can be reconciled without closing Settings. During that read, the last
verified rows remain visible only as disabled evidence and an identified
refreshing state replaces the action. Failure removes those rows and returns
to the existing unavailable **Try again** path. Initial loading and
unavailability have no competing refresh; receipt loading remains independent,
while control and proposal mutations fence the action. There is no timer,
polling, observer, new store, proposal mutation, or execution authority.

Every row and review, dismissal, retry, or resident action also receives a
localized **Proposal n of total** accessibility suffix derived only from the
current bounded verified order. The random review UUID remains SwiftUI identity
and the existing 50-row application ceiling bounds enumeration. Two meetings
that propose the same Skill therefore have distinct English and Spanish Voice
Control/VoiceOver names without revealing either subject. The ordinal is not
durable and may change when the verified list changes; no stable offer key,
subject UUID, title, transcript, preview, argument, destination, or recipient
enters the label. The enumerated rows use a bounded compatibility array because
the SDK's direct `EnumeratedSequence` collection conformance is macOS 26-only;
Sequoia support remains unchanged.

An already-open exact confirmation is also fenced. `ExecuteSkillRequest`
carries the reviewed offer key separately from the effect's idempotency key;
storage accepts equality for one-shot work or the exact `offerKey:` prefix for
destination-scoped package exports. The durable claim resolves an exact owner
first and checks the dismissal before granting a new one. Thus whichever SQLite
write commits first owns the outcome: a prior dismissal refuses the stale
execution, while a prior claim remains idempotently resolvable because it has
already durably accepted the user's subject-surface approval.
Opaque provider identity bytes are preserved. Settings still cannot confirm,
execute, or create standing rules.

The inert return path revalidates the current catalogue version, typed reason,
global pause, individual enablement, expiry, dismissal, and exact subject shape
before routing. Missing or concurrently retired authority returns one
unavailable result and reloads the list; a thrown read retains the row and
shows an inline retry. The primary `WindowGroup` carries the constant Codable
value `MainWindowIdentity.primary`, so `openWindow(id:value:)` fronts the one
existing library window rather than creating a duplicate. `pendingRoute`
still handles both warm and cold main scenes, and Settings dismisses itself
after the destination is admitted. No proposal is constructed or executed.

Closing a receipt inspector without choosing a recovery route returns keyboard
and assistive focus to the exact receipt row that opened it. Settings retains
only that proposal UUID until native sheet dismissal finishes, then sends one
focus request to `SkillActivitySection`; the row owner applies local SwiftUI
keyboard and accessibility focus after its reconstructed focus scope is ready.
Choosing recovery clears the request because Settings is about to close. The
native Escape dismissal remains the modal cancel contract, and no receipt
payload or execution authority is added to the focus path.

Loading, unavailable, empty, and populated activity are mutually exclusive
presentation states. Loading takes precedence even when a previous snapshot
matches the selected scope, so changing scope and refreshing after a verified
receipt mutation both remove old rows before awaiting storage. Each verified
empty title names Recent, Waiting, Attention, or Completed and describes what
would appear there; it never implies that history was deleted.

The control-center use case begins policy and bounded receipt reads together but
preserves their separate authority. A missing or corrupt policy still fails the
whole pane closed. A receipt-only read failure returns the verified policy and
catalogue with no receipt rows plus an explicit unavailable marker. Settings
therefore keeps policy and proposal actions usable, exposes only the activity
retry, and never labels an empty array as verified history. A policy mutation may
start while a receipt read is pending: it invalidates the older load identity,
owns its write and fresh snapshot, and prevents the late read from overwriting
the mutation result.

Empty and unavailable transitions expose combined localized status semantics
and request one medium-priority VoiceOver announcement through the public
AppKit application notification. Loading remains silent to avoid repetitive
speech, and Retry stays a separate keyboard-reachable button. The app retains
no observer, timer, window, or accessibility object for this handoff.

The switches write SQLite v35 state. Global pause leaves every individual
choice intact; resuming restores those choices. Meeting proposals read the
same state and disappear while paused or disabled. A confirmation sheet that
was already open still has no stale authority: `ExecuteSkill` re-reads policy
immediately before admission and before any durable claim or effect. Missing
or corrupt singleton state fails closed. A Settings read failure shows an
explicit unavailable/retry state and never renders an implicit enabled
control.

If a control mutation or its owned verification read fails, Settings retains
the last verified snapshot, disables all policy switches, and exposes one
**Reload controls** action in the same pane. That action calls only the
generation-fenced control-center read; it never repeats the ambiguous mutation,
because the write may have committed before its response failed. A successful
read replaces pause, per-Skill, receipt-scope, and receipt state with durable
truth and re-enables the switches without reconstructing Settings. Another read
failure keeps the stale snapshot disabled and the reload action available.

Each available row also renders two independent truths. Its transfer boundary
is derived from the definition's declared capabilities: `sendRemote` means the
material may leave Portavoz, while every other contract says only that Portavoz
performs no direct network handoff. The latter deliberately does not claim that
a chosen file destination, clipboard consumer, Reminders list, or other native
app cannot sync. The second label derives from `confirmationPolicy`; all current
Skills therefore disclose that approval is required for every run even while
their enable switch is on. Titles and skill identifiers never select either
privacy statement.

Every activity scope is bounded before presentation (20 by default and 50
maximum). ApplicationKit requests exactly one additional continuation sentinel,
so the actual storage limits are 21 or 51 and remain below StorageKit's hard
100-row boundary. The sentinel never enters the returned visible receipts.
Results are ordered by `(updatedAt DESC, proposalID ASC)`. The user may choose
one exact available catalogue Skill or **All actions**, plus **Any time**, the
past 24 hours, past seven days, or past 30 days. ApplicationKit resolves the
rolling period from a fresh reference date for every explicit read, while
StorageKit receives only an optional inclusive absolute `updatedAt` lower bound.
The optional identity and time predicate are composed with the lifecycle
predicate before `LIMIT`; the view never filters an already-loaded page and
therefore cannot fabricate an empty result for older matching receipts. A
non-catalogue identity or non-finite reference fails before either
control-center store read, while malformed storage identities or cutoffs return
no rows.

Recent uses its full v35 index; schema v39 adds one partial direction-matched
index for each state scope. Schema v42 adds one full and three state-partial
`(skillID, updatedAt DESC, proposalID ASC)` indexes for exact-Skill reads. The
period predicates reuse the same filtered or unfiltered indexes and add no
schema. The query explicitly pins the matching index so an empty or sparse
scope cannot fall back to a state-leading index plus a temporary sort.
The Attention predicate excludes only known waiting and terminal states, so a
future state remains visible for review. Malformed durable proposal identities
fail the projection instead of silently disappearing from the audit surface.

Each selected scope begins with the 20-row application window. **Show more
runs** appears only when the verified 21st row proves that more matching history
exists. Exactly 20 matches therefore render all 20 without a false expansion
action or redundant 50-row read. Activation performs one explicit replacement
read at the existing 50-row ceiling. The control disappears after expansion,
even when a 51st sentinel proves that the product ceiling hides older history;
there is no infinite scroll, cursor accumulation, count query, or background
prefetch.
Changing scopes, the exact Skill filter, or the update period resets to 20
before the next read, while same-selection refreshes and verified policy
mutations retain the selected 20-or-50 limit and compute the rolling boundary
again. A returned snapshot is adopted only while its scope, Skill identity,
period, limit, and generation still match. The accessible menu values name the
current localized Skill and period. A verified period-filtered empty state says
the time period matched no run and also names the exact Skill when selected.
If that verified empty result still has an exact Skill or update-period filter,
**Clear activity filters** removes both in one action without changing Recent,
Waiting, Attention, or Completed. The ordinary selection task resets the
history window to 20 and reloads; the action disappears for an unfiltered empty
state, receipt rows, loading, and unavailable history. The empty explanation
and the identified button remain separate accessibility elements so the
control is not flattened into static copy.

A verified empty or populated scope also exposes **Refresh activity**. It
performs only the existing control-center read with the selected scope, exact
Skill filter, update period, and current 20-or-50 limit, so an execution that
changed outside Settings can be re-read without changing selection or
reconstructing the window. Refresh uses the normal loading state, hides stale
rows immediately, and keeps the same scope/Skill/period/limit/generation
adoption fence. It is absent
during loading and unavailability, where the existing retry remains
authoritative. No timer, polling, observer, receipt mutation, or execution
action is introduced.

The request and returned snapshot carry the selected scope, optional Skill
identity, and update period. Settings does not show an older snapshot under a
new selection while its read is in flight or after it fails. A receipt-only
failure presents an explicit retry and no receipt rows, while keeping the
independently verified pause and per-Skill controls usable. A failed control
mutation still disables those controls until their durable policy can be
verified again.

Each receipt row is an accessible button that opens the first AUTO-6 inspection
slice. StorageKit reads the current projection and its oldest-first append-only
events in one snapshot and verifies their predecessor links and projected tail.
`LoadSkillReceiptInspection` then replays the permitted confirmation, begin,
retry, success, failure, and pre-handoff cancellation transitions. Missing,
incomplete, impossible, or unknown evidence produces one explicit unavailable
state; it never fabricates a timeline. Storage probes at most 257 rows and
refuses to materialize more than 256 events for one receipt. The sheet shows
only the adapter-aware current status, causal event label, attempt number,
typed failure category, and timestamp. It does not
receive or render the idempotency key, arguments, destination, result, meeting
title, transcript, or summary. The inspection-error **Try again** repeats only
that read and cannot execute or retry a Skill.

Inspection does not make every receipt depend on execution policy. It reads
and causally replays the audit first. A non-failed receipt derives historical
source context without a policy read, and external/destructive failure guidance
derives its verification-only boundary the same way. Missing, legacy, or stale
subjects resolve unavailable before policy as well. Only a failed local receipt
with an otherwise-valid current subject/catalogue match reads global pause and
per-Skill enablement. Cancellation is checked around those boundaries, so an
unrelated policy failure cannot erase verified history or outside-outcome
guidance, while local recovery still fails closed.

A verified Waiting receipt has one additional action: **Revoke approval**.
The sheet sends only the proposal UUID to `RevokeWaitingSkillExecution`, which
can request only the existing pre-handoff cancellation transition. The action
is absent for executing, failed, succeeded, cancelled, missing, or unverified
receipts. SQLite serializes revocation with begin: revocation first records one
cancel event and prevents execution; begin first returns unavailable because
the effect may already have started. A thrown write keeps the waiting receipt
and an inline retry. A verified revoked or unavailable outcome reloads the
inspection and currently selected activity scope from storage. The sheet never
receives the offer or idempotency key, arguments, subject identity,
destination, result, or meeting content and therefore cannot execute or retry
an effect.

A verified failed receipt now derives one recovery classification from its
causal audit, projected typed failure category, exact v41 subject, current
catalogue version, and current global/per-Skill policy. A local recoverable
meeting or commitment run exposes **Review recovery in context**. That action
sends only the proposal UUID, re-reads the same authorities, and returns at most
an inert route to Meeting Detail or focused Commitment Radar. The destination
must rebuild a fresh proposal and exact preview before any new confirmation;
the receipt action itself cannot begin, settle, or perform the failed effect.
The sheet records that route and dismisses first. Its parent `onDismiss` then
opens the value-scoped primary scene and closes the weakly captured exact
presenting Settings `NSWindow` through one narrow AppKit boundary. A SwiftUI
`DismissAction` captured by the sheet or presenter does not own that window,
`dismissWindow` leaves the Settings host open after this modal transition, and
the process key window has already returned to the primary scene at that point.
The bridge keeps only a weak reference and invokes `close()` on that exact host.

Calendar recovery remains explicit guidance to use the resident menu-bar
surface. External or destructive failures expose only a warning to verify the
outside destination because the outcome may already exist. Missing/deleted
subjects, legacy pre-v41 receipts, disabled policy, stale catalogue versions,
and malformed histories provide no recovery action. A thrown route resolution
keeps the receipt and shows a retry for that read only. Settings still receives
no subject, arguments, offer key, idempotency key, preview, destination,
recipient, confirmation, or effect authority.

Every verified non-failed receipt separately classifies whether its current
source can be reviewed. Meeting and commitment receipts expose **Review source
in context** after the causal audit, exact catalogue version, subject kind, and
current foreign-key-backed subject all validate. Historical review deliberately
ignores global pause and per-Skill disablement: those policies gate proposals
and execution, not access to existing evidence. Calendar receipts instead
explain that their original event remains resident in the menu bar because
public SwiftUI cannot open `MenuBarExtra` programmatically. Failed receipts do
not receive this general route and retain the stricter recovery behavior above.

The source action sends only the proposal UUID and can return only the existing
inert meeting or commitment route. It neither changes the receipt nor runs the
Skill. Missing/deleted/legacy subjects, stale catalogue versions, mismatched
subject kinds, malformed causal history, and calendar subjects without a direct
opener return unavailable. A thrown resolution retains the receipt timeline,
the route retry, and the independent Waiting revocation action. Both source and
recovery navigation use the generic weak Settings-window bridge after the sheet
dismisses; neither route carries content or effect authority into Settings.

D379 freezes the 0.8.0 public catalogue at these six actions. Public copy uses
action vocabulary consistently while internal `Skill` types, IDs, migrations,
telemetry, and accessibility identifiers stay stable. User-authored actions,
standing rules, and additional workflow kinds are post-release scope rather
than incomplete 0.8.0 behavior.

Twenty bilingual XCUITest journeys cover the pane: plain-language review-first
comprehension; fail-closed control
loading; read-only recovery after an unverified control mutation; isolated
scope failure; stale-row-free activity transitions; explicit bounded history
expansion from 20 to 50; explicit same-scope refresh that preserves the expanded
window; isolated proposal failure;
successful and failed Proposed review routing; successful and failed Proposed
dismissal; successful and failed Waiting revocation; successful and failed
failed-run recovery routing; successful and failed non-failed receipt source
routing; exact keyboard/accessibility focus restoration; and the main
disposable journey. The mutation-recovery case proves the failed toggle never
looks committed before verification, controls stay disabled until a verified
read adopts the already committed durable value, and reload neither repeats the
write nor closes Settings. The source success returns a real Waiting fixture to
its exact Meeting Detail without a confirmation sheet or duplicate main window.
The history case seeds 25 content-free destination-scoped approvals, proves
exactly 20 rows appear initially, then reveals all 25 through one explicit
expansion whose control does not become unbounded pagination.
The refresh case selects that 25-row Waiting projection, expands it, triggers
the delayed production read through the identified refresh action, observes the
ordinary stale-row-free loading state, and verifies the 50-row window remains
selected when all 25 rows return.
The source failure preserves its causal event, receipt row, independent revoke
action, Settings window, and route-only retry. The main journey disables export,
pauses all Skills, proves offers stay absent, resumes without losing the
individual choice, confirms the remaining recap proposal, traverses all four
activity scopes, checks typed why/input explanations from real producers, opens
its causal receipt, and verifies both content-free boundaries.

## Resident pre-meeting brief proposal (D322, Aug 2026)

The existing next-meeting card now proposes the available pre-meeting brief
Skill when Calendar access already exists. The resident surface never prompts.
EventKit supplies one opaque `eventIdentifier`; Portavoz does not derive an
identity from private title, attendee, or timestamp content. Identifiers may
disappear after a full calendar sync or change when an event moves calendars,
so exact lookup failure retires the open confirmation as stale instead of
guessing another event.

Selecting **Prepare brief** composes the same cited `MeetingBrief` used by the
manual Library flow and shows that exact immutable artifact, its evidence, and
the two local capabilities before confirmation. The model allocates one
proposal UUID with that preview. Confirmation re-resolves the exact opaque
event and compares the complete event snapshot before `ExecuteSkill` claims the
attempt. The effect then crosses one process-owned local-draft boundary with
the approved artifact verbatim; it does not read Calendar, Ask, storage, or a
model after confirmation. Success retires the event-scoped offer, presents the
same artifact, and appears in the global Skills receipt history. Failure keeps
the original proposal retryable. A rebuilt presentation may resume only that
failed owner; a different owner that settled or may have delivered makes the
new preview stale. Dismissal is durable for that event, while
pause and per-Skill disablement remain independent global controls.

The confirmation, result, event actions, dismissal, errors, and capability
chips have stable accessibility identifiers. The bilingual XCUITest journey
mounts the exact production `MenuBarContent` and model in a disposable app
window because `MenuBarExtra` belongs to SystemUIServer and cannot be opened
deterministically across supported macOS versions. It proves exact preview,
confirmation, unchanged result, offer retirement, and the global durable
receipt without reading the host Calendar. Opening the actual status item on
Sequoia and Tahoe remains a field-shell check, not something this host claims.

## Confirmed commitment to Reminders proposal (D323, Aug 2026)

Commitment Radar now projects the Reminder Draft Skill only for confirmed,
non-deleted commitments on the current bounded page. `LoadReminderDraftSurface`
combines one policy read, one bounded dismissal read, and one batch execution
read for at most 200 exact idempotency keys. A succeeded receipt remains on the
commitment even while Skills are paused or disabled; only an actionable offer
disappears. A failed durable owner is the only retryable state, and retry keeps
that owner's proposal identity.

Selecting **Create in Reminders** opens the exact projected title and due date,
then inspects authorization without prompting. Portavoz requests Reminders
full access only after the explicit **Allow Reminders Access** action. When
authorized, it binds the preview to the default list's bounded opaque EventKit
identifier and visible title; no fallback list is selected. Immediately before
execution, the app re-reads the exact commitment and Skill policy, verifies the
durable owner, and re-resolves the approved list. The EventKit boundary checks
authorization and list identity again, constructs the reminder and saves it
through the same process-owned `EKEventStore`. A removed or renamed list,
permission change, stale commitment, or competing durable owner fails closed.
The sheet keeps an explicit **Refresh list** recovery action so a rename,
removal, or new system default can be re-resolved and shown before another
confirmation instead of trapping the user in a retry loop against stale data.
An external save error is deliberately reported as unverified rather than as a
known non-creation: the user is told to check Reminders before retrying because
an external store can fail after the handoff boundary becomes ambiguous.

Success retires the subject offer and leaves one content-free receipt both in
Radar and Skills Settings. Dismissal is durable only for that commitment. The
disposable XCUITest platform starts undetermined, grants access only through
the production permission action, exposes one exact fake list, and never reads
or writes host Reminders or TCC. The bilingual real-app journey covers preview,
explicit access, exact destination, confirmation, offer retirement, and both
receipt surfaces. Physical Sequoia/Tahoe TCC prompt, default-list, and save
behavior remain field evidence.
