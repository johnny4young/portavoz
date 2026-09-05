# Spec 07 — Interfaces: CLI, MCP, and exporters

Status: implemented; MCP verified E2E with a real agent. Decisions: D12 (sharing ladder), D22 (RAG), D47 (revision-fenced CLI refine persistence), D51 (safe atomic bundle import), D52 (read-consistent off-main bundle export), D67–D69 (enforced meeting-content egress, including explicit publishing), D75 (persisted CLI privacy receipts), D76 (local support evidence is not an outbound integration), D79 (disposable Release scale evidence), D81 (production lexical candidate benchmark), D82 (isolated semantic resource benchmark), D83 (comparable semantic after matrix), D84 (copied real-audio waveform evidence), D85 (protected measured Spotlight reconciliation), D87 (portable typed evidence), D88 (portable current claim feedback), D89 (portable decision evidence), D90 (portable action-item evidence), D91 (portable role-separated Apuntador evidence), D100 (shared Ask workflow across app, CLI, and MCP), D102 (one executable composition and bounded meeting reads), D103 (terminal product workflows enter ApplicationKit), D115 (private-iCloud receipt evidence), D116 (filesystem-capability-safe private publication), D179 (capture-safe existing-library sync admission), D183 (bounded backup destination identity), D184 (durable backup publication evidence), D185 (strict staged-source adoption), D186 (successful-publication source checkpoints), D187 (fail-closed pending-publication reconciliation), D188 (durable typed backup failure outcomes), D189 (fail-closed backup launch continuation), D233 (correction-lineage invalidation before composed interfaces), D234 (correction-aware documents and protected correction replay), D237 (transport-neutral confirmed commitment replay), D356 (bounded legacy CLI input and drained capture tasks), D385 (loopback-only manual Ask egress), D386 (explicit Library-only terminal Ask policy), D387 (macOS-only direct-Web source policy).

Native automation decisions: D324 (honest Start/Stop actions), D325 (bounded
meeting/person/commitment App Entities and exact open routes), and D326
(availability-shaped protected entity publication). D327 adds one review-first
email-composer handoff without adding an email transport. D328 adds one exact
secret-Gist Skill through the existing protected Gist transport. D434 adds one
review-first pending-action-item GitHub issue through the existing protected
issue transport.

D437's standing pre-meeting brief is deliberately a macOS Settings/EventKit
surface, not a CLI, MCP, App Intent, exporter, or network adapter. Neither
terminal interface can create, enable, retry, or delete unattended authority,
and the local brief artifact is not added to portable meeting bundles, support
diagnostics, or CloudKit. External interface actions remain proposal-scoped.

The email recap Skill is an AppKit interface adapter, not a network
integration. ApplicationKit composes one summary-derived `MeetingRecap` behind
an explicit `sendRemote` proposal. Meeting Detail shows the exact plain-text
subject/body, no recipients, and the external-app sync boundary before the
confirm action grants proposal-scoped egress. The app then constructs
`NSSharingService(.composeEmail)` task-locally on the main actor, sets an empty
recipient list and the approved subject, and hands over the approved body.
Portavoz stores no destination, credential, or reusable consent, performs no
request, and never invokes Send. The resulting receipt means only that the
system composer handoff was requested; whether the external client saves,
syncs, edits, or sends remains visibly under user control.

The secret-Gist Skill is the networked interface counterpart. ApplicationKit
owns the immutable `SecretGistDraft` and explicit `sendRemote` proposal; the
app composes it through the canonical correction-aware Markdown workflow,
compares the complete approved draft before claim, and prepares the existing
Keychain-backed publisher. `GistPublisher` still owns the exact
`https://api.github.com/gists` request, secret-by-default payload, and response
codec, while `URLSessionDataEgressGateway` still validates the endpoint,
classification, provider disclosure, meeting identity, and consent source.
The proposal UUID is injected as the data-egress event UUID, so its durable
pre-transport insert is also the local no-duplicate fence. Missing credentials
are retryable before claim; every later failure is outcome unknown and never
authorizes another automatic request. The returned Gist URL is immediate UI
output, not durable receipt content.

