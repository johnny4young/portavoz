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
| Granola ($1.5B valuación, Serie C $125M mar-2026; free = notas ilimitadas pero historial de ~30 días — **monetiza el ARCHIVO**) | Cloud, sin bot, Mac+iOS+Android | El loop de coautoría (D28): notas crudas → IA teje con transcript, **tus líneas en negro / adiciones IA en gris con link al segmento**; Templates (~29) ≠ Recipes (prompts guardados post-hoc con `/`); Briefs pre-reunión desde calendario; share links públicos sin login con búsqueda en transcript; iOS graba desde Lock Screen. **Sus críticas #1 = nuestro plan**: sin speaker ID, sin playback de audio, consent — D21+D27+D8. Y su palanca de monetización (rehén del archivo) es imposible para nosotros = argumento de venta |
| Fathom (free: captura ILIMITADA pero IA capada a 5 llamadas/mes desde 2026; $16–25 anual) | Cloud, bot | Regala la captura y cobra la INTELIGENCIA (patrón inverso a Granola); target resumen < 30 s post-llamada |
| Fireflies ($10–19) | Cloud, bot | Chat RAG sobre historial ("Global Brain") — nuestra versión: 100% local |
| tl;dv (free ilimitado; $18+) | Cloud, bot | Clips/momentos compartibles con link al instante |
| Otter ($100M ARR; free VERIFICADO: 300 min/mes, tope 30 min/conversación, 3 imports de por vida) | Cloud, bot→agente sin bot | **Lanzó servidor MCP para ChatGPT/Claude** — valida nuestro moat M8. Su free sigue siendo el más tacaño de la categoría (corregido en ronda 2: el "unlimited" de su home es solo el plan Business) |
| Anarlog (ex-Hyprnote/Char; free local + $8/mes) | **OSS local (Tauri)** | Data ownership: cada reunión un .md del usuario; BYOK. Lección: pivotó de OSS puro → el trono "open source local" está vacante |
| MacWhisper (€59 único) / superwhisper ($249 lifetime) | Nativo Mac | El modelo de negocio completo (D9/D10) |
| Krisp | Audio bot-free | **Live Interpreter** → nuestros captions traducidos ES↔EN on-device (Translation framework) |
| Jamie (€0–39/mes; alemán, hosting EU) | Nativo bot-free, **cloud** (su "privacy" = soberanía EU, NO local) | **Sidebar ⌘J system-wide** ("Spotlight de reuniones": busca en todo el historial desde cualquier app — idea para nuestro ⌘K global); elección de modelo por tarea (validación de D25); es pull manual — sin detección de preguntas |
| Cluely ($20–75/mes) + interview copilots + **Teams "Facilitator" (~ago-sep 2026)** | Overlays de respuesta en vivo | El patrón del Copiloto D26 SIN dueño en meeting-notes: Cluely promete 300 ms y entrega 5–10 s reales + estigma "cheating"; Microsoft valida la detección proactiva de preguntas y pone fecha límite competitiva; los interview copilots (~$9/mes) prueban la demanda. Nuestro ángulo: local (latencia real), transparente, y `contexto` responde desde TU historial |
| Circleback | Action items | Distribución de action items a la persona correcta; automatizaciones post-reunión → App Intents |
| MeetGeek | Templates/agentes | Auto-detección del tipo de reunión → Recipe automática; reglas de auto-grabación con guardrails |
| Read.ai | Coaching | "Meeting health" local: talk-time, interrupciones, ratio de preguntas (PRO) |
| Gemini en Meet | Plataforma | Resumen adjunto al evento del calendario (EventKit) + borrador de email recap |
| MacParakeet (GPL, Swift; **ahora 100% gratis, sin tier pago**) | OSS dictado+meetings | Scheduler de slots, retención, Homebrew+Sparkle, benchmarks públicos ("155x realtime") en README; **modo dictado system-wide por hotkey** (superficie que nos falta); "Ask" en vivo sobre la reunión; 98 idiomas con dual-engine Parakeet+WhisperKit (25+73). **Solo patrones, jamás código (GPL)** |
| Meetily v0.4 (MIT, Rust+Tauri; PRO cloud en camino) | OSS local cross-platform | 7 proveedores LLM incl. **sidecar llama.cpp propio** (qwen3.5 2b/4b GGUF); recomendador: RAM ≥14 GB → 4b, sino 2b; catálogo Whisper **con variantes q5 (turbo 547 MB)** + Parakeet ONNX; **resumen EN cacheado → re-traducción sin re-generar** (directo a nuestro core ES/EN); caché de resumen por fingerprint (transcript+prompt+template+modelo); plantillas JSON validables con action items citando segmento+timestamp; normalización a −23 LUFS + RNNoise; import de audio externo como reunión. **Hueco confirmado: cero chat/Q&A/RAG** — nuestro M8+Copiloto no tiene rival OSS |
| Humla (MIT, Tauri+sidecars Swift; cloud opcional **$7/mes/workspace**) | OSS meetings | Dual-stream capture, pyannote community-1 + Sortformer, routing de engine **por idioma**, override por nota, "notas=intención + transcript=hechos", **playback con highlight palabra a palabra** (→ D27), PocketBase self-hosted gratis vs cloud pago — el modelo de monetización de sync que D12-L2 puede copiar |
| Riffado (AGPL) | Companion Plaud | AES-256-GCM at rest, webhooks firmados, backup/restore unificado |

