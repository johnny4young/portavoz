# Spec 07 — Interfaces: CLI, MCP, and exporters

Status: implemented; MCP verified E2E with a real agent. Decisions: D12 (sharing ladder), D22 (RAG), D47 (revision-fenced CLI refine persistence), D51 (safe atomic bundle import), D52 (read-consistent off-main bundle export), D67–D69 (enforced meeting-content egress, including explicit publishing), D75 (persisted CLI privacy receipts), D76 (local support evidence is not an outbound integration), D79 (disposable Release scale evidence), D81 (production lexical candidate benchmark), D82 (isolated semantic resource benchmark), D83 (comparable semantic after matrix), D84 (copied real-audio waveform evidence), D85 (protected measured Spotlight reconciliation), D87 (portable typed evidence), D88 (portable current claim feedback), D89 (portable decision evidence), D90 (portable action-item evidence), D91 (portable role-separated Apuntador evidence), D100 (shared Ask workflow across app, CLI, and MCP), D102 (one executable composition and bounded meeting reads), D103 (terminal product workflows enter ApplicationKit), D115 (private-iCloud receipt evidence), D116 (filesystem-capability-safe private publication).

## CLI — `portavoz-cli` (dispatch in `Sources/portavoz-cli/CLI.swift`)

SPM binary (`swift build --product portavoz-cli` → `.build/debug/portavoz-cli`). Shares the DB and models with the app (including the configurable recordings folder, via `RecordingsLocation`).

`CLIPlatformDependencies` is constructed once per process and owns the concrete
PlatformKit Keychain adapter, async `ManageSecrets` boundary, and encrypted
voice stores. `CLIComposition.open` is the single product database composition
surface. Meeting list/detail/search/open-item reads enter
`ApplicationKit.QueryMeetingLibrary`; Ask enters `AskMeetings`; MCP assembles
its tools from those two workflows. Detail and the latest live General summary
come from one read-consistent StorageKit snapshot. Commands retain parsing and
terminal/protocol formatting. Standalone transcription, diarization,
summarization, persisted refinement, document and action publication, local
voice identity, and pinned-model lifecycle enter ApplicationKit workflows.
`CLIProductAdapters` confines concrete files, models, Store, provider,
integration, voice, and streaming-fingerprint behavior. Capture diagnostics
and benchmark harnesses deliberately retain isolated direct construction.

| Command | Usage (from the code) |
|---|---|
| `devices` | Lists inputs (including iPhones via Continuity) |
| `record` | `[--seconds N] [--mic <name-or-uid>] [--pid <pid> …] [--system] [--out <dir>] [--transcribe] [--language es] [--models-dir <dir>] [--aec] [--no-aec]` — raw capture is the default; `--aec` explicitly opts into voice processing for diagnostics, while legacy `--no-aec` remains a compatible no-op |
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
| `bench-fts` | `[--meetings N] [--segments-per-meeting N]` — legacy disposable FTS harness |
| `bench-scale` | `[--library-sizes 1000,10000,50000,100000] [--meeting-minutes 30,120,480] [--runs 20] [--output report.json]` — Release-only tracked scale matrix over throwaway databases; lexical timing calls the exact ApplicationKit candidate policy without loading embeddings (D79/D81) |
| `bench-semantic` | `[--segments 100000] [--runs 20] [--output checkpoint.json]` — one production-schema semantic checkpoint with 512-dimensional deterministic vectors, exact-top-result validation, wall/CPU/footprint metrics; `scripts/run-semantic-scale-baseline.sh` isolates and aggregates comparable 1k/10k/50k/100k Release matrices (D82/D83) |
| `bench-waveform` | `[--mic <audio>] [--system <audio>] [--buckets 600] [--runs 20] [--output report.json]` — Release waveform probe that copies one or both channels to a unique throwaway directory, reports format/size/duration but no source paths or content, separates first/repeat wall/CPU/footprint distributions, fingerprints the exact buckets, and replaces its scratch input to characterize invalidation (D84) |
| `bench-spotlight` | `[--mode legacy|snapshot] [--meetings N] [--runs N] [--delivery-items N] [--output report.json]` — Release projection probe over a throwaway production-schema database. The wrapper runs isolated 1k/10k/100k legacy and snapshot processes, checks exact fingerprints, and may publish only synthetic items to a unique protected named index before deleting them (D85) |

