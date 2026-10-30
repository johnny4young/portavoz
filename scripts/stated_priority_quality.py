#!/usr/bin/env python3
"""Arm-neutral, public-fixture scoring for stated-priority classification."""

import argparse
import hashlib
import json
import math
import re
import sys
from collections import Counter
from pathlib import Path


SCHEMA_VERSION = 1
FIXTURE_KIND = "stated-priority-quality-fixture"
OBSERVATIONS_KIND = "stated-priority-observations"
SCORECARD_KIND = "stated-priority-quality-scorecard"
COMPARISON_KIND = "stated-priority-quality-comparison"
PUBLIC_GENERATION = "public-synthetic-v1"
PUBLIC_SOURCE = "public-synthetic-only"
CONTROL_ARM = "no-proposal-control-v1"
LANGUAGES = ("en", "es")
LABELS = ("priority", "demotion", "question", "abstain")
# Any abstention not classified as neutral speech is scored as `refused`, so a
# disabled or failed arm never earns credit on the gold `abstain` cases.
OUTCOMES = LABELS + ("refused",)
SPLITS = ("development", "evaluation")
EXPECTED_COUNTS = {
    "development": {"priority": 3, "demotion": 3, "question": 2, "abstain": 2},
    "evaluation": {"priority": 12, "demotion": 12, "question": 8, "abstain": 8},
}
TAGS = frozenset({
    "accents", "action-item-only", "apostrophe-curly", "apostrophe-straight",
    "asr-comma", "casing", "competing-targets", "contraction", "contradiction",
    "descriptive", "double-negation", "filler", "hypothetical", "imperative",
    "lower-ambiguity", "negation-scope", "no-punctuation", "prompt-injection",
    "question-answered", "question-unanswered", "quoted-third-party",
    "relative-clause", "same-caption-qa", "self-correction", "spanish-demotion",
    "split-caption", "status-only", "superseded", "topic-mention",
    "unclear-antecedent", "urgency-only",
})
# `classified-neutral` is a recognized absence of priority speech; every other
# reason is a policy refusal or a technical failure and must stay distinguishable.
ABSTAIN_REASONS = (
    "classified-neutral", "low-confidence", "small-margin", "conflicting-evidence",
    "missing-context", "invalid-output", "truncation", "timeout",
    "runtime-unavailable", "disabled",
)
TECHNICAL_REASONS = frozenset({"invalid-output", "truncation", "timeout", "runtime-unavailable"})
SAFE_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
PROBABILITY_SUM_TOLERANCE = 1e-3
WILSON_Z = 1.959964


class StatedPriorityQualityError(ValueError):
    """Fail-closed fixture, observation, or comparison error."""


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise StatedPriorityQualityError(f"duplicate key: {key}")
        result[key] = value
    return result


def load_json(path, label, maximum_bytes=2 * 1024 * 1024):
    try:
        if path == "-":
            raw = sys.stdin.buffer.read(maximum_bytes + 1)
        else:
            path = Path(path).expanduser()
            if not path.is_file():
                raise StatedPriorityQualityError(f"{label} not found: {path}")
            raw = path.read_bytes()
        if len(raw) > maximum_bytes:
            raise StatedPriorityQualityError(f"{label} exceeds the size limit")
        return json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except OSError as error:
        raise StatedPriorityQualityError(f"{label} could not be read: {path}") from error
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise StatedPriorityQualityError(f"{label} is not valid UTF-8 JSON") from error


def exact_object(value, path, keys):
    if not isinstance(value, dict):
        raise StatedPriorityQualityError(f"{path} must be an object")
    if set(value) != set(keys):
        raise StatedPriorityQualityError(f"{path} must contain exactly: {', '.join(sorted(keys))}")
    return value


def safe_id(value, path):
    if not isinstance(value, str) or SAFE_ID.fullmatch(value) is None:
        raise StatedPriorityQualityError(f"{path} has an unsafe value")
    return value


def bounded_text(value, path, maximum=500):
    if not isinstance(value, str) or not value.strip() or len(value) > maximum or "\x00" in value:
        raise StatedPriorityQualityError(f"{path} must contain 1 to {maximum} safe characters")
    return value


def nonnegative_integer(value, path):
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise StatedPriorityQualityError(f"{path} must be a nonnegative integer")
    return value


def span_object(value, path):
    exact_object(value, path, {"captionID", "quote"})
    safe_id(value["captionID"], f"{path}.captionID")
    bounded_text(value["quote"], f"{path}.quote")
    return value


