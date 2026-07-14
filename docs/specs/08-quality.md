# Spec 08 — Calidad: tests, harnesses y números medidos

Estado: 401 tests de paquete en verde (13 gated) + 15 UI tests XCUITest. CI en GitHub Actions (`.github/workflows/ci.yml`: macos-latest, build + test + **SwiftLint `--strict`**).

**SwiftLint (`.swiftlint.yml`, `strict: true`)**: config recomendada de industria (reglas por defecto + opt-in de correctness/claridad, umbrales de industria: line 120, function-body 60/100, cyclomatic 12/20, type-body 400/600). `swiftlint lint --strict` pasa con **cero violaciones** sobre `Sources`; en CI cualquier violación rompe el build. Excepciones inherentes silenciadas in-line con justificación (datos sha256 del catálogo, dispatchers arg-parser del CLI, vistas SwiftUI grandes) — partir esas vistas queda como deuda técnica.

## Suite de tests — `Tests/PortavozTests/`

| Archivo | Cubre |
|---|---|
| AudioCaptureTests | CaptureFileWriter CAF, drift summary, Downmix, **Resample.linear**, startup cleanup |
| AudioProcessCatalogTests | scope por bundle ID del tap directo: app exacta/helpers permitidos, lookalikes y apps ajenas rechazados |
| TranscriptionTests | Mapper/deltas, WhisperEngine helpers, higiene anti-silencio, **SpokenLanguageDetector**, **VocabularyPrompt**, **AudioLevel.normalizePeak** |
| CaptionCoalescerTests | 13 casos del coalescer (merge, identidad, canales, pausas, límites, puntuación suelta, split temprano de `system` tras oración) |
| DiarizationTests | Catálogo, SpeakerAttributor (multi-turno), SanitizeTurns, **MergeMicroClusters** (6), DiarizationEvaluation (unidades), streaming vivo (gated) |
| LiveSpeakerLabelerTests | 7 casos: split de fila con dos voces, última fila intocable, idempotencia, mic nunca re-etiquetado, "Me" por voiceprint |
| IntelligenceTests | PromptFactory, filtros de naming, **NamingExcerpt**, **LiveSummaryPolicy** |
| ChapterExtractorTests / TranscriptNoiseFilterTests | boundaries/labels de capítulos y filtrado conservador de fragmentos sin perder frases/acrónimos |
| MeetingBundleTests | round-trip/remap de texto, audio, notas y Companion cards; compatibilidad aditiva del format v1 |
| MeetingHealthTests | 6 casos: talk-time/share, preguntas ES/EN, interrupciones con umbral, monólogos encadenados, sin atribuir excluidos |
| VocabularyMinerTests | 6 casos: formas de dominio, umbral de recurrencia, exclusión de vocabulario existente/stoplist, heurísticas de forma |
| MeetingTypeDetectorTests | catálogo de Recipes + excerpt capado; gated: clasifica standup/planning/interview y deja general en paz (criterio M13b) |
| StorageTests | Contrato D4 completo (tombstones, versionado, FTS hostil, retención, paths) |
| RecordingsLocationTests | 7: marker, fallback, resolve, migración resumable |
| CoreTypesTests | Tipos + **TitleTemplate** |
| LocalizationTests / EnglishSourceTests | String Catalogs EN/ES, placeholders, export `.lproj`, higiene de source público en inglés (README/top-level tooling, scripts, `.github`, packaging, app source) |
| RAGTests / MCPServerTests / VoiceIdentityTests / IntegrationsTests | RAG fusion, protocolo MCP, voiceprint cifrado, exporters offline |
| ParakeetIntegrationTests + gated | Modelos reales — requieren `PORTAVOZ_MODEL_TESTS=1` + `PORTAVOZ_TEST_WAV` / `PORTAVOZ_TEST_CONVERSATION_WAV` / `PORTAVOZ_TEST_ENROLL_WAV` |

