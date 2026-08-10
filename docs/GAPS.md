# GAPS — Gap analysis for world-class quality

What Portavoz lacks compared with the state of the art measured in the two rounds of competitive analysis (PRODUCT.md). Ordered by impact. Each gap states **what exists today**, **what is missing**, and **where it is planned** — if it is not planned, it says so.

Resolved gaps are kept as one-line entries so the ledger stays complete; their full rationale lives in [DECISIONS.md](DECISIONS.md) and the as-built [specs/](specs/README.md). Open and partial gaps state their remaining scope in full. **Pending field verification** below is the list that needs a real meeting rather than code.

## Product gaps (users feel them)

| # | Gap | Today | Missing | Plan |
|---|---|---|---|---|
| 1 | ~~**Zero distribution**~~ | **RESOLVED (10 Jul; hardened 16 Jul 2026)**. See D74. | — | ✅ |
| 2 | ~~**Audio cannot be played**~~ | **RESOLVED (Jul 2026)**. | — | ✅ |
| 3 | ~~**Cannot write during the meeting**~~ | **RESOLVED (Jul 2026)**. See D28, D135. | — | ✅ |
| 4 | ~~**Recording requires the full window**~~ | **RESOLVED (Jul 2026)**. | — | ✅ |
| 5 | ~~**Spanish-only UI**~~ | **RESOLVED (Jul 2026)**. | — | ✅ |
| 6 | ~~**No onboarding**~~ | **RESOLVED (Jul 2026)**. | — | ✅ |
| 7 | ~~**Macs without Apple Intelligence = no local summary**~~ | **RESOLVED (Jul 2026)**. | — | ✅ |
| 8 | ~~**External audio import without UI**~~ | **RESOLVED (Jul 2026)**. | — | ✅ |
| 9 | ~~**No recap email**~~ | **RESOLVED (Jul 25, 2026)**. See D136. | — | ✅ |
| 10 | Native App Intents, App Entities, and protected entity Spotlight ✅ / Quick Look remains absent | **Start field-verified Jul 27; Stop and bounded entities implemented Aug 9; protected entity publication implemented Aug 10, 2026.** The SDK-only shipping source extracts exactly five actions, three entities, and three queries: Start/Stop plus exact open actions for meeting, canonical person, and confirmed commitment (D139/D140/D324–D326). Tahoe+ uses immediate foreground modes while the compatibility property preserves Sequoia. Entity lookups are bounded, literal, database-backed, and route inside the chosen process with explicit recovery. On macOS 15+, one coalescing reconciler publishes all three entity types in a named complete-protection index from one consistent narrow snapshot; meeting entities preserve the released capped full-text body. The 14.4 path publishes meeting documents to that same versioned index, so there is no duplicate meeting surface. Stable, Dev, and UI-test identities remain distinct. Start's user-created Shortcut was field-verified from Shortcuts, Spotlight, and Siri. Stop/entity actions and entity publication are locally covered by metadata, unit/integration boundaries, and bilingual real-app handoff, but physical picker/search result presentation, Siri disambiguation, cold recovery, and registration still need Sequoia and Tahoe evidence. D141 still omits the unsupported duplicate `AppShortcutsProvider` | Collect Stop/entity publication and routing evidence on physical Sequoia/Tahoe Macs. Quick Look genuinely needs an extension target and stays planned | D139–D141, D324–D326; AUTO-3 field / QL M14a/M16 |
| 11 | Cross-device sync has no second-device product yet | **Band 6A–6C2 macOS vertical complete in code (D92–D97):** schema v14 remains the mutation authority; deterministic text-first envelopes replay atomically through encrypted private-zone records and durable exact attempts; D96 owns zero-touch consent/status/actions; and D97 adds one signed-capability-gated private container, process-scoped serialized wakeups, exact Developer ID release admission, and bilingual Settings. Audio, paths, voiceprints, secrets, and embeddings stay local | Production container/profile/account plus two-Mac convergence are still field gates before public enablement; the actual cross-device experience arrives with the 6D in-person iOS recorder shell. Audio remains a later separate opt-in | Band 6D / M14c; field pending |

## Technical gaps (debt and risk)

