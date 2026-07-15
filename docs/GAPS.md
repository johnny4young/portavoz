# GAPS — Gap analysis for world-class quality

What Portavoz lacks (Jul 2026) compared with the state of the art measured in the two rounds of competitive analysis (PRODUCT.md). Ordered by impact. Each gap states **what exists today**, **what is missing**, and **where it is planned** — if it is not planned, it says so.

## Product gaps (users feel them)

| # | Gap | Today | Missing | Plan |
|---|---|---|---|---|
| 1 | ~~**Zero distribution**~~ | **RESOLVED (10 Jul 2026)**: public repo + v0.1.0 release (notarized DMG, Sparkle appcast) + Homebrew tap with a clean audit — `brew install --cask portavoz` works | growth (stars, discoverability) | ✅ M9 |
| 2 | ~~**Audio cannot be played**~~ | **RESOLVED (Jul 2026)**: synchronized player + highlighting/auto-scroll + colored waveform + m4a clips, silence skipping, AAC transcoding, and import (`AudioPlaybackKit`, M11) | — | ✅ |
| 3 | ~~**Cannot write during the meeting**~~ | **RESOLVED (Jul 2026)**: notes panel during recording, persistence, notes→prompt weaving, co-authored rendering with a ▸ marker (M10/D28) | field verification: 5 real notes → a summary that expands them without contradicting them | ✅ code / field pending |
| 4 | ~~**Recording requires the full window**~~ | **RESOLVED (Jul 2026)**: "Vista compacta" button while recording → floating HUD (NSPanel `.nonactivatingPanel` + `.borderless`, floating level, all Spaces) with timer, latest caption, mic meter, and stop; the main window minimizes to the Dock and the HUD expands it again only when leaving `.recording`. Clicks do not steal focus from Zoom/Meet | field verification (menu bar item DONE Jul 2026: MenuBarExtra with status + start/stop + dictation + launch-at-login) | ✅ code / field pending |
| 5 | ~~**Spanish-only UI**~~ | **RESOLVED (Jul 2026)**: English source strings, `Localizable.xcstrings` + `InfoPlist.xcstrings`, complete ES translation, export to `en.lproj`/`es.lproj` in `make-app.sh`, `CFBundleDevelopmentRegion=en`, `CFBundleLocalizations=[en, es]`, Settings selector **System / English / `Español`** with live SwiftUI locale | — | ✅ |
| 6 | ~~**No onboarding**~~ | **RESOLVED (Jul 2026)**: 4-step first-run flow (`OnboardingView`): local-first welcome, guided permissions (mic now / system audio explained / optional calendar), model download with progress + hardware recommendation, optional voice enrollment. Shown once (`hasOnboarded`); existing libraries skip it; `-show-onboarding` forces it | visual verification pending | ✅ code |
| 7 | ~~**Macs without Apple Intelligence = no local summary**~~ | **RESOLVED (Jul 2026)**: first-class Ollama plus embedded MLX. The shipped MLX path uses Qwen3.5-4B 4-bit on GPU and has been verified on a real 40-minute meeting | — | ✅ D32 |
| 8 | ~~**External audio import without UI**~~ | **RESOLVED (Jul 2026)**: "Importar audio…" button + drag-and-drop in the library → transcribes (Whisper) + diarizes + summarizes as a new meeting (M11) | — | ✅ |
| 9 | No recap email (brief ✅) | **Pre-meeting brief DONE (Jul 2026)**: collapsible today/tomorrow agenda, brief with relevance + citations + recording from the brief + proactive banner (M13b) | post-meeting recap draft (email/Slack) | M16 |
| 10 | Native App Intents and Quick Look remain absent | Post-meeting Shortcut hook, `portavoz://record`, and Spotlight indexing are implemented | AppIntents/Siri metadata requires the future Xcode app target; Quick Look remains planned | M14a/M16 |

## Technical gaps (debt and risk)

