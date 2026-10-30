import contextlib
import copy
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "stated_priority_quality.py"
SPEC = importlib.util.spec_from_file_location("stated_priority_quality", SCRIPT)
quality = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(quality)
FIXTURE = ROOT / "Fixtures" / "StatedPriorityQuality" / "public-synthetic-v1.json"
Error = quality.StatedPriorityQualityError


def gold_echo(case, probabilities=None):
    gold = case["gold"]
    if gold["label"] == "abstain":
        return quality.observation(case["id"], "abstain", "classified-neutral", probabilities=probabilities)
    return quality.observation(
        case["id"], gold["label"], target=gold["target"], evidence=gold["evidence"],
        probabilities=probabilities,
    )


def peaked(label, confidence):
    rest = round((1 - confidence) / 3, 6)
    return {name: confidence if name == label else rest for name in quality.LABELS}


class StatedPriorityQualityTests(unittest.TestCase):
    def fixture(self):
        return quality.validate_fixture(quality.load_json(FIXTURE, "fixture"))

    def document(self, fixture, split, observations, arm="test-arm"):
        return quality.observations_document(fixture, split, arm, observations)

    def echo_document(self, fixture, split):
        return self.document(fixture, split, [gold_echo(case) for case in quality.split_cases(fixture, split)])

    def case_with_label(self, fixture, split, label):
        return next(case for case in quality.split_cases(fixture, split) if case["gold"]["label"] == label)

    def replace(self, document, replacement):
        document["observations"] = [
            replacement if item["id"] == replacement["id"] else item for item in document["observations"]
        ]
        return document

    def test_canonical_fixture_is_balanced_by_language_split_and_label(self):
        fixture = self.fixture()

        distribution = Counter(
            (case["language"], case["split"], case["gold"]["label"]) for case in fixture["cases"]
        )

        expected = {}
        for language in ("en", "es"):
            expected.update({
                (language, "development", "priority"): 3,
                (language, "development", "demotion"): 3,
                (language, "development", "question"): 2,
                (language, "development", "abstain"): 2,
                (language, "evaluation", "priority"): 12,
                (language, "evaluation", "demotion"): 12,
                (language, "evaluation", "question"): 8,
                (language, "evaluation", "abstain"): 8,
            })
        self.assertEqual(distribution, Counter(expected))
        self.assertEqual(fixture["contentSource"], "public-synthetic-only")

    def test_fixture_keeps_every_withdrawn_detector_failure_as_a_case(self):
        fixture = self.fixture()
        by_sentence = {
            (case["focus"]["sentence"], case["gold"]["label"]): case for case in fixture["cases"]
        }

        regressions = {
            ("La prioridad es baja.", "demotion"): "el rediseño del tablero",
            ("The dashboard doesn’t come first.", "demotion"): "The dashboard",
            ("The priority is the dashboard.", "priority"): "the dashboard",
            ("Cerrar el reporte, es la prioridad.", "priority"): "Cerrar el reporte",
            ("The migration that Ana started is our top priority.", "priority"):
                "The migration that Ana started",
        }

        for key, target in regressions.items():
            with self.subTest(sentence=key[0]):
                self.assertIn(key, by_sentence)
                self.assertEqual(by_sentence[key]["gold"]["target"]["quote"], target)
        same_caption = by_sentence[("The priority is the dashboard.", "priority")]
        self.assertEqual(len(same_caption["captions"]), 1)

    def test_fixture_rejects_a_family_that_crosses_splits(self):
        broken = copy.deepcopy(self.fixture())
        development = self.case_with_label(broken, "development", "priority")
        evaluation = self.case_with_label(broken, "evaluation", "priority")
        evaluation["family"] = development["family"]

        with self.assertRaisesRegex(Error, "families cross splits"):
            quality.validate_fixture(broken)

    def test_fixture_rejects_abstain_truth_that_carries_evidence(self):
        broken = copy.deepcopy(self.fixture())
        case = self.case_with_label(broken, "evaluation", "abstain")
        case["gold"]["evidence"] = [{"captionID": case["focus"]["captionID"], "quote": case["focus"]["sentence"]}]

        with self.assertRaisesRegex(Error, "abstain truth"):
            quality.validate_fixture(broken)

    def test_fixture_rejects_a_target_outside_its_evidence(self):
        broken = copy.deepcopy(self.fixture())
        case = next(
            case for case in broken["cases"]
            if case["gold"]["label"] == "demotion" and len(case["gold"]["evidence"]) == 2
        )
        case["gold"]["evidence"] = [
            span for span in case["gold"]["evidence"] if span["captionID"] != case["gold"]["target"]["captionID"]
        ]

        with self.assertRaisesRegex(Error, "target must lie inside its evidence"):
            quality.validate_fixture(broken)

    def test_fixture_rejects_a_focus_mention_that_is_not_the_gold_target(self):
        broken = copy.deepcopy(self.fixture())
        retracted = next(
            case for case in broken["cases"]
            if case["gold"]["label"] == "abstain" and "self-correction" in case["tags"]
        )
        declared = next(
            case for case in broken["cases"]
            if case["family"] == retracted["family"] and case["gold"]["label"] == "priority"
        )
        declared["focus"]["mention"] = retracted["focus"]["mention"]

        with self.assertRaisesRegex(Error, "focus mention must be the gold target"):
            quality.validate_fixture(broken)

    def test_fixture_rejects_a_disagreement_without_adjudication(self):
        broken = copy.deepcopy(self.fixture())
        case = self.case_with_label(broken, "evaluation", "demotion")
        case["annotation"]["secondReview"]["label"] = "priority"

        with self.assertRaisesRegex(Error, "secondReview.adjudication"):
            quality.validate_fixture(broken)
        case["annotation"]["secondReview"]["adjudication"] = "Owner kept demotion."
        quality.validate_fixture(broken)

    def test_no_proposal_control_promotes_nothing_and_earns_no_credit(self):
        fixture = self.fixture()

        scorecard = quality.score(fixture, "evaluation", quality.no_proposal_observations(fixture, "evaluation"))

        self.assertEqual(scorecard["arm"], "no-proposal-control-v1")
        self.assertEqual(scorecard["counts"]["unsafePromotions"], 0)
        self.assertEqual(scorecard["metrics"]["accuracy"], {"count": 0, "total": 80, "rate": 0.0})
        self.assertEqual(scorecard["metrics"]["coverage"]["count"], 0)
        self.assertEqual(scorecard["abstentionReasons"], {"disabled": 80})
        self.assertEqual(scorecard["confusion"]["abstain"]["refused"], 16)
        self.assertEqual(scorecard["confusion"]["abstain"]["abstain"], 0)

    def test_gold_echo_scores_every_metric_as_perfect(self):
        fixture = self.fixture()

        scorecard = quality.score(fixture, "evaluation", self.echo_document(fixture, "evaluation"))

        metrics = scorecard["metrics"]
        self.assertEqual(metrics["accuracy"]["rate"], 1.0)
        self.assertEqual(metrics["macroF1"], 1.0)
        self.assertEqual(metrics["priorityRecall"]["count"], 24)
        self.assertEqual(metrics["priorityPrecision"]["rate"], 1.0)
        self.assertEqual(metrics["unsafePromotion"]["count"], 0)
        self.assertEqual(metrics["coverage"]["count"], 64)
        self.assertEqual(metrics["selectiveError"]["count"], 0)
        for key in ("targetExact", "evidenceExact", "evidenceCaptionExact"):
            with self.subTest(metric=key):
                self.assertEqual(metrics[key]["rate"], 1.0)
        self.assertEqual(scorecard["qualityDecision"], "review-required")
        self.assertEqual(scorecard["productDecision"], "not-evaluated")

    def test_demotion_and_question_promoted_to_priority_count_as_unsafe(self):
        fixture = self.fixture()
        document = self.echo_document(fixture, "evaluation")
        for label in ("demotion", "question"):
            case = self.case_with_label(fixture, "evaluation", label)
            self.replace(document, quality.observation(
                case["id"], "priority", target=case["gold"]["target"], evidence=case["gold"]["evidence"],
            ))

        scorecard = quality.score(fixture, "evaluation", document)

        self.assertEqual(scorecard["counts"]["unsafePromotions"], 2)
        self.assertEqual(scorecard["counts"]["demotionToPriority"], 1)
        self.assertEqual(scorecard["counts"]["questionToPriority"], 1)
        self.assertEqual(scorecard["metrics"]["unsafePromotion"]["total"], 56)
        self.assertEqual(scorecard["metrics"]["priorityPrecision"], {"count": 24, "total": 26, "rate": 0.923077})

    def test_claim_with_invented_evidence_is_refused_not_promoted(self):
        fixture = self.fixture()
        case = self.case_with_label(fixture, "evaluation", "demotion")
        document = self.replace(self.echo_document(fixture, "evaluation"), quality.observation(
            case["id"], "priority", target=case["gold"]["target"],
            evidence=[{"captionID": "c9", "quote": "Invented support."}],
        ))

        scorecard = quality.score(fixture, "evaluation", document)

        row = next(item for item in scorecard["cases"] if item["id"] == case["id"])
        self.assertEqual((row["decision"], row["reason"], row["outcome"]), ("abstain", "invalid-output", "refused"))
        self.assertTrue(row["unsupportedEvidence"])
        self.assertEqual(scorecard["counts"]["unsafePromotions"], 0)
        self.assertEqual(scorecard["counts"]["technicalFailures"], 1)

    def test_claim_whose_evidence_misses_the_focus_or_the_target_is_refused(self):
        fixture = self.fixture()
        case = next(
            case for case in quality.split_cases(fixture, "evaluation")
            if case["gold"]["label"] == "demotion" and case["focus"]["mention"] is None
        )
        target = case["gold"]["target"]
        context_only = [span for span in case["gold"]["evidence"] if span["captionID"] == target["captionID"]]
        focus_only = [span for span in case["gold"]["evidence"] if span["captionID"] == case["focus"]["captionID"]]
        self.assertNotEqual(target["captionID"], case["focus"]["captionID"])

        for name, evidence in {"misses the focus": context_only, "misses the target": focus_only}.items():
            document = self.replace(self.echo_document(fixture, "evaluation"), quality.observation(
                case["id"], "demotion", target=target, evidence=evidence,
            ))
            row = next(item for item in quality.score(fixture, "evaluation", document)["cases"]
                       if item["id"] == case["id"])
            with self.subTest(name):
                self.assertEqual((row["reason"], row["unsupportedEvidence"]), ("invalid-output", True))

    def test_abstention_with_malformed_probabilities_fails_closed(self):
        fixture = self.fixture()
        case = self.case_with_label(fixture, "evaluation", "abstain")
        malformed = {label: "high" for label in quality.LABELS}
        document = self.replace(
            self.echo_document(fixture, "evaluation"),
            quality.observation(case["id"], "abstain", "low-confidence", probabilities=malformed),
        )

        scorecard = quality.score(fixture, "evaluation", document)

        row = next(item for item in scorecard["cases"] if item["id"] == case["id"])
        self.assertEqual((row["reason"], row["outcome"], row["confidence"]), ("invalid-output", "refused", None))
        self.assertEqual(scorecard["counts"]["technicalFailures"], 1)

    def test_target_and_evidence_exactness_are_judged_apart_from_the_label(self):
        fixture = self.fixture()
        case = self.case_with_label(fixture, "evaluation", "demotion")
        document = self.replace(self.echo_document(fixture, "evaluation"), quality.observation(
            case["id"], "question", target=case["gold"]["target"], evidence=case["gold"]["evidence"],
        ))

        metrics = quality.score(fixture, "evaluation", document)["metrics"]

        self.assertEqual(metrics["accuracy"]["count"], 79)
        self.assertEqual(metrics["targetExact"]["rate"], 1.0)
        self.assertEqual(metrics["evidenceExact"]["rate"], 1.0)

    def test_decision_that_contradicts_its_probabilities_is_counted(self):
        fixture = self.fixture()
        case = self.case_with_label(fixture, "evaluation", "priority")
        document = self.replace(
            self.echo_document(fixture, "evaluation"), gold_echo(case, peaked("abstain", 0.7)),
        )

        counts = quality.score(fixture, "evaluation", document)["counts"]

        self.assertEqual(counts["probabilityDisagreements"], 1)

    def test_probabilities_that_do_not_sum_to_one_are_refused(self):
        fixture = self.fixture()
        case = self.case_with_label(fixture, "evaluation", "priority")
        broken = {"priority": 0.9, "demotion": 0.5, "question": 0.05, "abstain": 0.05}
        document = self.replace(self.echo_document(fixture, "evaluation"), gold_echo(case, broken))

        scorecard = quality.score(fixture, "evaluation", document)

        row = next(item for item in scorecard["cases"] if item["id"] == case["id"])
        self.assertEqual(row["reason"], "invalid-output")
        self.assertIsNone(row["confidence"])

    def test_only_a_neutral_classification_earns_credit_on_gold_abstain(self):
        fixture = self.fixture()
        case = self.case_with_label(fixture, "evaluation", "abstain")
        outcomes = {}
        for reason in ("classified-neutral", "low-confidence", "timeout"):
            document = self.replace(
                self.echo_document(fixture, "evaluation"),
                quality.observation(case["id"], "abstain", reason),
            )
            row = next(item for item in quality.score(fixture, "evaluation", document)["cases"]
                       if item["id"] == case["id"])
            outcomes[reason] = row["correct"]

        self.assertEqual(outcomes, {"classified-neutral": True, "low-confidence": False, "timeout": False})

    def test_observation_contract_fails_closed(self):
        fixture = self.fixture()
        cases = quality.split_cases(fixture, "development")
        priority = self.case_with_label(fixture, "development", "priority")
        abstain_with_evidence = quality.observation(priority["id"], "abstain", "low-confidence")
        abstain_with_evidence["evidence"] = priority["gold"]["evidence"]
        failures = {
            "one entry per split case": [gold_echo(case) for case in cases[:-1]],
            "outside the split": [gold_echo(case) for case in cases[:-1]]
                + [gold_echo(self.case_with_label(fixture, "evaluation", "priority"))],
            "must not carry a target or evidence": [
                abstain_with_evidence if case["id"] == priority["id"] else gold_echo(case) for case in cases
            ],
            "reason is only valid": [
                quality.observation(case["id"], "question", "timeout") if case is cases[0] else gold_echo(case)
                for case in cases
            ],
        }
        for message, observations in failures.items():
            with self.subTest(message=message), self.assertRaisesRegex(Error, message):
                quality.validate_observations(self.document(fixture, "development", observations), fixture, "development")

        foreign = self.echo_document(fixture, "development")
        foreign["fixtureSHA256"] = "0" * 64
        with self.assertRaisesRegex(Error, "different fixture"):
            quality.validate_observations(foreign, fixture, "development")
        with self.assertRaisesRegex(Error, "different split"):
            quality.validate_observations(self.echo_document(fixture, "development"), fixture, "evaluation")

    def test_risk_coverage_orders_decisions_by_confidence(self):
        fixture = self.fixture()
        cases = quality.split_cases(fixture, "development")
        decided = [case for case in cases if case["gold"]["label"] != "abstain"]
        wrong = decided[0]
        observations = []
        for case in cases:
            if case is wrong:
                wrong_label = "question" if case["gold"]["label"] != "question" else "demotion"
                observations.append(quality.observation(
                    case["id"], wrong_label, target=case["gold"]["target"],
                    evidence=case["gold"]["evidence"], probabilities=peaked(wrong_label, 0.4),
                ))
            else:
                observations.append(gold_echo(case, peaked(case["gold"]["label"], 0.7)))

        curve = quality.score(fixture, "development", self.document(fixture, "development", observations))["riskCoverage"]

        self.assertEqual([point["threshold"] for point in curve], [0.7, 0.4])
        self.assertEqual(curve[0]["selectiveError"], {"count": 0, "total": len(decided) - 1, "rate": 0.0})
        self.assertEqual(curve[1]["coverage"], {"count": len(decided), "total": 20, "rate": 0.8})
        self.assertEqual(curve[1]["selectiveError"]["count"], 1)

    def test_zero_observed_failures_still_report_a_nonzero_upper_bound(self):
        z_squared = quality.WILSON_Z ** 2

        interval = quality.wilson_interval(0, 56)

        self.assertEqual(interval, [0.0, round(z_squared / (56 + z_squared), 6)])
        self.assertIsNone(quality.wilson_interval(0, 0))

    def test_comparison_pairs_cases_and_never_selects_a_winner(self):
        fixture = self.fixture()

        comparison = quality.compare(
            fixture,
            "development",
            quality.no_proposal_observations(fixture, "development"),
            self.echo_document(fixture, "development"),
        )

        self.assertEqual(comparison["paired"]["rightOnlyCorrect"]["count"], 20)
        self.assertEqual(comparison["paired"]["leftOnlyCorrect"]["count"], 0)
        self.assertEqual(comparison["unsafePromotions"], {"left": [], "right": []})
        self.assertEqual(comparison["winner"], "not-evaluated")
        with self.assertRaisesRegex(Error, "different split"):
            quality.compare(
                fixture, "evaluation",
                quality.no_proposal_observations(fixture, "development"),
                self.echo_document(fixture, "development"),
            )

    def test_cli_scores_control_observations_from_a_file(self):
        with tempfile.TemporaryDirectory() as directory:
            observations = Path(directory) / "control.json"
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                quality.main(["control", "--fixture", str(FIXTURE), "--split", "development"])
            observations.write_text(output.getvalue(), encoding="utf-8")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = quality.main([
                    "score", "--fixture", str(FIXTURE), "--split", "development",
                    "--observations", str(observations),
                ])

        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output.getvalue())["counts"]["cases"], 20)

    def test_make_control_target_emits_one_json_scorecard(self):
        result = subprocess.run(
            ["make", "--no-print-directory", "stated-priority-quality-control"],
            cwd=ROOT, check=True, capture_output=True, text=True,
        )
        document = json.loads(result.stdout)

        self.assertEqual(document["kind"], quality.SCORECARD_KIND)
        self.assertEqual(document["split"], "development")


if __name__ == "__main__":
    unittest.main()
