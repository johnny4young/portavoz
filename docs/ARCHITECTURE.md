# ARCHITECTURE — Diseño técnico y reglas de ingeniería

## Qué es Portavoz

Asistente de reuniones privacy-first y local-first para plataformas Apple (macOS primero; iOS/iPadOS después; visionOS eventual), escrito nativamente en Swift 6 + SwiftUI. Promesa central: **saber quién dijo qué — incluidas las intervenciones del usuario — sin que el audio salga del dispositivo.** Es el sucesor Swift-nativo de las ideas de Meetily (repo de referencia en `../meetily`; se estudia, jamás se porta su código).

Diferenciadores en orden de prioridad: who-said-what estructural por captura dual-canal, diarización con identidad de voz del usuario, resúmenes bilingües ES/EN y captions traducidos en vivo, integraciones de flujo dev (GitHub/Linear/Jira, servidor MCP local, automatizaciones App Intents), formato de datos abierto (Markdown + SQLite del usuario).

## Workspace SPM (un solo package)

`PortavozCore` contiene los tipos de dominio compartidos; los 8 Kits dependen de Core y **nunca entre sí** (única excepción: `IntegrationsKit → IntelligenceKit`).

| Módulo | Responsabilidad |
|---|---|
| `PortavozCore` | Tipos de dominio: IDs tipados (UUID), `AudioChannel`, `AudioChunk`, `TranscriptSegment`, `Speaker` |
| `ModelStoreKit` | Registry curado (`ModelCatalog`, routing **por tarea** `ModelTask`) + `ModelStore`: descargas verificadas por sha256/commit pineado. Compartido por todos los Kits que cargan modelos |
| `AudioCaptureKit` | Mic (AVAudioEngine) + process taps por app (Core Audio, macOS 14.4+); `RecordingSession` (con tap `onChunk`); `WAVWriter`; políticas de retención |
| `TranscriptionKit` | Protocolo `TranscriptionEngine`; `ParakeetEngine` (vivo sliding window + batch long-form); `TranscriptionScheduler` (slots D7) |
| `DiarizationKit` | `PyannoteDiarizer` (pyannote community-1 + WeSpeaker vía FluidAudio) sobre canales system/room; `SpeakerAttributor` (who-said-what estructural); `Voiceprint` (biométrico: solo on-device, cifrado, nunca sync, borrable) |
| `IntelligenceKit` | `SummaryProvider`: `FoundationModelSummaryProvider` (on-device, map-reduce convergente, D18) + `OpenAICompatibleSummaryProvider` (BYOK, opt-in explícito, jamás default silencioso); Recipes; bilingüe con `targetLanguage` + `glossary` |
| `ContextFeedKit` | Links/notas/snippets con timestamp durante la reunión ("las notas llevan la intención, el transcript los hechos") |
| `StorageKit` | `MeetingStore` sobre GRDB 7 + FTS5 (contrato D4 ejecutado — ver D19): reuniones, transcript, snapshots de resumen versionados, búsqueda full-text, retención de audio. sqlite-vec llega con el RAG (M8) |
| `SyncKit` | CloudKit vía CKSyncEngine (M7). Escalera de compartir: export/Gist → CKShare → relay self-hostable (D12) |
| `IntegrationsKit` | Exporters + Gist + servidor MCP local (solo localhost + token de sesión) |
| `portavoz-cli` | Harness de desarrollo ejecutable (`record --seconds N --pid X --system --out dir`) |

## Diseño del pipeline de audio (M1)

```
MicrophoneSource (AVAudioEngine, formato nativo)  ──┐
ProcessTapSource (tap por PID / global, 14.4+)    ──┤──► AsyncThrowingStream<AudioChunk>
[RoomSource: iPhone vía Continuity — futuro]      ──┘            │
                                                                  ▼
                                        RecordingSession (actor, un consumer por canal)
                                             │ writer perezoso al primer chunk (sample rate real)
                                             ▼
                              microphone.wav / system.wav (WAVWriter → AVAudioFile 16-bit)
```

- Los canales **jamás se mezclan antes de diarizar** (D5): todo lo del mic es del usuario por hardware.
- El chunk lleva `timestamp` en segundos desde el inicio de sesión (`HostClock` sobre host time).
- Drift = |segundos escritos mic − system|; criterio M1: < 50 ms en 30 min.
- Sin FFmpeg: `AVAudioFile` escribe WAV directo desde Float32.

## Pipeline de transcripción (M2)

```
RecordingSession.start(sources:onChunk:)  ── tap por chunk ──► AsyncStream<AudioChunk> por canal
                                                                       │
                     TranscriptionScheduler (D7: slots)                ▼
   live: inmediato ────────────────────────────────► ParakeetEngine.transcribe (SlidingWindowAsrManager,
   batch: FIFO serial, Task.detached(.utility) ───► ParakeetEngine.transcribeFile (AsrManager long-form)
                                                                       │
                                          ParakeetSegmentMapper (deltas por timings absolutos)
                                                                       ▼
                                                     AsyncThrowingStream<TranscriptSegment>
```

- Modelos: `ModelCatalog` (artefactos pineados por sha256 + commit) → `ModelStore` (descarga verificada, `~/Library/Application Support/Portavoz/Models`) → `AsrModels.load` — nunca se carga nada sin verificar (D15).
- Un solo `AsrModels` compartido entre jobs (MLModel es thread-safe); cada job crea su manager con estado de decoder propio.
- Ventana viva custom left 11 / chunk 1.0 / right 0.4 y filtro de overlap propio (D16). Medido: transcript lag p95 0.53 s con batch a ~100x en paralelo.
- Harness: `portavoz-cli bench-m2` reproduce el criterio de aceptación completo.

