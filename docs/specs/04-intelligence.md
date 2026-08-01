# Spec 04 — Intelligence (IntelligenceKit)

Status: implemented and verified (ES summary of EN meeting with glossary intact in 3.8 s; RAG answering with citations via MCP). Decisions: D8 (local by default, explicit BYOK), D18 (FM map-reduce), D22 (RAG), D26 (Apuntador implemented), D44–D47 (application workflows and immutable summary ownership), D62–D66 (atomic summary, Refine transcript, and Apuntador-card provenance), D67–D69 (enforced meeting-content egress; Intelligence owns the Apuntador and summary clients), D72 (capability-driven exact provider selection), D75 (receipt-before-transport privacy evidence), D79 (measured retrieval gate before vector-storage changes), D80 (prefix-evidenced interruption scan), D81 (bounded lexical candidates before vector storage), D82 (isolated semantic resource evidence), D83 (exact semantic adapter retained after budget pass), D87 (typed overview evidence), D88 (human feedback stays outside generation), D89 (position-typed decision evidence), D90 (identity-typed action-item evidence), D91 (role-separated Apuntador evidence), D100 (one evidence-preserving Ask workflow), D103 (terminal audio-summary workflow), D104 (application-owned durable generation policy), D108 (application-owned local-provider discovery), D122 (lexical transcript and generated-output admission), D132 (cast-grounded action owners), D133 (identity-based live-summary admission), D145 (exact-first instant Library semantic augmentation), D148 (content-free resource measurement), D151 (independent MLX inference lane), D152 (one semantic-corpus indexing operation), D161 (composition-owned MLX residency), D170 (recording-scoped bounded live Apuntador generation), D171 (signal-driven bounded live-summary delivery), D172 (deterministic generated-intelligence admission), D176 (one bounded semantic-indexing flight), D177 (capture-prioritized semantic checkpoints), D178 (signal-driven background semantic owner), D192 (content-free staged Ask tracing), D193 (authoritative Ask benchmark receipts), D194 (adapter-neutral multilingual quality contract), D195 (production retrieval observation without answer-quality claims), D196 (corpus-read-only Ask retrieval), D197 (typed semantic readiness and background-only product writes), D198 (revision-fenced semantic publication), D199 (compatibility-fenced semantic vectors), D200 (independent durable semantic maintenance ownership), D201 (progressive exact-first Ask evidence), D206 (injected semantic-index query port with exact control retained), D207 (non-serving shadow comparisons with payload-free telemetry).

## Model scheduler — `IntelligenceScheduler` (D29)

Single-flight actor that serializes EVERY FM call in the process with priorities `interactive > live > background`, FIFO per class, latest-wins by `key` (for discardable Apuntador ticks), and caller cancellation. Granularity = one call: map-reduce chains release the slot between steps → an interactive job's wait is bounded by the in-flight call (~1–4 s). No FM dependency (8 pure tests, run on any platform). The provider's public methods accept `priority:` (default `.interactive`); the app's rolling summary passes `.background`. Swift 6: `Response<T>` is not Sendable → closures return payloads built inside the slot.

D148 emits distinct queue-wait and inference intervals from this actor.
Background, live, and interactive priorities map to post-capture,
live-interactive, and user-initiated workload classes without exposing the
latest-wins key or prompt. A process-wide event-only relay lets ad hoc provider
instances use the app recorder without importing OSLog or changing scheduling
policy.

D151 reuses the same scheduler policy through a second process-owned
single-flight instance for MLX/GPU inference. It is independent from the
Foundation Models/ANE instance: neither capability can queue behind the other,
but both publish the same content-free queue and execution event shapes.
User-driven regeneration and Import use interactive MLX priority; durable
post-capture summary generation uses background priority. IntelligenceKit's
`MLXSummaryRuntime` owns container mechanics, while the AppServices-owned
process instance and residency adapter own active-use lifetime and idle
release. Neither runtime layer replaces scheduling.

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
(owner by label and optional exact evidence tags). `StructuredSummary.draft(for:)`
resolves owners once against the cast: a unique exact label wins, while a
display name is admitted only when unique. The resolved `SpeakerID` travels
beside the canonical rendered owner into typed action projection; unknown and
ambiguous generated names are cleared rather than re-resolved by array order. A
matching leading owner prefix is removed from the task text so
`Daniel: task — Daniel` cannot render. It also admits only tags
emitted for that request. Unknown, altered, repeated, or excess tags disappear;
no valid tag, no distinctive lexical overlap, or an empty overview produces no claim. Tag-shaped literals in
transcript text, speaker names, and user notes are escaped before prompting,
so content cannot impersonate the provider-owned namespace.

`TranscriptFormatter` excludes legacy rows without letters or digits before
prompting and numbers only admitted rows, keeping tags contiguous. Exact tag
resolution is followed by `SummaryEvidenceAdmission`: every overview, typed
decision, and action source must share a distinctive folded token with the
statement it supports. If paraphrase or output-language translation prevents a
deterministic check, the link fails closed while generated text remains visible.

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
Planning index 1, and 1:1 and Retrospective index 2 (the "Agreements"
section). Standup, Interview, Discovery, Postmortem, and custom structures
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
duplicate, altered, empty, lexically unrelated, or rolling-note tags produce
no evidence. `SummaryActionAdmission` also removes empty/duplicate tasks and
compares each action's attribution-independent statement body with the
recipe's typed decision section before Markdown, action identity, or evidence
is created. That catches the same claim when a decision carries a leading
speaker prefix but the generated action carries that speaker in its separate
owner field. `groundedOwner` then treats generated identity as a cast claim:
only an existing speaker label or confirmed display name survives, and both
Markdown and storage consume that same admitted value. Provider prompts
independently require a concrete future commitment or assigned next step,
reject current state, explanation, quotation, and decision restatement, and
permit no task when no commitment exists; the deterministic gate remains
authoritative.

Translation creates fresh action-item IDs and carries matching evidence by
task position with fresh evidence IDs; bullet/Markdown coordinates are not
involved. The source revision and ordered segment IDs remain intact until
Storage validates them. Completing a task never invokes a provider and never
changes its generated evidence. Apuntador-card provenance remains independent
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

