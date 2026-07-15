# iOS/iPadOS — technical implementation plan (phase 3, M14)

Complements D11 (strategy) and the ROADMAP (M14a–d). This document exists so that phase 3 starts with zero wishful thinking: **what is technically feasible on iOS, with which APIs, and what resource budget each component has**.

## The truth about capture (why iOS ≠ Mac)

| Capability | macOS | iOS | API/reason |
|---|---|---|---|
| System audio (other apps) | ✅ process taps | ❌ impossible | Sandbox; there is no equivalent to `CATapDescription` |
| Recording third-party calls (Zoom/Meet/Teams) | ✅ via tap | ❌ impossible | No public API; iOS 18.1+ call recording is exclusive to the Phone app |
| Mic in background | ✅ | ✅ with `UIBackgroundModes: audio` | Legitimate continuous recording; orange indicator always visible |
| Screen broadcast | n/a | ⚠️ ReplayKit `RPBroadcastSampleHandler` | Audio only FROM APPS THAT ALLOW IT, 50 MB RAM limit in the extension, a Zoom call does NOT provide its audio — useful as an experimental importer, never as a promise |

D11 conclusion (unchanged): the iPhone is an **in-person recorder + companion**. Everything else is product honesty.

## What builds today and what must be changed (M14a)

- `Package.swift` already declares `.iOS(.v17)`. Audit by Kit:
  - **PortavozCore, StorageKit, IntelligenceKit, IntegrationsKit, ContextFeedKit**: portable as-is (GRDB, FM, and NLContextualEmbedding exist on iOS; FM requires iOS 26).
  - **AudioCaptureKit**: `ProcessTapSource` is macOS-only (already behind `#if os(macOS)`); `MicrophoneSource` needs an iOS branch: `AVAudioSession` (category `.playAndRecord`, mode `.measurement` or `.voiceChat` for AEC — on iOS, voice processing comes from the session mode), interruptions (incoming call → pause + silence gap, the same machinery used for macOS device changes applies), Bluetooth path: `AVAudioSession.CategoryOptions.bluetoothHighQualityRecording` **verified (iOS 26)** with caveats — works only with the session's default mode (does it conflict with AEC mode? validate), adds input latency (not for live captions with AirPods), requires compatible AirPods (checkable at runtime), and **is not supported in the EU** — always pair it with `allowBluetoothHFP` as a fallback.
  - **TranscriptionKit**: Parakeet TDT v3 int8 (~483 MB) runs on the ANE in iPhone 12+ (FluidAudio supports iOS). **Whisper large-v3-turbo fp16 (1.6 GB) does NOT reasonably fit on iPhone** → verified options: argmax's quantized `large-v3-v20240930_626MB` (recommended for multilingual use), `SpeechAnalyzer` (iOS 26, free, es_MX/es_US supported, whisper-base/small-class quality — sufficient for mobile), or defer to the Mac via sync ("refine where there are watts").
  - **DiarizationKit**: pyannote+WeSpeaker (~14 MB) runs on iOS without difficulty. The voiceprint is NEVER synced (D8): it is re-enrolled per device.
- **The iOS app requires an Xcode project** (end of the D20-SPM-only era): iOS app target + extensions (share, experimental broadcast, widgets/Live Activity). The SPM package remains the sole source of the Kits.

## Budgets by device (to be validated in M14a with mobile `bench`)

| Device | Live STT | Local refine | Summary LLM |
|---|---|---|---|
| iPhone 12–14 (4–6 GB) | Parakeet int8 ✅ | whisper-small or defer to Mac | FM if iOS 26+AI; otherwise, defer/BYOK |
| iPhone 15 Pro+ (8 GB) | Parakeet int8 ✅ | SpeechAnalyzer ✅ | On-device FM ✅ |
| M-series iPad | = Mac (without taps) | Whisper turbo viable | FM ✅ |

Rules: live STT degrades BEFORE dropping the recording (saving WAV is always inexpensive); `ProcessInfo.thermalState` ≥ `.serious` → disable live captions, continue recording; battery < 20% → offer "record only".

## Sync (M14c): CKSyncEngine, no proprietary server

- **What it syncs**: meetings/speakers/segments/summaries (the D4 schema is already sync-ready: UUIDs, tombstones, `updatedAt`). Audio is NOT synced by default (large); opt-in per meeting with a CKAsset asset.
- **Encryption**: `encryptedValues` for all content fields; with the user's Advanced Data Protection, true E2E.
- **Conflicts**: last-writer-wins per field using `updatedAt` (summaries are immutable snapshots — never a conflict); tombstones always win.
- **Voiceprint and keys: never** (D8/D21).
- Companion: remote control of Mac recording via CloudKit push (ephemeral "command" record) — zero proprietary infrastructure.

## Live Activity + Dynamic Island (M14c)

- ActivityKit: timer + latest coalesced caption (the coalescer already provides the stable line) + stop button. Update budget: ActivityKit limits frequency → update per FINALIZED SENTENCE, not per delta (once again, the coalescer pays off).
- Long-press/button = "mark moment" (timestamp → candidate clip in M9).

## What we will NOT do on iOS (anti-promises)

- Record calls from other apps (impossible).
- Whisper large on iPhone (unrealistic RAM/thermal budget).
- Proprietary sync with our own backend before L2 (D12).
- Synchronized voiceprint (biometrics remain where they were created).
