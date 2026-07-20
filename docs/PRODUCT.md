# PRODUCT — Vision, market, and features

## The promise (one only, for launch)

> **"Record your meeting and know who said what — including you — without requiring your audio or meeting content to leave your Mac."**

Everything else arrives across versions. The project's discipline is not to
dilute this promise before M5. Local processing is the default; explicit remote
providers and publishing are optional, and the per-meeting privacy receipt
makes tracked exceptions visible instead of weakening the promise silently.

## Positioning

No one in the market combines these 6 attributes; each competitor has ~2:

1. **True local-first** (on-device transcription + diarization + summarization)
2. **Speaker identity** (who said what + which contributions belong to the user + explicitly confirmed people remembered across meetings)
3. **Features for developers** (issues, ADRs, MCP, Shortcuts)
4. **Deep ES/EN bilingual support** (cross-language summaries, technical glossary, translated captions)
5. **One-time payment** (vs market-wide subscriptions of $8–19/user/month)
6. **Open source** (MIT)

Founding user and archetype: a Spanish-speaking developer with meetings in English.

## Competitive map (Jul 2026) and what was incorporated from each one

| Competitor | Model | What we stole from it |
|---|---|---|
| Granola ($1.5B valuation, Series C $125M Mar-2026; free = unlimited notes but ~30-day history — **monetizes the ARCHIVE**) | Cloud, bot-free, Mac+iOS+Android | The co-authoring loop (D28): raw notes → AI weaves them with the transcript, **your lines in black / AI additions in gray with a link to the segment**; Templates (~29) ≠ Recipes (post-hoc saved prompts with `/`); pre-meeting Briefs from the calendar; public share links without login, with transcript search; iOS records from the Lock Screen. **Its #1 criticisms = our plan**: no speaker ID, no audio playback, consent — D21+D27+D8. And its monetization lever (holding the archive hostage) is impossible for us = selling point |
| Fathom (free: UNLIMITED capture but AI capped at 5 calls/month since 2026; $16–25 annual plan) | Cloud, bot | Give capture away and charge for INTELLIGENCE (the inverse of Granola's pattern); summary target < 30 s post-call |
| Fireflies ($10–19) | Cloud, bot | RAG chat over history ("Global Brain") — our version: 100% local |
| tl;dv (unlimited free; $18+) | Cloud, bot | Shareable clips/moments with an instant link |
| Otter ($100M ARR; VERIFIED free: 300 min/month, 30 min/conversation cap, 3 lifetime imports) | Cloud, bot→bot-free agent | **Launched an MCP server for ChatGPT/Claude** — validates our M8 moat. Its free tier remains the stingiest in the category (corrected in round 2: the "unlimited" on its home page applies only to the Business plan) |
| Anarlog (ex-Hyprnote/Char; free local + $8/month) | **Local OSS (Tauri)** | Data ownership: each meeting is a user-owned .md file; BYOK. Lesson: it pivoted away from pure OSS → the "local open source" throne is vacant |
| MacWhisper (€59 one-time) / superwhisper ($249 lifetime) | Native Mac | The entire business model (D9/D10) |
| Krisp | Bot-free audio | **Live Interpreter** → our on-device translated ES↔EN captions (Translation framework) |
| Jamie (€0–39/month; German, EU hosting) | Native bot-free, **cloud** (its "privacy" = EU sovereignty, NOT local) | **System-wide ⌘J sidebar** ("meeting Spotlight": searches the entire history from any app — idea for our global ⌘K); model selection per task (validation of D25); it is manual pull — no question detection |
| Cluely ($20–75/month) + interview companions + **Teams "Facilitator" (~Aug-Sep 2026)** | Live-response overlays | The D26 Companion pattern has NO owner in meeting notes: Cluely promises 300 ms and delivers an actual 5–10 s + "cheating" stigma; Microsoft validates proactive question detection and sets a competitive deadline; interview companions (~$9/month) prove demand. Our angle: local (real latency), transparent, and `contexto` answers from YOUR history |
| Circleback | Action items | Distribution of action items to the right person; post-meeting automations → App Intents |
| MeetGeek | Templates/agents | Automatic meeting-type detection → automatic Recipe; auto-recording rules with guardrails |
| Read.ai | Coaching | Local "meeting health": talk-time, interruptions, question ratio (PRO) |
| Gemini in Meet | Platform | Summary attached to the calendar event (EventKit) + recap email draft |
| MacParakeet (GPL, Swift; **now 100% free, no paid tier**) | OSS dictation+meetings | Slot scheduler, retention, Homebrew+Sparkle, public benchmarks ("155x realtime") in README; **system-wide dictation mode via hotkey** (a surface we lack); live "Ask" about the meeting; 98 languages with dual-engine Parakeet+WhisperKit (25+73). **Patterns only, never code (GPL)** |
| Meetily v0.4 (MIT, Rust+Tauri; PRO cloud forthcoming) | Local cross-platform OSS | 7 LLM providers incl. **its own llama.cpp sidecar** (qwen3.5 2b/4b GGUF); recommender: RAM ≥14 GB → 4b, otherwise 2b; Whisper catalog **with q5 variants (turbo 547 MB)** + Parakeet ONNX; **cached EN summary → re-translation without re-generation** (directly relevant to our ES/EN core); summary cache keyed by fingerprint (transcript+prompt+template+model); validatable JSON templates with action items citing segment+timestamp; normalization to −23 LUFS + RNNoise; external audio import as a meeting. **Confirmed gap: zero chat/Q&A/RAG** — our M8+Companion has no OSS rival |
| Humla (MIT, Tauri+Swift sidecars; optional cloud **$7/month/workspace**) | OSS meetings | Dual-stream capture, pyannote community-1 + Sortformer, engine routing **by language**, per-note override, "notes=intent + transcript=facts", **playback with word-by-word highlighting** (→ D27), free self-hosted PocketBase vs paid cloud — the sync monetization model that D12-L2 can copy |
| Riffado (AGPL) | Plaud companion | AES-256-GCM at rest, signed webhooks, unified backup/restore |

**Structural threats and defense:** (1) platform AI (Zoom AI Companion, Teams Companion, Gemini) — locked into a platform and subscription, no cross-platform library, zero privacy → our single local library is the answer. (2) Apple Sherlocking — Notes already records/transcribes/summarizes on-device and **macOS 26 released `SpeechAnalyzer`/`SpeechTranscriber`, faster than Whisper in public benchmarks**; the OS floor rises every year. Rule: no core feature can be something Apple will obviously make "basic" in 1–2 years. We live above the floor: speaker identity, developer workflow, deep bilingual support, RAG. And we turn the floor into a provider: SpeechAnalyzer is another quality engine in D25 (free, no download).

## Target FREE vs PRO policy (one-time payment ~$69, launch $49)

This is the intended entitlement model, not a claim that every PRO row or
license gate is implemented today. Current implementation status lives in
[ARCHITECTURE.md](ARCHITECTURE.md), [GAPS.md](GAPS.md), and the as-built
[specs/](specs/README.md).

| | FREE (forever) | PRO |
|---|---|---|
| Unlimited local recording/transcription/diarization | ✅ | ✅ |
| Summaries (local models + BYOK) | ✅ | ✅ + advanced Recipes |
| "You vs. others" (mic channel) | ✅ | ✅ |
| Voice enrollment + automatic names | — | ✅ |
| MD/Obsidian/Gist export, FTS search | ✅ | ✅ |
| Bilingual summary with glossary | ✅ basic | ✅ + live "what did I miss?" |
| Per-meeting privacy receipt | ✅ | ✅ |
| Live translated captions | ✅ basic | ✅ continuous |
| Multi-device sync (CloudKit) | — | ✅ |
| RAG chat over history | — | ✅ |
| GitHub/Linear/Jira export, ADRs | — | ✅ |
| Local MCP server | — | ✅ |
| Clips (mark / export) | mark | export |
| Post-meeting automations (Shortcut hook today; native App Intents planned) | — | ✅ |
| Meeting health (talk-time, interruptions) | — | ✅ |
| Watch "you were mentioned" + iPad PiP captions | — | ✅ |

## Target features by platform

The following is the product vision. It intentionally includes planned
capabilities; current and deferred status is authoritative in
[GAPS.md](GAPS.md), [IOS.md](IOS.md), and the as-built specs.

**macOS (primary product):** per-app taps; iPhone as a room mic via Continuity (hybrid meetings: 3 channels); Foundation Models for summaries; menu bar + floating transcript panel; App Intents/Shortcuts + calendar-based auto-recording (EventKit); Core Spotlight; widgets; Focus filters; Handoff; Quick Look; CLI + XPC.

**iOS (in-person recorder + companion):** the 6 D11 modes. Highlights: studio-quality AirPods recording (iOS 26 `bluetoothHighQualityRecording`); Live Activity + Dynamic Island; Siri/App Intents; share extension; E2E CKSyncEngine; remote control of Mac recording; overnight BGProcessingTask; thermal degradation (`ProcessInfo.thermalState`).

**iPadOS:** PiP live captions (AVPictureInPictureController rendering the transcript as video — floating subtitles over Zoom in Stage Manager, composable with translation); PencilKit canvas anchored to the timeline (handwriting → context feed); Split View alongside the meeting app.

**visionOS (halo, late phase):** inexpensive SwiftUI port; immersive review room (spatial timeline); premium in-person recorder. No capture promises (same constraint as iOS).

**Apple Watch:** remote control + haptic "you were mentioned" with the transcribed question.

## Founding use case: ES/EN bilingual

- Simultaneous English transcription + Spanish summary (configurable default flow).
- Technical glossary that preserves English technical terms (`deploy`, `PR`, `rollback`) — never "extraction request".
- Domain vocabulary as initial_prompt (service/teammate names).
- "What did I miss?": a live, Spanish-language catch-up for the last N minutes.
- "Someone asked you something" detector (name mentioned → notification with the question).
- **Live Companion (D26/D91)**: questions detected in the conversation ("what is the difference between `var` and `let`?") → card with a suggested answer in <5 s; `contexto` answers from local RAG, `conocimiento` answers from on-device FM (or BYOK with disclosure). Review separates what triggered the card from the exact passages cited by a context answer.
- Live translated ES↔EN captions (Translation framework, on-device; partials in the original language, translation when each segment is finalized).

## Future (research, not committed)

- **Context feed**: timestamped links/notes/stack traces that enrich the summary.
  The existing Core `ContextItem` and note persistence flow are the foundation;
  a dedicated package boundary is unnecessary until the capability has a
  distinct vertical use case.
- **Synthesized voice**: Apple's Personal Voice (iOS 17+) to speak for the user; requires a virtual audio driver (virtual microphone) on macOS + mandatory disclosure to participants. Phase 4+.

## Standout UX (signature moments)

The moments that make people say "no one else does this" — each maps to a milestone:

1. **The waveform that knows who is speaking** (M9): timeline colored by speaker; drag it and the transcript follows; click a sentence and the audio jumps there with live highlighting.
2. **The Companion card** (M11): someone asks a technical question and the answer is already in your panel before you finish processing the question.
3. **"You were asked"** (M11 + Watch in phase 3): you are distracted, and the watch vibrates with the transcribed question.
4. **Translated captions floating over Zoom** (M14d, iPad PiP): subtitles in your language over any calling app, composable with translation.
5. **Dynamic Island recording** (M14c): timer + latest sentence in the island; long-press = mark moment.
6. **⌘K over your history** (RAG already exists): "what did we agree about the budget?" answers with clickable citations that jump to the audio (M9 connects it).
7. **Automatic Recipe** (M13): the app detects that it was a 1:1 and proposes the correct format without asking.
8. **"Recommended for your Mac"** (M10): the app knows which models run well on your hardware and does not make you choose blindly.
9. **The receipt, not a privacy slogan** (Band 3H): each meeting states whether tracked work stayed local or a remote transfer was attempted, while legacy history shows its honest coverage boundary.
10. **A summary that shows its work** (Band 5B): overview sources are compact timestamps; selecting one focuses the exact supporting transcript line and audio moment without interrupting the user's playback intent.
11. **Correct the claim, preserve the record** (Band 5C): a private correction or unsupported mark stays visibly separate from generated text, can be cleared without hidden text history, and travels only through an explicit meeting export.
12. **A decision you can verify in one click** (Band 5D): each supported decision bullet exposes its exact transcript and audio moments; stale or missing evidence disables navigation instead of presenting false certainty.
13. **A to-do that remembers the commitment** (Band 5E): the source stays attached to the task even after its checkbox changes, so users can verify who committed to what without searching the meeting or trusting generated text blindly.
14. **A Companion answer with two kinds of proof** (Band 5F): the card shows where the question was asked separately from which earlier meeting passages supported its answer; knowledge answers and pings never pretend to have transcript support they did not use.

## Performance targets (world-class = numbers)

| Metric | Target | Measured (Jul 2026) |
|---|---|---|
| Live transcript latency | < 2 s | ✅ p95 0.53 s |
| Post-meeting summary | < 30 s (incremental summarization during the meeting) | ✅ 3.8 s |
| Cold start | < 1.5 s | ✅ 0.94 s cold / ~0.26 s warm (`portavoz-app --bench-startup`, Jul 2026) |
| RAM while recording (Mac, LIVE STT + diarization) | < 800 MB peak while recording · < 200 MB idle post-meeting (target revised Jul 2026: the original 500 MB target was set without live diarization) | ✅ by phase (`--bench-record 60 --bench-log`, via `open -n`): 20 MB without models → ~515 MB engines → **569–795 MB peak while recording** → **140–160 MB after the meeting** (idle release + reclaimable CoreML pages). The embedded MLX summary uses ~2.4 GB transiently and is released only after 120 s (previously it remained resident forever) |
| Battery (iPhone, live STT) | < 10%/hour (ANE) | phase 3 |
| Search through 100k segments | exact p95 < 50 ms; lexical Ask p95 < 100 ms | ✅ exact p95 **30.99 ms**; lexical Ask p95 **66.89 ms**, down from 111.19 ms through bounded per-term candidates and reciprocal-rank fusion (`portavoz-cli bench-scale`, D81) |
| Private Spotlight projection through 100k meetings | wall/CPU p95 < 500 ms | ✅ wall/CPU p95 **425.64/423.58 ms**, down from 22,085.35/22,720.40 ms through one exact snapshot; protected named-index delivery is launch-reconciled and retryable without an outbox (D85) |
| Semantic retrieval through 100k embedded segments | p95 < 100 ms | ✅ wall/CPU p95 **90.22/91.26 ms**, down from 325.41/328.43 ms through streamed zero-copy Accelerate scoring and bounded exact top-k; **8.42 MiB incremental p95** (D83) |
| Waveform generation, 56-minute dual-channel recording | first wall < 150 ms; repeat wall/CPU p95 < 100 ms | ✅ first wall/CPU **109.25/94.81 ms**; repeat p95 **70.11/71.33 ms**, down from 747.53/754.79 ms through stateless Accelerate spans; **0.33 MiB incremental p95**, exact result preserved, no cache lifecycle (D84) |
| Meeting Detail first content, 2 h / 5k segments | < 300 ms | ✅ **91.87 ms**, down from 522.30 ms, with zero measured hangs; `MeetingHealth` p95 is 9.94 ms, down from 347.58 ms (D79/D80) |
| Mic/system drift | < 50 ms in 30 min | ✅ 4 ms over an actual 22 min |
| Diarization DER (4 speakers) | < 15%; user contributions 100% | ✅ AMI 7.6%; real meeting pending corrected RTTM |
| Refine (Whisper batch) | > 15x real time | ✅ 23–42x |

## Security (commitments)

Keychain for secrets; `NSFileProtectionComplete` (iOS) / optional SQLCipher
(macOS); on-device-only, deletable voiceprints; implemented opt-in private
CloudKit meeting-text transport on macOS using encrypted fields/assets, pending
production two-Mac field proof; sha256-pinned models; Hardened Runtime,
notarization, signed releases, and SECURITY.md; local MCP over process stdio
with no network listener; content-free egress receipts persisted before a
redirect-blocked transport; opt-in telemetry; recording disclosure with jurisdiction
presets; pinned SPM dependencies. **Current macOS distribution is intentionally
and accurately not App Sandbox-enabled.** D78's signed sandbox/control matrix
proved containment and several compatible capabilities, but also proved that
the current shared app/CLI/MCP storage layout cannot survive an entitlement
toggle. App Sandbox remains a supported future direction only after reversible
data migration, security-scoped custom folders, Sparkle setup, and signed
capture/automation feature-parity smoke. End-to-end protection for third-party
CloudKit data depends on the user's optional Advanced Data Protection setting;
Portavoz cannot inspect that setting and therefore promises encryption, not
unconditional end-to-end encryption. Until then, Developer ID, Hardened
Runtime, notarization, narrow TCC entitlements, and enforceable egress policy
are the shipping boundary — never a sandbox marketing claim.
