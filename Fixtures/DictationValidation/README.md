# Public dictation corpus

`public-synthetic-v1.json` contains original Portavoz test text under the root
MIT license. No private meeting, external dataset, downloaded voice, model or
audio recording is included. `textLicense` applies to the text, not to audio
that a separately authorized synthesizer might produce.

## Inventory and ground truth

The matrix is 60 phrase families × 8 explicitly declared acoustic/rate profiles:
160 English cells, 160 Spanish cells, 80 synthetic language-switching cells and
80 adversarial cells. Paired translations and related adversarial phrases share
one of 37 phrase groups. Variants are **not independent speakers or independent
phrases**. Report family, phrase-group, profile and cell counts separately.

Spoken segments declare their language; `acceptedTexts` records literal targets
and any reviewed alternatives. It is not an invitation to add the current model's
mistake as an acceptable answer. Numbers, negation, names, code, URLs, email,
typographic apostrophes, accented text, repetition, minimal utterances and quoted
hostile instructions are represented. Non-speech families have empty references.
`critical` flags exact-text review cases; a formatting mismatch is not, by itself,
a demonstrated factual error. ASR word/character error scoring and final output
fidelity must remain separate.

Eight profiles declare gain, optional noise floor, speaking rate, tail length
and background duration. These are recipes, not measurements of already rendered
clips. Language-switching segments are intended for explicitly attributed local
voices; this is not a natural bilingual speaker sample. Synthetic noise, tones
and impulses do not stand in for real coughs, music, accents or Bluetooth capture.

Families and related phrase groups cannot cross the tuning/holdout split.
Case/whitespace/NFC-equivalent references cannot disguise exact split leakage.
A rendered manifest must also assign disjoint voice identities to the two splits,
including cross-language reuse. This checks declared identities, not independent
human-speaker generalization; semantic paraphrase leakage still needs review.

## Validate the reviewed source

```sh
python3 scripts/dictation_corpus.py verify-public
python3 -m unittest Tests.Tooling.test_dictation_corpus
```

The public generation is SHA-256 pinned in the validator. A structurally valid
but edited/relabelled source does not become reviewed public data. Schema changes,
new references or acoustic recipes require an explicit generation/hash review;
do not update the pin just to match an unexplained mutation.

Model and controller launchers bind the admitted manifest bytes and published
request through the child run. Rewriting either document invalidates the
observation, even when the decoded manifest values remain equal; the retained
files must still match the identity that an evidence consumer will read.

The inventory output contains counts and the public digest, not text. It says
`audioChecked: false`, `qualityMeasured: false` and
`verifiedDeliveryMeasured: false`. A zero exit validates the corpus contract;
it is **not** a quality score or an accepted performance baseline.

## Admit local audio bytes

```sh
python3 scripts/dictation_corpus.py validate-audio \
  --manifest /absolute/scratch/audio-manifest.json \
  --audio-root /absolute/scratch/audio
```

The manifest has exactly these fields:

- `schemaVersion: 1`, `kind: "dictation-audio-manifest"`.
- `corpusSHA256`: the reviewed source digest; `recipeSHA256`: the exact producer
  recipe digest. The latter is recorded identity, not a producer attestation.
- `voices`: `tuning` and `holdout`, each with `en` and `es` SHA-256 voice identity
  digests. Names, filesystem paths and raw voice metadata are not in the receipt.
- `entries`: exactly one entry for every `<family-id>.<profile-id>` cell.
  Each entry has `caseID`, `audioSHA256`, `frames`, `sampleRate: 16000`,
  `channels: 1`, `sampleWidth: 2` and the sorted unique `voiceSHA256` list for its
  declared spoken segments (empty for non-speech).

