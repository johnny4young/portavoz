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
4. **Higiene anti-silencio**: segmentos sin contenido léxico (p. ej. `.` solo) no entran al resultado final; además, si el canal mic produce el mismo boilerplate corto de Whisper en cadencia de VAD (caso real: `Me: Thank you.` cada ~30 s sin que el usuario hablara), el post-proceso lo elimina. Una ocurrencia aislada de "Thank you" se conserva.
5. **Idioma hablado preservado por segmento**: Refine solo fija `hints.language` cuando la evidencia del transcript es homogénea (`Meeting.language` sin segmentos previos, tags por segmento o `NLLanguageRecognizer` local). Si la reunión es mixta — p. ej. una persona habla español y otra inglés — deja `nil` para que Whisper autodetecte y conserve el idioma de cada hablante/segmento. El idioma de UI/resumen nunca se usa como fallback del transcript.

- Carga con model+tokenizer de directorios verificados, `download: false` (jamás descarga sin verificar). Tokenizer local evita red.
- Vocabulario (`hints.vocabulary`) → `promptTokens` como frase natural en el idioma hablado homogéneo ("In this meeting we discussed …" / "En esta reunión hablamos de …", no lista "Glossary:"); en reuniones mixtas/unknown se omite el prompt para no sesgar Whisper hacia un idioma. WhisperKit lo prepende con `<|startofprev|>` y filtra especiales.
- `timings.inputAudioSeconds` under-reporta con VAD → duración desde el archivo.

## Spike SpeechAnalyzer (M12/D25) — estado y hallazgos (jul 2026)

`SpeechAnalyzerEngine` (macOS 26, `#if canImport(Speech)`): implementado contra el `.swiftinterface` REAL del SDK local — misma forma que el live de Parakeet para benchmarks idénticos. Hallazgos del spike:

1. **SpeechAnalyzer SÍ acepta vocabulario custom** — `AnalysisContext.contextualStrings[.general]` existe en el SDK (26.5) y el engine lo cablea desde `hints.vocabulary`. Esto CORRIGE la investigación de la ronda 2 ("perdió contextualStrings") — llegó en una beta posterior a las reviews.
2. **⚠️ Cuelga en procesos CLI sin bundle**: `SpeechTranscriber.supportedLocale(equivalentTo:)` (primer await) suspende PARA SIEMPRE en `portavoz-cli` — sample muestra el pool cooperativo vacío y el runloop aparcado (el daemon de Speech nunca responde a un proceso sin contexto de bundle/TCC). **El benchmark del rol vivo debe correr DENTRO de la app** — `NSSpeechRecognitionUsageDescription` ya añadido al Info.plist.
3. **Harness compartido**: `LiveTranscriptionBench` (TranscriptionKit) pacea el archivo a ritmo real (chunks de 1 s) y mide lag de finalización. Frentes: `portavoz-cli bench-live --engine parakeet` y, para speech, `Portavoz.app/Contents/MacOS/portavoz-app --bench-live <file> [--seconds] [--language]` (launch-arg oculto: corre in-bundle, imprime a stdout, sale).
4. **⚠️ Bug de finalización (arreglado)**: `finalizeAndFinishThroughEndOfInput()` lo llama el FEEDER al agotarse el input — secuenciado después del loop de `transcriber.results` deadlockea (results solo termina cuando alguien finaliza; el primer bench quedó aparcado para siempre).
5. **Comparación medida (mismos 60 s de reunión real EN, canal system, M4 Max)**:

| | Parakeet v3 (CLI) | SpeechAnalyzer en_US (in-app) |
|---|---|---|
| primer resultado | 1.13 s | **1.03 s** |
| lag finalización p50/p95/max | **0.07 / 0.68 / 0.72 s** | 0.47 / 0.82 / 0.82 s |
| emisión | 36 finales append-only (deltas chicos: "uh", "and") | 9 finales-oración + **150 volátiles** (replace) |
| chars finales | 461 | 603 |
| estilo | limpio | verbatim con disfluencias ("uh") |
| con locale equivocado (es_CL sobre EN) | — | latencia igual (p50 0.16) pero texto basura → detectar idioma ANTES importa |

Lectura M12: ambos viven bajo 1 s de p95 — SpeechAnalyzer ES viable para el rol vivo (cero descarga, volátiles ricos para captions, vocabulario custom), Parakeet conserva la corona de finalización. Lo que falta para intercambiarlos en la app es la decisión append-vs-replace del coalescer (los volátiles de Speech REEMPLAZAN el rango; el coalescer actual asume deltas).

## Coalescer de captions — `CaptionCoalescer` (usado por la app)

La fila más nueva crece mientras el canal siga hablando: pausas mid-sentence ≤ 6 s se quedan en la fila, continuación < 2 s tras oración cerrada fluye en micrófono, pero en `system`/`room` la pausa tras oración se corta antes (0.6 s) para que dos participantes remotos consecutivos se vean como dos filas `Ellos` aun antes del refine. Corte duro a 280 chars. Deltas sin contenido léxico se descartan salvo puntuación final que complete una fila existente (`"."` aislado no crea `Yo: .`). Identidad de fila estable (id/startTime se conservan) → SwiftUI no reconstruye y la traducción solo traduce filas cerradas (solo la última fila global puede crecer). 13 tests.

## Vocabulario — `VocabularyPrompt`

`parse()` (coma-separado, trim, dedup) y `text()` (frase natural EN/ES según idioma hablado homogéneo). Fuentes: Ajustes de la app (UserDefaults `customVocabulary`, editor de lista), CLI `--vocab`. **VocabularyMiner** (puro, 6 tests): mina términos con forma de dominio (acrónimos, códigos letra+dígito, CamelCase — nunca palabras capitalizadas normales) que recurren ≥3 veces en los últimos 12 transcripts y los sugiere como chips en Ajustes → Vocabulario. **Flujo revisar-antes-de-agregar** (caso de campo: el minero sugiere lo que Whisper OYÓ — sugirió "Qord2M" cuando el término real era "Kord2m"): el chip precarga el campo de texto para corregir la grafía y confirmar con Add; la ✕ descarta para siempre (`vocabularyRejectedSuggestions` en defaults, el minero los excluye); adoptar una versión editada también rechaza la forma cruda mal-oída para que no vuelva. No corre bajo XCUITest para no mover el layout async. Consumidores: WhisperEngine (promptTokens solo cuando hay idioma homogéneo), resúmenes (glossary, spec 04). **Parakeet vivo no tiene hook de bias** — el refine corrige el registro.

## Límites conocidos

1. Parakeet vivo degrada con acentos no nativos (verificado: intervención EN con acento salió garbled en vivo; el mismo audio por Whisper salió limpio) — respuesta actual: refine.
2. Sin modo dictado system-wide (idea futura, ROADMAP "Later").
3. ~~Cuantizadas de Whisper aún no en el catálogo~~ — **HECHO (M12)**: variante **626 MB** (`whisper-large-v3-626mb`, 17 artefactos sha256-pineados al mismo commit de argmax que turbo) para poco disco. `WhisperEngine.loadRecommended(descriptor:)` la selecciona; `AppServices.loadWhisperIfNeeded` la elige según el toggle "Whisper compacto" (Ajustes) y recarga si cambia; el recomendador la activa si detecta poco disco. Default sigue siendo turbo.
4. FluidAudio pineado por revisión `c367a18e` (timeout del type-checker en su CLI target en v0.15.4; fix upstream #732 sin release) — volver a `.upToNextMinor` cuando salga > 0.15.4.
