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

Además (mientras el usuario estaba en su 3ª reunión): **(7) editor de lista para el vocabulario** (Enter añade, − quita; mismo storage) — `a27f711`; **(8) merge de micro-clusters en diarización** (`d70a9ed`): labels con <15 s de habla total ceden sus turnos al major temporalmente más cercano; "Me" nunca absorbe ni es absorbido (un "Me" fantasma contaminaría owners de action items). **Validado: la reunión real pasó de 11 → 4 speakers y AMI quedó intacto (7.6%, 2 speakers)**. ⚠️ La app instalada se construyó ANTES de (8) — reinstalar (`make-app.sh --release` + copiar) cuando no haya grabación en curso; mientras tanto el merge aplica vía `meetings refine`.

## Ronda 3 (2026-07-07, feedback de la reunión de 10:47 con AEC activo)

La 4ª reunión real (8 min, AEC activo) validó el grueso y destapó 4 puntos; todos resueltos (`1d9c952`…`ddf8524`), 143 tests verdes, app reinstalada:

- **AEC converge en ~2 s** (medido: ratio mic/system 0.38 en 0–2 s → 0.03–0.11 después) → `MicrophoneSource.warmUp()` arranca el engine sin tap apenas el usuario pulsa grabar, y la convergencia ocurre mientras cargan los modelos.
- **"Sugerir nombres" desbordaba la ventana** (prefix ciego de 3000 chars + instrucciones + schema + asistentes > 4096 tokens) → `NamingExcerpt`: primeras intervenciones sustanciales por speaker + líneas que mencionan candidatos, cap 2000 chars, cronológico. El verificador sigue usando el transcript COMPLETO.
- **Intervención del usuario garbled en vivo** ("LOCOL TESTIN U Be REASE S…") → VALIDADO con el clip real: el audio del mic está perfecto (AEC no degrada); Whisper lo transcribe limpio a 31x ("doing a local testing before release properly the PR to a staging"). Es la debilidad conocida de Parakeet vivo con acento; la respuesta es el refine.
- **Refine in-app (D7)**: botón "Refinar" (wand.and.stars) en el detalle — descarga Whisper verificado la primera vez (1.6 GB), re-transcribe ambos canales con vocabulario, re-diariza (merge incluido), replaceCast y regenera el resumen. `AppServices.loadWhisperIfNeeded`.

## Ronda 4 (2026-07-07, incidente del refine + UX de biblioteca)

**INCIDENTE**: el primer uso del refine in-app reemplazó la reunión de 10:47 (66 segmentos, 8 speakers) por 3 segmentos/2 speakers. **Datos restaurados** vía tombstones D4 (des-tombstonear originales + tombstonear el cast malo). Causa raíz encontrada con instrumentación (WhisperKit loguea a os_log; hay que setear `Logging.shared.loggingCallback`):

- **`DecodingOptions.concurrentWorkerCount` default = 16** → los workers corren en carrera sobre el estado compartido del decoder y los chunks se pierden EN SILENCIO (el path VAD-chunked de WhisperKit traga los failures por chunk: `case .failure: Logging.debug`, sin rethrow). No-determinístico: una corrida sobreviven 2 chunks del final, otra 3 del medio; con logging verbose (que serializa) salen los 20 chunks completos (109 segmentos).
- **Bug #2 APILADO — el prompt de vocabulario envenena la decodificación**: con 1 worker (carrera eliminada) el colapso persiste pero DETERMINÍSTICO — con los 12 términos del usuario solo sobrevive el chunk que de verdad los menciona ("Daniel… Messenger…"); los otros 19 descarrilan (QC de Whisper los descarta) y el swallow de errores los hace invisibles. Por eso el A/B inicial engañó: sin vocab también colapsaba (por la carrera) y se descartó la hipótesis del vocab prematuramente. Fixes: fraseo natural del prompt ("In this meeting we discussed …" en vez de lista "Glossary:"), el retry secuencial quita los promptTokens, y — CLAVE — la cobertura que decide el retry se mide sobre segmentos LIMPIOS (los chunks envenenados devuelven spans válidos con texto que se limpia a vacío, y la cobertura cruda parecía sana → el retry no disparaba). Verificado: con los 12 términos del usuario, 3 → 82 segmentos (15x; la pasada secuencial corta menos que la VAD-chunked, cobertura completa igual).
- **Fixes en WhisperEngine**: `concurrentWorkerCount: 1` (el ANE serializa igual; 29x real time), peak-normalización previa (`AudioLevel.normalizePeak` — el EnergyVAD de WhisperKit umbral absoluto 0.02 y esta reunión rondaba 0.018-0.055), y retry secuencial sin chunking si la cobertura < 20% del audio (cinturón y tirantes).
- **Refine ahora es DRAFT** (nunca override): sheet de comparación actual-vs-refinado (segmentos/speakers/habla cubierta/muestra) + warning rojo si cubre <50%; se aplica solo con "Aplicar". **Validado por el usuario en producción**: el sheet detectó el colapso (66→3, 7:40→0:23 min) y evitó la pérdida.
- **"Sugerir nombres" blindado**: si el extracto denso aún desborda la ventana, reintenta una vez con la mitad; el alert genérico de errores dejó de titularse "No se pudo publicar".