Files are always `<caseID>.wav` directly under the explicitly selected root;
the manifest cannot provide paths. Admission rejects missing/duplicate cases,
unknown fields, cross-split voices, mismatched attribution, cross-family audio
reuse, symlinks, nonregular files, truncated PCM, wrong formats/hashes and files
that change during inspection. JSON is bounded to 2 MB; each mono PCM16 file to
120 seconds and 4,000,128 bytes. Files are hashed in bounded chunks. Success
checks bytes/format/declared attribution; it does **not** prove that a synthesizer
actually used the declared voice, rate or gain, or that the speech matches the
reference. The generation/consumption owner must provide that separate evidence.

The filesystem tests use tiny artificial PCM buffers and identify their scope as
parser/digest validation. Even a fully admitted matrix retains
`qualityMeasured: false` and `verifiedDeliveryMeasured: false`. No ASR hypothesis,
transcript, local path or raw error becomes inventory output.


## Render locally with installed macOS voices

`materialize_dictation_corpus.py` is an explicit developer operation, not an app
startup task. Supply a local JSON selection with `tuning` and `holdout`, each
mapping `en` and `es` to an already available voice name. The two partitions
must not share a selected voice identity. For example, when installed:

```json
{
  "tuning": {"en": "Samantha", "es": "Mónica"},
  "holdout": {"en": "Daniel", "es": "Paulina"}
}
```

```sh
python3 scripts/materialize_dictation_corpus.py \
  --voices /absolute/scratch/voices.json \
  --output /absolute/scratch/new-dictation-audio
```

The output directory must not exist. The producer uses only the reviewed public
text, enumerates available macOS voices, invokes `/usr/bin/say` with an explicit
input file and PCM16 output, and never plays audio or invokes a voice/model
installer. It is not a general-purpose arbitrary-text synthesis service. Each
subprocess has a 45-second deadline; the matrix checks a one-hour deadline at
work boundaries. A blocked filesystem call is not a hard real-time guarantee.

Identical voice/text/rate synthesis is cached only inside an owned temporary
directory. Every cell still applies its declared profile: fixed gain, seeded
uniform noise, bounded PCM clipping (counted), and **additional** silence. The
producer does not crop existing silence, infer speech-end timestamps or modify
recordings. No-op gain/noise preserves source samples exactly. Background
waveforms are synthetic silence, uniform noise, a 440 Hz tone or impulses,
not recordings of environmental sound.

`recipe.json` binds the reviewed source, producer script digests, Python version,
macOS build, system speech executable digest and selected voice names/locales.
A voice identity digest describes that selection and OS build, not a checksum
of every installed voice asset. Exact rendered WAV hashes remain authoritative
for a comparison; regenerating on another host is not assumed bit-identical.
`materialization.json` reports actual file counts, cache use, clipping and elapsed
rendering time without the source text. `manifest.json` is published last, only
after all 480 files pass admission. The directory is private and output files
are owner-only; JSON publication never replaces an existing file. Failure keeps
explicitly incomplete output, not a successful manifest; cached text and source
speech files are removed. Do not resume by overwriting that directory.

The producer's filesystem/transaction tests use an explicitly identified speech
double. Actual macOS synthesis is a separate lane. Neither a speech-double run
nor real synthesis measures ASR quality, product memory usage or verified text
insertion. Model and end-to-end baselines need their own receipts and deadlines.

## Observe the installed Parakeet adapter

Build and characterize the test-only probe in Release. Debug is refused for an
explicit model run because the vendor can mirror transcript-bearing diagnostics
to stderr. The engine lane never calls a model downloader:

```sh
scripts/run-swift-tests.sh --configuration release --jobs 4 \
  -Xswiftc -warnings-as-errors --filter DictationModelProbeTests
# Set this to the actual Release .xctest bundle produced by the command above.
# SwiftPM's native and SwiftBuild layouts use different bundle names.
python3 scripts/run_dictation_model_baseline.py \
  --audio-root /absolute/scratch/new-dictation-audio \
  --test-bundle "$RELEASE_TEST_BUNDLE" \
  --xctest "$(xcrun --find xctest)" \
  --case en-payment-negation.clean --case es-payment-negation.clean \
  --case mixed-review.clean --case non-speech-silence.clean \
  --output /absolute/scratch/new-model-observation
```