def quoted_once(span, captions_by_id):
    caption = captions_by_id.get(span["captionID"])
    return caption is not None and caption["text"].count(span["quote"]) == 1


def validate_captions(captions, path):
    if not isinstance(captions, list) or not 1 <= len(captions) <= 6:
        raise StatedPriorityQualityError(f"{path} must contain 1 to 6 captions")
    by_id = {}
    previous_start = -1
    for index, caption in enumerate(captions):
        caption_path = f"{path}[{index}]"
        exact_object(caption, caption_path, {"id", "speaker", "startMs", "endMs", "final", "text"})
        caption_id = safe_id(caption["id"], f"{caption_path}.id")
        if caption_id in by_id:
            raise StatedPriorityQualityError(f"{path} contains duplicate caption ids")
        bounded_text(caption["speaker"], f"{caption_path}.speaker", 80)
        start = nonnegative_integer(caption["startMs"], f"{caption_path}.startMs")
        end = nonnegative_integer(caption["endMs"], f"{caption_path}.endMs")
        if end <= start or start < previous_start:
            raise StatedPriorityQualityError(f"{caption_path} offsets are not ordered")
        if not isinstance(caption["final"], bool):
            raise StatedPriorityQualityError(f"{caption_path}.final must be boolean")
        bounded_text(caption["text"], f"{caption_path}.text")
        previous_start = start
        by_id[caption_id] = caption
    return by_id


def validate_case(case, path):
    exact_object(
        case,
        path,
        {"id", "family", "language", "split", "tags", "captions", "focus", "gold", "annotation"},
    )
    safe_id(case["id"], f"{path}.id")
    safe_id(case["family"], f"{path}.family")
    if case["language"] not in LANGUAGES:
        raise StatedPriorityQualityError(f"{path}.language is invalid")
    if case["split"] not in SPLITS:
        raise StatedPriorityQualityError(f"{path}.split is invalid")
    tags = case["tags"]
    if not isinstance(tags, list) or not tags or len(set(tags)) != len(tags) or not set(tags) <= TAGS:
        raise StatedPriorityQualityError(f"{path}.tags must be unique known tags")
    captions = validate_captions(case["captions"], f"{path}.captions")

    focus = exact_object(case["focus"], f"{path}.focus", {"captionID", "sentence", "mention"})
    sentence_span = {"captionID": focus["captionID"], "quote": focus["sentence"]}
    span_object(sentence_span, f"{path}.focus")
    if not quoted_once(sentence_span, captions):
        raise StatedPriorityQualityError(f"{path}.focus sentence must occur once in its caption")
    if focus["mention"] is not None:
        bounded_text(focus["mention"], f"{path}.focus.mention", 120)
        if focus["sentence"].count(focus["mention"]) != 1:
            raise StatedPriorityQualityError(f"{path}.focus mention must occur once in the sentence")

    gold = exact_object(case["gold"], f"{path}.gold", {"label", "target", "evidence"})
    label = gold["label"]
    if label not in LABELS:
        raise StatedPriorityQualityError(f"{path}.gold.label is invalid")
    evidence = gold["evidence"]
    if not isinstance(evidence, list) or len(evidence) > 6:
        raise StatedPriorityQualityError(f"{path}.gold.evidence must be a bounded array")
    for index, span in enumerate(evidence):
        span_object(span, f"{path}.gold.evidence[{index}]")
        if not quoted_once(span, captions):
            raise StatedPriorityQualityError(f"{path}.gold.evidence[{index}] must occur once in its caption")
    if len({(span["captionID"], span["quote"]) for span in evidence}) != len(evidence):
        raise StatedPriorityQualityError(f"{path}.gold.evidence contains duplicates")
    target = gold["target"]
    if label == "abstain":
        if target is not None or evidence:
            raise StatedPriorityQualityError(f"{path} abstain truth must not carry a target or evidence")
    else:
        if not evidence or sentence_span not in evidence:
            raise StatedPriorityQualityError(f"{path} evidence must include the focal sentence")
        if target is None and label != "question":
            raise StatedPriorityQualityError(f"{path} {label} truth requires a target")
    if target is not None:
        span_object(target, f"{path}.gold.target")
        if not quoted_once(target, captions) or not any(
            span["captionID"] == target["captionID"] and target["quote"] in span["quote"]
            for span in evidence
        ):
            raise StatedPriorityQualityError(f"{path}.gold.target must lie inside its evidence")

    annotation = exact_object(
        case["annotation"], f"{path}.annotation", {"rationale", "ambiguity", "secondReview"}
    )
    bounded_text(annotation["rationale"], f"{path}.annotation.rationale", 300)
    if annotation["ambiguity"] is not None:
        bounded_text(annotation["ambiguity"], f"{path}.annotation.ambiguity", 300)
    review = exact_object(
        annotation["secondReview"], f"{path}.annotation.secondReview", {"label", "adjudication"}
    )
    if review["label"] not in LABELS:
        raise StatedPriorityQualityError(f"{path}.annotation.secondReview.label is invalid")
    if review["label"] == label:
        if review["adjudication"] is not None:
            raise StatedPriorityQualityError(f"{path} agreeing review must not carry an adjudication")
    else:
        bounded_text(review["adjudication"], f"{path}.annotation.secondReview.adjudication", 300)


