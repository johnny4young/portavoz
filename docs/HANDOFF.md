# HANDOFF — Estado del proyecto

> Documento de traspaso entre sesiones de trabajo. Actualizar al final de cada sesión significativa.
> Última actualización: 2026-07-07 (release 0.1.0 notarizado + verificación con reunión real de 22 min).

## Estado actual

| Hito | Estado |
|---|---|
| **M0 — Scaffold** | ✅ Completo (`1b9aa47`). SPM workspace, CI, docs. |
| **M1 — Captura** | ✅ **Completo — test de aceptación PASADO con reunión real de 22 min: drift 4 ms** (< 50 ms; +4 ppm medido en 5 puntos, lineal → ~7 ms proyectado a 30 min). |
| **M2 — Transcripción** | ✅ **Completo, criterio medido en verde** (ver abajo). **Re-pase de calidad D7 ejecutado**: Whisper large-v3-turbo pineado (1.6 GB), `transcribe --engine whisper` y `meetings refine <id>` (re-transcribe+re-diariza+reemplaza el cast con tombstones; los snapshots de resumen sobreviven). |
| **M3 — Diarización** | ✅ **Núcleo completo y verificado con audio real (AMI) y sintético.** **DER medido contra el sample AMI real de pyannote: 7.6%** (< 15% ✓, harness `portavoz-cli der`). Reunión real de 22 min procesada: 4 clusters grandes correctos (94.7% del habla) + 6 micro-clusters espurios (~59 s; ver descubrimientos: threshold). DER formal pendiente de que el usuario corrija el RTTM borrador (`~/Desktop/portavoz-verificacion/`). |
| **M4 — Inteligencia** | ✅ **Núcleo completo, criterio medido en verde**: resumen estructurado ES de reunión EN con glosario intacto en 3.8 s (< 30 s); path incremental (map-reduce) verificado. Falta la parte "durante la reunión" (resumen rodante) — va con la app. |
| **M5 — Public 0.1** | 🚧 StorageKit (D19) + app shell (D20, **grabación in-app verificada por el usuario 2026-07-07**) + **export MD/PDF/Gist** (L0 de D12) + **polish de UI**: ícono real (`assets/AppIcon.icns`, regenerable con `scripts/make-icon.swift`), `MarkdownText` (bloques + inline), **resumen rodante en vivo** durante la grabación (cada ~40 s con FM), regenerar resumen a demanda (es/en, nueva versión del snapshot), Ajustes (⌘,) con token de GitHub en Keychain y "Publicar como Gist" desde la app con confirmación off-device. **Empaquetado completo (D23)**: Sparkle 2 embebido (menú "Buscar actualizaciones…", llave EdDSA dedicada account `portavoz`, pública en `assets/`), `make-dmg.sh` y `make-release.sh <v>` → DMG 7.9 MB + appcast firmado + cask (`packaging/portavoz.rb`), verificado E2E ad-hoc. **Release 0.1.0 real firmado + notarizado (2026-07-07)**: hardened runtime + entitlement de mic (`packaging/portavoz.entitlements`), firma por SHA-1 del cert (`8C8B5B14…`, hay dos Developer ID con el mismo nombre), perfil notarytool `portavoz-notary` (Apple ID `asesordeprogramacion@gmail.com`) → notarización **Accepted**, stapled, `spctl` "Notarized Developer ID"; instalado en /Applications y **usado en reunión real de 22 min**. Falta solo publicar: push del repo, `gh release create v0.1.0 dist/release/*`, tap de Homebrew. |
| **M6 — Identidad y lenguaje** | 🚧 Voiceprint + nombres (D21, verificado E2E) ✓. **Captions traducidos en vivo** (Translation framework, picker →es/→en en grabación) y **EventKit como candidatos de nombres** (filtro `NameSuggestionFilter` acepta transcript O asistentes): **código listo y testeado, verificación interactiva pendiente** (descarga de idioma / TCC calendario). |
| **M8 — Dev moat** | 🚧 **MCP local + RAG funcionando (criterio de aceptación cumplido)**: `portavoz-cli mcp` (6 tools incl. `ask`) y `portavoz-cli ask` — retrieval híbrido (FTS OR-keywords + coseno sobre NLContextualEmbedding latino cross-lingüe es/en, fusión RRF, multi-query con FM, micro-segmentos excluidos del índice), respuesta on-device con citas. Verificado E2E: agente MCP respondió "what did we agree about the transcription budget?" con fuentes. **Export GitHub Issues + Linear**: código listo y testeado offline (`portavoz-cli issues --meeting <id> --github o/r | --linear-team id`, tokens en Keychain) — publish real pendiente de tokens. Falta: App Intents. |

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