The launcher admits the complete audio matrix before and after measurement,
requires explicit unique canonical case IDs and a new output directory, and
records the exact test binary and audio-manifest digests. It passes a minimal
environment to one owned XCTest process, discards raw process output and enforces
a finite subprocess deadline. No other process is reserved, suspended or stopped.
A zero child exit without the matching complete observation is not success.
`request.json` and `outcome.json` identify scope, failure and timeout without
transcript text; they do not certify that an uncommitted source snapshot produced
a particular executable. An integration-qualified source SHA is a separate gate.

The launcher resolves `CFBundleExecutable` from the selected bundle's bounded
XML or binary `Contents/Info.plist`; it does not assume a build-system-specific
executable name. Missing/malformed metadata, a missing executable, path traversal
and symlink escape fail before output or launch. The metadata bytes and declared
executable identity must remain unchanged through the run and between matrix
cohorts. Tests enter both launchers with native SwiftPM and SwiftBuild layouts,
including an adversarial metadata replacement after child completion. This does
not attest every framework or resource in the bundle.

The native lane re-hashes installed Parakeet artifacts through
`ModelStore.verifiedInstallation`, checks each selected PCM hash and frame count,
and feeds 100 ms buffers paced by `ContinuousClock`. Overflow, early termination
and stream errors never produce a successful model receipt. Its observation
reuses the production `CaptionCoalescer`, `DictationAssembler`,
`DictationTextRules` and `TranscriptionAccuracy`; no alternate tokenizer or
accuracy normalizer is introduced. The original assembled text is scored; the
legacy filler-cleaned variant is measured separately as a change flag, not used
to conceal recognition errors. Recognized text and references stay in memory.

`model.json` contains two sequential passes over the selected cells, per-cell
WER/CER and exact-reference-match, model preparation times and content-free public
live-work counts. An exact mismatch in a critical family calls for review, not an
automatic claim of a factual error. A successful run means observation completed,
not that quality passed a competitive threshold. The first engine load may use
existing Core ML disk caches; these passes are not independent cold starts.
The probe does **not** execute `DictationController`, real microphone capture,
transformation providers or `TextInserter`, and explicitly marks controller,
verified delivery and memory as unmeasured. Those require their own lanes; four
selected cases are not a full bilingual/product qualification.

### Repeat speech beyond the live context window

Use `--repetitions 12` to concatenate each selected admitted PCM cell twelve
times in memory. The default remains `1`; allowed values are `1...12`. The
native fixture repeats every accepted reference with the same count and retains
empty non-speech ground truth. No source WAV is edited, no silence is cropped,
and no new synthesis or model download occurs. Repetitions are adversarial
variants of the same phrase/voice, not independent speakers or new source cells.

The **derived sequence**, not merely its source, must fit 120 seconds. Both the
launcher and native consumer reject overflow before inference. The run deadline
includes repeated duration and any additional attribution pass; the two-hour
limit does not increase. For example, append `--repetitions 12 --attribute-live`
to a run selecting `en-payment-negation.clean` and `es-payment-negation.clean`
to exercise long repeated utterances. Select smaller groups if a request exceeds
a bound; do not trim the source or relax the bound to obtain a passing run.

Model request/observation schema **2** binds repetition count at the run and row
levels, source PCM/manifest identity and the actual consumed duration. The child
receives the count explicitly. A short row, stale schema-1 binary, ignored count,
or boolean masquerading as an integer cannot satisfy a repeated request.
The native producer verifies its public live-work frame count against the
expanded PCM, not the original file. Older archived observations remain evidence
of their own binaries; they cannot qualify this new input contract.