`meetings refine` parses identity and optional external-audio/language/
vocabulary/threshold input, then enters `RefinePersistedMeeting`. The workflow
loads the current detail, resolves retained or explicit audio through an
injected file adapter, runs the same `RefineMeeting` draft policy as the app,
and applies through the same `MeetingStore.applyRefinedCast` Unit of Work.
Language, cast, transcript, and `transcriptRevision` therefore commit
atomically, and a concurrent transcript change rejects the stale result instead
of overwriting newer truth. Terminal progress retains download path, channel
timing, and diarization-threshold output without exposing model construction to
the command (D47/D103).

The `ask` command opens the requested Store at composition and then enters the
same `ApplicationKit.AskMeetings` workflow as the macOS Ask surfaces. The CLI
formats only the returned storage-independent answer and citations. An
unavailable or failed on-device answer keeps and prints the most relevant
evidence instead of discarding successful retrieval (D100).

Keychain credentials are read through `ManageSecrets`. Gist and issue workflows
first admit the local meeting plus rendered document or pending-item set. Only
then does the publisher adapter prepare once by resolving the device secret or
its explicit environment-variable fallback. Missing meetings and empty pending
sets do not read Keychain or print an egress warning; successful preparation
precedes the warning and transport. IntegrationsKit publishers receive only the
resolved token and never import or construct Keychain.

`transcribe`, `diarize`, and `summarize` use ApplicationKit file-analysis
workflows. ApplicationKit owns file admission, ordering, timing, attribution,
meeting identity, optional persistence, and stable progress values; adapters
load only the pinned engines required by the command. Saved external
summarization commits meeting/cast/transcript before provider egress and the
immutable summary afterward. `voice` delegates enroll/status/delete to one
local-identity workflow, and `models` delegates catalog-order
inspect/verify/download to one lifecycle workflow. Synchronous download
callbacks are serialized and drained before a terminal success or failure is
reported (D75/D103).

## MCP server — `portavoz-cli mcp`

- Transport: **JSON-RPC 2.0 over stdio, newline-delimited**; protocolVersion `2024-11-05`. Storage-agnostic protocol layer in IntegrationsKit (`MCPServer`, `MCPTool` with Data→String handlers, raw JSON schemas); the toolbox is assembled in the CLI (`MeetingToolbox`).
- Registration with an agent: `claude mcp add portavoz -- portavoz-cli mcp`.
- **6 tools**: `list_meetings` · `search_meetings` (FTS with snippets+ids+timestamps) · `get_transcript` (attributed) · `get_summary` (latest read-consistent General snapshot + action items) · `get_action_items` (global pending items) · `ask` (the shared ApplicationKit hybrid on-device workflow with bounded per-term lexical candidates, complete selected segments, and citations).
- Verified E2E: an MCP agent answered "what did we agree about the transcription budget?" with the correct sources.

## Exporters — IntegrationsKit

- `MeetingExporter`: canonical Markdown (title/metadata/summary with demoted headings/pending items/attributed transcript) and **PDF via pure CoreText** (without AppKit — builds for iOS; US Letter pagination verified with CGPDFDocument).
- **Single-meeting document preparation/publication (D103/D105):**
  ApplicationKit loads one coherent current detail/General-summary projection.
  Meeting Detail receives canonical Markdown/PDF bytes and its released
  title-based suggested filename for the native save surface. Terminal export
  returns Markdown, writes Markdown/PDF through an injected file port, or
  invokes an explicit Gist publisher. Secret-Gist adapters resolve credentials only after the local
  document exists. Pending issue publication uses the same projection shape,
  resolves owner names from its cast, filters unfinished actions, and preserves
  their stored order. SwiftUI and command files do not read Store, render the
  canonical document, or construct IntegrationsKit publishers.
