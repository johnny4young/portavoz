# CLAUDE.md

Portavoz: asistente de reuniones privacy-first para plataformas Apple, en Swift 6 + SwiftUI. Este archivo es solo la guía operativa mínima — **el conocimiento del proyecto vive en `docs/`, no aquí**.

## Al empezar CUALQUIER sesión

1. **Lee [docs/HANDOFF.md](docs/HANDOFF.md)** — estado de sesión: qué se hizo, qué quedó verificado, próximos pasos, quirks del entorno. Es SOLO continuidad, no conocimiento durable.
2. **El conocimiento técnico as-built vive en [docs/specs/](docs/specs/README.md)** — 8 specs por dominio (captura, transcripción, diarización, inteligencia, storage, app, interfaces, calidad) escritos desde el código real, con lo implementado separado de lo planeado. Lee el spec del área que vayas a tocar ANTES de tocarla.
3. Según necesites: [docs/DECISIONS.md](docs/DECISIONS.md) (decisiones vinculantes D1–D28), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (reglas de ingeniería), [docs/PRODUCT.md](docs/PRODUCT.md) (visión, mapa competitivo, FREE/PRO), [docs/ROADMAP.md](docs/ROADMAP.md) (fases y milestones), [docs/GAPS.md](docs/GAPS.md) (brechas conocidas), [docs/IOS.md](docs/IOS.md) (fase iOS).

## Al terminar una sesión significativa

Actualiza [docs/HANDOFF.md](docs/HANDOFF.md) (estado y próximos pasos). El conocimiento técnico nuevo va al **spec correspondiente**, las decisiones de peso a DECISIONS.md. Nada importante puede quedar solo en la conversación ni solo en el HANDOFF.

## Comandos

```sh
swift build
swift test    # si falla con "no such module": DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Reglas para todo cambio

- Respeta las reglas de ingeniería de [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (privacidad local-first, MIT/no-GPL, Swift 6 estricto, scheduler vivo≠batch, sha256 en modelos).
- `swift test` en verde antes de cerrar cualquier tarea.
- Conventional Commits.