| # | Gap | Risk | Plan |
|---|---|---|---|
| T1 | ~~WAV crash safety~~ | **RESOLVED (Jul 2026)**: capture migrated to CAF; legacy `.wav` readers keep a fallback. | ✅ |
| T2 | ~~**Taps + VPIO in the same process**~~ | **RESOLVED IN CODE (D125)**. See D125. | ✅ |
| T3 | ~~FM without a priority policy~~ | **RESOLVED (D29)**. See D29. | ✅ |
| T4 | ~~**Unmeasured Mac performance numbers**~~ | **RESOLVED (PERF-001/D137)**: `make perf-ledger` re-measures the unattended journeys against `docs/evidence/perf-thresholds.json` and fails a release on a budget miss. Battery stays an iOS-phase measurement. See D83, D137. | ✅ |
| T5 | Exact semantic retrieval remains O(n), although the reference-host budget is restored | D318 keeps the Accelerate exact authority and normalized Float32 BLOB schema, but maps up to 512 MiB of `main` only for a file-backed macOS store on a volume classified as local and internal. The 9 Aug 2026 authoritative `make perf-ledger` run on the 36 GiB Tahoe reference host measured 63.53 ms wall / 64.54 ms CPU p95 at 100,000 × 512 against the 100 ms budget, with 0.17 MiB incremental process footprint. This closes the current-host regression, not the algorithmic or field-evidence gap: no accepted Sequoia, 8/16 GiB, correction-heavy, or alternative-engine matrix exists, and SQLite's documented mapped-page I/O signal risk remains explicit. | Keep exact control as the correctness authority and retain the local/internal guard. Collect the accepted D215/D219 multi-host receipts across Sequoia and Tahoe plus the required memory profiles; require bilingual quality, cancellation, correction, rebuild, disk, and rollback parity before selecting sqlite-vec, USearch/ANN, or any new product authority. |
| T6 | ~~Audio storage 126 MB/channel/22 min~~ | **RESOLVED (Jul 2026)**. | ✅ |
| T7 | CI does not run model-gated tests | **ACCEPTED with a compensating local gate (Q4, Aug 7 2026).** Hosted CI cannot provide what these tests gate on: Apple Intelligence must be enabled interactively, Apple's contextual-embedding assets download through a flaky user-session service (documented failure even on a real host), and several suites need multi-GB sha256-pinned speech models or the owner's private enrollment audio. The compensating gate is `make test-model-gated`, a required pre-flight step in docs/RELEASING.md: it runs the six model/intelligence-gated classes on the release Mac and fails when a filter matches nothing (rename protection) or when a class skips entirely (the capability under test is absent), printing every individual skip for owner review | Revisit only if GitHub ships Apple-Silicon runners with Apple Intelligence, or a self-hosted runner is accepted |
| T8 | ~~No SwiftLint/format in CI~~ | **RESOLVED (Jul 2026)**. | ✅ |
| T9 | ~~FluidAudio pinned to a revision~~ | **RESOLVED (Jul 2026)**. | ✅ |
| T10 | ~~No unified local diagnostics/provenance surface~~ | **RESOLVED through D146**. See D115, D146. | ✅ |
| T11 | ~~Post-recording workflow is only partially durable~~ | **RESOLVED (D36–D43/D70/D73/D104; field-hardening Jul 16)**. See D36, D43, D70, D73, D104. | ✅ |
| T12 | ~~Persisted UUID read fallbacks create random identities~~ | **RESOLVED (Band 0 slice 0A)**. | ✅ |
| T13 | ~~Some library aggregates include soft-deleted meetings~~ | **RESOLVED (Band 0 slice 0A)**. | ✅ |
| T14 | ~~Summary-language defaults differ by entry path~~ | **RESOLVED (Band 0 slice 0B)**. | ✅ |
| T15 | ~~**Broad app invalidation and orchestration concentration**~~ | **RESOLVED (D44–D61/D85/D98–D114/D222–D228/D239)**. See D44, D61, D85, D98, D114, D222, D228, D239. | ✅ |
| T16 | ~~A generated custom summary structure can disappear from Meeting Detail after broad reload~~ | **RESOLVED (Band 2 slice 2E)**. See D25. | ✅ |
| T17 | ~~A cold recording never attaches live transcription after its model becomes ready~~ | **RESOLVED (D121)**. See D121. | ✅ |
| T18 | ~~Refined punctuation noise and model-authenticated but false summary sources survive into durable output~~ | **RESOLVED (D122/D172)**. See D122, D172. | ✅ |
| T19 | ~~A prolonged remote callback outage can leave an unattended microphone recording, while support export cannot compare channel shape~~ | **RESOLVED (D123)**. See D123. | ✅ |
| T20 | ~~A rejected optional Stop payload can strand already-finalized audio in a recording shell~~ | **RESOLVED in code (D127)**. See D127. | ✅ |
| T21 | ~~Mixed-language live translation can repeatedly ask for a source language, while incoming captions steal history scroll and blur too aggressively~~ | **RESOLVED in code (D128/D129)**. See D128, D129. | ✅ |
| T22 | ~~Automatic Refine can translate mixed speakers, live speaker bleed can duplicate rows, generated summaries can invent owners, and verified Whisper preparation looks like a repeated download~~ | **RESOLVED in code (D130–D132/D142)**. See D130, D132, D142. | ✅ |
| T23 | Live-lane accuracy has a measuring stick but no accepted challenger | `bench-live` scores WER/CER against a reference (`--reference`) and writes JSON evidence (`--output`). The pinned FluidAudio 0.15.5 now contains `StreamingNemotronMultilingualAsrManager` and downloadable Nemotron 3.5 ASR 0.6B CoreML variants for Spanish/English; FluidAudio 0.15.3 explicitly removed its experimental Qwen3 ASR backend, so the former wait-for-Qwen trigger is obsolete. Upstream model-card numbers are research input, not Portavoz evidence. | Add a sha256-pinned, non-serving Nemotron Latin 1120 ms adapter and run the exact Portavoz bilingual live harness against Parakeet v3 on owner-reviewed accents, code-switching, names, digits, latency, thermal load, and resident memory. Keep Parakeet until the local matrix wins within the existing latency/resource budgets and the OpenMDW-1.1 redistribution/attribution review is accepted. |
| T24 | Instant semantic recall has no explicit user-facing asset preparation control | D145/D197/D199 reuse Apple's installed Latin contextual embedding assets, keep Ask and Library corpus-read-only, require the active compatibility profile, and expose one internal `ready`/`partial`/`building`/`unsupported`/`failed` contract without downloading from a query. Exact bilingual/accent-folded FTS remains available everywhere, but a clean Mac that has never prepared embeddings receives no semantic augmentation and the internal state is not yet presented in Settings | Measure the OS asset footprint and add an explicit Settings prepare/status action before presenting semantic recall as universally ready; retain exact search through every state |
| T25 | The resource-interference matrix has collectors but no accepted hardware baseline | D148/D149 define content-free workload intervals and the fail-closed 27-cell contract. D150/D152 provide isolated native Release collectors for all nine scenarios: idle, recording, Stop, Refine, Summary, Ask, standalone semantic indexing, recording plus indexing, and recording plus post-capture batch transcription. Concurrent collectors prepare assets and runtimes outside measurement, start exact product work only after real recording Start, freeze before Stop, and fail closed unless workload validation and Stop both succeed. D167 adds a threshold-free safety invariant for competing Whisper/MLX residency; D177–D181 make semantic backfill, existing-library sync, and whole-library backup yield with durable progress. D191 separately closes the deterministic synthetic three-hour continuity cell: a clean Release probe conserves 172,800,000 frames per channel through the production session/publication path, requires healthy CAFs and zero drift, and fences duration-dependent heap growth. It does not alter the 27-cell matrix or claim accelerated dirty-page pressure as real recording RAM. Other host-pressure, power, storage, concurrency, and scheduler outputs remain intentionally inactive. Model-heavy paths use verified Portavoz or already-installed Apple assets plus fixed public synthetic fixtures, but no host receipt is accepted | Capture three stable runs per cell on 8 GB, 16 GB, and reference Macs; add the real-time 90-minute dual-channel, Stop-under-pressure, resident-model, speaker/mic, and AirPods evidence; review and freeze the baseline before deriving numeric tiers, budgets, or TTLs |
| T26 | Whole-library Markdown backup relaunch recovery lacks real process-kill field evidence | **IMPLEMENTED in code through D180–D189:** capture-safe staging, lease-owned immutable sources, bounded destination identity, durable cursor-bound publication and typed failure outcomes, exact no-follow reconciliation, and strict stage adoption now converge in one fail-closed launch coordinator. It catalogs journals before cleanup, preserves every matching stage, refuses ambiguous/conflicting evidence, reconstructs filename and typed-result state, resumes strictly after the durable cursor, and abandons retryable adopted leases without deleting their source. Deterministic tests cover active continuation, completed-result reconstruction, ambiguity, conflict, capture suspension, malformed catalog protection, destination-setup failure, and terminal recovered-source cleanup without an implicit fresh export | Kill the app in the supported reservation-before-move, move-before-completion, checkpoint, failure-record, suspension, and completed-terminal windows against a scratch real destination; relaunch after each and retain content-free evidence that files are neither overwritten nor duplicated before closing the field claim |
| T27 | Ask benchmark authority exists, but no accepted comparable multi-host baseline or complete product-path quality run has been collected | D192 emits one content-free trace across current corpus readiness, expansion, lexical retrieval, query embedding, semantic scan, fusion, citation materialization, first evidence, first observable answer token, and completion. D193 pairs every passing Ask resource run with a strict native sidecar and aggregates per-stage/milestone wall and CPU p50/p95, corpus generation/checksum/readiness, and validated deterministic citation evidence across profiles. D194 adds the canonical 240-query public multilingual quality pack and fail-closed adapter-neutral evaluator. D195 adds a CLI-only adapter over the real product retrieval path with canonical transcript-revision provenance, but deliberately leaves answer evidence `notEvaluated`. D196 makes product Ask corpus-read-only, versions resource evidence to a preindexed schema-2 contract, and versions the production observation adapter so before/after evidence cannot mix silently. D197 extends that read-only boundary to Library, centralizes typed semantic readiness, and leaves the signal-driven supervisor as the sole product corpus writer. D198 fences every semantic batch by meeting, transcript revision, segment identity, and exact source text so concurrent correction or deletion cannot publish stale vectors. D199 fingerprints the concrete model, dimension, pooling pipeline, and vector schema beside every vector; reads require that active profile, while schema v17 and background maintenance reset incompatible derived rows to the `NULL` rebuild cursor without touching transcript or FTS data. D200 adds schema-v18 content-free source identity plus independent kind-wide lease, heartbeat, bounded retry, and one-shot retry/lease-expiry wakes while leaving `NULL` vectors as the sole progress cursor. Deterministic migration, duplicate-admission, partial-publication, pre-expiry relaunch, expired-owner recovery, bounded-failure, capture-denial, and exact-FTS tests pass without changing meeting lifecycle; the meeting-processing `.index` kind remains dormant. D201 moves deterministic bilingual exact retrieval ahead of optional generation, publishes lexical evidence while semantic augmentation continues, fences the fused set before answering, and makes Foundation Models expansion an evidence-empty fallback. Focused concurrency, telemetry, presentation, and cancellation tests pass, and scoped XCUITest coverage asserts the progressive UI phases. D202 defines a pure single-actor turn chunk candidate with ordered source provenance, per-source spoken language, stable membership identity, and correction-local delta invalidation, while deliberately leaving schema v18 and production segment retrieval unchanged. D203 adds disposable segment and speaker-turn quality adapters plus observation schema 2, which ranks by unit while retaining every ordered canonical source; repeated, unknown, unordered, cross-meeting, stale, and hard-negative member evidence now fails closed without changing product storage or retrieval. D204 keeps public-synthetic-v1 reproducible, adds a v2 corpus with two real same-actor turns per four-segment meeting, and emits one fail-closed paired comparison receipt bound to the same fixture, build, commit, schema-2 observations, exact adapter roles, canonical citations, and aggregate plus per-relationship retrieval parity. D205 adds the clean-source Release orchestrator, makes OS embedding downloads explicit and disabled in accepted pairs, and publishes all five private artifacts only after the complete run. D206 injects one read-only semantic-index query port into Ask and Library while retaining the shipped Accelerate exact adapter as the only product authority; no shadow candidate or engine dependency is composed yet. D207 adds a benchmark-only non-serving shadow decorator: exact control returns without awaiting the candidate, candidate failure cannot affect product results, and the closed comparison event exposes only aggregate agreement, timing, dimension, limit, and outcome fields—never queries, vectors, citation identifiers, transcript text, model names, paths, or raw errors. D208 routes optional benchmark execution through the existing capture-aware maintenance gate, admits one candidate with no backlog, emits payload-free policy/busy/capture skips, cancels active cooperative work when capture begins, and waits for cancellation before resuming. D209 binds the closed evidence identity to the candidate implementation itself, so a call site cannot mislabel which engine family produced an aggregate event. D210 lets derived engines return only ordered segment/revision identities and resolves them through current authoritative StorageKit citations, dropping stale, missing, duplicate, invalid, or deleted evidence before comparison. D211 selects stable sqlite-vec v0.1.9 exact full-scan as the first research engine and pins its official amalgamation archive for static-only vendoring; ANN alphas, dynamic loading, and USearch remain deferred. D212 vendors the immutable tagged C blob plus a deterministically rendered tagged header, compiles it only through the test-only CSQLiteVecResearch target, and proves one in-memory exact vec0 query. D213 adds a separate test-only SQLiteVecResearchKit whose disposable in-memory cosine ranker emits identity-only results through D210 and is characterized behind D207 aggregate comparison with deterministic corpus-order ties and cancellation signalling. D214 adds a test-only schema-1 exact-path harness over one synthetic 512-dimensional corpus, runs the real scratch-store Accelerate control and disposable sqlite-vec candidate at canonical 1k/10k/50k/100k scales, replaces the candidate's capped KNN query with an exact scalar full scan ordered by distance/source row, separates unlike build lifecycles from directly comparable alternating-order query timing, and emits only stdout host/configuration, byte/count, timing, and agreement aggregates. D215 adds a fail-closed one-host acceptance boundary: one clean unchanged commit must provide three exact-shaped observations per canonical scale from one supported Apple-Silicon Sequoia/Tahoe memory profile; duplicate keys, payload fields, copied observations, mixed hosts, invalid counts/configuration, and non-finite values are malformed, while missing scales, p95/p50 instability above 1.25, or top-hit/top-k-set divergence produce a complete blocked aggregate-only stdout receipt. D216 evolves that receipt to externally validated schema 2 and adds an ephemeral cross-host scorecard requiring one 8 GB, 16 GB, and reference receipt, coverage of both supported OS majors, one source commit/toolchain, and passing host evidence throughout; missing coverage, blocked evidence, or identity mismatch remains a blocked scorecard, while malformed or repeated-profile input produces none. D217 adds the final private retention boundary: one canonical passing scorecard and its three revalidated receipts can be published only after explicit scorecard-file digest and source-commit acknowledgement from the matching clean checkout; publication is owner-only, atomic, non-overwriting, repository-local only under an ignored path, and permanently marked research-only with no engine decision. D218 adds a test-only atomic sqlite-vec mutation primitive and a content-free Release harness for full rebuild plus add/update/delete batches of 1, 10, and 100 at the canonical exact scales; post-operation top-hit and top-k source identity must match the real scratch-store Accelerate control, while the unlike rebuild and mutation lifecycles stay explicitly separate. D219 adds a threshold-free one-host receipt over three observations per canonical scale: complete shape and top-hit/top-k-set parity become `review-required`, while missing coverage or agreement drift is blocked; timing distributions remain human-review inputs rather than an automatic performance verdict. D220 adds the detached, exactly recomputable cross-host review: one revalidated receipt per 8 GB, 16 GB, and reference profile must cover Sequoia/Tahoe and share source/toolchain identity; complete evidence remains `review-required`, blocked/missing/divergent evidence stays blocked, and no cross-engine ratio or threshold is derived. D221 adds the private retention gate: canonical D220 evidence requires its exact digest, sole source commit, all three receipts, and the fixed human acknowledgement; the retained envelope stays research-only with engine and performance decisions `not-evaluated`. No real mutation cross-host review or baseline has been retained yet. Product Ask and Library still compose exact control directly, and no product schema, writer, app composition, product-owned baseline, engine verdict, or user-visible candidate authority exists yet. Unaccepted development runs over all 240 public queries produced identical v1/v2 retrieval aggregates—Hit@1 0.5574, Recall@10 0.8638, MRR 0.6276, nDCG@10 0.6817, exact rank-one 0.5932, 16 hard-negative hits, and zero invalid/stale citations—so the preindexed path introduced no observed aggregate retrieval drift while the existing quality and answer gates remain blocked. A clean D204 preflight on the current host reached Apple's Natural Language runtime but both sandboxed and unrestricted attempts failed before observation with asset-download timeout plus host service error 141; no partial evidence was retained and this is a model/host readiness block, not candidate quality evidence. The current answer provider is non-streaming, so its token milestone occurs only when the complete string returns. D315 adds the separately versioned deterministic answer judge (content-free observations; grounding, policy, and hard-negative citation metrics; prose quality explicitly notEvaluated) — the judge exists, but no accepted answer observations have been collected yet | Install/verify Apple's Latin contextual embedding assets outside measurement, then collect paired segment/speaker-turn scorecards and the D204 receipt from one clean committed Release build before any production selection. Collect one passing schema-2 D215 receipt in fresh Release processes for every required memory profile, covering both supported OS majors, then run the D216 comparator, review its passing canonical scorecard, and use the D217 digest/source gate before retaining the private research baseline; do not treat synthetic scorecards, one current-host smoke, or one receipt as accepted evidence. Separately collect one D219 mutation receipt per required profile with both OS majors represented, run D220, conduct explicit human timing review, and use the D221 digest/source/acknowledgement gate for private retention; `review-required` remains neither a performance pass nor an engine verdict. Require segment-parity-or-better multilingual quality, latency, memory, disk, and correction cost before any product schema or app wiring. Capture real process-kill/relaunch field evidence for semantic maintenance without claiming the deterministic recovery proof as host evidence. Add a separately versioned answer observation/judge and an untracked private anonymized pack; run the clean schema-2 Release matrix on supported memory profiles; compare historical v1/v2 retrieval without claiming cross-schema latency parity; accept only stable comparable evidence; reconcile historical semantic measurements; require both quality packs to pass before further retrieval/index changes |
| T28 | Transcript corrections are not yet searchable or exposed through MCP as composed material | **PARTIAL (D225/D229–D235)**: Meeting Detail composes current-revision text, speaker, split, explicit adjacent merge, and suppress corrections over immutable accepted evidence; derived artifacts are fenced by effective correction lineage; Markdown, PDF, SRT, WebVTT, CLI, and Gist share one composed projection with original timing; private sync converges compatible histories and fences conflicts. **PARTIAL (D313)**: an active `replaceText` correction now serves its corrected text through the per-segment `segmentCorrectedText` FTS projection (v33, transactionally refreshed and backfilled on upgrade), a speaker-only correction no longer hides its line from search, and MCP appends the frozen-prefix `portavoz-reading/2` tools (`get_transcript_v2` composed and fail-closed, `get_summary_v2`/`get_action_items_v2` with correction provenance). **Still open:** split/merge/suppress content stays out of search (no 1:1 segment identity), semantic search serves no text-replaced segment (stored embeddings describe the original text), Spotlight remains correction-unaware, and Apuntador is not automatically regenerated | Decide whether split/merge/suppress content earns a search identity story or stays excluded by design; define corrected-text re-embedding for the semantic lane; extend Spotlight only with the same fail-closed revision fences; add explicit Apuntador regeneration policy only after source/evidence semantics are characterized |
| T29 | Commitment confirmation and global Radar exist, but candidate admission and cross-surface continuity remain open | **PARTIAL (D236–D269)**: schemas v20–v24 store only explicitly confirmed continuity with exact source evidence and append-only lifecycle; Meeting Detail presents an evidence-first bilingual review inbox; the Library-global Radar filters confirmed work, exposes bounded source/history, and measured p95 4.25/25.27 ms at 1k/10k against a 100 ms budget; content-free reminders schedule, snooze, and clear without moving commitment truth; a private advisory 90-day scorecard reports field quality. **Still open:** the strict 48-case multilingual benchmark selected **no** candidate engine; one dirty-head smoke produced six explanation-supported false suggestions, 0.777778 link precision, and 0.666667 abstention accuracy, which is not an accepted baseline; no accepted quality floor, link-confirmation UI, or chronology presentation invokes the link path; the continuity envelope and review feedback remain outside bundles, CloudKit, CLI, and MCP | Collect an untracked anonymized real-meeting pack, run the clean-head local-profile matrix, explicitly review a similarity/abstention candidate, and invoke the D255 digest/source/candidate gate before exposing suggestions. Then add explicit link confirmation UI and honest first-promised/last-discussed chronology. Define library-global sync/export contracts separately. Model-inferred owner/deadline values must remain suggestions until the user confirms them |

