# Spec 04 — Intelligence (IntelligenceKit)

Status: implemented and verified (ES summary of EN meeting with glossary intact in 3.8 s; RAG answering with citations via MCP). Decisions: D8 (local by default, explicit BYOK), D18 (FM map-reduce), D22 (RAG), D26 (Companion implemented), D44–D47 (application workflows and immutable summary ownership), D62–D66 (atomic summary, Refine transcript, and Companion-card provenance), D67–D69 (enforced meeting-content egress; Intelligence owns the Companion and summary clients), D72 (capability-driven exact provider selection), D75 (receipt-before-transport privacy evidence), D79 (measured retrieval gate before vector-storage changes), D80 (prefix-evidenced interruption scan), D81 (bounded lexical candidates before vector storage), D82 (isolated semantic resource evidence), D83 (exact semantic adapter retained after budget pass), D87 (typed overview evidence), D88 (human feedback stays outside generation), D89 (position-typed decision evidence), D90 (identity-typed action-item evidence), D91 (role-separated Companion evidence), D100 (one evidence-preserving Ask workflow), D103 (terminal audio-summary workflow), D104 (application-owned durable generation policy), D108 (application-owned local-provider discovery).

## Model scheduler — `IntelligenceScheduler` (D29)

Single-flight actor that serializes EVERY FM call in the process with priorities `interactive > live > background`, FIFO per class, latest-wins by `key` (for discardable Companion ticks), and caller cancellation. Granularity = one call: map-reduce chains release the slot between steps → an interactive job's wait is bounded by the in-flight call (~1–4 s). No FM dependency (7 pure tests, run on any platform). The provider's public methods accept `priority:` (default `.interactive`); the app's rolling summary passes `.background`. Swift 6: `Response<T>` is not Sendable → closures return payloads built inside the slot.

## On-device summaries — `FoundationModelSummaryProvider`

Requires macOS 26 + active Apple Intelligence (`unavailabilityReason()` provides the human-readable reason: ineligible device / AI turned off / model downloading).

**3B model budgets (measured, nonnegotiable):**
- The 4096-token window counts EVERYTHING: instructions + prompt + guided-generation schema + output. Structured-pass material ≤ ~3000 chars (`TranscriptFormatter.onDeviceReduceBudget`).
- Recursive map-reduce: 4500-char chunks (`onDeviceChunkBudget`) → notes with `maximumResponseTokens: 250` (guarantees ≥4× compression per level → convergence; without the cap, it does NOT converge) → recurse until it fits; max depth 4.
- **Always greedy decoding** (`GenerationOptions(sampling: .greedy)`): with sampling, the 3B invents action items (observed). Strict guidance: "solo compromisos explícitos, array vacío si no hubo".
- FRESH session per chunk (sessions accumulate context and overflow on the second chunk).

**Guided generation**: `GeneratedSummary` (@Generable) → overview + up to four
exact `overviewEvidence` E-tags + sections (instructed headings, bullets, and
one `bulletEvidence` E-tag array per bullet) + actionItems
(owner by label and optional exact evidence tags). `StructuredSummary.draft(for:)` resolves owners against
Speakers by label/displayName (case-insensitive) and admits only tags emitted
for that request. Unknown, altered, repeated, or excess tags disappear; no
valid tag or an empty overview produces no claim. Tag-shaped literals in
transcript text, speaker names, and user notes are escaped before prompting,
so content cannot impersonate the provider-owned namespace.

## Typed overview evidence (D87)

`TranscriptFormatter.formatWithEvidence` is separate from the canonical
fingerprint/transcript formatter. It prefixes request rows with compact
`[E1]`, `[E2]`, … tags and returns the exact tag-to-segment map. Map-phase
instructions preserve those tags beside facts. Foundation Models uses the
guided field above; `OpenAICompatibleSummaryProvider` exposes the same optional
JSON field to Ollama, BYOK, and MLX while continuing to decode older responses
without it. Strict resolution deduplicates in model order and caps four links.
`summarizeNotes` deliberately disables claim creation because rolling compressed
notes do not own one stable full-meeting tag map. Translation pivots clone the
typed links with fresh claim IDs; Storage owns revision validation/stamping.

## Typed decision evidence (D89)

`Recipe.decisionSectionIndexes` classifies semantics explicitly: General and
Planning index 1, and 1:1 index 2. Standup, Interview, and custom structures
classify none; headings are never inferred across languages. A provider result
must contain exactly the recipe's section count, and a classified section must
contain exactly one evidence array per bullet. `StructuredSummary` then maps
only exact request-local E-tags to the rendered nonempty section/bullet
coordinate. Unknown, duplicate, empty, altered, shape-mismatched, unclassified,
or rolling-note evidence yields no typed decision.

