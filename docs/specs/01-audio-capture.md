# Spec 01 — Audio capture (AudioCaptureKit)

Status: implemented and verified in real meetings (Jul 2026). Decisions: D5 (dual-channel), D6 (process taps), D24 (AEC), D27 (audio first-class), D36/D37 (durable reservation and provisional rollback), D38 (validated atomic publication), D40 (evidence-first launch recovery).

## Channel model (D5)

Two SEPARATE streams, never mixed before diarization:

| Channel | Source | Meaning | File |
|---|---|---|---|
| `microphone` | `MicrophoneSource` (AVAudioEngine) | The user's voice — "Me" by hardware ground truth | `Audio/<meeting-uuid>/microphone.caf` |
| `system` | `ProcessTapSource` (Core Audio process taps, macOS 14.4+) | The other participants (audio from other apps) | `Audio/<meeting-uuid>/system.caf` |

`AudioChunk` (PortavozCore): `channel`, mono `samples: [Float]`, `sampleRate`, `timestamp` (seconds since the first callback, through `HostClock` over host time).

## MicrophoneSource — `Sources/AudioCaptureKit/MicrophoneSource.swift`

- **AEC by default (D24)**: `setVoiceProcessingEnabled(true)` on the input node + `voiceProcessingOtherAudioDuckingConfiguration = .min` (without this, AEC attenuates the meeting audio the user hears). Opt-out: `init(voiceProcessing: false)`, UI "Cancelación de eco" (`aecEnabled` in UserDefaults), CLI `record --no-aec`. If the device rejects voice processing, it degrades to raw capture without failing.
- **`warmUp()`**: starts the engine WITHOUT a tap so that AEC's adaptive filter converges while models load. Measured: AEC takes ~2 s to converge (mic/system RMS ratio 0.38 at 0–2 s → 0.03–0.11 afterward); without warm-up the first seconds of captions leak echo.
- **Device-change resilience**: observes `AVAudioEngineConfigurationChange` (connecting headphones SILENTLY STOPS the engine — real bug: a mic died at minute 24 of 30). On change: reinstalls the tap, retries every 0.5 s if there is no usable input, resamples the new device to the stream's original rate (`Resample.linear`, tested), and **fills the gap with silence** so the timeline remains aligned with the system channel (gap = samples expected by clock − delivered; 0.5 s threshold).
- Device selection by UID/name (`--mic` in CLI) through `kAudioOutputUnitProperty_CurrentDevice`; on restart, if the pinned device has disappeared, it falls back to the default. The app preserves the preferred UID, marks it unavailable in Ajustes, and uses the default input only for that recording.
- **Local mute**: `setMuted` replaces every mic-channel buffer with exactly the same number of zero samples. The call is untouched and the dual timeline remains aligned.

## ProcessTapSource — `Sources/AudioCaptureKit/ProcessTapSource.swift`

- `CATapDescription(stereoMixdownOfProcesses:)` receives `[AudioObjectID]` directly (not `[NSNumber]`); PID→object through `kAudioHardwarePropertyTranslatePIDToProcessObject`. No PIDs = global system tap.
- Requires a private aggregate device with `kAudioAggregateDeviceTapListKey` + `kAudioSubTapDriftCompensationKey: true`; the format is read with `kAudioTapPropertyFormat` BEFORE the IOProc.
- **A tap without TCC permission delivers SILENCE, not an error** (0.0 peak in `system.caf` = missing "Grabación de pantalla y audio del sistema" → enable and relaunch). `RecordingSession.Summary.peaks` detects it.
- **OUTPUT-change resilience** (real field bug Jul 2026: switching from Mac speaker → headphones left the system channel MUTED): the tap/aggregate binds to the default output when created and does not follow it automatically. `ProcessTapSource` listens to `kAudioHardwarePropertyDefaultOutputDevice` (listener block on a serial rebuild queue) and **rebuilds the graph** (tap+aggregate+IOProc) on the new output while preserving the SAME stream/continuation; it resamples to the original rate and fills the switching gap with silence (mirrors mic input resilience). It cannot be unit-tested without real Core Audio → field verification pending.
- **App-mode scope**: `captureMode` (`auto`/`app`/`system`) decides between global and direct taps. The direct tap includes the PID of each recognized meeting app and only audio processes whose bundle ID is that app or a dot-delimited child (browser/Zoom/Teams helpers); music and notifications from unrelated apps are excluded. Without a recognized app, an empty list explicitly degrades to the global tap, as explained in Ajustes.
- The first buffer arrives **~2.4 s after** the mic starts (ScreenCaptureKit startup latency) — constant offset, not drift; the drift harness covers it with a ±5 s range.

## RecordingSession — `Sources/AudioCaptureKit/RecordingSession.swift`