| T30 | Meeting Memory Graph has three source-backed fact adapters, all canonically verified, but user-facing Ask/scale serving remains open | **PARTIAL (D270–D286)**: a deterministic 36-case public-synthetic corpus defines six longitudinal jobs; schemas v25–v30 add topic, decision, commitment-change, question, and blocker authority plus a disposable relational graph; three adapters (active blockers, authoritative first discussion, current person commitments) serve and are canonically verified through public product boundaries; Ask carries a separately typed fact seam with exact alias/date/status filters, typed synthesis, and deterministic post-RRF selection that reserves transcript rank. The graph only checks or selects topology — it never becomes source evidence. **Still open:** the other three D270 job adapters, relational latency/throughput budgets, private owner-reviewed evidence, sync/export, CLI, MCP, UI, and product telemetry. Released consumers remain transcript-only | Finish the remaining exact query adapters and measure relational query/projection budgets with untracked owner-reviewed evidence before explicit released adoption |
| T31 | ~~Strict lint is configured but the current local branch is red~~ | **RESOLVED (Aug 9, 2026):** cohesive owner splits removed all 20 audited first-party violations without blanket suppressions; strict SwiftLint is clean across 636 production Swift files. | ✅ |
| T32 | ~~Database-open failure still terminates the app at launch~~ | **RESOLVED in code (D319):** `AppServices` now throws and opens the authority before constructing any other process owner. A root launch state keeps normal UI and background work absent on failure, offers retry, exports content-free mode-`0600` diagnostics, and creates a `quick_check`-verified read-only SQLite recovery copy through hidden mode-`0700` staging without overwriting, mutating, migrating, deleting, or silently recreating the source. Deterministic tests cover corrupt/missing sources, privacy, permissions, non-overwrite, retry, and source parity; bilingual XCUITest exercises the real disposable recovery journey. Automatic repair or restore-over-authority remains deliberately excluded. | ✅ |

