# PRODUCT — Visión, mercado y features

## La promesa (una sola, para el lanzamiento)

> **"Graba tu reunión y sabe quién dijo qué — incluido tú — sin que nada salga de tu Mac."**

Todo lo demás llega por versiones. La disciplina del proyecto es no diluir esta promesa antes de M5.

## Posicionamiento

Nadie en el mercado combina estos 6 atributos; cada competidor tiene ~2:

1. **Local-first real** (transcripción + diarización + resumen on-device)
2. **Identidad del hablante** (quién dijo qué + cuáles intervenciones son del usuario)
3. **Features para developers** (issues, ADRs, MCP, Shortcuts)
4. **Bilingüe ES/EN profundo** (resúmenes cruzados, glosario técnico, captions traducidos)
5. **Pago único** (vs suscripciones de $8–19/usuario/mes de todo el mercado)
6. **Open source** (MIT)

Usuario fundador y arquetipo: dev hispanohablante con reuniones en inglés.

## Mapa competitivo (jul 2026) y qué se incorporó de cada uno

| Competidor | Modelo | Qué le robamos |
|---|---|---|
| Granola ($14–35/u/mes, free 25 notas) | Cloud, sin bot, Mac+iOS | Recipes (plantillas que reestructuran), UX "notas manuales + IA completa", soporte MCP (validación de demanda) |
| Fathom (free ilimitado; team $19) | Cloud, bot | El estándar de generosidad FREE; target resumen < 30 s post-llamada |
| Fireflies ($10–19) | Cloud, bot | Chat RAG sobre historial ("Global Brain") — nuestra versión: 100% local |
| tl;dv (free ilimitado; $18+) | Cloud, bot | Clips/momentos compartibles con link al instante |
| Otter ($16.99, free 300 min) | Cloud, bot | Contraejemplo: free tacaño mata el crecimiento |
| Anarlog (ex-Hyprnote/Char; free local + $8/mes) | **OSS local (Tauri)** | Data ownership: cada reunión un .md del usuario; BYOK. Lección: pivotó de OSS puro → el trono "open source local" está vacante |
| MacWhisper (€59 único) / superwhisper ($249 lifetime) | Nativo Mac | El modelo de negocio completo (D9/D10) |
| Krisp | Audio bot-free | **Live Interpreter** → nuestros captions traducidos ES↔EN on-device (Translation framework) |
| Jamie | Nativo bot-free, GDPR | Sidebar de Q&A en vivo sobre la reunión en curso |
| Circleback | Action items | Distribución de action items a la persona correcta; automatizaciones post-reunión → App Intents |
| MeetGeek | Templates/agentes | Auto-detección del tipo de reunión → Recipe automática; reglas de auto-grabación con guardrails |
| Read.ai | Coaching | "Meeting health" local: talk-time, interrupciones, ratio de preguntas (PRO) |
| Gemini en Meet | Plataforma | Resumen adjunto al evento del calendario (EventKit) + borrador de email recap |
| MacParakeet (GPL, Swift) | OSS dictado | Scheduler de slots, pipeline determinístico de limpieza <1 ms, políticas de retención, Homebrew+Sparkle, benchmarks públicos en README. **Solo patrones, jamás código (GPL)** |
| Humla (MIT, Tauri+sidecars Swift) | OSS meetings | Dual-stream capture, pyannote community-1 + Sortformer, routing por idioma, override de idioma por nota, pills de hablante editables, "notas=intención + transcript=hechos", PocketBase opcional |
| Riffado (AGPL) | Companion Plaud | AES-256-GCM at rest, webhooks firmados, backup/restore unificado |

**Amenazas estructurales y defensa:** (1) IA de plataforma (Zoom AI Companion, Teams Copilot, Gemini) — enjauladas por plataforma y suscripción, sin biblioteca cross-plataforma, cero privacidad → nuestra biblioteca única local es la respuesta. (2) Sherlocking de Apple (Notes ya graba/transcribe/resume on-device) — el piso del OS sube cada año; regla: ninguna feature core puede ser algo que Apple obviamente hará "básico" en 1–2 años. Vivimos encima del piso: identidad del hablante, flujo dev, bilingüe profundo, RAG.

## FREE vs PRO (pago único ~$69, lanzamiento $49)

