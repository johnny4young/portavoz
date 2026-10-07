# Dictation quality contract — candidate evaluation protocol

**Status: proposal, not implemented qualification or an accepted release gate.**
Research date: 2026-10-06. The numerical targets below are candidate engineering
and product goals, not industry standards, vendor claims, measured Portavoz
results, or permission to run experiments. Maintainers must review and freeze
this protocol before collecting a scored holdout. This document changes no
runtime, default, model, permission, dependency or existing test budget.

## 1. A claim that can be tested

The initial target population is adults dictating on Apple Silicon Macs in
Colombian Spanish, English technical prose, and natural switching between those
languages. Primary work: short messages, documents, issue descriptions and
technical identifiers in explicitly supported editors. The first claim to earn
is **reliable, faithful local dictation for this population and editor matrix**.
Medical/legal transcription, all languages, all accents, Intel Macs, agent
execution and universal application support are outside that initial claim.

“Best Mac dictation” has no defensible universal scalar. Publish a scorecard for
accuracy, meaning preservation, delivery, latency, resource cost and privacy.
A narrowly scoped comparative claim requires all safety gates, noninferiority on
predeclared important dimensions and a statistically supported useful advantage
on at least one primary dimension. State tested products, versions, population,
hardware, dates, modes and uncertainty alongside the claim. Otherwise say
“meets the candidate target” or “inconclusive,” not “best.” A good WER cannot
compensate for changing a negation or pasting into the wrong application.

## 2. Public baseline and evidence debt

