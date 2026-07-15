# Spec 04 — Intelligence (IntelligenceKit)

Status: implemented and verified (ES summary of EN meeting with glossary intact in 3.8 s; RAG answering with citations via MCP). Decisions: D8 (local by default, explicit BYOK), D18 (FM map-reduce), D22 (RAG), D26 (Companion implemented).

## Model scheduler — `IntelligenceScheduler` (D29)

Single-flight actor that serializes EVERY FM call in the process with priorities `interactive > live > background`, FIFO per class, latest-wins by `key` (for discardable Companion ticks), and caller cancellation. Granularity = one call: map-reduce chains release the slot between steps → an interactive job's wait is bounded by the in-flight call (~1–4 s). No FM dependency (7 pure tests, run on any platform). The provider's public methods accept `priority:` (default `.interactive`); the app's rolling summary passes `.background`. Swift 6: `Response<T>` is not Sendable → closures return payloads built inside the slot.

## On-device summaries — `FoundationModelSummaryProvider`

Requires macOS 26 + active Apple Intelligence (`unavailabilityReason()` provides the human-readable reason: ineligible device / AI turned off / model downloading).

**3B model budgets (measured, nonnegotiable):**
- The 4096-token window counts EVERYTHING: instructions + prompt + guided-generation schema + output. Structured-pass material ≤ ~3000 chars (`TranscriptFormatter.onDeviceReduceBudget`).
- Recursive map-reduce: 4500-char chunks (`onDeviceChunkBudget`) → notes with `maximumResponseTokens: 250` (guarantees ≥4× compression per level → convergence; without the cap, it does NOT converge) → recurse until it fits; max depth 4.
- **Always greedy decoding** (`GenerationOptions(sampling: .greedy)`): with sampling, the 3B invents action items (observed). Strict guidance: "solo compromisos explícitos, array vacío si no hubo".
- FRESH session per chunk (sessions accumulate context and overflow on the second chunk).

**Guided generation**: `GeneratedSummary` (@Generable) → overview + sections (instructed headings) + actionItems (owner by label). `StructuredSummary.draft(for:)` resolves owners against Speakers by label/displayName (case-insensitive).

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

## BYOK (D8) — `OpenAICompatibleChatClient` + `BYOKSettings` + `OpenAICompatibleSummaryProvider`

- **`OpenAICompatibleChatClient`**: minimal client for any `/chat/completions` endpoint (OpenAI/OpenRouter/Groq/Ollama/LM Studio) — one system + one user go in, text comes out. `providerLabel` = endpoint host (the honest name for the disclosure: "api.openai.com" means cloud, "localhost" means nothing left the device). Static, pure request/parse (tested offline). Cloud calls do NOT pass through `IntelligenceScheduler` — single-flight exists because of ANE contention and does not apply to the network.
- **`BYOKSettings`**: endpoint and model in UserDefaults (`byokEndpoint`/`byokModel`); the key ONLY in Keychain (`SecretStore.byokAPIKeyService`). `client(...)` returns a ready client or nil — no one sees a half-configured state. `companionClient()` additionally requires the explicit `companionBYOKEnabled` opt-in (D26: configuring is not consenting); missing pieces fall back to on-device, never to an error.
- **`OpenAICompatibleSummaryProvider`**: now owns only the summary prompt and JSON→`StructuredSummary` contract; HTTP lives in the chat client. It weaves in user notes (D28) just like on-device — parity tested. Key via `PORTAVOZ_BYOK_API_KEY` in the CLI; in the app, Keychain via Settings.

## Multiple summary engines (D25/M12) — Apple FM · local Ollama · embedded MLX · cloud BYOK

