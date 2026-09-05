# iOS/iPadOS — technical implementation plan (phase 3, M14)

Complements D11 (strategy), current architecture, and the field gates in
`GAPS.md`. This document exists so that the deferred iOS phase starts with zero
wishful thinking: **what is technically feasible on iOS, with which APIs, and
what resource budget each component has**.

## The truth about capture (why iOS ≠ Mac)

| Capability | macOS | iOS | API/reason |
|---|---|---|---|
| System audio (other apps) | ✅ process taps | ❌ impossible | Sandbox; there is no equivalent to `CATapDescription` |
| Recording third-party calls (Zoom/Meet/Teams) | ✅ via tap | ❌ impossible | No public API; iOS 18.1+ call recording is exclusive to the Phone app |
| Mic in background | ✅ | ✅ with `UIBackgroundModes: audio` | Legitimate continuous recording; orange indicator always visible |
| Screen broadcast | n/a | ⚠️ ReplayKit `RPBroadcastSampleHandler` | Audio only FROM APPS THAT ALLOW IT, 50 MB RAM limit in the extension, a Zoom call does NOT provide its audio — useful as an experimental importer, never as a promise |

D11 conclusion (unchanged): the iPhone is an **in-person recorder + companion**. Everything else is product honesty.

## What compiles today and what still requires a real app (M14a)

`Package.swift` declares `.iOS(.v17)`, and D438 now makes that declaration a
real compiler contract rather than documentation. `scripts/check-ios-portability.sh`
resolves the installed iPhone Simulator SDK and sequentially cross-builds the
following targets for `arm64-apple-ios17.0-simulator` in one scratch graph:

- **PortavozCore**: verified. It includes the portable meeting/evidence values,
  deterministic commitment replica merge, and deferred-Mac-work contract.
- **StorageKit**: verified. Its default SQLite URL uses the platform Application
  Support container rather than a macOS home-directory fallback.
- **ApplicationKit**: verified with its full dependency graph, including
  ModelStoreKit, TranscriptionKit, DiarizationKit, IntelligenceKit,
  AudioPlaybackKit, and StorageKit. Foundation Models providers and generated
  response types declare both macOS 26 and iOS 26 availability; module presence
  alone is not treated as a deployment-version guard.
- **IntegrationsKit**: verified, including the transport-neutral sync codec and
  CKSyncEngine types. The current `SecTask` signed-entitlement probe is
  deliberately macOS-only; iOS returns capability unavailable until a real
  signed iOS app adapter exists. A compiler pass is not CloudKit runtime proof.

The default model, database, and voiceprint roots now all use
`URL.applicationSupportDirectory`, which preserves the released macOS paths and
maps an eventual iOS app into its own container. This says nothing about model
runtime quality, memory, thermal cost, background execution, Keychain access,
or signed-container behavior.

Still outside the compiler ratchet:

- **AudioCaptureKit mobile composition**: `ProcessTapSource` remains macOS-only.
  `MicrophoneSource` needs an iOS `AVAudioSession` owner with explicit category,
  mode, route, interruption, media-services-reset, background-expiry, and
  Bluetooth policy. Live captions must degrade before durable audio capture.
- **Mobile model admission**: Parakeet, compact Whisper/SpeechAnalyzer, and
  diarization must pass installed-asset latency, memory, energy, thermal,
  cancellation, and relaunch measurements on supported physical devices.
  The 1.6 GB desktop Whisper model is not a default iPhone plan.
- **Executable composition**: there is no iOS app target, scene, entitlement,
  provisioning profile, push registration, microphone runtime, UI test host,
  or App Store artifact yet. The iOS app requires an Xcode project while SPM
  remains the sole source of the Kits.

## Budgets by device (to be validated in M14a with mobile `bench`)

