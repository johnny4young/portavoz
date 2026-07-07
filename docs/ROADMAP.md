# Roadmap

Each milestone is independently shippable and has a measurable acceptance criterion.

## Fase 1 — Fundación local-first (M0–M6, M8 núcleo) ✅ construida

| Milestone | Scope | Acceptance criterion | Estado |
|---|---|---|---|
| **M0 — Skeleton** | SPM workspace, domain contracts, CI, docs | `swift test` green in CI; `brew`-ready layout | ✅ |
| **M1 — Capture** | Mic + per-app process taps, dual-channel recording, retention policies, AEC (D24), device-change resilience | 30-min recording produces two synced WAVs, drift < 50 ms | ✅ medido: 4 ms |
| **M2 — Transcription** | Parakeet streaming (FluidAudio), slot scheduler, model registry with verified downloads | Live transcript < 2 s latency while a batch file transcribes without degrading it | ✅ p95 0.53 s |
| **M3 — Diarization** | pyannote on system channel, "Me" via mic channel, editable speaker pills, micro-cluster merge | 4-person meeting: DER < 15%, user's turns 100% attributed | ✅ AMI 7.6% |
| **M4 — Intelligence** | Incremental summaries (Foundation Models + BYOK), Recipes v1, bilingual EN/ES output | Structured summary < 30 s after meeting end; Spanish summary of an English meeting with glossary intact | ✅ 3.8 s |
| **M5 — Public 0.1** | StorageKit (FTS5, versioned snapshots), export MD/PDF/Gist, polished UI, DMG+Sparkle+cask firmado y notarizado | Public release: "knows who said what, locally" | ✅ falta publicar |
| **M6 — Identity & language** | Auto speaker naming (LLM + EventKit), voice enrollment, live translated captions | 1-tap speaker→name mapping; live ES↔EN captions | ✅ código; verificación de campo parcial |
| **M8 — Dev moat (núcleo)** | MCP server, GitHub/Linear export, local RAG chat | An MCP agent answers "what did I agree to yesterday?" | ✅ verificado |

## Fase 2 — Talla mundial en la Mac (0.2–0.4)

La fase donde el usuario siente que **nativo vale la pena**. Orden = dependencia técnica.

| Milestone | Scope | Acceptance criterion |
|---|---|---|
| **M9 — Audio first-class (D27)** | AudioPlaybackKit: player sincronizado con transcript (click-para-saltar, highlight en vivo), waveform coloreada por speaker, clips exportables, skip-silencio, velocidad | Reproducir cualquier reunión con highlight sincronizado; exportar un clip de 30 s con atribución en < 2 s |
| **M10 — Motores plurales (D25)** | SpeechAnalyzer como engine de calidad seleccionable; LLM local embebido (GGUF/MLX 3B) para Macs sin Apple Intelligence; recomendador por hardware; overrides por reunión/idioma; `bench` compara engines | Un Mac sin Apple Intelligence produce resumen 100% local; Ajustes muestra "Recomendado para tu Mac" correcto; benchmark reproducible por engine |
| **M11 — Copiloto en vivo (D26)** | Detección de preguntas en captions cerradas + tarjeta de respuesta (FM/RAG local; BYOK opt-in con disclosure); detector "te preguntaron" unificado | Pregunta de conocimiento detectada y respondida en tarjeta < 5 s; preguntas logísticas no generan tarjetas |
| **M12 — Publicación + growth OSS** | Push del repo, release v0.x en GitHub, tap Homebrew, README con benchmarks públicos (patrón MacParakeet), issues templates, SECURITY.md | `brew install --cask portavoz` funciona; benchmarks reproducibles en el README |
| **M13 — Meeting health + polish PRO** | Talk-time, interrupciones, ratio de preguntas (local); Recipes avanzadas; auto-detección de tipo de reunión → Recipe | Panel de salud por reunión; Recipe sugerida correcta en ≥ 3 tipos de reunión |

## Fase 3 — iOS/iPadOS (M14, ex-M7)

Constraint duro D11: iOS no captura audio de otras apps. El iPhone es **grabadora presencial de primera clase + companion**, no un clon de la Mac.

| Milestone | Scope | Acceptance criterion |
|---|---|---|
| **M14a — Proyecto Xcode + Kits portables** | Target iOS; auditar Kits: `#if os(macOS)` en AudioCaptureKit (ScreenCaptureKit/process taps fuera), TranscriptionKit con Parakeet int8 (~483 MB, viable en ANE de iPhone; Whisper large NO — usar SpeechAnalyzer/whisper small para refine móvil), FM disponible en iOS 26 | Los Kits compilan para iOS; grabadora presencial transcribe en vivo en un iPhone 15+ |
| **M14b — Grabadora presencial** | Los 6 modos D11: AirPods studio-quality (`bluetoothHighQualityRecording`), llamadas por altavoz, share extension importadora, BGProcessingTask nocturno (refine con `requiresExternalPower`), degradación térmica | Grabar 1 h presencial con < 10%/h de batería; refine nocturno al enchufar |
| **M14c — Companion + sync** | CKSyncEngine E2E (`encryptedValues`), Live Activity + Dynamic Island (timer + última caption), control remoto de la grabación de la Mac, Handoff | Grabar en iPhone → resumen leíble en la Mac sin abrir la app; Live Activity correcta 30 min |
| **M14d — iPad** | PiP live captions (AVPictureInPictureController sobre Zoom/Meet en Stage Manager), Split View, PencilKit anclado al timeline (ContextFeedKit) | Captions flotantes sobre una llamada real en iPad |

## Fase 4 — Compartir y plataforma (M15+)

| Milestone | Scope | Acceptance criterion |
|---|---|---|
| **M15 — Sharing L1 (D12)** | CKShare de reunión entre Apple IDs (read-only primero); "bundle" exportable `.portavoz` (manifest + sqlite extract + audio opcional) como formato de intercambio offline | Compartir una reunión con otro Apple ID; abrir un bundle en otra Mac |
| **M16 — App Intents / Shortcuts** | Automatizaciones post-reunión (resumen→Notes/mail/Slack vía Shortcuts), auto-grabación por calendario con guardrails, Spotlight/Quick Look | "Cuando termine una reunión del calendario X, exporta el resumen a Y" sin tocar la app |
| **M17 — Sharing L2** | Relay self-hostable (patrón Humla/PocketBase) con visor web read-only de snapshots | Un participante sin la app lee el resumen vía link self-hosted |
| **M18 — visionOS (halo)** | Port SwiftUI de biblioteca+detalle; sala de revisión inmersiva (timeline espacial con clips); sin promesas de captura | Revisar una reunión en Vision Pro con timeline espacial |

Later / investigación: dictado global estilo MacParakeet (reusar pipeline vivo en overlay system-wide), voz sintetizada (Personal Voice + driver virtual, disclosure obligatorio), aprendizaje de vocabulario (minar términos frecuentes de transcripts refinados y sugerirlos), soporte de grabadoras hardware (patrón riffado) si hay demanda.