`AppServices.summaryEngine` (UserDefaults `summaryEngine`: `appleOnDevice` default / `ollama`) + `configuredSummaryProvider()` → nil = Apple FM (map-reduce + scheduler + cache/pivot); Ollama = `OllamaService.summaryProvider(model:)` (an `OpenAICompatibleSummaryProvider` against `localhost:11434/v1`, **without an API key** — Ollama ignores it, nothing leaves the device). `AppServices.summarize(_:)` centralizes: configured provider, or FM on macOS 26, or throw. It wires the final summary (recording + import) and regeneration; the **live rolling summary remains FM-only** (it uses the incremental `condenseWindow`/`summarizeNotes` APIs that Ollama does not have). `OllamaService`: `isRunning()` (GET `/api/version`), `models()` (GET `/api/tags`, pure/tested `parseModels`). Ajustes → "Motor de resúmenes": picker + detection + model list + **"Recomendado para tu Mac"** (pure `HardwareRecommender.advise(HardwareProfile)`: RAM + Apple Intelligence + Ollama running + free disk space → suggested engine with readable reasons + "Aplicar" button; `AppServices.currentHardwareProfile()` reads the real hardware). **Closes GAPS #7** (a Mac without Apple Intelligence summarizes 100% locally); verified E2E with gpt-oss:20b (ES summary in 24 s) + UITest of the Ajustes section. For non-Apple, fingerprint caching applies the same way, but the translation pivot is FM-only. **Per-meeting override (M12)**: `configuredSummaryProvider(override:)` forces an engine for a specific meeting without changing the global default; the detail's "Regenerar" menu offers language (es/en) and, when there is a real choice, the **alternative engine** (Apple↔Ollama — only the one that is NOT the default and only if it is usable here: Ollama with a configured model, or Apple with `appleSummaryAvailable`). The override flows through the same branch (direct Ollama vs FM with cache/pivot), so an override to Apple preserves the cache and pivot.

**Embedded MLX (D32, Jul 2026)**: third engine `summaryEngine = "mlx"` — `MLXSummaryProvider` (IntelligenceKit) runs **Qwen3.5-4B 4-bit** (Apache-2.0, sha256-pinned in `ModelCatalog.mlxQwen35`, 3 GB; `mlxQwen3` remains in the catalog for A/B) in-process on the GPU via `mlx-swift-lm` (exact 3.31.4 — successor to mlx-swift-examples; the tokenizer is provided by `swift-transformers` through the `MLXHuggingFace` macros). **Field A/B (Jul 10, refined 56 min / 852-segment sprint demo)**: Qwen3-4B collapsed into a degenerate loop twice (34k and 68k chars truncated); Qwen3.5-4B with `enable_thinking: false` (additionalContext — the 3.5 family reasons by default and loses the JSON prompt) produced decisions + open questions + 11 action items with owners in clean Spanish in 89 s. `maxTokens` 16384 as a pure anti-runaway safeguard. Reuses the prompt and JSON contract from `OpenAICompatibleSummaryProvider.prompt/parseStructured` — same `StructuredSummary`, same fingerprint. `MLXModelCache` (actor) keeps ONE `ModelContainer` loaded and serializes generation (`container.perform`, temperature 0); it does not pass through `IntelligenceScheduler` (GPU, not ANE). Ajustes → "Built-in (MLX)": `MLXModelRow` row with verified download/status/delete (`AppServices.mlxDownloaded/downloadMLX/deleteMLXModel`); `HardwareRecommender` suggests it with RAM ≥ 8 GB and no Apple Intelligence or Ollama. **Shipping**: SwiftPM does not compile Metal shaders → `scripts/build-mlx-metallib.sh` caches `mlx-swift_Cmlx.bundle` (one-time xcodebuild, keyed by mlx-swift version), and `make-app.sh` copies it to `Contents/Resources`. **E2E verification**: `portavoz-app --mlx-smoke [real]` — synthetic ES in 3 s; with `real`, summarizes the most recent meeting in the library (read-only). Verified with a real meeting of 40 min / 686 segments: 44 s, coherent decisions and action items. There is no test under `swift test` because the CLI runner cannot have a metallib. **Memory (critical)**: without `MLX.GPU.set(cacheLimit:)`, MLX's buffer cache grows without limit on long prompts — 31 GB of RSS was observed on that same meeting before macOS suspended the process. `MLXModelCache` sets 20 MB (the LLMEval value) and `maxTokens: 2048` as the generation cap; with that, the real peak is ~4.5 GB (2.3 GB weights + KV + runtime).