A longer duration alone is not a quality pass. The rejected all-token-passthrough
experiment demonstrated that even a provider with a deduplication call can replay
its left context. Report WER/CER and output growth for repeated speech rather
than hiding the failure behind successful frame conservation or a green process.

### Attribute a mismatch before replacing the engine

`--attribute-live` explicitly adds a separate pinned-vendor run for each selected
case and pass. It uses the production window configuration and real mapper, but
is a **test-only experiment**, not an alternate shipping engine. It compares the
vendor's `finish()` result with the mapped/coalesced text, counts token timings
rejected at/before the mapper's current edge, and compares the experiment's final
text with the actual production adapter's result in memory. Only scores, counts
and that equality flag are written. `adapterDeltas` separately scores the actual
production adapter's space-joined deltas before coalescing; this naive join is a
diagnostic stage, not a proposed final assembler.

A changed WER across stages identifies a boundary to investigate, not permission
to patch it with vocabulary or an epsilon. If the independent experiment does
not reproduce the product text, that mismatch remains explicit; it cannot prove
an exact cause in the production run. Both paths currently use the same verified
model artifacts, but attribution loads an additional set of weights and executes
another live pass. Its timing and memory must not be compared with the ordinary
single-engine baseline as if conditions were identical.

The provider does not publicly expose per-window failure counts. Input-frame
conservation and a successful terminal callback do not certify that every
inference window succeeded; `backendWindowFailureCoverageMeasured` stays false.
No model receipt substitutes for the pending controller failure/dispatch tests.

Source and audio manifests retain their 2 MB input bound. A model observation has
an explicit 8 MB bound for the full two-pass, per-cell diagnostic schema. The
launcher computes the required paced audio duration plus its fixed five-minute
allowance **before** reserving output. A selection exceeding the two-hour owned
process bound is refused instead of silently capped and started anyway. Split
large attribution requests into sequential selections; never hide a missing
selection in an aggregate or assume independent cold starts between its passes.

### Admit complete observations, not success flags

The launcher validates a closed root/cell/score/live-work schema before marking
an observation admitted. Every requested row binds the canonical public source,
actual frames/chunks, typed finite metrics and ordered input/completion phases.
`qualityMeasured: true` without the score payload is invalid. Unknown fields,
including accidental transcript content, cannot enter an admitted receipt.
Absent first-update time is allowed only when both text stages emitted no words;
high WER/CER is retained as a bad-quality observation rather than rejected for
looking bad. These checks validate receipt structure and attribution, not
scientific truth, a quality threshold, or controller/verified-delivery coverage.
Adversarial runner tests inject incomplete and content-bearing receipts at the
actual launch boundary instead of testing only a standalone schema helper.


## Observe the real controller without native insertion

Add `--controller` to the same explicit launcher. This selects
`DictationControllerModelTests`, not the model-only consumer. Build Release
with the matching source first. Requests/outcomes use schema 3; the distinct
controller observation uses schema 1. Model-only schema 2 remains unchanged.
`--controller --attribute-live` is rejected before output or a child exists:
independent vendor attribution is a different experiment, not a controller run.

The lane enters the production `DictationController` with one isolated
microphone source per request. It reuses the same 100 ms public-PCM feeder as
the model-only lane. After all admitted bytes have been supplied, a test driver
requests Stop through the real controller; only that controller's Stop closes
the microphone stream. There is no extra padding, fake capture clock or bypass
of the minimum-duration/stop-tail rules. Installed Parakeet weights load lazily
inside the first controller request and are reused for later cells/passes.
Every row states whether it requested a fresh load or reused the engine; failed
preparation attempts remain counted. Core ML disk-cache state is uncontrolled.

This is **not native insertion**. Platform admission is a declared test double;
no global trigger, microphone device, permission prompt, clipboard access or
keyboard event is used. The insertion port retains the proposed output in RAM
and returns rejection. Literal mode, automatic language, no replacements and
no vocabulary are explicit volatile test preferences, not changes to user
settings. The controller's coalescer and final rules actually produce that
output; the probe does not reconstruct it using a parallel text policy.

