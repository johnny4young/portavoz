# Roadmap

Each milestone is independently shippable and has a measurable acceptance criterion.

## Current state and next step (Jul 2026)

Single source of truth for progress — it previously lived in a session HANDOFF; state is now read here, decisions in [DECISIONS.md](DECISIONS.md), as-built behavior in [specs/](specs/README.md), and gaps + field verification in [GAPS.md](GAPS.md).

**Next concrete step:** implement architecture Band 4 slice 4D: measure
brute-force semantic cosine latency, CPU, and memory at the same
1k/10k/50k/100k scale before considering sqlite-vec or a segment-layout
migration. Band 4C now puts lexical Ask safely inside budget, while Band 4B
puts 5k-detail first content inside budget; D79–D81 therefore reject
speculative vector storage, view decomposition, `DatabasePool`, or chapter
caching. D78 closes Band 3 by retaining the accurately documented
non-sandboxed distribution until a reversible feature-parity migration passes
its app/CLI/MCP storage, custom-folder, Sparkle, capture, and automation gates.

Slices 3A–3K now cover attempt-level generation provenance, every current
meeting-content HTTP path, an honest per-meeting receipt, and local redacted
support/recovery evidence plus stable recording-lifecycle failures. The Jul 16
Sequoia stabilization interrupt fixed Stop timestamp identity, audio-first
capture/recovery, proactive Whisper preparation, exact capability-aware
Summary/Companion setup, role-specific speech-model readiness, and independent
app/DMG notarization. Band 3 is complete.
`LibraryModel`, scoped Library observation, `ExportMeetingBundle`, `ImportMeetingBundle`,
`RecoverInterruptedMeetings`, `StartRecording`, `StopRecording`,
`RefineMeeting`, `ImportMeeting`, and T16 are complete; Bands 0–2 are
complete. Every slice
preserves all v0.6.0 features and updates
`ARCHITECTURE.md` plus every affected source-of-truth document in the same
commit (D33/D34/D36/D37/D38/D39/D40/D41/D42/D43/D44/D45/D46/D47/D48/D49/D50/D51/D52/D53/D54/D55/D56/D57/D58/D59/D60/D61/D62/D63/D64/D65/D66/D67/D68/D69/D70/D71/D72/D73/D74/D75/D76/D77/D78/D79/D80/D81).

- **Architecture Band 4 slice 4C complete — Ask ranks evidence, not one huge
  OR union (Jul 16, 2026)**: StorageKit's exact FTS top-k uses the equivalent
  hidden `rank` path, while IntegrationsKit owns local-RAG lexical selection.
  Normal questions retrieve bounded candidates per unique content term and
  fuse them with reciprocal rank, so passages supported by several terms
  climb; unusually long questions keep the complete released broad-OR
  fallback. Answers receive complete segment text while search UI retains its
  highlighted snippet. At 100k segments, exact p95 falls from 38.38 ms to
  30.99 ms and lexical Ask from 111.19 ms to 66.89 ms (39.8% faster), safely
  inside both budgets. The full Release matrix, explicit BM25 equivalence,
  multi-term relevance, long-question fallback, hostile-input coverage, D81,
  678 package tests, and the unchanged 25-case EN/ES UI contract protect the
  result. No schema, vector format, model, database pool, or UI layout changed;
  semantic cosine cost is the next measurement.

- **Architecture Band 4 slice 4B complete — long details are linear in the
  common case (Jul 16, 2026)**: interruption detection now uses a prefix
  maximum-end boundary to skip only transcript history that provably cannot
  overlap. It still detects an older long segment behind a newer ended one.
  Release p95 falls from 24.25/347.58/5,385.76 ms to
  2.55/9.94/41.39 ms at 1,250/5,000/20,000 segments: 9.5×/35×/130× faster.
  The same native 5k fixture now reaches first content in 91.87 ms instead of
  522.30 ms and records zero hangs instead of one 515.86 ms hang. Before/after
  reports, two health-conservation characterizations, 675 package tests, D80, and
  the unchanged 25-case EN/ES XCUITest baseline protect the result. Because
  the 300 ms target now passes, speculative Meeting Detail decomposition is
  not the next slice; broad OR retrieval is.

- **Architecture Band 4 slice 4A complete — scale decisions now start with
  evidence (Jul 16, 2026)**: a Release CLI matrix measures the production
  schema at 1k/10k/50k/100k library segments and 30-minute/2-hour/8-hour
  meetings. Exact FTS remains inside its 50 ms budget at 100k; broad OR
  retrieval misses at 50k and 100k. Core detail reads and chapter extraction
  stay fast, while `MeetingHealth` reaches p95 347.58 ms at 5k and 5.39 s at
  20k. A disposable 5k-detail app fixture records 522.30 ms to first content,
  one 515.86 ms initial hang, a working later summary observation, and an
  inspected `band-4a-scale-detail-5000-segments` screenshot. Xcode 26.6's
  SwiftUI lane returns its explicit no-data warning, so invalidation causes
  remain open instead of being misreported. Two repeatable runners, tracked
  content-free JSON, the 32nd architecture rule, 673 package tests, and the
  25th EN/ES XCUITest protect D79. Slice 4B optimizes health first.

- **Architecture Band 3 slice 3K complete — App Sandbox has measured gates,
  not hopeful entitlements (Jul 16, 2026)**: a Developer-ID-signed sandboxed
  probe and identical non-sandboxed control produce a tracked capability
  matrix. Container enforcement and child inheritance are proven; microphone,
  Keychain, hotkey, loopback networking, and process-catalog operations pass.
  The full private process-tap graph starts/stops in both variants, proving
  structural setup compatibility while real product capture remains a gate.
  Current shared app/CLI/MCP storage, plain custom-folder paths, Sparkle setup,
  and interactive automation still lack feature parity, so production remains
  notarized/Hardened Runtime and non-sandboxed. The 31st architecture rule and
  672nd package test require the decision and experimental harness to remain
  explicit (D78). Band 3 is complete.

- **Architecture Band 3 slice 3J complete — recording failures have stable
  recovery contracts (Jul 16, 2026)**: Core now defines five product-level
  failure categories, while ApplicationKit Start/Stop return stable coded
  failures instead of dependency-localized text. Every existing durable
  distinction remains intact, including preserved partial audio, fallback
  commits, critical persistence loss, and destructive cleanup failure. The app
  owns EN/ES copy and routes each case to retry, the Library, or local support
  diagnostics; the failed screen exposes a selectable reference. Typed outcome,
  architecture, localization, and EN/ES UI coverage plus the 30th architecture
  rule protect the boundary. The complete gate is 671 package tests (13 gated),
  zero strict-lint violations across 250 Swift source files, and all 24
  XCUITest cases in English and Spanish with inspected
  `band-3j-typed-recording-failure` screenshots (D77).

- **Architecture Band 3 slice 3I complete — private support evidence that can
  recover work (Jul 16, 2026)**: Settings can explicitly save a local,
  versioned JSON support file built from one read-consistent Store snapshot.
  It pseudonymizes meeting identities, rehashes stored fingerprints, and keeps
  only environment/readiness, lifecycle/revision, stable error codes, durable
  job state, content-free generation provenance, and existing privacy events.
  Meeting text, generated output, prompts, raw errors, secrets, config/metrics,
  full URLs, and paths are excluded by construction. Meeting Detail now
  observes durable jobs independently, explains active or exhausted work, and
  exposes one retry that preserves identity/idempotency/input evidence for the
  normal worker fence. Content-free signposts carry only kind, attempt, and
  outcome. Adversarial redaction, persistence, observation, model,
  localization, and EN/ES UI coverage plus the 29th architecture rule protect
  the boundary. The complete gate is 667 package tests (13 gated), zero
  strict-lint violations across 249 Swift source files, and all 23 XCUITest
  cases in English and Spanish with inspected
  `band-3i-redacted-support-export` and
  `band-3i-actionable-processing` screenshots (D76).

