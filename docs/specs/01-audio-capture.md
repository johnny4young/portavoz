# Spec 01 — Captura de audio (AudioCaptureKit)

Estado: implementado y verificado en reuniones reales (jul 2026). Decisiones: D5 (dual-canal), D6 (process taps), D24 (AEC), D27 (audio first-class).

## Modelo de canales (D5)

Dos streams SEPARADOS, jamás mezclados antes de diarizar:

| Canal | Fuente | Significado | Archivo |
|---|---|---|---|
| `microphone` | `MicrophoneSource` (AVAudioEngine) | La voz del usuario — "Me" por verdad de hardware | `Audio/<meeting-uuid>/microphone.caf` |
| `system` | `ProcessTapSource` (Core Audio process taps, macOS 14.4+) | Los demás participantes (audio de otras apps) | `Audio/<meeting-uuid>/system.caf` |

`AudioChunk` (PortavozCore): `channel`, `samples: [Float]` mono, `sampleRate`, `timestamp` (segundos desde el primer callback, vía `HostClock` sobre host time).

## MicrophoneSource — `Sources/AudioCaptureKit/MicrophoneSource.swift`

- **AEC por defecto (D24)**: `setVoiceProcessingEnabled(true)` en el input node + `voiceProcessingOtherAudioDuckingConfiguration = .min` (sin esto, la AEC atenúa el audio de la reunión que el usuario escucha). Opt-out: `init(voiceProcessing: false)`, UI "Cancelación de eco" (`aecEnabled` en UserDefaults), CLI `record --no-aec`. Si el dispositivo rechaza voice processing, degrada a captura cruda sin fallar.
- **`warmUp()`**: arranca el engine SIN tap para que el filtro adaptativo de la AEC converja mientras cargan los modelos. Medido: la AEC tarda ~2 s en converger (ratio RMS mic/system 0.38 en 0–2 s → 0.03–0.11 después); sin warm-up los primeros segundos de captions filtran eco.
- **Resiliencia a cambio de dispositivo**: observa `AVAudioEngineConfigurationChange` (conectar audífonos DETIENE el engine en silencio — bug real: un mic murió al minuto 24 de 30). Al cambiar: reinstala el tap, reintenta cada 0.5 s si no hay input utilizable, resamplea el dispositivo nuevo al rate original del stream (`Resample.linear`, testeado) y **rellena el hueco con silencio** para que la timeline siga alineada con el canal system (gap = muestras esperadas por reloj − entregadas; umbral 0.5 s).
- Selección de dispositivo por UID/nombre (`--mic` en CLI) vía `kAudioOutputUnitProperty_CurrentDevice`; en restart, si el dispositivo pinneado desapareció cae al default.

## ProcessTapSource — `Sources/AudioCaptureKit/ProcessTapSource.swift`

- `CATapDescription(stereoMixdownOfProcesses:)` recibe `[AudioObjectID]` directo (no `[NSNumber]`); PID→objeto vía `kAudioHardwarePropertyTranslatePIDToProcessObject`. Sin PIDs = tap global del sistema.
- Requiere aggregate device privado con `kAudioAggregateDeviceTapListKey` + `kAudioSubTapDriftCompensationKey: true`; el formato se lee con `kAudioTapPropertyFormat` ANTES del IOProc.
- **Un tap sin permiso TCC entrega SILENCIO, no error** (peak 0.0 en `system.caf` = falta "Grabación de pantalla y audio del sistema" → activar y relanzar). `RecordingSession.Summary.peaks` lo detecta.
- **Resiliencia a cambio de OUTPUT** (bug real de campo jul 2026: al pasar de altavoz Mac → audífonos el canal system quedó MUDO): el tap/aggregate se ata al output por defecto al crearse y no lo sigue solo. `ProcessTapSource` escucha `kAudioHardwarePropertyDefaultOutputDevice` (listener block en cola de rebuild serial) y **reconstruye el grafo** (tap+aggregate+IOProc) en el nuevo output manteniendo el MISMO stream/continuation; resamplea al rate original y rellena el hueco de la conmutación con silencio (espeja la resiliencia de input del mic). No es unit-testeable sin Core Audio real → verificación de campo pendiente.
- El primer buffer llega **~2.4 s después** de que arranca el mic (latencia de arranque de ScreenCaptureKit) — offset constante, no drift; el harness de drift lo cubre con rango ±5 s.

## RecordingSession — `Sources/AudioCaptureKit/RecordingSession.swift`

Actor que coordina fuentes y writers por canal (creados lazy con el primer chunk, al rate real de la fuente). `onChunk` es la costura donde cuelga la transcripción viva sin que el writer espere. Un canal caído termina su archivo y NO mata la sesión (errores por canal en el Summary). `Summary`: files, secondsWritten, peaks, errors, `driftSeconds`.

`CaptureFileWriter`: PCM 16-bit mono vía AVAudioFile desde Float32, contenedor **CAF** — su data chunk queda dimensionado "hasta EOF" mientras se escribe, así que un crash deja el archivo legible. **Verificado empíricamente (jul 2026)**: `kill -9` a los 6 s de grabación → WAV leía 0.00 s / 0 bytes; CAF conserva 5.23 s. Lectores de reuniones viejas (.wav) siguen funcionando vía `MeetingAudioLayout.channelFile` (prefiere .caf, cae a .wav). `verify_drift.py` convierte CAF con afconvert.

## Sincronía verificada (M1)

- **Drift medido: 4 ms en 22 min reales** (+4 ppm, lineal en 5 puntos; proyección 30 min ≈ 7 ms; criterio < 50 ms). Harness: `scripts/verify_drift.py` (correlación de envolventes RMS, rango ±5 s con warning de borde — con ±2 s el offset real de 2.4 s quedaba fuera y reportaba drift falso).
- Requisito del método: los dos canales deben compartir audio real (reunión por parlantes, o llamada real donde el mic capta al usuario).

## Carpeta de grabaciones

`RecordingsLocation` (StorageKit, spec 05): raíz configurable con marker file compartido app/CLI, resolución con fallback y migración resumable.

## Límites conocidos y riesgos

1. **⚠️ Taps + VPIO en el mismo proceso**: MacParakeet los descartó por "no coexistir confiablemente". Nuestra evidencia (1 reunión real con ambos) es insuficiente — vigilar glitches/dropouts del canal system con AEC activa. Plan B (D27): cancelación de eco offline post-grabación.
2. ~~Crash-safety~~ — **RESUELTO**: contenedor CAF verificado contra kill -9 (arriba).
3. **Sin canal "room"** todavía (iPhone como mic de sala vía Continuity — planeado, PRODUCT).
4. PCM = ~126 MB por canal por 22 min (CAF, mismo bitrate que WAV); **transcode AAC resuelto en M11** mediante `AudioTranscoder` y la acción "Comprimir audio".

## Planeado (no implementado)

Canal room; normalización −23 LUFS del pipeline de captura (hoy solo peak-normalize antes de Whisper, spec 02). Playback/waveform/clips, skip-silencio, transcode AAC e import ya están implementados en M11 (spec 06 + AudioPlaybackKit).