| Device | Live STT | Local refine | Summary LLM |
|---|---|---|---|
| iPhone 12–14 (4–6 GB) | Parakeet int8 ✅ | whisper-small or defer to Mac | FM if iOS 26+AI; otherwise, defer/BYOK |
| iPhone 15 Pro+ (8 GB) | Parakeet int8 ✅ | SpeechAnalyzer ✅ | On-device FM ✅ |
| M-series iPad | = Mac (without taps) | Whisper turbo viable | FM ✅ |

Rules: live STT degrades BEFORE dropping the recording (saving WAV is always inexpensive); `ProcessInfo.thermalState` ≥ `.serious` → disable live captions, continue recording; battery < 20% → offer "record only".

## Sync (M14c): CKSyncEngine, no proprietary server

**As built after Band 6C2 (D92–D97):** schema v14 has a content-free per-meeting
mutation journal with monotonic local/acknowledged generations, explicit
initial seeding, and deletion state that survives physical purge. Portable
meeting roots and typed evidence update it in their own transaction;
device-local paths, embeddings, generation links, canonical people, jobs,
receipts, audio, model state, keys, and voiceprints do not. Acknowledging an
in-flight generation cannot hide a newer edit. StorageKit can now join only
the current pending generation to a complete text-first aggregate containing
the cast, bilingual transcript, every summary/action/evidence version, notes,
and Apuntador cards/evidence. IntegrationsKit deterministically encodes that
envelope; StorageKit validates and atomically replays it while preserving
matching device-local derivations, deferring live remote work behind unsent
local work, making remote deletion privacy-dominant, and suppressing accepted
remote echo. IntegrationsKit now maps that envelope to one deterministic
private-zone `MeetingReplica`: small payloads and their digest use encrypted
values; large payloads use a private owner-only `0600` CKAsset staging file
whose content CloudKit encrypts by default; matching records preserve system
fields; deletion saves a tombstone. A separate private owner-only `0600`
IntegrationsKit store now persists content-free account-scoped consent/seed,
opaque CKSyncEngine serialization, record system fields, exact attempts,
bounded retries, replay cursors, and remote deferrals. Each actual destination
independently probes complete protection and backup exclusion with empty,
content-free files before publication. When the destination supports a metadata
capability, the writer applies and verifies it; only `EINVAL` or `ENOTSUP` may
omit that specific capability, and every other error fails closed. Exact
envelope and transport-state bytes use validated, durable, same-directory
atomic `0600` publication (D116). Account loss pauses work and a real switch
clears old account-scoped metadata; callbacks pass through a thin injected
delegate to StorageKit's replay authority. A platform-neutral lifecycle owns
zero-platform local-only launch, explicit enable/seed/retry/pause/remove-device,
account transitions, and truthful content-free status. macOS now composes that
boundary through one inert signed-capability/account-gated private-container
actor and one process-scoped serialized owner for journal, account, retry, and
silent-push wakeups. Its bilingual Settings pane keeps future-change enablement
and existing-library upload separate. Production packaging requires an
unexpired Developer ID profile whose exact CloudKit/container/environment/push
values match the signed app, while local/XCUITest builds remain no-cloud. There
is still **no audio sync or iOS app target**; production two-Mac convergence is
a field gate, not a unit-test claim.

**Planned execution:**

- **6B1 complete — portable content/replay:** exact-generation aggregate,
  deterministic bytes, atomic validation/replay, local-derivation preservation,
  live/live deferral, deletion priority, and immutable identity fences (D93).
- **6B2A complete — dormant record codec:** IntegrationsKit owns encrypted
  inline CKRecord values, an encrypted-by-default CKAsset fallback for
  oversized meetings, capability-probed owner-only staging, strict validation,
  existing-record reuse, and saved deletion tombstones without creating a
  runtime (D94/D116).
- **6B2B complete — durable dormant transport:** private owner-only account/consent/seed,
  opaque engine/system-field, exact attempt, retry, cursor, and deferred-replay
  state survives restart through capability-probed durable atomic publication.
  Partial failures stay independent, account switches reset old account
  metadata, and a thin injected delegate forwards callbacks without app runtime
  composition (D95/D116).
