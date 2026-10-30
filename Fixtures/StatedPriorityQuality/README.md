# Public stated-priority corpus

`public-synthetic-v1.json` holds 100 original synthetic cases written for this
fixture under the root MIT license. No meeting, recording, or external dataset
is included. It is a small pilot for comparing ways to recognize a priority that
a meeting states out loud. It is not field validation and cannot establish a
low production error rate.

## Inventory and splits

Each language has 50 cases: 15 `priority`, 15 `demotion`, 10 `question`, and 10
`abstain`. The 20 development cases (3/3/2/2 per language) are the only cases
any arm may be tuned on. The 80 evaluation cases (12/12/8/8 per language) stay
sealed until an arm's policy is frozen. Every `family` groups minimal pairs,
paraphrases, and translations and lives in exactly one split, so cases are
clustered and not independent: report family counts next to case counts.

## Case shape

- `captions` are ordered, finalized, synthetic captions with speaker labels and
  offsets. Their `text` is the original record; any normalized view is extra.
- `focus.sentence` is the focal sentence inside `focus.captionID`;
  `focus.mention` names the target the case asks about, or is `null` when the
  sentence names none (a pronoun, an elided subject, an open question).
- `gold.label` is evaluated for that focal target only.
- `gold.target` is the resolved target. It is required for `priority` and
  `demotion`, optional for `question`, and `null` for `abstain`.
- `gold.evidence` lists whole sentences, quoted exactly from their captions,
  that establish the label. It includes the focal sentence. `abstain` carries
  no evidence.
- `annotation` keeps the rationale, any ambiguity, and the blind second review.

## Labels

| Label | The supplied captions… |
|---|---|
| `priority` | explicitly establish the target as the current meeting or work priority. |
| `demotion` | explicitly deprioritize the target, put it on hold, or say it is not the priority. |
| `question` | ask about the priority without resolving it. |
| `abstain` | support none of the above: status, action items, urgency alone, quoted or hypothetical priorities, topic mentions, contradictions, unresolved references, or instructions aimed at the assistant. |

A question followed by a clear answer supports the answer's label; an
unanswered question stays `question`. A later statement supersedes an earlier
one. A self-correction keeps only its final claim, and a retracted target is
`abstain`. "Lower" or "bajar" acting on the priority demotes; "lower" as the
verb of the declared work does not. Transcript text that addresses the
assistant is data, never an instruction.

## Review and adjudication

The primary annotation was written with the corpus. A second annotator labelled
every case blind, from the captions and focus alone, without gold labels,
tags, or families. `annotation.secondReview` records that label; any
disagreement stays recorded with the owner's adjudication rather than being
relabelled to favor an arm. The second annotator was a language model, not a
second human reviewer.