The GitHub issue Skill reuses `GitHubIssuesExporter` rather than adding an app-
specific publisher. ApplicationKit owns a bounded correction-aware
`GitHubIssueDraft` for one current pending action item and exactly one current
evidence record. The two-stage app sheet first admits a canonical ASCII
`owner/repository`, then shows the exact destination, title, body, citations,
and egress disclosure. Citation time is finite, nonnegative, and bounded below
the platform integer-conversion limit; the formatter revalidates that contract
and returns typed unavailable evidence instead of converting corrupt timing.
Confirmation recomputes every reviewed byte before the Keychain token, durable
claim, or egress event can exist. The proposal UUID is
the data-egress event UUID; the event insert precedes transport and the
idempotency key includes action item plus repository. The production adapter
uses an ephemeral no-cookie/no-cache session with 15-second request and
20-second resource deadlines and no waits-for-connectivity. A response is
accepted only when it names the exact reviewed repository at
`https://github.com/<owner>/<repository>/issues/<positive id>` without port,
userinfo, query, or fragment. Missing credentials remain known before claim;
every later transport, provider, decode, settlement, or interruption failure
is terminal outcome unknown and cannot authorize an automatic retry.

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

The original hand-written development commands share a strict throwing value
reader rather than silently retaining defaults. String values must be present
and non-empty; numeric values must parse exactly, floating-point values must be
finite, and all values are admitted before any concrete side effect. Recording
and live-benchmark durations are `1...86,400` seconds, Ask result limits are
`1...50`, process IDs fit a positive `pid_t`, diarization thresholds are inside
`0...1`, and DER collars are `0...60` seconds. The disposable FTS harness
accepts at most 100,000 meetings and 10,000 segments per meeting, then uses
checked multiplication and rejects any corpus above 1,000,000 segments.

`record` owns and drains every live-transcription task. Normal completion
finishes its channel streams and awaits them; cancellation or capture failure
first stops the recording session, then finishes, cancels, and awaits them.
`bench-m2` starts its batch loop only after microphone admission. Cancellation
stops the microphone, finishes the feed, cancels the feeder and in-flight batch,
and awaits both. Normal benchmark completion still lets the current batch pass
finish so the reported concurrent-load measurement remains comparable.

| Command | Usage (from the code) |
|---|---|
| `devices` | Lists inputs (including iPhones via Continuity) |
| `record` | `[--seconds N] [--mic <name-or-uid>] [--pid <pid> …] [--system] [--out <dir>] [--transcribe] [--language es] [--models-dir <dir>] [--aec] [--no-aec]` — raw capture is the default; `--aec` explicitly opts into voice processing for diagnostics, while legacy `--no-aec` remains a compatible no-op |
| `transcribe` | `--file <wav> [--engine parakeet\|whisper] [--vocab "a,b,c"] [--language es] [--models-dir <dir>]` |
| `diarize` | `--file <wav> [--attribute] [--threshold t] [--language es] [--models-dir <dir>]` |
| `summarize` | `--file <wav> [--out-language es] [--glossary a,b,c] [--byok <endpoint> --byok-model <model>] [--save] [--db <path>]` — full wav→transcript→diarization→summary pipeline |
| `meetings` | `list \| show <uuid> \| search <texto> \| refine <uuid> [--file <wav>] [--language es] [--vocab "…"] [--db] [--models-dir]` |
| `export` | `--meeting <uuid> [--format md\|pdf\|srt\|vtt] [--out <path>] [--gist [--public]]` — Markdown may print to stdout; PDF and subtitle formats require an output path |
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
| `bench-semantic` | `[--segments 100000] [--runs 20] [--variants 1] [--output checkpoint.json]` — one production-schema schema-2 semantic checkpoint with deterministic normalized vectors, exact-top-result validation, compatibility profile/asset disclosure, and separate store-open/corpus-seed/warmup/measured-query wall/CPU plus footprint metrics. `scripts/run-semantic-scale-baseline.sh` isolates each scale in a fresh Release process and seals source, binary, toolchain, host, fixture, query-pack, profile, asset, configuration, and stage identity into one fail-closed manifest; `PORTAVOZ_SEMANTIC_SCALE_VARIANTS` selects the bounded query batch. `scripts/run-semantic-control-baseline.sh` alternates three canonical and three diagnostic matrices from one clean unchanged source, validates both aggregate receipts, then publishes them owner-only. Either runner may set `PORTAVOZ_SEMANTIC_SOURCE_ROOT` to a separate clean source worktree while retaining the current checkout's newer validation tools. `scripts/semantic_scale_manifest.py compare` refuses unlike or legacy evidence; `baseline` requires three unique clean same-identity canonical-scale manifests and retains aggregate-only one-vector control or a separately scoped three-vector diagnostic; `cross-host` embeds and revalidates one canonical control receipt per 8 GiB, 16 GiB, and reference profile, requires collective Sequoia/Tahoe coverage, and emits an incomplete matrix with no authority until the real set is complete (D82/D83/D345–D347) |
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
D386 keeps this frozen terminal contract explicitly Library-wide. CLI and MCP
both pass `.library` to the source-required application workflow; they do not
infer a meeting, expose the macOS Web choice, or inherit mutable UI
selection. A future terminal source option must be an explicit versioned
interface change with its own consent and compatibility review.
D387 does not widen CLI or MCP. Direct Web authority is macOS-only and bound to
its per-request consent surface; terminal callers cannot reuse it implicitly.