- **6C1 complete — shared lifecycle policy:** account/driver protocols, six
  truthful phases, and explicit enable/seed/retry/pause/remove-device semantics
  are independent of SwiftUI and CloudKit composition (D96).
- **6C2 complete — macOS consent/status/runtime:** the inert container/engine
  owner admits only exact signed capability evidence after account-scoped
  opt-in; one process model owns content-free wakes; six truthful phases and
  explicit enable/manual sync/retry/seed/pause/remove actions are bilingual
  (D97).
- **Shared readiness complete (D438):** the four shared targets cross-build for
  iOS 17; compatible commitment histories have a deterministic replica merge;
  and future refine/diarization/summary handoff has a versioned content-free
  request plus one-owner lease/CAS state machine. None is composed into an iOS
  app, meeting CloudKit replica, worker, or UI yet.
- **Next — read-only continuity shell:** add the signed Xcode target and first
  prove account-scoped text-only meeting reads, explicit sync status, offline
  cache, relaunch, conflict disclosure, and correction/commitment review over
  public bilingual seed data. Do not start capture in the first slice.
- **Then — in-person microphone capture:** add the `AVAudioSession` owner and
  durable mic-first recording lifecycle without importing macOS call-capture
  assumptions. Validate interruption, route change, media-services reset,
  background expiry, low disk, memory pressure, battery, and thermal behavior
  before enabling local live models by device tier.
- **Then — notes/review/corrections/commitments:** reuse exact typed local truth
  and evidence navigation before introducing mobile generation. Voice
  enrollment remains device-local.
- **Then — explicit heavy-work handoff:** persist and transport D438's
  content-free request/snapshot only after text sync is field-proven. A Mac
  claims one expiring opaque lease, and result publication rechecks the exact
  source revision and fingerprint. Audio transfer, if ever added, needs a
  separate per-meeting consent/size/deletion/retry contract.
- **Encryption:** use encrypted record values for content fields. Do not claim
  end-to-end guarantees beyond the user's actual iCloud/Advanced Data
  Protection configuration.
- **Conflicts:** 6B1 rejects immutable identity rewrites, defers a live
  remote aggregate behind unsent local work, and lets remote deletion win that
  race without purging. 6B2 durably stages deferred fetches, classifies
  server-record conflicts, protects newer generations from late callbacks, and
  treats physical CKRecord deletion as metadata-only. Broad field-level
  last-writer-wins is not the contract. D438's commitment merge performs
  canonical append-only union only when shared identities are immutable and the
  combined lifecycle replays; otherwise it returns an explicit conflict. The
  current meeting replica still excludes commitment envelopes.
- **Audio:** never part of initial sync. A later per-meeting CKAsset opt-in has
  its own size, retry, deletion, and consent contract.
- **Voiceprint, canonical person links, secrets, and keys: never** (D8/D21/D92–D97).
- **Later Apuntador control:** an ephemeral CloudKit command record may control
  Mac recording only after private data sync is field-proven; it is not part of
  6B and requires explicit device trust and replay protection.

## Frozen heavy-work handoff contract (D438)

The implemented Core contract is deliberately smaller than a transport:

- operations are closed to `refine`, `diarization`, and `summary`;
- the stable idempotency key covers meeting, kind, transcript revision, and one
  lowercase SHA-256 input fingerprint, so different mobile request UUIDs for
  the same exact material converge without copying content;
- snapshots are format-versioned and compare-and-swap revisioned;
- one opaque Mac/device UUID and lease token own an attempt, renewal is capped
  to 15 minutes at a time, expired work may be reclaimed, and attempts stop at
  three;
- claim/start/renew/succeed/fail/cancel/supersede replays are exact and
  idempotent, while stale revisions, owners, leases, source revisions, or input
  fingerprints fail closed;