| # | Gap | Risk | Plan |
|---|---|---|---|
| T1 | ~~WAV crash safety~~ | **RESOLVED**: verified that WAV+kill -9 = 0 readable bytes; capture migrated to CAF (kill -9 → 5.23 s of 6 s preserved); readers with fallback to legacy .wav | ✅ Jul 2026 |
| T2 | **Taps + VPIO in the same process** | MacParakeet declared them "reliably" incompatible; we have 1 OK sample | Active monitoring (see field verification below) + offline echo-cancel plan B (D27) |
| T3 | ~~FM without a priority policy~~ | **RESOLVED (D29)**: single-flight `IntelligenceScheduler` with priorities, latest-wins per key, 7 tests | ✅ Jul 2026 |
| T4 | ~~**Unmeasured Mac performance numbers**~~ | **RESOLVED for cold start, recording RAM, FTS at 1k meetings/80k segments, drift, DER, refine, and summary; battery remains an iOS-phase measurement** | ✅ spec 08; expand to 100k segments in refactor Band 4 |
| T5 | Brute-force O(n) RAG | at 1,000+ meetings, `ask` degrades | measure first (T4); sqlite-vec if it misses the target |
| T6 | ~~Audio storage 126 MB/channel/22 min~~ | **RESOLVED (Jul 2026)**: "Comprimir audio (AAC)" button in the detail view → transcodes to m4a (`AudioTranscoder`), deletes the original only after verified writing; `MeetingAudioLayout` prefers m4a | ✅ |
| T7 | CI does not run model-gated tests | integration regressions are invisible in CI | self-hosted runner or monthly manual job — NOT PLANNED |
| T8 | ~~No SwiftLint/format in CI~~ | **RESOLVED (Jul 2026)**: `.swiftlint.yml` calibrated to zero errors + `lint` job in CI (M9 prep) | ✅ |
| T9 | ~~FluidAudio pinned to a revision~~ | **RESOLVED (Jul 2026)**: 0.15.5 includes fix #732; re-pinned to `.upToNextMinor(from: "0.15.5")` | ✅ |
| T10 | No unified local diagnostics/provenance surface | field failures and generated artifacts are harder to explain | refactor Band 3: signposts, local diagnostics export, generation provenance, explicit opt-in for any transfer |
| T11 | ~~Post-recording workflow is only partially durable~~ | **RESOLVED (Band 1, D36–D43):** capture persists shell/assets before writing, validates and publishes CAFs without overwrite, and atomically commits captured content plus the exact first job. A process-scoped owner-leased worker resumes diarization/summary after launch recovery with exact fingerprints, bounded retries, optional-summary degradation, atomic artifacts/dependents, and no polling. Stop navigates immediately after the handoff; audio/transcript survive failures, and Shortcut parity is retained | ✅ atomic admission/rollback, job/artifact/recovery tests + disposable runtime characterization |
| T12 | ~~Persisted UUID read fallbacks create random identities~~ | **RESOLVED (Band 0 slice 0A):** malformed persisted IDs and enums now fail with typed `StorageError` integrity errors instead of minting, omitting, or changing entity meaning | ✅ strict-decoding + source-guard tests |
| T13 | ~~Some library aggregates include soft-deleted meetings~~ | **RESOLVED (Band 0 slice 0A):** every summary, finding, participant, action, voice-mix, and talk-balance projection scopes through a live meeting; restore returns the prior values | ✅ delete/restore conservation tests |
| T14 | ~~Summary-language defaults differ by entry path~~ | **RESOLVED (Band 0 slice 0B):** independent typed transcript/summary policies now drive recording, rolling summary, import, and regeneration through one resolver; mixed/unknown follow-spoken summaries use the selected app locale | ✅ D35 + policy/unit/EN-ES UI tests |
| T15 | Broad app invalidation and orchestration concentration | **Band 2 slice 2A established a Core-only `ApplicationKit` and executable dependency/import rules, but production workflows and global `libraryVersion` invalidation have not moved yet** | **Next:** extract and adopt `DeleteMeeting`/`RestoreMeeting`; continue one characterized use case at a time, then replace broad invalidation with scoped observations |

## Positioning gaps (against the competitive map)

- **OSS growth after publication**: distribution is solved; discoverability,
  adoption, and trust in a native Swift + MIT product remain ongoing work.
- **Watch companion**: Teams "Facilitator" arrives ~Aug-Sep 2026. Being first in local meeting notes matters (M13).
- **Public benchmarks**: reproducible latency, drift, DER, summary, refine,
  startup, FTS, and memory numbers are published. The next credibility step is
  retaining those baselines through the refactor and adding large-library
  results.
- **The archive story**: Granola charges for access to your >30-day-old notes. Our inverse pitch — "your history is never held hostage" — is not written in any README yet.

