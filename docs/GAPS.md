# GAPS — Análisis de brechas para talla mundial

Qué le falta a Portavoz (jul 2026) comparado contra el estado del arte medido en las dos rondas de análisis competitivo (PRODUCT.md). Ordenado por impacto. Cada brecha dice **qué existe hoy**, **qué falta** y **dónde está planeado** — si no está planeado, lo dice.

## Brechas de producto (el usuario las siente)

| # | Brecha | Hoy | Falta | Plan |
|---|---|---|---|---|
| 1 | **Distribución cero** | DMG notarizado + cask + appcast listos, repo privado, 0 usuarios | push, release, tap, README con benchmarks | M9 — es un día de trabajo |
| 2 | ~~**El audio no se puede escuchar**~~ | **RESUELTO (jul 2026)**: player sincronizado + highlight/auto-scroll + waveform coloreado + clips m4a (`AudioPlaybackKit`, M11) | falta skip-silencio (menor) | ✅ |
| 3 | **No se puede escribir durante la reunión** | `ContextItem` modelado, cero UI/storage/prompt | el loop de coautoría completo (el patrón de $1.5B de Granola) | M10 / D28 |
| 4 | **Grabar exige la ventana completa** | RecordingView a pantalla | HUD flotante compacto (NSPanel non-activating) con captions + stop; menu bar | NO PLANEADO — proponer con M10 (misma vista) |
| 5 | **UI solo en español** | strings hardcodeados | localización (mínimo EN — "talla mundial" implica bilingüe también en la UI, no solo en los resúmenes) | NO PLANEADO — añadir a M9 (String Catalogs antes de publicar; después duele más) |
| 6 | **Onboarding inexistente** | primer arranque descarga modelos con progreso, sin explicación de permisos/valor | flujo primera-vez: permisos guiados (mic/system/TCC), descarga con recomendación por hardware, enrolar voz opcional (patrón Meetily) | Parcial en M12 (recomendador); el flujo NO está planeado |
| 7 | **Macs sin Apple Intelligence = sin resumen local** | FM o BYOK manual | Ollama primera clase → MLX embebido | M12 / D25 |
| 8 | ~~**Import de audio externo sin UI**~~ | **RESUELTO (jul 2026)**: botón "Importar audio…" + drag-drop en la biblioteca → transcribe (Whisper) + diariza + resume como reunión nueva (M11) | — | ✅ |
| 9 | Sin brief pre-reunión ni recap email | EventKit ya lee asistentes | Briefs (Granola) + borrador de recap (Gemini) | M13b / M16 |
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
| T8 | Sin SwiftLint/format en CI | estilo a mano | añadir en M9 (barato antes de contribuidores) |
| T9 | FluidAudio pineado a revisión | fix upstream sin release | volver a upToNextMinor cuando salga > 0.15.4 |
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