`bench-ask-attribution` is deliberately separate from product `ask` and the
canonical `bench-ask-quality` observation contract. It accepts the same
fixture/output/build/commit/retrieval-unit identity but rejects asset downloads.
It indexes only an isolated disposable corpus, observes actual Library
lexical/fused evidence and batched semantic candidates, and atomically writes
one owner-only, non-overwriting `ask-quality-attribution` document. The nested
canonical observation is unchanged; profile/coverage/stage fields belong only
to this diagnostic envelope. Arbitrary provider/storage errors are not printed.
`scripts/ask_quality_attribution.py --fixture <json> --observations <json>
--output <json>` validates and summarizes that envelope into another private
non-serving artifact. This command does not add models, remote egress, answer
generation, app controls, or terminal authority over the user's Library.

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
- **9 tools**: the frozen ordered prefix `list_meetings` · `search_meetings` (FTS with snippets+ids+timestamps) · `get_transcript` (attributed) · `get_summary` (latest read-consistent General snapshot + action items) · `get_action_items` (global pending items) · `ask` (the shared ApplicationKit hybrid on-device workflow with bounded per-term lexical candidates, complete selected segments, and citations), plus the appended `portavoz-reading/2` tools `get_transcript_v2` · `get_summary_v2` · `get_action_items_v2`.
- **Correction boundary (D233/D234/D313):** search and Ask serve the corrected
  text of an active `replaceText` correction under its accepted segment
  identity, keep speaker-only-corrected lines findable, and continue omitting
  structurally corrected rows. The six v1 tools are frozen — same names, array
  order, accepted-only text, clamps, and error strings — so existing consumers
  observe no change. The appended v2 tools carry the composed contract: every
  response opens with one content-free header line, `portavoz-reading/2
  meeting=<uuid> base=<n> correction=<accepted|16-hex|unavailable>
  reading=<composed|accepted> composed=<current|pending>`. `get_transcript_v2`
  composes on demand and paginates composed rows ("Rows x-y of N"); any
  composition doubt downgrades to the accepted body with
  `reading=accepted composed=pending` (fail closed). `get_summary_v2` and
  `get_action_items_v2` always read accepted generated artifacts but disclose
  whether they predate the current corrections via `composed=pending`.
- **Read-only shape (MCP-001, Jul 2026)**: the `initialize` response carries `instructions` declaring the contract — every tool only reads, nothing can mutate the library, processing stays local, and `ask` is the preferred entry for questions. `get_transcript` is paginated by segment (`offset`/`limit`, default 200, cap 500) with a self-describing header naming the covered range, the total, and the exact offset to continue from — an agent never guesses whether more remains, and a past-the-end offset gets an honest one-line answer instead of an error. `search_meetings` accepts `limit` (default 20, cap 50); the boundary never sees an unbounded client value. `MeetingToolboxTests` covers the real catalog (shape, schemas, pagination overlap/bounds/caps, search clamping) — previously only the protocol layer had tests, against fakes.
- Verified E2E: an MCP agent answered "what did we agree about the transcription budget?" with the correct sources.

## Exporters — IntegrationsKit

D234 gives every document renderer one ApplicationKit-owned, correction-aware
projection over a coherent Library snapshot. Markdown, PDF, SRT, WebVTT, CLI,
and Gist export the composed reading while preserving accepted source IDs and
the original audio intervals. A summary from another correction revision is
omitted rather than exported as current. Correction provenance remains an
explicit option: Markdown/PDF append the disclosure and source map, WebVTT adds
a valid `NOTE` plus corrected-cue markers, and SRT uses only visible cue markers
so its grammar stays portable. Malformed or revision-mismatched history fails
closed before a renderer or publisher receives content.