UX de la misma ronda (`c3f6d08`): rename de speaker arreglado (carrera del alert-dismiss — capturar valores al tap), captions con follow-live pausable (scroll manual pausa, reanuda a los 10 s o con el botón "Seguir en vivo"), títulos por plantilla (`TitleTemplate`: {date} {time} {seq} {weekday}, ISO-first estilo Zoom, Ajustes → Títulos), título editable (lápiz en el detalle), context menu Renombrar/Eliminar en el sidebar.

**Carpeta de grabaciones configurable: HECHA** (`0150611`): Ajustes → Grabaciones (convención Zoom "Store my recordings at"), `RecordingsLocation` en StorageKit — el root elegido persiste en `recordings-root.txt` JUNTO A LA DB (archivo, no UserDefaults → el CLI respeta la misma carpeta); sin bookmark (hay hardened runtime pero NO sandbox — un path plano basta; TCC pide una vez para carpetas protegidas, usage strings añadidos al Info.plist incl. discos externos). Migración resumable por directorio de reunión (copy a temp oculto + rename atómico cross-volume; ya-migrado se salta) y resolución con fallback al root por defecto — una migración interrumpida no rompe nada. La DB sigue guardando solo paths relativos (D4). Sobre "aprender acentos localmente": fine-tuning on-device no es viable con estos modelos; el camino real es vocabulario auto-sugerido (minar términos frecuentes de transcripts refinados) — anotado como idea M8.

## Roadmap 2.1 — ronda 2 de análisis (2026-07-07, verificación adversarial)

Segunda pasada con 3 agentes de verificación (Granola/Jamie/Fathom profundo; SpeechAnalyzer/MLX/WhisperKit técnico; Otter/MacParakeet/pricing/OSS-landscape). Correcciones y hallazgos aplicados a DECISIONS (D25-D27 enmendadas, **D28 nueva**), ROADMAP (fase 2 reordenada) y PRODUCT:

- **Corregido**: el free de Otter NO es ilimitado (300 min/mes, tope 30 min/conversación — el más tacaño); SpeechAnalyzer NO es clase-calidad (WER 14% conversacional ≈ whisper-base/small, sin vocabulario custom, sin diarización) → re-posicionado al rol VIVO y a iOS, jamás default de refine.
- **Verificado**: WhisperKit cuantizadas existen (`large-v3-v20240930_547MB`/`_626MB`, la 626 recomendada multilingüe); MLX gana a llama.cpp para LLM embebido (mlx-swift-lm, MIT, SPM nativo, 1.4-1.8x, ~2-2.5GB q4); `bluetoothHighQualityRecording` real pero **no soportado en la UE** + latencia extra; one-time pricing validado como patrón del nicho nativo (MacWhisper €59, VoiceInk $25-49); Argmax OSS SDK v1.0 trae SpeakerKit (diarización) en el paquete que ya usamos.
- **⚠️ Riesgo nuevo a vigilar**: MacParakeet DESCARTÓ process taps porque "no coexisten confiablemente con VPIO in-process" — nuestra combinación exacta D6+D24. 1 reunión OK no es evidencia; vigilar glitches del canal system con AEC activo. Plan B documentado en D27: echo-cancel offline post-grabación.
- **Hallazgo mayor (D28)**: el loop de coautoría de Granola (notas crudas → IA teje; negro=tuyo/gris=IA con links) es el patrón más validado de la categoría ($1.5B) y nuestro `ContextItem` ya lo modela desde M0 — estaba huérfano y sin fecha. Ahora es M10, antes que el Copiloto.
- **Copiloto validado con urgencia**: nadie lo tiene en meeting-notes; Cluely falla (5-10s reales); **Teams "Facilitator" llega ~ago-sep 2026**. Nuestro target <5s local gana al estado del arte real.
- **Fase 2 reordenada**: M9=publicar YA (stars componen: Meetily 20.5K/Anarlog 8.8K/MacParakeet 451 en 5 meses), M10=notas coautoría, M11=audio+crash-safety (CAF/fragmentado — los WAV probablemente no sobreviven kill -9), M12=motores (Ollama primero, MLX después), M13=Copiloto.
- Storage: MacParakeet guarda AAC 64kbps (~10MB vs nuestros 126MB/canal por 22 min) — transcode post-refine en M11.