- **Architecture Band 3 slice 3H complete — every meeting has an honest
  privacy receipt (Jul 16, 2026)**: schema v7 persists immutable content-free
  egress attempts plus the date receipt tracking began. The shared gateway
  validates policy, writes that evidence, and only then transports meeting
  material; a receipt failure prevents transfer, an HTTP failure remains
  visible, and redirects are rejected. Meeting Detail independently observes
  generation provenance and egress evidence, then shows one of three truthful
  states: all tracked work stayed local, no remote transfer has been recorded
  since tracking began for a legacy meeting, or remote content may have left
  with its purpose, destination host, and time. Saved app and CLI operations
  use the same store-backed recorder. Migration, validation, transaction,
  ordering, failure, redirect, observation, localization, and UI coverage plus
  the 28th architecture rule protect the boundary. The complete gate is 663
  package tests (13 gated), zero strict-lint violations across 245 Swift source
  files, and all 21 XCUITest cases in English and Spanish with inspected
  `band-3h-privacy-receipt` screenshots (D75).

- **Sequoia stabilization unit 6 complete — Homebrew carries its own trust
  evidence (Jul 16, 2026)**: the published v0.6.0 cask was reproduced in an
  isolated app directory. Its shared DMG was signed, notarized, and stapled,
  but the extracted `Portavoz.app` had no stapled ticket; a direct DMG launch
  retained outer-image trust while a package manager had to obtain the inner
  ticket online. Distribution now submits and staples the signed app before
  creating the DMG, then separately notarizes and staples the DMG. The release
  gate mounts the final image, copies the app out exactly as Homebrew does, and
  requires independent codesign, stapler, and Gatekeeper acceptance. CI also
  runs the complete package suite on a `macos-15` Sequoia runner. One packaging
  architecture case brings the package gate to 654 tests (13 gated), with 244
  linted Swift sources and 21 UI cases (D74). A clean-machine Homebrew check of
  the next public artifact remains release evidence, not implementation work.

- **Sequoia stabilization unit 5 complete — model readiness follows the job
  (Jul 16, 2026)**: Refine prepares only its required Whisper runtime and
  acquires only pyannote when speaker attribution begins; the live Parakeet
  engine is no longer a hidden prerequisite. Per-model tasks deduplicate
  concurrent users. External-audio Import requests diarization alone, durable
  first-pass recovery and Dictation request transcription alone, and a failed
  optional diarizer can no longer block a saved recording's transcript.
  Existing Refine degradation still returns honest unattributed segments.
  One architecture characterization brings the gate to 653 package tests (13
  gated), 244 linted Swift source files, and 21 UI cases (D73).

- **Sequoia stabilization unit 4 complete — intelligence setup is explicit
  (Jul 16, 2026)**: one app-owned Foundation Models capability now drives
  clean-install summary selection, exact provider composition, Settings
  guidance, recording controls, and Companion refresh. Existing preferences
  are preserved; selected Apple/Ollama/MLX engines no longer fall through to a
  different provider. Typed setup states open the Intelligence pane directly.
  Companion is shown only when its Apple classifier can run, and Settings
  explains why BYOK cannot replace that classifier on Sequoia. Five policy
  cases plus a full Sequoia summary-to-Settings-to-Companion XCUITest bring the
  gate to 652 package tests (13 gated), 244 linted Swift source files, and 21 UI
  cases (D72).

- **Sequoia stabilization unit 3 complete — Whisper can be ready before
  Refine (Jul 16, 2026)**: Settings now exposes proactive Download, retry,
  progress, and safe deletion for Turbo and Compact. One app-scoped serialized
  task survives the Settings window; Refine and external-audio Import join the
  matching transfer rather than duplicating it. TranscriptionKit alone creates
  an opaque token after the pinned model and tokenizer pass ModelStore, and the
  app retains that evidence without retaining the heavyweight runtime. The
  clean-install Settings assertion, a 25th architecture rule, and existing
  ModelStore integrity cases bring the gate to 647 package tests (13 gated),
  240 linted Swift source files, and 20 UI cases (D71).

- **Sequoia stabilization unit 2 complete — audio starts before models (Jul
  16, 2026)**: Start now warms the microphone, selects channels, reserves the
  durable shell/assets, and begins capture without awaiting Parakeet download
  or Core ML compilation. If the verified live engine is absent, or either
  caption lane fails, the session records explicit recovery evidence while
  audio continues. Stop atomically admits an exact multilingual first-pass
  transcription job; the worker joins one deduplicated verified model load,
  transcribes each healthy finalized channel, applies mic-noise/bleed hygiene,
  and publishes cast/transcript/revision plus exact diarization in one owned
  transaction. Truly silent audio retains explicit recovery guidance. Three
  fingerprint cases, hardened Start/Stop/architecture coverage, and atomic
  artifact/dependent persistence bring the gate to 646 package tests (13
  gated), 238 linted Swift source files, and 20 UI cases (D70).

- **Sequoia stabilization unit 1 complete — Stop uses durable timestamp
  identity (Jul 16, 2026)**: a real recording exposed that GRDB stores dates at
  millisecond precision while the live shell retained `Date()` submilliseconds.
  The captured Unit of Work now compares the exact canonical database values
  for shell and asset reservation timestamps. The strict title, ownership,
  channel, path, lifecycle, and reservation-ID fences remain unchanged. One
  production-shaped regression brings the current gate to 640 package tests
  (13 gated), 235 linted Swift source files, and 20 UI cases.

- **Architecture Band 3 slice 3G-b complete — explicit publishing crosses the
  shared egress boundary (Jul 16, 2026)**: Gist, GitHub Issue, and Linear Issue
  exporters no longer own URLSession. They require an injected gateway and a
  real source meeting, and declare separate operations, document/action-item
  classifications, destination scope, provider host, and operation-specific
  explicit consent. The adapter accepts only the exact GitHub Gist and Linear
  GraphQL endpoints or a canonical GitHub repository-issues endpoint; forged
  classification, consent, model, method, host, query, fragment, port, and path
  traversal are rejected before transport. The existing app secret-Gist
  confirmation and CLI opt-in, warning, request body, response parsing, and
  failure behavior are preserved. Six success/failure publisher cases, four direct
  publishing-policy cases, and a 24th architecture rule bring the current gate
  to 639 package tests (13 gated), 235 linted Swift source files, and 20 UI
  cases (D69). Content-free Ollama discovery/model downloads and the explicit
  local Shortcut process remain deliberately outside this meeting-content HTTP
  boundary.

- **Architecture Band 3 slice 3G-a complete — summaries cross the shared
  egress boundary (Jul 16, 2026)**: the OpenAI-compatible chat codec is now
  pure and transport-free. Both remote BYOK and local Ollama summary clients
  require an injected gateway and declare `summary-generation`, complete
  summary material, source meeting, provider/model, consent source, and
  conservative destination scope before URLSession. The app composes Settings
  consent for regeneration, import, and durable post-capture Ollama summaries;
  the CLI composes explicit-provider consent after its existing `--byok`
  warning. Ollama discovery remains direct because it carries no meeting
  content. Three summary policy/request cases plus a 23rd architecture rule
  bring the current gate to 628 package tests (13 gated), 235 linted Swift
  source files, and 20 UI cases (D68). At that slice boundary, explicit
  Gist/GitHub/Linear publishing remained deferred to 3G-b and is now complete.