- `SubtitleExport` (Jul 2026): SRT and WebVTT from the diarized transcript with caption discipline — consecutive rows merge only when their `SpeakerID` matches and the rendered cue, including its speaker prefix, remains within six seconds and 84 characters. Transcript text and user-assigned speaker names collapse line whitespace and neutralize the timestamp arrow; integer-millisecond timestamps use SRT's comma and VTT's period exactly; nonlexical rows never become cues. Reached from the Meeting Detail export menu, `PrepareMeetingDocument`, and the CLI export formats `srt`/`vtt`.
- `MeetingExporter.render(_:format:)` (Jul 2026): the single channel renderer for Portavoz-authored Markdown — plain text strips markers, Slack emits mrkdwn (`*bold*`, `•` bullets, no `#`), Markdown passes through canonical. Both the summary copy and the shareable recap ride it, so a channel convention is fixed in one place.
- `MeetingExporter`: canonical Markdown (title/metadata/summary with demoted headings/pending items/attributed transcript) and **PDF via pure CoreText** (without AppKit — builds for iOS; US Letter pagination verified with CGPDFDocument).
- **Single-meeting document preparation/publication (D103/D105):**
  ApplicationKit loads one coherent current detail/General-summary projection.
  Meeting Detail receives canonical Markdown/PDF/SRT/WebVTT bytes and its
  released title-based suggested filename for the native save surface.
  D234 composes current-revision correction history before rendering, preserves
  source IDs and original timing, and accepts one optional provenance flag.
  Subtitle formats use that same prepared content through a narrowed format
  port and retain extension-specific macOS content types.
  Terminal export returns Markdown, writes Markdown/PDF/SRT/WebVTT through an
  injected file port, or invokes an explicit Gist publisher. Secret-Gist
  adapters resolve credentials only after the local document exists. Pending
  issue publication uses the same projection shape,
  resolves owner names from its cast, filters unfinished actions, and preserves
  their stored order. SwiftUI and command files do not read Store, render the
  canonical document, or construct IntegrationsKit publishers.