## Roadmap 2.0 (2026-07-07, investigación de mercado)

Sesión de estrategia: 6 fuentes analizadas (riffado, MacParakeet, humla, Otter, artículo Meetily, Granola) + exploración profunda del repo local de Meetily + intel Apple (SpeechAnalyzer macOS 26, más rápido que Whisper). Resultados:
- **DECISIONS nuevas**: D25 (motores plurales por rol + recomendador por hardware; SpeechAnalyzer como engine de calidad; LLM local GGUF/MLX para Macs sin Apple Intelligence; parámetros de referencia de Meetily), D26 (Copiloto en vivo: detección de preguntas en captions cerradas → tarjeta con respuesta; contexto→RAG local, conocimiento→FM/BYOK con disclosure), D27 (audio first-class: AudioPlaybackKit con player sincronizado, waveform por speaker, clips, −23 LUFS, import de audio externo).
- **ROADMAP reescrito por fases**: Fase 2 = M9 audio / M10 motores / M11 Copiloto / M12 publicación / M13 meeting health; Fase 3 = M14a–d iOS (con presupuestos por dispositivo); Fase 4 = M15 sharing L1 (.portavoz bundle + CKShare) / M16 App Intents / M17 relay L2 / M18 visionOS.
- **docs/IOS.md nuevo**: aterrizaje técnico honesto de iOS (tabla de capturas imposibles vs posibles, auditoría de Kits portables, presupuestos de modelo por dispositivo — Whisper large NO cabe en iPhone → SpeechAnalyzer/small o diferir a Mac, CKSyncEngine, Live Activity por frase cerrada).
- **PRODUCT.md actualizado**: fila Meetily (hueco confirmado: cero chat/Q&A/RAG), Otter movió free a ilimitado + lanzó MCP (valida nuestro moat), MacParakeet ahora 100% gratis, humla cloud $7/mes, sección "UX descrestante (momentos firma)", tabla de performance con columna de medidos.

## Próximos pasos (en orden)

**Verificaciones que aún necesitan al usuario (próxima reunión real):**
- **⚠️ Taps + AEC conviviendo**: vigilar el canal system con AEC activo (glitches, dropouts, silencio) — MacParakeet reporta que VPIO y process taps "no coexisten confiablemente" en el mismo proceso. Si aparece, plan B en D27.
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

## Descubrimientos técnicos

**Migrados a [specs/](specs/README.md) (2026-07-07)** — el conocimiento técnico durable ya no vive en este archivo. Por tema: captura → [specs/01](specs/01-audio-capture.md) · transcripción → [specs/02](specs/02-transcription.md) · diarización/identidad → [specs/03](specs/03-diarization-identity.md) · inteligencia → [specs/04](specs/04-intelligence.md) · storage → [specs/05](specs/05-storage.md) · app/empaquetado → [specs/06](specs/06-app-macos.md) · CLI/MCP → [specs/07](specs/07-interfaces.md) · tests/números/bugs → [specs/08](specs/08-quality.md). Brechas para talla mundial → [GAPS.md](GAPS.md).

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
