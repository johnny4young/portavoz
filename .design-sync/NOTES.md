# design-sync notes — Portavoz

- Repo shape: Swift 6 / SwiftUI app + static site. NOT a React design-system
  repo — the standard converter path does not apply. The design system was
  authored directly in Claude Design (project pinned in config.json) and this
  repo consumes it: curated pull lives in `docs/design/ds/`.
- Pull direction only: never write/delete files in the remote project from
  here without an explicit user request — the project is the user's working
  design surface.
- Aparente tensión resuelta: SKILL.md dice "amber never enters the app" y
  colors.css define --voice-me ámbar PARA la app. Lectura correcta (readme):
  el ámbar entra a la app EXCLUSIVAMENTE como la voz del usuario (dirección
  B, «el color ES la voz»); jamás como accent general.
- Next implementation source: docs/design/ds/explorations/6a-implementation-spec.md
  (4 features aprobadas) + Aurora shell + voces B como refresh visual.

- Aurora en la app (jul 11): dosis window/header/sidebar implementadas en dark; `--aurora-selection` deliberadamente NO — la selección de listas la dibuja AppKit y repintarla pelea contra la plataforma; la postura indigo quedó vía AccentColor compilado + PVDesign.accent en todo el chrome propio.

- Pull jul 11 noche (2º): el usuario iteró el DS en Claude Design — icono ELEGIDO
  «La P que habla» (assets/portavoz-icon-p.svg squircle + -menubar.svg 16px
  template; asta pulsa rojo grabando / indigo dictando), guidelines brand-icon +
  logo, tokens NUEVOS de chips codificados por evidencia (--chip-ai violeta +
  chispa ámbar / --chip-voice cyan / --chip-offer neutro — «una sugerencia nunca
  se lee como botón»), ui_kits/macos-app completo (firma: mix de voces por fila
  de reunión en el sidebar) y el proposals HTML entero (rondas 1a-7a, todas
  aprobadas). readme/styles/SKILL sin cambios de fondo. Todo en docs/design/ds/.

- Pull jul 11 noche (3º, opus): el usuario añadió 3 pantallas nuevas al ui_kit en
  Claude Design — Settings.jsx (2a: nav+búsqueda, recomendación honesta de Apple
  Intelligence, ledger de privacidad), Menubar.jsx (2b: icono waveform vivo,
  acciones, próxima reunión, recientes) y Dictation.jsx (4b: una tira flotante que
  muta dictando→insertado→aviso), cada una con su .card.html. index.html cambió el
  name del @dsCard a "macOS app". tokens/colors.css, Recording.jsx y demás sin
  cambios vs el 2º pull. Confirma: los chips por evidencia (--chip-ai-spark) ya se
  usan en Settings y Menubar.

- Pull jul 11 (4º, opus): el usuario mejoró Settings.jsx — ahora los 7 paneles
  tienen contenido REAL (antes solo Inteligencia): PVPaneGeneral/Audio/Intel/
  Voice/Agenda/Integrations/Data con primitivas reutilizables (PVRow título+sub,
  PVGroup, PVToggle, PVSeg, PVRadio, PVKeycap, PVGhostBtn). El motor de resúmenes
  es 3 radios (Apple/Ollama/Integrado MLX) + Qwen3.5 4B eliminable; refine =
  Turbo/Compacto; vocabulario = chips con ✕; ledger = 4 tiles. Dictation.jsx y
  Recording.jsx SIN cambios. El usuario pide aplicar estas «interfaces claras» a
  la app (settings, dictation panel, recording hud).