**Amenazas estructurales y defensa:** (1) IA de plataforma (Zoom AI Companion, Teams Copilot, Gemini) — enjauladas por plataforma y suscripción, sin biblioteca cross-plataforma, cero privacidad → nuestra biblioteca única local es la respuesta. (2) Sherlocking de Apple — Notes ya graba/transcribe/resume on-device y **macOS 26 liberó `SpeechAnalyzer`/`SpeechTranscriber`, más rápido que Whisper en benchmarks públicos**; el piso del OS sube cada año. Regla: ninguna feature core puede ser algo que Apple obviamente hará "básico" en 1–2 años. Vivimos encima del piso: identidad del hablante, flujo dev, bilingüe profundo, RAG. Y convertimos el piso en proveedor: SpeechAnalyzer es un engine de calidad más en D25 (gratis, sin descarga).

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
- **Copiloto en vivo (D26)**: preguntas detectadas en la conversación ("¿cuál es la diferencia entre `var` y `let`?") → tarjeta con respuesta sugerida en <5 s; `contexto` responde el RAG local, `conocimiento` responde FM on-device (o BYOK con disclosure).
- Captions traducidos en vivo ES↔EN (Translation framework, on-device; parciales en idioma original, traducción al finalizar cada segmento).

## Futuro (investigación, no comprometido)

- **Feed de contexto** (ContextFeedKit ya existe): links/notas/stack traces con timestamp que enriquecen el resumen.
- **Voz sintetizada**: Personal Voice de Apple (iOS 17+) para hablar por el usuario; requiere driver de audio virtual (micrófono virtual) en macOS + disclosure obligatorio a los participantes. Fase 4+.

## UX descrestante (momentos firma)

Los momentos que hacen decir "esto no lo hace nadie" — cada uno mapea a un milestone:

1. **La waveform que sabe quién habla** (M9): timeline coloreada por speaker; arrastras y el transcript te sigue; click en una frase y el audio salta ahí con highlight en vivo.
2. **La tarjeta del Copiloto** (M11): alguien pregunta algo técnico y la respuesta ya está en tu panel antes de que termines de procesar la pregunta.
3. **"Te preguntaron"** (M11 + Watch en fase 3): estás distraído, el reloj vibra con la pregunta transcrita.
4. **Captions traducidas flotando sobre Zoom** (M14d, iPad PiP): subtítulos en tu idioma sobre cualquier app de llamadas, componible con traducción.
5. **Dynamic Island grabando** (M14c): timer + última frase en la isla; long-press = marcar momento.
6. **⌘K sobre tu historial** (ya existe el RAG): "¿qué acordamos del budget?" responde con citas clicables que saltan al audio (M9 lo conecta).
7. **Recipe automática** (M13): la app detecta que fue un 1:1 y te propone el formato correcto sin preguntar.
8. **"Recomendado para tu Mac"** (M10): la app sabe qué modelos corren bien en tu hardware y no te hace elegir a ciegas.

## Targets de performance (talla mundial = números)

| Métrica | Target | Medido (jul 2026) |
|---|---|---|
| Latencia transcript en vivo | < 2 s | ✅ p95 0.53 s |
| Resumen post-reunión | < 30 s (resumen incremental durante la reunión) | ✅ 3.8 s |
| Cold start | < 1.5 s | ⏱ pendiente medir (`bench` M10) |
| RAM grabando (Mac, STT cargado) | < 500 MB | ⏱ pendiente medir |
| Batería (iPhone, STT en vivo) | < 10%/hora (ANE) | fase 3 |
| Búsqueda en 1,000 reuniones | < 50 ms (FTS5) | ⏱ pendiente corpus sintético |
| Drift mic/system | < 50 ms en 30 min | ✅ 4 ms en 22 min reales |
| DER diarización (4 hablantes) | < 15%; intervenciones del usuario 100% | ✅ AMI 7.6%; reunión real pendiente de RTTM corregido |
| Refine (Whisper batch) | > 15x tiempo real | ✅ 23–42x |

## Seguridad (compromisos)

Keychain para secretos; `NSFileProtectionComplete` (iOS) / SQLCipher opcional (macOS); voiceprints solo on-device y borrables; CloudKit `encryptedValues` (+ADP); sha256 pineado en modelos; App Sandbox + Hardened Runtime + notarización; MCP solo localhost+token; telemetría opt-in; disclosure de grabación con presets por jurisdicción; SPM pineado + releases firmados + SECURITY.md.