**Incremental APIs** (for the rolling summary): `condenseWindow(segments…)`
(one map pass over ONLY new content), `condenseNotes(text…)` (collapses the
stack), `summarizeNotes(material, request:)` (reduce+structured pass). The app
uses them through one signal-driven coordinator (spec 06): caption, speaker,
and note changes invalidate current state; after the 40-second minimum cadence,
one cycle admits at most 32 oldest unseen closed rows and 6,000 characters →
note stack → collapse at > 6,000 characters → render. Successful backlog drains
through later bounded cycles. Provider failure preserves the cursor and waits
for the next evidence signal. `LiveSummaryPolicy.shouldReplace` retains renders
< 90% of the current one (visible monotonicity). The cursor is an identity set,
not an array offset, so a late live-diarization split cannot skip its fresh child
(D133).

## Prompt-injection guard (Jul 2026, pure, tested)

Every model prompt that carries meeting-derived material states that it is
untrusted quoted source: embedded requests, commands, and formatting orders are
content to report or transform, never instructions to follow.
`PromptFactory.sourceMaterialGuard()` is shared by summary, map-phase notes,
finished-summary translation, speaker naming, chapter titles, pre-meeting
briefs, meeting-type detection, RAG answers, and title suggestions; Apuntador
keeps equivalent classifier and knowledge rules because its trusted user
question is distinct from retrieved meeting passages. One coverage test
enumerates the current Foundation Models entry points and fails if any listed
prompt loses the shared boundary; reviewers must add each new meeting-derived
prompt to that inventory. On the output side, `CompanionAnswer.usable` strips
assistant preambles ("Sure, here's the answer:", "Claro, ...") and drops
role-drift responses ("as an AI ...") alongside the existing hedges — no card
beats a drifted card. Accented Spanish vowels in those patterns ride as ICU
escapes so the file stays inside the English-source gate.

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

## BYOK (D8/D67/D68) — gateway-backed summary and Apuntador clients

- **`OpenAICompatibleChatCodec`**: internal, transport-free request/response codec shared by the summary and Apuntador clients for `/chat/completions` endpoints (OpenAI/OpenRouter/Groq/Ollama/LM Studio). One system + one user message go in and text comes out; no URLSession dependency is reachable through this type.
- **`OpenAICompatibleSummaryClient`**: public summary transport facade that cannot send without an injected `DataEgressGateway`. It declares full meeting-summary material, source meeting identity, exact destination/scope, provider/model, and operation-specific consent separately from the encoded body. Cloud calls do NOT pass through `IntelligenceScheduler` — single-flight exists because of ANE contention and does not apply to the network.
- **`CompanionBYOKClient`**: accepts the same endpoint/model/key shape and also requires a gateway. Its separate operation declares question-only material so recent transcript context can never be smuggled through summary metadata.
- **Receipt semantics (D75)**: the production gateway validates those declarations, persists one immutable content-free attempt, and only then exposes the body to URLSession. Receipt failure prevents the call; HTTP failure retains the attempt; redirects are rejected. Intelligence providers never create or interpret receipt rows themselves.
- **`BYOKSettings`**: endpoint and model remain visible UserDefaults preferences (`byokEndpoint`/`byokModel`); the key is ONLY the PlatformKit Keychain value identified by `SecretIdentifier.byokAPIKey`. App composition resolves that key asynchronously through `ApplicationKit.ManageSecrets` and passes explicit opt-in/endpoint/model/key/gateway values to IntelligenceKit. `companionClient(...)` returns a client only when every value and the explicit `companionBYOKEnabled` consent are present; missing pieces fall back to on-device, never to an error. IntelligenceKit does not import or construct Keychain.
- **`OpenAICompatibleSummaryProvider`**: owns only the summary prompt, JSON→`StructuredSummary` contract, and a gateway-backed summary client. It forwards `SummaryRequest.meetingID`, weaves in user notes (D28) just like on-device, and retains parity tests. Key via `PORTAVOZ_BYOK_API_KEY` in the CLI; in the app, Keychain via Settings.

## Multiple summary engines (D25/M12) — Apple FM · local Ollama · embedded MLX · cloud BYOK

`AppServices.summaryEngine` (UserDefaults `summaryEngine`: `appleOnDevice` / `ollama` / `mlx`) is sampled by app-owned provider resolvers. On a clean install, `ApplicationKit.ConfigureInitialSummaryProvider` probes one capability-neutral profile and initializes the preference only when it is absent: usable Apple FM wins; otherwise Ollama wins only when its running server exposes a nonempty model whose normalized name is not classified as OCR, embedding, reranking, or Whisper work; the explicit-download MLX path is selected when hardware can run it. The main-actor selection store re-checks the preference at its guarded write and reports whether the write won. Existing choices are never migrated silently. `DiscoverLocalSummaryProviders` returns the same typed recommendation to Settings and Onboarding, so process availability cannot be confused with generation readiness and localization remains in presentation. The macOS adapter owns Foundation Models capability, content-free localhost discovery, RAM/disk facts, provider DTO mapping, and UserDefaults persistence (D108). Every manual, import, and durable summary path honors the selected engine exactly: missing Ollama selection, missing MLX download, pre-macOS-26 Apple selection, and unavailable Apple model become typed setup states, never fallback to another provider. Meeting Detail opens the native Settings scene directly at Intelligence for those states (D72).

The durable post-capture worker selects Ollama through `OllamaService.summaryProvider(model:gateway:consent:)` (an `OpenAICompatibleSummaryProvider` against `localhost:11434/v1`, **without an API key** — Ollama ignores it, nothing leaves the device), verified embedded MLX, or available Apple FM. Ollama summary generation still crosses the gateway with `local-device` scope and Settings consent; its content-free health and model-discovery requests remain direct because they contain no meeting material. ApplicationKit's regeneration and import adapters consume explicit availability without constructing providers inside the use cases. The **live rolling summary remains FM-only** (it uses the incremental `condenseWindow`/`summarizeNotes` APIs that Ollama/MLX do not have). `OllamaService`: `isRunning()` (GET `/api/version`), `models()` (GET `/api/tags`, pure/tested `parseModels`). Settings retains the engine picker, detection, model list, localized typed reasons, and prominent Apply action. `LocalSummaryProviderPolicy` is pure and tested against Apple availability, name-screened Ollama models, MLX hardware eligibility, and low-memory/disk guidance. **Closes GAPS #7** (a Mac without Apple Intelligence summarizes 100% locally); verified E2E with gpt-oss:20b (ES summary in 24 s) + UITest of the Settings section. Every provider stamps its own material fingerprint, but the released Meeting Detail path performs cache lookup and translation pivot only for Apple FM; configured Ollama/MLX regenerates directly. **Per-meeting override (M12)**: the `RegenerateSummary` provider resolver forces an engine for one meeting without changing the global default; the detail menu offers language (es/en) and, when there is a real choice, the **alternative engine** (Apple↔Ollama — only the one that is not the default and only if it is usable here: Ollama with a configured model, or Apple with `appleSummaryAvailable`). An Apple override preserves its cache and pivot path.

