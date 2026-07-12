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
