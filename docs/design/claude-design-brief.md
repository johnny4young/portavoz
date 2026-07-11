# Portavoz Design System — brief para Claude Design

> Pega este brief como primer mensaje en un proyecto **Design system** de
> claude.ai/design. Describe el producto real, los tokens de facto que hoy
> viven en el código, el inventario de superficies, y las convenciones de
> estructura que el sync posterior (`/design-sync`) espera.

## El producto

Portavoz es un asistente de reuniones **privacy-first, 100% local** para
macOS (Swift 6 + SwiftUI, próximamente iOS). Graba reuniones, transcribe en
vivo, separa voces on-device y resume localmente. Personalidad de marca:
**serio pero cálido, técnico sin frialdad, honesto** ("measured, not
promised", "your history is never hostage"). Bilingüe ES/EN de nacimiento.

## Tokens de facto (lo que HOY vive en el código — punto de partida, no dogma)

**Color (app macOS)**
- Tint global: `indigo` de sistema (controles, links, iconos activos).
- Chips de sugerencia: `accentColor.opacity(0.14)` en cápsula; oferta
  secundaria a `0.08`.
- Cards/tiles: `quaternary.opacity(0.5)`, radios 10 (tiles) y 12 (cards).
- Paneles flotantes: `.regularMaterial`, radio 14.
- Semánticos: verde = mic OK / éxito; naranja = advertencia (mic bajo,
  permisos); rojo = destructivo/grabando (punto en menu bar).
- ⚠️ Deuda conocida: la selección de listas usa el accent del SISTEMA del
  usuario (verde en mi Mac) y choca con el indigo — el design system debe
  decidir una postura.

**Color (sitio web portavoz.app — el "mundo del icono")**
- Fondo slate `#0e1120` → gradientes radiales violeta `#5226bf`.
- Acento único ámbar `#fdbf47` (la barra pico del waveform).
- Texto papel cálido `#f3f1ec`, secundario `#b9b6c4`.

**Tipografía**
- App: system font (SF Pro); números SIEMPRE `monospacedDigit`; jerarquía
  usada: largeTitle.bold (títulos de página), title2.bold (valores de
  tiles), headline (títulos de card), caption/caption2 (ayudas).
- Web: Fraunces (display serif, eje SOFT 50) + Instrument Sans (cuerpo) +
  IBM Plex Mono (comandos y números).
- Pregunta abierta para el DS: ¿cuánta identidad web (Fraunces/ámbar)
  entra a la app nativa sin pelear con lo nativo-macOS?

**Iconografía**: SF Symbols exclusivamente (waveform.and.mic,
record.circle.fill, person.wave.2, chart.bar.xaxis, sparkles ✦ para
sugerencias IA, arrow.uturn.backward para restore).

**Motion**: pulse en símbolos activos (dictado); waveform CSS "breathe"
3.6s en la web con `prefers-reduced-motion` respetado.

## Inventario de superficies reales (todas existen hoy)

1. **Biblioteca** (sidebar): botones de acción, búsqueda, secciones
   colapsables (To-dos, Recently deleted), filas de reunión, agenda.
2. **Detalle de reunión**: pills de speakers (Me = accent), CHIPS de
   sugerencia (nombres ✦, voz 🎙, recipe, título, thin-summary — el patrón
   más repetido del producto: sugerencia pura, click aplica, jamás solo),
   resumen estructurado con coautoría "▸", action items con checkbox,
   meeting health (barras de talk-time), transcript denso con pills.
3. **Grabación en vivo**: timer, captions carrusel estilo lyrics, medidor
   de mic (cápsula 4pt, mapeo dB −60→0), notas, tarjetas del Companion.
4. **HUD flotante** (400×88) y **panel de dictado** (520×~70): material,
   siempre-encima, mic meter, texto en vivo.
5. **Insights**: tiles de stats (valor grande + label caption), chart de
   barras semanal (Swift Charts), cards de personas y gauge circular de
   pendientes.
6. **Onboarding** (4 pasos), **Settings** (16 secciones en Form grouped),
   **menu bar** (icono estado + menú), **Ask** (chat con citas).
7. **Web** (portavoz.app): hero waveform, features grid, números medidos,
   footer.

## Lo que le pido al design system

1. **Foundations**: paleta única que reconcilie indigo-app + ámbar/slate-web
   con modos light/dark; escala tipográfica; espaciado (hoy: 12/16/24);
   radios (hoy: 10/12/14); semánticos (éxito/advertencia/destructivo/
   grabando/IA-sugerencia).
2. **Componentes** (con variantes por card):
   - Chip de sugerencia (IA ✦ / voz / recipe; hover; aplicado).
   - Card (tile de stat, card de contenido, tarjeta Companion).
   - Pill de speaker (Me / nombrado / S-label / editable).
   - Meter (mic level OK/bajo; gauge circular).
   - Fila de lista (reunión, to-do con checkbox, papelera con restore).
   - Botón (primario/segundario/destructivo/ghost; tamaños).
   - Panel flotante (HUD, dictado strip, banner pre-reunión).
   - Empty states (biblioteca vacía, sin pendientes, papelera).
3. **Voz y tono**: microcopy bilingüe con la personalidad ("Deleted, not
   gone", "Measured, not promised").

## Convenciones para el sync posterior (importante)

- El proyecto DEBE crearse como tipo **Design system** (el tipo es
  inmutable — un proyecto normal no se puede convertir).
- Un componente = un HTML de preview **autocontenido** (CSS inline, sin
  CDNs) con el marcador de card en la PRIMERA línea:
  `<!-- @dsCard group="Components" -->` — el pane agrupa por ese `group`.
- Grupos sugeridos: `Foundations` (Colors, Type, Spacing), `Components`,
  `Patterns` (chips/sugerencias), `Surfaces` (paneles/HUD), `Brand` (web).
- Estructura de paths estable: `foundations/colors/index.html`,
  `components/chip/index.html`, etc. — el sync es incremental por
  componente; paths estables = diffs limpios.
- Variantes de un componente en UNA card (subtitle las lista), no una card
  por variante.
