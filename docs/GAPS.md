# GAPS — Gap analysis for world-class quality

What Portavoz lacks (Jul 2026) compared with the state of the art measured in the two rounds of competitive analysis (PRODUCT.md). Ordered by impact. Each gap states **what exists today**, **what is missing**, and **where it is planned** — if it is not planned, it says so.

## Product gaps (users feel them)

| # | Gap | Today | Missing | Plan |
|---|---|---|---|---|
| 1 | ~~**Zero distribution**~~ | **RESOLVED (10 Jul; hardened 16 Jul 2026)**: public repo, Sparkle appcast, direct DMG, and Homebrew tap. D74 notarizes/staples both the app and DMG and verifies an app copied out of the final image, so package-manager trust no longer depends on the outer container | growth (stars, discoverability); clean-Sequoia install of the next public artifact remains release evidence | ✅ M9/D74 |
| 2 | ~~**Audio cannot be played**~~ | **RESOLVED (Jul 2026)**: synchronized player + highlighting/auto-scroll + colored waveform + m4a clips, silence skipping, AAC transcoding, and import (`AudioPlaybackKit`, M11) | — | ✅ |
| 3 | ~~**Cannot write during the meeting**~~ | **RESOLVED (Jul 2026)**: notes panel during recording, persistence, notes→prompt weaving, co-authored rendering with a ▸ marker (M10/D28); **plus (Jul 25)** a separate regenerable "Enhanced notes" document per meeting — raw notes verbatim in bold, expanded with transcript facts (NOTES-001/D135) | field verification: 5 real notes → a summary that expands them without contradicting them | ✅ code / field pending |
| 4 | ~~**Recording requires the full window**~~ | **RESOLVED (Jul 2026)**: "Vista compacta" button while recording → floating HUD (NSPanel `.nonactivatingPanel` + `.borderless`, floating level, all Spaces) with timer, latest caption, mic meter, and stop; the main window minimizes to the Dock and the HUD expands it again only when leaving `.recording`. Clicks do not steal focus from Zoom/Meet | field verification (menu bar item DONE Jul 2026: MenuBarExtra with status + start/stop + dictation + launch-at-login) | ✅ code / field pending |
| 5 | ~~**Spanish-only UI**~~ | **RESOLVED (Jul 2026)**: English source strings, `Localizable.xcstrings` + `InfoPlist.xcstrings`, complete ES translation, export to `en.lproj`/`es.lproj` in `make-app.sh`, `CFBundleDevelopmentRegion=en`, `CFBundleLocalizations=[en, es]`, Settings selector **System / English / `Español`** with live SwiftUI locale | — | ✅ |
| 6 | ~~**No onboarding**~~ | **RESOLVED (Jul 2026)**: 4-step first-run flow (`OnboardingView`): local-first welcome, guided permissions (mic now / system audio explained / optional calendar), live-model readiness with progress + hardware recommendation, optional voice enrollment. The separate Whisper quality model can be prepared proactively in Settings; its verified app-scoped task survives that window and is reused by Refine/Import. Shown once (`hasOnboarded`); existing libraries skip it; `-show-onboarding` forces it | visual verification pending | ✅ code |
| 7 | ~~**Macs without Apple Intelligence = no local summary**~~ | **RESOLVED (Jul 2026)**: first-class Ollama plus embedded MLX. A clean install now chooses only a capability-compatible local path, preserves existing preferences, never silently changes a selected provider, and routes missing setup directly to Intelligence Settings. The shipped MLX path uses Qwen3.5-4B 4-bit on GPU and has been verified on a real 40-minute meeting | — | ✅ D32/D72 |
| 8 | ~~**External audio import without UI**~~ | **RESOLVED (Jul 2026)**: "Importar audio…" button + drag-and-drop in the library → transcribes (Whisper) + diarizes + summarizes as a new meeting (M11) | — | ✅ |
| 9 | ~~**No recap email**~~ | **RESOLVED (Jul 25, 2026)**: pre-meeting brief (M13b) plus the post-meeting **shareable recap** — summary-derived draft with real open commitments and owners, addressed to everyone or one participant, shaped for email/Slack/Markdown, reviewed and edited before the user copies it or picks a destination in the system share sheet (FEATURE-003/D136) | field verification: a real recap sent to real participants | ✅ code / field pending |
| 10 | Native App Intent ✅ / Quick Look remains absent | **App Intent DONE (Jul 26; field-registration hardened Jul 27, 2026)**: `StartRecordingIntent` is visible in the Shortcuts action picker, with metadata extracted separately from the SDK-only intents file under the shipping module name — no Xcode app target needed. The intent routes inside its owning process; stable, Dev, and UI-test apps have distinct system identities so LaunchServices cannot hide the Dev action behind another build (D139/D140). On macOS, reliable Spotlight/Siri invocation uses a user-created Shortcut containing the Portavoz-icon action. The custom Shortcut was field-verified from Shortcuts, Spotlight, and Siri on Jul 27. D141 removes the redundant `AppShortcutsProvider` after field testing showed its unsupported automatic shortcut beside the raw action in the macOS picker. Post-meeting Shortcut hook, `portavoz://record`, and meeting Spotlight indexing already existed | Quick Look genuinely needs an extension target and stays planned | D139–D141; QL M14a/M16 |
| 11 | Cross-device sync has no second-device product yet | **Band 6A–6C2 macOS vertical complete in code (D92–D97):** schema v14 remains the mutation authority; deterministic text-first envelopes replay atomically through encrypted private-zone records and durable exact attempts; D96 owns zero-touch consent/status/actions; and D97 adds one signed-capability-gated private container, process-scoped serialized wakeups, exact Developer ID release admission, and bilingual Settings. Audio, paths, voiceprints, secrets, and embeddings stay local | Production container/profile/account plus two-Mac convergence are still field gates before public enablement; the actual cross-device experience arrives with the 6D in-person iOS recorder shell. Audio remains a later separate opt-in | Band 6D / M14c; field pending |

