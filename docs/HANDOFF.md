# HANDOFF — Estado del proyecto

> Documento de traspaso entre sesiones de trabajo. Actualizar al final de cada sesión significativa.
> Última actualización: 2026-07-06 (sesión M2).

## Estado actual

| Hito | Estado |
|---|---|
| **M0 — Scaffold** | ✅ Completo (`1b9aa47`). SPM workspace, 9 targets, CI, docs. |
| **M1 — Captura** | ✅ Funcionalmente completo y verificado. Pendiente solo el test de aceptación largo (30 min, drift < 50 ms con `scripts/verify_drift.py`). |
| **M2 — Transcripción** | ✅ **Completo y verificado con el criterio de aceptación en verde** (ver abajo). |

**Sin push al remoto todavía** (`origin = git@github.com:johnny4young/portavoz.git`).

## M2 — qué se construyó (verificado en el mundo real, 2026-07-06)

- **FluidAudio 0.15.x** (Apache-2.0) como dependencia SPM, pineado `upToNextMinor(from: "0.15.4")` — su API pública renombra tipos entre minors.
- **Registry multi-artefacto** (`ModelRegistry.swift`): `ModelDescriptor` ahora lista N `ModelArtifact` (path relativo + sha256 + tamaño), con `resolveBase` pineado a commit exacto de HF. Catálogo: Parakeet TDT 0.6B v3 = 21 artefactos, 483 MB (solo el subset int8 que FluidAudio carga, no los 3 GB del repo).
- **`ModelStore`** (actor): descarga por artefacto → verifica tamaño + sha256 (CryptoKit streaming, 1 MiB) → move atómico. `verify()` re-hashea todo; `ensureAvailable()` sana lo que falte/corrupto. Testeado offline con `file://` URLs, incluido rechazo de tampering.
- **`ParakeetEngine`**: vivo = `SlidingWindowAsrManager` con ventana custom (left 11 s / chunk 1.0 s / right 0.4 s); batch = `AsrManager` long-form disk-backed con `parallelChunkConcurrency: 1` (cortesía hacia el slot vivo) y `melChunkContext: false` (recomendado para v3 multilingüe). Los updates vivos pasan por `ParakeetSegmentMapper` que **corta el overlap re-decodificado** usando los timings absolutos (ver descubrimientos).
- **`TranscriptionScheduler`** (D7): lane vivo inmediato; slot batch serial FIFO en `Task.detached(priority: .utility)`.
- **CLI**: `models download|verify|path`, `transcribe --file`, `record --transcribe [--language]`, `bench-m2` (harness de aceptación). `RecordingSession.start` ganó un `onChunk` tap para colgar transcripción viva de la grabación.

### Resultado de aceptación M2 (M4 Max, 2026-07-06)

`bench-m2 --batch-file <4 min wav> --seconds 40` con voz por parlantes al mic:
- **Vivo: transcript lag p50 0.24 s · p95 0.53 s · max 0.56 s** (criterio < 2 s) ✓
- Diagnóstico palabra-más-vieja (incluye el span de audio del delta): p95 1.45 s.
- **Batch: 18 pasadas a ~100x tiempo real, sin degradar lo vivo** ✓
- 29 tests en verde (26 unit + integración con modelo real gated por `PORTAVOZ_MODEL_TESTS=1` + `PORTAVOZ_TEST_WAV`).

## Próximos pasos (en orden)

1. **Test de aceptación M1 pendiente**: 30 min con audio APERIÓDICO (podcast) → `scripts/verify_drift.py` (drift real por correlación; el "drift" del CLI es proxy burdo).
2. **M3 — Diarización**: pyannote community-1 vía FluidAudio (`DiarizerManager`) sobre el canal system; "Me" estructural por canal mic; DER < 15% en reunión de 4. La misma FluidAudio ya trae los modelos de diarización — reusar `ModelStore` (añadir descriptor pineado al catálogo).
3. Calidad de captions vivo (opcional, no bloquea M3): los deltas cortan subwords en las costuras de ventana ("ally, on your device"). Opciones: merge de subwords al borde, o esperar el re-pase final (Whisper, M4/M5) que es quien produce el transcript de calidad.
4. `AudioRetentionPolicy` sigue diferida a M5 (necesita StorageKit).

## Quirks del entorno de desarrollo