- **Architecture Band 3 slice 3F complete — Companion BYOK crosses one
  enforceable, content-free egress boundary (Jul 16, 2026)**: PortavozCore now
  names outbound operation, destination, conservative scope, classification,
  meeting identity, consent source, and provider/model disclosure without
  copying payload content. IntegrationsKit validates those declarations before
  URLSession observes a request, including HTTP(S)-only exact destination/
  provider matching,
  question-only non-empty POST semantics, and a meeting identity for persisted
  Settings consent. The injected Companion client is the only production BYOK
  path for live and post-Refine cards; it still sends only the classified
  knowledge question, never transcript context, falls back on-device after an
  ordinary provider/policy failure, and does not fall through on cancellation.
  Provenance records `local-device` only for provable loopback and otherwise
  records `remote`. Six policy/request cases, strengthened provenance cases,
  and an architecture bypass guard bring the current gate to 624 package tests
  (13 gated), 235 linted Swift source files, and 20 UI cases (D67). At that
  slice boundary, summary and explicit integration egress paths remained
  deferred to 3G and are now complete.

- **Architecture Band 3 slice 3E complete — Companion cards carry exact,
  privacy-safe attempt provenance (Jul 16, 2026)**: each durable live or
  post-Refine card links one successful `.companion` run. Its length-framed
  fingerprint hashes the meeting/revision/workflow, candidate, ordered context,
  owner/language/time, and configured external provider without storing any of
  that private material. Configuration distinguishes the Foundation Models
  classifier, actual answer provider/model, context count, and whether a BYOK
  transfer occurred and succeeded; metrics contain only question/answer byte
  counts, kind, and directed status. A cancelled remote request never falls
  through to a local model, while an ordinary provider failure retains the
  released on-device fallback and records both stages honestly. Live successes
  and completed terminal attempts join the atomic Stop snapshot; post-Refine
  success replaces cards with run links in one current-revision transaction,
  while an incomplete refresh preserves prior cards and stores current terminal
  attempts best effort. Heuristic rejects, unavailable models, classifier
  negatives, unusable answers, and deduplicated cards create no orphaned run.
  Eight direct provenance/storage cases plus strengthened Stop/Refine coverage
  prove content redaction, remote success/fallback/cancellation, stale-revision
  rejection, link retention, and late-write rollback. The current gate is 617
  package tests (13 gated), 233 linted Swift source files, and 20 UI cases (D66).

- **Architecture Band 3 slice 3D complete — accepted Refine transcripts carry
  atomic, content-free provenance (Jul 16, 2026)**: one composite transcript
  attempt covers every non-silent system/microphone Whisper call that produces
  a reviewable draft. Its exact fingerprint binds source transcript revision,
  selected Whisper model/revision, automatic versus fixed language hint,
  vocabulary material, and content digests for the actual channels; persisted
  configuration and metrics contain only safe identity/count/timing data. A
  successful run stays ephemeral with the draft until Apply atomically inserts
  it, links every accepted segment, replaces cast/transcript/language, and
  increments the revision under the existing stale-draft fence. Discarded,
  empty, stale, or invalid drafts create no orphaned success; failures and
  cancellations after the attempt begins persist standalone best effort.
  Legacy recordings derive content digests locally while finalized v6 assets
  reuse checksum evidence after a size check. Seventeen Refine and seven
  operation-fingerprint cases cover mixed language, privacy-safe metadata,
  no-attempt paths, failure/cancellation, invalid provenance, segment-link
  retention, stale rejection, and injected transactional rollback. The current
  gate is 609 package tests (13 gated), 231 linted Swift source files, and 20 UI
  cases (D65).

- **Architecture Band 3 slice 3C complete — imported summaries preserve both
  aggregate durability and attempt truth (Jul 16, 2026)**: external-audio import
  resolves the configured summary provider with provider/model/revision
  identity and creates one content-free run immediately before each real model
  call. Success atomically links that run to the immutable summary/actions;
  provider failure, cancellation, or summary-publish failure records a
  standalone best-effort terminal attempt. Provider unavailability creates no
  synthetic run. The already committed imported meeting, copied audio, cast,
  transcript, navigation timing, progress, and idle release remain unchanged.
  Exact metadata/privacy assertions and a real-Store injected summary rollback
  prove the boundary. The current gate is 606 package tests (13 gated), 230
  linted Swift source files, and 20 UI cases (D64).

- **Architecture Band 3 slice 3B complete — durable summary provenance shares
  the job fence (Jul 16, 2026)**: every post-capture model attempt now snapshots
  provider/model identity, the exact durable operation fingerprint, job attempt,
  recipe, output language, and transcript revision immediately before invoking
  the provider. Success commits the run, immutable summary, action items, job
  success, and lifecycle reconciliation in the existing lease/revision-fenced
  transaction. Provider/publish failures and cancellations after model start
  persist separate best-effort terminal runs; unavailable providers or inputs
  superseded before model start create none. Provenance JSON remains content-free
  and retries keep distinct attempt records. A required `SummaryArtifact` run,
  injected SQLite rollback, mismatch guards, and direct metadata tests cover the
  boundary; the durable resume XCUITest exercises the production worker. The
  slice gate was 603 package tests (13 gated), 230 linted Swift source files,
  and 20 UI cases (D63).

- **Architecture Band 3 slice 3A complete — manual summaries carry atomic,
  content-free provenance (Jul 16, 2026)**: `RegenerateSummary` now records the
  provider, model/revision, material fingerprint, recipe/reuse operation,
  output language, timing, outcome, and aggregate output metrics for direct
  generation and Apple translation pivots. Successful runs, immutable summary,
  and action items commit atomically; failed/cancelled attempts are best effort
  terminal records, while exact cache hits create no model run. Storage rejects
  orphaned successful runs, blank summary languages, malformed JSON, and
  cross-meeting/language links. No transcript, notes, prompt, summary, or action
  text enters provenance. Post-refine regeneration benefits through the same
  use case. Thirteen focused cases cover provider paths, fallback, cancellation,
  validation, rollback, and real-Store linkage. That slice gate was 600 package
  tests (13 gated), 230 linted Swift files, and 20 UI cases (D62).

- **Architecture Band 2 slice 2U complete — package boundaries describe real
  behavior (Jul 16, 2026)**: a compatibility audit found no app, CLI, test,
  project, script, or visible external source consumer for `ContextFeedKit` or
  `SyncKit`. Their public products, targets, test edges, and two placeholder
  files are removed; Core's `ContextItem`, co-authored notes, and future sync
  plans remain intact. A twenty-first architecture test prevents either name
  from returning without a deliberate vertical use case. Band 2 closes at 596
  package tests (13 gated), 229 linted Swift files, and 20 UI cases; fresh
  app-window evidence confirms no visible change (D61).

- **Architecture Band 2 slice 2T complete — Meeting Detail writes through one
  owner (Jul 16, 2026)**: `MeetingDetailModel` now owns explicit actions and
  effects for title/speaker changes, name and voice suggestions, action-item
  completion, Companion removal, meeting deletion, and searchable-content
  changes. Its `AppServices` client adapts Store, lifecycle, and Spotlight's
  compatibility trigger; the view no longer reaches any of those directly.
  Best-effort paths, manual-rename and Companion errors, delete navigation,
  and explicit remember-voice consent remain unchanged. The adapter also maps
  stale-refine persistence errors before presentation. Two direct model tests
  bring the verified baseline to 595 package tests (13 gated), 231 linted Swift
  files, and 20 UI cases. The existing summary case now checks that an action
  toggle returns through the scoped summary observation; the rail case retains
  fresh app-window evidence. At this slice boundary, only the two unused
  package targets remained; slice 2U subsequently removed them. Audio-path
  resolution and incremental Spotlight indexing remain measured Band 4 seams
  (D60).

