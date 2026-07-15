# Spec 08 — Quality: tests, harnesses, and measured numbers

Status: 435 package tests passing (13 gated) + 16 XCUITest UI tests. CI on GitHub Actions (`.github/workflows/ci.yml`: macos-latest, build + test + **SwiftLint `--strict`**).

**SwiftLint (`.swiftlint.yml`, `strict: true`)**: industry-recommended config (default rules + correctness/clarity opt-ins, industry thresholds: line 120, function-body 60/100, cyclomatic 12/20, type-body 400/600). `swiftlint lint --strict` passes with **zero violations** across `Sources`; in CI, any violation breaks the build. Inherent exceptions are suppressed inline with justification (catalog sha256 data, CLI arg-parser dispatchers, large SwiftUI views) — splitting those views remains technical debt.

## Test suite — `Tests/PortavozTests/`

| File | Coverage |
|---|---|
| AudioCaptureTests | CaptureFileWriter staging CAF, atomic no-overwrite publication, persisted-PCM recovery measurement, complete checksum/media/health evidence, drift summary, Downmix, **Resample.linear**, startup cleanup |
| AudioProcessCatalogTests | direct tap scope by bundle ID: exact app/allowed helpers accepted, lookalikes and unrelated apps rejected |
| TranscriptionTests | Mapper/deltas, WhisperEngine helpers, anti-silence hygiene, **SpokenLanguageDetector** with automatic/fixed mixed-language policy, **VocabularyPrompt**, **AudioLevel.normalizePeak** |
| CaptionCoalescerTests | 13 coalescer cases (merge, identity, channels, pauses, limits, loose punctuation, early split of `system` after sentence) |
| DiarizationTests | Catalog, SpeakerAttributor (multi-turn), SanitizeTurns, **MergeMicroClusters** (6), DiarizationEvaluation (units), live streaming (gated) |
| LiveSpeakerLabelerTests | 7 cases: row split with two voices, last row untouched, idempotency, mic never relabeled, "Me" by voiceprint |
| IntelligenceTests | PromptFactory, naming filters, **NamingExcerpt**, **LiveSummaryPolicy** |
| ChapterExtractorTests / TranscriptNoiseFilterTests | chapter boundaries/labels and conservative fragment filtering without losing sentences/acronyms |
| MeetingBundleTests | round-trip/remap of text, audio, notes, and Companion cards; additive compatibility of format v1 |
| MeetingHealthTests | 6 cases: talk-time/share, ES/EN questions, thresholded interruptions, chained monologues, unattributed excluded |
| VocabularyMinerTests | 6 cases: domain forms, recurrence threshold, existing-vocabulary/stoplist exclusion, form heuristics |
| MeetingTypeDetectorTests | Recipes catalog + capped excerpt; gated: classifies standup/planning/interview and leaves general alone (M13b criterion) |
| StorageTests / StorageSchemaV6Tests / RecordingPersistenceTests / ProcessingJobPersistenceTests / VoiceMixTests | Complete D4/D36/D37/D38/D39/D40 contract: strict persisted IDs/enums, tombstones plus guarded provisional rollback, versioning, hostile FTS, retention, paths, delete/restore conservation, schema-v6 v5-fixture migration, lifecycle/path/language/idempotency constraints, atomic pre-capture reservations, all-or-nothing captured/recovered snapshot installation, ready-state protection, and owner-leased durable jobs |
| RecordingsLocationTests | 7: marker, fallback, resolve, resumable migration |
| CoreTypesTests | Types + **TitleTemplate** + canonical `LanguageCode` and independent transcript/summary policies |
| LocalizationTests / EnglishSourceTests | EN/ES String Catalogs, placeholders, `.lproj` export, public-source English hygiene (README/top-level tooling, scripts, `.github`, packaging, app source), and English explanatory prose throughout `docs/` |
| RAGTests / MCPServerTests / VoiceIdentityTests / IntegrationsTests | RAG fusion, MCP protocol, encrypted voiceprint, offline exporters |
| ParakeetIntegrationTests + gated | Real models — require `PORTAVOZ_MODEL_TESTS=1` + `PORTAVOZ_TEST_WAV` / `PORTAVOZ_TEST_CONVERSATION_WAV` / `PORTAVOZ_TEST_ENROLL_WAV` |

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
XCUITest. The dev app is reinstalled only as `/Applications/Portavoz Dev.app`.

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