OpenAI-compatible providers expose the optional additive `bulletEvidence` JSON
field, so older responses still decode. Foundation Models guided generation
uses the same shape, and MLX reuses the OpenAI contract. Translation carries
only coordinates that remain valid after positional bullet-count validation,
mints fresh decision IDs, and preserves the source revision and ordered links.
Storage remains authoritative for coordinate, meeting, and revision admission.

## Typed action-item evidence (D90)

`StructuredSummary.Item` carries one optional additive evidence-tag array, so
older Ollama/BYOK/MLX responses remain decodable. Foundation Models guided
generation exposes the same per-item shape. `draft(for:)` first creates each
durable `ActionItem`, then resolves only exact request-local E-tags into a
separate `SummaryActionItemEvidence` keyed to that new task ID. Unknown,
duplicate, altered, empty, or rolling-note tags produce no evidence.

Translation creates fresh action-item IDs and carries matching evidence by
task position with fresh evidence IDs; bullet/Markdown coordinates are not
involved. The source revision and ordered segment IDs remain intact until
Storage validates them. Completing a task never invokes a provider and never
changes its generated evidence. Companion-card provenance remains independent
and is not inferred from this contract.

## Human claim feedback is not model material (D88)

`SummaryClaimFeedback` belongs to Core/Storage/UI, not an Intelligence provider.
One user correction or unsupported mark remains a separate current assessment
of the immutable overview claim. Summary and translation requests never include
it, provider responses cannot persist it, and regeneration/translation does not
inherit it. It also stays outside generation-run configuration/metrics,
telemetry, privacy receipts, and support diagnostics. This prevents a private
correction from becoming an implicit prompt or being misrepresented as model
output.

**Incremental APIs** (for the rolling summary): `condenseWindow(segments…)` (one map pass over ONLY new content), `condenseNotes(text…)` (collapses the stack), `summarizeNotes(material, request:)` (reduce+structured pass). The app uses them as follows (spec 06): note per 40 s tick over new closed rows → note stack → collapse at > 6000 chars → render; `LiveSummaryPolicy.shouldReplace` retains renders < 90% of the current one (visible monotonicity).

## Language and glossary — `PromptFactory` (pure, tested)

- **Output policy is independent from recognition (D35):**
  `SummaryLanguagePolicy.followSpokenLanguage` uses a homogeneous
  `Meeting.language`, then the selected app locale for mixed/unknown meetings;
  `.fixed` consistently produces English or Spanish. The persisted
  `summaryLanguage` UserDefaults value is resolved by one app adapter for final
  recording summaries, rolling summaries, audio import, and regeneration. An
  explicit regeneration language is retained by the immutable summary
  snapshot. None of these choices changes transcript text or the separate
  transcription policy.
- **The 3B ignores weak directives**: "BCP-47 tag es" comes out in English. What works: human-readable name ("Spanish (español)", `languageName(for:)` via Locale) + repeat the instruction AT THE END of the user prompt.
- Verbatim glossary (terms that are never translated) — comes from the user's vocabulary and/or `--glossary`.
- The real FoundationModels API is verified in the local SDK's `.swiftinterface` — a better source than any documentation.

## BYOK (D8/D67/D68) — gateway-backed summary and Companion clients

- **`OpenAICompatibleChatCodec`**: internal, transport-free request/response codec shared by the summary and Companion clients for `/chat/completions` endpoints (OpenAI/OpenRouter/Groq/Ollama/LM Studio). One system + one user message go in and text comes out; no URLSession dependency is reachable through this type.
- **`OpenAICompatibleSummaryClient`**: public summary transport facade that cannot send without an injected `DataEgressGateway`. It declares full meeting-summary material, source meeting identity, exact destination/scope, provider/model, and operation-specific consent separately from the encoded body. Cloud calls do NOT pass through `IntelligenceScheduler` — single-flight exists because of ANE contention and does not apply to the network.
- **`CompanionBYOKClient`**: accepts the same endpoint/model/key shape and also requires a gateway. Its separate operation declares question-only material so recent transcript context can never be smuggled through summary metadata.
- **Receipt semantics (D75)**: the production gateway validates those declarations, persists one immutable content-free attempt, and only then exposes the body to URLSession. Receipt failure prevents the call; HTTP failure retains the attempt; redirects are rejected. Intelligence providers never create or interpret receipt rows themselves.
- **`BYOKSettings`**: endpoint and model remain visible UserDefaults preferences (`byokEndpoint`/`byokModel`); the key is ONLY the PlatformKit Keychain value identified by `SecretIdentifier.byokAPIKey`. App composition resolves that key asynchronously through `ApplicationKit.ManageSecrets` and passes explicit opt-in/endpoint/model/key/gateway values to IntelligenceKit. `companionClient(...)` returns a client only when every value and the explicit `companionBYOKEnabled` consent are present; missing pieces fall back to on-device, never to an error. IntelligenceKit does not import or construct Keychain.
- **`OpenAICompatibleSummaryProvider`**: owns only the summary prompt, JSON→`StructuredSummary` contract, and a gateway-backed summary client. It forwards `SummaryRequest.meetingID`, weaves in user notes (D28) just like on-device, and retains parity tests. Key via `PORTAVOZ_BYOK_API_KEY` in the CLI; in the app, Keychain via Settings.

