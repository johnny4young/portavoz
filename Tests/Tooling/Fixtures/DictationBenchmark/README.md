# Offline dictation benchmark report adapter

This is a **synthetic harness proof**, not a dictation-quality result. No human
recordings, voices, transcripts, model output or native editor experiment are
included. The example's hashes identify invented fixture labels, not real audio
or model artifacts. Its proposed-output counts and receiver events are doubles.
The example intentionally contains a cancellation, unverified dispatch and an
unobserved planned attempt; its verdict is `inconclusive`.

## Reproduce the report

From the repository root, with Python 3 and no additional packages:

```sh
python3 scripts/dictation_benchmark.py \
  --input Tests/Tooling/Fixtures/DictationBenchmark/synthetic-input-v1.json \
  --output /absolute/private/new-report.json
python3 -m unittest Tests.Tooling.test_dictation_benchmark
```

The output path must not exist; its parent must already exist. The CLI writes
one owner-only (0600) JSON file atomically through the existing publication
helper. It does not overwrite an earlier run or partial result. The output is
byte-for-byte reproducible for the same input bytes and scorer version; the
checked-in `synthetic-report-v1.json` is a reviewed golden. Input JSON is bounded
to 8 MB and rejects duplicate keys/nonfinite numbers. Input identity is checked
again before publication. Unknown fields, malformed counts, stale plan digests
and unsupported units fail closed. Exit 2 means invalid input/output; exit 1
means an observed safety counterexample; exit 0 means a report was produced,
**not a quality pass**. This version never emits `pass`.

No microphone, speech engine, provider API, shell command from a fixture, native
receiver, network service or model download is invoked. Use the existing public
[corpus admission and bounded launchers](../../../../Fixtures/DictationValidation/README.md) for
those separately authorized collection steps. Their closed receipt schemas have
not changed. A model/controller receipt cannot be passed directly to this CLI:
it lacks some of the required provenance, character-edit and receiver evidence.
Do not reconstruct absent counts from rounded rates or fabricate phase/receiver
proofs merely to obtain an admitted input.

## Scope and relationship to the quality proposal