Local: `swift test` (if it fails with "no such module": `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — xcode-select points to CommandLineTools). XCTest, not Swift Testing (D13).

## UI tests — `Tests/PortavozUITests/` (`make test-ui`, D30)

XCUITest against the real app (XcodeGen generates the `.xcodeproj`, which is gitignored). `make test-ui` performs a preflight: it closes a previous Portavoz instance and warns if Gancho is running, because macOS XCUITest can fail before running tests with `Timed out while enabling automation mode` or interrupting windows. It verifies the UI through automation instead of driving the screen. Launch args: `-NSTreatUnknownArgumentsAsOpen NO`, `-ApplePersistenceIgnoreState YES`, `-use-temp-store` (disposable DB; Settings does not touch the real Keychain), `-seed-demo` (deterministic meeting with transcript, summary, coauthorship bullet "▸", and **audio**), `-seed-recovery` (a staging-only recovery fixture, allowed only with the temp store), and `-portavoz-open-settings` (deterministic Settings sheet for automation). Every launch receives a unique `PORTAVOZ_AUDIO_ROOT`; tests that exercise copied real audio may explicitly override it with `PORTAVOZ_TEST_AUDIO_ROOT`. The seed synthesizes a two-tone clip (mic/system) or adopts only that scratch copy. Covers 16 cases in `LibraryUITests`, `InsightsUITests`, `OnboardingUITests`, `MeetingDetailUITests`, and `SettingsUITests`: library and grouping, interrupted staging recovery to a playable detail, heatmap/interlocutors, first listen, summary/transcript/player/rail/clip, Settings navigation, independent transcript/summary language controls, custom structures, audio capture, mirror, and live locale. `make test-ui-en` and `make test-ui-es` force `-AppleLanguages`/`-AppleLocale`. Export itself (`AudioClipExporter`) is tested as a unit test — a 15 s clip from a 30 s source exports to m4a in a fraction of a second (comfortably below the < 2 s M11 criterion).

## Measurement harnesses

- `bench-m2`: live transcript lag (p50/p95/max) with concurrent batch processing.
- `portavoz-cli der`: DER against reference RTTM (public fixture: pyannote sample.wav/rttm).
- `scripts/verify_drift.py`: drift through envelope correlation (±5 s, edge warning, multi-point).

## Measured numbers (MacBook Pro M4 Max 36 GB, macOS 26, Jul 2026)

| Metric | Target | Measured |
|---|---|---|
| Live transcript lag | < 2 s | **p50 0.24 / p95 0.53 / max 0.56 s** |
| Batch Parakeet | — | ~100x real time (18 passes without degrading live processing) |
| Refine Whisper (22 real min) | > 15x | **23–42x** (1314 s in 31–56 s) |
| Mic/system drift | < 50 ms / 30 min | **4 ms / 22 min** (+4 ppm linear) |
| DER (AMI 2 speakers) | < 15% | **7.6%** (collar 0.25 s) |
| ES summary of EN meeting | < 30 s | **3.8 s** (glossary intact) |
| AEC convergence | — | **~2 s** (hence the warm-up) |
| Cold start | < 1.5 s | **0.94 s cold / ~0.26 s warm** (`--bench-startup`) |
| FTS at 1k meetings (80k segments) | < 50 ms | **p50 22.8 ms / p95 23.9 ms** (`portavoz-cli bench-fts`) |
| RAM by phase (`--bench-record 60 --bench-log <file>`, via `open -n`) | < 800 MB peak while recording / < 200 MB idle post-meeting | **20 MB without models → ~515 MB engines loaded → 569–795 MB peak while recording (LIVE diarization included) → 140–160 MB after the meeting**. The original target (500 MB) was set before adding live diarization; revised Jul 2026 |
| Embedded summary RAM (MLX) | transient, not resident | **~2.4 GB during generation**; `MLXModelCache` releases it only after 120 s idle (previously it remained resident forever) |

## Real bugs found and fixed (what an agent must know)

| Bug | Root cause | Fix |
|---|---|---|
| Meeting collapsed from 66→3 segments during refine | WhisperKit `concurrentWorkerCount` default 16 → race on shared decoder; its chunker SWALLOWS per-chunk errors | `concurrentWorkerCount: 1` + coverage retry |
| Deterministic collapse with vocabulary | promptTokens derail windows that do not mention the terms; raw coverage was misleading (valid spans, empty text) | coverage over CLEAN segments + retry without prompt + natural-language phrase |
| Silent meeting "sin voz" | WhisperKit EnergyVAD absolute threshold 0.02 | prior peak normalization |
| Repeated `Yo: .` and `Me: Thank you.` without speaking | Loose-punctuation deltas and Whisper silence boilerplate at VAD cadence | lexical hygiene + repeated-boilerplate filter on mic |
| Mic died when headphones connected (min 24/30) | AVAudioEngine stops on config-change, silent stream | restart + resample + silence gap |
| Phantom "Yo" with speakers | mic captured system audio (100% echo; text-only dedup covered only 57%) | AEC VPIO by default (D24) |
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
code failure: run the UITests without concurrent automation clients.