## Multiple summary engines (D25/M12) — Apple FM · local Ollama · embedded MLX · cloud BYOK

`AppServices.summaryEngine` (UserDefaults `summaryEngine`: `appleOnDevice` / `ollama` / `mlx`) is sampled by app-owned provider resolvers. On a clean install, `ApplicationKit.ConfigureInitialSummaryProvider` probes one capability-neutral profile and initializes the preference only when it is absent: usable Apple FM wins; otherwise Ollama wins only when its running server exposes a nonempty model whose normalized name is not classified as OCR, embedding, reranking, or Whisper work; the explicit-download MLX path is selected when hardware can run it. The main-actor selection store re-checks the preference at its guarded write and reports whether the write won. Existing choices are never migrated silently. `DiscoverLocalSummaryProviders` returns the same typed recommendation to Settings and Onboarding, so process availability cannot be confused with generation readiness and localization remains in presentation. The macOS adapter owns Foundation Models capability, content-free localhost discovery, RAM/disk facts, provider DTO mapping, and UserDefaults persistence (D108). Every manual, import, and durable summary path honors the selected engine exactly: missing Ollama selection, missing MLX download, pre-macOS-26 Apple selection, and unavailable Apple model become typed setup states, never fallback to another provider. Meeting Detail opens the native Settings scene directly at Intelligence for those states (D72).

The durable post-capture worker selects Ollama through `OllamaService.summaryProvider(model:gateway:consent:)` (an `OpenAICompatibleSummaryProvider` against `localhost:11434/v1`, **without an API key** — Ollama ignores it, nothing leaves the device), verified embedded MLX, or available Apple FM. Ollama summary generation still crosses the gateway with `local-device` scope and Settings consent; its content-free health and model-discovery requests remain direct because they contain no meeting material. ApplicationKit's regeneration and import adapters consume explicit availability without constructing providers inside the use cases. The **live rolling summary remains FM-only** (it uses the incremental `condenseWindow`/`summarizeNotes` APIs that Ollama/MLX do not have). `OllamaService`: `isRunning()` (GET `/api/version`), `models()` (GET `/api/tags`, pure/tested `parseModels`). Settings retains the engine picker, detection, model list, localized typed reasons, and prominent Apply action. `LocalSummaryProviderPolicy` is pure and tested against Apple availability, name-screened Ollama models, MLX hardware eligibility, and low-memory/disk guidance. **Closes GAPS #7** (a Mac without Apple Intelligence summarizes 100% locally); verified E2E with gpt-oss:20b (ES summary in 24 s) + UITest of the Settings section. Every provider stamps its own material fingerprint, but the released Meeting Detail path performs cache lookup and translation pivot only for Apple FM; configured Ollama/MLX regenerates directly. **Per-meeting override (M12)**: the `RegenerateSummary` provider resolver forces an engine for one meeting without changing the global default; the detail menu offers language (es/en) and, when there is a real choice, the **alternative engine** (Apple↔Ollama — only the one that is not the default and only if it is usable here: Ollama with a configured model, or Apple with `appleSummaryAvailable`). An Apple override preserves its cache and pivot path.