def validate_fixture(document):
    exact_object(document, "fixture", {"schemaVersion", "kind", "generation", "contentSource", "cases"})
    if document["schemaVersion"] != SCHEMA_VERSION:
        raise StatedPriorityQualityError("fixture schemaVersion is unsupported")
    if document["kind"] != FIXTURE_KIND:
        raise StatedPriorityQualityError("fixture kind is invalid")
    if document["generation"] != PUBLIC_GENERATION:
        raise StatedPriorityQualityError("fixture generation is not canonical")
    if document["contentSource"] != PUBLIC_SOURCE:
        raise StatedPriorityQualityError("fixture must contain only public synthetic material")
    cases = document["cases"]
    if not isinstance(cases, list) or len(cases) != 100:
        raise StatedPriorityQualityError("canonical fixture must contain exactly 100 cases")

    seen = set()
    family_splits = {}
    distribution = Counter()
    for index, case in enumerate(cases):
        validate_case(case, f"cases[{index}]")
        if case["id"] in seen:
            raise StatedPriorityQualityError(f"duplicate case id: {case['id']}")
        seen.add(case["id"])
        family_splits.setdefault(case["family"], set()).add(case["split"])
        distribution[(case["language"], case["split"], case["gold"]["label"])] += 1

    expected = Counter({
        (language, split, label): count
        for language in LANGUAGES
        for split, counts in EXPECTED_COUNTS.items()
        for label, count in counts.items()
    })
    if distribution != expected:
        raise StatedPriorityQualityError("fixture language, split, or label distribution is invalid")
    leaking = sorted(family for family, splits in family_splits.items() if len(splits) > 1)
    if leaking:
        raise StatedPriorityQualityError(f"families cross splits: {', '.join(leaking)}")
    return document


def digest(document):
    encoded = json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def split_cases(fixture, split):
    if split not in SPLITS:
        raise StatedPriorityQualityError("split must be development or evaluation")
    return [case for case in fixture["cases"] if case["split"] == split]


def observation(case_id, decision, reason=None, target=None, evidence=(), probabilities=None):
    return {
        "id": case_id,
        "decision": decision,
        "reason": reason,
        "target": target,
        "evidence": list(evidence),
        "probabilities": probabilities,
    }


def observations_document(fixture, split, arm, observations):
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": OBSERVATIONS_KIND,
        "fixtureSHA256": digest(fixture),
        "split": split,
        "arm": arm,
        "observations": observations,
    }


def no_proposal_observations(fixture, split):
    return observations_document(
        fixture,
        split,
        CONTROL_ARM,
        [observation(case["id"], "abstain", "disabled") for case in split_cases(fixture, split)],
    )