- snapshots retain only content-free result fingerprints and bounded typed
  failure codes. They have no audio, transcript, path, prompt, provider, model,
  credential, or generated-result field.

The contract has unit and strict-codec coverage but no persistence adapter,
CloudKit record, scheduler, Mac worker, iOS requester, or user-visible status.
Those are later implementation work, not hidden completion.

## Autonomous validation matrix for the mobile phase

Routine validation must not require private meetings or repeated user labor.
Every future slice starts from public/synthetic bilingual fixtures and a
deterministic seed mode, then adds physical evidence only where simulation
cannot establish truth.

| Boundary | Autonomous/repeatable gate | Irreducible field gate |
|---|---|---|
| Text continuity | EN/ES meetings, notes, corrections, commitments, conflicts, tombstones, offline/relaunch, corruption, and stale-generation fixtures with ground truth | Two physical devices/accounts only when account or push behavior is under test |
| Full UI journeys | Real-app iOS XCUITest over an atomic seed snapshot for first launch, read-only continuity, offline recovery, review/correction, and explicit handoff status | VoiceOver/Voice Control exploratory qualification on each supported physical OS |
| Capture | Deterministic injected audio, interruption/route/reset/background-expiry state tests, long synthetic recording, low-disk and cancellation faults | Real microphone/TCC, incoming-call interruption, Bluetooth/AirPods routes, lock screen, background time, and hardware media-services reset |
| Models | Installed-asset lanes over public bilingual audio/transcript ground truth, with content-free latency/quality/memory receipts and no transcript logs | Device-specific ANE/GPU/thermal/energy behavior and Apple Intelligence availability |
| Handoff | Duplicate request/claim, lease expiry, retry cap, cancellation, supersession, stale-result, offline, slow sync, relaunch, corruption, and two-Mac contention fixtures | Signed production CloudKit, real push/account transitions, and actual two-device convergence |
| Resource safety | Performance, allocations, memory warnings, stress, structured-cancellation, and no-crash loops with numeric budgets | Battery drain, thermal throttling, background survival, and Instruments leak review on supported hardware |

Release admission remains strict: simulator/package/XCUITest evidence cannot
certify permissions, interactive AI setup, external accounts, notarization/App
Store distribution, physical Sequoia/Tahoe companions, VoiceOver/Voice Control,
or 30-day no-loss field evidence.

## iPad and Watch feasibility, not promises

- **iPad captions overlay:** first prototype only with
  `AVPictureInPictureController.ContentSource` and an
  `AVSampleBufferDisplayLayer`-backed caption renderer over Portavoz-owned
  in-person capture. It must prove App Review compatibility, legibility,
  bounded frame/memory use, background behavior, and no implication that iPad
  can capture another app's call audio. A floating Zoom-overlay claim is not
  admitted by a local prototype.
- **Watch “you were asked”:** treat the alert as a content-minimized
  notification/WatchConnectivity delivery problem after phone-side directed-
  question evidence exists. Do not promise arbitrary background execution or
  rely on `WKInterfaceDevice.play` as a background wake mechanism. Validate
  duplicate delivery, stale meeting/question rejection, privacy on the wrist,
  offline queueing, battery, haptic usefulness, and paired-device relaunch.

## Live Activity + Dynamic Island (M14c)

- ActivityKit: timer + latest coalesced caption (the coalescer already provides the stable line) + stop button. Update budget: ActivityKit limits frequency → update per FINALIZED SENTENCE, not per delta (once again, the coalescer pays off).
- Long-press/button = "mark moment" (timestamp → candidate clip in M9).

## What we will NOT do on iOS (anti-promises)

- Record calls from other apps (impossible).
- Whisper large on iPhone (unrealistic RAM/thermal budget).
- Proprietary sync with our own backend before L2 (D12).
- Synchronized voiceprint (biometrics remain where they were created).