**Embedded MLX (D32/D151/D161, Jul 2026)**: third engine `summaryEngine = "mlx"` — `MLXSummaryProvider` (IntelligenceKit) runs **Qwen3.5-4B 4-bit** (Apache-2.0, sha256-pinned in `ModelCatalog.mlxQwen35`, 3 GB; `mlxQwen3` remains in the catalog for A/B) in-process on the GPU via `mlx-swift-lm` (exact 3.31.4 — successor to mlx-swift-examples; the tokenizer is provided by `swift-transformers` through the `MLXHuggingFace` macros). **Field A/B (Jul 10, refined 56 min / 852-segment sprint demo)**: Qwen3-4B collapsed into a degenerate loop twice (34k and 68k chars truncated); Qwen3.5-4B with `enable_thinking: false` (additionalContext — the 3.5 family reasons by default and loses the JSON prompt) produced decisions + open questions + 11 action items with owners in clean Spanish in 89 s. `maxTokens` 16384 as a pure anti-runaway safeguard. Reuses the prompt and JSON contract from `OpenAICompatibleSummaryProvider.prompt/parseStructured` — same `StructuredSummary`, same fingerprint. `MLXSummaryRuntime` (actor) keeps one verified `ModelContainer` loaded. Production `MLXSummaryProvider` values receive a narrow client for the AppServices-owned process runtime; AppServices records exact load/use/release transitions, guards model deletion, and preserves the 120-second idle fence. The independent MLX `IntelligenceScheduler` lane still serializes `container.perform` generation with explicit interactive/background priority and content-free queue/execution telemetry. Settings → "Built-in (MLX)": `MLXModelRow` row with verified download/status/delete (`AppServices.mlxDownloaded/downloadMLX/deleteMLXModel`); `LocalSummaryProviderPolicy` suggests it with RAM ≥ 8 GB when Apple Intelligence is unavailable and Ollama has no eligible name-screened model. **Shipping**: SwiftPM does not compile Metal shaders → `scripts/build-mlx-metallib.sh` caches `mlx-swift_Cmlx.bundle` (one-time xcodebuild, keyed by mlx-swift version), and `make-app.sh` copies it to `Contents/Resources`. **E2E verification**: `portavoz-app --mlx-smoke [real]` — synthetic ES in 3 s; with `real`, summarizes the most recent meeting in the library (read-only). Verified with a real meeting of 40 min / 686 segments: 44 s, coherent decisions and action items. Swift tests exercise provider/runtime injection without loading Metal; real generation still requires the bundled metallib. **Memory (critical)**: without `MLX.Memory.cacheLimit`, MLX's buffer cache grows without limit on long prompts — 31 GB of RSS was observed on that same meeting before macOS suspended the process. `MLXSummaryRuntime` sets the supported API to 20 MB (the LLMEval value) and `maxTokens: 16384` as the generation cap; with that, the real peak is ~4.5 GB (2.3 GB weights + KV + runtime) (D118).

## Seeded summary templates (TMPL, Jul 2026)

`Recipe.all` seeds eight templates: General, Standup, 1:1, Planning,
Interview, Discovery, Postmortem, Retrospective — each with fixed sections
and one anti-invention instruction line. `MeetingTypeDetector` carries the
same label set in BOTH its few-shot instructions and the `@Guide` string
(adding a template means touching both, or the classifier never emits it);
its gate still collapses unknown ids and `general` to nil. Presentation is
Spanish-first: built-in names and section titles are catalog keys rendered
through `Recipe.localizedDisplayName`/`localizedSectionSummary` (app-side
`RecipeDisplay.swift`); custom structures stay verbatim because their text
belongs to the user. The Meeting Detail Structure submenu
(`detail-structure-menu`, items `detail-structure-<id>`) shows each
template's section list under its name so the user sees what a structure
produces BEFORE generating; the "Summarize as X?" chip
(`detail-recipe-suggestion`) localizes the suggested name. Section headings
inside a generated summary are translated by the model (prompt rule); the
one heading WE render — the canonical action-items block — now follows the
output language ("Pendientes" for `es`), passed as
`markdown(recipe:language:)`. `parse` reads back exactly those two
headings and no others: the broader `isActionItemsHeading` set stays
confined to dropping a model-narrated duplicate section while rendering,
so a genuine "Next Steps" section survives the round trip.

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

Slice 2G routes post-refine Apuntador work through
`ApplicationKit.ApplyRefinedMeeting` and an app-owned availability/model
adapter. Apuntador runs only after the revision-fenced transcript transaction
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
- **Index**: BLOB in the `embedding` column of `segment` + brute-force cosine (sqlite-vec intentionally deferred). `ApplicationKit.IndexSemanticCorpus` owns corpus writes. It validates one returned vector per eligible segment before persistence and writes an empty marker for micro-segments (< 20 chars), which are excluded because they drowned out cross-lingual hits. The signal-driven background owner requests product drains; explicit disposable benchmarks may prepare their isolated stores. Ask and Library perform no backfill and read only already-published vectors. One process-shared coordinator admits only one maintenance flight.
- **Application boundary (D100/D201)**: `ApplicationKit.AskMeetings` is the only public workflow used by the macOS Ask route, resident command palette, CLI `ask`, local MCP `ask`, and meeting-brief evidence lookup. Instant results and citations are storage-independent values; the optional progressive contract emits lexical and final fused evidence without changing final-result consumers. Generated text is optional, so unavailable or failed local generation preserves evidence instead of converting retrieval success into failure; cancellation still propagates as cancellation.
- **Meeting preparation (D101)**: `ApplicationKit.PrepareMeetingBrief` ranks the shared Ask citations, joins them to one batched latest-live-General-summary projection and independently loaded open commitments, and exposes only storage-independent related meetings, commitments, and knowledge points. Foundation Models synthesis is optional and every returned source index is validated before it becomes a navigable knowledge point; invalid indexes and ordinary model failure produce no invented source, while cancellation remains cancellation.
- **Lexical candidates (D81)**: `ApplicationKit.LocalAskMeetingRetrieval` owns the policy. It normalizes and deduplicates content words ≥ 4 characters, retrieves a bounded FTS top-k list per term for normal questions of up to eight unique terms, and fuses those lists with RRF (`k=60`). Multi-term passages climb without scoring one complete OR union. Longer pasted questions retain the released broad-OR fallback, and every selected hit carries complete segment text in addition to its UI snippet.
- **Hybrid retrieval (D201)**: deterministic English/Spanish variants start bounded lexical and brute-force semantic candidate work concurrently, then fuse with RRF (`k=60`). Lexical citations may publish before semantic completion; only the final fused set reaches generation. FM expansion is a bounded evidence-empty fallback, never a first-evidence prerequisite, and term deduplication spans all variants.
- **Answer**: `OnDeviceAskMeetingIntelligence` wraps the IntelligenceKit query-expansion and answer primitives. The on-device FM receives complete selected segments, not bounded highlighted UI snippets, and citations retain segment/meeting identity plus timestamp. Verified E2E: MCP agent answered "what did we agree about the transcription budget?" with correct sources.