def validate_observations(document, fixture, split):
    exact_object(
        document,
        "observations document",
        {"schemaVersion", "kind", "fixtureSHA256", "split", "arm", "observations"},
    )
    if document["schemaVersion"] != SCHEMA_VERSION or document["kind"] != OBSERVATIONS_KIND:
        raise StatedPriorityQualityError("observations schema is invalid")
    if document["fixtureSHA256"] != digest(fixture):
        raise StatedPriorityQualityError("observations describe a different fixture")
    if document["split"] != split:
        raise StatedPriorityQualityError("observations describe a different split")
    safe_id(document["arm"], "observations.arm")
    expected_ids = {case["id"] for case in split_cases(fixture, split)}
    values = document["observations"]
    if not isinstance(values, list) or len(values) != len(expected_ids):
        raise StatedPriorityQualityError("observations must contain exactly one entry per split case")
    seen = set()
    for index, value in enumerate(values):
        path = f"observations[{index}]"
        exact_object(value, path, {"id", "decision", "reason", "target", "evidence", "probabilities"})
        if value["id"] not in expected_ids or value["id"] in seen:
            raise StatedPriorityQualityError(f"{path}.id is missing, duplicate, or outside the split")
        seen.add(value["id"])
        if value["decision"] not in LABELS:
            raise StatedPriorityQualityError(f"{path}.decision is invalid")
        if value["decision"] == "abstain":
            if value["reason"] not in ABSTAIN_REASONS:
                raise StatedPriorityQualityError(f"{path}.reason must be a known abstention reason")
            if value["target"] is not None or value["evidence"]:
                raise StatedPriorityQualityError(f"{path} abstention must not carry a target or evidence")
        elif value["reason"] is not None:
            raise StatedPriorityQualityError(f"{path}.reason is only valid for an abstention")
        if value["target"] is not None:
            span_object(value["target"], f"{path}.target")
        if not isinstance(value["evidence"], list) or len(value["evidence"]) > 8:
            raise StatedPriorityQualityError(f"{path}.evidence must be a bounded array")
        for span_index, span in enumerate(value["evidence"]):
            span_object(span, f"{path}.evidence[{span_index}]")
        probabilities = value["probabilities"]
        if probabilities is not None and (
            not isinstance(probabilities, dict) or set(probabilities) != set(LABELS)
        ):
            raise StatedPriorityQualityError(f"{path}.probabilities must name every label")
    return {value["id"]: value for value in values}


def valid_probabilities(probabilities):
    if probabilities is None:
        return True
    values = list(probabilities.values())
    if any(
        isinstance(value, bool) or not isinstance(value, (int, float))
        or not math.isfinite(value) or not 0 <= value <= 1
        for value in values
    ):
        return False
    return abs(sum(values) - 1) <= PROBABILITY_SUM_TOLERANCE


def admit(case, value):
    """Return the admitted decision, reason, and whether the claim was unsupported."""
    if value["decision"] == "abstain":
        return "abstain", value["reason"], False
    captions = {caption["id"]: caption for caption in case["captions"]}
    target = value["target"]
    grounded = (
        bool(value["evidence"])
        and all(span["captionID"] in captions and span["quote"] in captions[span["captionID"]]["text"]
                for span in value["evidence"])
        and (target is not None or value["decision"] == "question")
        and (target is None or (
            target["captionID"] in captions and target["quote"] in captions[target["captionID"]]["text"]
        ))
        and valid_probabilities(value["probabilities"])
    )
    if not grounded:
        return "abstain", "invalid-output", True
    return value["decision"], None, False


def wilson_interval(successes, total):
    if total == 0:
        return None
    proportion = successes / total
    denominator = 1 + WILSON_Z ** 2 / total
    center = (proportion + WILSON_Z ** 2 / (2 * total)) / denominator
    margin = WILSON_Z * math.sqrt(
        proportion * (1 - proportion) / total + WILSON_Z ** 2 / (4 * total ** 2)
    ) / denominator
    return [round(max(0.0, center - margin), 6), round(min(1.0, center + margin), 6)]


def fraction(count, total, interval=False):
    result = {"count": count, "total": total, "rate": round(count / total, 6) if total else None}
    if interval:
        result["interval95"] = wilson_interval(count, total)
    return result


def macro_f1(outcomes):
    scores = []
    for label in LABELS:
        true_positive = sum(1 for gold, decision in outcomes if gold == label and decision == label)
        predicted = sum(1 for _, decision in outcomes if decision == label)
        actual = sum(1 for gold, _ in outcomes if gold == label)
        if true_positive == 0:
            scores.append(0.0)
            continue
        precision = true_positive / predicted
        recall = true_positive / actual
        scores.append(2 * precision * recall / (precision + recall))
    return round(sum(scores) / len(scores), 6)


def summarize(rows):
    gold_priority = [row for row in rows if row["gold"] == "priority"]
    gold_other = [row for row in rows if row["gold"] != "priority"]
    decided = [row for row in rows if row["decision"] != "abstain"]
    return {
        "cases": len(rows),
        "accuracy": fraction(sum(row["correct"] for row in rows), len(rows)),
        "coverage": fraction(len(decided), len(rows)),
        "priorityRecall": fraction(
            sum(row["decision"] == "priority" for row in gold_priority), len(gold_priority), interval=True
        ),
        "unsafePromotion": fraction(
            sum(row["unsafePromotion"] for row in gold_other), len(gold_other), interval=True
        ),
    }