**Embedded MLX (D32, Jul 2026)**: third engine `summaryEngine = "mlx"` — `MLXSummaryProvider` (IntelligenceKit) runs **Qwen3.5-4B 4-bit** (Apache-2.0, sha256-pinned in `ModelCatalog.mlxQwen35`, 3 GB; `mlxQwen3` remains in the catalog for A/B) in-process on the GPU via `mlx-swift-lm` (exact 3.31.4 — successor to mlx-swift-examples; the tokenizer is provided by `swift-transformers` through the `MLXHuggingFace` macros). **Field A/B (Jul 10, refined 56 min / 852-segment sprint demo)**: Qwen3-4B collapsed into a degenerate loop twice (34k and 68k chars truncated); Qwen3.5-4B with `enable_thinking: false` (additionalContext — the 3.5 family reasons by default and loses the JSON prompt) produced decisions + open questions + 11 action items with owners in clean Spanish in 89 s. `maxTokens` 16384 as a pure anti-runaway safeguard. Reuses the prompt and JSON contract from `OpenAICompatibleSummaryProvider.prompt/parseStructured` — same `StructuredSummary`, same fingerprint. `MLXModelCache` (actor) keeps ONE `ModelContainer` loaded and serializes generation (`container.perform`, temperature 0); it does not pass through `IntelligenceScheduler` (GPU, not ANE). Settings → "Built-in (MLX)": `MLXModelRow` row with verified download/status/delete (`AppServices.mlxDownloaded/downloadMLX/deleteMLXModel`); `LocalSummaryProviderPolicy` suggests it with RAM ≥ 8 GB when Apple Intelligence is unavailable and Ollama has no eligible name-screened model. **Shipping**: SwiftPM does not compile Metal shaders → `scripts/build-mlx-metallib.sh` caches `mlx-swift_Cmlx.bundle` (one-time xcodebuild, keyed by mlx-swift version), and `make-app.sh` copies it to `Contents/Resources`. **E2E verification**: `portavoz-app --mlx-smoke [real]` — synthetic ES in 3 s; with `real`, summarizes the most recent meeting in the library (read-only). Verified with a real meeting of 40 min / 686 segments: 44 s, coherent decisions and action items. There is no test under `swift test` because the CLI runner cannot have a metallib. **Memory (critical)**: without `MLX.GPU.set(cacheLimit:)`, MLX's buffer cache grows without limit on long prompts — 31 GB of RSS was observed on that same meeting before macOS suspended the process. `MLXModelCache` sets 20 MB (the LLMEval value) and `maxTokens: 2048` as the generation cap; with that, the real peak is ~4.5 GB (2.3 GB weights + KV + runtime).

## Fingerprint cache + translation pivot (D25) — `SummaryFingerprint` + `translate`

- **`SummaryFingerprint.compute(request:providerID:)`**: SHA-256 of the MATERIAL and method — formatted transcript (with speaker names: renaming `S1` to `José` invalidates it because it changes attributions), D28 notes block, glossary, recipe, providerID, and `promptVersion` (constant to bump when prompts change substantially). **Intentionally excludes the output language** — that is what enables the pivot. Each provider stamps the fingerprint onto the draft it produces.
- **Regenerate (detail)**: same recipe + fingerprint + language already saved → "already up to date" notice without a model call (greedy would reproduce the same result); same recipe + fingerprint in another language → `translate(pivot)`; otherwise → full summary. Recipe identity is explicit at the storage port as well as inside the fingerprint, so Standup/custom reuse cannot be filtered through General.
- **`translate(_:to:glossary:)`**: parses the pivot markdown back into a structure (`StructuredSummary.parse` — invertible because EVERY snapshot comes from our renderer; round-trip tested) and translates **piece by piece: one call for the overview, one per section, one for the action items**. Piecewise because when given the whole thing — even with a guided schema — the 3B invented sections (2 failed iterations of the gated test: opaque markdown → truncated at the first paragraph; one-call mirrored schema → 3 sections of 1). The structure survives by construction; any bullet/item mismatch throws, and the caller falls back to a full resummary. Item owners travel positionally; the result retains the pivot's fingerprint. **Measured: constant 2.4 s vs 10.9 s for resummarizing the long synthetic meeting** (the savings scale with the meeting).

Since Band 2 slice 2D, Meeting Detail regeneration executes as
ApplicationKit's `RegenerateSummary`. The use case receives one immutable
meeting/recipe/language/override request, loads notes and glossary through
narrow ports, resolves a provider through an app adapter, and owns the exact
reuse policy above. Configured Ollama remains gateway-backed while MLX remains
an in-process generation path;
Apple FM retains exact-language cache, other-language pivot, translation
fallback, and full-generation order. Provider construction, model paths,
platform preference storage, availability, and localized UI copy remain in
the macOS app. A typed result preserves the released error asymmetry and makes
best-effort snapshot persistence explicit without changing broad invalidation.
Slice 2E adds D45 active-snapshot semantics: after successful regeneration,
Meeting Detail reloads the newest live immutable snapshot across recipes rather
than defaulting to General. Per-recipe version history is unchanged.

### Summary-generation provenance (D62–D64)

Each actual `RegenerateSummary` provider operation now produces a typed
`GenerationRun`. Direct Ollama/MLX/Foundation Models generation records a
`regenerate` operation; a reused Apple pivot records `translate-pivot`. The
envelope carries provider ID, model ID and optional pinned revision, the same
material fingerprint used by reuse, recipe/reuse policy, requested output
language, start/finish time, terminal outcome, and only output UTF-8 byte/action
counts. It never stores transcript, note, glossary, prompt, summary, or action
text. Ollama uses its configured model name; MLX uses the pinned catalog ID and
revision; Apple identifies the system language model without inventing an OS
revision.