## Technical gaps (debt and risk)

| # | Gap | Risk | Plan |
|---|---|---|---|
| T1 | ~~WAV crash safety~~ | **RESOLVED**: verified that WAV+kill -9 = 0 readable bytes; capture migrated to CAF (kill -9 → 5.23 s of 6 s preserved); readers with fallback to legacy .wav | ✅ Jul 2026 |
| T2 | ~~**Taps + VPIO in the same process**~~ | **RESOLVED IN CODE (D125):** real Sequoia and Tahoe calls confirmed that enabling VPIO could duck playback and degrade the meeting app's uplink; meeting and dictation capture are now raw and never enable call-audio ducking | Real-call Sequoia + Tahoe A/B remains below; post-capture bleed filtering replaces live graph mutation |
| T3 | ~~FM without a priority policy~~ | **RESOLVED (D29)**: single-flight `IntelligenceScheduler` with priorities, latest-wins per key, 7 tests | ✅ Jul 2026 |
| T4 | ~~**Unmeasured Mac performance numbers**~~ | **RESOLVED for cold start, recording RAM, drift, DER, refine, summary, exact/lexical/semantic retrieval through 100k segments, 30m/2h/8h detail projections, a real 55.9-minute dual-channel waveform, and Spotlight through 100k meetings. Band 4B brings first content from 522.30 ms to 91.87 ms; Band 4C brings lexical Ask from p95 111.19 ms to 66.89 ms; Band 4E brings semantic wall/CPU p95 from 325.41/328.43 ms to 90.22/91.26 ms; Band 4F brings waveform repeat wall/CPU p95 from 747.53/754.79 ms to 70.11/71.33 ms without a cache; Band 4G brings Spotlight projection wall p95 from 22,085.35 ms to 425.64 ms without an outbox. Battery remains an iOS-phase measurement. Retention now exists: `make perf-ledger` re-measures the unattended journeys against the budgets declared in `docs/evidence/perf-thresholds.json` and the committed baseline, and fails a release on a budget miss (PERF-001/D137)** | ✅ D79–D85/D137/spec 08 |
| T5 | ~~Brute-force O(n) semantic RAG~~ | **RESOLVED (D83): the exact adapter streams SQLite-owned BLOBs, scores with Accelerate, retains bounded top-k rowids, and fetches full passages only for winners. 100k wall/CPU p95 is 90.22/91.26 ms with 8.42 MiB incremental footprint** | ✅ Keep the exact Float32 vector layout carried unchanged into schema v14; reconsider sqlite-vec only after a future measured miss |
| T6 | ~~Audio storage 126 MB/channel/22 min~~ | **RESOLVED (Jul 2026)**: "Comprimir audio (AAC)" enters ApplicationKit, converts every raw channel as one failure-safe batch, refuses existing canonical outputs, and removes no original until every generated m4a verifies; `MeetingAudioLayout` prefers m4a | ✅ D112 |
| T7 | CI does not run model-gated tests | integration regressions are invisible in CI | self-hosted runner or monthly manual job — NOT PLANNED |
| T8 | ~~No SwiftLint/format in CI~~ | **RESOLVED (Jul 2026)**: `.swiftlint.yml` calibrated to zero errors + `lint` job in CI (M9 prep) | ✅ |
| T9 | ~~FluidAudio pinned to a revision~~ | **RESOLVED (Jul 2026)**: 0.15.5 includes fix #732; re-pinned to `.upToNextMinor(from: "0.15.5")` | ✅ |
| T10 | ~~No unified local diagnostics/provenance surface~~ | **RESOLVED through D146:** slices 3A–3H record content-free attempt provenance, enforce every current meeting-content HTTP path, and expose an honest per-meeting privacy receipt. Slice 3I adds an explicit local JSON support export over one atomic content-free snapshot; pseudonymizes identities and fingerprints; excludes meeting/generated text, prompts, raw errors, secrets, config/metrics, full URLs, and paths; independently exposes durable processing state and bounded retry in Meeting Detail; and emits content-free job signposts. Slice 3J keeps recording Start/Stop dependency messages outside the boundary by carrying only stable codes/categories until the app localizes recovery. Slice 3K adds signed sandbox/control evidence and an explicit feature-parity defer decision. D115 also discloses an acknowledged encrypted private-iCloud copy permanently and avoids claiming end-to-end protection unless Apple's account setting guarantees it. D146 keeps support format 2 stable while a separate content-free field protocol maps six real-call fixtures to seven stable subsystem evidence IDs and can pair the same pseudonymous meeting before/after Refine. Content-free discovery/download traffic and the explicit local Shortcut process remain deliberately outside the receipt boundary | ✅ D62–D78/D115/D146 |
| T11 | ~~Post-recording workflow is only partially durable~~ | **RESOLVED (D36–D43/D70/D73/D104; field-hardening Jul 16):** capture persists shell/assets before writing, starts independently from model readiness, validates and publishes CAFs without overwrite, and atomically commits captured content plus the exact first job. Missing or failed live captions admit durable multilingual first-pass transcription from finalized audio through a Parakeet-only readiness path; optional pyannote preparation cannot block transcript publication. A process-scoped supervisor resumes one owner-leased ApplicationKit workflow after launch recovery; it preserves exact fingerprints, bounded retries, optional-summary degradation, atomic artifacts/dependents, and scheduled wakes without polling. Reservation timestamps compare at SQLite's durable millisecond precision, not a stricter in-memory precision. Stop navigates immediately after the handoff; audio/transcript survive failures, and Shortcut parity is retained | ✅ audio-first start guard, role-scoped model-readiness characterization, atomic admission/rollback, submillisecond reservation regression, transcription/diarization/summary workflow/artifact/recovery tests + disposable runtime characterization |
| T12 | ~~Persisted UUID read fallbacks create random identities~~ | **RESOLVED (Band 0 slice 0A):** malformed persisted IDs and enums now fail with typed `StorageError` integrity errors instead of minting, omitting, or changing entity meaning | ✅ strict-decoding + source-guard tests |
| T13 | ~~Some library aggregates include soft-deleted meetings~~ | **RESOLVED (Band 0 slice 0A):** every summary, finding, participant, action, voice-mix, and talk-balance projection scopes through a live meeting; restore returns the prior values | ✅ delete/restore conservation tests |
| T14 | ~~Summary-language defaults differ by entry path~~ | **RESOLVED (Band 0 slice 0B):** independent typed transcript/summary policies now drive recording, rolling summary, import, and regeneration through one resolver; mixed/unknown follow-spoken summaries use the selected app locale | ✅ D35 + policy/unit/EN-ES UI tests |
| T15 | ~~**Broad app invalidation and orchestration concentration**~~ | **RESOLVED (D44–D61/D85/D98–D114):** characterized product and read policy enters ApplicationKit; Library, Insights, Meeting Detail, Ask, menu bar, first-run, local-data receipt, meeting preparation, backup, CLI/MCP, durable post-capture execution, coherent meeting-document preparation/publication, calendar-backed speaker naming, local voice enrollment, local-provider discovery, participant voice memory, Settings resources, reminders, review metadata, audio coordination, and verified model readiness have scoped owners and narrow ports. StorageKit supplies query-scoped observations and atomic aggregate/job transactions. Exact production-graph and repository-wide SwiftUI presentation ratchets now prevent dependency reversal, concrete adapter construction, and direct persistence access from views. The 5k detail reaches first content in 91.87 ms. Xcode 26.6 still emits no SwiftUI update-cause rows, so exact view invalidation causes remain explicitly unmeasured rather than represented as zero** | ✅ workflow/model/observation/architecture tests + bilingual real-app UI gates; re-measure SwiftUI causes when tooling supports them |
| T16 | ~~A generated custom summary structure can disappear from Meeting Detail after broad reload~~ | **RESOLVED (Band 2 slice 2E):** D25 cache/pivot reads carry the requested recipe, and Meeting Detail selects the most recently created live snapshot across recipes while preserving every recipe-specific version | ✅ storage history + recipe-cache tests and XCUITest reload fixture |
| T17 | ~~A cold recording never attaches live transcription after its model becomes ready~~ | **RESOLVED (D121):** recording starts immediately with bounded per-channel feeds, asynchronously joins the verified Parakeet load, and exposes preparing/available/failure state. The active session begins captions and downstream live features as soon as the engine is ready, while durable post-capture transcription still covers the pre-attachment interval. Translation also exposes download, unsupported-pair, and execution failures and cannot reuse cached output across target languages | ✅ bounded-feed, hot-attachment, callback, translation-state, and bilingual real-app UI evidence |
| T18 | ~~Refined punctuation noise and model-authenticated but false summary sources survive into durable output~~ | **RESOLVED (D122/D172):** one Core lexical policy filters both Refine channels, accepted Refine storage rejects nonlexical rows, and intelligence formatting excludes legacy noise. Generated source tags require distinctive lexical support before persistence, while decision restatements are removed from action items even when speaker attribution is rendered differently | ✅ Core/Application/Storage/Intelligence characterization and transaction tests |
| T19 | ~~A prolonged remote callback outage can leave an unattended microphone recording, while support export cannot compare channel shape~~ | **RESOLVED (D123):** after two outage minutes Portavoz keeps recovery/microphone capture running but promotes an explicit Stop action; multi-hour finalization runs at utility priority, and redacted support format 2 adds per-channel health/duration plus transcript counts without paths, checksums, identities, or content | ✅ outage-threshold, peer-publication, redaction, JSON export, and real-app UI evidence through Stop exit and typed Retry |
| T20 | ~~A rejected optional Stop payload can strand already-finalized audio in a recording shell~~ | **RESOLVED in code (D127):** Stop retries the full snapshot once, then degrades through provenance-valid core content, finalized audio plus durable transcription, and canonical needs-attention projections. Launch recovery repairs a content-bearing stale shell and validated assets in one pass | ✅ exhaustive use-case and real-Store regressions; next real-call Stop remains a field gate |
| T21 | ~~Mixed-language live translation can repeatedly ask for a source language, while incoming captions steal history scroll and blur too aggressively~~ | **RESOLVED in code (D128/D129):** each source revision uses an explicit source-target lane; a sufficiently long growing turn refreshes before another speaker closes it, target-language and uncertain rows remain spoken text, and translations use a labeled visual rail. Reader interaction pauses follow indefinitely, history stays sharp, and an explicit Jump to live resumes the bounded live treatment | ✅ routing/state/visual-policy tests plus disposable UI evidence; next mixed real call remains a field gate |
| T22 | ~~Automatic Refine can translate mixed speakers, live speaker bleed can duplicate rows, generated summaries can invent owners, and verified Whisper preparation looks like a repeated download~~ | **RESOLVED in code (D130–D132/D142):** automatic Refine never pins a complete channel; bounded live admission prefers direct system speech over time-aligned mic bleed, including exact two-word and rolling-edge copies; action owners must match the cast before Markdown and typed projection; Whisper distinguishes local verification from a real transfer, and models remain in Application Support across bundle replacement | ✅ deterministic multilingual, temporal callback-order, owner-admission, preparation-state/localization, paragraph-projection, and architecture evidence; next mixed real call remains a field gate |
| T23 | Live-lane accuracy has a measuring stick but no challenger yet | `bench-live` now scores WER/CER against a reference (`--reference`) and writes JSON evidence (`--output`); the Qwen3-ASR-0.6B CoreML candidate exists upstream but FluidAudio's latest tagged release (0.15.5) does not include `Qwen3AsrManager`, and the pinned-dependency rule forbids tracking `main` | Re-visit when FluidAudio tags a release with Qwen3 support: bench on Spanish fixtures vs Parakeet v3, swap the live lane only if WER wins within the latency budget (spec 02 §Qwen3-ASR candidate) |
| T24 | Instant Library semantic recall has no explicit asset-readiness control | D145 reuses Apple's installed Latin contextual embedding assets and never downloads from typing. Exact bilingual/accent-folded FTS remains available everywhere, but a clean Mac that has never prepared embeddings receives no semantic augmentation yet | Measure the OS asset footprint and add an explicit Settings prepare/status action before presenting semantic Library search as universally ready |
| T25 | The resource-interference matrix has collectors but no accepted hardware baseline | D148/D149 define content-free workload intervals and the fail-closed 27-cell contract. D150/D152 provide isolated native Release collectors for all nine scenarios: idle, recording, Stop, Refine, Summary, Ask, standalone semantic indexing, recording plus indexing, and recording plus post-capture batch transcription. Concurrent collectors prepare assets and runtimes outside measurement, start exact product work only after real recording Start, freeze before Stop, and fail closed unless workload validation and Stop both succeed. D167 adds a threshold-free safety invariant for competing Whisper/MLX residency, D177 defers or checkpoint-pauses semantic backfill across every protected capture phase while retaining `NULL` rows as its durable resume cursor, D178 resumes that work from launch/mutation/capture-stop signals without polling or background downloads, D179 applies the same capture checkpoint to explicit existing-library sync admission with a protected cursor, D180 defers a waiting whole-library backup before staging, and D181 checkpoints its bounded stage copy and one-at-a-time export across protected capture. Other host-pressure, power, storage, concurrency, and scheduler outputs remain intentionally inactive. Model-heavy paths use verified Portavoz or already-installed Apple assets plus fixed public synthetic fixtures, but no host receipt is accepted | Capture three stable runs per cell on 8 GB, 16 GB, and reference Macs; review and freeze the baseline before deriving numeric tiers, budgets, or TTLs |
| T26 | Whole-library Markdown backup is not relaunch-resumable | D180 prevents a backup requested during protected capture from reading SQLite or publishing files. D181 creates one coherent private SQLite stage, checkpoints bounded page copy and one-at-a-time render/publication work, and resumes process-locally without republishing completed files. D182 gives current-format stages kernel-owned leases and removes only provably abandoned stages at process launch while preserving live and unknown workspaces. D183 retains regular bookmark identity in the active actor, follows a moved destination, and reacquires/closes one access lease per execution interval without misrepresenting the current non-App-Sandbox app as security-scoped. App termination still loses the bookmark bytes, collision reservations, publication manifest, and state needed to adopt and continue that stage | Persist destination identity and a privacy-safe publication manifest, define collision reservation and the atomic move/manifest crash protocol, then add stage adoption and restart semantics before claiming relaunch-durable backup |

