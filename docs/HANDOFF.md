# HANDOFF — Estado del proyecto

> Documento de traspaso entre sesiones de trabajo. Actualizar al final de cada sesión significativa.
> Última actualización: 2026-07-06.

## Estado actual

| Hito | Estado |
|---|---|
| **M0 — Scaffold** | ✅ Completo y commiteado (`1b9aa47`). SPM workspace, 9 targets, CI, docs. |
| **M1 — Captura** | ✅ **Funcionalmente completo y verificado por el usuario.** Solo queda el test de aceptación largo (30 min, drift < 50 ms). |

**Sin push al remoto todavía** (`origin = git@github.com:johnny4young/portavoz.git`).

## Qué funciona (verificado en el mundo real, 2026-07-06)

- `swift build` limpio; **11 tests en verde**.
- **Micrófono**: grabación real verificada (48 kHz/16-bit, señal analizada). Selección de dispositivo por nombre/UID (`--mic`), enumeración con `portavoz-cli devices` — detecta incluso el iPhone vía Continuity (futuro canal "room").
- **Process tap (audio del sistema)**: verificado por el usuario con Spotify — `system.wav` captura la música, `microphone.wav` la voz. Canales separados en disco, con peak por canal y drift en ms reportados por el CLI.
- Pipeline completo: fuentes → downmix mono → `AsyncThrowingStream<AudioChunk>` → actor `RecordingSession` (peaks + errores por canal en el `Summary`) → `WAVWriter` (AVAudioFile, sin FFmpeg).

## Próximos pasos inmediatos (en orden)

1. **Test de aceptación M1**: 30 min con audio APERIÓDICO sonando (podcast ideal; música con beat repetitivo puede aliasear la correlación) y verificar con el script:
   ```sh
   swift run portavoz-cli record --seconds 1800 --system --out ~/Desktop
   python3 scripts/verify_drift.py ~/Desktop/microphone.wav ~/Desktop/system.wav
   ```
   El script mide el drift real por correlación cruzada (offset inicio vs offset final; los desfases constantes se cancelan). Validado contra sintéticos con verdad conocida: precisión ~1-3 ms. El número "drift" que imprime el CLI es solo un proxy burdo (diferencia de duraciones, incluye el offset de arranque del tap ~1 s) — la verificación real es el script.
2. **M2 — Transcripción**: añadir FluidAudio como dependencia SPM; `ParakeetEngine: TranscriptionEngine` (streaming); scheduler de slots (vivo vs batch); registry con descarga verificada del modelo Parakeet. Criterio: transcript en vivo < 2 s de latencia con un archivo transcribiendo en batch sin degradarlo.
3. Nota de alcance: la **aplicación de `AudioRetentionPolicy` se difirió a M5** — borrar audio "N días después" requiere registros de reuniones persistidos (StorageKit), que no existen hasta M5. El tipo ya está definido en AudioCaptureKit.

## Quirks del entorno de desarrollo

- **`xcode-select` apunta a CommandLineTools**, que no incluye XCTest ni Swift Testing. Los tests se corren con `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`, o arreglar permanente con `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. (Por esto los tests son XCTest y no Swift Testing.)
- Toolchain: Swift 6.3.3, macOS 26, Apple Silicon.
- El repo de referencia Meetily vive en `../meetily` (Tauri/Rust; estudiar, jamás portar código — ver DECISIONS).

## Descubrimientos técnicos ya pagados (no re-descubrir)

- `CATapDescription(stereoMixdownOfProcesses:)` recibe **`[AudioObjectID]` directo**, no `[NSNumber]` como sugiere la firma ObjC.
- El tap requiere un **aggregate device privado** con `kAudioAggregateDeviceTapListKey` + `kAudioSubTapDriftCompensationKey: true`; el formato del stream se lee del tap con `kAudioTapPropertyFormat` ANTES de crear el IOProc.
- PID → objeto Core Audio: `kAudioHardwarePropertyTranslatePIDToProcessObject` con el PID como qualifier.
- `AVAudioFile` escribe WAV directo desde buffers Float32 con settings `AVLinearPCMBitDepthKey: 16` — no se necesita encoder externo (Meetily usaba un sidecar de FFmpeg para esto).
- Meetily guarda API keys en SQLite plano (tabla `settings`) — el anti-patrón que motivó nuestra regla de Keychain.
- **Un tap sin permiso TCC entrega SILENCIO, no error.** Si `system.wav` existe pero peak = 0.0%, el fix es: Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema → activar la app de terminal → relanzarla. El CLI ya detecta este caso y lo imprime. (Diagnosticado y confirmado en el mundo real el 2026-07-06.)
- La enumeración de inputs (kAudioHardwarePropertyDevices + kAudioDevicePropertyStreamConfiguration) lista también los iPhones vía Continuity — base del futuro canal `room` para reuniones híbridas.

## Cómo continuar en una sesión nueva

1. Abrir la sesión **en esta carpeta** (`cd ~/Personal/github/portavoz && claude`) — así CLAUDE.md carga automáticamente y apunta aquí.
2. Leer este HANDOFF (estado + próximos pasos) y retomar el hito en curso (M1, M2… según ROADMAP).
3. Al cerrar la sesión: actualizar este documento (estado, verificado, próximos pasos, descubrimientos) y añadir a DECISIONS.md cualquier decisión nueva. **Nada importante puede quedar solo en la conversación.**

## Mapa de documentos

- [CLAUDE.md](../CLAUDE.md) — guía operativa mínima para sesiones de Claude Code (apunta aquí).
- [docs/DECISIONS.md](DECISIONS.md) — **registro de todas las decisiones con su porqué** (D1–D14).
- [docs/ARCHITECTURE.md](ARCHITECTURE.md) — diseño técnico: módulos, pipeline de audio, reglas de ingeniería, entorno de desarrollo.
- [docs/PRODUCT.md](PRODUCT.md) — visión, análisis de mercado, modelo FREE/PRO, features por plataforma, targets de performance.
- [docs/ROADMAP.md](ROADMAP.md) — hitos M0–M8 con criterios de aceptación.