- **Whole-library Markdown backup (D99/D181–D189):** ApplicationKit receives a process-owned staged-source session through `LibraryMarkdownBackupStore`, the canonical renderer through `LibraryMarkdownBackupDocuments`, filesystem publication and exact destination evidence through `LibraryMarkdownBackupFiles`, opaque destination identity plus bounded access through `LibraryMarkdownBackupDestinationAccess`, and owner-private publication evidence through `LibraryMarkdownBackupRecoveryStore`; IntegrationsKit and `FileManager` never enter Settings SwiftUI. StorageKit creates one coherent private SQLite stage through bounded GRDB page checkpoints and exposes one newest-first aggregate at a time. The ApplicationKit actor checkpoints before each source read and after content load, render, and atomic publication while retaining at most one pending aggregate/document. The app renderer runs at utility priority. The destination adapter prepares identity only after admission, resolves a fresh lease for each execution interval, and closes it on completion, suspension, or failure. The current non-App-Sandbox PlatformKit implementation uses a regular Foundation bookmark with `withoutImplicitSecurityScope`; a future sandbox adapter can balance security-scoped access behind the same port. The filesystem adapter enumerates visible existing Markdown names, atomically writes a UUID temporary file in the resolved directory, and moves it to the final portable name without replacement. Before that move, the use case atomically persists the exact portable filename, meeting identity, SHA-256, byte count, and—when safe—the matching content-free source cursor; after the move it records completion. No transcript, summary, or Markdown bytes enter the journal. A post-move journal failure preserves the published in-process result and retries the exact completion before advancing; bookmark refresh and failed-publication clearing likewise persist before their in-memory transitions. After immutable completion, the use case persists the stage's content-free cursor; equal retries are idempotent, backward cursors and pending-publication checkpoints fail closed, and a failed cursor write retries without repeating the destination move. Each source, document-render, or publication failure is recorded as a bounded immutable typed outcome at the exact staged-source cursor before that cursor may advance; ApplicationKit normalizes its title to at most 4 KiB of UTF-8, the journal stores no transcript, summary, or rendered Markdown bytes, and exact failure-record retries are idempotent. A successful render that has not yet produced a reservation is replayed from the immutable stage after interruption. A bounded reconciliation use case can inspect the exact no-follow regular destination file, clear a missing reservation for source retry, complete exact matching bytes, repair the checkpoint to the furthest immutable publication or failure cursor, or preserve conflicting or cursor-less evidence fail-closed. Failure-only and already-completed checkpoint repair do not reacquire the destination. Terminal retry removes the journal before closing the stage and does not reacquire the destination. A collision advances the application allocator; source, document, and publication failures remain typed per meeting while healthy files continue. Stage directories use Portavoz's canonical lowercase UUID form. Launch catalogs every canonical journal UUID before root-coordinated cleanup, preserving matching stages even when strict journal shape later fails. Zero journals cleans only provably abandoned unprotected stages; multiple journals fail closed without choosing. One journal enters the maintenance gate, reconciles exact destination evidence, and then adopts only its exact read-only stage and cursor. Validation requires contiguous unique outcomes and a checkpoint at the furthest durable cursor; the exporter rebuilds filename allocation from destination and journal evidence, reconstructs the typed result, and resumes after the checkpoint. Completed recovery removes the journal before closing the stage without destination access. Ambiguous, malformed, missing, conflicting, cursor-less, or unavailable evidence remains untouched and blocks a second backup. Setup failure abandons the adopted lease without deleting the immutable source, and capture-stop signals retry suspended recovery without polling.
- `GistPublisher`: exact `https://api.github.com/gists`, secret by default, explicit `--public`; token from Keychain. Construction requires a `DataEgressGateway`, and publication requires the source `MeetingID`.
- `GitHubIssuesExporter` (canonical REST `https://api.github.com/repos/{owner}/{repo}/issues`) and `LinearExporter` (exact GraphQL `https://api.linear.app/graphql`; **the token is sent bare in Authorization, WITHOUT a Bearer prefix**): action items → issues. Both require a gateway and source meeting. GitHub repository input uses the shared canonical ASCII value, accepts exact reviewed title/body material, and validates the returned issue URL against that same repository and a positive issue number. The review-first app path and CLI are tested offline; real publishing remains field evidence requiring test credentials and repositories.
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

Manual Ask is the third gateway-backed model consumer. The app-owned Ollama
adapter is pinned to `http://localhost:11434/v1`, declares
`ask-answer-generation` plus `meeting-answer-material`, carries no false single
meeting identity for cross-library evidence, and requires the user's selected
local-engine setting. Gateway validation rejects a forged remote destination,
wrong classification, wrong consent, empty model, redirect, or empty POST
before transport. Its receipt is persisted to schema v43's separate global
content-free table before URLSession can observe the body.

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

D434 makes the GitHub app path use that same contract with one exact
proposal-scoped event identity. It adds no reusable egress consent, automatic
retry, direct `URLSession.shared` path, or durable issue URL/content. A forged
success URL for another owner or repository is rejected after the attempt and
therefore becomes outcome unknown rather than a retryable failure.

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
3. The native Start action, URL route, post-meeting Shortcut hook, Spotlight
   indexing, and user-created Start Shortcut invocation from Spotlight and Siri
   are implemented and field-verified. The native Stop action is implemented
   and locally verified. Meeting, canonical-person, and confirmed-commitment
   App Entities and exact open actions are implemented and locally verified.
   Their protected native publication is implemented and deterministically
   verified at the storage, adapter, metadata, and app-route boundaries. Stop
   plus physical entity picker/search result presentation, Siri disambiguation,
   cold recovery, and registration still need Sequoia/Tahoe evidence.

## M16 automation (Jul 2026)

