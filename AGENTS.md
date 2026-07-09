# AGENTS.md

Portavoz: asistente de reuniones privacy-first para plataformas Apple, en Swift 6 + SwiftUI. Este archivo es solo la guía operativa mínima — **el conocimiento del proyecto vive en `docs/`, no aquí**.

## Al empezar CUALQUIER sesión

Todo el conocimiento es durable y vive en `docs/` — no hay archivo de traspaso de sesión (el HANDOFF se eliminó en jul 2026; su contenido se repartió a las docs de abajo).

1. **Estado y siguiente paso**: [docs/ROADMAP.md](docs/ROADMAP.md) abre con "Estado actual y siguiente paso" — qué está hecho, qué falta, cuál es el próximo paso concreto.
2. **Conocimiento técnico as-built**: [docs/specs/](docs/specs/README.md) — 8 specs por dominio (captura, transcripción, diarización, inteligencia, storage, app, interfaces, calidad) escritos desde el código real, con lo implementado separado de lo planeado. Lee el spec del área que vayas a tocar ANTES de tocarla.
3. Según necesites: [docs/DECISIONS.md](docs/DECISIONS.md) (decisiones vinculantes D1–D30), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (reglas de ingeniería + quirks del entorno), [docs/PRODUCT.md](docs/PRODUCT.md) (visión, mapa competitivo, FREE/PRO), [docs/GAPS.md](docs/GAPS.md) (brechas conocidas + verificación de campo pendiente), [docs/IOS.md](docs/IOS.md) (fase iOS).

## Al terminar una sesión significativa

El conocimiento nuevo va a su casa durable: estado/progreso → **ROADMAP**, técnico as-built → **spec correspondiente**, decisiones de peso → **DECISIONS.md**, brechas/pendientes → **GAPS.md**. Nada importante puede quedar solo en la conversación.

## Comandos

```sh
swift build
swift test    # si falla con "no such module": DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Reglas para todo cambio

- Respeta las reglas de ingeniería de [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (privacidad local-first, MIT/no-GPL, Swift 6 estricto, scheduler vivo≠batch, sha256 en modelos).
- `swift test` en verde antes de cerrar cualquier tarea.
- **Tras cualquier cambio de UI, deja la app reinstalada con `make install`** — el usuario prueba localmente los últimos cambios; que lo instalado siempre coincida con el trabajo reciente.
- **Toda feature o fix visible para el usuario añade UNA entrada a [CHANGELOG.md](CHANGELOG.md)** — en inglés, corta y llamativa para usuario final (**emoji + nombre de la feature** — qué te da), la más nueva arriba bajo la fecha de hoy. La plomería interna (refactors, CI, docs) NO lleva entrada.
- Conventional Commits.
