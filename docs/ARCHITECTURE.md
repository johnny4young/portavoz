# ARCHITECTURE — Diseño técnico y reglas de ingeniería

## Qué es Portavoz

Asistente de reuniones privacy-first y local-first para plataformas Apple (macOS primero; iOS/iPadOS después; visionOS eventual), escrito nativamente en Swift 6 + SwiftUI. Promesa central: **saber quién dijo qué — incluidas las intervenciones del usuario — sin que el audio salga del dispositivo.** Es el sucesor Swift-nativo de las ideas de Meetily (repo de referencia en `../meetily`; se estudia, jamás se porta su código).

Diferenciadores en orden de prioridad: who-said-what estructural por captura dual-canal, diarización con identidad de voz del usuario, resúmenes bilingües ES/EN y captions traducidos en vivo, integraciones de flujo dev (GitHub/Linear/Jira, servidor MCP local, automatizaciones App Intents), formato de datos abierto (Markdown + SQLite del usuario).

## Workspace SPM (un solo package)

`PortavozCore` contiene los tipos de dominio compartidos; los 8 Kits dependen de Core y **nunca entre sí** (única excepción: `IntegrationsKit → IntelligenceKit`).

| Módulo | Responsabilidad |
|---|---|
| `PortavozCore` | Tipos de dominio: IDs tipados (UUID), `AudioChannel`, `AudioChunk`, `TranscriptSegment`, `Speaker` |
| `AudioCaptureKit` | Mic (AVAudioEngine) + process taps por app (Core Audio, macOS 14.4+); `RecordingSession`; `WAVWriter`; políticas de retención |
| `TranscriptionKit` | Protocolo `TranscriptionEngine`; routing de modelos **por tarea** (`ModelTask`), nunca un modelo global; registry con sha256 + revisión pineados |
| `DiarizationKit` | pyannote community-1 vía FluidAudio (alternativa Sortformer) sobre canales system/room; `Voiceprint` (biométrico: solo on-device, cifrado, nunca sync, borrable) |
| `IntelligenceKit` | `SummaryProvider`: Foundation Models (default), MLX local, BYOK cloud (opt-in explícito, jamás default silencioso); Recipes; `SummaryRequest` con `targetLanguage` + `glossary` (bilingüe) |
| `ContextFeedKit` | Links/notas/snippets con timestamp durante la reunión ("las notas llevan la intención, el transcript los hechos") |
| `StorageKit` | GRDB + FTS5 + sqlite-vec (llega en M1+; M0 sin deps). Contrato de schema congelado — ver D4 en [DECISIONS.md](DECISIONS.md) |
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