- **Whole-library Markdown backup (D99):** ApplicationKit receives the canonical renderer through `LibraryMarkdownBackupDocuments` and filesystem publication through `LibraryMarkdownBackupFiles`; IntegrationsKit and `FileManager` never enter Settings SwiftUI. The app renderer runs at utility priority. The filesystem adapter enumerates visible existing Markdown names, atomically writes a UUID temporary file in the chosen directory, and moves it to the final portable name without replacement. A collision advances the application allocator; source, document, and publication failures remain typed per meeting while healthy files continue.
- `GistPublisher`: exact `https://api.github.com/gists`, secret by default, explicit `--public`; token from Keychain. Construction requires a `DataEgressGateway`, and publication requires the source `MeetingID`.
- `GitHubIssuesExporter` (canonical REST `https://api.github.com/repos/{owner}/{repo}/issues`) and `LinearExporter` (exact GraphQL `https://api.linear.app/graphql`; **the token is sent bare in Authorization, WITHOUT a Bearer prefix**): action items → issues. Both require a gateway and source meeting. Tested offline; real publishing pending the user's tokens.
- Output to external services ALWAYS requires explicit confirmation (D8): the UI confirms before the gist; the CLI is opt-in by nature.

### Shared data-egress adapter (D67–D69)

IntegrationsKit now implements `URLSessionDataEgressGateway`, the concrete
adapter for Core's content-free `DataEgressGateway` port. Before sending it
requires an HTTP(S) destination with a host to equal the request URL and
validates the operation-specific provider, classification, consent, and
meeting metadata.
Apuntador BYOK is the first production consumer: it declares only a classified
knowledge question, distinguishes provable loopback from conservative remote
scope, and never sends recent transcript passages. The adapter carries payload
bytes separately from metadata so persisted privacy receipts and future
diagnostics do not duplicate meeting content. OpenAI-compatible summary generation is the
second consumer: app-owned Ollama calls and CLI `summarize --byok` require the
gateway, real source `MeetingID`, full-summary classification, exact provider,
model, destination and operation-specific consent. Only Ollama discovery stays
direct because those requests contain no meeting material.

D69 adds three operation-specific publishing contracts. Gist requests declare
`publish-github-gist`, complete meeting-export document material, explicit Gist
consent, the source meeting, GitHub's provider host, no model, and remote scope.
GitHub and Linear requests declare their own create-issue operations,
meeting-action-item material, and provider-specific explicit consent. The
adapter requires non-empty POST bodies and exact operation/classification/
consent/provider combinations. It accepts only the exact Gist and Linear URLs
or a canonical GitHub repository-issues path with no port, query, fragment,
empty owner/repository, or dot traversal. Forged metadata fails before
transport. App confirmation, CLI opt-in/warnings, body and authorization shape,
response parsing, and failure behavior remain unchanged.

Every current HTTP path that carries meeting content now crosses this gateway.
Content-free Ollama discovery and model downloads remain direct by design. The
post-meeting Shortcut is an explicit local `/usr/bin/shortcuts` process surface,
not a network adapter; its user-configured Shortcut may independently perform
external actions outside Portavoz's process.

D75 injects the opened `MeetingStore` as `DataEgressEventRecorder` for CLI Gist
and issue publication. `summarize --save` now commits the meeting, cast, and
transcript before an external summary call, then uses that same store-backed
gateway. A failed provider therefore leaves both the expensive transcript and
the attempted-transfer receipt available. Transient `summarize` without
`--save` keeps its existing no-database behavior and makes no durable receipt
claim. The concrete gateway validates first, writes the content-free attempt
second, blocks every redirect, and transports last. Receipt failure prevents
the request; HTTP failure retains the attempt because bytes may already have
been transmitted.

