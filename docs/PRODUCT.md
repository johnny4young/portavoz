# PRODUCT — Vision, market, and features

## The promise (one only, for launch)

> **"Record your meeting and know who said what — including you — without requiring your audio or meeting content to leave your Mac."**

Everything else arrives across versions. The project's discipline is not to
dilute this promise before M5. Local processing is the default; explicit remote
providers and publishing are optional, and the per-meeting privacy receipt
makes tracked exceptions visible instead of weakening the promise silently.

## Positioning

Portavoz prioritizes these six attributes for bilingual Apple-platform users;
this is a product direction, not an exhaustive market comparison or proof of
exclusivity. Implemented capabilities and remaining limits are owned by
[ARCHITECTURE.md](ARCHITECTURE.md), [GAPS.md](GAPS.md), and the as-built specs.

1. **Local custody by default** — on-device capture and processing, with explicit
   opt-in boundaries for remote providers and publishing.
2. **Verifiable speaker identity** — structural microphone attribution, reviewed
   speaker labels, and explicitly confirmed people remembered across meetings.
3. **Developer workflows** — source-backed artifacts and reviewed integrations;
   a planned integration must not be advertised as an available control.
4. **ES/EN usability** — bilingual summaries, technical vocabulary, and translated
   captions, with visible model, language, and macOS availability limits.
5. **A planned one-time purchase** — the intended entitlement model below, not
   an assertion about every competitor's billing or a live checkout offer.
6. **Open source** — MIT project code, with separate dependency and model terms.

Founding user and archetype: a Spanish-speaking developer with meetings in English.

## Competitive evidence and design lessons

Primary-source snapshot checked September 5, 2026. Vendor documentation describes
its own product; it is not our hands-on qualification. This deliberately bounded
sample does not establish that a feature has no competitor. Recheck exact plan,
platform, version, and source before publishing a comparison. Old valuations,
price ranges, performance slogans, and unverified feature-absence claims are not
current product evidence.