## Pending field verification (requires the user, not code debt)

Implemented and tested features whose final criterion can be closed only with a real meeting:

- **Companion < 5 s** (D26): in a real meeting, a knowledge question must produce a card in < 5 s; also validate the "you were asked" detector (mention of your name → ping) and, if you configured BYOK, the external path with disclosure.
- **Taps + VPIO coexisting** (T2): monitor the system channel with AEC active (glitches, dropouts, silence). 1 OK meeting is not evidence. If it appears, plan B in D27.
- **AirPods mute the system channel** (C, field 13 Jul 2026, OPEN): with AirPods connected, one meeting produced **mic only** — the `system.caf` channel was silent. Confirmed by measuring audio copied from the "Mita" meeting: mic −24.9 dBFS / 91% active (clean Spanish), system −51.2 dBFS / 2% active. Hypothesis: when AirPods are both output and input, macOS switches to HFP/SCO and the `CATap` on the default output stops reading the mix; or the graph rebuild (`ProcessTapSource.installOutputDeviceListener`) rebinds to a transient device. Confirmed a 2nd time (13 Jul, recording 9014F3AE with AirPods + video on the Mac): system.caf at −∞ dBFS (all zeros, 0% active) while the mic contained speech — and the silent channel produced a hallucinated Cyrillic segment (`<unk>ПРИК САКТО`), the source of "empezó a tomar el Russian". Mitigated: (a) `AudioSilence.fileIsSilent` skips digitally silent channels during refine, (b) live suppression of system-channel captions when `systemAudioMissing`, (c) B (live warning), (d) refine language override. With that, a silent channel remains EMPTY instead of inventing text. ROOT CAUSE in the code: `MicrophoneSource(voiceProcessing:)` opens the default input (AirPods) with `setVoiceProcessingEnabled(true)`, and opening the AirPods mic forces them into HFP → the output tap goes silent. The built-in mic fix (forcing built-in) was REJECTED: it breaks user MOBILITY (if the user moves away from the Mac, the built-in mic cannot capture them). User requirement: record with the system input/output, reactively. **SHIPPED EXPERIMENT (local, PENDING live verification)**: when the default output is Bluetooth, instead of tapping GLOBALLY, tap the meeting app PROCESS (`MeetingAppDetector` → PIDs for Zoom/Teams/Slack/Discord/Webex/FaceTime/browsers; `ProcessTapSource(processIDs:)` with `CATapDescription(stereoMixdownOfProcesses:)`). A process tap reads what the app renders BEFORE routing to the device → it MIGHT capture the call in HFP while retaining the AirPods mic. Fallback: no app detected → global tap (same as today). Outside Bluetooth → global tap (proven). A nudge in RecordingView names the tapped apps. A/B to verify: with AirPods + Zoom/Meet, the system channel must capture the call. If it does NOT, the process tap also cannot read in HFP and the limitation must be accepted (voice always captured, call limited).
- **AEC with speakers**: record through speakers and speak — your words appear as "Yo", others are NOT duplicated. If the mic sounds strange, Ajustes → disable "Cancelación de eco".
- **Device change**: connect/disconnect headphones midway — the mic channel survives (gap of silence, not termination).
- **Formal M3 DER**: correct the Speaker column of the draft RTTM in `~/Desktop/portavoz-verificacion/reunion-2026-07-07.md` → measure with `portavoz-cli der --file system.wav --reference <rttm corregido>`.
- **Translation pivot** (D25): regenerating a summary in another language must translate the existing snapshot (fast) instead of summarizing again; verify that it preserves structure and action items.
- **Translated captions**: record with the "Traducir → …" picker (the 1st time, macOS may ask to download the language pair).
- **Names from calendar**: event with attendees around a recording → "Sugerir nombres ✦" (requests calendar TCC).
- **Real export**: `export --gist` / "Publicar como Gist" with a token; `issues --github/--linear` with tokens against a test repo.

## What are NOT gaps (deliberate decisions — do not "fix")

- No proprietary backend or accounts (D12: zero servers until demand is proven).
- No call capture on iOS (D11: impossible; in-person recorder + companion).
- No bot that joins the call (the entire native bot-free market avoids it; our capture is local).
- Diarization threshold at 0.45 (raising it breaks AMI; fragmentation is resolved post-clustering).
- XCTest instead of Swift Testing (D13, because of the build environment without full Xcode).
