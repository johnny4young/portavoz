# 6a — Especificación de implementación (para Claude Code)

Specs de las 4 ideas de la ronda 6a del canvas `explorations/UI Refresh Proposals.html`.
Contexto: app macOS Swift 6 + SwiftUI, repo https://github.com/johnny4young/portavoz.
Todo corre on-device; ninguna feature puede introducir tráfico de red.

---

## 1 · ⌘K «Pregúntale a tu semana»

**Qué es:** paleta de comandos global (estilo Spotlight/Raycast) sobre cualquier vista de la app, que responde preguntas en lenguaje natural sobre el historial usando el RAG local existente.

**Dónde engancha en el código:**
- Reusar `RAGAnswerer` (IntelligenceKit) y `MeetingStore.search` (FTS5) — el pipeline ya existe en `AskView.swift`; esto es una superficie nueva sobre el mismo motor.
- Hotkey global: patrón de `GlobalHotkey.swift` (hoy registra ⌥⌘D para dictado). Default: ⌘K dentro de la app; opcional global en Settings.
- Panel: `NSPanel` no-activante flotante (mismo recipe de `RecordingHUD.swift` / `DictationPanel.swift`), 620pt de ancho, radio 16, `.regularMaterial`.

**Comportamiento:**
1. ⌘K abre el panel con focus en el input. `esc` cierra. Estado se descarta al cerrar.
2. Mientras se escribe: FTS5 instantáneo (títulos + snippets, <25 ms). Enter: respuesta RAG completa.
3. Respuesta = síntesis breve (2-3 frases, negritas en los hechos) + chips de cita `↗ {título} · {mm:ss}` — click navega a `Route.meeting(id)` y hace seek del player a ese timestamp.
4. `tab` limita el scope a la reunión abierta. `⌘C` copia la respuesta con citas en Markdown.
5. Bilingüe: responder en el idioma de la pregunta.

**Criterios de aceptación:** primera respuesta < 4 s con FM; cada afirmación de la respuesta tiene ≥1 cita; funciona con la ventana principal cerrada (panel independiente); cero red.

---

## 2 · Modo espejo (coach honesto post-reunión)

**Qué es:** tarjeta opt-in que aparece al terminar de procesar una reunión, con las métricas del usuario contadas con la voz de la marca — «medido, no juzgado». Nunca lenguaje evaluativo («mal», «demasiado»); solo números + comparación con la propia media.

**Dónde engancha:**
- Datos: `MeetingHealth.compute(segments:)` ya calcula talk-time, preguntas e interrupciones por speaker — filtrar `isMe`.
- Media personal: agregar sobre `LibraryStats` (IntegrationsKit) un promedio de share de habla de las últimas N reuniones (persistir nada nuevo: computar de la librería).
- Presentación: sheet/tarjeta al completarse el resumen post-reunión (hook donde `RecordingController` pasa a fase terminada), no bloqueante.
- Setting: `Settings › Mi voz y Companion › «Espejo al terminar» (off por defecto)`.

**Contenido de la tarjeta:** 3 tiles (`% hablaste` vs tu media resaltado en ámbar si difiere >10pts; `preguntas hiciste`; `interrupciones` con a-quién y timestamp clicable) + 1 línea ✦ de síntesis FM (máx 2 frases, template con hechos: escuchaste más/menos de lo habitual, qué quedó abierto tuyo) + acciones: «Ver mi tendencia» (→ Insights) y «No mostrar tras cada reunión».

**Criterios:** solo aparece con ≥2 speakers y ≥5 min; nunca aparece si el setting está off; el texto ✦ jamás usa adjetivos valorativos.

---

## 3 · Puente de idiomas en vivo

**Qué es:** durante la grabación, bajo cada caption final en idioma A se muestra su traducción al idioma preferido del usuario, en un carril secundario menor y en ámbar. El original manda; el puente acompaña.

**Dónde engancha:**
- Ya existe `LiveTranslation.swift` (portavoz-app) y el picker «Translate» en `RecordingView` — esto es un rediseño de presentación, no un motor nuevo.
- Traducir SOLO segmentos finalizados (no volátiles) para no parpadear; cola con `IntelligenceScheduler` en lane de fondo.
- Glosario: pasar `VocabularyPrompt.parse(customVocabulary)` para que la jerga (deploy, PR, QVTL…) quede intacta.

**Presentación (patrón lyrics):** línea original = estilo actual del carrusel; debajo, indentada al inicio del texto (no del pill), 15px, color `--brand-amber`/`.orange` al 90%, misma alineación. Si la traducción llega >2 s tarde, aparece con fade, nunca reordena líneas.

**Criterios:** latencia del puente < 3 s p95; toggle en la barra de grabación («Traducir: off / ES / EN»); jerga del vocabulario nunca traducida; off = cero costo.

---

## 4 · Onboarding «primera escucha»

**Qué es:** reemplaza los 4 pasos actuales de `OnboardingView.swift` por una demo en primera persona: el usuario dice una frase y ve en vivo transcripción → separación de su voz → mini-resumen, ANTES de pedir permisos.

**Flujo:**
1. Pantalla única: waveform breathe + «Di una frase — mira lo que pasa.» Botón único «Escuchar 10 s». (Pedir permiso de mic aquí, inline, con una línea de por qué.)
2. Captura 10 s con `MicrophoneSource` + Parakeet live (si el modelo no está, usar SpeechAnalyzer del sistema para no bloquear la demo con una descarga).
3. Mostrar en vivo: caption apareciendo (patrón lyrics) → pill «Tu voz» ámbar → tarjeta con ✓ transcrita en X s · ✓ voz separada · ✦ resumen de una línea, cerrando con «todo sin red, como acabas de ver».
4. Recién entonces: permisos restantes (system audio se pide en la primera grabación real, como hoy), calendario opcional, y oferta de enrolar la voz reutilizando el audio que ACABA de grabar (un click, no otros 12 s).
5. `hasOnboarded` se mantiene como flag; «Saltar» siempre visible (voz de marca: sin fricción, sin dark patterns).

**Criterios:** de app abierta a demo completada < 60 s; funciona sin descargar modelos (fallback SpeechAnalyzer); el audio de la demo se descarta salvo que el usuario acepte enrolar su voz; ES/EN según idioma del sistema.

---

## Notas transversales

- Toda UI nueva usa los tokens del design system (`tokens/colors.css` como referencia de valores; en SwiftUI: indigo accent, ámbar = solo la voz del usuario, verde/naranja/rojo semánticos).
- Números siempre `monospacedDigit`. Copy bilingüe vía `L10n`.
- Los chips ✦ mantienen el contrato: proponen, un click aplica, jamás actúan solos.