- **Architecture Band 2 slice 2S complete — Meeting Detail reads one meeting,
  not the library (Jul 15, 2026)**: ApplicationKit now owns storage-independent
  `MeetingReviewReadModel`, core, newest-summary, section, and update contracts.
  Each detail route owns one `@MainActor @Observable MeetingDetailModel` that
  merges transcript/cast, newest immutable summary/action items, and Companion
  card streams; distinguishes missing from failed state; preserves healthy
  sections after partial failure; and publishes one projection. StorageKit
  observes the three query families through explicit regions and shares the
  core/Companion helpers with one-shot reads. Meeting Detail no longer reloads
  those projections through `libraryVersion` or three sequential Store reads.
  Accepted Refine regenerates from the accepted draft itself, avoiding a race
  with observation delivery. Seven new model, real-Store observation, and
  architecture tests bring the verified baseline to 593 package tests (13
  gated), 231 linted Swift files, and 20 UI cases. The existing detail case
  retains fresh app-window visual evidence. Direct detail mutations still use
  the Store and increment the broad counter for Spotlight; slice 2T removes
  that presentation bypass without changing visible behavior (D59).

- **Architecture Band 2 slice 2R complete — Insights reads only what changed
  (Jul 15, 2026)**: ApplicationKit now owns one storage-independent
  `InsightsReadModel` plus facts, balance, findings, section, and update
  contracts. Each `ContentView` owns a per-window `InsightsModel` that samples
  one scope date, rejects stale observations, preserves healthy sections on a
  partial failure, and publishes one dashboard projection. StorageKit exposes
  independent observations for live meetings; participant/commitment facts;
  voice balance; and finding evidence bounded to the 60 newest live meetings
  in the selected scope. One-shot and observed paths share query helpers.
  `InsightsView` no longer imports StorageKit, reaches `services.store`, or
  consumes `libraryVersion`; Meeting Detail and Spotlight retain that seam.
  Ten new read-model, model, observation, and architecture tests bring the
  verified baseline to 586 package tests (13 gated), 227 linted Swift files,
  and 20 UI cases. The existing heatmap case retains app-window-only visual
  evidence. No visible behavior, schema, localized copy, `DatabaseQueue`, or
  capability dependency changed (D58).

- **Architecture Band 2 slice 2Q complete — meeting preparation policy is
  inward (Jul 15, 2026)**: `ApplicationKit` now owns `BriefRelevance`,
  `ReminderPolicy`, and `MirrorStats`; `PortavozCore` owns the calendar-neutral
  `UpcomingEvent` value; and `IntegrationsKit` retains EventKit mapping, RAG,
  external formats/egress, and MCP adapters. Brief ranking/reasons, reminder
  timing/deduplication, and mirror qualification plus bilingual factual
  synthesis are unchanged. An eighteenth architecture rule locks the split and
  direct app imports. The existing 14 policy tests remain green, bringing the
  verified baseline to 576 package tests (13 gated), 223 linted Swift files,
  and 20 UI cases. A temp-store-only fresh-recording fixture validates and
  retains app-window evidence of the real opted-in mirror sheet. No released
  behavior, schema, capability dependency, or localized copy changed (D57).

- **Architecture Band 2 slice 2P complete — Insights policy is inward (Jul 15,
  2026)**: `ApplicationKit` now owns `InsightsScope`, `LibraryStats`, and
  `InsightsFindings`, preserving current/previous scope windows, duration and
  streak aggregates, zero-filled rhythm heatmaps, no-decision findings, and
  recurring-topic ranking. `InsightsView` consumes those policies without an
  `IntegrationsKit` import; the Store-backed facts, voice balance, and broad
  `libraryVersion` refresh remain unchanged. A seventeenth architecture rule
  locks source ownership and the narrow app import. The existing 21 policy
  tests remain green, bringing the verified baseline to 575 package tests (13
  gated), 222 linted Swift files, and 19 UI cases; the Insights heatmap case now
  retains app-window screenshot evidence. No visible behavior, schema,
  capability dependency, or localized copy changed (D56).

- **Architecture Band 2 slice 2O complete — meeting review policy is inward
  (Jul 15, 2026)**: `ApplicationKit` now owns the deterministic
  `ChapterExtractor`, `PlaybackRanges`, `SummarySections`, and `VoiceHue`
  policies. Meeting Detail, Insights, recording captions, and the app design
  system consume them through the application boundary; `IntegrationsKit` no
  longer owns their source files. Sixteen architecture rules prevent the four
  policies from returning to the outbound layer and require every direct app
  consumer to import `ApplicationKit`. The existing 18 policy tests preserve
  chapter boundaries, safe voice-range complements, language-agnostic summary
  tabs, and stable speaker hues. The verified baseline is 574 package tests
  (13 gated), 222 linted Swift files, and 19 UI cases; retained XCUITest
  screenshots cover Meeting Detail review and Library voice mix. No visible
  behavior, schema, dependency edge, or localized copy changed (D55).

- **Architecture Band 2 slice 2N complete — Library reads only what changed
  (Jul 15, 2026)**: ApplicationKit now owns storage-independent Library row,
  open-item, trash, search, section, and update contracts. StorageKit exposes
  independent `ValueObservation` streams with explicit regions for meeting
  rows/voice mix (`meeting`, `speaker`, `segment`), open items (`meeting`,
  `summary`, `actionItem`), trash (`meeting`), and active FTS (`meeting`,
  `segment`). The app composition adapter merges section updates while
  `LibraryModel` preserves healthy sections when one projection fails. Library
  no longer consumes `libraryVersion`; Detail, Insights, and Spotlight retain
  it for their own parity slices. Three real-Store observation tests and a
  ninth model test bring the verified baseline to 573 package tests (13 gated),
  222 linted Swift files, and 19 UI cases. `DatabaseQueue` and schema v6 remain
  unchanged (D54).

- **Architecture Band 2 slice 2M complete — Library state has one owner (Jul
  15, 2026)**: each main window now owns one `@MainActor` `@Observable`
  `LibraryModel`. Its private-write value snapshot and enum actions/effects own
  loading, FTS debounce, stale-result fences, meetings/voice mix/open items,
  rename/mutations, trash, import progress/errors, calendar agenda, briefs,
  and navigation outcomes. `LibraryView` and `TrashSection` render and present
  native UI only; an `AppServices` client adapts the existing Store, use cases,
  and platform services. The characterized `libraryVersion` trigger and
  StorageKit projection types remain intentionally as compatibility seams for
  the next scoped-observation slice. Eight direct model tests plus a fifteenth
  architecture rule bring the verified baseline to 569 package tests (13
  gated), 220 linted Swift files, and 19 UI cases (D53).

- **Architecture Band 2 slice 2L complete — exports stop blocking the meeting
  view (Jul 15, 2026)**: `ApplicationKit.ExportMeetingBundle` now owns one
  read-consistent meeting/cast/transcript/newest-summary/notes/Companion
  projection, machine-local path clearing, optional canonical audio policy,
  and format-neutral document assembly. StorageKit reads the complete live
  export snapshot in one GRDB transaction; private app adapters retain
  configured/fallback root resolution and format-v1 IntegrationsKit mapping,
  but complete channel reads and JSON/base64 encoding run at utility priority.
  Missing/unreadable channels, the native save panel, filename/UTI, and visible
  error behavior remain unchanged. Eight use-case/real-Store tests plus a
  fourteenth architecture rule bring the verified baseline to 560 package
  tests (13 gated) plus 19 UI cases (D52).