### Corpus-read-only Ask retrieval (D196)

`LocalAskMeetingRetrieval` has no indexing coordinator or corpus-maintenance
operation. It applies deterministic bounded bilingual expansion, then starts
exact FTS and optional semantic work concurrently. Exact citations publish
when FTS finishes. If Apple Latin assets are already available, the semantic
task borrows the shared runtime with `allowAssetDownload: false`, embeds only
query variants, and scans only vectors already persisted by maintenance. The
request cannot persist vectors or turn missing corpus rows into a query
prerequisite.

An unavailable or ordinarily failing semantic runtime returns no semantic
candidates, preserving exact evidence through the same fusion and citation
path. Cancellation is rechecked and propagated. The app's signal-driven owner
continues durable corpus work independently; explicit resource and quality
benchmark setup may prepare only its disposable database before the observed
request begins.

When both deterministic paths produce no citation, the optional Foundation
Models expander may add at most three new normalized variants and retry the
same read-only retrieval. Its duration remains inside the complete Ask trace,
but it emits no duplicate primary expansion stage; a separately versioned
receipt is required before exposing a dedicated fallback-stage metric.

### Content-free Ask stage tracing, receipts, and quality contract (D192–D196)

`AskPipelineTelemetry` owns one random process-local trace for every validated
search, evidence, and answer request. `LocalAskMeetingRetrieval` emits matched
intervals for the current corpus-readiness check, expansion, lexical query,
query embedding, semantic scan, fusion, and citation materialization.
`AskMeetings` emits first-evidence at the first nonempty progressive update,
then first-token and one terminal outcome. Expansion starts before the two
candidate paths; lexical and semantic stage order is intentionally concurrent,
first evidence follows lexical completion, and fusion starts after both settle.
Empty or invalid requests still bypass every capability and trace.

The taxonomy accepts no question, meeting, segment, citation, file, model, or
error payload. Cancellation closes the active stage and complete trace as
cancelled; an ordinary generation failure keeps its established evidence-first
behavior and finishes successfully without a first-token milestone. The
current non-streaming answer capability exposes its first token only when the
complete string returns, so that milestone is intentionally an
ApplicationKit-observable boundary rather than a claim about model-internal
token timing. App composition records the closed values as OSLog Points of
Interest. The benchmark process consumes that observer through one strict
native collector. Every passing isolated Ask run publishes operation,
first-evidence, first-observable-token, and seven stage timings plus only a
corpus generation, corpus checksum, readiness counts, and citation-ordinal
digest. Runtime UUIDs, questions, transcript text, generated answers, paths,
model names, and durable identities never enter the receipt.

The resource assembler requires a one-to-one Ask resource/pipeline run set.
Evaluation reports p50/p95 wall and process CPU for every boundary, separates
time to first evidence from subsequent generation, and blocks on malformed or
invalid citations, changed corpus/result identity, missing runs, or unstable
distributions. Receipt schema 2 proves the fixed ten-segment corpus starts
pending at fixture seed, reaches ready during unmeasured benchmark setup, and
remains ready before and after the measured request. The prior schema-1 cold
backfill receipt remains a historical before-state and is intentionally not
comparable with this request-read-only path.

Quality evidence is intentionally separate from resource evidence. The
canonical public pack contains exactly 240 judged queries across monolingual,
cross-language, code-switched, and isolated robustness relationships. A strict
local evaluator accepts complete adapter/build/commit-bound observations and
scores retrieval, answer quality, abstention, hard negatives, and canonical
citation identity overall and per relationship. Exact fact retrieval and all
declared quality floors fail closed. Its published scorecard contains only
aggregate metrics and fixture/source-control identity; query, transcript,
answer, owner, and citation identifiers remain outside the report. The harness
does not enter the app dependency graph or select an embedding/index adapter.
The CLI production adapter seeds and explicitly indexes a disposable
`MeetingStore` before it executes the real `LocalAskMeetingRetrieval` hybrid
path without opening the user library.
It maps ephemeral identities back to fixture identities and carries transcript
revision through `SearchHit` and `AskCitation`. Its deterministic no-expansion
control isolates shipped retrieval from optional query generation. Answer fields
remain explicitly `notEvaluated`, so retrieval metrics are useful while complete
answer and policy gates still block. The version-2 adapter identity records the
preindexed setup contract. The owner-only observation writer is atomic and
non-overwriting; none of this tooling enters the app dependency graph.
One complete unaccepted development run over all 240 queries reproduced the
adapter-v1 aggregate retrieval metrics exactly, including zero invalid or stale
citations. That is no-drift evidence for the preindexed query path, not an
accepted Release baseline or answer-quality claim.

### Instant Library semantic augmentation (D145)

Library typing stays independent from model setup and generated query
expansion. Its query-specific FTS5 observation publishes exact, accent-folded
English/Spanish results first. `LocalLibrarySemanticSearch` then borrows the
process semantic runtime and the existing StorageKit exact-cosine adapter only
when the OS-managed Latin assets are already present. It never calls
`requestAssets()` from the search field, skips work during active capture, and
never writes a corpus row. Cancellation is checked between preparation, query
embedding, and semantic lookup; any semantic failure degrades to no appended
hits rather than failing lexical search. Exact hits keep their order and
duplicate semantic IDs are discarded. Library and Ask share one app runtime
and one readiness resolver, while the background owner remains independent of
their request lifetimes.

### Shared semantic-indexing flight (D176)

`SemanticCorpusIndexingCoordinator` is the process-owned ApplicationKit actor
between background maintenance and `IndexSemanticCorpus`. It admits one active
flight. Product queries never join it. Concurrent complete maintenance callers
join the same drain; explicit disposable benchmarks may also use a coordinator
owned by their isolated process or fixture.