## Positioning gaps (against the competitive map)

- **OSS growth after publication**: distribution is solved; discoverability,
  adoption, and trust in a native Swift + MIT product remain ongoing work.
- **Watch companion**: Teams "Facilitator" arrives ~Aug-Sep 2026. Being first in local meeting notes matters (M13).
- **Semantic end-of-turn model (APUN-005 tail)**: the deterministic D138
  endpointer covers turn ends visible in the transcript (punctuation,
  interrogatives, owner mentions). pipecat smart-turn v3 (8.7 MB int8, BSD-2,
  ~12 ms, 23 languages, sha256-pinnable) would add intonation-only turn ends
  but ships ONNX-only; adoption is deliberately deferred until an official
  CoreML artifact exists or an onnxruntime dependency is justified on its own
  merits. Re-check the pipecat-ai/smart-turn-v3 repo when revisiting.
- **Public benchmarks**: reproducible latency, drift, DER, summary, refine,
  startup, FTS, semantic, long-audio waveform, large-library Spotlight, and
  memory numbers are published. The next credibility step is retaining these
  baselines and adding an ethical quality corpus for evidence-linked claims.
- **The archive story**: Granola charges for access to your >30-day-old notes. Our inverse pitch — "your history is never held hostage" — is not written in any README yet.