- **`xcode-select` apunta a CommandLineTools** → tests con `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (o arreglar con `sudo xcode-select -s …`). Por esto la suite es XCTest.
- Toolchain: Swift 6.3.3, macOS 26, Apple Silicon (M4 Max, 36 GB).
- Modelos instalados en `~/Library/Application Support/Portavoz/Models/` (override con `--models-dir`).
- El repo de referencia Meetily vive en `../meetily` (estudiar, jamás portar — GPL en MacParakeet también: mirar sin tocar).
- El Python de python.org no tiene certificados SSL (`urllib` falla) — usar `curl` en scripts.

## Descubrimientos técnicos ya pagados (no re-descubrir)

### M2 (transcripción)

- **FluidAudio resuelve la carpeta del modelo como el repo SIN el sufijo `-coreml`** (`parakeet-tdt-0.6b-v3`). Si `AsrModels.load(from:)` no encuentra los archivos en ESA carpeta, **re-descarga el repo entero él mismo, SIN verificación, a un directorio hermano** — bypassea nuestro registry sha256. El `folderName` del catálogo debe ser exactamente ese; hay test que lo protege.
- **`SlidingWindowAsrConfig.hypothesisChunkSeconds` está muerto en FluidAudio 0.15.4**: el pipeline solo emite un update por `chunkSeconds` (default 11 s → latencia 13+ s). Para captions < 2 s: ventana custom left 11 / chunk 1.0 / right 0.4 (= 12.4 s ≤ 15 s del modelo). La latencia estructural es chunk + right + inferencia.
- **El dedup de tokens upstream falla con chunks pequeños**: al deslizarse la ventana, cada update confirmado re-emite ~todo el left context (verificado: texto duplicado masivo). Fix nuestro en `ParakeetSegmentMapper`: los `tokenTimings` de los updates vienen en **tiempo absoluto del stream** — filtrar tokens con `startTime > último borde emitido` y reconstruir el texto del delta con `joinedText` (maneja `▁` de SentencePiece).
- **`ASRResult.duration` = 0 en el path disk-backed** (archivos > ~30 s) — leer la duración real con `AVAudioFile` para métricas.
- **`TdtDecoderState()` es `throws`**; se pasa `inout` a métodos del actor `AsrManager` (legal: var local).
- Primer load del modelo compila para ANE (~14 s el Encoder en M4 Max); después queda cacheado por CoreML (~1 s).
- El modelo Parakeet v3 es CC-BY-4.0 (el código FluidAudio Apache-2.0) — ambos MIT-compatibles con atribución.
- Los sha256 pineados salen del **tree API de HF** (`/api/models/<repo>/tree/<rev>?recursive=true`): los LFS traen sha256 directo (`lfs.oid`); los archivos chicos hay que hashearlos uno mismo. Procedimiento documentado en el doc comment de `ModelCatalog.parakeetTdtV3`.
- `say -o x.aiff` + `afconvert -f WAVE -d LEI16@16000 -c 1` genera fixtures de voz para pruebas; `afplay` por parlantes al mic hace un loop acústico E2E real.

### M1 (captura) — sigue vigente

- `CATapDescription(stereoMixdownOfProcesses:)` recibe **`[AudioObjectID]` directo**, no `[NSNumber]`.
- El tap requiere aggregate device privado con `kAudioAggregateDeviceTapListKey` + `kAudioSubTapDriftCompensationKey: true`; leer el formato con `kAudioTapPropertyFormat` ANTES del IOProc.
- PID → objeto Core Audio: `kAudioHardwarePropertyTranslatePIDToProcessObject`.
- `AVAudioFile` escribe WAV 16-bit directo desde Float32 — sin FFmpeg.
- **Un tap sin permiso TCC entrega SILENCIO, no error** (peak 0.0% en system.wav → Ajustes → Privacidad → Grabación de pantalla y audio del sistema → activar la terminal → relanzar). El CLI lo detecta e imprime.
- La enumeración de inputs lista iPhones vía Continuity — base del futuro canal `room`.

## Cómo continuar en una sesión nueva

1. Abrir la sesión **en esta carpeta** (`cd ~/Personal/github/portavoz && claude`).
2. Leer este HANDOFF y retomar el hito en curso según ROADMAP.
3. Al cerrar: actualizar este documento y añadir a DECISIONS.md cualquier decisión de peso. **Nada importante puede quedar solo en la conversación.**

## Mapa de documentos

- [CLAUDE.md](../CLAUDE.md) — guía operativa mínima para sesiones de Claude Code (apunta aquí).
- [docs/DECISIONS.md](DECISIONS.md) — **registro de todas las decisiones con su porqué** (D1–D16).
- [docs/ARCHITECTURE.md](ARCHITECTURE.md) — diseño técnico: módulos, pipelines, reglas de ingeniería, entorno.
- [docs/PRODUCT.md](PRODUCT.md) — visión, mercado, FREE/PRO, targets de performance.
- [docs/ROADMAP.md](ROADMAP.md) — hitos M0–M8 con criterios de aceptación.