This adapter implements a small, separately versioned **descriptive** scoring
surface inspired by [the proposed quality contract](https://github.com/johnny4young/portavoz/pull/87).
It is not the proposal's complete `evaluation-config/1`, `attempt/1` or
`evaluation-report/1` schema. Those names are intentionally not claimed here.
The source helper from [receipt-admission #89](https://github.com/johnny4young/portavoz/pull/89)
is reused to reject impossible word-error accounting.

The adapter consumes **explicit integer edit counts produced by an identified
scorer**, not raw references/hypotheses. It performs no second normalization and
no independent ASR measurement. The caller must preserve the exact reference,
audio, normalization/scorer identity and original observations in a restricted
evidence store. NFC/case/punctuation policy and character segmentation must be
reviewed and frozen before collection. In particular, Swift's character scoring
must not silently be mixed with Unicode-code-point scoring from another tool.
A digest records identity; it does not prove that the named implementation ran.

## Frozen metric registry

`METRIC_REGISTRY` in `scripts/dictation_benchmark.py` is versioned and included by
canonical SHA-256 digest in the run plan and report. Changing its rules requires
a new reviewed plan. No numeric acceptance threshold or confidence interval is
adopted by this version.

- Raw and post-rule WER/CER: sum substitutions, deletions and insertions divided
  by the corresponding reference counts, per declared split/stratum. Report
  word-weighted/micro rates and descriptive speaker-macro WER separately. WER
  may exceed 1. Missing attempt/stage scores make the complete rate `null`;
  available-case rates and their denominators are separate. Cancelled/failed
  attempts are retained; an explicitly scored empty speech hypothesis is full
  deletion. The tool does not invent a hypothesis for a missing attempt
- No-speech: no WER/CER is assigned to an empty reference. Report lexical-proposal
  incidence, planned/scored/missing counts and lexical words per minute of
  scored **fed-frame** exposure. A zero/missing exposure yields `null`, never
  zero hallucination risk. Background speech is outside this v1 no-speech class
- Latency: nearest-rank p50/p95 in monotonic milliseconds, split into warm and
  process-cold lanes. Intervals are request-to-ready, speech-onset-to-rendered
  partial, Stop-to-prepared and Stop-to-observed-edit. Only completed attempts
  with the required phases contribute samples; observed-edit also requires
  verified delivery. Planned eligibility, measured count and missing/unsuccessful
  count accompany every success-conditional estimate. A callback must not be
  labelled a rendered partial without actual UI evidence
- Delivery: structurally matching declared receiver evidence divided by **all
  frozen eligible planned attempts**, including failures, cancellations and
  missing observations. Display `dispatched-unverified`, `refused`, `failed`,
  `not-attempted` and `missing` separately. This is a descriptive completion
  fraction, not an estimated population reliability or confidence lower bound
- Safety: retain wrong-target, wrong-selection, wrong-text, duplicate insertion, no-speech
  insertion, dispatch of a delivery-ineligible planned attempt and
  dispatch-after-cancel counterexamples as `fail`. Otherwise the
  verdict remains `inconclusive`; no attempt receipts means `not-run`. Absence of
  an observed violation does not demonstrate safe delivery

The registry does not estimate semantic correctness, critical-token exact match,
resource/privacy/endurance limits, cluster-aware confidence intervals, paired
comparative effects or an accepted release gate. The report lists these limits
and always sets `populationQualified`, `consentVerified` and
`audioBytesVerified` to false. Tiny synthetic fixtures never certify population
rates. There is no universal "accuracy percentage" or "best dictation" verdict.

## Exact input contract: `dictation-benchmark-input`, version 1

All objects reject extra fields. The checked-in input supplies a complete
executable example. IDs must be opaque lowercase identifiers (maximum 64
characters), never names, paths, transcripts or credentials. Digests are 64
lowercase hexadecimal characters; source commits are 40. Integers reject JSON
booleans. Arrays are bounded; plans/datasets/receipts have at most 10,000 items.

The root has exactly `kind`, `schemaVersion`, `evidenceClass`, `configuration`,
`dataset`, `plan` and `attempts`. `evidenceClass` is `synthetic-fixture` or
`declared-observation`. Use one configuration per input; comparisons are separate
runs and do not select a winner per utterance.

### Configuration

Required: `sourceCommit`, Boolean `treeClean`, `binaryDigest`,
`dependencyDigest`, unique nonempty `modelDigests` (maximum 16), `runtimeDigest`,
`normalizerDigest`, `protocolDigest`, `hostDigest`, `dictionaryDigest`,
`profileID`, `networkPolicy: "local-only"`, `clockCalibrationDigest`, and
`clockUnit: "monotonic-ms"`. Store the underlying model revisions, build flags,
OS/chip/device/cache conditions, normalization specification, calibration and
other manifest detail behind these immutable identities. Cross-process receiver
clocks must be calibrated onto the same monotonic origin before exporting
phases. The adapter does not attest to configuration, calibration or local-only
network behavior merely because those assertions are present.

### Dataset and consent/provenance

Required: `datasetID`, `provenance`, `licenseReviewID`, `consentPolicyID`, `cases`.
Synthetic provenance is `synthetic-fixture` with null consentPolicyID. Declared
observations use `consented-adult-declared` and a nonempty consentPolicyID.
**Review IDs are assertions, not verified consent or a permission grant.**

Before collecting/scoring actual adult voices, the responsible custodian must
verify named-source authorization, audio/text licensing, recording and local
scoring permission, access, retention, withdrawal/deletion handling, and which
aggregates/examples may be published. Voice/audio consent is separate from a
text license. Never include minors, bystanders, private meetings or real secrets
in this lane. No provider transmission is supported. Do not publish the raw
manifest or even small-group aggregates without checking re-identification risk
and the separate publication permission. Keep restricted consent records outside
the repository and public report. Withdrawal invalidates the affected dataset
version and requires a new plan/report; this tool does not delete source records.

Each case has exactly `caseID`, `speakerClusterID`, `familyID`, `sessionID`,
`split`, `stratum`, `audioDigest`, `referenceDigest`, `referenceWords`,
`referenceCharacters`, `sampleRate`, `frames`, `speechExpected`.

Speaker/family/session identities are digests; declared identities and audio
hashes cannot cross splits. Nonempty reference hashes cannot cross splits.
Splits are `tuning`, `development`, `holdout`. Strata are `quiet-es`, `quiet-en`,
`quiet-mixed`, `snr10`, `other-speech`, `no-speech`; unsupported or finer strata
need a reviewed schema extension. This does not establish human independence,
consent, actual SNR, reference accuracy or absence of paraphrase contamination.
Reference counts must match speechExpected and no-speech uses zero references.
Audio accounting is 16 kHz, 1 through 19,200,000 frames (20 minutes) per case.
This descriptive format does not widen the existing audio launcher's bounds or
read audio bytes. Hash admission alone does not prove the declared speech exists.

### Frozen plan and attempts

Plan fields: `generationID`, `configurationDigest`, `datasetDigest`,
`metricRegistryDigest`, `seed`, `attempts`. Digests use the existing `fingerprint`
canonical JSON encoding: UTF-8, sorted keys, compact separators, no ASCII escape
conversion. Freeze the plan before execution and preserve its exact contents.
The tool validates supplied ordering/seed; it does not randomize or execute a
plan. No post-hoc exclusion facility is provided. Unselected dataset cases are
reported separately and are not covertly treated as executed or missing attempts.

Each planned row has `attemptID`, `caseID`, positive `repetition`, `conditionID`,
`temperature` (`warm` or `process-cold`), Boolean `deliveryEligible`, `targetID`,
`selectionID`. Attempt IDs and `(caseID, repetition, conditionID)` keys are unique.
Delivery eligibility and intended target/selection are declared before execution.
A recognition failure cannot retroactively make an eligible attempt ineligible.
No-speech cases are never delivery eligible: their correct outcome inserts nothing.

Each supplied receipt has `attemptID`, `planDigest`, `status`, `failureReason`,
`fedFrames`, `scores`, `phases`, `deliveryOutcome`, `preparedTextDigest`,
`receiverProof`. Status is completed/cancelled/refused/failed/timed-out.
Completed status requires null failureReason; cancelled requires user-cancelled;
timed-out requires timeout; refused/failed require capture/model/delivery/safety.
Cancelled status also requires the cancel phase. Completed status also requires all declared input frames; interrupted capture
must retain a non-completed status. Missing receipts remain
missing; duplicate receipts or an unknown planned ID are invalid. A resumed or
rerun experiment gets a new generation; preserve original failed receipts.

`scores` contains exactly `raw` and `postRule`, each null or a closed count object:
`wordSubstitutions`, `wordDeletions`, `wordInsertions`, `hypothesisWords`,
`characterSubstitutions`, `characterDeletions`, `characterInsertions`,
`hypothesisCharacters`. Counts must satisfy unit-cost edit accounting, including
reference minus deletions plus insertions equalling hypothesis length. These
checks cannot verify the truth or minimality of the claimed alignment without
the restricted source strings. Null means unmeasured, not a perfect transcript.

`phases` has exactly ready/speechOnset/speechEnd/firstRenderedPartial/stop/prepared/
dispatch/receiver/cancel, each null or a finite nonnegative millisecond offset
within one hour. Request is offset zero. Causal phase pairs must be ordered;
prepared requires Stop, dispatch requires prepared, receiver requires dispatch.
Partial/failed attempts may retain incomplete phases, with missing metric samples
reported explicitly. Do not substitute controller callbacks for rendering or
CGEvent dispatch for an observed edit.

`deliveryOutcome` is not-attempted/refused/dispatched-unverified/verified/failed.
Dispatch requires a prepared-text digest and timestamp. A receiverProof has
exactly generationID/attemptID/targetID/selectionID/textDigest/insertionCount/
acknowledgementMs. Verified requires the same generation/attempt, intended target,
selection, exact prepared-text digest, one insertion and matching receiver
acknowledgement. An observed mismatch may be retained as failed evidence and
triggers the relevant safety counterexample. This is structural proof admission,
not a signature or independent verification of a producer. A cancellation after
dispatch retains observed delivery; cancellation before a later dispatch is a
safety failure. Verified post-dispatch cancellation is retained in delivery counts
but excluded from completed-success latency.

## What remains before actual quality qualification

Obtain authorized audio and accurate references, independently review the
protocol/metric registry and consent records, implement reviewed collection
adapters for the exact machine/configuration, and retain immutable original
receipts. Run the existing native seams only on authorized disposable targets.
Then add appropriate confidence bounds and semantic review before applying any
proposed thresholds. Current synthetic data, hosted CI and a successful report
command do not satisfy these collection or population-evidence requirements.