## Pending field verification (requires the user, not code debt)

Implemented and tested features whose final criterion can be closed only with a real meeting:

Use the content-free procedure and exact admission checks in
[`FIELD-VALIDATION.md`](FIELD-VALIDATION.md) for callback recovery, AirPods
process-tap capture, cold live captions, live translation, post-capture Refine,
and Apuntador/name continuity. The collector rejects content-bearing additions
and never reads `/Applications/Portavoz.app`.

D147 now turns the release subset into a machine-readable, fail-closed
scorecard: deterministic, signed-build, real-hardware, and user-field proofs
must all describe the exact release identity. This automation does not close
the rows below. Missing real Sequoia/Tahoe built-in and AirPods packages,
callback recovery, long-call, model-cold, or mixed-language evidence remains a
visible release blocker rather than being inferred from deterministic tests.

- **Portavoz 0.7.0 Homebrew install on clean Sequoia** (D74): `brew install --cask johnny4young/tap/portavoz` must install and launch the 0.7.0 public artifact on a Mac with no prior Portavoz receipt. The local v0.6.0 cask reproduction proved the outer DMG passed while the extracted app lacked a stapled ticket; the fixed release gate now rejects that state. Preserve `brew install --verbose --debug` output if any separate failure remains.
- **Production private sync** (D97/D116): configure `iCloud.app.portavoz.mac`, deploy the production CloudKit schema, and issue an unexpired Developer ID profile with the exact production CloudKit and macOS push capabilities. On two clean Macs using one iCloud account, prove explicit future-change opt-in, separately confirmed existing-library seed, bidirectional edits, encrypted tombstone propagation, restart/retry, silent-push wake, sign-out/in, a real account switch requiring fresh consent, pause, and remove-this-Mac without deleting local meetings or remote records. Record the actual destination's complete-protection and backup-exclusion capabilities and verify that unsupported metadata omits only the unavailable key while `0600`, durable verification, and atomic publication remain intact. Reproduce Homebrew extraction and renew the profile before expiry. Do not market sync as field-proven until this matrix passes.
- **Apuntador < 5 s** (D26/D72): on macOS 26 with Apple Intelligence available, a real meeting knowledge question must produce a card in < 5 s; also validate the "you were asked" detector (mention of your name → ping) and, if you configured BYOK, the external answer path with disclosure. Sequoia is intentionally excluded because the current question classifier is Foundation-Models-only; Settings explains this and exposes no dead enable toggle.
- **Call-safe raw capture (D125)**: on both Sequoia and Tahoe, begin a call
  without Portavoz, confirm participant playback and the user's uplink, then
  start Portavoz without changing devices. Playback and uplink must sound
  identical while the Portavoz mic and system timelines both advance. Repeat
  through built-in speaker/mic and AirPods. Export content-free diagnostics
  before and after Refine.
