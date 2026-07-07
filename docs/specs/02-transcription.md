# Spec 02 — Transcripción (TranscriptionKit, ModelStoreKit)

Estado: implementado y verificado. Decisiones: D7 (routing por tarea), D15 (pinning sha256), D16 (captions vivas), D25 (motores plurales — planeado).

## Roles y motores (D7)

| Rol | Motor | Estado |
|---|---|---|
| Vivo (`liveTranscription`) | Parakeet TDT 0.6B v3 int8 (FluidAudio) | ✅ p95 0.53 s medido |
| Calidad (`finalTranscription`) | Whisper large-v3-turbo (WhisperKit 1.0.0, pin exacto) | ✅ 23–42x medido |
| Plurales por rol con recomendador | — | Planeado (D25/M12) |

## Registry de modelos — ModelStoreKit

- `ModelCatalog` con 4 descriptores pineados: `parakeetTdtV3` (21 artefactos, 483 MB, subset int8), `speakerDiarization` (10 artefactos, ~14 MB), `whisperLargeV3Turbo` (24 artefactos, ~1.6 GB), `whisperTokenizer` (3 archivos). Cada `ModelArtifact` = path relativo + sha256 + tamaño; `resolveBase` pineado a commit exacto de HF.
- `ModelStore` (actor): descarga por artefacto → verifica tamaño + sha256 (CryptoKit streaming 1 MiB) → move atómico. `verify()` re-hashea; `ensureAvailable()` sana faltantes/corruptos. Instalación en `~/Library/Application Support/Portavoz/Models/` (override `--models-dir`).
- **Gotcha protegido por test**: el `folderName` de Parakeet debe ser `parakeet-tdt-0.6b-v3` (SIN sufijo `-coreml`) — FluidAudio resuelve la carpeta así y si no encuentra los archivos **re-descarga el repo entero sin verificación** a un directorio hermano.
- Los sha256 salen del tree API de HF (`/api/models/<repo>/tree/<rev>?recursive=true`): LFS trae `lfs.oid`; archivos chicos se hashean a mano. Procedimiento en el doc comment de `ModelCatalog.parakeetTdtV3`.

## Vivo: ParakeetEngine + mapper

- Ventana deslizante custom **left 11 s / chunk 1.0 s / right 0.4 s** (≤ 15 s del modelo). El preset `.streaming` de FluidAudio NO sirve: su `hypothesisChunkSeconds` es código muerto (solo emite por `chunkSeconds` = 11 s → latencia 13+ s).
- **Filtro de deltas propio** (`ParakeetSegmentMapper`): el dedup upstream falla con chunks pequeños (re-emite ~todo el left context). Los `tokenTimings` de los updates vienen en tiempo absoluto del stream → filtrar `startTime > último borde emitido` y reconstruir texto con `joinedText` (maneja `▁` de SentencePiece).
- Batch: `AsrManager` long-form disk-backed, `parallelChunkConcurrency: 1` (cortesía al slot vivo), `melChunkContext: false` (recomendado para v3 multilingüe). Segmentos-oración por puntuación (los timings TDT no traen gaps: el corte por pausa casi nunca dispara; `sentenceTerminators` + pauseSplit 0.5 s + máx 15 s).
- `TranscriptionScheduler` (D7): lane vivo inmediato; slot batch serial FIFO en `Task.detached(priority: .utility)`.
- `TdtDecoderState()` es `throws` y se pasa `inout` (var local). `ASRResult.duration` = 0 en el path disk-backed → leer duración real con AVAudioFile.
- Primer load compila para ANE (~14 s el encoder en M4 Max); después CoreML cachea (~1 s).
- Licencias: modelo Parakeet v3 CC-BY-4.0, FluidAudio Apache-2.0, WhisperKit MIT — todas MIT-compatibles con atribución.

## Calidad: WhisperEngine — `Sources/TranscriptionKit/WhisperEngine.swift`

Endurecido contra 3 fallas REALES de WhisperKit (todas reproducidas y verificadas, jul 2026):

