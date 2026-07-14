# GAPS — Análisis de brechas para talla mundial

Qué le falta a Portavoz (jul 2026) comparado contra el estado del arte medido en las dos rondas de análisis competitivo (PRODUCT.md). Ordenado por impacto. Cada brecha dice **qué existe hoy**, **qué falta** y **dónde está planeado** — si no está planeado, lo dice.

## Brechas de producto (el usuario las siente)

| # | Brecha | Hoy | Falta | Plan |
|---|---|---|---|---|
| 1 | ~~**Distribución cero**~~ | **RESUELTO (10 jul 2026)**: repo público + release v0.1.0 (DMG notarizado, appcast Sparkle) + tap Homebrew con audit limpio — `brew install --cask portavoz` funciona | crecimiento (stars, discoverability) | ✅ M9 |
| 2 | ~~**El audio no se puede escuchar**~~ | **RESUELTO (jul 2026)**: player sincronizado + highlight/auto-scroll + waveform coloreado + clips m4a, skip-silencio, transcode AAC e import (`AudioPlaybackKit`, M11) | — | ✅ |
| 3 | ~~**No se puede escribir durante la reunión**~~ | **RESUELTO (jul 2026)**: panel de notas durante grabación, persistencia, tejido notas→prompt, render de coautoría con marca ▸ (M10/D28) | verificación de campo: 5 notas reales → resumen que las expande sin contradecirlas | ✅ código / campo pendiente |
| 4 | ~~**Grabar exige la ventana completa**~~ | **RESUELTO (jul 2026)**: botón "Vista compacta" en grabación → HUD flotante (NSPanel `.nonactivatingPanel` + `.borderless`, level floating, todas las Spaces) con timer, última caption, medidor de mic y stop; la ventana principal se minimiza al Dock y el HUD vuelve a expandirse solo al salir de `.recording`. Los clicks no roban foco de Zoom/Meet | verificación de campo (menu bar item HECHO jul 2026: MenuBarExtra con estado + start/stop + dictado + launch-at-login) | ✅ código / campo pendiente |
| 5 | ~~**UI solo en español**~~ | **RESUELTO (jul 2026)**: source strings en inglés, `Localizable.xcstrings` + `InfoPlist.xcstrings`, traducción ES completa, export a `en.lproj`/`es.lproj` en `make-app.sh`, `CFBundleDevelopmentRegion=en`, `CFBundleLocalizations=[en, es]`, selector Settings **System / English / Español** con locale SwiftUI en vivo | — | ✅ |
| 6 | ~~**Onboarding inexistente**~~ | **RESUELTO (jul 2026)**: flujo primera-vez de 4 pasos (`OnboardingView`): bienvenida local-first, permisos guiados (mic ahora / system audio explicado / calendario opcional), descarga de modelos con progreso + recomendación por hardware, enrolar voz opcional. Se muestra una vez (`hasOnboarded`); bibliotecas existentes lo saltan; `-show-onboarding` lo fuerza | verificación visual pendiente | ✅ código |
| 7 | ~~**Macs sin Apple Intelligence = sin resumen local**~~ | **RESUELTO (jul 2026)**: Ollama de primera clase — Ajustes → Motor de resúmenes detecta Ollama, lista modelos, resume 100% local sin key (`OllamaService` + `OpenAICompatibleSummaryProvider`). Verificado E2E con gpt-oss:20b (resumen ES en 24 s). **MLX embebido también hecho (D32, jul 2026)**: Qwen3-4B 4-bit en GPU, cero instalaciones, verificado en reunión real de 40 min | ✅ |
| 8 | ~~**Import de audio externo sin UI**~~ | **RESUELTO (jul 2026)**: botón "Importar audio…" + drag-drop en la biblioteca → transcribe (Whisper) + diariza + resume como reunión nueva (M11) | — | ✅ |
| 9 | Sin recap email (brief ✅) | **Brief pre-reunión HECHO (jul 2026)**: agenda colapsable hoy/mañana, brief con relevancia + citas + grabar desde el brief + banner proactivo (M13b) | borrador de recap post-reunión (email/Slack) | M16 |
| 10 | Sin App Intents/Shortcuts/Spotlight | — | automatizaciones post-reunión | M16 |

