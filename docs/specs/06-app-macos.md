# Spec 06 — macOS App (portavoz-app + packaging scripts)

Status: implemented, signed with Developer ID, and used in real meetings; published DMGs through 0.6.0 were accepted and stapled by Apple. D74 now requires the inner app to carry independent notarization evidence in the next release. Decisions: D20 (SPM + script, no checked-in Xcode project), D23 (packaging), D10 (distribution), D40 (evidence-first launch recovery), D43 (durable Stop), D44–D60 (application workflow, feature-state ownership/mutations, scoped Library/Insights/Meeting Detail reads, and inward product/read policy), D61 (implemented package boundaries only), D62–D73 (atomic generated artifacts, enforced meeting-content data-egress verticals, audio-first and role-specific model readiness, app-scoped Whisper preparation, and capability-driven intelligence setup), D74 (independent app/DMG notarization evidence), D75 (store-receipted egress and Meeting Detail privacy receipt), D76 (redacted support export, processing recovery, and content-free signposts), D77 (typed recording failures and app-owned recovery), D78 (measured App Sandbox defer gate), D79–D85 (measured detail, retrieval, waveform, and Spotlight scale), D86 (explicit canonical people), D87 (typed overview evidence navigation), D88 (explicit local claim feedback), D89 (decision evidence navigation), D90 (action-item evidence navigation), D91 (role-separated Companion evidence navigation), D97 (provisioned opt-in CloudKit composition).

## Structure

`portavoz-app` is an SPM `executableTarget` (SwiftUI + Observation, @MainActor). `scripts/make-app.sh [--release]` builds `dist/Portavoz.app`: Info.plist (usage descriptions in English: mic, system audio, calendar, Desktop/Documents/Downloads/removable volumes folders), embeds `Sparkle.framework` + rpath, exports `Resources/Localization/Portavoz/*.xcstrings` to `Contents/Resources/{en,es}.lproj/{Localizable,InfoPlist}.strings`, declares `CFBundleDevelopmentRegion=en` + `CFBundleLocalizations=[en, es]`, signs internal XPCs, hardened runtime (`--options runtime`) + `--timestamp` with real identity + entitlement `com.apple.security.device.audio-input` (without it, the hardened runtime blocks the mic). **No sandbox.**

- Signature: by SHA-1 of cert (`PORTAVOZ_SIGN_IDENTITY`) — there are TWO Developer IDs with the same name on the machine and the name is ambiguous.
- `make install`: renames only the freshly built bundle to `Portavoz Dev`, re-signs it with Hardened Runtime and a secure timestamp, deep/strict-verifies `dist/Portavoz.app`, copies it to `/Applications/Portavoz Dev.app`, deep/strict-verifies the installed copy, and only then launches it. It never writes `/Applications/Portavoz.app`.
- `make-dmg.sh`: with `PORTAVOZ_NOTARY_PROFILE`, first verifies the embedded CloudKit profile and exact signed production capabilities, then archives the app, notarizes/staples/validates it, creates the UDZO DMG + `/Applications` symlink, and separately signs/notarizes/staples the image. `verify-distribution.sh` mounts the final DMG, copies the app out like Homebrew Cask, and independently requires codesign, stapler, Gatekeeper, and CloudKit-profile acceptance.
- `make-release.sh <v>`: requires a Developer ID identity, notary profile, and Developer ID CloudKit/APNs provisioning profile; stamps version, DMG, `generate_appcast --account portavoz` (dedicated EdDSA key — the default from Keychain is for ANOTHER project), cask with sha256 → `dist/release/`.
- Sparkle 2.9: menu "Buscar actualizaciones…" (`SPUStandardUpdaterController`); `SUFeedURL` points to GitHub release; public key in `assets/sparkle-public-key`.

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

DB (`MeetingStore`) + lazy shared engines: `transcriber` (Parakeet), `diarizer` (with voiceprint if exists; `invalidateDiarizer()` after enroll/delete), and `whisper` (runtime loaded only for Refine/Import). `modelsState` drives visible live-model preparation. Parakeet and pyannote each have an independently retained, process-scoped task: concurrent callers join the exact verified capability instead of loading a bundle. Recording samples only an already-resident transcriber and starts audio immediately; background preparation may request both afterward. Durable first-pass recovery and Dictation request Parakeet only; Refine/Import request pyannote only at their attribution boundary and never acquire live Parakeet as a side effect. Whisper Turbo/Compact preparation has its own app-scoped serialized task and observable state. Settings can proactively start/retry/delete a variant; the task survives that window, Refine/Import join it, and successful completion retains only an opaque verified token until runtime allocation. The heavyweight runtime keeps its two-minute idle-release policy. Library, Insights, and Meeting Detail receive storage-independent updates from query-scoped Store observations; no app feature consumes a global `libraryVersion` counter.