- **Post-meeting hook**: `PostMeetingShortcut.runIfConfigured(markdown:)` — when stop reaches `.done`, if Ajustes → Automation has a Shortcut name, runs `/usr/bin/shortcuts run <name> --input-path <tmp.md>` with the complete Markdown export (MeetingExporter). Deliberately fire-and-forget: it never blocks or delays the pipeline; Shortcut failures are visible in Shortcuts (the meeting is saved regardless).
- **URL scheme** `portavoz://record` (CFBundleURLTypes in make-app.sh): opens the app and STARTS a recording — always visible (window + mic indicator; nothing records while hidden). Verified E2E: `open "portavoz://record"` launches, navigates, and records. Combined with Shortcuts automations (time/calendar), this provides scheduled auto-recording.
- **AppIntents/Siri**: `StartRecordingIntent` and `StopRecordingIntent` use
  immediate foreground execution on macOS 26+ and retain the framework's
  deprecated compatibility property for macOS 14.4/15. Each posts one buffered
  process-local request that `PortavozAppDelegate` consumes only after the
  complete service graph exists. Neither reopens a URL, because a LaunchServices
  lookup could select another installed handler after the system already chose
  the intent-owning bundle. Start enters the existing pending recording route.
  Stop synchronously returns one honest disposition: accepted, queued, no
  active recording, still preparing, already stopping, or recovery required.
  Accepted work is fenced to one task over the process-owned recording
  controller and brings the recording surface forward before finalization; the
  result says **stopping**, never **stopped**, and every other state names one
  recovery. The macOS build deliberately omits `AppShortcutsProvider`:
  automatic App Shortcuts are not a supported macOS product surface and field
  testing showed that publishing one beside a native action creates duplicate
  picker rows.
  The SPM shipping path compiles the SDK-only intents source under the shipping
  module name and runs `appintentsmetadataprocessor` out of band;
  `make-app.sh` fails unless the resulting `Metadata.appintents` declares exactly
  five actions, three App Entities, and their three string queries.
  `PortavozMeetingEntity`, `PortavozPersonEntity`, and
  `PortavozCommitmentEntity` expose only a display title/name plus meeting date
  or optional commitment due date. Their standard `AppDependency` catalog is
  installed only after the database opens. ApplicationKit caps resolution at
  50 identifiers/results and normalized text at 120 characters; system
  suggestions use 20 rows and mixed exact/text selectors are rejected.
  StorageKit escapes literal wildcard input, excludes
  deleted/dismissed truth, preserves requested identity order, and does not
  load transcript, audio, summary, or evidence content.
  `OpenMeetingIntent`, `ShowPersonCommitmentsIntent`, and
  `OpenCommitmentIntent` revalidate one exact value before a latest-wins,
  consume-once process route. Meeting opens Detail; person opens a visible,
  reversible owner focus in Commitment Radar; commitment identity opens only
  that live item and overrides stale window filters until **Show all** restores
  them. Missing/malformed values and catalog failure route to Library or
  unfiltered Radar with explicit recovery instead of exiting.
  Stable, Dev, and XcodeGen hosts use separate bundle identifiers; Dev is
  force-registered only after its rewritten localized name and final signature
  verify. On macOS the action is selected from the Shortcuts action picker; a
  user-created Shortcut containing it is the reliable Spotlight/Siri adapter
  because direct App Shortcut surfacing is not a supported macOS product
  contract. XCUITest targets the generated test app explicitly, verifies that
  the public production URL and native Start handoff enter a visible active
  recording, and drives the native Stop handoff only after `.recording` to
  require the recording controller's typed recovery. The saved Start Shortcut
  was field-verified from Shortcuts, Spotlight, and Siri on July 27, 2026; Stop
  and the App Entity surface remain physical Sequoia/Tahoe field gates.
  App Entity queries retain the macOS 14.4 deployment floor. On macOS 15+,
  D326 publishes all three `IndexedEntity` values through one protected named
  index; 14.4 keeps the released meeting-document representation in that same
  versioned index. This local implementation evidence does not close physical
  system presentation or registration.