- **App shell SwiftUI** (`portavoz-app`, D20): target SPM + `scripts/make-app.sh` → `dist/Portavoz.app` (Info.plist con usage descriptions de mic/audio del sistema, firma ad-hoc). Biblioteca con búsqueda FTS, detalle con **speaker pills editables** (pendiente M3 cerrado), resumen + action items chequeables, y grabación con captions vivas + pipeline post-reunión completo (`RecordingController`). Verificado: lanza, renderiza, comparte SQLite con el CLI, y **la grabación in-app funcionó en prueba real del usuario** (la reunión quedó en la biblioteca).
- **Export (L0 de la escalera D12)**: `MeetingExporter.markdown` (título + metadata + resumen con headings degradados + pendientes + transcript atribuido) y `.pdf` (CoreText puro, sin AppKit — compila para iOS; paginación US Letter verificada con CGPDFDocument). `GistPublisher` contra `api.github.com/gists` (secreto por defecto, `--public` explícito); `SecretStore` en Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) — publicar un gist real queda pendiente de probar con token. CLI: `export --meeting <id> [--format md|pdf] [--out] [--gist [--public]]`, `secrets set-github-token`. App: menú Exportar (MD/PDF) con `fileExporter`.
- **`MeetingStore`** (GRDB 7 + FTS5): contrato D4 completo — UUID PKs, tombstones, summaries como snapshots versionados inmutables (action items = excepción mutable en su tabla), paths relativos con rechazo de absolutos, `visibility` reservado. Búsqueda FTS5 con snippets e input hostil sanitizado. **`enforceAudioRetention` cierra la deuda de M1** (borra audio expirado, jamás el transcript).
- **Tipos movidos a Core** (evita deps Kit↔Kit): `Meeting` (nuevo), `AudioRetentionPolicy` (typealias de compat en AudioCaptureKit), `Recipe`/`SummaryDraft`/`ActionItem`.
- **CLI**: `summarize --save [--db]` persiste reunión+speakers+segmentos+resumen; `meetings list|show|search`. E2E verificado con la conversación TTS: FTS encuentra "[latency]" con snippet, show imprime transcript atribuido + resumen v1.
- sqlite-vec diferido a M8 (D19). **67 tests en verde** (12 nuevos de storage).

## Verificación con reunión real (2026-07-07, 22 min, app notarizada)

Reunión "Reunión 7 Jul 2026 at 9:10 AM" (`652CEACF…`), grabada con la 0.1.0 instalada, reproduciendo una reunión grabada por parlantes:

- **M1 drift: PASS 4 ms** (tras corregir `verify_drift.py`, commit `93d6570` — ver descubrimientos).
- **Refine D7 sobre reunión real ✓**: Whisper a **30x** (1314 s en 43.5 s), 1661 segmentos vivos fragmentados → 444 segmentos-oración con puntuación. Calidad noche y día.
- **Resumen final se generó solo** (v1, en, coherente). Regenerarlo en la app usaría el transcript refinado.
- **Diarización**: 4 clusters grandes = 94.7% del habla del canal system (estructura temporal consistente entre pase vivo y refine) + 6 micro-clusters de 3–28 s (fragmentación, ver threshold en descubrimientos).
- **Borrador para DER formal**: `~/Desktop/portavoz-verificacion/reunion-2026-07-07.{rttm,md}` — el usuario corrige la columna Speaker en el .md, se transcriben las correcciones al .rttm y se mide con `portavoz-cli der --file system.wav --reference <rttm corregido>`.
- **Hallazgo del setup**: con parlantes (sin audífonos) el mic capta el audio del sistema → el canal "Me" duplica a los demás participantes. No es bug (mic→Me es estructural, D5) pero es limitación real; mitigación futura: AEC con `setVoiceProcessingEnabled` de AVAudioEngine, o gating por voiceprint en el canal mic. Recomendación al usuario mientras: audífonos.

