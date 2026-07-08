# Roadmap

Each milestone is independently shippable and has a measurable acceptance criterion.

## Estado actual y siguiente paso (jul 2026)

Fuente única del progreso — antes vivía en un HANDOFF de sesión; ahora el estado se lee aquí, las decisiones en [DECISIONS.md](DECISIONS.md), lo as-built en [specs/](specs/README.md) y las brechas + verificación de campo en [GAPS.md](GAPS.md).

- **Fase 1 (M0–M6, M8 núcleo): construida y medida en verde** — todos los criterios de aceptación cumplidos (drift 4 ms, lag p95 0.53 s, DER AMI 7.6%, resumen 3.8 s). 0.1.0 firmada + notarizada, usada en 4 reuniones reales.
- **Fase 2: el NÚCLEO de M10, M12 y M13 ya está implementado y testeado** (jul 2026, día Fable) — notas de coautoría (tejido notas→resumen), caché por fingerprint + pivote de traducción, BYOK, y el Companion en vivo completo (detección + routing + BYOK + "te preguntaron"), todo sobre el scheduler de prioridad D29. Lo que falta de cada uno está en su fila abajo.
- **Siguiente paso concreto → M9 (publicación)**, la única brecha de impacto 1 (GAPS #1) y bloqueante de crecimiento. La **preparación interna ya está hecha** (jul 2026): README con benchmarks reproducibles ✅, SwiftLint (config calibrada + job de CI) ✅, issue/PR templates ✅, SECURITY.md/LICENSE/CONTRIBUTING ✅. Lo que **falta** es: (a) la **localización EN** (String Catalogs / `.lproj`, GAPS #5 — diferida a justo antes de publicar; enfoque decidido: `.lproj/Localizable.strings` copiados por `make-app.sh` a `Contents/Resources` con lookup por `Bundle.main`, sin tocar los ~145 `Text`); (b) las **acciones públicas irreversibles** que requieren tu autorización explícita: `git push` a `git@github.com:johnny4young/portavoz.git`, `gh release create v0.1.0 dist/release/*`, y el tap `johnny4young/homebrew-portavoz` con `dist/release/portavoz.rb`.
- **Verificación de campo pendiente** (features hechas, criterio final con el usuario): lista en [GAPS.md](GAPS.md#verificación-de-campo-pendiente).
- **Deuda menor viva**: FluidAudio pineado a revisión → volver a `.upToNextMinor` cuando salga > 0.15.4 (GAPS T9); política de micro-clusters de diarización a evaluar contra el RTTM corregido; `meetings refine` podría aceptar `--threshold`.

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

La fase donde el usuario siente que **nativo vale la pena**. Reordenada tras la ronda 2 de análisis: publicar PRIMERO (los stars componen: Meetily 20.5K, Anarlog 8.8K, MacParakeet 451 en 5 meses — cada mes privado es crecimiento regalado), y las notas de coautoría (D28) entran antes que el Companion porque son el patrón más validado de la categoría.

| Milestone | Scope | Acceptance criterion |
|---|---|---|
| **M9 — Publicación + growth OSS** | **Prep interna hecha (jul 2026)**: README con tabla de benchmarks reproducibles (latencia viva p95, Whisper 23–42×, DER AMI 7.6%, resumen 3.8 s, drift 4 ms — con el comando del CLI para reproducir cada uno + tabla de modelos con disco/RAM), SwiftLint (`.swiftlint.yml` a cero errores + job `lint` en CI), issue/PR templates, SECURITY.md. **Falta**: localización EN (diferida a pre-publicación, GAPS #5) + push del repo, release v0.1 en GitHub y tap Homebrew (acciones públicas — requieren autorización del usuario) | `brew install --cask portavoz` funciona; benchmarks reproducibles en el README |
| **M10 — Notas de coautoría (D28)** | **Implementado (jul 2026)**: ContextItem en Core, tabla v3, tejido notas→prompt con presupuesto del 3B, convención "▸" de coautoría, `addContextNote()` + persistencia + regenerate; **panel de notas en grabación** (TextField + lista timestampeada con quitar, columna derecha) y **render de coautoría** en el detalle (bullets "▸" con marca de acento estilo Granola). Falta: verificación de campo (5 notas reales → resumen que las expande) | Una reunión con 5 notas crudas produce un resumen que las expande sin contradecirlas, con marcas de coautoría |
| **M11 — Audio first-class (D27)** | **Completo (jul 2026)**: AudioPlaybackKit con player sincronizado (transcript carrusel estilo Spotify en detalle y grabación), waveform coloreado por canal, clips (in/out → m4a < 2 s), **skip-silencio**, **transcode AAC** ("Comprimir audio") e **import** (botón + drag-drop → transcribe/diariza/resume). Crash-safety (CAF) ya resuelto (T1). Cubierto por XCUITest (D30) | Reproducir cualquier reunión con highlight sincronizado ✅; un `kill -9` a los 30 min no pierde más de 1 s de audio ✅ (CAF); clip de 30 s exportado en < 2 s ✅ |
| **M12 — Motores plurales (D25)** | **Implementado (jul 2026): (1) caché de resumen por fingerprint + pivote de traducción; (2) BYOK con key en Keychain; (3) SpeechAnalyzer benchmarkeado en el rol vivo vs Parakeet (spec 02); (4) Ollama de primera clase como motor de resúmenes (Ajustes → detecta + lista modelos + resume 100% local sin key — cierra GAPS #7, verificado E2E gpt-oss:20b); (5) recomendador por hardware ("Recomendado para tu Mac"); (6) variante Whisper compacta de 626 MB para poco disco (Ajustes → toggle; el recomendador la activa si detecta poco disco; artefactos sha256-pineados, D7); (7) override de motor+idioma por reunión (menú "Regenerar" del detalle: idioma es/en + motor alternativo Apple↔Ollama, solo el no-default y solo si es usable — `configuredSummaryProvider(override:)`).** Falta: MLX embebido (cero-dependencias, fase posterior); decisión append-vs-replace del coalescer (SpeechAnalyzer, requiere verificación de campo) | Un Mac sin Apple Intelligence produce resumen 100% local (vía Ollama guiado o MLX); "Recomendado para tu Mac" correcto; `bench` compara engines |
| **M13 — Companion en vivo (D26)** | **Núcleo implementado (jul 2026)**: heurística+clasificador FM+routing knowledge/context/logistics, tarjetas con copiar/descartar, toggle por grabación, sobre el scheduler D29. BYOK para knowledge implementado (opt-in D8, disclosure por tarjeta, fallback on-device). Detector "te preguntaron" unificado (gate de nombre determinístico + ping naranja). Falta: verificación de campo del presupuesto <5 s. **Ventana competitiva: Teams Facilitator ~ago-sep 2026** | Pregunta de conocimiento → tarjeta < 5 s (Cluely real: 5–10 s); preguntas logísticas no generan tarjetas |
| **M13b — Meeting health + Recipes** | Talk-time, interrupciones, ratio de preguntas (local); Recipes avanzadas; auto-detección de tipo de reunión → Recipe; brief pre-reunión desde calendario (patrón Granola Briefs) | Panel de salud por reunión; Recipe sugerida correcta en ≥ 3 tipos de reunión |

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

Later / investigación: dictado global estilo MacParakeet (reusar pipeline vivo en overlay system-wide), voz sintetizada (Personal Voice + driver virtual, disclosure obligatorio), aprendizaje de vocabulario (minar términos frecuentes de transcripts refinados y sugerirlos), soporte de grabadoras hardware (patrón riffado) si hay demanda, **naming de speakers por voiceprint cross-meeting** (pedido de campo jul 2026: recordar la voz de un participante entre reuniones para autosugerir su nombre — hoy el voiceprint existe pero solo para "Me", D21; extenderlo a otros speakers es factible reusando el embedding de WeSpeaker, con caveat biométrico fuerte D8: on-device, nunca sync, borrable, y consentimiento — guardar la huella de voz de terceros es más sensible que la propia).