- **Mouse push-to-talk delivery**: with Accessibility granted, configure
  vendor-facing Button 3 (middle click) and one additional mouse button in
  separate runs. In a third-party editor, prove press starts, release inserts
  once, the target app never receives the configured click, unconfigured
  buttons still pass through, timeout re-arming works, and rebinding during an
  active mouse-owned session cancels safely. Repeat once after revoking and
  re-granting Accessibility through System Settings. XCUITest covers Settings
  and pure ownership rules but cannot drive a session event tap into another
  process.
- **System callback recovery (D120, field 21 Jul 2026)**: one real recording's system channel stopped advancing after 33:20 while microphone capture continued for more than two hours. In another real call, reproduce a complete callback stall and prove that Portavoz shows the remote-audio warning within about eight seconds, keeps microphone capture active, rebuilds the same process tap, resumes the same system timeline, and clears the warning after frames return. Deterministic source/session coverage is complete, and scoped XCUITest proves the prolonged-outage Stop exits capture into the explicit typed no-audio Retry when the fixture publishes no file; real Core Audio recovery and durable-file publication are not yet claimed.
- **Stop durability after rejected live payload (D127, field 22 Jul 2026)**: in the next real call, Stop must open the saved meeting without `recording.stop.snapshot.persistence.failed`. Export redacted diagnostics before Refine and prove both finalized channels, a non-recording lifecycle, and either the preserved live transcript or an explicit durable transcription job. The exhaustive transaction and launch-recovery regressions are complete; field closure is not yet claimed.
- **Mixed-language field integrity (D130–D132/D142, field 24–27 Jul 2026)**: in the next Spanish/English call, verify that an overlapping exact two-word or rolling-edge speaker copy produces one direct-system live row rather than alternating `Me`/`Them` copies, sequential acknowledgements remain separate, stable same-voice rows read as one paragraph, and unresolved generic `Them` rows remain separate. Stop must open a non-recording meeting, automatic Refine must preserve each turn's spoken language, and generated action owners must be cast labels/confirmed names or unassigned. Reinstall `Portavoz Dev.app` before one repeat and confirm Settings still reports the verified Whisper variant as downloaded; a checksum-only pass must say it is checking local files, and a percentage labeled download must correspond to missing/corrupt artifacts.
- **July 30 live-quality evidence (D172/D173/T23)**: an 8:55 real call reached
  `ready` with successful transcription, diarization, and summary jobs, but its
  redacted report showed a clipped 0 dBFS system channel, a weak −41.63 dBFS
  microphone RMS, only 2 microphone rows among 94 transcript rows, and three
  successful Apuntador generations within 29 seconds. Deterministic card
  admission now makes one source-turn lineage replace its earlier card and
  summary admission removes attribution-shaped decision/task copies. The
  persisted writer pass now exposes sustained system-channel ceiling evidence
  through a dismissible live warning without changing the call or recording.
  Live paragraph and talk-balance derivations now own fixed recent-work bounds
  while the complete admitted transcript remains available to Stop/recovery.
  Field validation remains open for live WER/CER, card usefulness,
  business-quality decisions/tasks, whether the warning appears on the next
  genuinely clipped call, and the upstream source of that clipping.