## Mejoras tras la 2ª reunión real (2026-07-07, 30 min, feedback del usuario)

La segunda reunión (`8AA7DCCC…`, reproducida por parlantes, audífonos desde ~24:10) destapó 6 problemas; todos corregidos y commiteados (`a972146`…`42d44bc`), 133 tests verdes, app reinstalada en /Applications (firmada, sin notarizar — para pruebas locales basta):

1. **Bug grave: el mic murió al conectar audífonos** — microphone.wav terminó en 1449.9 s de 1806.6 s, sin error. AVAudioEngine se detiene ante `AVAudioEngineConfigurationChange` y el stream quedaba mudo. Fix: reinstalar tap + reiniciar engine (con retries), resampleo lineal si el dispositivo nuevo trae otro rate, y relleno del hueco con silencio para que la timeline siga alineada.
2. **Eco por parlantes = "Yo" fantasma** — ~100% del canal mic era eco (el usuario habló UNA vez); dedup por texto solo detectaría 57% (el eco degradado se transcribe distinto: ahí nace lo de LVGT→LGBT). Fix de raíz: **AEC (voice processing de Apple) en el input node, ON por defecto** (D24), ducking `.min` para no atenuar la reunión. Toggle en Ajustes + `record --no-aec`. Smoke test OK; verificación de campo pendiente.
3. **Captions fragmentadas** ("ration of" / "ation overall") — `CaptionCoalescer`: la fila más nueva crece mientras el canal siga hablando (pausas mid-sentence ≤6 s, continuación tras oración <2 s, corte a 280 chars). Identidad de fila estable; la traducción en vivo ahora espera a que la fila cierre; autoscroll sigue endTime.
4. **Resumen en vivo encogía y su costo crecía** — ahora acumula notas (una pasada map de 250 tokens SOLO sobre filas nuevas cerradas), colapsa la pila a >6000 chars y re-renderiza desde notas: costo por tick plano. `LiveSummaryPolicy` retiene renders <90% del actual (monotonicidad visible).
5. **Vocabulario custom** (Ajustes → Vocabulario, coma-separado): llega a Whisper como promptTokens (`<|startofprev|>`, sesgo de decodificación), a los resúmenes como glossary, y a `meetings refine --vocab`. Parakeet vivo no tiene hook de bias — el refine corrige el registro.
6. **UI congelada en reuniones largas** — transcript del detalle y captions en `LazyVStack` (antes eager: 1600+ filas montadas de una), ventana viva a 150 filas coalescidas.

Nota: el inglés indio se transcribe mal en vivo (Parakeet); el re-pase Whisper large-v3-turbo lo maneja mucho mejor — es la respuesta por ahora.

## Próximos pasos (en orden)

**Verificaciones que aún necesitan al usuario (próxima reunión real):**
- **AEC**: grabar con parlantes y hablar — tus palabras deben salir como "Yo" y los demás NO deben duplicarse. Si el mic se oye raro, Ajustes → desactivar "Cancelación de eco" y avisar.
- **Cambio de dispositivo**: conectar/desconectar audífonos a mitad de grabación — el canal mic debe sobrevivir (con hueco de silencio, no muerte).
- **Resumen en vivo**: debe crecer siempre, nunca encoger.
- **Vocabulario**: cargar términos (LVGT…) en Ajustes antes de la reunión; tras `meetings refine`, verificar que se transcriben bien.
- Corregir labels del RTTM borrador (`~/Desktop/portavoz-verificacion/reunion-2026-07-07.md`) → DER formal M3 en reunión real.
- Captions traducidos: grabar con el picker "Traducir → …" activo; la primera vez macOS puede pedir descargar el par de idiomas.
- Nombres con calendario: evento con asistentes alrededor de una grabación → "Sugerir nombres" (pide TCC de calendario). La reunión de prueba menciona "Vishakha" — buen caso para el botón ✦ con el transcript refinado.
- Issues: `secrets set-github-token` / `set-linear-token` + `portavoz-cli issues --meeting <id> --github <owner/repo>` contra un repo de prueba.
- `ask` con tu propia biblioteca: `portavoz-cli ask "¿qué acordé ayer?"` (y vía MCP: `claude mcp add portavoz -- portavoz-cli mcp`).
- Probar `export --gist` / "Publicar como Gist" con token real.