- **Architecture Band 2 slice 2K complete — meeting bundles become one safe
  aggregate (Jul 15, 2026)**: `ApplicationKit.ImportMeetingBundle` now owns
  machine-local path clearing, optional attachment staging, one complete Store
  commit, and compensating cleanup. The private IntegrationsKit adapter still
  decodes and remaps format v1 off the MainActor; its validated handoff admits
  only canonical system/microphone channels and m4a/caf/wav extensions. One
  StorageKit Unit of Work installs meeting, cast, transcript, immutable summary
  version 1 with action items, notes, and Companion cards, so a failure in the
  last child rolls everything back. Nine use-case/security/real-Store tests
  plus a thirteenth architecture rule bring the verified baseline to 551
  package tests (13 gated) plus 19 UI cases (D51).

- **Architecture Band 2 slice 2J complete — recovery finishes before workers
  begin (Jul 15, 2026)**: `ApplicationKit.RecoverInterruptedMeetings` now owns
  expired-lease-first ordering, non-ready candidate selection, a dynamic
  per-aggregate live-recording gate, evidence-to-lifecycle reconciliation,
  guarded empty-shell discard, canonical failure preservation, and typed
  invalidation/logging results. The private macOS adapter retains configured
  plus fallback root discovery and detached CAF validation, hashing,
  remeasurement, and no-overwrite publication. Launch still awaits the full
  no-ML pass before worker adoption. Thirteen use-case/real-Store tests plus a
  twelfth architecture rule bring the verified baseline to 541 package tests
  (13 gated) plus 19 UI cases (D50).

- **Architecture Band 2 slice 2I complete — Start reserves truth before
  hardware (Jul 15, 2026)**: `ApplicationKit.StartRecording` samples start
  preferences once, prepares an injected runtime, derives the title and
  same-day sequence, atomically reserves the meeting shell plus pending channel
  assets, and only then invokes source start. Failed starts inspect staging and
  published evidence, retain any bytes as `needsAttention`, and discard only
  an untouched empty shell; every failure releases preparation. A private app
  runtime owns concrete mic/process-tap sources, `RecordingSession`, direct
  per-channel Parakeet streams, and one voiceprint future shared by live
  diarization and Stop. The controller retains live filtering, diarization,
  rolling summary, localized result mapping, and synchronous next-buffer mic
  mute. Ten use-case/real-Store tests plus an eleventh architecture rule bring
  the verified baseline to 527 package tests (13 gated) plus 19 UI cases (D49).

- **Architecture Band 2 slice 2H complete — Stop has one durable owner (Jul
  15, 2026)**: `ApplicationKit.StopRecording` receives immutable finalized
  capture evidence and owns reservation/publication reconciliation,
  provisional attribution, homogeneous aggregate language without changing
  each segment language, transcript/no-audio recovery, atomic captured
  snapshot plus exact initial-job admission, worker kick, and recording-engine
  release. `RecordingController` retains only the real session flush/feed
  teardown and typed result-to-UI mapping. The existing worker still owns
  diarization, optional summary, and terminal-aware Shortcut delivery. Eleven
  use-case/real-Store tests plus a tenth architecture rule bring the verified
  baseline to 516 package tests (13 gated) plus 19 UI cases (D48).

- **Architecture Band 2 slice 2G complete — reviewed refine cannot overwrite
  newer truth (Jul 15, 2026)**: `ApplicationKit.RefineMeeting` owns the typed
  audio/preference/processor/progress workflow and produces a draft carrying
  its source transcript revision. Automatic recognition remains unhinted for
  mixed ES/EN evidence; silent channels, microphone noise, and bleed remain
  suppressed; diarization remains degradable; cancellation is explicit; and
  engine release is guaranteed after every model-owning exit.
  `ApplyRefinedMeeting` commits language, cast, transcript, and the next
  revision atomically, rejects a stale draft, preserves immutable summaries,
  and treats Companion refresh as post-commit optional work. The CLI uses the
  same StorageKit Unit of Work. Sixteen use-case/storage tests, a ninth
  architecture rule, and a 19th XCUITest bring the verified baseline to 504
  package tests (13 gated) plus 19 UI cases (D47).

- **Architecture Band 2 slice 2F complete — imported audio has one owner (Jul
  15, 2026)**: `ApplicationKit.ImportMeeting` now coordinates typed file,
  preference, processor, store, summary, and progress ports. Meeting-length
  copies and rollback run off the main actor; copied audio remains staged until
  one StorageKit transaction commits the meeting, cast, and transcript. A
  required precommit failure removes staged audio best-effort, while the
  released required transcription, degradable second diarizer pass, optional
  summary, independent language policies, idle engine release, Library
  invalidation, and navigation timing remain unchanged. Thirteen import tests
  plus an eighth architecture rule bring the package baseline to 487 tests
  (D46).

- **Architecture Band 2 slice 2E complete — summary structures survive reload
  (Jul 15, 2026)**: regeneration cache/pivot reads now include the selected
  recipe, and Meeting Detail selects the newest live immutable snapshot across
  every recipe instead of silently defaulting to General. SQLite insertion
  order breaks equal-timestamp ties deterministically; older General, Standup,
  Planning, 1:1, Interview, and custom snapshots remain addressable in their
  independent version histories. One storage test, recipe-aware use-case
  assertions, and an 18th XCUITest close T16 and bring the package baseline to
  473 tests (D45).

- **Architecture Band 2 slice 2D complete — regeneration is one application
  workflow (Jul 15, 2026)**: Meeting Detail now sends `RegenerateSummary` one
  immutable request and maps its typed result. ApplicationKit admits
  IntelligenceKit only for this vertical slice and coordinates narrow
  storage, preferences, and provider ports; private app adapters retain global
  versus per-meeting engine selection, local model construction, Apple
  availability, and platform preferences. Provider override, recipe/language,
  persisted notes, glossary, direct-provider behavior, Apple fingerprint hit,
  translation pivot/fallback, and the released visible/silent error policies
  are unchanged. Nine use-case tests plus a new source ratchet bring the
  package baseline at that slice was 472 tests.

- **Architecture Band 2 slice 2C complete — purge crosses explicit ports (Jul
  15, 2026)**: manual permanent deletion and launch-time 30-day cleanup now
  run through `PurgeMeeting`/`PurgeExpiredTrash`. ApplicationKit coordinates a
  narrow StorageKit port with an app-owned filesystem adapter; it never imports
  FileManager policy. Audio failure remains degradable, storage failures still
  propagate to the presentation boundary, strict cutoff and continue-after-failure behavior are preserved,
  and the existing `libraryVersion` net change is unchanged. Four tests cover
  port behavior, failures, expiry, and real scratch audio/database removal. The
  package baseline at that slice was 462 tests.

- **Architecture Band 2 slice 2B complete — trash mutations enter through use
  cases (Jul 15, 2026)**: ApplicationKit now admits StorageKit for the first
  real vertical workflows. `DeleteMeeting` and `RestoreMeeting` depend on a
  narrow Sendable persistence port, with MeetingStore as the production
  adapter. Library, Meeting Detail, and Recently Deleted use the boundary;
  source rules prevent direct lifecycle writes from returning. Port-delegation
  and real-store conservation tests retain the exact tombstone, aggregate, and
  voice-mix behavior. The package baseline is 458 tests.

- **Architecture Band 2 slice 2A complete — dependencies are executable (Jul
  15, 2026)**: SwiftPM and XcodeGen now expose a Core-only `ApplicationKit`,
  linked by app, CLI, and tests, with a Sendable async use-case contract. Five
  architecture tests parse the real manifests and source imports: they freeze
  the Core-only starting edge, forbid capability-to-application dependencies,
  reject presentation/platform imports in ApplicationKit, and keep Core's one
  existing Security exception from spreading (D44). No production call path
  changed. That behavior-neutral shell became the foundation for slice 2B.