- **Clear playback quality (D144)**: after a built-in-speaker call with both
  system and microphone channels, compare `Clear playback` on and off over
  remote-only speech, local-only speech, and one overlapping turn. The clear
  mix must remove the delayed remote copy without clipping the user's turn.
  Repeat with a mic-only/in-person recording and confirm that no clear toggle
  or channel attenuation is applied. This validates listening quality only;
  the original files must remain byte-for-byte unchanged.
- **AirPods system-channel continuity** (C, field 13 Jul 2026, OPEN): two
  AirPods recordings produced mic-only evidence, including one digitally silent
  system channel. Silent-channel hallucinations are already rejected and
  automatic/app capture can tap recognized meeting processes before device
  routing. D125 additionally removes VPIO from meeting capture, eliminating one
  graph conflict. Repeat the D125 A/B with AirPods: if the process tap remains
  silent, preserve microphone mobility and report the hardware limitation
  rather than forcing the built-in mic.
- **Device change (D163)**: a July 30 real call confirmed that switching from
  built-in audio to AirPods no longer closed the app. The remaining field
  closure repeats built-in speaker/mic → AirPods → built-in and proves both
  microphone and system files continue on their original timelines with only
  bounded silence at each handoff. The repeated Jul 28–29
  `AVAudioEngineImpl::InstallTapOnNode` SIGABRT signature is covered by a fresh
  microphone graph plus generation-fenced route work, and process-tap
  Start/rebuild/Stop are serialized in code; reverse-route and dual-channel
  continuity remain the field gate.