The coordinator owns one active task plus waiter identities and a scalar
complete-demand count, not an unbounded request queue. Cancelling one borrower
does not cancel work still awaited elsewhere; cancelling the final waiter
cancels the worker and the operation's cancellation fence prevents embedding
persistence. Missing rows stay `NULL`, so a coalesced bounded request is
rediscovered by the next background signal. Exact FTS remains independent and
publishes first. There is no second product indexing lane.

### Capture-prioritized semantic checkpoints (D177)

`IndexSemanticCorpus` receives an ApplicationKit `DurableMaintenanceGate`
rather than reading app or platform state. Before its first storage read it
evaluates admission for the established
`maintenance/searchIndex/execute` descriptor. After each persisted bounded
batch, a complete drain evaluates one checkpoint before fetching more work.
The unrestricted default preserves deterministic CLI, benchmarks, and isolated
use-case composition.

The macOS composition root evaluates those boundaries against the pure resource
policy and its lock-protected capture mirror. Starting, active, and stopping
capture map deferral or checkpoint-pause decisions to one expected suspension.
An admitted batch is never rolled back: its vectors and micro-segment markers
commit atomically, the result records `pausedByPolicy`, and remaining `NULL`
rows continue to own the work durably. A later request resumes those rows
without a timer or in-memory queue.

Ask cannot be paused by corpus maintenance because it does not join that
flight. It proceeds with exact lexical evidence and every semantic row already
indexed; Library has the same read-only relationship, and its exact results
remain independently observable and first.
D178 supplies wake-on-capture-stop ownership. Host-pressure, power, and
storage adapters remain later durable-maintenance work.

### Signal-driven background semantic owner (D178)

The macOS process owns one `SemanticCorpusIndexingSupervisor` around the shared
D176 coordinator. App launch, successful searchable mutations, and capture
returning inactive are explicit wake signals. While one drain is active, every
additional signal sets one rerun bit; after that rerun, the owner sleeps until
another signal or a D200 durable wake. There is no polling loop or request
array; only one cancellable future wake may represent a persisted retry or
predecessor lease expiration.

The production adapter checks cancellation, protected capture, and one pending
`NULL` embedding row before it inspects the semantic runtime. It proceeds only
when Apple's Latin contextual embedding assets are already installed and
always requests `allowAssetDownload: false`. The D177 gate still rechecks
capture inside the indexing operation after each committed batch. Temporary
and isolated benchmark stores disable this owner.

Ordinary failure keeps the durable rows pending under D200's bounded retry
envelope. Ask never repairs those rows in the request path; it keeps exact
lexical evidence and any semantic rows already published. Library follows the
same rule. The shared readiness resolver reports a pending failed corpus as
`failed`, while published vectors remain queryable, so a background failure is
partial semantic coverage rather than query failure or user-facing maintenance
latency.

### Typed semantic readiness and background-only writes (D197)

`ResolveSemanticCorpusReadiness` is the shared ApplicationKit query contract.
It performs no preparation or persistence. It combines the injected runtime's
installed-asset capability, a valid active embedding profile, a profile-aware
durable maintenance probe, and one process-shared
`SemanticCorpusMaintenanceState` into five closed states:
`ready` when no live row is pending, `partial` when rows are pending and the
owner is idle, `building` while a drain is active, `failed` after an ordinary
drain failure with pending rows, and `unsupported` when this process cannot
produce a query vector. A complete corpus wins over stale process failure and
resolves `ready`.

Exact FTS is independent of every state. Ask and Library may search already-
published vectors in `ready`, `partial`, `building`, or `failed`; only
`unsupported` skips semantic work. Neither query path owns a coordinator,
invokes `IndexSemanticCorpus`, persists a vector, or downloads an asset. The
supervisor transitions the shared process state synchronously to `building`
before starting a drain and to `idle` or `failed` when the final coalesced pass
finishes. Durable `NULL` rows remain the real progress cursor; the phase stores
no corpus identity or payload and is not a durable job system.

### Revision-fenced semantic publication (D198)

`IndexSemanticCorpus` carries each selected segment's immutable source identity
through the embedding call: segment ID, meeting ID, transcript revision, and
exact text. Its StorageKit publication is one compare-and-swap boundary. A
vector is accepted only while that live segment is still unembedded, the live
meeting is still at the selected revision, and the source text still matches.

Published and skipped segment IDs are returned as content-free outcomes. The
operation counts only accepted full-text and micro-segment-marker writes;
concurrent completion, correction, replacement, or deletion is not a model
failure. Current replacement rows remain `NULL` and a later supervisor signal
resumes them. No second cursor, timer, heartbeat, processing job, asset
download, or query-path write is introduced.

### Compatibility-fenced semantic vectors (D199)

`SemanticEmbeddingProfile` identifies the complete persisted vector space:
the Natural Language model identifier and revision, vector dimension,
Portavoz pooling-pipeline identifier and revision, and binary vector-schema
version. A stable SHA-256 fingerprint of that profile is stored beside every
vector. The profile contains no transcript or query content.

The prepared embedder is the authority for the active profile. Readiness,
background maintenance, Ask, Library, CLI, and benchmark adapters pass that
same typed value instead of inferring compatibility from vector width. Storage
accepts publication only when every non-empty vector has the profile's exact
dimension and only finite values, then commits the vector and fingerprint in
the same revision-fenced update. Semantic reads scan only rows carrying the
active fingerprint.

When the model, its revision, dimension, pooling pipeline, or vector schema
changes, maintenance resets only incompatible derived vectors to the existing
`NULL` replay cursor before rebuilding them. Exact FTS and authoritative
transcript rows remain available throughout the rebuild. An invalid or
unavailable profile disables semantic work rather than reading an unknown
vector space.

### Durable semantic maintenance ownership (D200)

`ProcessSemanticCorpusMaintenance` owns one content-free scheduling operation
for the active embedding profile and semantic source generation. StorageKit
advances that generation only for authoritative transcript mutations; vector
publication is excluded. Admission is idempotent, superseded pending work is
cancelled, and a kind-wide lease prevents concurrent process owners. The lease
has a bounded heartbeat, but semantic progress remains exclusively in missing
or incompatible `NULL` vector rows.

Expected capture suspension clears the lease, returns the operation to pending,
and refunds its attempt. Ordinary failures receive two bounded retries and the
macOS owner schedules one future wake rather than polling. A relaunch before a
dead owner's lease expires wakes at that expiry; after expiration StorageKit
recovers the same operation and resumes only remaining rows. Terminal derived
failure does not change meeting lifecycle or exact FTS availability, and the
meeting-processing `.index` kind remains dormant.