Repository observation: main
[`c881df8f5e2b99929d3402c3b6eaf41422d65c2d`](https://github.com/johnny4young/portavoz/commit/c881df8f5e2b99929d3402c3b6eaf41422d65c2d).
Use [GAPS](GAPS.md), [quality spec](specs/08-quality.md),
[macOS spec](specs/06-app-macos.md), [transcription spec](specs/02-transcription.md)
and the [existing public corpus contract](../Fixtures/DictationValidation/README.md).
These are evidence about their identified trees, not this proposal's experiments.

| Evidence available | What it establishes | What remains missing |
|---|---|---|
| 60 synthetic text families, 37 related phrase groups, eight profiles, 480 variants | Public text/PCM admission and reproducible synthetic regression structure | Independent natural speakers, Colombian accents, natural switching, real devices |
| September 21 controller observation: 960 attempts; 932 pipeline-complete, 28 short-capture cancellations | All attempts retained; an admitted observation | A quality acceptance or native delivery result |
| Arithmetic mean attempt WER: EN 0.384410/320 attempts; ES 0.395312/320; mixed 0.421957/160 | Synthetic speech-stratum errors under that scorer | Word-weighted natural-speaker WER, a competitive ranking, or “percentage accuracy” |
| 16 lexical proposals in 64 non-speech attempts | Speech-admission counterexamples; insertion double refused delivery | Native wrong-paste incidence or the cause of hallucination |
| Stop-to-prepared-text p50 0.361246 s, p95 0.429853 s on 932 phase-complete attempts | A limited internal interval | Physical gesture, rendered partial, observed insertion, cold-cache timing |
| Maximum sampled whole-XCTest-process footprint 540,296,296 bytes | Sampled process observation | App-exclusive RAM, accelerator/service totals, battery or leak qualification |
| Controller, lifecycle, corpus and native receiver seams | Valuable deterministic contracts | End-to-end natural recognition in real target applications |

The older complete observation elsewhere in spec 08 has different denominators
and a word-weighted score over nonempty proposals. Do not combine it with the
September 21 arithmetic-mean scores. Spec 06 previously stated that live
Parakeet silence yields no segment and that final insertion was verified end to
end; GAPS records silence proposals and dispatch-only delivery, so spec 06 now marks
that wording as withdrawn/historical. Neither statement was ever
current certification; preserve dated failures before making a release claim.

Related destination/recovery, clipboard-ownership, verified/dispatched/refused
outcome and Literal/Clean profile work was proposed separately and was not part
of the observed main tree. Do not add separate proposals' feature lists together
and call the combination main. Any eventual integrated SHA needs its own
qualification.

## 3. Data and consent before models

### Three different suites

1. **Fast deterministic regression:** retain the existing public synthetic
   corpus and source/hash admission. Extend characterization for token boundaries,
   repeated words, long-context replay and provisional/final revisions without
   changing references merely to accept current mistakes. No synthetic speaker
   independence claim.
2. **Natural-speaker qualification:** propose 60 consented adult speakers: 20
   tuning, 10 development and 30 sealed test, disjoint by speaker, household,
   recording session and related prompt family. Include varied Colombian regions,
   ages and self-described language backgrounds without promising national
   representativeness. If recruitment cannot cover a group, narrow the claim.
   Obtain about 100 utterances per test speaker (3,000 test utterances), balanced
   across Spanish, English technical speech and natural code-switching where the
   speaker is comfortable. Do not force unnatural bilingual performances.
3. **Device and safety qualification:** independent declared recordings and
   disposable editor interactions; include non-speech, cancellations, ownership
   races, permission/device failures and recovery. Audio replay bypassing capture
   is labeled a different lane from an acoustic microphone experiment.

Candidate natural-test content mix: 25% messages, 25% longer prose, 25% technical
content and 25% short/adversarial utterances. Tag overlapping features rather than
pretending each is a disjoint statistical sample: proper nouns, numbers/currency,
dates/times, paths/URLs/email, code identifiers, negations, corrections, repeated
words, punctuation commands, hesitation and quoted instructions. Include 0.2–2 s,
2–15 s, 15–60 s and continuous 2–5 minute speech. A valid short utterance rejected
by capture policy is a task failure, not an excluded ASR sample.

Recruitment must explicitly permit recording, local scoring, retention duration,
withdrawal handling and who can access raw audio/reference transcripts. Cloud
comparison requires separate named-provider transmission permission. Do not use
private meetings, children, real credentials, private paths or unrelated screen
content. Use invented names and safe command strings. Acoustic background audio
also needs lawful provenance and bystander consent. Keep raw audio and text
private by default; release only separately licensed/consented examples. Dataset
availability or a permissive text license does not prove audio/voice consent.

Public corpora can supplement, not replace, target speakers: Mozilla Common Voice
for licensed read speech and FLEURS for multilingual coverage have different task
and accent distributions. Audit the exact dataset release/card, license,
attribution and speaker/session fields before admitting it. Missing Colombian or
natural-switching metadata is an explicit coverage gap. Never infer demographic
identity from voices. See sources below; this proposal downloads no dataset.

### References and split integrity

Two bilingual annotators independently transcribe literal speech; adjudicate
before seeing system labels or hypotheses. Publish a rubric for hesitations,
partial words, punctuation commands, numerals and alternatives. Version/hash the
reference and frozen normalization implementation. For meaning labels, two
blinded reviewers independently score every natural holdout utterance at raw and
post-cleanup stages; adjudicate every disagreement and report agreement and
denominators. A smaller pilot may use a labeled stratified sample, but cannot
qualify the population error-rate gate or count unreviewed outputs as correct.
No LLM-only semantic judge.

Keep speaker, prompt family, paraphrase family, voice, session and source-recording
IDs disjoint across tuning/development/test. Noise variants of one recording stay
in its partition. Check exact and normalized text/audio duplicates plus human
paraphrase review. Personal dictionary entries are fixed from tuning material or
an explicitly separate onboarding list; do not derive them from holdout answers.
Maintain an inaccessible sealed test set until configuration is frozen. Any tuning
after viewing it makes it development data; obtain a new holdout for fresh claims.
Vendor pretraining contamination may be unknowable: disclose it, add freshly
consented original prompts, and avoid asserting guaranteed training independence.

## 4. Configuration and machine manifest

Compare configurations, not just model names. Record commit and clean-tree state,
binary hash/signature, build mode/compiler/SDK, dependency-lock digest, model
repository/revision/artifact SHA-256, quantization/compute units, tokenizer,
streaming chunk/context/VAD/endpointer settings, language hint, dictionary digest,
cleanup policy/prompt/model and every feature flag. Record OS build, chip/RAM,
model disk-cache state, power source/low-power mode, battery health, thermal state,
input device/firmware/sample rate, route, output device, app/editor version and
keyboard layout. A configuration or host change creates a new cell.

Start with a small predeclared tuning grid:

| Profile | Voice route | Transform | Purpose |
|---|---|---|---|
| Local baseline | Current pinned Parakeet/controller | Shipping text rules recorded exactly (bilingual filler removal on by default, deterministic dictionary replacements) | Characterize current shipping path |
| Local alternative | Supported pinned local engine on supported OS | Same text-rule policy | Isolate engine/runtime trade-off |
| Local clean | Winning local voice route | Explicit deterministic or local clean mode | Measure added semantic risk and editing savings |
| Cloud voice/clean | Named versioned provider(s), only with approval | Stage-specific network policy | Separate cost/privacy/latency class |

Apple Speech's supported locale/OS and installed assets are part of its cell; a
fixed-language route cannot silently stand in for natural code-switch support.
A refinement model is not automatically a selectable live dictation engine.
Proposed VAD/context/vocabulary mechanisms need their own call-site admission;
this table does not claim that any unimplemented configuration already exists.
The shipping baseline is not a literal mode: its default post-rule text drops
hesitation fillers, so literal-reference WER at that stage must be reported
separately from raw/adapter-stage WER rather than attributed to recognition.
Tune on development data with a bounded grid and keep all candidates' results.
Select one default per supported profile before testing, rather than selecting a
winner per utterance. Keep offline and cloud leaderboards separate. A local ASR
followed by a remote rewriter is a cloud-assisted profile.

Primary reference host: one declared Apple Silicon laptop with 16 GB RAM; add an
8 GB supported low-memory host and a high-end host as distinct qualification
cells. Retain the project's historical M4 Max reference separately, not as proof
for every Mac. Test all claimed supported OS families, with no extrapolation
from a single hosted runner. Use laptop mic, wired USB headset and Bluetooth mic;
include actual route switching, disconnect/reconnect and sample-rate changes.
Use quiet room, office background and controlled +20/+10/0 dB SNR mixes where
calibration is valid. Report how SNR was measured; synthetic mixtures are not
physical Bluetooth evidence. Keep ambient noise and voice level documented.

“Warm” means loaded model and initialized stream; “process cold” means a fresh
process with declared disk caches; “system/model cold” requires a reproducible,
explicitly authorized cache condition. Do not erase user caches to create it.
Randomize paired product order with a saved seed, block by host/day/condition,
keep foreground/background work stable and record disturbances. Use at least
three independent sessions/days, 59 declared process-cold starts and 200 warm
utterances per primary host/profile. A distribution-free one-sided 95% upper
bound on p95 needs at least 59 independent observations (0.95^59 < 0.05); fewer
cold starts can support a cold p50 estimate but leave the cold p95 gate
inconclusive. Three session blocks
are likewise too few for a meaningful block bootstrap; add independent
sessions/days before treating a latency interval as a gate verdict.

## 5. Metrics and candidate numerical goals

All numbers in this section are **proposed targets**, chosen to make the
experience useful and mistakes visible. Pilot variance, cost and human feedback
may justify a prospective revision before holdout; never weaken a threshold
after failure to convert that run into a pass. Publish absolute results and
confidence intervals even when the candidate target is missed.

| Dimension | Candidate acceptance goal | Rationale and denominator |
|---|---|---|
| Natural literal WER | <=8% quiet Spanish and English; <=12% quiet code-switch; <=15% at +10 dB SNR | Practical first quality bar, not a benchmark fact; each primary stratum must qualify |
| CER | <=4% quiet ES/EN; <=6% quiet mixed | Reveals identifier/orthographic errors that word aggregation obscures |
| Meaning-critical error | <=1% of natural utterances; <=0.5% cleanup-induced harmful changes | User intent matters more than punctuation; report exact names/numbers/negations separately |
| Critical-token exact match | >=99% on predeclared entity slots | No case-folding or numeric normalization that hides a changed value; escaping/path case follows declared task |
| Valid short-utterance completion | >=99% | “Sí”, “no”, names and numbers must remain usable; no audio padding to evade capture policy |
| Non-speech lexical output | <=0.1% attempted no-speech sessions; zero automatic lexical insertions in the safety suite | Silence, tones, music, coughs, keyboard and playback-only conditions; separate proposals from inserted text |
| Warm first rendered partial | p50 <=300 ms, p95 <=700 ms after annotated speech onset | Feedback without confusing model acquisition with speaking latency |
| Warm Stop-to-final prepared text | p50 <=500 ms, p95 <=1,000 ms | Internal finishing interval, separately from delivery |
| Warm Stop-to-observed edit | p50 <=700 ms, p95 <=1,500 ms | Useful completion where a receiver can verify the edit |
| Process-cold request-to-ready | p50 <=2 s, p95 <=5 s | Visible readiness before inviting speech; collect enough trials for tail uncertainty |
| Verified delivery in supported matrix | >=99.5% eligible attempts; zero wrong-target or duplicate inserts | Separate `verified`, `dispatched-unverified`, `refused`, `failed` and `not-attempted` delivery outcomes; cancellation is an attempt status |
| Cancellation | feedback p95 <=200 ms; zero later dispatch after pre-dispatch cancel | A posted event cannot be undone by later cancellation; report that boundary |
| Safe recovery | >=99% of predeclared completed-output failure opportunities recoverable by explicit user choice | Lost/unretained output counts as failure; qualify same-process and crash/relaunch recovery separately from interrupted audio |
| Resource cost | <=1.5 GiB peak total attributable memory; steady idle <=1% of one CPU core; active mean <=100% of one core | Candidate 16 GB baseline; include helper/service costs or mark attribution unavailable |
| Battery and endurance | <=5 additional battery percentage points/hour versus matched idle; retained memory growth <=100 MiB after 1,000 sessions and quiescence | Paired repeated laptop trials; report battery health, thermal state and measurement noise |
| Local privacy | zero attributable audio/transcript egress or unintended persistence during the declared experiment | Bounded observed evidence, never proof of universal absence |

WER = (substitutions + deletions + insertions) / reference words; CER uses
characters. Report micro/word-weighted WER and speaker-macro WER separately,
plus medians and per-stratum denominators. WER can exceed 100%. Use a versioned
NFC/case/punctuation policy and preserve phonemic accents; also report an
unnormalized exact-match track for identifiers and critical values. Never turn
WER into a general “accuracy percentage.” Empty speech outputs count as full
deletions for task-level transcription scoring; retain cancelled/failed attempts
and report ASR-only conditional scores separately. Empty-reference no-speech
cases use incidence metrics, not division by zero or invented WER. Also report
lexical words per minute of non-speech exposure. Distinguish no audible voice
from background speech without an intended user utterance; report them separately.

Compare raw engine hypothesis, adapter/coalescer text, post-rule/cleanup output
and observed receiver text. Attribute loss/replay to a stage only with evidence
at those boundaries. Report cleanup benefit (reviewed editing actions/time saved)
alongside deletions, fabricated content and meaning changes. Spoken command text
is data; never execute shell/code/agent instructions during evaluation.

Latency uses monotonic timestamps for request, model ready, first PCM, annotated
speech onset/end, first engine update, first rendered partial, Stop, final text,
dispatch and receiver acknowledgement. Also measure speech-end-to-final to catch
endpointing delays. Rendered feedback needs UI evidence; controller callbacks do
not measure it. Log clock synchronization/calibration and nearest-rank quantiles.
Report timeout/failure rates and success-conditional latency together; do not
silently drop slow failures. Include p50/p95 for cold and warm separately, with
bootstrap intervals and sample counts. A missing receiver timestamp is unknown,
not zero milliseconds.

## 6. Delivery, safety and recovery matrix

Use only an explicitly authorized disposable developer build/store, synthetic
text and a scratch pasteboard/receiver. Installing a differently named app does
not prove data-store isolation. The release application and live library are
not test targets. Existing native permission gates must remain fail-closed.

Test plain text (TextEdit), native rich text, a browser textarea/contenteditable,
Electron editor, terminal input without execution, and an AX-limited custom
editor. Pin actual versions and classify each supported/unsupported capability.
Do not imply this proposal has run those applications. Include Spanish/English
UI, US/Spanish/Latin American keyboard layouts, emoji/combining marks, selection
replacement, focused window changes, multiple windows and slow receivers.

Delivery eligibility is frozen from the requested task/case before execution,
not inferred from a successful recognition. For valid eligible dictation,
unexpected refusal, empty output and timeout remain end-to-end failures. Report
conditional delivery-after-final separately; expected safety refusals belong to
their declared negative-control denominator.

A successful delivery is exact text observed at the intended target and selection
for that generation. CGEvent dispatch is only dispatch. AX readback may be
unavailable, lossy, unsupported or time out; classify it as unverified without
replaying automatically. Use an owned receiver that acknowledges the actual
insertion and run positive/negative controls so a fake readback cannot pass.
For arbitrary editors, use separately authorized human observation when needed;
never scrape unrelated private text to establish success.

Mandatory adversarial cases:

- Focus/window/application/selection changes during capture, finalization,
  modifier release, paste and acknowledgement; original destination closed,
  secure field or uncertain element identity; session cancelled/restarted while
  delayed callbacks and feedback return. Never retarget silently.
- Clipboard with multiple items/types, binary formats, empty state, promised or
  oversized representations; another application changes it during acquisition,
  before dispatch and before restore. Bound materialization and restoration;
  never overwrite a newer owner's clipboard or drop formats silently. Refusal
  is safer than unbounded acquisition. Verify exact bytes when preservation is
  supported, plus truthful retained-text recovery when it is not.
- Cancel before ready, mid-capture, during model/cleanup, immediately before and
  after dispatch; lost key-up, repeated press, press-and-hold/toggle collisions,
  mouse conflicts and modifier keys held. Late work cannot affect a new session.
- Revoke microphone/Accessibility permissions, input unavailable, no first PCM,
  stalled stream after first PCM, source EOF, model failure, memory pressure,
  system sleep/wake, Bluetooth route changes, device removal and reconnect.
  Distinguish effect fencing from actual termination of a blocked native call.
- Recovery after refused delivery, app relaunch and process termination, with
  exact retention/deletion policy declared. Do not imply volatile final text
  can recover interrupted audio or survive a crash. Never automatic repaste.
- VoiceOver labels/status, keyboard-only operation, reduced motion, high contrast,
  remappable shortcuts, no reliance on color alone and no stolen focus. Human
  assistive-technology qualification complements seeded XCUITest assertions.

The safety suite requires zero unauthorized effects in all scripted negative
controls and zero observed wrong-target/duplicate pastes. One such event stops
that candidate's qualification regardless of averages. Preserve evidence without
sensitive content; diagnose before collecting another generation.

## 7. Sample size, uncertainty and fair comparison

Pre-register primary strata, weights, thresholds, competitor configurations,
exclusions, timeout policy and analysis before opening holdout results. The 3,000
utterance/30-speaker design is a starting proposal, not a power guarantee. Estimate
between-speaker variance on pilot data and simulate 90% power for predeclared
true absolute WER improvements beyond the 2-point superiority margin (for
example 3 and 4 percentage points), including the declared multiplicity
correction. Expand independent speakers if necessary; a true 2-point effect
is the test boundary and cannot provide high power for that stronger claim. Never add
only favorable cases or stop sampling at the first significant result.

Use 10,000 paired speaker-cluster bootstrap replicates with a saved seed, retaining
all utterances and devices belonging to each sampled speaker together. Resample
the same speakers for both systems and report 95% intervals for scores and paired
differences. For synthetic tests, cluster by independent phrase group/voice
structure and describe the inference as synthetic only. For device/day latency,
resample independent host-day/session blocks; utterance repeats are not fresh
independent samples. Shared prompt topics can add cross-speaker dependence;
include a predeclared family-block sensitivity analysis and disclose uncertainty
when the proposed clusters do not capture it. Use a predeclared family-wise comparison correction (for
example Holm) for multiple primary systems/strata; label exploratory slices.

Candidate comparative rule: the adjusted upper confidence bound for Portavoz
minus comparator WER is below -0.02 for superiority, or below +0.01 for
noninferiority, on each declared primary speech stratum. On Stop-to-observed-edit
p95 require no worse than +200 ms for noninferiority. These are proposed practical
margins, not established preferences. To claim an advantage, require at least
one superiority result, all important dimensions noninferior, and all safety/
privacy gates passed. Trade-offs without dominance are a scorecard, not a winner.

For fixed absolute gates, use the adverse one-sided 95% confidence bound: upper
for error/latency/resource limits, lower for completion/exact-match rates. Report
both point estimate and interval. “No events observed” is not zero true risk.
About 3,000 independent zero-failure opportunities are needed for a one-sided
95% binomial upper bound near 0.1%; roughly 600 for 0.5%. The non-speech
lexical-output gate therefore needs an explicitly budgeted no-speech suite of
that size; otherwise it is inconclusive by construction. An all-zero empirical
bootstrap interval cannot certify zero risk: use an exact one-sided binomial
bound only when independent trials are justified, otherwise mark the population
rate inconclusive and limit the claim to the tested matrix. Repeated audio, one
speaker or one deterministic race is not 3,000 independent opportunities. Report
cluster-aware uncertainty or explicitly limit the claim to the tested matrix;
do not certify rare-event population rates from tiny suites. If an interval
crosses a threshold, the result is inconclusive, not a pass. Safety counterexamples
remain blockers even when a statistical interval looks favorable.

### Compare two to four products without copying implementations

Recommended initial comparison set: Handy and Superwhisper local profiles, plus
VoiceInk local as an optional third and Wispr Flow as a separately labeled cloud
fourth. These are research choices, not asserted quality leaders. Freeze the
actual installed version, model, mode and settings; official documentation is
configuration guidance, not comparable benchmark evidence.

1. Review current terms, license, permitted automation and benchmark publication
   conditions before installation/use. Obtain any required paid account and
   provider-data permission; do not bypass trials, anti-automation or access
   restrictions. This document authorizes no purchase or upload.
2. Use normal documented input/output behavior in an independent harness. Do not
   copy competitor source, assets, prompts or private protocols. Portavoz remains
   MIT/no-GPL: VoiceInk GPL source is not implementation material. Dataset/model
   licenses are separate from application licenses and require their own review.
3. Run both a factory-default user-experience lane and, where supported, a matched
   local-model/literal lane. Do not handicap a competitor with arbitrary settings
   or claim matched compute when a product hides its model/runtime. Mark unknowns.
4. Feed identical, permitted consented audio for ASR comparison with a documented
   capture route. Run a separate calibrated acoustic end-to-end lane in randomized
   blocks. Label virtual/replay input rather than presenting it as physical-mic
   experience. Keep user dictionary knowledge equivalent and frozen.
5. Separate transcription, cleanup, auto-learning, context capture and telemetry.
   VoiceInk local transcription alone does not establish its enhancement/Dictionary
   Auto Learn route is local. Disable those routes or establish the selected local
   configuration. Superwhisper voice and language models are separate stages.
   For Handy, document model and paste strategy, including experimental settings.
   For Wispr Flow, distinguish privacy/no-retention settings from on-device
   processing. Test mixed speech; language detection wording is not evidence that
   code-switching works or fails.
6. Score blinded outputs with the same reference/rubric. Keep refusals, timeouts,
   paid limits and missing capabilities in their own categories. Report costs and
   network conditions for cloud lanes; cached/network-free repetitions are not
   independent service reliability trials. Publish only authorized aggregate
   results and permitted examples. Give a reproducible configuration and limitation
   statement rather than vendor marketing claims.

## 8. Privacy and resource evidence

Inspect the entire selected path: voice inference, cleanup, dictionary learning,
context, updates, crash reporting and model preparation. In a controlled local
lane, observe attributable connection metadata with permitted system tools and
repeat with outbound access unavailable after authorized assets are installed.
Use synthetic content; inspect owned cache/log/temp locations for unintended
persistence. Record tools, time window, denied connections and attribution limits.
Encrypted network observation cannot prove what payload was sent, and silence in
one window cannot prove universal non-egress. Never collect credentials or defeat
OS security to strengthen a claim. Clipboard managers and recipient applications
have their own persistence/network boundaries.

Measure app plus child/helper process footprint, CPU seconds, peak/steady state,
thermal transitions and reported accelerator attribution where available. Missing
service/accelerator visibility means incomplete total-memory evidence. Pair active
and idle battery trials of equal duration, brightness, radios and background
work, using at least three independent repetitions; report discharge confidence
intervals, not a single battery percentage. Run a separately bounded 1,000-session
endurance campaign and a continuous long-stream case; sample through declared
quiescence after Stop/Cancel, distinguish cache residency from unbounded growth,
and retain every stall. Do not restart each case and call that leak qualification.

## 9. Reusable harness and evidence contracts (proposed)

Reuse current corpus admission, model/controller launchers, monotonic phase sink,
accuracy evaluator and native receiver. Their existing closed schemas remain
unchanged. Add a separately versioned adapter/report layer only after reviewing
this contract; do not add arbitrary fields to existing admitted receipts. No new
harness is implemented by this documentation change. Before schema admission,
freeze a metric registry: metric ID, processing stage, unit, numerator, denominator
eligibility, strata, missing-data policy, estimator/interval, threshold/direction
and comparative margin. The conceptual objects below must become exact executable
schemas with validator tests; their table alone is not a complete wire format.

The extension should support: manifest validation; explicit capability admission;
ordered run-plan generation; immutable configuration/reference identities; bounded
sequential execution; per-attempt terminal receipts written immediately; native
receiver acknowledgement; scoring; paired analysis; and aggregate report
validation. Do not claim a CLI command exists until implemented and tested.

Required conceptual schemas (all exact versioned JSON objects, unknown fields
rejected; no raw text/path/secret in public receipts):

| Object | Required fields and invariants |
|---|---|
| `evaluation-config/1` | `protocolDigest`, `sourceCommit`, `treeClean`, `binaryDigest`, `dependencyDigest`, `modelDigests[]`, `runtimeDigest`, `hostID`, `osBuild`, `profileID`, `mode`, `networkPolicy`, `dictionaryDigest`, `normalizerDigest`, `datasetDigest`, `splitDigest`, `seed`, `timeouts`, `budgetDigest`; valid hash/type/enums, no secret values |
| `dataset-manifest/1` | `datasetID`, `generationDigest`, `licenseReviewID`, `consentPolicyID`, `split`; each case has opaque `caseID`, `speakerClusterID`, `householdID`, `familyID`, `paraphraseFamilyID`, `sessionID`, `sourceRecordingID`, `voiceID` (synthetic only, else `null`), `strata[]`, `audioDigest`, `referenceDigest`, `durationMs`, `speechExpected`; no names, transcripts, source paths or private consent forms |
| `run-plan/1` | Config/manifest digests, ordered unique `(caseID, repetition, conditionID, productProfileID)` keys, planned count, randomization seed, independent-cluster counts and registered exclusions; immutable before execution |
| `attempt/1` | Run/config/case identities, ordinal, terminal `status`, typed `failureReason`, capture/readiness state, ordered monotonic phase offsets or `null`, frame accounting, raw/post-rule error counts and reference lengths, critical-slot counts, semantic-review IDs, lexical-output flag, `deliveryOutcome`, receiver-proof digest or `null`, clipboard/focus ownership verdicts, bounded resource observations |
| `evaluation-report/1` | Exact source/head/build identities; all planned/observed/failed/cancelled/missing counts; per-stratum denominators; score/quantile estimates and intervals; uncertainty method/seed/cluster counts; candidate thresholds and adverse bounds; gate states; artifact digests; deviations and limitations as controlled IDs; reviewer sign-offs |

Terminal attempt status enum: `completed`, `cancelled`, `refused`, `failed`,
`timed-out`. Delivery enum: `not-attempted`, `refused`, `dispatched-unverified`,
`verified`, `failed`. Gate enum: `pass`, `fail`, `inconclusive`, `not-run`,
`not-applicable` (the last requires a predeclared scope reason). Keep signed-off
human prose separate from machine admission. Opaque consent/review IDs are not
proof of consent; custodians retain restricted records and independent review.
Small-group aggregates/linked pseudonyms can still identify people; review
publication and suppress identifying slices without silently altering evaluation.

Validate finite units/ranges, sample cardinalities, phase ordering, conserved
frames, identity before/after execution and referential integrity. A cancelled
attempt cannot have verified pre-cancel success invented after the fact; actual
post-dispatch cancellation must retain its dispatch timestamp/outcome. A verified
outcome requires an admitted receiver proof for the same target/session/generation.
Missing data remains `null` with a reason, never a fabricated zero. Crash midway
leaves an incomplete report containing prior immutable attempt receipts. A rerun
is a new generation linked to the failure; it never overwrites a red result.
Archive sensitive raw hypotheses separately with approved retention; public
reports contain counts and consented examples only. Existing field collectors'
closed privacy contracts must not be broadened to accept these new schemas.

### Human-readable report template

- Claim, intended population, exclusions, date and protocol version
- Candidate and baseline exact source/binary/model/configuration identities
- Dataset provenance, consent/license review, split leakage checks and coverage
- Planned/completed/cancelled/failed/missing counts and first-attempt results
- Per-stratum raw ASR, post-rule and observed-output WER/CER/critical errors
- Natural-speaker paired differences, confidence bounds and adjudication rubric
- Cold/warm phase p50/p95, failure/timeouts and receiver coverage
- Safety/clipboard/focus/cancel matrix, accessibility, device and OS results
- CPU/RAM/battery/thermal/endurance and network/persistence observation boundaries
- Candidate gate verdicts, unresolved discrepancies, reviewer decisions and
  permitted reproducibility artifact links

## 10. Acceptance sequence and stop conditions

These phases are proposed evidence dependencies, not a private delivery schedule
or authorization to merge existing work.

1. **Protocol review:** maintainers approve scope, candidate budgets, rubric,
   consent/license process, device/editor matrix and analysis plan. Keep the
   withdrawn silence/E2E wording reconciled without erasing negative evidence.
2. **Attribution:** characterize model output, segment mapping/coalescing, cleanup
   and controller behavior independently. Fix reproduced token loss/replay and
   silence admission with call-site counterexamples; no epsilon/token blacklist
   or engine switch accepted solely because a few examples improve.
3. **Harness proof:** schema/normalizer/receipt tests, synthetic goldens and
   negative controls pass. Missing models/permissions produce `not-run` or refusal,
   not green evidence. Acquire no assets or permissions implicitly.
4. **Pilot/tuning:** consented development data, bounded configurations, resource
   and latency feasibility, power estimate; then freeze protocol/configuration.
5. **Sealed qualification:** natural holdout, native receiver/editor, physical
   device/OS/accessibility, privacy/resource/endurance and paired competitor lanes.
   Integrating separately proposed work is its own reviewed decision; test the actual final
   integrated tree and retain its source and build identities.
6. **Claim review:** independent bilingual semantic reviewer plus maintainer
   review all gates, confidence bounds, failures and exclusions. Publish the
   bounded scorecard; defer comparative marketing until evidence supports it.

Stop candidate qualification on wrong-target/duplicate insertion, unauthorized
network/content exposure, clipboard loss, unexplained identity/schema mutation,
non-speech automatic insertion or regression in mandatory safety controls. Stop
an experiment if consent is withdrawn, unexpected private data appears, hardware
is distressed or the host is not safe to control. Quarantine only owned evidence,
preserve failure metadata, explain the blocker and require an authorized fix/new
run. Never relax a budget, skip a hard case, force permissions, retry into green,
merge, release or deploy as a substitute for evidence.

All required repository CI must finish successfully for the exact documentation head before
calling this proposal source-validated. Such CI does not execute this protocol or
qualify product quality. Future implementation needs required strict Swift tests,
applicable native/UI gates and unchanged runtime budgets in addition to this
scorecard. Passing seeded UI, hosted CI or corpus validation alone cannot authorize
a “best dictation” claim.

## 11. Primary sources and scope

Sources consulted for the protocol on 2026-10-06; mutable product documentation
must be checked again and exact versions recorded at experiment time.

- [Portavoz corpus and commands](../Fixtures/DictationValidation/README.md),
  [current gaps](GAPS.md), [quality evidence](specs/08-quality.md),
  [field privacy protocol](FIELD-VALIDATION.md),
  [assistive validation](ASSISTIVE-VALIDATION.md): implemented seams and boundaries,
  not acceptance of the proposed budgets.
- [Bisani and Ney, Bootstrap Estimates for Confidence Intervals in ASR Performance
  Evaluation (2004)](https://www-i6.informatik.rwth-aachen.de/publications/download/401/BisaniM.NeyH.--BootstrapEstimatesforConfidenceIntervalsinASRPerformanceEvaluation--2004.pdf):
  paired resampling and speaker dependence; the 10,000 replicates and decision
  margins here are proposed protocol choices.
- [NIST SCLITE scoring documentation](https://github.com/usnistgov/SCTK/blob/master/doc/sclite.htm)
  and [NIST exact binomial confidence limits](https://itl.nist.gov/div898/software/dataplot/refman2/auxillar/exacbici.htm):
  error accounting and rare-event uncertainty.
- [Whisper basic normalizer](https://github.com/openai/whisper/blob/main/whisper/normalizers/basic.py)
  and [English normalizer](https://github.com/openai/whisper/blob/main/whisper/normalizers/english.py):
  examples of consequential scoring transformations, not a mandated ES/EN policy.
- [Apple CGEvent post](https://developer.apple.com/documentation/coregraphics/cgevent/post%28tap%3A%29?language=objc)
  and [AX attribute read errors](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue):
  posted events and fallible readback motivate the delivery-evidence distinction.
- [FLEURS dataset card](https://huggingface.co/datasets/google/fleurs/blob/main/README.md):
  multilingual read-speech coverage and CC-BY-4.0. Its published sample ID is not a
  speaker ID; speaker-cluster inference needs verified additional metadata.
- [Mozilla Caribbean Spanish dataset card](https://mozilladatacollective.com/datasets/cmr2cf2x202uins07a4pe7m66):
  CC0-1.0 regional speech, including but not limited to Colombian Caribbean.
  This does not constitute a Colombian-only natural dictation cohort.
- [Handy canonical repository](https://github.com/cjpais/Handy) and
  [license](https://github.com/cjpais/Handy/blob/main/LICENSE): local-model and paste
  configuration reference, not independent quality evidence.
- [VoiceInk canonical repository](https://github.com/Beingpax/VoiceInk),
  [license](https://github.com/Beingpax/VoiceInk/blob/main/LICENSE) and
  [privacy/data documentation](https://tryvoiceink.com/docs/privacy-and-data):
  distinct transcription, enhancement and auto-learning routes; GPL source must
  not be ported into Portavoz.
- [Superwhisper models](https://superwhisper.com/models): voice/language model
  stage configuration; vendor benchmark values are not results for this cohort.
- [Wispr Flow privacy documentation](https://docs.wisprflow.ai/articles/3467817258-security-and-compliance-faq)
  and [language documentation](https://docs.wisprflow.ai/articles/3191899797):
  detection and mixed-language cleanup behavior to test, not assume.
