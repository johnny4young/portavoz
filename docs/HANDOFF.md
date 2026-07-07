# HANDOFF — Estado del proyecto

> Documento de traspaso entre sesiones de trabajo. Actualizar al final de cada sesión significativa.
> Última actualización: 2026-07-07 (sesión M2+M3+M4+M5·storage).

## Estado actual

| Hito | Estado |
|---|---|
| **M0 — Scaffold** | ✅ Completo (`1b9aa47`). SPM workspace, CI, docs. |
| **M1 — Captura** | ✅ Funcionalmente completo y verificado. Pendiente solo el test de aceptación largo (30 min, drift < 50 ms con `scripts/verify_drift.py`). |
| **M2 — Transcripción** | ✅ **Completo, criterio de aceptación medido en verde** (ver abajo). |
| **M3 — Diarización** | ✅ **Núcleo completo y verificado con audio real (AMI) y sintético.** Pendientes: DER formal en reunión real de 4 personas, y las "speaker pills" (UI — no existe app target todavía; va con el shell de app hacia M5). |
| **M4 — Inteligencia** | ✅ **Núcleo completo, criterio medido en verde**: resumen estructurado ES de reunión EN con glosario intacto en 3.8 s (< 30 s); path incremental (map-reduce) verificado. Falta la parte "durante la reunión" (resumen rodante) — va con la app. |
| **M5 — Public 0.1** | 🚧 **StorageKit completo** (GRDB 7 + FTS5, contrato D4 ejecutado, D19): persistencia E2E verificada vía `summarize --save` + `meetings list/show/search`; retención de audio de M1 cerrada. Faltan: app shell SwiftUI, export MD/PDF/Gist, empaquetado (DMG + Sparkle + Homebrew). |

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

## M3 — qué se construyó (verificado 2026-07-07)

- **`ModelStoreKit`** (target nuevo): `ModelRegistry` + `ModelStore` salieron de TranscriptionKit para compartirse entre Kits sin violar la regla "los Kits no dependen entre sí". Catálogo ahora con 2 modelos pineados.
- **`PyannoteDiarizer`** (actor, DiarizationKit): pyannote community-1 + WeSpeaker v2 (10 artefactos sha256, ~14 MB, commit `1ed7a662…`). Streaming por ventanas de 10 s con `atTime` (SpeakerManager mantiene S1/S2… entre ventanas) + `diarizeFile` batch. Carga por paths explícitos — sin riesgo de descarga no verificada.
- **`clusteringThreshold = 0.45`** (D17) — calibrado contra el sample AMI de pyannote con RTTM de referencia; el default 0.7 de FluidAudio fusiona speakers reales (wiring interno ×1.2 → 0.84 coseno).
- **`SpeakerAttributor`** (pure functions): mic → "Me" (hardware, D5); system → turno con mayor overlap; segmentos multi-turno se parten en límites de turnos con reparto proporcional de palabras; sin turno → sin atribuir.
- **Corte por puntuación** en segmentos batch (`ParakeetSegmentMapper`): los timings TDT no traen gaps → el corte por pausa casi nunca dispara; la puntuación de Parakeet v3 da segmentos-oración, que es lo que hace funcionar la atribución.
- **CLI**: `diarize --file <wav> [--attribute] [--threshold t]`; `models download|verify|path` ahora cubre el catálogo entero.
- Resultados: AMI (2 speakers reales) ≈ RTTM de referencia; conversación TTS 2 voces → 7/8 oraciones bien atribuidas (artefacto: speaker espurio en la última ventana zero-padded, q ~0.2). 40 tests en verde (2 de integración con modelos reales, gated).

## M4 — qué se construyó (verificado 2026-07-07)