An exact-language cache hit creates no run because no provider operation took
place. A failed/cancelled attempt is stored separately on a best-effort basis;
if pivot translation fails, its failed run precedes the released full-summary
fallback and that second attempt gets its own successful run. A successful run,
immutable summary, and action items commit in one StorageKit transaction. A
persistence failure still returns the released `completed(persisted: false)`
result, and provider failures retain their existing silent versus visible
presentation. Accepted Refine invokes this same regeneration use case after its
transcript commit, so its follow-up summary is covered.

`ApplicationKit.ProcessPostCaptureJobs` uses the same envelope with a different
operation identity. It snapshots the selected provider/model, durable job ID
and attempt, `generate` operation, General recipe, target language, source
transcript revision, and exact `SummaryOperationFingerprint` immediately before
the provider call. Ollama records its configured model; MLX records the pinned
Qwen 3.5 catalog ID/revision; Apple records `system-language-model`; the
disposable UI fixture records its deterministic fixture model. Its metrics are
the same aggregate output byte/action counts and contain no meeting content.

Success is not published independently: the run, immutable summary/actions,
job success, and lifecycle reconciliation share the existing owner-
lease/source-revision-fenced transaction. A provider or publish failure after
model start writes a best-effort failed run; task cancellation, lease loss, or
superseded input writes a cancelled run. Provider unavailability or input
supersession before the attempt produces no run. Every retry therefore receives
its real durable attempt number without changing the workflow's released retry,
optional degradation, provider fallback, immediate-detail, or Shortcut policy.

External-audio import uses the same envelope after a different business fence.
The required copied-audio/meeting/cast/transcript aggregate commits first. A
metadata-bearing provider resolver then creates one attempt immediately before
each real model call, carrying provider/model and optional revision, the
material `SummaryFingerprint`, General recipe, requested output language,
timing, and the `audio-import`/`generate` operation. Metrics contain only output
UTF-8 bytes and action-item count. Success commits run + immutable summary +
actions atomically; provider failure, cancellation, or summary-publish rollback
stores the same attempt best effort as failed/cancelled. No provider means no
synthetic run, and optional intelligence can never remove the already committed
meeting or copied audio (D64).

Slice 2F routes the optional import summary through
`ApplicationKit.ImportMeeting` and an app-owned provider resolver. The use case
resolves the independently configured output language after it detects whether
the imported transcript is homogeneous, builds the General recipe request,
and attempts both generation and immutable persistence only after the required
meeting/cast/transcript aggregate commits. Either summary failure is
best-effort: the imported meeting and its audio remain available, exactly as in
the released path. The app adapter reuses configured summary-engine selection
while exposing provider/model metadata through an import-specific port
(D46/D64).

Slice 2G routes post-refine Companion work through
`ApplicationKit.ApplyRefinedMeeting` and an app-owned availability/model
adapter. Companion runs only after the revision-fenced transcript transaction
commits. An unavailable provider skips refresh, and an incomplete or canceled
refresh preserves the prior cards; a complete pass replaces the snapshot,
including with an empty set when the refined transcript contains no
card-worthy questions. Card persistence failure is reported as a degradable
outcome and never converts an accepted transcript into failure. Existing
summary rows remain untouched by that transaction. After successful apply,
Meeting Detail invokes the existing `RegenerateSummary` workflow with the
current recipe/output-language policy, producing a new immutable snapshot
without rewriting history (D47).

Meeting Detail's optional title, summary-structure, and chapter-label pass now
enters `ApplicationKit.SuggestMeetingReviewMetadata` over one
storage-independent review projection (D111). The workflow admits only a
template-like current title, a General summary, and chapter starts that have no
generated label; trims and bounds labels; maps a proposed recipe back to the
built-in catalog; and degrades ordinary generator failures independently.
Cancellation remains cancellation so a newer review revision can retry rather
than publish stale output. The macOS adapter owns Foundation Models capability,
the scale-fixture bypass, `TitleSuggester`, `MeetingTypeDetector`, and
`ChapterTitler`. The route model owns one-shot completion and request fencing.
Every result remains inert until the user accepts it, and literal chapter
excerpts remain the fallback when generation is unavailable or fails.

`SummaryOperationFingerprint` is deliberately separate from that cache key.
It length-prefixes and hashes D25 material identity plus provider, requested
output language, and source transcript revision, so a durable worker cannot
publish a summary produced for a stale cast, provider, or language. Ollama's
identity exactly mirrors the provider's `localhost/<model>` cache identity.
After successful diarization, D42 atomically enqueues this exact operation. The
`ProcessPostCaptureJobs` workflow recomputes it before generation and completes
through the D41 summary Unit of Work. Transient provider failure retries
durably; exhausted summary work cancels without failing the meeting because the
released product already treats a transcript without a summary as valid
(D104).