- **Architecture Band 1 complete — normal Stop is durable (Jul 15, 2026)**:
  Stop now publishes audio, installs captured assets/live transcript/notes/cards,
  and admits the exact first diarization job in one SQLite transaction (D43).
  The meeting opens immediately while the process worker continues attribution
  and optional summary; relaunch resumes the same work. One recording-scoped
  voiceprint value keeps live and durable identity consistent. The configured
  Shortcut runs after terminal processing, including transcript-only success,
  while temp-store automation can never invoke a host Shortcut. One request
  policy test plus atomic admission/rollback tests bring the package baseline
  to 449. The next architecture band is the application-layer extraction.

- **Architecture Band 1 slice 1D-b2b executor complete (Jul 15, 2026)**: a
  process-scoped supervisor now starts after capture recovery and serially
  resumes supported durable diarization/summary jobs. It owns 120-second
  leases with 30-second heartbeats, exact versioned operation fingerprints,
  stale-input cancellation, bounded retries, and one scheduled future wake
  instead of polling. Diarization completion and exact dependent summary
  enqueue remain atomic; exhausted optional summaries cancel without failing
  the meeting. Four focused fingerprint tests bring the package baseline to
  446. A safe temp-store-only processing fixture adds the 17th XCUITest case,
  and a disposable direct-app smoke reached `ready`, transcript revision 1,
  and two succeeded jobs while preserving the original Spanish transcript.
  The normal Stop producer remains unchanged for the final 1D-b2b cutover.

- **Architecture Band 1 slice 1D-b2 control plane advanced (Jul 15, 2026)**:
  optional or superseded work now has an owner-leased terminal cancellation
  transition that does not turn the meeting into `needsAttention`, and workers
  can query the earliest future `notBefore` for their explicit capabilities
  without polling or observing tombstoned meetings. Two focused tests bring the
  package baseline to 442. The released synchronous Stop path remains unchanged;
  the concrete process executor landed in the following 1D-b2b unit.

- **Architecture Band 1 slice 1D-b2a complete (Jul 15, 2026)**: StorageKit now
  commits diarization cast replacement/transcript revision or one immutable
  summary snapshot together with owner-leased job success and optional
  dependent enqueue (D41). Exact operation fingerprints, source revisions,
  live ownership, and current speaker references fence stale output. Generic
  completion cannot mark generated work successful without its artifact, and
  lifecycle derivation preserves unresolved capture publication. Five focused
  tests bring the package baseline to 440. The released synchronous Stop path
  remains unchanged; slice 1D-b2b owns app queue adoption.

- **Architecture Band 1 slice 1D-b1 complete (Jul 15, 2026)**: a process-level
  `RecordingRecoveryCoordinator` now recovers expired leases and reconciles
  interrupted capture state before any view is required. It scans the current
  and fallback audio roots, remeasures persisted PCM off the main actor,
  publishes staging-only CAFs, revalidates final-only CAFs, records missing
  channels explicitly, and preserves ambiguous copies without overwrite or
  deletion. A repeat-safe StorageKit Unit of Work protects ready meetings and
  installs recovered evidence atomically (D40). Three focused package tests
  bring the baseline to 435, and a new disposable XCUITest proves a recovered
  meeting is visible and playable. The launch pass invokes no ML; slice 1D-b2b
  owns concrete durable job producers/workers.

- **Architecture Band 1 slice 1D-a complete (Jul 15, 2026)**: the schema-v6
  job row now has strict `PortavozCore` domain types and a StorageKit queue.
  Enqueue is atomic/idempotent, live-rooted claims are filtered by worker kind
  and ordered by priority, attempts are protected by owner-bound expiring
  leases, progress is monotonic, retries use `notBefore`, and terminal/expired
  work derives the meeting lifecycle repeat-safely (D39). Seven focused tests
  bring the package baseline to 432. The released synchronous post-capture
  path remains unchanged; slice 1D-b1 subsequently added launch recovery and
  slice 1D-b2b owns app queue adoption.

- **Architecture Band 1 slice 1C complete (Jul 15, 2026)**: channels now write
  to `<channel>.partial.caf`, then Stop validates a readable non-empty mono
  CAF, streams its SHA-256, records duration/size/format, finite peak/RMS dBFS,
  and signal health before a same-directory no-overwrite rename publishes
  `<channel>.caf`. One `installCapturedSnapshot` transaction advances the
  shell, finalizes assets, and installs the provisional live
  cast/transcript/notes/Companion cards before derived processing. Atomic
  collision/rollback, signal-classification, metadata, and untouched-shell
  tests brought the package baseline to 425 tests. Slice 1D-a subsequently
  added the durable queue contract and slice 1D-b1 added launch recovery.

- **Architecture Band 1 slice 1B complete (Jul 15, 2026)**: every new live
  recording now atomically persists a `recording` meeting shell and one typed
  pending `audioAsset` per selected source before capture starts. Empty startup
  attempts are rolled back only when no file or persisted content exists; any
  written channel is preserved as `needsAttention`. Stop advances the durable
  lifecycle through `captured`, `processing`, and `ready`, while empty captions
  or later required-write failures keep the audio discoverable. Four focused
  reservation/rollback tests brought the package baseline to 419 tests. Slice
  1C subsequently replaced direct final-path writes with staged publication.

- **Architecture Band 1 slice 1A complete (Jul 15, 2026)**: one atomic,
  additive schema-v6 migration establishes meeting lifecycle/revision fields,
  `audioAsset`, idempotent `processingJob`, `generationRun` links,
  `outboxEvent`, and typed meeting-preference storage. A real-shape v5 fixture
  and a scratch copy of the real release database migrate without changing
  legacy meeting or audio-directory truth; SQL constraints reject invalid
  states, paths, language-mode pairs, and duplicate jobs. The migration
  deliberately performs no filesystem backfill, so runtime behavior remains
  unchanged until slice 1B.

- **Architecture Band 0 slice 0B complete (Jul 15, 2026)**: transcript
  recognition and generated-summary language now use independent typed
  policies. Auto mode keeps mixed ES/EN evidence unforced, while a separate
  persisted Summary language setting consistently controls recording, rolling
  summary, import, and regeneration. Refine recalculates homogeneous language
  from its output and clears stale aggregate metadata for mixed/unknown
  meetings. Durable per-meeting rows now have a schema-v6 home, but app flows
  do not create or read them yet.

- **Architecture Band 0 slice 0A complete (Jul 14, 2026)**: StorageKit no
  longer mints random identities, silently drops malformed contextual rows, or
  changes invalid channels to `system`. Typed integrity errors surface corrupt
  persisted values. Deleted meetings now disappear from summaries, findings,
  participants, action totals, voice mixes, and talk balance; restoring the
  meeting returns the exact prior projections. Regression coverage guards both
  invariants.