- **`FoundationModelSummaryProvider`** (on-device, macOS 26+): guided generation (`@Generable`) → `StructuredSummary` neutro (compartido con BYOK) → markdown + action items con owners resueltos contra los `Speaker`. Decodificación greedy. Transcripts largos por **map-reduce recursivo** (chunks 4500 chars → notas cap 250 tokens → converge garantizado).
- **`OpenAICompatibleSummaryProvider`** (BYOK): cualquier endpoint `/chat/completions`; opt-in explícito y etiquetado (D8); key por `PORTAVOZ_BYOK_API_KEY` en el CLI (Keychain llega con la app).
- **`PromptFactory` + `TranscriptFormatter`** (puros, testeados): directiva de idioma con nombre humano + repetición al final del prompt; glosario verbatim; secciones del Recipe traducibles; formato `[mm:ss] Label: texto`.
- **CLI `summarize`**: pipeline completo wav → transcript → diarización → atribución → resumen; `--out-language`, `--glossary`, `--byok`.
- **Dependencia FluidAudio pineada por revisión** (`c367a18e…`): el tag v0.15.4 tiene un timeout determinístico del type-checker en su target CLI (arreglado upstream en #732, sin release aún) — **volver a `.upToNextMinor` cuando salga > 0.15.4**.
- Resultados: resumen ES de reunión EN, headings traducidos, `roadmap`/`batch`/`pipeline` intactos, 3.8 s; sin action items inventados (greedy + guías estrictas); path incremental ~11 s para 3 ventanas. **55 tests en verde** (4 de integración con modelos reales, gated).

## M5 — qué hay hasta ahora (StorageKit verificado 2026-07-07)

- **`MeetingStore`** (GRDB 7 + FTS5): contrato D4 completo — UUID PKs, tombstones, summaries como snapshots versionados inmutables (action items = excepción mutable en su tabla), paths relativos con rechazo de absolutos, `visibility` reservado. Búsqueda FTS5 con snippets e input hostil sanitizado. **`enforceAudioRetention` cierra la deuda de M1** (borra audio expirado, jamás el transcript).
- **Tipos movidos a Core** (evita deps Kit↔Kit): `Meeting` (nuevo), `AudioRetentionPolicy` (typealias de compat en AudioCaptureKit), `Recipe`/`SummaryDraft`/`ActionItem`.
- **CLI**: `summarize --save [--db]` persiste reunión+speakers+segmentos+resumen; `meetings list|show|search`. E2E verificado con la conversación TTS: FTS encuentra "[latency]" con snippet, show imprime transcript atribuido + resumen v1.
- sqlite-vec diferido a M8 (D19). **67 tests en verde** (12 nuevos de storage).

## Próximos pasos (en orden)

1. **Test de aceptación M1 pendiente** (usuario): 30 min con audio APERIÓDICO (podcast) → `scripts/verify_drift.py` (drift real por correlación; el "drift" del CLI es proxy burdo).
2. **Validación M3 formal** (usuario): reunión real de 4 personas → DER < 15% (los turnos salen de `diarize`; falta harness de DER contra referencia — FluidAudio trae `DiarizationDER.swift` que puede reusarse). "Me" 100% ya es estructural por diseño.
3. **M5 restante**: (a) **app shell SwiftUI** (primer target de UI; desbloquea speaker pills M3 y resumen rodante M4) — decidir estructura: target SPM ejecutable vs proyecto Xcode (TCC/entitlements/firma pesan hacia Xcode o XcodeGen); (b) export MD/PDF/Gist (IntegrationsKit); (c) empaquetado DMG + Sparkle + Homebrew (D10).
4. Deuda menor: captions vivos cortan subwords en costuras (espera al re-pase Whisper); speaker espurio en ventana final zero-padded del diarizer; volver FluidAudio a `.upToNextMinor` cuando haya release > 0.15.4.

## Quirks del entorno de desarrollo

- **`xcode-select` apunta a CommandLineTools** → tests con `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (o arreglar con `sudo xcode-select -s …`). Por esto la suite es XCTest.
- Toolchain: Swift 6.3.3, macOS 26, Apple Silicon (M4 Max, 36 GB).
- Modelos instalados en `~/Library/Application Support/Portavoz/Models/` (override con `--models-dir`).
- El repo de referencia Meetily vive en `../meetily` (estudiar, jamás portar — GPL en MacParakeet también: mirar sin tocar).
- El Python de python.org no tiene certificados SSL (`urllib` falla) — usar `curl` en scripts.

## Descubrimientos técnicos ya pagados (no re-descubrir)

### M4 (inteligencia)

- **La ventana de 4096 tokens del modelo on-device cuenta TODO**: instrucciones + prompt + schema del guided generation + salida. 6000 chars de material la reventaron (`exceededContextWindowSize`); el material del pase estructurado debe quedar ≤ ~3000 chars.
- **El map-reduce necesita compresión garantizada**: sin `maximumResponseTokens` en las notas, cada nota puede medir ~2800 chars y la recursión NO converge ("did not converge"). Cap de 250 tokens = ≥4x por nivel.
- **El modelo de 3B ignora directivas de idioma débiles**: "BCP-47 tag es" en instructions → salida en inglés. Funciona: nombre humano ("Spanish (español)") + repetir la orden AL FINAL del prompt de usuario.
- **Con sampling, el 3B inventa action items** (le atribuyó compromisos al speaker espurio S3). Greedy + guía "solo compromisos explícitos, array vacío si no hubo" lo corrigió.
- La API real de FoundationModels se verifica en el `.swiftinterface` del SDK local (`MacOSX26.5.sdk/...FoundationModels.framework/Modules/...swiftinterface`) — mejor fuente que cualquier doc.
- **FluidAudio v0.15.4 no compila entero en esta máquina** (timeout del type-checker en `NemotronMultilingualFleursBenchmark.swift` de su CLI; a veces pasa, a veces no — depende de la carga). Fix upstream #732 (`c367a18e`) pineado por revisión.

### M3 (diarización)

- **El threshold efectivo de asignación de speakers es `clusteringThreshold × 1.2`** (wiring interno de `DiarizerManager` → `SpeakerManager`). Con el default 0.7 → 0.84 de distancia coseno: fusiona hasta los 2 speakers del sample AMI real. Nuestro default: 0.45.
- **Fixture de calibración**: `pyannote-audio` publica `src/pyannote/audio/sample/sample.wav` (30 s de reunión AMI real, 2 speakers) **con su `sample.rttm` de referencia** — ground truth público y reproducible para validar diarización sin grabar reuniones.
- Las voces TTS de `say` comparten vocoder → embeddings casi indistinguibles para WeSpeaker (a 0.45: Samantha vs Rishi separa bien; con default 0.7 se fusiona TODO). No calibrar contra TTS; usar el sample AMI.
- **La última ventana parcial (zero-padded) del diarizer suele crear un speaker espurio** con quality ~0.2 — ruido de cola conocido, marginal en audio largo.
- **Los timings TDT de Parakeet no traen gaps** (fin de token = inicio del siguiente, semántica frame-jump): el corte de segmentos por pausa casi nunca dispara en batch — cortar por puntuación de oración.
- `DiarizerModels.load(localSegmentationModel:localEmbeddingModel:)` carga por paths explícitos y jamás descarga (a diferencia de `AsrModels.load`).
- Un `PyannoteDiarizer` = una sesión: `SpeakerManager` acumula la base de voces entre llamadas (así "S1" es estable), o sea que reuniones distintas no comparten instancia.

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
- [docs/DECISIONS.md](DECISIONS.md) — **registro de todas las decisiones con su porqué** (D1–D19).
- [docs/ARCHITECTURE.md](ARCHITECTURE.md) — diseño técnico: módulos, pipelines, reglas de ingeniería, entorno.
- [docs/PRODUCT.md](PRODUCT.md) — visión, mercado, FREE/PRO, targets de performance.
- [docs/ROADMAP.md](ROADMAP.md) — hitos M0–M8 con criterios de aceptación.