- **Returning to the canonical graph profile after an alternate profile stalls
  until the next authority write.** Derived-maintenance operations are
  idempotent by `(kind, targetFingerprint, sourceGeneration)`; once the
  canonical operation is `done`, re-admitting it at the same source generation
  reloads the done row and `claim` finds nothing pending, while
  `meetingMemoryGraphRequiresMaintenance()` keeps reporting true. Only
  reachable by running an older binary after a newer one (profile fingerprints
  are per-build constants), and any authority write clears it. Found by the
  GRAPH-6 harness, which proves rebuild determinism through the alternate
  profile without the return trip.
- **RESOLVED (D314, Aug 7 2026) — graph rebuild-from-zero was superlinear.**
  The per-scope rebuild used to load every live topic row to resolve family
  roots (`liveTopicRecords`) once per topic/decision scope — 17.6 minutes /
  48.9 edges/s at 10k meetings vs 414 at 1k. Family resolution now runs as
  two recursive CTEs (`topicFamilyRootID`, `topicFamilyMemberIDs`) inside the
  scope's own transaction: 1 892.9 edges/s and 27.2 s at 10k (38.7×),
  near-linear against 2 766 edges/s at 1k, with query lanes still inside the
  250 ms budget. Evidence:
  docs/evidence/meeting-memory-graph-rebuild-20260807.json.

