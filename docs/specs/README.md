# Specs técnicos — cómo leer esta carpeta

Documentación **as-built** de Portavoz: describe lo que el código hace HOY, verificable contra `Sources/` y `Tests/`. Escrita para que cualquier agente o humano pueda trabajar en el proyecto sin contexto de conversaciones previas.

## Convenciones (sin ambigüedad)

- Todo lo descrito en las secciones normales **está implementado y testeado** (`swift test`, 264 tests, 13 gated por `PORTAVOZ_MODEL_TESTS=1` u otras variables de integración).
- Lo NO implementado vive solo en subsecciones tituladas **"Planeado (no implementado)"**, con referencia a la decisión (Dxx) o milestone (Mxx) que lo define.
- Cada número de performance citado fue **medido** en la máquina de referencia (MacBook Pro M4 Max, 36 GB, macOS 26) — la fecha y condición acompañan al número.
- Los "límites conocidos" son fallas o riesgos reales observados, no hipótesis.

## Índice

| Spec | Cubre | Kits |
|---|---|---|
| [01-audio-capture.md](01-audio-capture.md) | Captura dual-canal, AEC, resiliencia, formatos, carpeta configurable | AudioCaptureKit |
| [02-transcription.md](02-transcription.md) | STT vivo (Parakeet), refine (Whisper), coalescer, vocabulario, registry de modelos | TranscriptionKit, ModelStoreKit |
| [03-diarization-identity.md](03-diarization-identity.md) | Diarización, atribución, voiceprint, nombres | DiarizationKit, IntelligenceKit (naming) |
| [04-intelligence.md](04-intelligence.md) | Resúmenes FM/BYOK, resumen rodante, RAG local, embeddings | IntelligenceKit |
| [05-storage.md](05-storage.md) | Schema SQLite, contrato de datos, FTS, retención, carpeta de grabaciones | StorageKit, PortavozCore |
| [06-app-macos.md](06-app-macos.md) | App SwiftUI, vistas, flujos, empaquetado, firma, updates | portavoz-app, scripts/ |
| [07-interfaces.md](07-interfaces.md) | CLI completo, servidor MCP, exportadores | portavoz-cli, IntegrationsKit |
| [08-quality.md](08-quality.md) | Suite de tests, harnesses, números medidos, bugs encontrados | Tests/, scripts/ |

## Documentos hermanos (fuera de specs/)

- [../DECISIONS.md](../DECISIONS.md) — decisiones vinculantes D1–D30 con su porqué. Los specs las citan por número.
- [../ARCHITECTURE.md](../ARCHITECTURE.md) — reglas de ingeniería y diseño de alto nivel.
- [../ROADMAP.md](../ROADMAP.md) — fases y milestones con criterios de aceptación.
- [../PRODUCT.md](../PRODUCT.md) — visión, mapa competitivo, FREE/PRO.
- [../IOS.md](../IOS.md) — aterrizaje técnico de la fase iOS.
- [../GAPS.md](../GAPS.md) — análisis de brechas + verificación de campo pendiente.
- [../ROADMAP.md](../ROADMAP.md) abre con **"Estado actual y siguiente paso"** — el estado del proyecto se lee ahí (no hay archivo de traspaso de sesión).

## Reglas del repo (para agentes)

- Swift 6 estricto; los Kits solo dependen de PortavozCore (excepción: IntegrationsKit→IntelligenceKit); infra compartida va a ModelStoreKit/PortavozCore.
- MIT; jamás portar código GPL (Meetily en `../meetily` y MacParakeet son SOLO referencia de patrones).
- `swift test` verde antes de cerrar cualquier tarea (si falla con "no such module": `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`).
- Conventional Commits. Modelos siempre pineados por sha256 (D15).