## Fingerprint cache + translation pivot (D25) — `SummaryFingerprint` + `translate`

- **`SummaryFingerprint.compute(request:providerID:)`**: SHA-256 of the MATERIAL and method — formatted transcript (with speaker names: renaming `S1` to `José` invalidates it because it changes attributions), D28 notes block, glossary, recipe, providerID, and `promptVersion` (constant to bump when prompts change substantially). **Intentionally excludes the output language** — that is what enables the pivot. Each provider stamps the fingerprint onto the draft it produces.
- **Regenerar (detail)**: same fingerprint + same language already saved → "ya está al día" notice without a model call (greedy would reproduce the same result); same fingerprint in ANOTHER language → `translate(pivot)`; otherwise → full summary.
- **`translate(_:to:glossary:)`**: parses the pivot markdown back into a structure (`StructuredSummary.parse` — invertible because EVERY snapshot comes from our renderer; round-trip tested) and translates **piece by piece: one call for the overview, one per section, one for the action items**. Piecewise because when given the whole thing — even with a guided schema — the 3B invented sections (2 failed iterations of the gated test: opaque markdown → truncated at the first paragraph; one-call mirrored schema → 3 sections of 1). The structure survives by construction; any bullet/item mismatch throws, and the caller falls back to a full resummary. Item owners travel positionally; the result retains the pivot's fingerprint. **Measured: constant 2.4 s vs 10.9 s for resummarizing the long synthetic meeting** (the savings scale with the meeting).

`SummaryOperationFingerprint` is deliberately separate from that cache key.
It length-prefixes and hashes D25 material identity plus provider, requested
output language, and source transcript revision, so a durable worker cannot
publish a summary produced for a stale cast, provider, or language. Ollama's
identity exactly mirrors the provider's `localhost/<model>` cache identity.
After successful diarization, D42 atomically enqueues this exact operation. The
process worker recomputes it before generation and completes through the D41
summary Unit of Work. Transient provider failure retries durably; exhausted
summary work cancels without failing the meeting because the released product
already treats a transcript without a summary as valid.

D43 preserves post-meeting Shortcut behavior after Stop becomes asynchronous.
When no summary provider is available, the Shortcut receives transcript-only
Markdown after diarization. Otherwise it runs after summary success or terminal
optional cancellation. This hook remains best-effort; disposable temp-store
launches suppress it, and exactly-once external delivery remains planned for
the Band 3 outbox.

## Local RAG (D22) — `SentenceEmbedder` + `RAGAnswerer` + storage

- **Embeddings**: `NLContextualEmbedding(script: .latin)` — shared es/en space (genuinely cross-lingual). Mean-pool + L2-normalize. `prepare()` requests assets from the OS.
- **Index**: BLOB in the `embedding` column of `segment` + brute-force cosine (sqlite-vec intentionally deferred). Micro-segments (< 20 chars) EXCLUDED from the index (they drowned out cross-lingual hits).
- **Hybrid retrieval**: FTS5 with OR of content words ≥ 4 chars (AND over the literal question never matches) + semantic; RRF fusion (k=60). Multi-query: FM generates bilingual paraphrases of the question (`expandQuery`).
- **Answer**: on-device FM with `[n]` citations that map to segments (meetingID + timestamp). Verified E2E: MCP agent answered "what did we agree about the transcription budget?" with correct sources.

## Coauthoring notes (D28) — the notes→summary weave (implemented)