## Positioning gaps (against the competitive map)

- **OSS growth after publication**: distribution is solved; discoverability,
  adoption, and trust in a native Swift + MIT product remain ongoing work.
- **Watch companion**: Teams "Facilitator" arrives ~Aug-Sep 2026. Being first in local meeting notes matters (M13).
- **Semantic end-of-turn model (APUN-005 tail)**: the deterministic D138
  endpointer covers turn ends visible in the transcript (punctuation,
  interrogatives, owner mentions). pipecat smart-turn v3 (8.7 MB int8, BSD-2,
  ~12 ms, 23 languages, sha256-pinnable) would add intonation-only turn ends
  but ships ONNX-only; adoption is deliberately deferred until an official
  CoreML artifact exists or an onnxruntime dependency is justified on its own
  merits. Re-check the pipecat-ai/smart-turn-v3 repo when revisiting.
- **Public benchmarks**: reproducible latency, drift, DER, summary, refine,
  startup, FTS, semantic, long-audio waveform, large-library Spotlight, and
  memory numbers are published. The next credibility step is retaining these
  baselines and adding an ethical quality corpus for evidence-linked claims.
- **The archive story**: Granola charges for access to your >30-day-old notes. Our inverse pitch — "your history is never held hostage" — is not written in any README yet.