| | FREE (para siempre) | PRO |
|---|---|---|
| Grabación/transcripción/diarización ilimitadas locales | ✅ | ✅ |
| Resúmenes (modelos locales + BYOK) | ✅ | ✅ + Recipes avanzadas |
| "Tú vs. otros" (canal mic) | ✅ | ✅ |
| Enrollment de voz + nombres automáticos | — | ✅ |
| Export MD/Obsidian/Gist, búsqueda FTS | ✅ | ✅ |
| Resumen bilingüe con glosario | ✅ básico | ✅ + "¿qué me perdí?" en vivo |
| Captions traducidos en vivo | ✅ básico | ✅ continuo |
| Sync multi-dispositivo (CloudKit) | — | ✅ |
| Chat RAG sobre historial | — | ✅ |
| GitHub/Linear/Jira export, ADRs | — | ✅ |
| Servidor MCP local | — | ✅ |
| Clips (marcar / exportar) | marcar | exportar |
| Automatizaciones App Intents post-reunión | — | ✅ |
| Meeting health (talk-time, interrupciones) | — | ✅ |
| Watch "te mencionaron" + PiP captions iPad | — | ✅ |

## Features por plataforma

**macOS (producto principal):** taps por app; iPhone como mic de sala vía Continuity (reuniones híbridas: 3 canales); Foundation Models para resúmenes; menu bar + panel flotante de transcript; App Intents/Shortcuts + auto-grabación por calendario (EventKit); Core Spotlight; widgets; Focus filters; Handoff; Quick Look; CLI + XPC.

**iOS (grabadora presencial + companion):** los 6 modos de D11. Destacados: AirPods studio-quality (iOS 26 `bluetoothHighQualityRecording`); Live Activity + Dynamic Island; Siri/App Intents; share extension; CKSyncEngine E2E; control remoto de la grabación de la Mac; BGProcessingTask nocturno; degradación térmica (`ProcessInfo.thermalState`).

**iPadOS:** PiP live captions (AVPictureInPictureController renderizando transcript como video — subtítulos flotantes sobre Zoom en Stage Manager, componible con traducción); canvas PencilKit anclado al timeline (manuscritos → feed de contexto); Split View junto a la app de meeting.

**visionOS (halo, fase tardía):** port SwiftUI barato; sala de revisión inmersiva (timeline espacial); grabadora presencial premium. Sin promesas de captura (mismo constraint que iOS).

**Apple Watch:** control remoto + haptic "te mencionaron" con la pregunta transcrita.

## Caso de uso fundador: bilingüe ES/EN

- Transcripción en inglés + resumen en español simultáneos (flujo por defecto configurable).
- Glosario técnico que conserva anglicismos (`deploy`, `PR`, `rollback`) — jamás "solicitud de extracción".
- Vocabulario de dominio como initial_prompt (nombres de servicios/compañeros).
- "¿Qué me perdí?": catch-up de los últimos N minutos en español, en vivo.
- Detector de "te preguntaron algo" (nombre mencionado → notificación con la pregunta).
- Captions traducidos en vivo ES↔EN (Translation framework, on-device; parciales en idioma original, traducción al finalizar cada segmento).

## Futuro (investigación, no comprometido)

- **Feed de contexto** (ContextFeedKit ya existe): links/notas/stack traces con timestamp que enriquecen el resumen.
- **Voz sintetizada**: Personal Voice de Apple (iOS 17+) para hablar por el usuario; requiere driver de audio virtual (micrófono virtual) en macOS + disclosure obligatorio a los participantes. Fase 4+.

## Targets de performance (talla mundial = números)

| Métrica | Target |
|---|---|
| Latencia transcript en vivo | < 2 s |
| Resumen post-reunión | < 30 s (resumen incremental durante la reunión) |
| Cold start | < 1.5 s |
| RAM grabando (Mac, STT cargado) | < 500 MB |
| Batería (iPhone, STT en vivo) | < 10%/hora (ANE) |
| Búsqueda en 1,000 reuniones | < 50 ms (FTS5) |
| Drift mic/system | < 50 ms en 30 min |
| DER diarización (4 hablantes) | < 15%; intervenciones del usuario 100% |

## Seguridad (compromisos)

Keychain para secretos; `NSFileProtectionComplete` (iOS) / SQLCipher opcional (macOS); voiceprints solo on-device y borrables; CloudKit `encryptedValues` (+ADP); sha256 pineado en modelos; App Sandbox + Hardened Runtime + notarización; MCP solo localhost+token; telemetría opt-in; disclosure de grabación con presets por jurisdicción; SPM pineado + releases firmados + SECURITY.md.