- **Formal M3 DER**: correct the Speaker column of the draft RTTM in `~/Desktop/portavoz-verificacion/reunion-2026-07-07.md` → measure with `portavoz-cli der --file system.wav --reference <rttm corregido>`.
- **Translation pivot** (D25): regenerating a summary in another language must translate the existing snapshot (fast) instead of summarizing again; verify that it preserves structure and action items.
- **Cold live captions, translated captions, and reader ownership (D121/D128/D129)**: release the idle speech models or use a clean install, start recording before Parakeet is ready, and prove captions begin automatically during the same call after verified preparation without an audio gap or memory growth. Then use the "Translate → …" picker across Spanish and English speakers; prove same-language and uncertain short rows remain unchanged, a long still-growing opposite-language row gains a labeled translation before the next speaker, later growth refreshes that row, no source-language modal appears, target switching cannot restore stale output, pair download is deliberate, and unsupported/failure states are visible rather than silent. Scroll into caption history while new rows arrive: the position and sharp text must remain stable until the explicit Jump to live action.
- **Hybrid Library search (D143/D145)**: on Sequoia and Tahoe, confirm an
  unaccented query finds accented source text, common English/Spanish terms
  find the same meeting, and an exact hit remains first. After the Apple Latin
  embedding assets have been prepared through an explicit intelligence flow,
  search one paraphrase with no shared words and verify the appended semantic
  hit seeks to the correct timestamp. Repeat during recording and confirm only
  exact search runs and recording responsiveness does not regress.
