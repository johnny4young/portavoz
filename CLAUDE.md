# CLAUDE.md

Portavoz: asistente de reuniones privacy-first para plataformas Apple, en Swift 6 + SwiftUI. Este archivo es solo la guía operativa mínima — **el conocimiento del proyecto vive en `docs/`**.

## Al empezar CUALQUIER sesión

1. **Lee [docs/HANDOFF.md](docs/HANDOFF.md) antes de tocar nada** — tiene el estado actual, lo verificado, los próximos pasos exactos y los quirks del entorno. Es el mecanismo de continuidad entre sesiones.
2. Consulta según necesites: [docs/DECISIONS.md](docs/DECISIONS.md) (decisiones vinculantes D1–D14), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (diseño técnico y reglas de ingeniería), [docs/PRODUCT.md](docs/PRODUCT.md) (visión, mercado, FREE/PRO), [docs/ROADMAP.md](docs/ROADMAP.md) (hitos M0–M8 con criterios de aceptación).

## Al terminar una sesión significativa

Actualiza [docs/HANDOFF.md](docs/HANDOFF.md): estado, qué quedó verificado, próximos pasos, descubrimientos técnicos nuevos. Si se tomó una decisión de peso, añádela a DECISIONS.md. Nada importante puede quedar solo en la conversación.

## Comandos

```sh
swift build
swift test    # si falla con "no such module": DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Reglas para todo cambio

- Respeta las reglas de ingeniería de [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (privacidad local-first, MIT/no-GPL, Swift 6 estricto, scheduler vivo≠batch, sha256 en modelos).
- `swift test` en verde antes de cerrar cualquier tarea.
- Conventional Commits.