D76's support JSON is deliberately not an IntegrationsKit publisher and never
crosses `DataEgressGateway`: the user explicitly saves a redacted local file
through the native app panel. Portavoz performs no upload or sharing action.
If the user later attaches that file to another application, that is a visible
macOS file action outside Portavoz's transport graph. This keeps the existing
privacy receipt as the only in-product network-egress truth.

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
- **Spotlight** (`SpotlightIndexer`, Jul 2026): local Core Spotlight search uses one process-scoped actor and one consistent StorageKit snapshot. Launch and searchable mutations request a reconciliation; 250 ms burst coalescing, compact SHA-256 client state, and retries make it independent of a SwiftUI window. Publication replaces the meeting domain in a named `app.portavoz.meetings.v2` index with complete file protection and 500-item batches, then removes the released default-index domain only after the protected index is ready. Unchanged state is a no-op; `-use-temp-store` suppresses OS indexing. Each item retains title + date + newest cross-recipe summary + first 40 ordered live segments (cap 4,000 characters), with the meeting UUID as identifier. A measured 100,000-meeting projection is 425.64 ms wall p95 versus 22,085.35 ms for the legacy N+1 path, so D85 rejects an outbox consumer at the measured scale. The hit still navigates via `onContinueUserActivity(CSSearchableItemActionType)` → `Route.meeting`. **Double GOTCHA (field, Jul 2026)**: (1) without `NSUserActivityTypes: [com.apple.corespotlightitem]` in Info.plist, macOS discards the continuation; (2) even with it, SwiftUI's `onContinueUserActivity` does NOT fire on macOS — the activity reaches the classic `NSApplicationDelegate`. `PortavozAppDelegate.application(_:continue:)` (via `@NSApplicationDelegateAdaptor`) parses the identifier and navigates through `AppServices.pendingRoute` (the banner channel); ContentView also applies any `pendingRoute` present WHEN MOUNTING (cold start: the activity may arrive before the window, and `onChange` does not fire for the initial value).
- **`.portavoz` bundle** (`MeetingBundle`, IntegrationsKit, Jul 2026 — M15 L0): versioned JSON (ISO8601, sortedKeys) with meeting+speakers+segments+summary+typed overview/decision/action-item evidence+current overview feedback+action items+notes+Apuntador cards with optional question/answer evidence and optional audio; `audioDirectory` is ALWAYS cleared on export (D4). Readers reject a future `formatVersion` with a clear error; unknown future fields are ignored. All later fields remain optional/additive under formatVersion 1, so older readers import the subset they understand. `remappedForImport()` mints fresh IDs for every imported entity while preserving relationships: feedback follows its remapped overview claim, each decision keeps its rendered coordinate, action evidence follows its fresh task identity, Apuntador evidence follows its fresh card identity, and every evidence link follows its fresh segment — importing twice creates two independent meetings. Foreign or malformed nested Apuntador evidence is dropped without losing the card or legitimizing the wrong relation. UI: export from the detail menu (without audio / **with audio**), import through the open panel (UTI `app.portavoz.meeting-bundle`, extension `.portavoz`), and double-click routing. Import decoding/remapping remains a private IntegrationsKit adapter and runs off the MainActor. Its ApplicationKit handoff rejects path-shaped/unknown channel names, unsupported extensions, duplicate channels, and foreign evidence; only system/microphone m4a/caf/wav attachments can materialize as canonical files under `Audio/<fresh-uuid>/`. Meeting, cast, transcript, immutable summary/actions/evidence/feedback, notes, and Apuntador cards/evidence then commit as one aggregate; a final evidence-link failure rolls back the transaction, compensates staged audio, and never publishes a partial Library entry (D51). Export now loads that content from one live StorageKit snapshot, strips the local directory in ApplicationKit, and performs optional full-channel reads plus IntegrationsKit format-v1 encoding at utility priority; missing/unreadable channels remain omitted and SwiftUI retains the native save panel (D52/D87/D88/D89/D90/D91). For email-sized files, compress with AAC before exporting.
- **Meeting sync codecs** (`MeetingSyncEnvelopeCodec` + `CloudMeetingRecordCodec`, IntegrationsKit, Bands 6B1–6B2A): deterministic sorted-key JSON with millisecond timestamps wraps StorageKit's exact-generation text-first envelope. One dormant private-zone `MeetingReplica` stores payloads within a conservative 512 KiB policy in `encryptedValues`; larger payloads use a private CKAsset staging file whose content CloudKit encrypts by default. Content-free `0600` probes in the destination directory independently apply and read back complete protection and backup exclusion. Supported metadata is applied while the staging sibling is empty; only direct or wrapped `EINVAL`/`ENOTSUP` omits the unavailable key, and every other failure stays closed. One POSIX descriptor then handles partial writes and `EINTR`, synchronizes with `fsync`, closes, and verifies exact size plus owner-only permissions before one same-volume atomic rename. Supported metadata is also verified, no Foundation reopen occurs, and partial content never occupies the final path. The digest is encrypted, matching records are reused to preserve system fields, malformed records fail closed, and deletion remains a saved tombstone. The envelope carries every live portable summary/evidence version but no audio, local paths, embeddings, canonical people, generation provenance, jobs, receipts, secrets, or voiceprints (D93/D94/D116).
- **Dormant CloudKit transport** (`CloudMeetingSyncStateStore` + `CloudMeetingSyncCoordinator` + `CloudMeetingSyncEngineDelegate` + `CloudMeetingSyncRuntime`, IntegrationsKit, Band 6B2B): a separate owner-only snapshot stores only hashed account scope/explicit consent/seed policy, opaque CKSyncEngine serialization, CKRecord system fields, exact attempt metadata, deterministic bounded retries, replay cursors, and deferred-replay metadata. Exact outgoing and deferred bytes use the same capability-probed metadata over mandatory `0600`, POSIX write/`fsync`, verification, and atomic-publication primitive. Account loss pauses without erasing attempts; account switches reset old account-scoped metadata and require consent for the new account. StorageKit remains the mutation/replay authority; explicit initial seed calls its journal API and completes only after journal plus attempts drain. Late callbacks settle only exact generations, pending preparation reconciles both durable stores, callback failures re-add their exact engine change, partial failures remain independent, and physical CKRecord deletions invalidate metadata without deleting content. The runtime can build a manually driven engine only from an injected CKDatabase, restored state, and the thin delegate; automatic sync is disabled. App composition creates no CKContainer, requests no account, adds no entitlement, performs no sync network request, and exposes no UI (D95/D116).
- **Cloud sync lifecycle policy** (`CloudMeetingSyncLifecycle`, IntegrationsKit, Band 6C1): one CloudKit-free actor composes the D95 store/coordinator/delegate behind injected account and manual-driver protocols. An unconsented launch returns local-only without calling the platform. Explicit enable binds consent to the available account; existing-library seed remains a separate action. Account loss pauses while retaining consent and attempts; account switch clears the old scope. Status combines only the content-free StorageKit pending count, protected queue/retry/seed/account state, and typed failures. Pause preserves queue/local/remote data; remove clears only this device's transport files/metadata; explicit retry re-admits the exact generation/payload while retaining attempt history. No CKContainer, entitlement, app network composition, or UI exists in this slice (D96).
- **macOS Cloud sync composition** (`CloudKitMeetingSyncPlatform` + `MeetingSyncModel`, Band 6C2): one inert IntegrationsKit actor creates the named container only after D96 consent and a fail-closed signed-capability/profile probe, checks account status before user identity, and gives the manually driven D95 runtime only the private database. One process-scoped app model serializes explicit actions FIFO and coalesces content-free journal, account, retry, and silent-push wakeups; SwiftUI owns none of those lifecycles. A bilingual Settings pane exposes six truthful phases plus distinct enable, manual sync, retry, existing-library seed, pause, and remove-this-Mac actions, while explicitly excluding audio, paths, voiceprints, secrets, and embeddings. Local/XCUITest builds use no restricted capabilities or host CloudKit; Developer ID artifacts must embed an unexpired profile whose exact production container/service/environment/push values match the signed app before notarization and after DMG extraction (D97).
