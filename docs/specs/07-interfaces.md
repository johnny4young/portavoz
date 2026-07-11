# Spec 07 — Interfaces: CLI, MCP y exportadores

Estado: implementado; MCP verificado E2E con un agente real. Decisiones: D12 (escalera de compartir), D22 (RAG).

## CLI — `portavoz-cli` (dispatch en `Sources/portavoz-cli/CLI.swift`)

Binario SPM (`swift build --product portavoz-cli` → `.build/debug/portavoz-cli`). Comparte DB y modelos con la app (incluida la carpeta de grabaciones configurable, vía `RecordingsLocation`).

| Comando | Usage (del código) |
|---|---|
| `devices` | Lista inputs (incluye iPhones vía Continuity) |
| `record` | `[--seconds N] [--mic <name-or-uid>] [--pid <pid> …] [--system] [--out <dir>] [--transcribe] [--language es] [--models-dir <dir>] [--no-aec]` |
| `transcribe` | `--file <wav> [--engine parakeet\|whisper] [--vocab "a,b,c"] [--language es] [--models-dir <dir>]` |
| `diarize` | `--file <wav> [--attribute] [--threshold t] [--language es] [--models-dir <dir>]` |
| `summarize` | `--file <wav> [--out-language es] [--glossary a,b,c] [--byok <endpoint> --byok-model <model>] [--save] [--db <path>]` — pipeline completo wav→transcript→diarización→resumen |
| `meetings` | `list \| show <uuid> \| search <texto> \| refine <uuid> [--file <wav>] [--language es] [--vocab "…"] [--db] [--models-dir]` |
| `export` | `--meeting <uuid> [--format md\|pdf] [--out <path>] [--gist [--public]]` |
| `secrets` | `set-github-token <token> \| clear-github-token` (Keychain; equivalentes para Linear) |
| `voice` | `enroll [--file <wav>] \| status \| delete` |
| `der` | `--file <wav> --reference <rttm> [--threshold t] [--collar s]` — harness DER |
| `mcp` | Servidor MCP por stdio (ver abajo) |
| `ask` | `"<pregunta>" [--db <path>] [--limit n]` — RAG local con citas |
| `issues` | `--meeting <uuid> (--github <owner/repo> \| --linear-team <id>)` |
| `models` | `download \| verify \| path` — catálogo completo sha256 |
| `bench-m2` | Harness de aceptación M2 (lag vivo + batch concurrente) |

## Servidor MCP — `portavoz-cli mcp`

- Transporte: **JSON-RPC 2.0 por stdio, newline-delimited**; protocolVersion `2024-11-05`. Capa de protocolo storage-agnostic en IntegrationsKit (`MCPServer`, `MCPTool` con handlers Data→String, schemas JSON crudos); el toolbox se arma en el CLI (`MeetingToolbox`).
- Registro con un agente: `claude mcp add portavoz -- portavoz-cli mcp`.
- **6 tools**: `list_meetings` · `search_meetings` (FTS con snippets+ids+timestamps) · `get_transcript` (atribuido) · `get_summary` (último snapshot + action items) · `get_action_items` (pendientes globales) · `ask` (RAG híbrido on-device con citas).
- Verificado E2E: un agente MCP respondió "what did we agree about the transcription budget?" con fuentes correctas.

## Exportadores — IntegrationsKit

- `MeetingExporter`: markdown canónico (título/metadata/resumen con headings degradados/pendientes/transcript atribuido) y **PDF por CoreText puro** (sin AppKit — compila para iOS; paginación US Letter verificada con CGPDFDocument).
- `GistPublisher`: `api.github.com/gists`, secreto por defecto, `--public` explícito; token del Keychain.
- `GitHubIssuesExporter` (REST) y `LinearExporter` (GraphQL; **el token va pelado en Authorization, SIN prefijo Bearer**): action items → issues. Testeados offline; publish real pendiente de tokens del usuario.
- Salida al exterior SIEMPRE con confirmación explícita (D8): la UI confirma antes del gist; el CLI es opt-in por naturaleza.