- **Spotlight** (`SpotlightIndexer`, D85/D326): local Core Spotlight search uses
  one process-scoped actor and one consistent StorageKit projection. Launch and
  searchable mutations request reconciliation; 250 ms burst coalescing,
  mode-versioned SHA-256 client state, and bounded retry make it independent of
  a SwiftUI window. One named `app.portavoz.search.v3` index uses complete
  protection and 500-value replacement batches. On macOS 15+ it publishes
  native meeting, canonical-person, and confirmed/done commitment App Entities;
  on 14.4 it publishes meeting documents. Meeting entity attributes retain
  title + date + newest cross-recipe summary + first 40 ordered live segments
  under the released 4,000-character cap. People retain only canonical name;
  commitments retain only title and optional due date. Distinct state prefixes
  force replacement when OS capability changes, while one index prevents
  duplicate meeting results. Only after v3 is ready does retryable, marker-
  guarded cleanup remove `app.portavoz.meetings.v2` and the released default
  domain. `-use-temp-store` suppresses OS indexing.
  The measured 100,000-meeting D85 projection remains 425.64 ms wall p95 versus
  22,085.35 ms for the legacy N+1 path, so no outbox consumer is introduced.
  The 14.4 document hit navigates through
  `CSSearchableItemActionType` → `Route.meeting`; entity hits use their exact
  `OpenIntent`. **Double GOTCHA (field, Jul 2026):** (1) without
  `NSUserActivityTypes: [com.apple.corespotlightitem]` in Info.plist, macOS
  discards a document continuation; (2) even with it, SwiftUI's
  `onContinueUserActivity` does not fire on macOS. The activity reaches the
  classic `NSApplicationDelegate`, which parses identity into
  `AppServices.pendingRoute`; ContentView also consumes a route already present
  when it mounts so cold launch cannot strand it.