### Speaker-safe retrieval chunk candidate (D202)

`RetrievalTurnChunker` is a pure ApplicationKit policy used to evaluate richer
semantic context before any production-index migration. It sorts and validates
authoritative transcript rows, rejects mixed meetings, duplicate identities,
unknown speaker references, and invalid timelines, and emits deterministic
`RetrievalChunk` values. Adjacent sources may coalesce only when they resolve
to one confirmed person, one meeting-local speaker, or the local microphone.
Unattributed remote/room rows remain separate, and no length target can merge
different actors.

Every chunk keeps ordered segment identities and exact temporal, channel,
speaker, person, and per-source spoken-language evidence. Text receives only
canonical Unicode and whitespace normalization; chunking never translates or
corrects vocabulary. Stable membership identity is separate from a source
fingerprint that covers each source's normalized text. `RetrievalChunkDelta`
therefore retains unaffected chunks across a meeting revision while upserting
only membership, source text, attribution, language, or timing changes. The
revision still travels with the derived value as a future publication fence.

This contract is not used by product Library, Ask, the semantic maintenance
owner, or StorageKit. The CLI quality harness may project it into a disposable
database and run the same production retrieval implementation used by the
segment control. Observation schema 2 keeps one ranked chunk identity plus all
ordered canonical source segment identities, so source order, revision,
hard-negative inclusion, and exact citation timestamps remain fail-closed.
The current public-synthetic-v2 topology contains two two-segment same-actor
turns in every four-segment meeting and interleaves spoken languages. A strict
offline comparator accepts only the exact segment-control and speaker-turn
adapter identities from one fixture, build, commit, and schema-2 observation
pair. It blocks any aggregate or language-relationship retrieval regression;
its parity outcome is evidence, not permission to alter product retrieval.
Segment-level embeddings remain authoritative until the candidate proves
multilingual quality, latency, memory, disk, and incremental correction
behavior against the current segment baseline.

### Semantic-index query port (D206)

`SemanticIndexSearching` is the read-only ApplicationKit seam between product
retrieval and a concrete vector query implementation. It accepts one query
vector, the exact active `SemanticEmbeddingProfile`, and a bounded result limit;
it returns current StorageKit `SearchHit` projections so citation identity,
timestamp, meeting, and transcript revision remain available to Ask and
Library. Query-vector creation and the runtime lease stay outside the port.

The shipped `AccelerateExactSemanticIndex` delegates to the existing
SQLite-streamed cosine scan. `LocalAskMeetingRetrieval` and
`LocalLibrarySemanticSearch` inject the port and default to that adapter, so
their lexical-first policy, readiness gate, cancellation, rank fusion, and
failure degradation are unchanged. Corpus indexing, compatibility invalidation,
and durable maintenance do not depend on the query port and retain one writer.
Three deterministic tests prove exact-control rank parity and that both product
consumers use an injected adapter with the expected vector, profile, and limit.

No shadow engine is composed yet, candidate output is not served, and no
sqlite-vec, Core Spotlight, USearch, schema, package, or migration has been
selected. Later SEARCH-5 slices must put candidates behind this seam and retain
exact control as the only user-visible authority until accepted quality and
resource evidence exists.

### Non-serving semantic shadow comparison (D207-D211)

`ShadowComparingSemanticIndex` is a benchmark-only decorator over the D206
port. It waits only for the exact control, projects its citation identity to a
private `(segment ID, transcript revision)` comparison key, submits the same
vector/profile/limit to an injected candidate executor, and immediately returns
the control hits without awaiting the candidate. The candidate result is never
returned to Ask or Library. A failed or cancelled candidate cannot change the
control outcome, while a failed control prevents shadow scheduling because no
authoritative comparison exists.

The emitted `SemanticIndexShadowEvent` is structurally payload-free: it contains
only a closed candidate-family enum, closed outcome, vector dimension, requested
limit, result counts, overlap count, same-rank count, optional top-hit agreement,
and control/candidate durations. It has no fields for user queries, vectors,
meeting or segment IDs, titles, transcript text, model identifiers, paths, or
raw errors. Tests inject a manual executor to prove the control is returned
before candidate execution and that divergent or failed candidates remain
non-serving. Construction requires both telemetry and executor explicitly, so a
candidate cannot run through an accidental evidence-disabled default.

`SemanticIndexShadowCandidateSearching` refines the query port with one closed
research-adapter identity owned by the candidate implementation. The decorator
accepts that candidate directly and derives every event identity from it; no
parallel constructor label can name a different engine than the implementation
that ran. This binds comparison attribution before a concrete engine or package
is introduced.

Derived engines implement `SemanticIndexShadowRanking` and return only ordered
`SemanticSearchCandidateIdentity` values: segment ID plus the transcript
revision from which the rank was derived. The generic
`ProjectedSemanticIndexShadowCandidate` bounds the candidate list by the
requested limit and asks `MeetingStore` to materialize current citations in
that order. Projection omits negative revisions, duplicate segment IDs,
missing/deleted rows, deleted meetings, and revision mismatches. It never
backfills from ranks beyond the requested window, so stale evidence cannot
silently change the measured candidate workload or citation authority.

`SemanticIndexShadowCoordinator` is the optional benchmark executor for the
decorator. It evaluates every candidate at the existing durable-maintenance
`.admission` boundary as a `.maintenance` / `.searchIndex` / `.execute`
workload. It retains at most one active flight and no queue: policy denial,
another active candidate, or capture suspension produces a closed payload-free
skip outcome. Capture suspension cooperatively cancels the active candidate;
resume waits for that flight to settle before accepting later work. Candidate
implementations therefore remain responsible for cancellation cooperation.

The default product composition still injects `AccelerateExactSemanticIndex`
directly. The shadow wrapper and coordinator have no app wiring, durable output,
candidate package, derived schema, or index writer. D208 governs research work;
it does not enable a shipping shadow lane or select an engine. D209 binds
candidate identity to its implementation without adding an adapter dependency.
D210 makes current StorageKit evidence the only candidate projection authority;
it still adds no concrete engine, package, schema, or app wiring.