Local: `swift test` (si falla con "no such module": `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — xcode-select apunta a CommandLineTools). XCTest, no Swift Testing (D13).

## UI tests — `Tests/PortavozUITests/` (`make test-ui`, D30)

XCUITest sobre la app real (XcodeGen genera el `.xcodeproj`, gitignored). `make test-ui` hace preflight: cierra una instancia previa de Portavoz y advierte si Gancho está corriendo, porque XCUITest de macOS puede fallar antes de ejecutar tests con `Timed out while enabling automation mode` o ventanas interruptoras. Verifica la UI por automatización en vez de conducir la pantalla. Launch-args: `-NSTreatUnknownArgumentsAsOpen NO`, `-ApplePersistenceIgnoreState YES`, `-use-temp-store` (DB desechable; Settings no toca Keychain real), `-seed-demo` (reunión determinística con transcript, resumen, bullet "▸" de coautoría y **audio**) y `-portavoz-open-settings` (sheet determinística de Settings para automation). El audio se aísla con la env `PORTAVOZ_AUDIO_ROOT`; el seed sintetiza un clip de dos tonos (mic/system) o adopta una grabación real dejada en la raíz — apunta `PORTAVOZ_TEST_AUDIO_ROOT` a una copia real para ejercitar el player sobre audio de verdad. Cubre 15 casos en `LibraryUITests`, `InsightsUITests`, `OnboardingUITests`, `MeetingDetailUITests` y `SettingsUITests`: biblioteca y agrupación, heatmap/interlocutores, primera escucha, resumen/transcript/player/rail/clip, navegación de Settings, estructuras custom, captura de audio, mirror y locale en vivo. `make test-ui-en` y `make test-ui-es` fuerzan `-AppleLanguages`/`-AppleLocale`. El export en sí (`AudioClipExporter`) se prueba como unit test — un clip de 15 s de un fuente de 30 s exporta a m4a en fracción de segundo (holgado bajo el criterio < 2 s de M11).

## Harnesses de medición

- `bench-m2`: lag de transcript vivo (p50/p95/max) con batch concurrente.
- `portavoz-cli der`: DER contra RTTM de referencia (fixture pública: sample.wav/rttm de pyannote).
- `scripts/verify_drift.py`: drift por correlación de envolventes (±5 s, warning de borde, multi-punto).

## Números medidos (MacBook Pro M4 Max 36 GB, macOS 26, jul 2026)

| Métrica | Target | Medido |
|---|---|---|
| Lag transcript vivo | < 2 s | **p50 0.24 / p95 0.53 / max 0.56 s** |
| Batch Parakeet | — | ~100x tiempo real (18 pasadas sin degradar lo vivo) |
| Refine Whisper (22 min reales) | > 15x | **23–42x** (1314 s en 31–56 s) |
| Drift mic/system | < 50 ms / 30 min | **4 ms / 22 min** (+4 ppm lineal) |
| DER (AMI 2 speakers) | < 15% | **7.6%** (collar 0.25 s) |
| Resumen ES de reunión EN | < 30 s | **3.8 s** (glosario intacto) |
| Convergencia AEC | — | **~2 s** (por eso el warm-up) |
| Cold start | < 1.5 s | **0.94 s frío / ~0.26 s tibio** (`--bench-startup`) |
| FTS a 1k reuniones (80k segmentos) | < 50 ms | **p50 22.8 ms / p95 23.9 ms** (`portavoz-cli bench-fts`) |
| RAM por fases (`--bench-record 60 --bench-log <file>`, vía `open -n`) | < 800 MB pico grabando / < 200 MB idle post-reunión | **20 MB sin modelos → ~515 MB engines cargados → 569–795 MB pico grabando (diarización EN VIVO incluida) → 140–160 MB tras la reunión**. El target original (500 MB) se fijó antes de sumar la diarización en vivo; revisado jul 2026 |
| RAM del resumen embebido (MLX) | transitoria, no residente | **~2.4 GB durante la generación**; `MLXModelCache` la libera solo tras 120 s idle (antes quedaba residente para siempre) |

## Bugs reales encontrados y corregidos (los que un agente debe conocer)

| Bug | Causa raíz | Fix |
|---|---|---|
| Reunión colapsó 66→3 segmentos en refine | WhisperKit `concurrentWorkerCount` default 16 → carrera sobre decoder compartido; su chunker TRAGA errores por chunk | `concurrentWorkerCount: 1` + retry de cobertura |
| Colapso determinístico con vocabulario | promptTokens descarrilan ventanas que no mencionan los términos; cobertura cruda engañaba (spans válidos, texto vacío) | cobertura sobre segmentos LIMPIOS + retry sin prompt + frase natural |
| Reunión silenciosa "sin voz" | EnergyVAD de WhisperKit umbral absoluto 0.02 | peak-normalize previo |
| `Yo: .` y `Me: Thank you.` repetido sin hablar | Deltas de puntuación suelta y boilerplate de silencio de Whisper en cadencia VAD | higiene léxica + filtro de boilerplate repetido en mic |
| Mic murió al conectar audífonos (min 24/30) | AVAudioEngine se detiene en config-change, stream mudo | restart + resample + gap de silencio |
| "Yo" fantasma con parlantes | mic captaba el system audio (100% eco; dedup por texto solo cubría 57%) | AEC VPIO por defecto (D24) |
| Drift falso 115 ms | offset real 2.4 s fuera del rango ±2 s del script | rango ±5 s + warning de borde |
| Rename de speaker no guardaba | alert-dismiss nileaba el estado antes del Task | capturar valores al tap |
| "Sugerir nombres" desbordaba contexto | prefix ciego + schema + asistentes > 4096 tokens | NamingExcerpt dirigido + retry a la mitad |
| Speakers fusionados (AMI) | threshold ×1.2 interno (0.7→0.84) | 0.45 calibrado contra RTTM real |
| 11 speakers donde había 4 | fragmentación por codecs remotos; threshold no puede subir (0.50 rompe AMI) | mergeMicroClusters < 15 s |

## Fixtures de audio para pruebas

`say -o x.aiff` + `afconvert -f WAVE -d LEI16@16000 -c 1` genera voz sintética; `afplay` por parlantes al mic hace un loop acústico E2E real. **Jamás calibrar diarización con TTS** (spec 03). El Python de python.org no tiene certificados SSL — usar `curl` en scripts.

## Cómo medir antes de afirmar (regla)

Ningún número entra a un spec sin harness reproducible. Si un claim viene de un tercero (benchmark de Apple, WER de Argmax), se cita la fuente y se marca "no medido aquí".

## Flakes conocidos

**Flake de entorno — automation mode (jul 2026):** `make test-ui` falla con
"Timed out while enabling automation mode" (0 tests ejecutados) cuando hay
OTRA sesión de automatización/accessibility activa en la máquina — observado
con la sesión de computer-use de un agente: 3 intentos consecutivos fallaron
en init y el mismo código pasó 7/7 en un ciclo sin esa sesión. No es fallo de
código: correr los UITests sin clientes de automatización concurrentes.