def risk_coverage(rows):
    decided = [row for row in rows if row["decision"] != "abstain"]
    if not decided or any(row["confidence"] is None for row in decided):
        return None
    ordered = sorted(decided, key=lambda row: (-row["confidence"], row["id"]))
    points = []
    wrong = 0
    for index, row in enumerate(ordered, start=1):
        wrong += not row["correct"]
        if index == len(ordered) or ordered[index]["confidence"] != row["confidence"]:
            points.append({
                "threshold": row["confidence"],
                "coverage": fraction(index, len(rows)),
                "selectiveError": fraction(wrong, index),
            })
    return points


def case_rows(fixture, split, document):
    by_id = validate_observations(document, fixture, split)
    rows = []
    for case in split_cases(fixture, split):
        value = by_id[case["id"]]
        decision, reason, unsupported = admit(case, value)
        gold = case["gold"]
        outcome = "refused" if reason not in (None, "classified-neutral") else decision
        correct = outcome == gold["label"]
        probabilities = value["probabilities"]
        confidence = (
            round(max(probabilities.values()), 6)
            if probabilities is not None and not unsupported else None
        )
        evidence_keys = {(span["captionID"], span["quote"]) for span in value["evidence"]}
        rows.append({
            "id": case["id"],
            "family": case["family"],
            "language": case["language"],
            "tags": case["tags"],
            "gold": gold["label"],
            "decision": decision,
            "reason": reason,
            "outcome": outcome,
            "correct": correct,
            "unsafePromotion": decision == "priority" and gold["label"] != "priority",
            "hasTarget": gold["target"] is not None,
            "unsupportedEvidence": unsupported,
            "confidence": confidence,
            "targetExact": correct and gold["target"] is not None and value["target"] == gold["target"],
            "evidenceExact": correct and decision != "abstain" and evidence_keys == {
                (span["captionID"], span["quote"]) for span in gold["evidence"]
            },
            "evidenceCaptionExact": correct and decision != "abstain" and {
                span["captionID"] for span in value["evidence"]
            } == {span["captionID"] for span in gold["evidence"]},
        })
    return rows


def score(fixture, split, document):
    rows = case_rows(fixture, split, document)
    decided = [row for row in rows if row["decision"] != "abstain"]
    predicted_priority = [row for row in rows if row["decision"] == "priority"]
    targeted = [row for row in rows if row["gold"] != "abstain"]
    with_target = [row for row in rows if row["hasTarget"]]
    confusion = {gold: {outcome: 0 for outcome in OUTCOMES} for gold in LABELS}
    for row in rows:
        confusion[row["gold"]][row["outcome"]] += 1
    reasons = Counter(row["reason"] for row in rows if row["reason"] is not None)
    by_tag = {}
    for tag in sorted({tag for row in rows for tag in row["tags"]}):
        tagged = [row for row in rows if tag in row["tags"]]
        by_tag[tag] = {
            "cases": len(tagged),
            "correct": fraction(sum(row["correct"] for row in tagged), len(tagged)),
            "unsafePromotions": sum(row["unsafePromotion"] for row in tagged),
        }
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": SCORECARD_KIND,
        "fixtureGeneration": fixture["generation"],
        "fixtureSHA256": digest(fixture),
        "split": split,
        "arm": document["arm"],
        "observationsSHA256": digest(document),
        "qualityDecision": "review-required",
        "productDecision": "not-evaluated",
        "counts": {
            "cases": len(rows),
            "families": len({row["family"] for row in rows}),
            "decided": len(decided),
            "unsupportedEvidence": sum(row["unsupportedEvidence"] for row in rows),
            "technicalFailures": sum(count for reason, count in reasons.items() if reason in TECHNICAL_REASONS),
            "unsafePromotions": sum(row["unsafePromotion"] for row in rows),
            "demotionToPriority": confusion["demotion"]["priority"],
            "questionToPriority": confusion["question"]["priority"],
        },
        "confusion": confusion,
        "abstentionReasons": {reason: reasons[reason] for reason in ABSTAIN_REASONS if reasons[reason]},
        "metrics": {
            **summarize(rows),
            "macroF1": macro_f1([(row["gold"], row["outcome"]) for row in rows]),
            "priorityPrecision": fraction(
                sum(row["gold"] == "priority" for row in predicted_priority), len(predicted_priority)
            ),
            "selectiveError": fraction(sum(not row["correct"] for row in decided), len(decided)),
            "targetExact": fraction(sum(row["targetExact"] for row in with_target), len(with_target)),
            "evidenceExact": fraction(sum(row["evidenceExact"] for row in targeted), len(targeted)),
            "evidenceCaptionExact": fraction(
                sum(row["evidenceCaptionExact"] for row in targeted), len(targeted)
            ),
        },
        "byLanguage": {
            language: summarize([row for row in rows if row["language"] == language])
            for language in LANGUAGES
        },
        "byLabel": {
            label: {
                "recall": fraction(confusion[label][label], sum(confusion[label].values())),
                "refused": confusion[label]["refused"],
            }
            for label in LABELS
        },
        "byTag": by_tag,
        "riskCoverage": risk_coverage(rows),
        "cases": [
            {key: row[key] for key in (
                "id", "language", "gold", "decision", "reason", "outcome", "correct",
                "unsafePromotion", "unsupportedEvidence", "confidence",
            )}
            for row in rows
        ],
    }