## Brechas técnicas (deuda y riesgo)

| # | Brecha | Riesgo | Plan |
|---|---|---|---|
| T1 | ~~Crash-safety del WAV~~ | **RESUELTO**: verificado que WAV+kill -9 = 0 bytes legibles; captura migrada a CAF (kill -9 → 5.23 s de 6 s conservados); lectores con fallback a .wav legado | ✅ jul 2026 |
| T2 | **Taps + VPIO en el mismo proceso** | MacParakeet los declaró incompatibles "confiablemente"; tenemos 1 muestra OK | Vigilancia activa (ver verificación de campo, abajo) + plan B offline echo-cancel (D27) |
| T3 | ~~FM sin política de prioridad~~ | **RESUELTO (D29)**: `IntelligenceScheduler` single-flight con prioridades, latest-wins por key, 7 tests | ✅ jul 2026 |
| T4 | **Números de perf sin medir**: cold start, RAM grabando, FTS a 1k reuniones, batería | targets publicados sin evidencia — inaceptable para el README de M9 | `portavoz-cli bench --suite full` + corpus sintético (M9) |
| T5 | RAG brute-force O(n) | a 1,000+ reuniones el `ask` se degrada | medir primero (T4); sqlite-vec si falla el target |
| T6 | ~~Storage de audio 126 MB/canal/22 min~~ | **RESUELTO (jul 2026)**: botón "Comprimir audio (AAC)" en el detalle → transcode a m4a (`AudioTranscoder`), borra el original solo tras escritura verificada; `MeetingAudioLayout` prefiere m4a | ✅ |
| T7 | CI no corre los tests gated de modelos | regresiones de integración invisibles en CI | runner self-hosted o job manual mensual — NO PLANEADO |
| T8 | ~~Sin SwiftLint/format en CI~~ | **RESUELTO (jul 2026)**: `.swiftlint.yml` calibrado a cero errores + job `lint` en CI (M9 prep) | ✅ |
| T9 | ~~FluidAudio pineado a revisión~~ | **RESUELTO (jul 2026)**: 0.15.5 incluye el fix #732; re-pineado a `.upToNextMinor(from: "0.15.5")` | ✅ |
| T10 | Sin telemetría de crashes (opt-in) | bugs de campo invisibles post-publicación | decidir en M9 (¿solo GitHub issues? ¿MetricKit local?) |

## Brechas de posicionamiento (contra el mapa competitivo)

- **Velocidad de publicación**: Meetily 20.5K stars / Anarlog 8.8K / MacParakeet 451 en 5 meses — cada semana privada regala terreno. El nicho "Swift nativo + MIT" está VACÍO (MacParakeet es GPL).
- **Companion con reloj**: Teams "Facilitator" llega ~ago-sep 2026. Ser primeros en meeting-notes local importa (M13).
- **Benchmarks públicos**: MacParakeet publica WER/velocidad/memoria reproducibles en el README — es el estándar de credibilidad del nicho. Tenemos los harnesses; falta la disciplina de publicarlos (M9).
- **La historia del archivo**: Granola cobra por acceder a tus notas de >30 días. Nuestro pitch inverso — "tu historial jamás es rehén" — no está escrito en ningún README todavía.

## Verificación de campo pendiente (necesita al usuario, no es deuda de código)

Features implementadas y testeadas cuyo criterio final solo se cierra con una reunión real:

- **Companion < 5 s** (D26): en una reunión real, una pregunta de conocimiento debe producir tarjeta en < 5 s; validar también el detector "te preguntaron" (mención de tu nombre → ping) y, si configuraste BYOK, la ruta externa con disclosure.
- **Taps + VPIO conviviendo** (T2): vigilar el canal system con AEC activo (glitches, dropouts, silencio). 1 reunión OK no es evidencia. Si aparece, plan B en D27.
- **AirPods mudan el canal system** (C, campo 13 jul 2026, ABIERTO): con AirPods conectados una reunión salió con **solo el mic** — el canal `system.caf` quedó mudo. Confirmado midiendo el audio copiado de la reunión "Mita": mic −24.9 dBFS / 91% activo (español limpio), system −51.2 dBFS / 2% activo. Hipótesis: cuando los AirPods son a la vez salida y entrada, macOS conmuta a HFP/SCO y el `CATap` sobre el default-output deja de leer la mezcla; o el rebuild del grafo (`ProcessTapSource.installOutputDeviceListener`) se re-liga a un device transitorio. Confirmado 2ª vez (13 jul, grabación 9014F3AE con AirPods + video por el Mac): system.caf a −∞ dBFS (todo ceros, 0% activo) mientras el mic tenía voz — y el canal mudo produjo un segment alucinado en cirílico (`<unk>ПРИК САКТО`), el origen del "empezó a tomar el Russian". Mitigado: (a) `AudioSilence.fileIsSilent` salta canales de silencio digital en el refine, (b) supresión en vivo de captions del canal system cuando `systemAudioMissing`, (c) B (aviso en vivo), (d) override de idioma del refine. Con eso un canal mudo queda VACÍO en vez de inventar texto. CAUSA RAÍZ en el código: `MicrophoneSource(voiceProcessing:)` abre el input por defecto (AirPods) con `setVoiceProcessingEnabled(true)`, y abrir el mic de los AirPods los fuerza a HFP → el tap del output enmudece. El fix del mic integrado (forzar built-in) se DESCARTÓ: rompe la MOVILIDAD del usuario (si se aleja del Mac, el mic integrado no lo capta). Requisito del usuario: grabar con el input/output del sistema, reactivo. **EXPERIMENTO shipeado (local, PENDIENTE verificación en vivo)**: cuando el default output es Bluetooth, en vez del tap GLOBAL se tapea el PROCESO de la app de reunión (`MeetingAppDetector` → PIDs de Zoom/Teams/Slack/Discord/Webex/FaceTime/browsers; `ProcessTapSource(processIDs:)` con `CATapDescription(stereoMixdownOfProcesses:)`). Un process tap lee lo que la app renderiza ANTES del routing al device → PODRÍA capturar la llamada en HFP manteniendo el mic de los AirPods. Fallback: sin app detectada → tap global (igual que hoy). Fuera de Bluetooth → tap global (proven). Nudge en RecordingView nombra las apps tapeadas. A/B a verificar: con AirPods + Zoom/Meet, el canal system debe capturar la llamada. Si NO lo hace, el process tap tampoco lee en HFP y hay que aceptar el límite (voz siempre capturada, llamada limitada).
- **AEC con parlantes**: grabar por parlantes y hablar — tus palabras salen como "Yo", los demás NO se duplican. Si el mic suena raro, Ajustes → desactivar "Cancelación de eco".
- **Cambio de dispositivo**: conectar/desconectar audífonos a mitad — el canal mic sobrevive (hueco de silencio, no muerte).
- **DER formal M3**: corregir la columna Speaker del RTTM borrador en `~/Desktop/portavoz-verificacion/reunion-2026-07-07.md` → medir con `portavoz-cli der --file system.wav --reference <rttm corregido>`.
- **Pivote de traducción** (D25): regenerar un resumen en otro idioma debe traducir el snapshot existente (rápido) en vez de re-resumir; verificar que conserva estructura y action items.
- **Captions traducidos**: grabar con el picker "Traducir → …" (la 1ª vez macOS puede pedir descargar el par de idiomas).
- **Nombres por calendario**: evento con asistentes alrededor de una grabación → "Sugerir nombres ✦" (pide TCC de calendario).
- **Export real**: `export --gist` / "Publicar como Gist" con token; `issues --github/--linear` con tokens contra un repo de prueba.

## Lo que NO son brechas (decisiones deliberadas — no "arreglar")

- Sin backend propio ni cuentas (D12: cero servidores hasta demanda probada).
- Sin captura de llamadas en iOS (D11: imposible; grabadora presencial + companion).
- Sin bot que se une a la llamada (todo el mercado bot-free nativo lo evita; nuestra captura es local).
- Threshold de diarización en 0.45 (subirlo rompe AMI; la fragmentación se resuelve post-clustering).
- XCTest en vez de Swift Testing (D13, por el entorno de build sin Xcode completo).