The first engine experiment is fixed to sqlite-vec v0.1.9 exact full-scan. Its
official amalgamation archive is pinned by SHA-256 in
`scripts/vendor-sqlite-vec.sh`, which accepts an offline archive or downloads
the same checksum-pinned release asset and stages only static C/header files plus the
separately reviewed and checksum-pinned upstream MIT text.
Dynamic extension loading is not permitted in the signed macOS app. D211 is a
supply-chain boundary only: no vendored source, SwiftPM target, schema, writer,
ranker, benchmark composition, or product wiring exists yet. sqlite-vec ANN
alphas and USearch HNSW remain deferred until exact parity has isolated runtime,
disk, packaging, and correction costs without approximate-recall tradeoffs.

### Governed semantic embedding runtime (D165)

ApplicationKit exposes `SemanticEmbeddingRuntimeClient` rather than a concrete
NaturalLanguage model. Its generic operation closure receives only a prepared
`SemanticTextEmbedding` and keeps the app's exact residency lease alive for the
entire callback. Ask starts deterministic lexical retrieval and semantic
readiness concurrently; only the semantic branch borrows the runtime and
performs query-vector creation plus semantic lookup inside that callback.
Library performs only query-vector creation and semantic lookup inside the
same boundary. Background maintenance separately holds its lease
around corpus indexing. The runtime also exposes the active compatibility
profile without preparing or downloading assets.

The macOS adapter owns one actor-backed `SentenceEmbedder` per process and
coalesces preparation. Library and Ask call it only after
`hasAvailableAssets` and pass `allowAssetDownload: false`. Ask treats ordinary
preparation or semantic-query failure as no semantic candidates while
propagating cancellation. A failed load is generation-fenced and retryable.
Explicit release unloads only the in-process model and is rejected while
either surface is borrowing it. The CLI composes one equivalent process-local
runtime; isolated semantic benchmark constructors are not production owners.
Index persistence, brute-force exact cosine, and the
decision to defer sqlite-vec remain unchanged.

## Coauthoring notes (D28) — the notes→summary weave (implemented)

- `SummaryRequest.contextItems`: user notes travel to the FINAL pass as intent. `PromptFactory.notesBlock` formats them with timestamps (`[mm:ss] nota`), chronologically, with a hard budget (120 chars/note, 800 for the block — tested).
- **3B budget respected**: the block shares the window with the condensed material, so the reduce target SHRINKS by exactly the space occupied by the block (`condense(reduceBudget:)`).
- Instructions (`notesBehavior`): each note is a topic the summary MUST cover, expanded with facts, never contradicted; bullets originating from a note are prefixed with **"▸ "** — a cheap token instead of inflating the guided-generation schema; the renderer can display Granola-style coauthorship (black/gray) without changing types. The language instruction still closes the prompt (D18).
- Full flow wired: **notes panel in `RecordingView`** (TextField + timestamped list with remove, right column, always visible during recording) → `RecordingController.addContextNote()` (anchors to the current moment) → rolling and final summaries see them → persisted at stop (`contextItem` table, v3 migration) → regeneration in the detail reloads them from the store. **Coauthorship rendering** in `MarkdownText`: bullets prefixed with "▸ " are drawn with an accent mark (Granola style — content originating from your note is distinguishable from the pure AI summary). M10 complete except for field verification (5 real notes → summary that expands them).

## Enhanced notes (NOTES-001/D135) — the notes→document expansion (implemented)

`ApplicationKit.EnhanceMeetingNotes` is the Granola-pattern complement to the
D28 weave: instead of covering notes inside the summary, it produces ONE
separate regenerable document FROM them. It reuses the summary machinery
wholesale — `SummaryRegenerationProviderResolver` (FM/Ollama/MLX/BYOK, per-call
engine override), `SummaryFingerprint` (its internal `enhanced-notes` recipe id
keeps these fingerprints disjoint from every summary cache row), and the
D62–D78 provenance regime (`GenerationRunKind.enhancedNotes`; exact
fingerprint + language hit → `.unchanged`, no model call, no run; succeeded run
commits atomically with the `EnhancedNote`; failed/cancelled runs persist
best-effort with content-free sorted-keys config/metrics JSON). The recipe's
contract: each raw note repeated verbatim in bold, in order, expanded with one
to three sentences of what the transcript shows around that note's moment;
contradictions stated plainly; only the notes covered; nothing invented.
Whitespace-only notes are dropped before fingerprinting; a meeting with no
usable notes answers `.noNotes` before resolving any provider.

## On-demand catch-up

`CatchUpPolicy.clip` is a pure admission boundary over closed live-caption
rows. It excludes the coalescer's mutable tail, requires at least two admitted
rows, keeps only the last five minutes, and preserves the newest material when
prompt formatting reaches its budget. The app maps microphone/system channels
to local/remote speaker identities and asks
`FoundationModelSummaryProvider.catchUp` for a 2-4 bullet recap at interactive
priority. The prompt uses the shared source-material guard and follows the
homogeneous spoken language when one exists.

Generation is recording-scoped and ephemeral: one task owns one visible card,
and neither request nor result enters StorageKit. Dismiss cancels and clears
the task. Stop performs the same cancellation before durable capture handling;
completion and failure paths independently fence publication on the recording
still being active. Unsupported platforms return a truthful local capability
message without attempting provider fallback.

## Live Apuntador (D26) — `LiveCompanion` + `QuestionHeuristic` + `CompanionCard`

3-stage pipeline over coalescer rows. A row closes when the next one is created; since D138 a silence endpointer also treats the still-OPEN remote row as a finished turn after 2.0 s without any new delta (`TurnEndpointPolicy` — one shared channel/noise/question gate for silence and real close, one detection per row+text-length, the row itself stays open for presentation). Every accepted delta re-arms the deadline; entering the recording phase first drains rows that closed while Start was preparing and then arms the open tail. Enabling Apuntador mid-recording arms an already-open remote row, while disabling Apuntador cancels it. Without this synchronization, a question followed by silence produced no card until someone spoke again — or ever, if the meeting stayed quiet:
1. **Pure gate** (tested, es/en): `looksLikeQuestion` (`?`/`¿`, initial interrogatives, minimum 12 chars) **OR `mentions(ownerName)`** — the "te preguntaron" detector: whole-word, case/diacritic-insensitive match of the first name or full name ("John" does NOT trigger inside "Johnny"). The name comes from Ajustes ("Tu nombre") with default `NSFullUserName()`. The common case (nobody asked) costs zero.
2. **FM classifier** (`DetectedQuestion` @Generable: isQuestion/question/kind) sent to the scheduler with `.live` + key `companion-detect` (latest-wins: ticks never stack up). `logistics` → no card (the classic failure mode for this class of features), **unless the caption names you**: then the card is a PING ("te preguntaron", question without an invented answer, orange tint). Two lessons from the 3B caught by the gated test: (a) `directed` is ALWAYS the deterministic name gate, never the model's opinion (requesting it as a field → it stripped "Johnny," from the question and reported false); (b) the logistics filter needs literal few-shot examples ("¿nos acompañas mañana…?" is logistics, NOT context) — with only the abstract rule, it leaked through.
3. **Answer**: `knowledge` → BYOK if the user configured it AND enabled the opt-in (app composition injects the resolved `CompanionBYOKClient`; same instructions as on-device, 400 tokens max, `source` = provider host; if the provider or egress-policy call fails, it falls back to on-device FM and says so in `source`); without BYOK → direct FM (1–3 sentences, same language, greedy, 220 tokens max, `.interactive`). `context` → `RAGAnswerer` with the last ~13 live rows as passages ("¿qué dijimos del budget?" answers from what was JUST said) — meeting context NEVER goes to BYOK, only the text of the `knowledge` question (D8/D67). Explicit cancellation never falls through to the local answer.

