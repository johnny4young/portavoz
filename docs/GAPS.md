# GAPS — Análisis de brechas para talla mundial

Qué le falta a Portavoz (jul 2026) comparado contra el estado del arte medido en las dos rondas de análisis competitivo (PRODUCT.md). Ordenado por impacto. Cada brecha dice **qué existe hoy**, **qué falta** y **dónde está planeado** — si no está planeado, lo dice.

## Brechas de producto (el usuario las siente)

| # | Brecha | Hoy | Falta | Plan |
|---|---|---|---|---|
| 1 | ~~**Distribución cero**~~ | **RESUELTO (10 jul 2026)**: repo público + release v0.1.0 (DMG notarizado, appcast Sparkle) + tap Homebrew con audit limpio — `brew install --cask portavoz` funciona | crecimiento (stars, discoverability) | ✅ M9 |
| 2 | ~~**El audio no se puede escuchar**~~ | **RESUELTO (jul 2026)**: player sincronizado + highlight/auto-scroll + waveform coloreado + clips m4a, skip-silencio, transcode AAC e import (`AudioPlaybackKit`, M11) | — | ✅ |
| 3 | ~~**No se puede escribir durante la reunión**~~ | **RESUELTO (jul 2026)**: panel de notas durante grabación, persistencia, tejido notas→prompt, render de coautoría con marca ▸ (M10/D28) | verificación de campo: 5 notas reales → resumen que las expande sin contradecirlas | ✅ código / campo pendiente |
| 4 | ~~**Grabar exige la ventana completa**~~ | **RESUELTO (jul 2026)**: botón "Vista compacta" en grabación → HUD flotante (NSPanel `.nonactivatingPanel` + `.borderless`, level floating, todas las Spaces) con timer, última caption, medidor de mic y stop; la ventana principal se minimiza al Dock y el HUD vuelve a expandirse solo al salir de `.recording`. Los clicks no roban foco de Zoom/Meet | verificación de campo; menu bar item (menor) | ✅ código / campo pendiente |
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