- **Names from calendar**: event with attendees around a recording → "Sugerir nombres ✦" (requests calendar TCC).
- **Remembered-voice calibration (D105)**: build an explicit-consent private
  fixture with repeated clean clips for several remembered people plus
  same-gender and noisy-call negatives. Record nearest and runner-up cosine
  distances without persisting audio, then choose a threshold and minimum
  separation margin from false-accept/false-reject evidence. Until that matrix
  exists, `0.54` remains provisional and every result must remain an explicit
  suggestion rather than an inferred identity.
- **Confirmed person continuity (D86)**: name and explicitly remember a non-user speaker in one meeting, then confirm that the same normalized name in another meeting offers the existing person rather than linking automatically. Also verify that two distinct people with the same name remain selectable and that an accepted Refine asks for a fresh link because its speaker IDs are new observations.
- **Real-model overview evidence quality (D87)**: generate summaries with Apple
  Foundation Models, MLX, and the configured Ollama model over a copied real
  meeting; verify that every visible source directly supports the overview,
  unsupported overviews show no source rather than a weak one, and Refine turns
  the prior links stale before the regenerated summary installs fresh links.
- **Real-model Apuntador evidence quality (D91)**: on a copied real meeting,
  verify that every detected question keeps its exact spoken turn, every
  context answer exposes only the transcript passages named by exact local-RAG
  citations, and those passages directly support the answer. Knowledge answers
  and directed pings must expose no invented answer source. After Refine, old
  card evidence must resolve stale until the refreshed Apuntador snapshot
  installs sources for the accepted transcript revision.
- **Real export**: `export --gist` / "Publicar como Gist" with a token; `issues --github/--linear` with tokens against a test repo.

## What are NOT gaps (deliberate decisions — do not "fix")

- No proprietary backend or accounts (D12: zero servers until demand is proven).
- No call capture on iOS (D11: impossible; in-person recorder + companion).
- No bot that joins the call (the entire native bot-free market avoids it; our capture is local).
- Diarization threshold at 0.45 (raising it breaks AMI; fragmentation is resolved post-clustering).
- XCTest instead of Swift Testing (D13, because of the build environment without full Xcode).
