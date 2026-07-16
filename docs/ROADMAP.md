# Roadmap

Each milestone is independently shippable and has a measurable acceptance criterion.

## Current state and next step (Jul 2026)

Single source of truth for progress — it previously lived in a session HANDOFF; state is now read here, decisions in [DECISIONS.md](DECISIONS.md), as-built behavior in [specs/](specs/README.md), and gaps + field verification in [GAPS.md](GAPS.md).

**Next concrete step:** continue Band 2 of the approved architecture-hardening
program in [refactor-20260714.md](refactor-20260714.md): extract
`ExportMeetingBundle` from `MeetingDetailView`. Preserve format-v1 additive
compatibility, machine-local path stripping, latest-summary/notes/Companion
content, optional canonical audio, the native save panel, and visible error
behavior while moving aggregate assembly and meeting-length file reads behind
one characterized ApplicationKit boundary. `ImportMeetingBundle`,
`RecoverInterruptedMeetings`, `StartRecording`, `StopRecording`,
`RefineMeeting`, `ImportMeeting`, and T16 are complete; Bands 0 and 1 are
complete. Every slice
preserves all v0.6.0 features and updates
`ARCHITECTURE.md` plus every affected source-of-truth document in the same
commit (D33/D34/D36/D37/D38/D39/D40/D41/D42/D43/D44/D45/D46/D47/D48/D49/D50/D51).

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
| **M14d — iPad** | PiP live captions (AVPictureInPictureController over Zoom/Meet in Stage Manager), Split View, PencilKit anchored to the timeline (ContextFeedKit) | Floating captions over a real call on iPad |

## Phase 4 — Sharing and platform (M15+)

| Milestone | Scope | Acceptance criterion |
|---|---|---|
| **M15 — Sharing L1 (D12)** | **L0 DONE (Jul 2026)**: `.portavoz` bundle — versioned JSON (formatVersion 1, additive) with transcript+cast+summary+action items+notes+Companion and optional audio (D4: local paths never travel); export from the detail menu, import via button/declared UTI/double-click (ALWAYS fresh IDs when importing — two imports = two independent meetings; 8 round-trip/compatibility tests). **Remaining**: CKShare between Apple IDs | Share a meeting with another Apple ID; open a bundle on another Mac ✅ (offline) |
| **M16 — App Intents / Shortcuts** | **v1 DONE (Jul 2026)**: (1) post-meeting hook — Ajustes → name of a Shortcut that runs when each meeting ends with the full Markdown as input (`shortcuts run` + `--input-path`, best effort, never blocks the pipeline); (2) `portavoz://record` URL scheme (CFBundleURLTypes) — any automation starts a VISIBLE recording (verified E2E). **Deferred**: AppIntents/Siri phrases — the AppIntents metadata processor runs only in Xcode builds; it enters with M14a's Xcode project. (3) Spotlight (Jul 2026): full reindex on launch/library change — title + summary + first lines of transcript; one click opens the meeting (`onContinueUserActivity`). Remaining: Quick Look | "Cuando termine una reunión del calendario X, exporta el resumen a Y" without touching the app ✅ (Shortcut with Markdown as input) |
| **M17 — Sharing L2** | Self-hostable relay (Humla/PocketBase pattern) with read-only web snapshot viewer | A participant without the app reads the summary through a self-hosted link |
| **M18 — visionOS (halo)** | SwiftUI port of library+detail; immersive review room (spatial timeline with clips); no capture promises | Review a meeting on Vision Pro with a spatial timeline |

Later / research: ~~MacParakeet-style system-wide dictation~~ (**DONE Jul 2026**: system-wide ⌥⌘D — Carbon hotkey + non-activating floating panel + Parakeet streaming with custom vocabulary + paste-and-restore through Accessibility; toggle in Ajustes, off by default; spec 06), synthesized voice (Personal Voice + virtual driver, mandatory disclosure), ~~vocabulary learning~~ (**DONE Jul 2026**: `VocabularyMiner` suggests recurring domain-shaped terms as chips in Ajustes), hardware recorder support (riffed pattern) if there is demand, ~~cross-meeting voiceprint-based speaker naming~~ (**DONE Jul 2026**: `VoiceGallery` + `VoiceMatcher` + chips — opt-in per person with the "Remember this voice" gesture after confirming a name; encrypted, never synced, forgettable in Ajustes; spec 03).
