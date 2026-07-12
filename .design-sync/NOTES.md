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