Every requested attempt remains in the observation, including cancellations
and pipeline failures. `proposedOutputScore` evaluates the output the user
would have been offered, **including empty output from an unsuccessful
attempt**, not the recognizer in isolation. The original public corpus contains
valid subminimum utterances; excluding them would conceal a reachable outcome.
`pipelineCompleted` independently requires an eligible controller outcome,
completed public input, exact fed/backend frames/chunks and a valid completed
live-work sample. It does not mean successful insertion or acceptable quality.
Failed work may have no public sample; missing evidence cannot be filled with
an invented successful sample. All such rows retain their outcome and counts.

The bounded memory observer reuses `ResourceProbeUsage.current`, sampling the
whole XCTest process approximately every 100 ms plus start/end. It reports
observed peak, endpoints, sample count and thermal endpoints. A sampling error
cannot become zero memory usage. PCM is already allocated at the initial
snapshot; caches, framework allocations and the test harness are included.
This is not attribution to dictation alone, the absolute instantaneous peak,
a leak proof, or a hardware reservation. The source and acquired runtime lease
are stopped/released before the final footprint sample; controller outcome
timestamps themselves do not certify resource-quiescence timing.

A cancelled controller may release its lease before the adapter's asynchronous
cleanup finishes. A missing live-work sample preserves that limitation; the
final footprint is not proof of backend quiescence, and process footprint does
not attribute all accelerator/driver allocations to this feature.

The launcher checks executable bytes and file identity before and after the
child. A concurrently replaced build cannot retain the prelaunch digest in an
admitted observation. This detects changes; it is not immutable bundle capture
or proof that frameworks, resources and source belong to a qualified commit.

Closed-schema admission rechecks every requested row, model/manifest identity,
preparation-attempt accounting, phase shape, proposed-output score, input/work
accounting and memory sample. It retains bad results instead of relabeling them
as successful; `observed` means the observation completed, **not** that any
quality/performance threshold passed. Native receiver acknowledgement, physical
gesture timing, rendered frames, AppServices cache ownership, physical devices
and the integrated source SHA require separate evidence.

## Observe the complete controller matrix in bounded cohorts

```sh
python3 scripts/run_dictation_controller_matrix.py \
  --audio-root "$PUBLIC_AUDIO_ROOT" --all \
  --test-bundle "$RELEASE_TEST_BUNDLE" --xctest "$(xcrun --find xctest)" \
  --output "$NEW_PRIVATE_OUTPUT_DIRECTORY"
```

The command reuses the existing controller lane without changing its model,
profile or timeout formula. `--all` explicitly selects the pinned 480-cell
matrix; repeated `--case` options instead select a declared subset. Default
cohorts contain at most 16 cells and 120 seconds of input per pass. An explicit
`--cohort-size 1...16` can reduce the count, not enlarge those bounds.

Each cohort runs sequentially in a **fresh process with two local passes**.
Engine preparation therefore restarts at cohort boundaries; compare rows by
their recorded runtime state rather than treating every first cell as a
controlled cold-cache measurement. This condition does not qualify a long
single-process stress run or repair a backend failure that such a run reveals.

`matrix-request.json` records every planned cohort before execution. Each
`cohort-NNNN` directory retains its request, model receipt when available and
terminal outcome. The first non-observed cohort stops execution without retry;
an interrupted child cannot delete earlier completed cohorts. An interrupted
matrix without `matrix-outcome.json` is incomplete, not implicitly successful.
An unfinished cohort still has no admitted per-cell completion count.

The final matrix receipt revalidates the original executable, audio and all
completed cohort files. It reports selected versus observed cells and whether
the full public corpus was selected, never accepted quality or verified
insertion. Files are create-only and owner-only; a new attempt needs a new
output directory. Keep failed attempts instead of replacing them with a later
green result. Neither raw child output nor transcript text is exported.