D43 preserves post-meeting Shortcut behavior after Stop becomes asynchronous.
When no summary provider is available, the Shortcut receives transcript-only
Markdown after diarization. Otherwise it runs after summary success or terminal
optional cancellation. This hook remains best-effort; disposable temp-store
launches suppress it. Exactly-once external delivery remains future automation
work; completed Band 3 deliberately kept the local Shortcut process outside the
meeting-content HTTP receipt boundary.

## Local RAG (D22/D100) — `AskMeetings` + retrieval and answer primitives

- **Embeddings**: `NLContextualEmbedding(script: .latin)` — shared es/en space (genuinely cross-lingual). Mean-pool + L2-normalize. `prepare()` requests assets from the OS.
- **Index**: BLOB in the `embedding` column of `segment` + brute-force cosine (sqlite-vec intentionally deferred). Micro-segments (< 20 chars) EXCLUDED from the index (they drowned out cross-lingual hits).
- **Application boundary (D100)**: `ApplicationKit.AskMeetings` is the only public workflow used by the macOS Ask route, resident command palette, CLI `ask`, local MCP `ask`, and meeting-brief evidence lookup. Instant results and citations are storage-independent values; generated text is optional, so unavailable or failed local generation preserves evidence instead of converting retrieval success into failure; cancellation still propagates as cancellation.
- **Meeting preparation (D101)**: `ApplicationKit.PrepareMeetingBrief` ranks the shared Ask citations, joins them to one batched latest-live-General-summary projection and independently loaded open commitments, and exposes only storage-independent related meetings, commitments, and knowledge points. Foundation Models synthesis is optional and every returned source index is validated before it becomes a navigable knowledge point; invalid indexes and ordinary model failure produce no invented source, while cancellation remains cancellation.
- **Lexical candidates (D81)**: `ApplicationKit.LocalAskMeetingRetrieval` owns the policy. It normalizes and deduplicates content words ≥ 4 characters, retrieves a bounded FTS top-k list per term for normal questions of up to eight unique terms, and fuses those lists with RRF (`k=60`). Multi-term passages climb without scoring one complete OR union. Longer pasted questions retain the released broad-OR fallback, and every selected hit carries complete segment text in addition to its UI snippet.
- **Hybrid retrieval**: lexical candidates + brute-force semantic candidates are fused again with RRF (`k=60`). Multi-query still asks FM for bilingual paraphrases (`expandQuery`), and term deduplication spans those variants.
- **Answer**: `OnDeviceAskMeetingIntelligence` wraps the IntelligenceKit query-expansion and answer primitives. The on-device FM receives complete selected segments, not bounded highlighted UI snippets, and citations retain segment/meeting identity plus timestamp. Verified E2E: MCP agent answered "what did we agree about the transcription budget?" with correct sources.

## Coauthoring notes (D28) — the notes→summary weave (implemented)

- `SummaryRequest.contextItems`: user notes travel to the FINAL pass as intent. `PromptFactory.notesBlock` formats them with timestamps (`[mm:ss] nota`), chronologically, with a hard budget (120 chars/note, 800 for the block — tested).
- **3B budget respected**: the block shares the window with the condensed material, so the reduce target SHRINKS by exactly the space occupied by the block (`condense(reduceBudget:)`).
- Instructions (`notesBehavior`): each note is a topic the summary MUST cover, expanded with facts, never contradicted; bullets originating from a note are prefixed with **"▸ "** — a cheap token instead of inflating the guided-generation schema; the renderer can display Granola-style coauthorship (black/gray) without changing types. The language instruction still closes the prompt (D18).
- Full flow wired: **notes panel in `RecordingView`** (TextField + timestamped list with remove, right column, always visible during recording) → `RecordingController.addContextNote()` (anchors to the current moment) → rolling and final summaries see them → persisted at stop (`contextItem` table, v3 migration) → regeneration in the detail reloads them from the store. **Coauthorship rendering** in `MarkdownText`: bullets prefixed with "▸ " are drawn with an accent mark (Granola style — content originating from your note is distinguishable from the pure AI summary). M10 complete except for field verification (5 real notes → summary that expands them).

## Live Companion (D26) — `LiveCompanion` + `QuestionHeuristic` + `CompanionCard`