1. **Publicar 0.1.0**: push del repo (`git@github.com:johnny4young/portavoz.git`), `gh release create v0.1.0 dist/release/*`, crear tap `johnny4young/homebrew-portavoz` con `dist/release/portavoz.rb`.
2. **Política de micro-clusters** en diarización: mergear/degradar clusters con < ~15 s de habla total hacia el cluster dominante vecino (o marcar sin atribuir) — el threshold NO se puede subir (ver descubrimientos). Evaluar contra el RTTM corregido cuando exista.
3. **AEC en el canal mic** (`setVoiceProcessingEnabled`) para el caso parlantes-sin-audífonos.
4. **M6/M8 restante**: App Intents; M7 iOS+PRO (necesita proyecto Xcode).
5. Deuda menor: volver FluidAudio a `.upToNextMinor` cuando haya release > 0.15.4; `meetings refine` podría aceptar `--threshold`.
   Nota TCC: la 0.1.0 notarizada tiene identidad estable — los permisos ya persisten entre updates (el problema de re-pedir permisos era solo de las builds ad-hoc).

## Quirks del entorno de desarrollo

- **`xcode-select` apunta a CommandLineTools** → tests con `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` (o arreglar con `sudo xcode-select -s …`). Por esto la suite es XCTest.
- Toolchain: Swift 6.3.3, macOS 26, Apple Silicon (M4 Max, 36 GB).
- Modelos instalados en `~/Library/Application Support/Portavoz/Models/` (override con `--models-dir`).
- El repo de referencia Meetily vive en `../meetily` (estudiar, jamás portar — GPL en MacParakeet también: mirar sin tocar).
- El Python de python.org no tiene certificados SSL (`urllib` falla) — usar `curl` en scripts.

## Descubrimientos técnicos ya pagados (no re-descubrir)

### Verificación real (M1/M3, 2026-07-07)

- **ScreenCaptureKit entrega su primer buffer ~2.4 s después de que arranca el mic** (microphone.wav 1316.5 s vs system.wav 1314.1 s en la misma grabación). Ese offset constante quedaba FUERA del rango ±2 s de `verify_drift.py` → la correlación se enganchaba a picos espurios y reportó 115 ms de drift falso. Rango ampliado a ±5 s + warning de borde (`93d6570`). Drift real medido: 4 ms / 22 min (+4 ppm, lineal en 5 puntos).
- **La ventana del clusteringThreshold es finísima y NO se puede subir**: a 0.50 el sample AMI ya fusiona sus 2 speakers (DER 49.8%). Pero en reunión remota real (codecs/mics distintos por participante → más varianza intra-speaker), 0.45 fragmenta: 11 clusters donde hay ~4 reales (distancias al más cercano 0.55–0.64, justo sobre el efectivo 0.45×1.2=0.54). Sweep medido: 0.45→11, 0.50→6, 0.55→5, 0.60→4. Conclusión: mantener 0.45 y atacar la fragmentación con política post-clustering de micro-clusters (los 6 espurios suman solo 59 s de 1119 s ≈ 5% de confusión máxima).
- **Reproducir una reunión por parlantes duplica el contenido**: el mic capta el audio del sistema por el aire y todo sale también como "Me". Para tests de drift es justo lo que se necesita (canales correlacionados); para uso real, audífonos o AEC futuro.
- Whisper large-v3-turbo procesa 22 min reales a **30x** en M4 Max.

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