## Límites conocidos

1. MCP sin auth (proceso local por stdio — aceptable; el plan de seguridad exige localhost+token si algún día hay transporte de red).
2. `issues` y `export --gist` verificados offline, publish real con tokens del usuario pendiente.
3. Sin App Intents/Shortcuts (M16).

## Automatización M16 (jul 2026)

- **Hook post-reunión**: `PostMeetingShortcut.runIfConfigured(markdown:)` — al `.done` del stop, si Ajustes → Automation tiene un nombre de Atajo, corre `/usr/bin/shortcuts run <name> --input-path <tmp.md>` con el export Markdown completo (MeetingExporter). Fire-and-forget deliberado: jamás bloquea ni retrasa el pipeline; los fallos del Atajo se ven en Shortcuts (la reunión ya está guardada igual).
- **URL scheme** `portavoz://record` (CFBundleURLTypes en make-app.sh): abre la app y ARRANCA una grabación — visible siempre (ventana + indicador de mic; nada graba oculto). Verificado E2E: `open "portavoz://record"` lanza, navega y graba. Combinado con automatizaciones de Shortcuts (hora/calendario) da auto-grabación programada.
- **AppIntents/Siri**: diferido a M14a — el appintentsmetadataprocessor solo corre en builds Xcode; el bundle SPM de make-app.sh no registra intents.
- **Spotlight** (`SpotlightIndexer`, jul 2026): CSSearchableIndex local — rebuild completo (delete dominio + insert) al launch y con cada `libraryVersion` (barato: solo metadata; inmune al drift de borrados; `-use-temp-store` lo suprime). Cada item: título + fecha + resumen/primeras 40 líneas (cap 4000 chars) con el UUID de la reunión como identifier; el hit navega vía `onContinueUserActivity(CSSearchableItemActionType)` → `Route.meeting`. **GOTCHA doble (campo jul 2026)**: (1) sin `NSUserActivityTypes: [com.apple.corespotlightitem]` en el Info.plist, macOS descarta la continuación; (2) aún con eso, el `onContinueUserActivity` de SwiftUI NO se dispara en macOS — la activity llega al `NSApplicationDelegate` clásico. `PortavozAppDelegate.application(_:continue:)` (vía `@NSApplicationDelegateAdaptor`) parsea el identifier y navega por `AppServices.pendingRoute` (el canal del banner); ContentView además aplica el `pendingRoute` presente AL MONTAR (cold start: la activity puede llegar antes de la ventana y `onChange` no dispara para el valor inicial).
- **Bundle `.portavoz`** (`MeetingBundle`, IntegrationsKit, jul 2026 — M15 L0): JSON versionado (ISO8601, sortedKeys) con meeting+speakers+segments+resumen+notas; sin audio en v1 y `audioDirectory` SIEMPRE se anula al exportar (D4). Lectores rechazan `formatVersion` futuro con error claro; campos futuros desconocidos se ignoran (additive). `remappedForImport()` acuña IDs frescos en TODO preservando relaciones (speaker→segments, owner→action items) — importar dos veces = dos reuniones. UI: export en el menú del detalle (sin audio / **con audio**), import por el open panel (UTI `app.portavoz.meeting-bundle`, ext `.portavoz`, declarado en make-app.sh) y doble-click (delegate `application(_:open:)` → pendingRoute). **Audio (jul 2026)**: `audioFiles: [AudioAttachment]?` (name+ext+Data; base64 nativo de Codable) — campo ADITIVO sin bump de versión: los lectores 0.3.0 ignoran el campo e importan solo texto; los nuevos materializan los canales en `Audio/<uuid>/` y enganchan `audioDirectory` (el import queda con player/waveform/clips). Para archivos tamaño-mail: comprimir con AAC antes de exportar.