1. **`concurrentWorkerCount: 1`** — el default es 16 y los workers corren en carrera sobre el estado compartido del decoder: chunks enteros desaparecen EN SILENCIO y no-determinísticamente (reunión real de 482 s colapsó a 3 segmentos; el path VAD-chunked de WhisperKit traga los fallos por chunk con `Logging.debug`, sin rethrow). Con 1 worker: correcto y 23x (el ANE serializa igual).
2. **Peak-normalize antes de transcribir** (`AudioLevel.normalizePeak`, target 0.9, gain cap 20x): el EnergyVAD de WhisperKit gatea por energía ABSOLUTA (umbral 0.02) y una reunión con volumen bajo queda por debajo → "no hay voz".
3. **Retry de cobertura sobre segmentos LIMPIOS**: si el habla transcrita < 20% de la duración del archivo (audio > 60 s), re-decodifica secuencial (`chunkingStrategy: nil` — ese path SÍ propaga errores) y SIN promptTokens. Dos trampas cubiertas: los chunks envenenados devuelven timespans válidos con texto que `cleanSegmentText` deja vacío (la cobertura cruda engaña), y el prompt de vocabulario descarrila las ventanas que no mencionan los términos (verificado: con 12 términos solo sobrevivía el chunk que los decía). Verificado: 3 → 82 segmentos con vocabulario.

- Carga con model+tokenizer de directorios verificados, `download: false` (jamás descarga sin verificar). Tokenizer local evita red.
- Vocabulario (`hints.vocabulary`) → `promptTokens` como frase natural ("In this meeting we discussed …", no lista "Glossary:"); WhisperKit lo prepende con `<|startofprev|>` y filtra especiales.
- `timings.inputAudioSeconds` under-reporta con VAD → duración desde el archivo.

## Spike SpeechAnalyzer (M12/D25) — estado y hallazgos (jul 2026)

`SpeechAnalyzerEngine` (macOS 26, `#if canImport(Speech)`): implementado contra el `.swiftinterface` REAL del SDK local — misma forma que el live de Parakeet para benchmarks idénticos. Hallazgos del spike:

1. **SpeechAnalyzer SÍ acepta vocabulario custom** — `AnalysisContext.contextualStrings[.general]` existe en el SDK (26.5) y el engine lo cablea desde `hints.vocabulary`. Esto CORRIGE la investigación de la ronda 2 ("perdió contextualStrings") — llegó en una beta posterior a las reviews.
2. **⚠️ Cuelga en procesos CLI sin bundle**: `SpeechTranscriber.supportedLocale(equivalentTo:)` (primer await) suspende PARA SIEMPRE en `portavoz-cli` — sample muestra el pool cooperativo vacío y el runloop aparcado (el daemon de Speech nunca responde a un proceso sin contexto de bundle/TCC). **El benchmark del rol vivo debe correr DENTRO de la app** — `NSSpeechRecognitionUsageDescription` ya añadido al Info.plist.
3. **Harness listo y validado**: `portavoz-cli bench-live --file <wav|caf> --engine parakeet|speech --seconds N` — pacea el archivo a ritmo real (chunks de 1 s) y mide lag de finalización por segmento. Baseline Parakeet medido (60 s de reunión real, canal system): **46 finales · primer resultado 1.18 s · lag p50 0.19 s / p95 1.01 s / max 2.68 s**.
4. **Modelo de emisión distinto**: Parakeet emite DELTAS append-only; SpeechTranscriber emite resultados por rango (volátiles se reemplazan, finales estables) — la integración M12 debe decidir append-vs-replace en el coalescer antes de que el engine sea intercambiable en la app.

Siguiente paso M12: comando debug en la app (o launch-arg) que corra el mismo bench-live in-bundle → números comparables → decisión.

## Coalescer de captions — `CaptionCoalescer` (usado por la app)

La fila más nueva crece mientras el canal siga hablando: pausas mid-sentence ≤ 6 s se quedan en la fila, continuación < 2 s tras oración cerrada fluye, corte duro a 280 chars. Identidad de fila estable (id/startTime se conservan) → SwiftUI no reconstruye y la traducción solo traduce filas cerradas (solo la última fila global puede crecer). 10 tests.

## Vocabulario — `VocabularyPrompt`

`parse()` (coma-separado, trim, dedup) y `text()` (frase natural). Fuentes: Ajustes de la app (UserDefaults `customVocabulary`, editor de lista), CLI `--vocab`. Consumidores: WhisperEngine (promptTokens), resúmenes (glossary, spec 04). **Parakeet vivo no tiene hook de bias** — el refine corrige el registro.

## Límites conocidos

1. Parakeet vivo degrada con acentos no nativos (verificado: intervención EN con acento salió garbled en vivo; el mismo audio por Whisper salió limpio) — respuesta actual: refine.
2. Sin modo dictado system-wide (idea futura, ROADMAP "Later").
3. Cuantizadas de Whisper (`large-v3-v20240930_547MB/_626MB`, verificadas en el repo de argmax) aún no están en el catálogo — M12.
4. FluidAudio pineado por revisión `c367a18e` (timeout del type-checker en su CLI target en v0.15.4; fix upstream #732 sin release) — volver a `.upToNextMinor` cuando salga > 0.15.4.