## Pending field verification (requires the user, not code debt)

Implemented and tested features whose final criterion can be closed only with a real meeting:

Use the content-free procedure and exact admission checks in
[`FIELD-VALIDATION.md`](FIELD-VALIDATION.md) for callback recovery, AirPods
process-tap capture, cold live captions, live translation, post-capture Refine,
and Apuntador/name continuity. The collector rejects content-bearing additions
and never reads `/Applications/Portavoz.app`.

D147 now turns the release subset into a machine-readable, fail-closed
scorecard: deterministic, signed-build, real-hardware, and user-field proofs
must all describe the exact release identity. This automation does not close
the rows below. Missing real Sequoia/Tahoe built-in and AirPods packages,
callback recovery, long-call, model-cold, or mixed-language evidence remains a
visible release blocker rather than being inferred from deterministic tests.

- **Portavoz 0.7.0 Homebrew install on clean Sequoia** (D74): `brew install --cask johnny4young/tap/portavoz` must install and launch the 0.7.0 public artifact on a Mac with no prior Portavoz receipt. The local v0.6.0 cask reproduction proved the outer DMG passed while the extracted app lacked a stapled ticket; the fixed release gate now rejects that state. Preserve `brew install --verbose --debug` output if any separate failure remains.
- **Production private sync** (D97/D116): configure `iCloud.app.portavoz.mac`, deploy the production CloudKit schema, and issue an unexpired Developer ID profile with the exact production CloudKit and macOS push capabilities. On two clean Macs using one iCloud account, prove explicit future-change opt-in, separately confirmed existing-library seed, bidirectional edits, encrypted tombstone propagation, restart/retry, silent-push wake, sign-out/in, a real account switch requiring fresh consent, pause, and remove-this-Mac without deleting local meetings or remote records. Record the actual destination's complete-protection and backup-exclusion capabilities and verify that unsupported metadata omits only the unavailable key while `0600`, durable verification, and atomic publication remain intact. Reproduce Homebrew extraction and renew the profile before expiry. Do not market sync as field-proven until this matrix passes.
- **Apuntador < 5 s** (D26/D72): on macOS 26 with Apple Intelligence available, a real meeting knowledge question must produce a card in < 5 s; also validate the "you were asked" detector (mention of your name → ping) and, if you configured BYOK, the external answer path with disclosure. Sequoia is intentionally excluded because the current question classifier is Foundation-Models-only; Settings explains this and exposes no dead enable toggle.
- **Call-safe raw capture (D125)**: on both Sequoia and Tahoe, begin a call
  without Portavoz, confirm participant playback and the user's uplink, then
  start Portavoz without changing devices. Playback and uplink must sound
  identical while the Portavoz mic and system timelines both advance. Repeat
  through built-in speaker/mic and AirPods. Export content-free diagnostics
  before and after Refine.
- **Mouse push-to-talk delivery**: with Accessibility granted, configure
  vendor-facing Button 3 (middle click) and one additional mouse button in
  separate runs. In a third-party editor, prove press starts, release inserts
  once, the target app never receives the configured click, unconfigured
  buttons still pass through, timeout re-arming works, and rebinding during an
  active mouse-owned session cancels safely. Repeat once after revoking and
  re-granting Accessibility through System Settings. XCUITest covers Settings
  and pure ownership rules but cannot drive a session event tap into another
  process.