3-stage pipeline over closed coalescer rows (a row closes when the next one is created — never partial, never reprocessed):
1. **Pure gate** (tested, es/en): `looksLikeQuestion` (`?`/`¿`, initial interrogatives, minimum 12 chars) **OR `mentions(ownerName)`** — the "te preguntaron" detector: whole-word, case/diacritic-insensitive match of the first name or full name ("John" does NOT trigger inside "Johnny"). The name comes from Ajustes ("Tu nombre") with default `NSFullUserName()`. The common case (nobody asked) costs zero.
2. **FM classifier** (`DetectedQuestion` @Generable: isQuestion/question/kind) sent to the scheduler with `.live` + key `companion-detect` (latest-wins: ticks never stack up). `logistics` → no card (the classic failure mode for this class of features), **unless the caption names you**: then the card is a PING ("te preguntaron", question without an invented answer, orange tint). Two lessons from the 3B caught by the gated test: (a) `directed` is ALWAYS the deterministic name gate, never the model's opinion (requesting it as a field → it stripped "Johnny," from the question and reported false); (b) the logistics filter needs literal few-shot examples ("¿nos acompañas mañana…?" is logistics, NOT context) — with only the abstract rule, it leaked through.
3. **Answer**: `knowledge` → BYOK if the user configured it AND enabled the opt-in (app composition injects the resolved `CompanionBYOKClient`; same instructions as on-device, 400 tokens max, `source` = provider host; if the provider or egress-policy call fails, it falls back to on-device FM and says so in `source`); without BYOK → direct FM (1–3 sentences, same language, greedy, 220 tokens max, `.interactive`). `context` → `RAGAnswerer` with the last ~13 live rows as passages ("¿qué dijimos del budget?" answers from what was JUST said) — meeting context NEVER goes to BYOK, only the text of the `knowledge` question (D8/D67). Explicit cancellation never falls through to the local answer.

App: per-recording opt-in ("Companion" toggle next to the translation toggle, persists in `companionEnabled`); unlimited, newest-first, scrollable cards (question + answer + provenance — provider host or "on-device" — + copy/dismiss). On close, they are persisted in `companionCard`; the detail keeps the existing asked-at playback action and additionally separates exact question sources from answer sources. Refine rederives them: an incomplete pass retains the previous snapshot, and a complete pass replaces it, including with an empty set to remove stale questions. Answer cleanup removes only citation markers and trailing verbatim `passage N` references, never legitimate intermediate text. It never answers for you (D26). The classifier requires macOS 26 plus available Apple Intelligence, so the recording and Settings enable controls exist only when `FoundationModelsCapability` is available. On Sequoia, the Voice pane explains the requirement and that BYOK replaces only the knowledge-answer provider, not question detection; the independent post-meeting Mirror remains available. Settings' external-model section keeps its endpoint/model/key readiness rule, additionally disables Companion BYOK when the classifier cannot run, and turns the opt-in off when its key is removed (D72). Latency budget: bounded by D29 (replaceable `.live` detection + `.interactive` answer with wait ≤ in-flight call).

### Companion transcript evidence (D91)

`CompanionGenerationRequest` carries exact question segment identities and
`RAGPassage` may carry its source segment identity. Live generation uses the
closed row that triggered detection. Post-Refine generation coalesces adjacent
same-speaker rows into one turn and retains every constituent segment ID. The
`companion-generation-v2` fingerprint binds those ordered identities and every
optional passage identity in addition to the existing private material.

For context answers, `CompanionAnswer.citedPassageIndexes` extracts only exact
in-range `[N]` markers from the raw model response, deduplicated in first-use
order, before display cleanup removes the markers. `CompanionEvidenceFactory`
maps those indexes to same-meeting passages with real segment IDs. Knowledge
answers and directed pings receive question evidence but no answer evidence;
uncited context answers likewise receive no fabricated answer links. The
resulting `CompanionCardEvidence` is card-identity-keyed, revision-fenced, and
role-separated. It is attached to the card before the generated artifact
crosses StorageKit, but generation-run JSON remains content-free.

### Companion-card generation provenance (D66)

`ProvenanceCompanion` wraps the released pipeline without changing its card
policy. After the deterministic question/name gate and model availability
check, it creates one ephemeral attempt. The exact operation fingerprint hashes
meeting and source transcript revision, live-recording/post-refine workflow,
candidate, ordered question segment identities and `RAGPassage` material
(including optional segment identities), optional owner/language, exact asked-at
bits, and optional external destination/provider/model. The exact destination
may include a base path but appears only inside the hash; run JSON keeps only
the disclosure-safe provider label/model. None of the private meeting values is
copied into the run JSON.

A successful durable card receives one `.companion` `GenerationRun` whose
configuration names the Foundation Models classifier, actual answer provider
and model, context count, workflow/revision, conservative external destination
scope when a transfer was attempted, and whether a BYOK transfer was
configured, attempted, and successful. Metrics contain only question/answer
UTF-8 byte counts, kind, and directed status. A remote success identifies that
provider; a remote failure followed by the released local answer identifies
Foundation Models while retaining the failed-transfer facts. BYOK is marked
before transfer, and cancellation is rethrown or detected through
`Task.checkCancellation()` before fallback, so cancellation never invokes an
unintended local model. The original `LiveCompanion.process` still exposes its
underlying error rather than the internal trace wrapper.