- **Phase 1 (M0–M6, M8 core): built and measured green** — all acceptance criteria met (4 ms drift, 0.53 s p95 lag, 7.6% AMI DER, 3.8 s summary). 0.1.0 signed + notarized, used in 4 real meetings.
- **Phase 2: the CORE of M10, M12, and M13 is already implemented and tested** (Jul 2026, Fable day) — co-authored notes (notes→summary weaving), fingerprint cache + translation pivot, BYOK, and the complete live Companion (detection + routing + BYOK + "te preguntaron"), all on the D29 priority scheduler. What remains for each is in its row below.
- **M9 RELEASED (Jul 10, 2026)** 🎉: public repository at github.com/johnny4young/portavoz, v0.1.0 release (signed+notarized+stapled DMG, `spctl: Notarized Developer ID`; Sparkle appcast attached and reachable), and `portavoz` cask in the centralized `johnny4young/homebrew-tap` tap (`brew tap johnny4young/tap && brew install --cask portavoz`, clean audit; automated bump via `update-cask.yml` + TAP_DEPLOY_KEY, Gancho pattern). Pre-publication sensitivity sweep: work-environment fixtures replaced with a fictional universe. Next focus: OSS growth (README/discoverability) + continuous field verification.
- **v0.2.0 RELEASED (Jul 11, 2026)**: one day after 0.1.0 — system-wide ⌥⌘D dictation, voices remembered across meetings, persistent menu bar + launch at login, Spotlight, Insights, post-meeting Shortcut + `portavoz://record`, model idle release, fixed sidebar. Notarized DMG + Sparkle appcast (0.1.0 users receive the update automatically) + cask bumped via `update-cask.yml` (clean audit). CI fixed along the way: explicitly select the newest Xcode (the macos-latest image rotates defaults and mlx-swift requires tools 6.3).
- **v0.3.0 RELEASED (Jul 11, 2026)**: `.portavoz` bundle (share meetings between Macs, M15 L0), Markdown backup of the entire library, configurable dictation hotkey, and recent meetings in the menu bar. **Separate development flow from today onward**: `/Applications/Portavoz.app` is the user's notarized copy (only Sparkle/brew update it, DO NOT TOUCH); `make install` installs `/Applications/Portavoz Dev.app` (same bundle ID, re-signed after the rename); real data used for testing is copied, never operated on live (ARCHITECTURE).
- **v0.4.0 RELEASED (Jul 11, 2026)**: trash with restore (+30-day auto-purge), optional audio in the `.portavoz` bundle (additive field — older readers import text only), and hold-to-talk dictation (tap = toggle, hold = walkie-talkie). Next focus: design system in Claude Design (brief in docs/design/claude-design-brief.md) + subsequent sync with /design-sync.
- **v0.5.0 / v0.5.1 RELEASED (Jul 12–14, 2026)**: the 6a design system (details below) and, in 0.5.1, custom summary structures + the first pass at bug C (AirPods capture via a per-process tap on the meeting app).
- **v0.6.0 RELEASED (Jul 14, 2026)**: the Companion no longer exists only while live. Its cards are **persisted** with the meeting (`companionCard` table, v5 migration), reviewed in the detail rail (each one jumps the player to the moment of the question), **improved when refine is applied** (re-derived from the clean transcript, coalescing utterances and using context from both channels), and **travel in the `.portavoz` bundle** (optional additive field — closes T11). Also: **configurable capture sources** (mic + `Automatic`/meeting app/all system audio), **mute mic to Portavoz** (silences your channel, not the call), **chapters with AI-generated topical titles** (`ChapterTitler`, fallback to the real excerpt), and per-app capture is now **limited to recognized meeting apps + their helpers** by bundle ID (previously it tapped every process producing sound — picking up music and notifications). Notarized DMG + Sparkle appcast (build 202607141922 > 0.5.1's 202607140037) + cask bumped. 15 green UI tests + green package suite.
- **Website LIVE (Jul 10, 2026)**: [portavoz.app](https://portavoz.app) — static bilingual ES/EN landing page in `site/`, deployed to Cloudflare Pages (`portavoz-web` project, custom domain + www connected; repository and cask homepages point there). Continuous deployment via `.github/workflows/pages.yml` (push to main touching `site/**`), guarded by the `CLOUDFLARE_API_TOKEN` (Pages:Edit) + `CLOUDFLARE_ACCOUNT_ID` secrets — until they exist, the workflow cleanly skips deployment and a local deployment can be made with `npx wrangler@4 pages deploy site --project-name=portavoz-web --branch=main` (wrangler authenticated through OAuth).
- **Design system 6a implemented (Jul 12–14, 2026)**: the Claude Design DS brought into the app + web. In the app — 4a recording (top bar + one column + mute + adaptive HUD), two-column detail (health + chapters ✦ + persisted Companion), summary tabs, menu bar "✦ pendientes", and the three honest 6a features: **chapters** + **"solo mi voz"**, **6a-2 mirror mode** (measured-not-judged post-meeting coach, opt-in, pure `MirrorStats` + `MirrorCard`), and **6a-4 "primera escucha" onboarding** (live demo with SpeechAnalyzer before downloading models, reuses the audio to enroll the voice; `FirstListenController`). On the web — **"constelación de voces" DS landing page** (`site/`, bilingual, hero with orbiting voices, the amber one is you). Validation through **XCUITest** (15 UI tests) as the default method; computer-use only as a last resort (XCUITest caught a real `PlaybackRanges` crash). 401 green package tests, SwiftLint 0.
- **Minor active debt**: diarization micro-cluster policy to evaluate against the corrected RTTM (the knob already exists: `meetings refine --threshold`, Jul 2026). (FluidAudio re-pinned to `.upToNextMinor(from: "0.15.5")` — T9 resolved Jul 2026.)

## Phase 1 — Local-first foundation (M0–M6, M8 core) ✅ built

| Milestone | Scope | Acceptance criterion | Status |
|---|---|---|---|
| **M0 — Skeleton** | SPM workspace, domain contracts, CI, docs | `swift test` green in CI; `brew`-ready layout | ✅ |
| **M1 — Capture** | Mic + per-app process taps, dual-channel recording, retention policies, AEC (D24), device-change resilience | 30-min recording produces two synced WAVs, drift < 50 ms | ✅ measured: 4 ms |
| **M2 — Transcription** | Parakeet streaming (FluidAudio), slot scheduler, model registry with verified downloads | Live transcript < 2 s latency while a batch file transcribes without degrading it | ✅ p95 0.53 s |
| **M3 — Diarization** | pyannote on system channel, "Me" via mic channel, editable speaker pills, micro-cluster merge | 4-person meeting: DER < 15%, user's turns 100% attributed | ✅ AMI 7.6% |
| **M4 — Intelligence** | Incremental summaries (Foundation Models + BYOK), Recipes v1, bilingual EN/ES output | Structured summary < 30 s after meeting end; Spanish summary of an English meeting with glossary intact | ✅ 3.8 s |
| **M5 — Public 0.1** | StorageKit (FTS5, versioned snapshots), MD/PDF/Gist export, polished UI, signed and notarized DMG+Sparkle+cask | Public release: "knows who said what, locally" | ✅ released as v0.1.0 on Jul 10, 2026 |
| **M6 — Identity & language** | Auto speaker naming (LLM + EventKit), voice enrollment, live translated captions | 1-tap speaker→name mapping; live ES↔EN captions | ✅ code; partial field verification |
| **M8 — Dev moat (core)** | MCP server, GitHub/Linear export, local RAG chat | An MCP agent answers "what did I agree to yesterday?" | ✅ verified |

## Phase 2 — World-class on the Mac (0.2–0.6)

The phase where the user feels that **native is worth it**. Reordered after analysis round 2: release FIRST (stars compound: Meetily 20.5K, Anarlog 8.8K, MacParakeet 451 in 5 months — every private month is growth given away), and co-authored notes (D28) come before the Companion because they are the category's most validated pattern.

| Milestone | Scope | Acceptance criterion |
|---|---|---|
| **M9 — Release + OSS growth** | **Released (Jul 10, 2026)**: public repository, v0.1.0 GitHub release, signed/notarized/stapled DMG, Sparkle appcast, Homebrew cask, reproducible README benchmarks, strict SwiftLint CI, issue/PR templates, SECURITY.md, and EN/ES localization. Later releases through v0.6.0 continue the same distribution path | ✅ `brew install --cask portavoz`; benchmarks reproducible from the README |
| **M10 — Co-authored notes (D28)** | **Implemented (Jul 2026)**: ContextItem in Core, v3 table, notes→prompt weaving with the 3B model's budget, "▸" co-authorship convention, `addContextNote()` + persistence + regenerate; **notes panel during recording** (TextField + timestamped list with remove, right column) and **co-authorship rendering** in detail ("▸" bullets with a Granola-style accent mark). Remaining: field verification (5 real notes → a summary that expands them) | A meeting with 5 raw notes produces a summary that expands them without contradicting them, with co-authorship marks |
| **M11 — Audio first-class (D27)** | **Complete (Jul 2026)**: AudioPlaybackKit with synchronized player (Spotify-style carousel transcript in detail and recording), waveform colored by channel, clips (in/out → m4a < 2 s), **skip silence**, **AAC transcode** ("Comprimir audio"), and **import** (button + drag-and-drop → transcribe/diarize/summarize). Crash safety (CAF) already resolved (T1). Covered by XCUITest (D30) | Play any meeting with synchronized highlighting ✅; a `kill -9` at 30 min loses no more than 1 s of audio ✅ (CAF); 30 s clip exported in < 2 s ✅ |
| **M12 — Multiple engines (D25)** | **Implemented (Jul 2026): (1) summary cache by fingerprint + translation pivot; (2) BYOK with key in Keychain; (3) SpeechAnalyzer benchmarked in the live role vs. Parakeet (spec 02); (4) first-class Ollama as a summary engine (Settings detects + lists models and summarizes 100% locally without a key — closes GAPS #7, verified E2E with gpt-oss:20b); (5) hardware recommender; (6) compact 626 MB Whisper variant for low disk space; (7) per-meeting engine+language override.** **(8) Embedded MLX (D32): Apache-2.0 sha256-pinned Qwen3.5-4B 4-bit (~3 GB), in-process `MLXSummaryProvider` through the GPU, "Built-in (MLX)" option in Settings with verified download/remove, and the recommender suggests it without Apple Intelligence or Ollama (RAM ≥ 8 GB).** Remaining: coalescer append-vs-replace decision (SpeechAnalyzer, requires field verification) | A Mac without Apple Intelligence produces a 100% local summary (through guided Ollama or MLX); hardware recommendation is correct; `bench` compares engines |
| **M13 — Live Companion (D26)** | **Core implemented (Jul 2026)**: heuristic+FM classifier+routing for knowledge/context/logistics, cards with copy/dismiss, per-recording toggle, on the D29 scheduler. BYOK for knowledge implemented (D8 opt-in, disclosure per card, on-device fallback). Unified "te preguntaron" detector (deterministic name gate + orange ping). Remaining: field verification of the <5 s budget. **Competitive window: Teams Facilitator ~Aug–Sep 2026** | Knowledge question → card < 5 s (real Cluely: 5–10 s); logistics questions do not generate cards |
| **M13b — Meeting health + Recipes** | **COMPLETE (Jul 2026)**: (1) 100% local per-meeting health panel (`MeetingHealth`); (2) typed Recipes (standup/1:1/planning/interview) + FM `MeetingTypeDetector` with "Summarize as…?" chip and Structure submenu — suggestion only, never applied automatically; (3) pre-meeting brief from the calendar (`MeetingBrief` + "Next:" row in the sidebar; only with access already granted); bonus: in-app RAG chat + suggested smart title | Health panel ✅; correct suggested Recipe for ≥3 types ✅ (test gated against the real model: standup/planning/interview + debugging→general) |

## Phase 3 — iOS/iPadOS (M14, formerly M7)

Hard constraint D11: iOS does not capture audio from other apps. The iPhone is a **first-class in-person recorder + companion**, not a clone of the Mac.

| Milestone | Scope | Acceptance criterion |
|---|---|---|
| **M14a — Xcode project + portable Kits** | iOS target; audit Kits: `#if os(macOS)` in AudioCaptureKit (ScreenCaptureKit/process taps excluded), TranscriptionKit with Parakeet int8 (~483 MB, viable on the iPhone ANE; NO Whisper large — use SpeechAnalyzer/whisper small for mobile refine), FM available on iOS 26 | The Kits compile for iOS; the in-person recorder transcribes live on an iPhone 15+ |
| **M14b — In-person recorder** | The 6 D11 modes: AirPods studio-quality (`bluetoothHighQualityRecording`), speakerphone calls, importing share extension, overnight BGProcessingTask (refine with `requiresExternalPower`), thermal degradation | Record 1 h in person with < 10%/h battery use; overnight refine when plugged in |
| **M14c — Companion + sync** | CKSyncEngine E2E (`encryptedValues`), Live Activity + Dynamic Island (timer + latest caption), remote control of Mac recording, Handoff | Record on iPhone → readable summary on the Mac without opening the app; correct Live Activity for 30 min |
| **M14d — iPad** | PiP live captions (AVPictureInPictureController over Zoom/Meet in Stage Manager), Split View, PencilKit anchored to the Core context timeline | Floating captions over a real call on iPad |

## Phase 4 — Sharing and platform (M15+)

| Milestone | Scope | Acceptance criterion |
|---|---|---|
| **M15 — Sharing L1 (D12)** | **L0 DONE (Jul 2026)**: `.portavoz` bundle — versioned JSON (formatVersion 1, additive) with transcript+cast+summary+action items+notes+Companion and optional audio (D4: local paths never travel); export from the detail menu, import via button/declared UTI/double-click (ALWAYS fresh IDs when importing — two imports = two independent meetings; 8 round-trip/compatibility tests). **Remaining**: CKShare between Apple IDs | Share a meeting with another Apple ID; open a bundle on another Mac ✅ (offline) |
| **M16 — App Intents / Shortcuts** | **v1 DONE (Jul 2026)**: (1) post-meeting hook — Ajustes → name of a Shortcut that runs when each meeting ends with the full Markdown as input (`shortcuts run` + `--input-path`, best effort, never blocks the pipeline); (2) `portavoz://record` URL scheme (CFBundleURLTypes) — any automation starts a VISIBLE recording (verified E2E). **Deferred**: AppIntents/Siri phrases — the AppIntents metadata processor runs only in Xcode builds; it enters with M14a's Xcode project. (3) Spotlight (Jul 2026): full reindex on launch/library change — title + summary + first lines of transcript; one click opens the meeting (`onContinueUserActivity`). Remaining: Quick Look | "Cuando termine una reunión del calendario X, exporta el resumen a Y" without touching the app ✅ (Shortcut with Markdown as input) |
| **M17 — Sharing L2** | Self-hostable relay (Humla/PocketBase pattern) with read-only web snapshot viewer | A participant without the app reads the summary through a self-hosted link |
| **M18 — visionOS (halo)** | SwiftUI port of library+detail; immersive review room (spatial timeline with clips); no capture promises | Review a meeting on Vision Pro with a spatial timeline |

Later / research: ~~MacParakeet-style system-wide dictation~~ (**DONE Jul 2026**: system-wide ⌥⌘D — Carbon hotkey + non-activating floating panel + Parakeet streaming with custom vocabulary + paste-and-restore through Accessibility; toggle in Ajustes, off by default; spec 06), synthesized voice (Personal Voice + virtual driver, mandatory disclosure), ~~vocabulary learning~~ (**DONE Jul 2026**: `VocabularyMiner` suggests recurring domain-shaped terms as chips in Ajustes), hardware recorder support (riffed pattern) if there is demand, ~~cross-meeting voiceprint-based speaker naming~~ (**DONE Jul 2026**: `VoiceGallery` + `VoiceMatcher` + chips — opt-in per person with the "Remember this voice" gesture after confirming a name; encrypted, never synced, forgettable in Ajustes; spec 03).