- **System callback recovery (D120, field 21 Jul 2026)**: one real recording's system channel stopped advancing after 33:20 while microphone capture continued for more than two hours. In another real call, reproduce a complete callback stall and prove that Portavoz shows the remote-audio warning within about eight seconds, keeps microphone capture active, rebuilds the same process tap, resumes the same system timeline, and clears the warning after frames return. Deterministic source/session coverage is complete, and scoped XCUITest proves the prolonged-outage Stop exits capture into the explicit typed no-audio Retry when the fixture publishes no file; real Core Audio recovery and durable-file publication are not yet claimed.
- **Stop durability after rejected live payload (D127, field 22 Jul 2026)**: in the next real call, Stop must open the saved meeting without `recording.stop.snapshot.persistence.failed`. Export redacted diagnostics before Refine and prove both finalized channels, a non-recording lifecycle, and either the preserved live transcript or an explicit durable transcription job. The exhaustive transaction and launch-recovery regressions are complete; field closure is not yet claimed.
- **Mixed-language field integrity (D130–D132/D142, field 24–27 Jul 2026)**: in the next Spanish/English call, verify that an overlapping exact two-word or rolling-edge speaker copy produces one direct-system live row rather than alternating `Me`/`Them` copies, sequential acknowledgements remain separate, stable same-voice rows read as one paragraph, and unresolved generic `Them` rows remain separate. Stop must open a non-recording meeting, automatic Refine must preserve each turn's spoken language, and generated action owners must be cast labels/confirmed names or unassigned. Reinstall `Portavoz Dev.app` before one repeat and confirm Settings still reports the verified Whisper variant as downloaded; a checksum-only pass must say it is checking local files, and a percentage labeled download must correspond to missing/corrupt artifacts.
- **July 30 live-quality evidence (D172/D173/T23)**: an 8:55 real call reached
  `ready` with successful transcription, diarization, and summary jobs, but its
  redacted report showed a clipped 0 dBFS system channel, a weak −41.63 dBFS
  microphone RMS, only 2 microphone rows among 94 transcript rows, and three
  successful Apuntador generations within 29 seconds. Deterministic card
  admission now makes one source-turn lineage replace its earlier card and
  summary admission removes attribution-shaped decision/task copies. The
  persisted writer pass now exposes sustained system-channel ceiling evidence
  through a dismissible live warning without changing the call or recording.
  Live paragraph and talk-balance derivations now own fixed recent-work bounds
  while the complete admitted transcript remains available to Stop/recovery.
  Field validation remains open for live WER/CER, card usefulness,
  business-quality decisions/tasks, whether the warning appears on the next
  genuinely clipped call, and the upstream source of that clipping.
- **Clear playback quality (D144)**: after a built-in-speaker call with both
  system and microphone channels, compare `Clear playback` on and off over
  remote-only speech, local-only speech, and one overlapping turn. The clear
  mix must remove the delayed remote copy without clipping the user's turn.
  Repeat with a mic-only/in-person recording and confirm that no clear toggle
  or channel attenuation is applied. This validates listening quality only;
  the original files must remain byte-for-byte unchanged.
- **AirPods system-channel continuity** (C, field 13 Jul 2026, OPEN): two
  AirPods recordings produced mic-only evidence, including one digitally silent
  system channel. Silent-channel hallucinations are already rejected and
  automatic/app capture can tap recognized meeting processes before device
  routing. D125 additionally removes VPIO from meeting capture, eliminating one
  graph conflict. Repeat the D125 A/B with AirPods: if the process tap remains
  silent, preserve microphone mobility and report the hardware limitation
  rather than forcing the built-in mic.
- **Device change (D163)**: a July 30 real call confirmed that switching from
  built-in audio to AirPods no longer closed the app. The remaining field
  closure repeats built-in speaker/mic → AirPods → built-in and proves both
  microphone and system files continue on their original timelines with only
  bounded silence at each handoff. The repeated Jul 28–29
  `AVAudioEngineImpl::InstallTapOnNode` SIGABRT signature is covered by a fresh
  microphone graph plus generation-fenced route work, and process-tap
  Start/rebuild/Stop are serialized in code; reverse-route and dual-channel
  continuity remain the field gate.
- **Clear playback of dense turn-taking (D287, field 1–6 Aug 2026)**: six local
  crash reports over six days shared one signature — `MeetingAudioComposition`
  `.cleanMix` raising `-[AVScheduledAudioParameters _setRamp:]` and aborting
  the process the moment a meeting's playback was prepared. Replaying the real
  local library through the policy reproduced it exactly: 9 of 39 meetings
  carried 21 overlapping duck ramps, every one of them unopenable, and Refine
  could introduce the condition by rewriting turn timings. The pure schedule
  now reports zero violations across that same library and the boundary fails
  closed. The remaining field closure opens each previously affected meeting,
  plays across a merged rapid exchange, and confirms clear playback still
  quietens the microphone between distant turns; the deterministic tests prove
  the schedule's ordering invariant, not AVFoundation's acceptance of it.
- **Ask retrieval budget on a controlled host (D290/D291)**: every semantic
  scan measurement taken on 6 Aug 2026 — including the pre-change build at
  129.14 ms p95 — sits far above the 100 ms budget and the 92.85 ms committed
  26 Jul baseline for the identical 100k-segment, 512-dimension configuration.
  The runs were taken on a developer workstation with other applications
  running, and they disagree with themselves (one build measured three query
  variants faster than one, which is impossible), so the host's noise exceeds
  the effect being measured. Re-run `portavoz-cli bench-semantic --segments
  100000 --runs 20 --variants 1` and `--variants 3` on the named stable Mac
  with background services controlled, three times each, before treating any
  Ask retrieval number as a budget verdict. Until then SEARCH-3 is not closed
  on budget.
- **Formal M3 DER**: correct the Speaker column of the draft RTTM in `~/Desktop/portavoz-verificacion/reunion-2026-07-07.md` → measure with `portavoz-cli der --file system.wav --reference <rttm corregido>`.
- **Translation pivot** (D25): regenerating a summary in another language must translate the existing snapshot (fast) instead of summarizing again; verify that it preserves structure and action items.
- **Cold live captions, translated captions, and reader ownership (D121/D128/D129/D320)**: release the idle speech models or use a clean install, start recording before Parakeet is ready, and prove captions begin automatically during the same call after verified preparation without an audio gap or memory growth. Separately on clean Tahoe onboarding, observe that First Listen stays in preparation without opening the microphone while Apple's speech asset is cold, begins capture only after readiness, and clears the system microphone indicator when Continue, Skip, or dismissal leaves the step; repeat the teardown on Sequoia, where captions are explicitly unavailable, and confirm ten start/leave cycles do not grow retained memory. Then use the "Translate → …" picker across Spanish and English speakers; prove same-language and uncertain short rows remain unchanged, a long still-growing opposite-language row gains a labeled translation before the next speaker, later growth refreshes that row, no source-language modal appears, target switching cannot restore stale output, pair download is deliberate, and unsupported/failure states are visible rather than silent. Scroll into caption history while new rows arrive: the position and sharp text must remain stable until the explicit Jump to live action.
- **Hybrid Library search (D143/D145)**: on Sequoia and Tahoe, confirm an
  unaccented query finds accented source text, common English/Spanish terms
  find the same meeting, and an exact hit remains first. After the Apple Latin
  embedding assets have been prepared through an explicit intelligence flow,
  search one paraphrase with no shared words and verify the appended semantic
  hit seeks to the correct timestamp. Repeat during recording and confirm only
  exact search runs and recording responsiveness does not regress.