| Source | What the source supports | Portavoz design inference, not a superiority claim |
|---|---|---|
| [Granola Chat](https://docs.granola.ai/help-center/getting-more-from-your-notes/chatting-with-your-meetings) | Chat can use one meeting, selected meetings, folders, or the library. Basic chat uses the last 30 days; paid plans expose full note history. | Source scope should be visible and controllable. Compare local retrieval quality and citation navigation, not the mere presence of chat. |
| [Granola privacy and data FAQ](https://docs.granola.ai/help-center/consent-security-privacy/security-privacy-data-faqs) | The FAQ describes server storage, sharing and training controls, retention policies, and export of notes, summaries, and transcripts. | Distinguish custody, sharing, training, retention, and export. Cloud processing does not mean an absence of privacy controls; a plan's history-access limit is not proof of deletion or inability to export. |
| [Meetily upstream](https://github.com/Zackriya-Solutions/meetily) | The repository identifies MIT licensing and local Community transcription and summaries. Its PRO list marks meeting chat as forthcoming at this snapshot. | Local open-source competition exists. A README roadmap is not proof about all releases, forks, or the wider market. Evaluate an exact released build before a feature-by-feature comparison. |
| [Apple SpeechAnalyzer introduction](https://developer.apple.com/videos/play/wwdc2025/277/) | Apple describes on-device transcription, language/device availability, and downloading missing model assets through AssetInventory. | Treat OS speech as a capability-gated provider. On-device does not mean that assets are already installed, and a vendor description does not prove superiority to Parakeet or Whisper on our corpus. |

The useful design lessons remain: combine authored notes with source-backed AI
additions, make playback and citations easy to inspect, preserve exportability,
offer task-appropriate templates, and require review before external effects.
These are product hypotheses to validate in complete journeys, not a feature
checklist copied from a competitor. Ideas from incompatible-license projects
may inform independent design; their code is not an eligible dependency.

**Competitive risks:** platform-integrated assistants can reduce setup friction,
cloud tools can offer collaboration, and local open-source tools can offer data
custody. Portavoz should earn its place through reliable capture, source-backed
identity and answers, bilingual usability, and explicit control over data and
actions. None of those differentiators is automatically exclusive. Compare
end-to-end quality, latency, memory, and recovery under the same declared
conditions; do not infer a measured advantage from local execution alone.

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
| Post-meeting automations + native Start/Stop Recording App Intents | — | ✅ |
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
- **Live Apuntador (D26/D91)**: questions detected in the conversation ("what is the difference between `var` and `let`?") → card with a suggested answer in <5 s; `contexto` answers from local RAG, `conocimiento` answers from on-device FM (or BYOK with disclosure). Review separates what triggered the card from the exact passages cited by a context answer.
- Live translated ES↔EN captions (Translation framework, on-device; partials in the original language, translation when each segment is finalized).

## Future (research, not committed)

- **Context feed**: timestamped links/notes/stack traces that enrich the summary.
  The existing Core `ContextItem` and note persistence flow are the foundation;
  a dedicated package boundary is unnecessary until the capability has a
  distinct vertical use case.
- **Synthesized voice**: Apple's Personal Voice (iOS 17+) to speak for the user; requires a virtual audio driver (virtual microphone) on macOS + mandatory disclosure to participants. Phase 4+.

### 1.0.0 candidate boundary

The D379 six-action/six-graph freeze remains Portavoz's safety baseline, not
the final release target. Portavoz presents its six fixed, review-first
post-meeting workflows as
**Suggested actions** / **Acciones sugeridas**. They prepare a recap, text-only
package, local reminder, pre-meeting brief, email draft, or explicitly approved
secret Gist; they are not user-authored plugins or autonomous agents, and none
runs before exact review and confirmation.

The Meeting Memory Graph is an internal disposable relational projection, not a
visual graph. Its baseline product value is six source-backed Ask jobs: current
commitments for one person, active blockers for one commitment, and current
decisions, first confirmed discussion, decision changes, or changes since one
meeting for one topic.

The finite 1.0.0 expansion strengthens Apuntador through reliable streaming and
cancellation, explicit manual Ask, a visible meeting/library/notes/web source policy,
consented cited web research, interview assistance, typed user-authored notes,
and bounded opt-in proactive help. Every answer or suggestion must preserve
exact source provenance, honest unavailable/insufficient states, supported-
macOS degradation, and review-first external effects. A visual graph, implicit
identity guessing, user-authored actions, general-purpose standing automation,
broader graph sync/export/CLI/MCP, alternate search/ASR authority, and autonomous
external mutation remain outside this finite candidate. Current implemented
truth and exit evidence remain authoritative in `GAPS.md` and the as-built
specs. Progressive reliability, selected-engine manual Ask, explicit fail-
closed source policy, consented cited direct-Web pages, pull-based interview
assistance, typed raw-note Ask, and bounded source-closed proactive help are
implemented. The later bounded extension adds a seventh review-first action
for one evidenced GitHub issue and one explicitly created recurring rule for
local pre-meeting briefs, with pause, receipts, recovery, and capture priority.
That rule does not authorize recurring external effects or arbitrary actions.
Portavoz does not provide broad Web search discovery or autonomous
external action; exact 1.0 admission remains open.

## Standout UX (signature moments)

Signature experience targets, not exclusivity claims or a list of completed
features. Each maps to a milestone; current implementation and deferred platform
work remain explicit in the specs and [IOS.md](IOS.md).

1. **The waveform that knows who is speaking** (M9): timeline colored by speaker; drag it and the transcript follows; click a sentence and the audio jumps there with live highlighting.
2. **The Apuntador card** (M11): someone asks a technical question and the answer is already in your panel before you finish processing the question.
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
14. **A Apuntador answer with two kinds of proof** (Band 5F): the card shows where the question was asked separately from which earlier meeting passages supported its answer; knowledge answers and pings never pretend to have transcript support they did not use.

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
| Semantic retrieval through 100k embedded segments | p95 < 100 ms | ✅ D346 clean repeated schema-2 current control on the reference Mac: wall/CPU p95 maxima **73.92/74.50 ms** across three stable canonical observations. The separate three-query-variant diagnostic identity measured **80.37/81.63 ms** but has no budget authority and is not merged with the canonical receipt. Historical D83 remains 90.22/91.26 ms; D345 proves it is not directly comparable because schema 1 lacked complete identity |
| Waveform generation, 56-minute dual-channel recording | first wall < 150 ms; repeat wall/CPU p95 < 100 ms | ✅ first wall/CPU **109.25/94.81 ms**; repeat p95 **70.11/71.33 ms**, down from 747.53/754.79 ms through stateless Accelerate spans; **0.33 MiB incremental p95**, exact result preserved, no cache lifecycle (D84) |
| Meeting Detail first content, 2 h / 5k segments | < 300 ms | ✅ **91.87 ms**, down from 522.30 ms, with zero measured hangs; `MeetingHealth` p95 is 9.94 ms, down from 347.58 ms (D79/D80) |
| Mic/system drift | < 50 ms in 30 min | ✅ 4 ms over an actual 22 min |
| Diarization DER (4 speakers) | < 15%; user contributions 100% | ✅ AMI 7.6%; real meeting pending corrected RTTM |
| Refine (Whisper batch) | > 15x real time | ✅ 23–42x |

The older July measurements remain provenance, while D346 is the newer clean
current-control result on the Tahoe reference host. D347 does not promote
that one host into a market-wide claim: its fail-closed cross-host matrix is
currently **1/3 required memory profiles**, with no Sequoia receipt and no
cross-host authority. `docs/GAPS.md` T5 owns the remaining field evidence and
the separate algorithmic exact-scan limitation.

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

---

# Go-to-market

> Consolidated from the former local `STRATEGY-20260716.md` (deleted 2026-08-06).
> This section is **intent and policy**, not implemented status. Engineering
> sequencing lives in the local `docs/ROADMAP.md`; implemented truth lives in
> [ARCHITECTURE.md](ARCHITECTURE.md), [specs/](specs/README.md), and
> [GAPS.md](GAPS.md).

## Defensible positioning sentence

> Portavoz is the Apple-native meeting memory for people who cannot send every
> conversation to a cloud bot. It records locally, knows who said what,
> preserves English and Spanish as spoken, and lets every decision point back
> to evidence.

## What must exist before a serious paid launch

| Capability | Why it sells | Status |
|---|---|---|
| Reliable recording and crash recovery | The category has zero tolerance for lost meetings | Strength; field proof continues |
| Accurate mixed mic/system audio | Bot-free capture is the differentiator | Exists; device/AEC field matrix open |
| Useful transcript + speaker identity | Core outcome | Exists; real multilingual/speaker benchmarks pending |
| Evidence-linked outcomes | Trust against hallucination | Foundation exists; make proof the default interaction |
| Local intelligence fallback | Value without Apple Intelligence or cloud | Ollama/MLX paths exist; setup should simplify |
| FREE usable forever | Removes adoption friction | Policy in place |
| **Purchase / activate / restore** | Converts value into revenue | **Missing — the one true commercial blocker** |
| Signed updates and release trust | Buyers expect continuity | Release foundation exists |
| Privacy/egress receipt | Makes the promise verifiable | Implemented; productize and expose |
| Export/ownership | Avoids lock-in fear | Exists; improve discoverability |
| Clear compatibility | Prevents refunds and support load | Add matrix and pre-purchase check |

## Pricing policy

The FREE + one-time-PRO model is sound and matches the economics — the customer
supplies the Mac, storage, and local compute. The risk was never the price
concept; it is the missing checkout and license lifecycle.

**FREE — $0.** Unlimited local recording history and minutes; local
transcription, speaker separation/identity, playback, search; basic summaries
with a supported local/BYOK setup; import/export and ownership; no artificial
data lock; community support.

**PRO Personal — $69 one-time** (launch $49 for a clearly bounded window).
Sells: cross-device private text sync; advanced evidence/RAG/Ask and continuity;
Companion and advanced intelligence workflows where supported; recipes,
developer integrations, MCP, GitHub, Shortcuts/App Intents; advanced exports and
automation; priority support; all updates within the purchased major version.
**Never sell "AI minutes" for local processing.**

**PRO Family — validate before publishing.** Candidate $99 one-time for up to
five Macs in one household. Test demand first.

**Business pilot — not self-serve.** High-touch only, after inbound demand:
invoicing/PO support, documented deployment and update controls, a
security/data-flow package, priority onboarding, optional annual maintenance.
Do not promise admin, SSO, retention policy, BAA, legal hold, or audit exports
until implemented and reviewed.

### What "one-time" honestly means

- perpetual use of the purchased major version;
- bug and security fixes for the supported lifecycle;
- optional paid major upgrades, targeted every 18–24 months and only when
  meaningful, with an upgrade discount for existing customers;
- no loss of local data or FREE access if a customer declines an upgrade;
- no retroactive removal of purchased capabilities.

A separate voluntary supporter tier can fund open-source work without changing
the product contract.

### Commerce provider

Keep the provider replaceable — **the application must never depend on provider
SDK types.** Candidates: Lemon Squeezy (license keys with activation limits,
fast to launch), Stripe Managed Payments (merchant-of-record for tax, fraud,
disputes, localized checkout), Polar (open-source friendly). Score them:

| Criterion | Weight |
|---|---:|
| Seller-country eligibility and payout | 20% |
| Merchant-of-record tax/compliance | 20% |
| License API and webhooks | 15% |
| Checkout conversion / local payment methods | 15% |
| Refund/dispute/support workflow | 10% |
| Fees at $49/$69 | 10% |
| Data export/migration | 10% |

### Pricing experiments — sequential, never simultaneous

1. $49 launch vs $69 standard messaging;
2. "Pay once" vs "No subscription" headline;
3. product-led FREE → PRO upgrade moment after proven value;
4. family-pack interest;
5. professional discount for students, journalists, nonprofits, and open-source
   maintainers;
6. refund rate and support cost, not conversion alone.

Primary metrics: visitor→download, download→first recording, activated
user→PRO intent, checkout completion, refund rate, 30-day active use, and
support minutes per sale.

## Website and marketing principles

- Lead with the promise and the proof, not the feature list. Published
  reproducible benchmarks are the credibility asset — keep them current.
- Every claim on the site must map to evidence in the repo. No sandbox claim,
  no unconditional end-to-end-encryption claim, no "field-proven sync" claim
  until the corresponding evidence gates in [GAPS.md](GAPS.md) and
  [RELEASING.md](RELEASING.md) close.
- **Demonstrate local ownership:** show users how to find, back up, export, and
  restore their library. Describe Portavoz's own archive-access policy rather
  than attributing motives or universal restrictions to competitors.
- Start with narrow ideal customers (bilingual developers and consultants with
  English meetings) rather than "everyone who meets".

## What Portavoz must not become

1. **Not a generic AI wrapper.** The moat is capture, evidence, identity,
   continuity, and local policy — not a chat box over a transcript.
2. **Not a cloud service by default.** Cloud features stay explicit, minimal,
   reversible.
3. **Not a surveillance dashboard.** Never score employees, infer emotion, or
   enable hidden recording.
4. **Not feature soup.** New features must strengthen Capture, Understand, or
   Act.
5. **Not an enterprise roadmap before product-market fit.**
6. **Not a meeting bot.** Joining calls as a participant destroys the
   differentiation.
7. **Not "AI said so."** Generated decisions without evidence are suggestions.
8. **Not a false compliance product.** Local processing reduces exposure; it
   does not make a customer compliant with recording, professional, privacy,
   employment, or health law.
9. **Not cross-platform at the expense of Apple quality.**
10. **Not an Electron rewrite.**
11. **Not a lifetime-support trap.** One-time purchase still defines version,
    support, and paid-upgrade boundaries.
12. **Not an opaque privacy slogan.** Optional egress is disclosed exactly.
13. **Not autonomous without review.** External messages, tasks, tickets, and
    exports require confirmation.
14. **Not a replacement for human consent.** Help users record consent and
    understand local rules; never promise universal legality.
