# Spec 07 — Interfaces: CLI, MCP, and exporters

Status: implemented; MCP verified E2E with a real agent. Decisions: D12 (sharing ladder), D22 (RAG), D47 (revision-fenced CLI refine persistence).

## CLI — `portavoz-cli` (dispatch in `Sources/portavoz-cli/CLI.swift`)

SPM binary (`swift build --product portavoz-cli` → `.build/debug/portavoz-cli`). Shares the DB and models with the app (including the configurable recordings folder, via `RecordingsLocation`).

| Command | Usage (from the code) |
|---|---|
| `devices` | Lists inputs (including iPhones via Continuity) |
| `record` | `[--seconds N] [--mic <name-or-uid>] [--pid <pid> …] [--system] [--out <dir>] [--transcribe] [--language es] [--models-dir <dir>] [--no-aec]` |
| `transcribe` | `--file <wav> [--engine parakeet\|whisper] [--vocab "a,b,c"] [--language es] [--models-dir <dir>]` |
| `diarize` | `--file <wav> [--attribute] [--threshold t] [--language es] [--models-dir <dir>]` |
| `summarize` | `--file <wav> [--out-language es] [--glossary a,b,c] [--byok <endpoint> --byok-model <model>] [--save] [--db <path>]` — full wav→transcript→diarization→summary pipeline |
| `meetings` | `list \| show <uuid> \| search <texto> \| refine <uuid> [--file <wav>] [--language es] [--vocab "…"] [--db] [--models-dir]` |
| `export` | `--meeting <uuid> [--format md\|pdf] [--out <path>] [--gist [--public]]` |
| `secrets` | `set-github-token <token> \| clear-github-token` (Keychain; equivalents for Linear) |
| `voice` | `enroll [--file <wav>] \| status \| delete` |
| `der` | `--file <wav> --reference <rttm> [--threshold t] [--collar s]` — DER harness |
| `mcp` | MCP server over stdio (see below) |
| `ask` | `"<pregunta>" [--db <path>] [--limit n]` — local RAG with citations |
| `issues` | `--meeting <uuid> (--github <owner/repo> \| --linear-team <id>)` |
| `models` | `download \| verify \| path` — complete sha256 catalog |
| `bench-m2` | M2 acceptance harness (live lag + concurrent batch) |

`meetings refine` still owns its CLI/model presentation pipeline, but accepted
results now persist through the same `MeetingStore.applyRefinedCast` Unit of
Work as the app boundary. Language, cast, transcript, and
`transcriptRevision` therefore commit atomically, and a concurrent transcript
change rejects the stale CLI result instead of overwriting newer truth (D47).

## MCP server — `portavoz-cli mcp`

- Transport: **JSON-RPC 2.0 over stdio, newline-delimited**; protocolVersion `2024-11-05`. Storage-agnostic protocol layer in IntegrationsKit (`MCPServer`, `MCPTool` with Data→String handlers, raw JSON schemas); the toolbox is assembled in the CLI (`MeetingToolbox`).
- Registration with an agent: `claude mcp add portavoz -- portavoz-cli mcp`.
- **6 tools**: `list_meetings` · `search_meetings` (FTS with snippets+ids+timestamps) · `get_transcript` (attributed) · `get_summary` (latest snapshot + action items) · `get_action_items` (global pending items) · `ask` (hybrid on-device RAG with citations).
- Verified E2E: an MCP agent answered "what did we agree about the transcription budget?" with the correct sources.

## Exporters — IntegrationsKit

- `MeetingExporter`: canonical Markdown (title/metadata/summary with demoted headings/pending items/attributed transcript) and **PDF via pure CoreText** (without AppKit — builds for iOS; US Letter pagination verified with CGPDFDocument).
- `GistPublisher`: `api.github.com/gists`, secret by default, explicit `--public`; token from Keychain.
- `GitHubIssuesExporter` (REST) and `LinearExporter` (GraphQL; **the token is sent bare in Authorization, WITHOUT a Bearer prefix**): action items → issues. Tested offline; real publishing pending the user's tokens.
- Output to external services ALWAYS requires explicit confirmation (D8): the UI confirms before the gist; the CLI is opt-in by nature.

## Known limitations

1. MCP without auth (local process over stdio — acceptable; the security plan requires localhost+token if a network transport is ever added).
2. `issues` and `export --gist` verified offline; real publishing with the user's tokens pending.
3. Native AppIntents/Siri phrases are not registered because the shipping app
   remains an SPM-built bundle; the post-meeting Shortcut hook, URL scheme,
   and Spotlight are implemented. Native intents are deferred to M14a's Xcode
   app target.

## M16 automation (Jul 2026)

- **Post-meeting hook**: `PostMeetingShortcut.runIfConfigured(markdown:)` — when stop reaches `.done`, if Ajustes → Automation has a Shortcut name, runs `/usr/bin/shortcuts run <name> --input-path <tmp.md>` with the complete Markdown export (MeetingExporter). Deliberately fire-and-forget: it never blocks or delays the pipeline; Shortcut failures are visible in Shortcuts (the meeting is saved regardless).
- **URL scheme** `portavoz://record` (CFBundleURLTypes in make-app.sh): opens the app and STARTS a recording — always visible (window + mic indicator; nothing records while hidden). Verified E2E: `open "portavoz://record"` launches, navigates, and records. Combined with Shortcuts automations (time/calendar), this provides scheduled auto-recording.
- **AppIntents/Siri**: deferred to M14a — appintentsmetadataprocessor only runs in Xcode builds; the make-app.sh SPM bundle does not register intents.
- **Spotlight** (`SpotlightIndexer`, Jul 2026): local CSSearchableIndex — full rebuild (delete domain + insert) at launch and with every `libraryVersion` (inexpensive: metadata only; immune to deletion drift; `-use-temp-store` suppresses it). Each item: title + date + summary/first 40 lines (cap 4000 chars), with the meeting UUID as identifier; the hit navigates via `onContinueUserActivity(CSSearchableItemActionType)` → `Route.meeting`. **Double GOTCHA (field, Jul 2026)**: (1) without `NSUserActivityTypes: [com.apple.corespotlightitem]` in Info.plist, macOS discards the continuation; (2) even with it, SwiftUI's `onContinueUserActivity` does NOT fire on macOS — the activity reaches the classic `NSApplicationDelegate`. `PortavozAppDelegate.application(_:continue:)` (via `@NSApplicationDelegateAdaptor`) parses the identifier and navigates through `AppServices.pendingRoute` (the banner channel); ContentView also applies any `pendingRoute` present WHEN MOUNTING (cold start: the activity may arrive before the window, and `onChange` does not fire for the initial value).
- **`.portavoz` bundle** (`MeetingBundle`, IntegrationsKit, Jul 2026 — M15 L0): versioned JSON (ISO8601, sortedKeys) with meeting+speakers+segments+summary+action items+notes+Companion cards and optional audio; `audioDirectory` is ALWAYS cleared on export (D4). Readers reject a future `formatVersion` with a clear error; unknown future fields are ignored. All later fields remain optional/additive under formatVersion 1, so older readers import the subset they understand. `remappedForImport()` mints fresh IDs for every imported entity while preserving relationships — importing twice creates two independent meetings. UI: export from the detail menu (without audio / **with audio**), import through the open panel (UTI `app.portavoz.meeting-bundle`, extension `.portavoz`), and double-click routing. `audioFiles: [AudioAttachment]?` materializes channels in `Audio/<uuid>/`; optional `companionCards` are remapped and persisted with the imported meeting. For email-sized files, compress with AAC before exporting.