- `SummaryRequest.contextItems`: user notes travel to the FINAL pass as intent. `PromptFactory.notesBlock` formats them with timestamps (`[mm:ss] nota`), chronologically, with a hard budget (120 chars/note, 800 for the block — tested).
- **3B budget respected**: the block shares the window with the condensed material, so the reduce target SHRINKS by exactly the space occupied by the block (`condense(reduceBudget:)`).
- Instructions (`notesBehavior`): each note is a topic the summary MUST cover, expanded with facts, never contradicted; bullets originating from a note are prefixed with **"▸ "** — a cheap token instead of inflating the guided-generation schema; the renderer can display Granola-style coauthorship (black/gray) without changing types. The language instruction still closes the prompt (D18).
- Full flow wired: **notes panel in `RecordingView`** (TextField + timestamped list with remove, right column, always visible during recording) → `RecordingController.addContextNote()` (anchors to the current moment) → rolling and final summaries see them → persisted at stop (`contextItem` table, v3 migration) → regeneration in the detail reloads them from the store. **Coauthorship rendering** in `MarkdownText`: bullets prefixed with "▸ " are drawn with an accent mark (Granola style — content originating from your note is distinguishable from the pure AI summary). M10 complete except for field verification (5 real notes → summary that expands them).

## Live Companion (D26) — `LiveCompanion` + `QuestionHeuristic` + `CompanionCard`

3-stage pipeline over closed coalescer rows (a row closes when the next one is created — never partial, never reprocessed):
1. **Pure gate** (tested, es/en): `looksLikeQuestion` (`?`/`¿`, initial interrogatives, minimum 12 chars) **OR `mentions(ownerName)`** — the "te preguntaron" detector: whole-word, case/diacritic-insensitive match of the first name or full name ("John" does NOT trigger inside "Johnny"). The name comes from Ajustes ("Tu nombre") with default `NSFullUserName()`. The common case (nobody asked) costs zero.
2. **FM classifier** (`DetectedQuestion` @Generable: isQuestion/question/kind) sent to the scheduler with `.live` + key `companion-detect` (latest-wins: ticks never stack up). `logistics` → no card (the classic failure mode for this class of features), **unless the caption names you**: then the card is a PING ("te preguntaron", question without an invented answer, orange tint). Two lessons from the 3B caught by the gated test: (a) `directed` is ALWAYS the deterministic name gate, never the model's opinion (requesting it as a field → it stripped "Johnny," from the question and reported false); (b) the logistics filter needs literal few-shot examples ("¿nos acompañas mañana…?" is logistics, NOT context) — with only the abstract rule, it leaked through.
3. **Answer**: `knowledge` → BYOK if the user configured it AND enabled the opt-in (`BYOKSettings.companionClient()`, same instructions as on-device, 400 tokens max, `source` = provider host; if the cloud call fails, it falls back to on-device FM and says so in `source`); without BYOK → direct FM (1–3 sentences, same language, greedy, 220 tokens max, `.interactive`). `context` → `RAGAnswerer` with the last ~13 live rows as passages ("¿qué dijimos del budget?" answers from what was JUST said) — meeting context NEVER goes to BYOK, only the text of the `knowledge` question (D8).

App: per-recording opt-in ("Companion" toggle next to the translation toggle, persists in `companionEnabled`); unlimited, newest-first, scrollable cards (question + answer + provenance — provider host or "on-device" — + copy/dismiss). On close, they are persisted in `companionCard`; the detail reviews them and jumps to the moment asked. Refine rederives them: an incomplete pass retains the previous snapshot, and a complete pass replaces it, including with an empty set to remove stale questions. Answer cleanup removes only verbatim `passage N` citations at the end, never legitimate intermediate text. It never answers for you (D26). Settings: "Modelo externo (BYOK)" section with endpoint/model/key + Companion toggle disabled until everything is configured; removing the key turns off the toggle. Latency budget: bounded by D29 (replaceable `.live` detection + `.interactive` answer with wait ≤ in-flight call).

## Naming

See spec 03 (SpeakerNamer + NamingExcerpt + never-trust-verify filter).

## Known limits

1. **Without Apple Intelligence there is no local summary** — the gap that D25/M12 closes (first-class Ollama → embedded MLX).
2. Recipes: only `general` implemented; the recipe library is M13b.
3. Brute-force RAG: O(n) over embeddings — not measured at 1,000+ meetings (target < 50 ms probably requires sqlite-vec then).
4. ~~No FM priority policy~~ — resolved with `IntelligenceScheduler` (D29).

## Planned (not implemented)

BYOK summaries from the app (the Keychain plumbing already exists; the provider selector in the detail is missing — M12).