`AppServices` also owns one process-scoped `SpotlightIndexer` actor (D85).
Launch and every searchable mutation call `requestSpotlightReindex()`; requests
coalesce for 250 ms and are not tied to a `ContentView` lifecycle. The actor
loads one consistent StorageKit projection, hashes its exact documents into a
compact client state, skips unchanged publication, and retries failures after
one and five seconds. Its private backend serializes access to the named
`app.portavoz.meetings.v2` index, uses complete file protection and 500-item
batches, and removes the released default-index domain only after the protected
index is ready. Temporary UI-test stores disable OS indexing. Internal status
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
processor, Store, and Companion adapters; `RefineService` retains only
per-meeting presentation/task state, explicit cancellation, and run-identity
fencing. D65 freezes the selected Whisper descriptor for that use-case
instance and supplies each non-silent channel with exact local content
evidence. One composite successful transcript run stays inside the review
draft until Apply commits it with accepted language, cast, transcript, segment
links, and next revision. A stale/discarded draft writes no success; a begun
failed/cancelled attempt is standalone best-effort diagnostics. Summaries remain
immutable and Companion refresh is post-commit optional work. D66 passes the
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

D67 makes app composition explicit for the first migrated egress vertical.
`RecordingController` and `CompanionRefresh` each inject IntegrationsKit's
`URLSessionDataEgressGateway` when assembling the optional Companion client.
The client exists only when endpoint/model/Keychain key and the persisted
Companion opt-in are present. Production generation supplies its source
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
adapter for Companion, summaries, and Gist publication. The Store records the
validated content-free attempt before URLSession; a recorder error fails the
operation before transport. Meeting Detail receives a fourth independently
merged receipt stream and shows a compact right-rail card. Complete new history
without remote attempts reads “No remote service used”; an upgraded legacy
meeting shows the tracking start date; any remote attempt shows purpose, host,
and time plus the conservative warning that content may have left the Mac.
Accessibility boundaries are `detail-privacy-receipt` and
`privacy-remote-event-<index>`. English and Spanish catalog entries preserve
the same evidence meaning.

D76 composes one `ExportSupportDiagnostics` use case above StorageKit's atomic
support projection. `AppServices` contributes app/build/OS identity and
readiness for Parakeet, pyannote, Whisper, Foundation Models, MLX, and Ollama;
it contributes no endpoint, model secret, Keychain value, or meeting content.
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
retained successful Companion artifacts and terminal attempts completed before
Stop to the same captured snapshot; dismissed/deduplicated/no-card work creates
no orphaned success (D48/D66).

Slice 2I moves start policy through `ApplicationKit.StartRecording`.
`AppServices` composes private preference, filesystem, Store, and capture
runtime adapters. The use case owns once-sampled preferences, title/sequence,
atomic pre-source shell/asset reservation, source-start invocation,
staging/published evidence reconciliation, guarded discard or
`needsAttention`, and failure-time release. The private runtime owns preferred
mic fallback, AEC warm-up, meeting-app/global process-tap selection, concrete
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
independent transcript/cast, newest cross-recipe summary/action-item, Companion,
privacy-receipt, and durable-processing streams; distinguishes missing from failed state; rejects stale
observation instances; and preserves healthy sections after a partial failure.
`AppServices+MeetingDetail` maps the five StorageKit streams at composition.
The view no longer performs sequential detail/Companion/summary reads or keys
its task to `libraryVersion`; player loading, two-column review, chapters,
newest summary, exports, and visible errors remain unchanged. Accepted Refine
regenerates from the accepted draft's speakers/segments, avoiding a race with
observation delivery (D59).

Slice 2T routes Meeting Detail persistence through the same route-owned model.
Explicit actions/effects cover title and speaker rename, name/voice suggestion
acceptance, action-item completion, Companion removal, meeting deletion, and
searchable-content changes. `AppServices+MeetingDetail` adapts Store, the
ApplicationKit lifecycle use case, and the Spotlight reconciliation request;
`MeetingDetailView` reaches none of them directly. The model preserves silent
best-effort operations, visible manual-rename/Companion errors, explicit
remember-voice consent, and delete navigation. Scoped observations, not
optimistic duplicate arrays, return post-write state. The adapter maps the
stale-refine persistence error before presentation. The view still imports
StorageKit only for local recording-path helpers used by playback/voiceprint
extraction; that seam is deferred to measured Band 4 decomposition (D60).

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

Band 5F keeps Companion provenance inside that scoped read model without
conflating the question with the answer. Each evidenced card renders one
localized **Question source** control and zero or more ordered **Answer
sources**. The former identifies the exact transcript turn that produced the
question or directed ping; the latter appears only for context answers and
follows exact local-RAG citations. Selecting either role focuses the cited
transcript row and seeks the shared player without autoplay. Stale or
physically unavailable evidence remains explicit instead of navigating to a
nearby guess. Stable card/role/index accessibility identifiers make both paths
deterministic under XCUITest (D91).