Failure/cancellation after attempt start creates a terminal run. The
deterministic gate, unavailable model, classifier negative/logistics drop,
unusable answer, and post-generation deduplication create no durable run. A
directed ping is still a generated card and identifies Foundation Models even
when no answer stage was needed. Live and post-Refine persistence boundaries are
specified in specs 01, 05, and 06.

### Companion egress enforcement (D67)

The production live and post-Refine paths inject IntegrationsKit's
`URLSessionDataEgressGateway` into `CompanionBYOKClient`. The request carries a
content-free operation (`companion-knowledge-answer`), exact destination,
`local-device`/`remote` scope, `meeting-question-only` classification, source
meeting ID, Settings consent source, and provider/model disclosure separately
from its body. The adapter validates those facts before URLSession sees the
payload and rejects missing-host or non-HTTP(S) destinations. Only provable
loopback (`localhost`, `*.localhost`, valid `127/8`, or
`::1`) is local-device; private LAN, `.local`, malformed, and unknown hosts are
remote. A directly constructed public Companion client uses an explicit-client
consent marker and remains gateway-mandatory.

The body contains static Companion instructions and the classified knowledge
question only. No `RAGPassage`, transcript window, owner identity, or stored
card content enters the transport metadata or body. Offline tests capture and
decode the exact request, validate loopback classification and metadata
rejection, and an architecture test prevents Companion, provenance, or app
composition from restoring a direct network call.

### Summary egress enforcement (D68)

OpenAI-compatible summaries now use a second operation-specific vertical on
the same Core port and IntegrationsKit adapter. The app's regeneration, import,
and durable post-capture resolvers inject `URLSessionDataEgressGateway` and
declare Settings consent; the CLI's explicit `--byok` invocation declares
explicit-provider consent. Every call carries its source `MeetingID`,
`meeting-summary-material` classification, exact provider/model and destination,
and a conservative local-device/remote scope separately from the request body.
The adapter requires a non-empty POST and rejects absent meeting identity,
forged destination/provider/model, wrong material classification, and any
Companion consent marker used for a summary (or vice versa) before transport.

The terminal `summarize` command enters
`ApplicationKit.SummarizeAudioFile`. ApplicationKit owns file admission,
Parakeet-before-pyannote ordering, fresh meeting identity, attribution,
summary request material, timing, and optional persistence. With `--save`, the
meeting, cast, and transcript commit before the injected provider can cross the
gateway; the immutable summary commits only after provider success. Without
`--save`, the workflow remains database-free and makes no durable receipt
claim. On-device and explicit BYOK providers are selected at CLI composition,
not in the command body (D75/D103).

Only the gateway-backed client is public; the shared chat codec is internal and
transport-free. Offline tests decode remote and loopback requests, prove exact
metadata and consent, exercise the real provider response parser, and reject
cross-operation consent. The 23rd architecture rule prevents IntelligenceKit,
app composition, or CLI composition from restoring a direct summary network
path. D69 subsequently moves explicit publishing through the same port under
separate contracts; see spec 07.

## Meeting health at scale (D80)

`MeetingHealth` remains a pure local projection over attributed transcript
segments; no model, database, or persisted cache participates. Talk time,
questions, longest monologue, and the released 0.5-second interruption
threshold are unchanged. Interruption detection precomputes the maximum end
time for each sorted prefix and stops reverse inspection only when that entire
prefix cannot overlap the current segment. A newer ended neighbor alone is not
enough to stop, because an older long turn may still span it.

The adversarial edge is characterized directly. On the full Release matrix,
health p95 falls from 24.25/347.58/5,385.76 ms to 2.55/9.94/41.39 ms at
1,250/5,000/20,000 segments. Fully overlapping pathological input can still
require quadratic inspection; ordinary sequential meetings are near-linear.
The same native 5k detail reaches first content in 91.87 ms with no measured
hang, so no detail decomposition or health cache is selected.

## Naming

See spec 03 (SpeakerNamer + NamingExcerpt + never-trust-verify filter).

## Known limits

1. Meeting Detail cache lookup and translation pivot are Apple-FM-only;
   configured Ollama/MLX regeneration performs a new generation.
2. Band 4D measured the original 512-dimensional brute-force cosine path at
   325.41/328.43 ms wall/CPU p95 for 100k segments. Band 4E's exact streamed
   Accelerate adapter now passes at 90.22/91.26 ms while preserving complete
   passages, deterministic top-k, tombstones, and malformed-vector exclusion.
   sqlite-vec and a persisted-vector migration are not selected (D83).

## Planned (not implemented)

BYOK summaries from the app (the Keychain plumbing already exists; the provider selector in the detail is missing — M12).
