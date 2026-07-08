# Spec 08 — Calidad: tests, harnesses y números medidos

Estado: 199 tests de paquete en verde (9 gated) + 2 UI tests XCUITest. CI en GitHub Actions (`.github/workflows/ci.yml`: macos-latest, build + test).

## Suite de tests — `Tests/PortavozTests/`

| Archivo | Cubre |
|---|---|
| AudioCaptureTests | WAVWriter, drift summary, Downmix, **Resample.linear** |
| TranscriptionTests | Mapper/deltas, WhisperEngine helpers, **VocabularyPrompt**, **AudioLevel.normalizePeak** |
| CaptionCoalescerTests | 10 casos del coalescer (merge, identidad, canales, pausas, límites) |
| DiarizationTests | Catálogo, SpeakerAttributor (multi-turno), SanitizeTurns, **MergeMicroClusters** (6), DiarizationEvaluation (unidades) |
| IntelligenceTests | PromptFactory, filtros de naming, **NamingExcerpt**, **LiveSummaryPolicy** |
| StorageTests | Contrato D4 completo (tombstones, versionado, FTS hostil, retención, paths) |
| RecordingsLocationTests | 7: marker, fallback, resolve, migración resumable |
| CoreTypesTests | Tipos + **TitleTemplate** |
| RAGTests / MCPServerTests / VoiceIdentityTests / IntegrationsTests | RAG fusion, protocolo MCP, voiceprint cifrado, exporters offline |
| ParakeetIntegrationTests + gated | Modelos reales — requieren `PORTAVOZ_MODEL_TESTS=1` + `PORTAVOZ_TEST_WAV` / `PORTAVOZ_TEST_CONVERSATION_WAV` / `PORTAVOZ_TEST_ENROLL_WAV` |

Local: `swift test` (si falla con "no such module": `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` — xcode-select apunta a CommandLineTools). XCTest, no Swift Testing (D13).

## UI tests — `Tests/PortavozUITests/` (`make test-ui`, D30)

XCUITest sobre la app real (XcodeGen genera el `.xcodeproj`, gitignored). Verifica la UI por automatización en vez de conducir la pantalla. Launch-args: `-use-temp-store` (DB desechable) + `-seed-demo` (reunión determinística con transcript, resumen y bullet "▸" de coautoría). Cubre: `LibraryUITests` (la biblioteca renderiza) y `MeetingDetailUITests` (transcript + resumen + marca ▸ de coautoría D28).

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
| Cold start / RAM grabando / FTS a 1k reuniones | 1.5 s / 500 MB / 50 ms | **pendiente** — falta `bench` suite (M9) |

## Bugs reales encontrados y corregidos (los que un agente debe conocer)

| Bug | Causa raíz | Fix |
|---|---|---|
| Reunión colapsó 66→3 segmentos en refine | WhisperKit `concurrentWorkerCount` default 16 → carrera sobre decoder compartido; su chunker TRAGA errores por chunk | `concurrentWorkerCount: 1` + retry de cobertura |
| Colapso determinístico con vocabulario | promptTokens descarrilan ventanas que no mencionan los términos; cobertura cruda engañaba (spans válidos, texto vacío) | cobertura sobre segmentos LIMPIOS + retry sin prompt + frase natural |
| Reunión silenciosa "sin voz" | EnergyVAD de WhisperKit umbral absoluto 0.02 | peak-normalize previo |
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