def compare(fixture, split, left, right):
    left_rows = {row["id"]: row for row in case_rows(fixture, split, left)}
    right_rows = {row["id"]: row for row in case_rows(fixture, split, right)}
    paired = {"bothCorrect": [], "leftOnlyCorrect": [], "rightOnlyCorrect": [], "bothWrong": []}
    for case_id, left_row in left_rows.items():
        right_row = right_rows[case_id]
        key = {
            (True, True): "bothCorrect",
            (True, False): "leftOnlyCorrect",
            (False, True): "rightOnlyCorrect",
            (False, False): "bothWrong",
        }[(left_row["correct"], right_row["correct"])]
        paired[key].append(case_id)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": COMPARISON_KIND,
        "fixtureSHA256": digest(fixture),
        "split": split,
        "leftArm": left["arm"],
        "rightArm": right["arm"],
        "left": summarize(list(left_rows.values())),
        "right": summarize(list(right_rows.values())),
        "paired": {key: {"count": len(ids), "ids": ids} for key, ids in paired.items()},
        "unsafePromotions": {
            "left": [case_id for case_id, row in left_rows.items() if row["unsafePromotion"]],
            "right": [case_id for case_id, row in right_rows.items() if row["unsafePromotion"]],
        },
        "winner": "not-evaluated",
        "productDecision": "not-evaluated",
    }


def parser():
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate", help="validate the canonical fixture")
    validate.add_argument("--fixture", required=True)

    control = commands.add_parser("control", help="emit no-proposal control observations")
    control.add_argument("--fixture", required=True)
    control.add_argument("--split", choices=SPLITS, required=True)

    run = commands.add_parser("score", help="score one arm's observations")
    run.add_argument("--fixture", required=True)
    run.add_argument("--split", choices=SPLITS, required=True)
    run.add_argument("--observations", required=True, help="path, or - for stdin")

    comparison = commands.add_parser("compare", help="pair two arms case by case without a winner")
    comparison.add_argument("--fixture", required=True)
    comparison.add_argument("--split", choices=SPLITS, required=True)
    comparison.add_argument("--left", required=True)
    comparison.add_argument("--right", required=True)
    return root


def main(argv=None):
    args = parser().parse_args(argv)
    fixture = validate_fixture(load_json(args.fixture, "fixture"))
    if args.command == "validate":
        document = {
            "kind": FIXTURE_KIND,
            "generation": fixture["generation"],
            "cases": len(fixture["cases"]),
            "families": len({case["family"] for case in fixture["cases"]}),
            "secondReviewDisagreements": sum(
                case["annotation"]["secondReview"]["label"] != case["gold"]["label"]
                for case in fixture["cases"]
            ),
            "sha256": digest(fixture),
        }
    elif args.command == "control":
        document = no_proposal_observations(fixture, args.split)
    elif args.command == "score":
        document = score(fixture, args.split, load_json(args.observations, "observations"))
    else:
        document = compare(
            fixture,
            args.split,
            load_json(args.left, "left observations"),
            load_json(args.right, "right observations"),
        )
    print(json.dumps(document, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except StatedPriorityQualityError as error:
        print(f"stated priority quality error: {error}", file=sys.stderr)
        raise SystemExit(2)