- **`.portavoz` bundle** (`MeetingBundle`, IntegrationsKit, Jul 2026 — M15 L0): versioned JSON (ISO8601, sortedKeys) with meeting+speakers+segments+summary+typed overview/decision/action-item evidence+current overview feedback+action items+notes+Apuntador cards with optional question/answer evidence and optional audio; `audioDirectory` is ALWAYS cleared on export (D4). Readers reject a future `formatVersion` with a clear error; unknown future fields are ignored. All later fields remain optional/additive under formatVersion 1, so older readers import the subset they understand. `remappedForImport()` mints fresh IDs for every imported entity while preserving relationships: feedback follows its remapped overview claim, each decision keeps its rendered coordinate, action evidence follows its fresh task identity, Apuntador evidence follows its fresh card identity, and every evidence link follows its fresh segment — importing twice creates two independent meetings. Foreign or malformed nested Apuntador evidence is dropped without losing the card or legitimizing the wrong relation. UI: export from the detail menu (without audio / **with audio**), import through the open panel (UTI `app.portavoz.meeting-bundle`, extension `.portavoz`), and double-click routing. Import decoding/remapping remains a private IntegrationsKit adapter and runs off the MainActor. Its ApplicationKit handoff rejects path-shaped/unknown channel names, unsupported extensions, duplicate channels, and foreign evidence; only system/microphone m4a/caf/wav attachments can materialize as canonical files under `Audio/<fresh-uuid>/`. Meeting, cast, transcript, immutable summary/actions/evidence/feedback, notes, and Apuntador cards/evidence then commit as one aggregate; a final evidence-link failure rolls back the transaction, compensates staged audio, and never publishes a partial Library entry (D51). Export now loads that content from one live StorageKit snapshot, strips the local directory in ApplicationKit, and performs optional full-channel reads plus IntegrationsKit format-v1 encoding at utility priority; missing/unreadable channels remain omitted and SwiftUI retains the native save panel (D52/D87/D88/D89/D90/D91). For email-sized files, compress with AAC before exporting.
- **Confirmed commitment replay** (`CommitmentContinuityEnvelope`, PortavozCore/StorageKit, Aug 2026): canonical format-1 JSON-domain shape for one confirmed continuity aggregate, its exact source/evidence rows, and append-only lifecycle events. StorageKit export returns the validated persisted projection; replay canonicalizes millisecond timestamps, is idempotent for exact retries, and rejects conflicting identity or missing/mismatched local source, evidence, meeting, or person truth before inserting anything. This is an internal transport-neutral representation only. It is deliberately absent from `.portavoz` meeting bundles, meeting-sync envelopes, CloudKit records, CLI, MCP, and SwiftUI until a separately reviewed library-global transport and confirmation UX exist (D237).
- **Meeting sync codecs** (`MeetingSyncEnvelopeCodec` + `CloudMeetingRecordCodec`, IntegrationsKit, Bands 6B1–6B2A): deterministic sorted-key JSON with millisecond timestamps wraps StorageKit's exact-generation text-first envelope. One dormant private-zone `MeetingReplica` stores payloads within a conservative 512 KiB policy in `encryptedValues`; larger payloads use a private CKAsset staging file whose content CloudKit encrypts by default. Content-free `0600` probes in the destination directory independently apply and read back complete protection and backup exclusion. Supported metadata is applied while the staging sibling is empty; only direct or wrapped `EINVAL`/`ENOTSUP` omits the unavailable key, and every other failure stays closed. One POSIX descriptor then handles partial writes and `EINTR`, synchronizes with `fsync`, closes, and verifies exact size plus owner-only permissions before one same-volume atomic rename. Supported metadata is also verified, no Foundation reopen occurs, and partial content never occupies the final path. The digest is encrypted, matching records are reused to preserve system fields, malformed records fail closed, and deletion remains a saved tombstone. The envelope carries every live portable summary/evidence version but no audio, local paths, embeddings, canonical people, generation provenance, jobs, receipts, secrets, or voiceprints (D93/D94/D116).
- **Dormant CloudKit transport** (`CloudMeetingSyncStateStore` + `CloudMeetingSyncCoordinator` + `CloudMeetingSyncEngineDelegate` + `CloudMeetingSyncRuntime`, IntegrationsKit, Band 6B2B): a separate owner-only snapshot stores only hashed account scope/explicit consent/seed policy, an opaque existing-library cursor plus prepared marker, opaque CKSyncEngine serialization, CKRecord system fields, exact attempt metadata, deterministic bounded retries, replay cursors, and deferred-replay metadata. Exact outgoing and deferred bytes use the same capability-probed metadata over mandatory `0600`, POSIX write/`fsync`, verification, and atomic-publication primitive. Account loss pauses without erasing attempts; account switches reset old account-scoped metadata and require consent for the new account. StorageKit remains the mutation/replay authority; explicit initial seed admits deterministic bounded journal batches and completes only after preparation, journal, and attempts drain. The batch commits before cursor advancement, so its cross-store crash window replays idempotently. Late callbacks settle only exact generations, pending preparation reconciles both durable stores, callback failures re-add their exact engine change, partial failures remain independent, and physical CKRecord deletions invalidate metadata without deleting content. D234 adds a persisted protected-replay bit for competing correction replicas: deterministic compatible histories union in StorageKit, incompatible bases retain both exact payloads, block outgoing saves across restart and explicit retry, preserve remote CKRecord system fields through late callbacks, and resume only after an explicit restore/tombstone makes the histories converge. Deletion still wins. The runtime can build a manually driven engine only from an injected CKDatabase, restored state, and the thin delegate; automatic sync is disabled. App composition creates no CKContainer, requests no account, adds no entitlement, performs no sync network request, and exposes no UI (D95/D116/D179/D234).
- **Cloud sync lifecycle policy** (`CloudMeetingSyncLifecycle`, IntegrationsKit, Band 6C1): one CloudKit-free actor composes the D95 store/coordinator/delegate behind injected account and manual-driver protocols. An unconsented launch returns local-only without calling the platform. Explicit enable binds consent to the available account; existing-library seed remains a separate action. That request is durable and idempotent; a `DurableMaintenanceGate` can block before the first storage read or pause after a committed batch without constructing the driver. Account loss pauses while retaining consent and attempts; account switch clears the old scope. Status combines only the content-free StorageKit pending count, protected queue/retry/seed/account state, and typed failures. Pause preserves queue/local/remote data; remove clears only this device's transport files/metadata; explicit retry re-admits the exact generation/payload while retaining attempt history. No CKContainer, entitlement, app network composition, or UI exists in this slice (D96/D179).
- **macOS Cloud sync composition** (`CloudKitMeetingSyncPlatform` + `MeetingSyncModel`, Band 6C2): one inert IntegrationsKit actor creates the named container only after D96 consent and a fail-closed signed-capability/profile probe, checks account status before user identity, and gives the manually driven D95 runtime only the private database. One process-scoped app model serializes explicit actions FIFO and coalesces content-free journal, account, retry, and silent-push wakeups; SwiftUI owns none of those lifecycles. The composition root injects the capture-derived maintenance gate and wakes an explicitly requested seed when capture returns inactive; there is no polling owner. A bilingual Settings pane exposes six truthful phases plus distinct enable, manual sync, retry, existing-library seed, pause, and remove-this-Mac actions, while explicitly excluding audio, paths, voiceprints, secrets, and embeddings. Local/XCUITest builds use no restricted capabilities or host CloudKit; Developer ID artifacts must embed an unexpired profile whose exact production container/service/environment/push values match the signed app before notarization and after DMG extraction (D97/D179).