**Idle release (Jul 2026)**: engines do NOT stay resident forever. Generation pattern (new use cancels scheduled release): `scheduleWhisperRelease()` (120 s after refine/import; Whisper weighs 1.6 GB) and `scheduleRecordingEnginesRelease()` (600 s after stop/refine/import; doesn't trigger if refine is running or a speech-model load is in flight). `ApplicationKit.RefineMeeting` schedules both policies on every success, failure, or cancellation after model ownership begins; `ApplicationKit.StartRecording` schedules the recording-engine policy after every failed mic/channel/reservation/source-start attempt, while a successful audio-first start either owns the resident live engine or triggers shared preparation in the background; `ApplicationKit.StopRecording` schedules it after every accepted Stop request outcome and the recovery worker refreshes that idle policy after publishing. `MLXModelCache` (IntelligenceKit) does the same with Qwen3.5 container (2.4 GB resident measured) at 120 s. Consumers NEVER trust a shared reference after a long await: durable first-pass recovery calls `loadTranscriberIfNeeded()`, durable attribution and Import call `loadDiarizerIfNeeded()`, and Refine prepares Whisper then requests only its degradable diarizer. Note measurement (bench by phases): CoreML weights are file-backed and macOS reclaims them only when no longer used — post-stop footprint drops to ~160 MB without help; explicit release guarantees floor (~140 MB) and releases non-purgeable state.

## Design system in app (Jul 2026) — tokens + voices B + accent

Font: `docs/design/ds/` (authored in Claude Design, pine project). (1) `PVDesign` (app): Swift mirror of `tokens/*.css` — spacing 12/16/24, radios 8/10/12/14, tints 0.14/0.08, brand amber/violet/slate. When a value changes in the DS, it changes THERE and nowhere else. (2) **Voice B direction «el color ES la voz»**: `VoiceHue.index` (ApplicationKit, pure, FNV-1a — Swift hashValue is randomized by launch and DOESN'T work; 3 tests) assigns stable hue: named by hash of normalized name (same person = same color in all meetings), S-labels by appearance order; `VoicePalette` (app) maps to DS light/dark colors. Applied in: SpeakerPill (Me = solid amber + amber-contrast text; others hue 0.26), MeetingHealth bars (0.85), transcript pills, mic channel of waveform player (amber) and live recording labels. Indigo reserved for interaction (chips ✦, links, selection). (3) **App accent**: `assets/Assets.xcassets/AccentColor` (indigo #5856D6/#5E5CE6) compiled with `xcrun actool` in make-app.sh + `NSAccentColorName` — resolves system-accent debt for multicolor users (macOS gives priority to user who chose explicit color). **DS batch Jul 11 (2nd night — pull 9f11623 + implementation)**: (1) **Icon «La P que habla»**: assets/AppIcon.icns regenerated from DS SVG — the P is Fraunces (NOT installed locally): rendered in browser with Google Fonts via `scripts/icon-p.html` (canvas 1024, macOS grid: square 824 + radius 185) and `scripts/make-icns.sh` builds .icns; menu bar = `assets/icon/pv-menubar-32.png` pre-rendered as NSImage template (MenuBarIcon.swift) — the P adapts to appearance; recording follows record.circle.fill red (the «asta que pulsa» of DS remains flourish web). scripts/make-icon.swift (old icon) removed. (2) **Chips by evidence** (tokens --chip-* new): ChipLabel.swift (ai/voice/offer) + dynamic light/dark tokens in PVDesign (NSColor(name:dynamicProvider:)) — AI = violet tint + spark ✦ AMBER, voice = cyan + waveform, offer = neutral; applied to suggested title, S→name, voice matches, «Summarize as X?» and voice reminder offer. CONTROLS ✦ (Suggest names) follow indigo — deliberate distinction suggestion≠button. (3) **Settings 2a**: NavigationSplitView with 7 categories (SettingsCategories.swift) + search (.searchable filters by title and keyword bags EN/ES — ES live in catalog because EnglishSourceTests scans strings in code) + banner «100% local» → ledger; LedgerSection = real numbers (du of recordings root in Task.detached, count of meetings, enrolled+recorded voices) + honesty line of what actually goes out. gitHubSection extracted to GitHubSection.swift (file_length 700). (4) **Live lyrics 4a**: captionRow with colored voice pills (hash of label — S1/S2 stable, names = canonical hue), active line .title3, YOUR card in amber (me 0.12 + ring 0.35); FocusedTranscriptView already had fade/shrink/blur cylinder. **DS batch Jul 11 (3rd — pull 35264fb: Settings/Menubar/Dictation.jsx + menu bar implementation + mix)**: (1) **Menu bar 2b**: MenuBarContent rewritten as panel `.menuBarExtraStyle(.window)` (previously flat menu) — status header (mini waveform with amber/red peak when recording + «100% local · 0 B a la red hoy» green), quick actions grid (Record red / Dictate indigo / Ask), next meeting card (only if calendar access — never prompt here) with «grabar al empezar» → route .recording(event), recent with relative dates, footer (Open / Launch at login / Quit). Panel closes only on focus loss (opening window closes it). (2) **Voice mix in sidebar** (kit signature): `MeetingStore.voiceMixes(for:)` (StorageKit) — ONE added query that sums segment durations by (meeting, speaker), normalizes to assigned voice of each meeting and returns ordered slices by talk-time (isMe/displayName/fraction/order); 3 tests (fractions sum to 1 + order, empty input, meeting without attributed speech absent). `VoiceMixBar` under each meeting row colors each slice with `VoicePalette.color(for slice:)` — amber = you, stable hue by name, order for S-labels. Meetings without attributed segments simply don't show bar (honest).

**Dictation 4b (pull DS 4 — Jul 11)**: the dictation strip gains the three traits of exploration 4b. (1) **Visible target chip**: `DictationController.targetApp` = `NSWorkspace.frontmostApplication.localizedName` captured in `start()` BEFORE showing non-activating panel (frontmost still is destination app); strip shows `✎ <app>` — never dictate «a ciegas». (2) **Partial in gray**: `confirmedText` in `.primary` + `partialText` in `.tertiary` concatenated (previously joined into one string) — volatility shown in gray and affirmed on confirmation. (3) **Inserted state**: new `Phase.inserted(Int)` — after `TextInserter.insert`, strip shows «N palabras insertadas en <app> — nada se guardó» for 1.6 s before closing (previously closed abruptly). Privacy ledger does NOT adopt the mock DS tile «0 B a la red»: would be an unmeasurable metric (no network log); real LedgerSection says what CAN go out (gists, external model, update check) — more honest («Measured, not promised»).

**Real DS features (Jul 12 — «construyelas»): chapters + only-my-voice + summary tabs + menu-bar pending.** (1) **Summary tabs** (MeetingDetailView): SummarySections (ApplicationKit, pure, 3 tests) splits markdown by headers `## ` (language-agnostic) → intro + sections with bullet count; tab bar Summary/«Heading·N»/«To-dos·done/total» (active tab indigo filters). (2) **✦ Chapters** (chaptersSection): ChapterExtractor (ApplicationKit, pure, 6 tests) derives chapters LOCAL from transcript — boundary by pause ≥10s (with minimum spacing of 120s to avoid over-segmenting spaced seeds) or length ≥300s; label = first real sentence of chapter, with fallback search limited to that same chapter; ≤1 chapter → hidden rail. Rendered after MeetingHealth, click seeks+plays (disabled without audio). (3) **Only my voice** (MeetingPlayer + MeetingPlayerBar): `onlyMyVoice` + `nonVoiceRanges` — time-observer skips non-voice ranges like skipSilence; PlaybackRanges.complement (ApplicationKit, pure, 6 tests) computes complement of .microphone channel ranges within [0,duration] (merge with padding 0.25s); amber-tinted toggle in player bar. (4) **Pending menu bar**: recent shows «✦ N» = openActionItems grouped by meetingID. **2-column layout of detail (Jul 12)**: DONE. loadedBody: header + speakers + refineStatus full-width, then HStack(alignment:.top) — left VStack (summaryOrGenerate + transcriptSection with player, maxWidth infinity) + `detailRail` right (width 260: MeetingHealthView + chaptersSection + Companion persisted). Rail has own scroll and is HIDDEN entirely if no content (doesn't leave 260pt gap). maxWidth of content bumped to 1060. Matches MeetingDetail.jsx from DS.

**Pixel-perfect refinement (Jul 12 — user feedback: app fell short vs DS)**: (1) **Settings** (SettingsSidebar.swift): native one-line nav becomes custom — icon + title + single-line subtitle per category (SettingsCategory.subtitle), selection with indigo→violet gradient, own search field and green «Todo local» badge below, over AuroraSidebarBackground. LedgerSection: 3 rows → 4 tiles (audio/meetings/0 B to the network in green/voices); tile «a la red» = structural (nothing auto-uploads). (2) **Insights** (InsightsView): Swift Charts bar chart replaced by rhythm HEATMAP — LibraryStats.heatmap[week][day] (pure grid, 2 tests) rendered as 12 columns × 7 rows of day with relative indigo intensity to peak; meetings tile gains mini-waveform amber + real week-over-week delta. NO «hallazgos ✦» (no engine, no invention). (3) **Library sidebar** (LibraryView): «New recording» = gradient indigo→violet pill + mini-waveform (amber peak); Import/Ask/Insights = 3 vertical icon+label chips grid; search with keycap ⌘K; footer «100% local — nada sale de tu Mac» with green dot. `accessibilityIdentifier` preserved for XCUITest. **Refinement 2 (Jul 12 — DS screenshots): sidebar timeline + indigo selection + buttons under title.** (1) **MeetingDetail**: the 3 action buttons (refine/export/delete) MOVE from `.toolbar` (top-right) to a ROUND BUTTON ROW under title (actionRow/roundButton) — export tinted accent, delete red; matches DS (buttons live with meeting, not window chrome). (2) **Library sidebar timeline**: meetings grouped by recency (meetingGroups: Today/This week/Last week/Earlier, empty buckets dropped) instead of flat «Meetings». (3) **Indigo selection**: `.tint` does NOT override native sidebar highlight (which follows user's system accent — green on their Mac); solution: `.listRowBackground` with indigo→violet gradient when `route == .meeting(id)` + white text, which beats native highlight. Helpers moved to `extension LibraryView` (type_body_length). Menu bar and detail tabs/chapters/player-chips: DONE (see below).

**Recording 4a (Jul 12)**: RecordingView restructured to DS mockup. `recordingBar` (compact top bar: red dot + timer 24pt + `compactMeter` (mic dB) on left; Translate + Companion (button toggle) + HUD + **Stop red** on right — previously Stop was at bottom and header was 40pt). SINGLE column (previously two): `captionsList` (lyrics, `maxHeight:.infinity`) + ScrollView bounded (260) with companion cards + notes + live summary. `micLowBanner` separated (only when level is low). Language bridge (6a-3): translation under each caption goes in `.secondary` italic (NOT amber — amber only for your voice by voices-B; 6a spec said amber but voices-B is the newer canonical rule). Verification: build/lint/tests; computer-use not applicable (view only exists during live recording with audio engines).

**Recording/review polish (Jul 14)**: local mic mute in bar (zeros aligned, doesn't control call); floating HUD that grows with current utterance and returns to compact on speaker change/pause; unlimited Companion cards newest-first, persisted and reviewable; refine re-derives them; chapter titles with Foundation Models and literal fallback bounded to chapter. `MeetingDetailView` invalidates player/waveform and discards canceled loads when switching meetings so nothing from previous detail leaks into next.

**Aurora shell (Jul 2026)**: `Aurora.swift` — the `--aurora-*` doses of tokens, ONLY in dark appearance (icon world is dark; light stays native). `AuroraDetailBackground` (detail pane, wired in ContentView): 140° gradient #1C1A2E→#262626 + elliptical radial violet with center OUTSIDE screen (x=20%, y=-104pt, 1400×520) — only glow tail touches content; GeometryReader with `ignoresSafeArea` to bleed under toolbar and `.clipped()` to not spill over sidebar. `AuroraSidebarBackground`: brandSlate 0.6 over native vibrancy (deep glass, desktop breathes). Detail views are ScrollView with quaternary translucent fills — gradient breathes through cards without touching them. `--aurora-selection` NOT adopted: macOS draws sidebar selection natively and repainting fights platform.

**Unified accent (same batch)**: `PVDesign.accent = Color.indigo` (system indigo IS exactly the DS hex, adaptive). ALL usage of `Color.accentColor` in app target swept to `PVDesign.accent` — `Color.accentColor` follows user's system accent (not root `.tint`), and produced green/indigo mixes in same view when user has explicit accent. Root `.tint(.indigo)` also reads `PVDesign.accent`. What macOS paints natively (list selection, focus rings) follows user — correct platform behavior.

## Palette ⌘K «Pregúntale a tu semana» (Jul 2026 — design system 6a-1)

`CommandPaletteController` in AppServices (works with closed window) + `NSPanel` Spotlight-style (620 pt, radius 16, `.regularMaterial`, non-activating but key — closes on key loss and state DISCARDED, spec). ⌘K via CommandGroup in menu (works without window). Two lanes: FTS instant while typing (`store.search`, 6 hits with snippet·title·mm:ss, keystroke stale guard) and Enter → full RAG (`AskPipeline.retrieve` + `RAGAnswerer`, answers in question language). Citations as capsules `↗ título · mm:ss` → `pendingRoute` + `pendingSeek` (one-shot consumed by detail after player loads to jump to cited moment) + window reopen ONLY if none visible (openWindow always creates — gotcha). ⌘C copies response+citations in Markdown (`AskMarkdown`, IntegrationsKit). Verified E2E with seed: FTS instant, response IS correct with 6 citations, navigation to detail.

## Insights (Jul 2026) — library dashboard

`Route.insights` (button in sidebar): tiles (meetings, hours, average duration, weekly streak, most active day), a 12-week × 7-day rhythm heatmap with zero weeks retained, frequent people, pending gauge, and local findings. ApplicationKit owns `InsightsScope`, `LibraryStats`, `InsightsFindings`, and the complete storage-independent `InsightsReadModel`; calculations inject calendar/now. A per-window `InsightsModel` combines four app-mapped Store observations: live meeting chronology, participant/commitment facts, voice balance, and finding evidence for at most the 60 newest live meetings in the selected scope. Meetings without `endedAt` count but do not drag the average; no-decision findings require summarized evidence, and recurring topics exclude participant names. Everything remains 100% local. Writes refresh only the query families whose explicit base-table regions changed; scope changes restart the bounded finding observation without a process-wide reload.

## Resident menu bar (Jul 2026)

`MenuBarExtra(isInserted:)` bound to `@AppStorage("menuBarEnabled")` (toggle in Settings → Menu bar, on by default): template icon `waveform.and.mic` that changes to `record.circle.fill` while recording — the "¿estoy grabando?" at a glance. Menu: Start/Stop (Start opens window via `openWindow(id: "main")` + `pendingRoute = .recording(nil)`; Stop calls shared controller), Dictate (only with dictation enabled), Open Portavoz, Launch at login (`SMAppService.mainApp` — requires /Applications, which is the installation story), Quit. **Architectural precondition**: `RecordingController` moved from `@State` of RecordingView to `AppServices.recording` (shared) — view, HUD and menu bar observe THE SAME session and navigation never can orphan a recording (same fix as RefineService).

## Global dictation (Jul 2026)

**Hold-to-talk (Jul 2026)**: `GlobalHotkey` listens to kEventHotKeyPressed AND kEventHotKeyReleased (`GetEventKind` in same handler). Gesture without setting: a TAP (release < 0.5 s) preserves toggle; HOLD combination while speaking and release delivers at release — walkie-talkie. Verified E2E: hold of 2.5 s opens panel on press and closes only on release.

**Configurable hotkey (Jul 2026)**: `HotkeySetting` (keyCode + Carbon mask + label, AppStorage; default ⌥⌘D) + `HotkeyRecorder` in Settings (NSEvent local monitor captures next combo; Esc cancels; combos WITHOUT ⌘/⌥ rejected with beep — single letter as global hotkey would hijack typing). `syncHotkey` now always unregister-first so new combo applies live. Verified E2E: record ⌃⌥⌘M and trigger opens panel.
 — ⌥⌘D in any app

Surface validated by MacParakeet: global hotkey → speak → hotkey again → text written where cursor is. `GlobalHotkey` (Carbon `RegisterEventHotKey` — the only API consuming keystroke WITHOUT Accessibility permission; registered from App init, not view, to survive without window), `DictationController` in AppServices (mic → Parakeet streaming with custom vocabulary → `CaptionCoalescer` reused with echo/noise hygiene; nothing persisted: no meeting, no DB, no file), `DictationPanel` (same non-activating pattern as HUD, bottom-center, live text, X cancels), `TextInserter` (paste-and-restore: clipboard → synthetic ⌘V via CGEvent → restore; the ⌘V DOES require Accessibility — checked BEFORE recording with system prompt to avoid dictating into void). Toggle in Settings (off by default); `DictationAssembler` (TranscriptionKit, pure, tested) joins confirmed+partial. Verified E2E: hotkey triggers with app in background and panel transcribes real live audio; final insertion verified in field.

## Views and flows

**LibraryView + LibraryModel**: `New recording` (⌘N), FTS search with snippets, **"To-dos" section** (open action items from ALL meetings; click navigates to the meeting), recency-grouped meetings with `Rename`/`Delete`, Recently Deleted restore/permanent purge, import progress/errors, and calendar briefs. The per-window model owns data, debounce, mutations, and effects through its narrow client; the SwiftUI views own rendering, native presentation, AppStorage disclosure state, file picking/drop acceptance, and route binding. Library and Meeting Detail deletion plus Recently Deleted restore/permanent purge still enter through ApplicationKit use cases; launch cleanup uses the same purge boundary for tombstones strictly older than 30 days. Existing controls, navigation, and degradable filesystem behavior remain while scoped observations update only their owning sections. `library-search-field` now provides a stable automation boundary for the real FTS/model wiring; UITests use `firstMatch` for to-dos because a meeting title also appears as the row caption.

**RecordingView + RecordingController** (full live pipeline):
1. `start`: `RecordingController` resets live visual state and sends callbacks
   to `ApplicationKit.StartRecording`. The use case samples settings, asks the
   private runtime to warm the mic while engines load, atomically calls
   `MeetingStore.beginRecording` for the `recording` shell and pending
   `<channel>.partial.caf` assets, then invokes source start. The runtime owns
   the concrete mic (+system tap on 14.4+), `RecordingSession`, and direct
   Parakeet stream per channel; captions return through the callback to
   **CaptionCoalescer**. A no-file startup failure rolls back only the empty
   shell; staging or published evidence preserves it as `needsAttention`
   (D37/D49).
2. Live: captions in LazyVStack (window 150 rows) with **follow-live pausable** (manual scroll pauses; resumes after 10 s or button "Seguir en vivo"); **live voice pills** (S1/S2 — streaming diarization with dedicated instance + `LiveSpeakerLabeler`, spec 03: closed rows split/label by voice as each 10 s window arrives; "Ellos" while no coverage; "Me"→"Yo" via voiceprint); translation picker →es/→en (Translation framework, macOS 15+; only translates closed rows); **rolling monotonic summary** every ~40 s (FM note only of new closed rows → stack → collapse > 6000 chars → render; never shrinks — `LiveSummaryPolicy`) using the independent summary-output policy, never the transcript hint.
3. `stop`: flush and close writers → validate/hash/measure each CAF → atomically
   rename staging files without overwrite → one `installCapturedSnapshot`
   transaction for `captured` + finalized/missing assets + provisional live
   cast/transcript/context/Companion + the exact initial diarization job →
   enter `done` and open detail → process-scoped worker diarizes and atomically
   replaces the provisional cast → optional summary in the independently
   configured language → persist `ready`. The title (configurable
   `TitleTemplate`: `{date} {time} {seq} {weekday}`, ISO-first) is assigned at
   start, so sequence follows start order. `Meeting.language` is set only when
   all segments are homogeneous; mixed/unknown remains nil. Audio with no
   captions, a failed job admission, or later required-work failure remains
   discoverable as `needsAttention` rather than being deleted. A publication
   collision keeps its staging file and also becomes `needsAttention` for
   launch recovery.

Normal Stop now uses the durable process path (D39–D43). The active Start
session owns one utility-priority voiceprint future after reservation and feeds
that same value to both live diarization and the exact initial operation. After files publish,
`installCapturedSnapshot(..., enqueue:)` atomically installs captured
assets/live transcript/notes/cards and that first job. Stop enters `done`
immediately after the commit and kicks `PostCaptureProcessingSupervisor`, so
the detail opens while attribution and optional summary continue. A failed job
insert rolls back the snapshot; the controller then attempts one explicit
`needsAttention` snapshot fallback and never deletes audio.

Process launch creates `RecordingRecoveryCoordinator` outside the view
hierarchy. It seeds only the temp-store UI fixture and enters
`ApplicationKit.RecoverInterruptedMeetings`, which recovers expired leases,
filters non-ready meetings, rechecks live-capture activity per candidate, and
owns recovered-asset/lifecycle/failure policy. The private app filesystem
adapter scans configured and fallback roots and revalidates staging-only or
final-only CAF evidence off the main actor. Missing files are explicit;
staging plus final or duplicate-root evidence is preserved as
`capture.recovery.ambiguous` without overwrite or deletion. The coordinator
maps typed issues to OSLog and one broad invalidation. Only after the awaited
pass does the process supervisor resume owner-leased diarization/summary work
with durable retries and one scheduled wake instead of polling. Optional
initial summary-provider discovery runs only after recovery and durable
worker resume, so a local Ollama probe cannot delay finalized-audio or
transcript recovery. The user's post-meeting Shortcut runs after terminal
derived work, including
transcript-only completion when summary is unavailable; temp-store launches
suppress real host Shortcuts (D50).

Each actual durable summary model attempt begins only after the worker has
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

**MeetingDetailView**: header with editable title (pencil), editable speaker pills (capture values on tap — alert-dismiss niled state and rename was lost), chips "Sugerir nombres ✦" with evidence, versioned summary with regenerate (explicit es/en choices persist in the new immutable snapshot), lazy transcript, checkable action items. Summary setup failures are typed: unavailable Apple, missing Ollama selection, missing MLX download, and local-engine failure open an actionable alert whose recovery button opens the native Settings scene at the exact Intelligence category instead of ending in a generic error (D72).
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
- **Refine (D7/D35/D47/D73 in-app)**: `ApplicationKit.RefineMeeting` prepares only required Whisper and re-transcribes retained non-silent channels (+vocabulary), then applies microphone noise/bleed filtering and requests only best-effort pyannote diarization; live Parakeet is never a prerequisite. `TranscriptLanguagePolicy.automatic` uses a hint only when previous transcript evidence is homogeneous; if mixed ES/EN, it leaves auto-detection active to preserve speaker/segment language. The per-meeting "Re-transcribe in Spanish/English" choices are explicit fixed recovery operations, and neither app UI nor summary language is ever a transcript fallback. The use case returns a **DRAFT with comparison sheet** (segments/speakers/speech coverage/sample + red warning if it covers < 50% of current speech) and its source revision — **nothing is applied without "Apply"**. The running control becomes an explicit cancel action; cancellation leaves the current transcript untouched and does not permit a replacement heavy run until the old engine exits. `RefineService` is keyed by MeetingID outside the view hierarchy, so switching meetings does not lose a running pass or draft, and run IDs prevent stale completion from overwriting newer state. The app freezes the selected Whisper descriptor for the run and derives content evidence from finalized v6 checksums after a size check or by locally hashing legacy audio. One content-free composite transcript attempt covers every non-silent channel. On acceptance, `ApplyRefinedMeeting` atomically installs that successful run, links every new segment, installs homogeneous language (including `nil` for mixed/unknown), cast, transcript, and next revision; a stale/discarded draft creates no success record. Begun transcription failure/cancellation is standalone best-effort provenance. Companion refresh runs only afterward with the accepted revision. It derives per-turn language, creates exact card/run artifacts, persists current terminal attempts best effort, preserves prior cards on incomplete work, and replaces a complete snapshot plus links atomically; persistence failure warns without failing the transcript. Meeting Detail submits the accepted draft's exact speakers/segments to the existing `RegenerateSummary` use case under the independent current recipe/output policy, while scoped observations publish the committed transcript and preserve older immutable summaries. **Chip "Summary looks thin"** (`ThinSummaryPolicy`, pure): meeting ≥ 20 min with summary < 900 chars, or ≥ 40 min with 0 action items → offers regeneration with MLX in one click (only if MLX is downloaded and was not the generator; FM contract: suggestion, never automatic).
- Export: Markdown / PDF (pure CoreText, compiles for iOS) / **Secret Gist** with explicit off-device confirmation and gateway-enforced meeting/document metadata.

**SettingsView (⌘,)**: Language (use system language or force English/Spanish, saved in `@AppStorage("app-language")`, applies `\.locale` live to `ContentView` and `SettingsView`) · Intelligence language policies (`transcriptionLanguage`: "Auto-detect" / "English" / "Español" for recognition only; `summaryLanguage`: "Meeting language" / "English" / "Español" for generated output only) · capability-aware Summary engine selection whose localized recommendation action is prominent and whose unavailable Apple state names Ollama/MLX recovery · proactive Whisper Turbo/Compact rows with select/download/retry/delete, background progress, and stable `settings-whisper-*` accessibility identifiers (D71) · Audio (toggle AEC, preferred mic with visible fallback, capture mode auto/app/system and disclosure of scope) · Recordings (configurable folder with migration and progress) · Titles (template with help popover of tokens, insertable chips, `Reset` button, and live preview) · Vocabulary (list editor: Enter adds, − removes) · My voice (enroll 12 s / delete — destroys file+key) · Companion activation/status (enabled here or from recording only when the macOS 26 Apple classifier is available; Sequoia explains the requirement while retaining Mirror) · External model BYOK (endpoint/model in defaults, key in Keychain, answer-provider opt-in disabled until everything and the Companion classifier are available; deleting key turns it off — spec 04) · GitHub (token in Keychain) · explicit local redacted support export in Your data (`settings-export-diagnostics`, D76). A one-shot app route lets any feature open an existing or new Settings window at an exact category (D72).

## Verified in real world (Jul 2026)

4 real meetings recorded; TCC permissions stable between updates (real signature identity); 30 min recording survived device change halfway (post-fix); AEC eliminated speaker echo; refine incident recovered without loss.

## Additional as-built note

**Audio first-class (M11/D27) complete**: player synchronized with **Spotify-style lyrics transcript** (`FocusedTranscriptView`: spoken line stays CENTERED in fixed-height viewport, others fade/shrink/blur towards edges — cylinder effect with `.visualEffect`; no scroll bar; search in timeline moves transcript INSIDE its box, never page), click-to-jump, **waveform-scrubber** (colored by channel: accent=you, gray=them; dimmed after playhead; clip region shaded) and **clips** (mark in/out at playhead → `AudioClipExporter` exports mixed range to m4a/AAC via `AVAssetExportSession`, measured well below 2 s) — all in `AudioPlaybackKit`. Without audio, transcript is normal list. The **same carousel runs in live recording** (`FocusedTranscriptView` parametrized with `anchor`: during recording new line focuses at lower third `y≈0.82` — boundary — and old ones rise and fade; `followSignal` re-centers when live line GROWS, not just appears; replaced pausable follow-live). Also: **skip-silence** (toggle; skips gaps ≥1.2 s detected from waveform), **transcode AAC** ("Comprimir audio (AAC)" → `AudioTranscoder`, deletes original after verified write, rebuilds player from m4a) and **import** (library: "Importar audio…" button + drag-drop → the `AppServices` wrapper around `ApplicationKit.ImportMeeting`; it copies as system channel off the MainActor, applies the transcript recognition policy to Whisper, keeps mixed-language evidence automatic, degrades diarization and summary honestly, commits the required aggregate atomically, then preserves the existing success invalidation and navigation timing). **M11 complete.** `make test-ui` covers player, highlight and clip export button; preflight closes Portavoz before XCUITest to avoid automation mode failures from stale instances.

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
defines 32 XCUITest cases in `Tests/PortavozUITests`: Library (record button +
chips + time grouping + interrupted staging recovery + durable post-capture
resume + typed recording-start recovery), Insights (heatmap + interlocutors), Onboarding (first listen +
advance), MeetingDetail (summary tabs reveal ▸, typed overview/decision/action-item and role-separated Companion source transcript/audio navigation, explicit correction/unsupported/clear review, explicit confirmed-person
memory, newest-recipe reload, right
rail health+chapters, post-meeting mirror, processing failure/retry, player skip+only-my-voice, clip export, refine cancel, Sequoia summary setup routing and Companion requirements), and Settings (all categories,
independent transcript/summary language controls, proactive clean-install
Whisper preparation, explicit iCloud sync opt-in/existing-library separation,
custom structures, capture
controls, redacted support export, mirror, and live language switch via ⌘,). Every launch receives a
unique disposable `PORTAVOZ_AUDIO_ROOT` in addition to `-use-temp-store`, so
neither SQLite, audio, nor the encrypted participant-voice gallery can touch
the user's library or Keychain. `-seed-recovery`,
`-seed-processing`, `-seed-refine-running`, `-seed-just-recorded`,
`-seed-scale` with optional `-scale-auto-summary-update`,
`-simulate-recording-start-failure`, and
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
resort. Feature-band evidence retains app-window-only screenshots at asserted
Library, Insights, Meeting Detail, Companion evidence, confirmed-person memory, and post-meeting mirror checkpoints so unrelated desktop content
is never captured. `make test-ui-en` and `make test-ui-es` use Xcode's explicit
test language and region flags; the complete 32-case suite is green in the
default and forced-Spanish configurations. **Real bug caught by XCUITest (not computer-use):**
`PlaybackRanges.complement` built an inverted `ClosedRange` (`200...6`) and
crashed when a voice segment started after audio duration; the fix clamps
before forming the range and has unit coverage.