- **Names from calendar**: event with attendees around a recording → "Sugerir nombres ✦" (requests calendar TCC).
- **Remembered-voice calibration (D105)**: build an explicit-consent private
  fixture with repeated clean clips for several remembered people plus
  same-gender and noisy-call negatives. Record nearest and runner-up cosine
  distances without persisting audio, then choose a threshold and minimum
  separation margin from false-accept/false-reject evidence. Until that matrix
  exists, `0.54` remains provisional and every result must remain an explicit
  suggestion rather than an inferred identity.
- **Confirmed person continuity (D86)**: name and explicitly remember a non-user speaker in one meeting, then confirm that the same normalized name in another meeting offers the existing person rather than linking automatically. Also verify that two distinct people with the same name remain selectable and that an accepted Refine asks for a fresh link because its speaker IDs are new observations.
- **Real-model overview evidence quality (D87)**: generate summaries with Apple
  Foundation Models, MLX, and the configured Ollama model over a copied real
  meeting; verify that every visible source directly supports the overview,
  unsupported overviews show no source rather than a weak one, and Refine turns
  the prior links stale before the regenerated summary installs fresh links.
- **Real-model Apuntador evidence quality (D91)**: on a copied real meeting,
  verify that every detected question keeps its exact spoken turn, every
  context answer exposes only the transcript passages named by exact local-RAG
  citations, and those passages directly support the answer. Knowledge answers
  and directed pings must expose no invented answer source. After Refine, old
  card evidence must resolve stale until the refreshed Apuntador snapshot
  installs sources for the accepted transcript revision.
- **Resident pre-meeting brief shell (D322)**: deterministic bilingual
  XCUITest mounts the exact production menu-bar content and model in a
  disposable app window, but it cannot claim the SystemUIServer-owned status
  item or real EventKit/TCC behavior. On both Sequoia and Tahoe, with Calendar
  full access already granted, open the actual menu-bar panel and prove it does
  not prompt; review/confirm one exact event brief; change or remove that event
  before a second confirmation and require a stale refusal; dismiss a third
  offer and prove it stays absent after relaunch; then inspect the content-free
  receipt in Skills Settings. Repeat once after a full calendar sync because
  EventKit identifiers may disappear or change. No title/time fallback is
  acceptable.
- **Reminder Draft system boundary (D323)**: deterministic bilingual XCUITest
  drives the production Radar, model, permission action, exact target preview,
  ExecuteSkill path, and durable receipts through a disposable in-memory
  platform; it deliberately does not touch host TCC or Reminders. On both
  Sequoia and Tahoe, deny and grant Reminders full access from a clean TCC
  state, verify the prompt uses the localized purpose string, confirm that the
  displayed default list receives exactly one reminder with the approved title
  and due date, then rename/remove that list and revoke access before separate
  confirmations to require visible fail-closed recovery with no fallback or
  duplicate. Inject or observe a save error and verify the UI reports an
  unverified outcome, then check the target list before any retry. Repeat after
  relaunch and after changing the system default list.
- **Real export**: `export --gist` / "Publicar como Gist" with a token; `issues --github/--linear` with tokens against a test repo.
- **Summary fingerprint drift (D288)**: two of 47 real local meetings had their
  only automatic summary job cancelled as `processing.input.superseded` seconds
  after capture, with no transcript correction in their history. Recomputing
  each enqueued fingerprint from the frozen durable rows failed across every
  combination of segment order, output language, glossary, provider, and
  transcript revision, while the same reconstruction reproduced a succeeded
  meeting's fingerprint exactly. **The drifting input is still unidentified.**
  D288 makes the repair independent of that cause — the worker replaces the
  attempt with one bound to what it durably read, and the app says so when the
  bounded replacement is spent — and removes one proven contributor by giving
  the projection a total order. Both affected meetings are bilingual with
  `meeting.language` NULL; the succeeded control is homogeneous `en`. Field
  work: capture a fresh occurrence with the replacement in place and record
  whether the replacement succeeds, which would localize the drift to the
  producing stage's prediction rather than to anything the worker reads.

## What are NOT gaps (deliberate decisions — do not "fix")

- No proprietary backend or accounts (D12: zero servers until demand is proven).
- No call capture on iOS (D11: impossible; in-person recorder + companion).
- No bot that joins the call (the entire native bot-free market avoids it; our capture is local).
- Diarization threshold at 0.45 (raising it breaks AMI; fragmentation is resolved post-clustering).
- XCTest instead of Swift Testing (D13, because of the build environment without full Xcode).
- Meeting Detail recomputing the transcript projection on playback ticks —
  checked, and it does not. `loadedBody` hoists the transcript, accepted, and
  structure projections into locals, and it never reads a player property, so
  Observation does not invalidate it as playback advances. The three other
  `transcriptContent` call sites are event handlers (evidence focus, pending
  seek, seek-and-play), each once per user action.
- Duplicate keys aborting `Dictionary(uniqueKeysWithValues:)` — all 66 sites
  were audited against their key sources; every one is unique by construction
  (a primary key, a `Set`, or `enumerated()`). The rule to keep is that a new
  site must state which of those three guarantees it relies on.