Actor that coordinates sources and writers by channel (created lazily with the first chunk, at the source's actual rate). `onChunk` is the seam where live transcription attaches without making the writer wait. A failed channel ends its file and does NOT kill the session (per-channel errors in the Summary). `Summary`: published files, `PublishedCaptureFile` evidence, seconds written, peak/RMS amplitudes, errors, and `driftSeconds`.

Startup is transactional at both levels. Before a source starts,
`RecordingController` atomically inserts a `recording` meeting shell and one
pending `AudioAsset` reservation per selected channel. It then starts
`RecordingSession`, which stops partially started sources on failure; the
controller finishes Parakeet/diarization feeds, cancels their tasks, stops mic
warm-up, and schedules idle engine release. If startup wrote no channel file,
the empty provisional shell is rolled back. If any reserved file exists, the
shell is retained as `needsAttention` for recovery (D37).

Each reservation and writer uses `<channel>.partial.caf`. On stop, all writers
are released, each non-empty mono CAF is reopened for validation, SHA-256 is
streamed in 1 MiB chunks, and actual sample rate/channel count/duration/size,
finite peak/RMS dBFS from successfully written, signed-PCM-clamped samples, and
`healthy`/`silent`/`clipped` health are captured.
`CaptureFilePublisher` refuses cross-directory publication and existing final
paths, then one same-directory rename publishes `<channel>.caf`. Missing
channels stay metadata-free; a staging file that could not publish remains for
recovery.

At process launch, `RecordingRecoveryCoordinator` scans pending assets in both
the configured recordings root and the default fallback. Staging-only CAFs are
reopened, remeasured from persisted PCM, hashed, classified, and published;
final-only CAFs receive the same full validation. File inspection runs off the
main actor because meeting-length hashing and signal measurement must not block
launch. Missing files remain explicit missing evidence. Staging plus final, or
duplicate candidates across roots, is `capture.recovery.ambiguous`: every copy
is preserved and Portavoz neither overwrites nor guesses (D40).

The controller installs `captured`, finalized/missing assets, provisional live
cast/transcript, notes, and Companion cards in one StorageKit Unit of Work
before diarization or summary work, then records `processing` and finally
`ready`. Batch attribution atomically replaces the provisional cast. Audio
with no captions is retained as `needsAttention`; a later required-write
failure does the same. `stop` schedules engine release with `defer`, even when
there was not enough audio to keep.

`CaptureFileWriter`: 16-bit mono PCM through AVAudioFile from Float32, **CAF** container — its data chunk remains sized "to EOF" while being written, so a crash leaves the file readable. **Empirically verified (Jul 2026)**: `kill -9` at 6 s of recording → WAV read 0.00 s / 0 bytes; CAF preserves 5.23 s. Readers continue through `MeetingAudioLayout.channelFile`, which prefers user-compressed `.m4a`, then current `.caf`, then legacy `.wav`; staging files remain invisible. `verify_drift.py` converts CAF with afconvert.

## Verified synchronization (M1)

- **Measured drift: 4 ms over 22 real minutes** (+4 ppm, linear across 5 points; 30 min projection ≈ 7 ms; criterion < 50 ms). Harness: `scripts/verify_drift.py` (RMS envelope correlation, ±5 s range with edge warning — with ±2 s, the actual 2.4 s offset fell outside the range and reported false drift).
- Method requirement: both channels must share real audio (meeting over speakers, or a real call where the mic captures the user).

## Recordings folder

`RecordingsLocation` (StorageKit, spec 05): configurable root with a marker file shared by app/CLI, fallback resolution, and resumable migration.

## Known limitations and risks

1. **⚠️ Taps + VPIO in the same process**: MacParakeet rejected them because they "do not coexist reliably." Our evidence (1 real meeting with both) is insufficient — monitor glitches/dropouts on the system channel with AEC active. Plan B (D27): offline post-recording echo cancellation.
   - **Field finding (Jul 2026): the user's voice sounded DISTANT to others — cause = the Mac's BUILT-IN MICROPHONE (far-field), NOT AEC/Bluetooth.** Measured in the real recording (mic channel, RMS/s): with the Mac mic (min 0–3:55), the user's voice remained **≤ -45 dBFS** (mostly -50 to -60), very quiet/roomy; connecting **AirPods at 3:56** raised it to **-15…-25 dBFS** with a -68 floor (loud and clean). In other words, Bluetooth **fixed** the problem; it did not cause it (corrects a previously inverted hypothesis). Portavoz does not control what the call app (Zoom/Meet) sends to others; its own capture from the built-in mic is also quiet. **Implemented mitigation: live mic level meter** in `RecordingView` (`RecordingController.micLevel`, smoothed per-chunk peak on a dB scale) + "se te oye bajo — acércate o usa audífonos con micrófono" warning when `micLevelLow` (EMA of VOICED chunks below the threshold after ~15 s of speech; it does not confuse silence with a distant voice). (Note: in that same recording, switching output to AirPods triggered the muted-system-channel bug — fixed, see above — and the built-in mic→AirPods change at 3:56 had no interruption: input resilience OK.)
2. ~~Crash safety~~ — **RESOLVED**: CAF container verified against kill -9 (above).
3. **No "room" channel** yet (iPhone as a room mic through Continuity — planned, PRODUCT).
4. PCM = ~126 MB per channel per 22 min (CAF, same bitrate as WAV); **AAC transcode resolved in M11** through `AudioTranscoder` and the "Comprimir audio" action.

## Durable post-capture handoff (D43)

Normal `RecordingController.stop` now hands capture to the process-scoped
executor. A recording-scoped voiceprint read begins while capture is active.
After channel publication, one StorageKit transaction installs finalized or
missing assets, the provisional transcript/cast, notes, Companion cards, and
the exact first diarization job. Stop then navigates immediately and kicks the
worker; relaunch resumes the same owner-leased work after capture recovery.
Job-admission failure cannot expose a half-installed captured snapshot, and the
controller attempts an explicit `needsAttention` snapshot fallback without
deleting audio.

## Planned (not implemented)

Other planned work: room channel; −23 LUFS normalization in the capture
pipeline (today only peak-normalize before Whisper, spec 02).
Playback/waveform/clips, skip silence, AAC transcode, and import are already
implemented in M11 (spec 06 + AudioPlaybackKit).
