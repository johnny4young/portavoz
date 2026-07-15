# Roadmap

Each milestone is independently shippable and has a measurable acceptance criterion.

## Current state and next step (Jul 2026)

Single source of truth for progress — it previously lived in a session HANDOFF; state is now read here, decisions in [DECISIONS.md](DECISIONS.md), as-built behavior in [specs/](specs/README.md), and gaps + field verification in [GAPS.md](GAPS.md).

**Next concrete step:** implement Band 1 slice 1D of the approved
architecture-hardening program in
[refactor-20260714.md](refactor-20260714.md): adopt idempotent processing jobs
and reconcile interrupted `recording`/`processing` meetings plus staging files
on launch. Band 0 is complete and Band 1 slices 1A/1B/1C are complete. Every slice
preserves all v0.6.0 features and updates
`ARCHITECTURE.md` plus every affected source-of-truth document in the same
commit (D33/D34/D36/D37/D38).

- **Architecture Band 1 slice 1C complete (Jul 15, 2026)**: channels now write
  to `<channel>.partial.caf`, then Stop validates a readable non-empty mono
  CAF, streams its SHA-256, records duration/size/format, finite peak/RMS dBFS,
  and signal health before a same-directory no-overwrite rename publishes
  `<channel>.caf`. One `installCapturedSnapshot` transaction advances the
  shell, finalizes assets, and installs the provisional live
  cast/transcript/notes/Companion cards before derived processing. Atomic
  collision/rollback, signal-classification, metadata, and untouched-shell
  tests bring the package baseline to 425 tests. Slice 1D owns jobs and launch
  recovery.

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