## Pipeline de diarización y atribución (M3)

```
system.wav / AsyncStream<AudioChunk> ──► PyannoteDiarizer (ventanas 10 s, atTime continuo,
                                          SpeakerManager mantiene S1/S2… entre ventanas)
                                                    │  [SpeakerTurn]
TranscriptSegments (batch: 1 por oración; vivo: ~1 s) ──► SpeakerAttributor
                                                    │
                    mic → "Me" (hardware, D5) · system → turno solapado; multi-turno se parte
                    en los límites de turnos (palabras proporcionales al tiempo) · sin turno → nil
                                                    ▼
                                    transcript atribuido + [Speaker] ("Me" primero)
```

- Threshold de clustering **0.45** (D17) — el default 0.7 de FluidAudio fusiona speakers reales; calibrado contra el sample AMI de pyannote con su RTTM de referencia.
- Los segmentos batch cortan por **puntuación de oración** además de pausas: los timings TDT no traen gaps (fin de token = inicio del siguiente), así que la pausa casi nunca dispara.
- Harness: `portavoz-cli diarize --file x.wav [--attribute] [--threshold t]`.

## Arquitectura para motores plurales y configuraciones (fase 2, D25)

El objetivo: soportar hardware heterogéneo (8 GB sin Apple Intelligence hasta M4 Max) y condiciones de mercado cambiantes (Apple regalando SpeechAnalyzer) sin que ninguna feature dependa de UN modelo concreto.

- **`EngineRole` explícito** en ModelStoreKit: `liveTranscription`, `qualityTranscription`, `summarization`, `embedding`, `diarization`. `ModelCatalog.recommended(for:)` ya rutea por rol — crece a `candidates(for:) -> [ModelDescriptor]` + `recommended(for:hardware:)` con un `HardwareProfile` (chip, RAM, versión de macOS, Apple Intelligence sí/no) leído una vez al arrancar.
- **Protocolos por rol, no por modelo**: `SummaryProvider` ya existe (FM y BYOK lo implementan); igual para transcripción de calidad (`FileTranscriber`: Whisper hoy, SpeechAnalyzer y Parakeet-batch después). Las vistas y el CLI dependen del protocolo; la elección vive en Ajustes + overrides por reunión/idioma.
- **La cadena de fallback es visible**: cada resultado lleva el engine que lo produjo (columna `provenance` en summary/segment cuando toque el schema — aditivo, D4 lo permite); la UI lo muestra en gris ("Resumido on-device" / "Resumido por Ollama·qwen3"). Nada falla en silencio hacia otro proveedor: degradar = informar.
- **Config por capas**: default por hardware → Ajustes global por rol → override por reunión → override por idioma (patrón humla). Persistencia: los global en el marker/UserDefaults de app; los per-meeting en la DB (aditivo).
- **El audio como actor de primera clase (D27)** completa el flujo: capture (AudioCaptureKit) → registro inmutable WAV → playback/clips (AudioPlaybackKit) — el mismo asset alimenta transcripción, diarización, waveform y clips; ningún Kit duplica lectura de audio: `AudioAsset` (PortavozCore) encapsula path+formato+duración+waveform cache.

## Reglas de ingeniería (innegociables)

1. **Privacidad:** ninguna feature envía audio/transcripts fuera del dispositivo sin opt-in explícito y visible. Telemetría opt-in. API keys en Keychain — nunca SQLite ni UserDefaults (anti-patrón heredado de Meetily, que las guarda en SQLite plano).
2. **Higiene de licencias:** Portavoz es MIT. Prohibido copiar código de proyectos GPL — notablemente MacParakeet (GPL-3): valida nuestro stack pero es mirar-sin-tocar. Humla (MIT) y FluidAudio/WhisperKit (MIT/Apache) sí, con atribución.
3. **Swift 6 concurrencia estricta:** actors + `AsyncStream` end-to-end; `@unchecked Sendable` solo con comentario que justifique el confinamiento; sin locks manuales.
4. **Lo vivo nunca espera a lo batch:** transcripción en vivo y trabajo batch (archivos, re-pases) corren en slots separados del scheduler (patrón MacParakeet).
5. **Modelos = código:** toda descarga se verifica contra sha256 pineado antes de cargarse.
6. Conventional Commits (`feat:`, `fix:`, `docs:`…).

## Entorno de desarrollo

```sh
swift build    # compila todos los módulos
swift test     # suite XCTest
```

- Si los tests fallan con "no such module 'XCTest'": la máquina tiene CommandLineTools seleccionado. Correr con `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` o arreglar permanente: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- Targets mínimos: macOS 14.4 (process taps) / iOS 17 (WhisperKit). Features de OS 26 (SpeechAnalyzer, Foundation Models, AirPods studio recording) con degradación elegante.
- CI: `.github/workflows/ci.yml` (macos-latest, build + test).

## Contexto de negocio para decisiones técnicas

Todo open source (MIT). FREE nunca limita minutos/reuniones/historial — la computación local del usuario es gratis. PRO = pago único (conveniencia y poder: sync, integraciones dev, RAG, MCP). Distribución: DMG notarizado + Sparkle + Homebrew cask + venta directa; App Store en iOS. Detalle completo en [PRODUCT.md](PRODUCT.md) y decisiones D9/D10 en [DECISIONS.md](DECISIONS.md).