The classifier is also the question-cleaning boundary. It is instructed to use
normal sentence case, and a narrow deterministic presentation repair runs only
when a long output overwhelmingly capitalizes every word. The repair preserves
the configured owner's name and common technical acronyms; it never rewrites
the source transcript.

App: per-recording opt-in ("Apuntador" toggle next to the translation toggle, persists in `companionEnabled`); unlimited, newest-first, scrollable cards (question + answer + provenance — provider host or "on-device" — + copy/dismiss). On close, they are persisted in `companionCard`; the detail keeps the existing asked-at playback action and additionally separates exact question sources from answer sources. Refine rederives them: an incomplete pass retains the previous snapshot, and a complete pass replaces it, including with an empty set to remove stale questions. Answer cleanup removes only citation markers and trailing verbatim `passage N` references, never legitimate intermediate text. It never answers for you (D26). The classifier requires macOS 26 plus available Apple Intelligence, so the recording and Settings enable controls exist only when `FoundationModelsCapability` is available. On Sequoia, the Voice pane explains the requirement and that BYOK replaces only the knowledge-answer provider, not question detection; the independent post-meeting Mirror remains available. Settings' external-model section keeps its endpoint/model/key readiness rule, additionally disables Apuntador BYOK when the classifier cannot run, and turns the opt-in off when its key is removed (D72). Latency budget: bounded by D29 (replaceable `.live` detection + `.interactive` answer with wait ≤ in-flight call).

### Bounded live Apuntador work (D170)

The scheduler's `companion-detect` key bounds replaceable classifier calls, but
the complete live operation also includes request construction, BYOK
resolution, answer generation, and result delivery. App composition therefore
owns one `LiveCompanionWorkCoordinator` for the recording lifecycle. It runs
one complete `ProvenanceCompanion.generate` request at a time and retains only
the newest candidate that has not started. A later candidate replaces that
single pending slot without cancelling an answer already in progress.

Opt-out, Stop, reset, and next-session transitions clear pending material and
cancel the worker. Publication checks task cancellation after the complete
generator returns, so even a provider that finishes after ignoring
cancellation cannot create a card. A candidate submitted for a new lifecycle
waits for the cancelled operation to unwind instead of overlapping it. This
bound applies only to ephemeral generation work: accepted visible cards remain
unlimited history until the user dismisses them or the recording resets.

### Deterministic Apuntador card admission (D172)

Bounded execution prevents a task pile-up but cannot make generated output
idempotent. A still-growing row and its later close may both complete, and a
split caption may carry different row identities. `CompanionCardAdmission`
therefore runs after generation in both the live and post-Refine paths.
Overlapping question segment IDs are authoritative evidence that two cards
represent one source turn. A 12-second lexical fallback handles adjacent
split-row forms only when both contain enough distinctive material, have very
high token containment, and agree on negation polarity. Exact repeated wording
outside that live window remains an independent later question.

For one lineage, the card with the longer question, broader question evidence,
usable answer, or directed status replaces the weaker card; otherwise the
candidate is rejected. Replacement also replaces the card-keyed provenance
artifact. This policy changes neither question detection nor model answers and
never merges cards merely because their generated answers look similar.

### Bounded live-summary delivery (D171)

The FM-only incremental summary is invalidated by closed caption rows, late
live-speaker splits, and context-note changes. One app-owned coordinator
collapses those signals into one pending bit, keeps the established 40-second
minimum cadence, and permits one complete map/collapse/reduce cycle at a time.
Silence creates no timer work, and input bursts cannot create a task queue.

Each map step receives at most 32 oldest unseen closed rows and 6,000
characters. An oversized oldest row proceeds alone. Successful cycles report
whether unseen rows remain so backlog drains through later bounded passes. A
provider failure leaves the identity cursor unchanged and waits for the next
evidence signal rather than retrying forever. Condensed notes, row identities,
and the visible summary are candidate state until every provider step succeeds
and the task still belongs to the same active recording; only then do they
publish together. Reset, next-session, and Stop cancel the coordinator.

Automatic objective checking shares the same bounded cycle only when
Apuntador is enabled. Its detector checks cancellation after inference before
changing any objective. Neither live summary nor objectives gate capture,
durable captions, Stop, or final post-capture summary generation.

### Apuntador transcript evidence (D91)

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

### Apuntador-card generation provenance (D66)

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

### Apuntador egress enforcement (D67)

The production live and post-Refine paths inject IntegrationsKit's
`URLSessionDataEgressGateway` into `CompanionBYOKClient`. The request carries a
content-free operation (`companion-knowledge-answer`), exact destination,
`local-device`/`remote` scope, `meeting-question-only` classification, source
meeting ID, Settings consent source, and provider/model disclosure separately
from its body. The adapter validates those facts before URLSession sees the
payload and rejects missing-host or non-HTTP(S) destinations. Only provable
loopback (`localhost`, `*.localhost`, valid `127/8`, or
`::1`) is local-device; private LAN, `.local`, malformed, and unknown hosts are
remote. A directly constructed public Apuntador client uses an explicit-client
consent marker and remains gateway-mandatory.

The body contains static Apuntador instructions and the classified knowledge
question only. No `RAGPassage`, transcript window, owner identity, or stored
card content enters the transport metadata or body. Offline tests capture and
decode the exact request, validate loopback classification and metadata
rejection, and an architecture test prevents Apuntador, provenance, or app
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
Apuntador consent marker used for a summary (or vice versa) before transport.

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
