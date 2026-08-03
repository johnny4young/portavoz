import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "meeting_memory_graph_quality",
    ROOT / "scripts" / "meeting_memory_graph_quality.py",
)
quality = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(quality)


class MeetingMemoryGraphQualityTests(unittest.TestCase):
    def test_public_fixture_is_deterministic_and_balanced(self):
        first = quality.public_fixture()
        second = quality.public_fixture()

        self.assertEqual(first, second)
        validated = quality.validate_fixture(first)
        self.assertEqual(validated["caseCount"], 36)
        self.assertEqual(validated["jobCounts"], quality.JOB_COUNTS)
        self.assertEqual(
            validated["relationshipCounts"], quality.RELATIONSHIP_COUNTS
        )
        self.assertEqual(
            set(validated["abstentionReasonCounts"]),
            quality.ABSTENTION_REASONS,
        )
        self.assertTrue(
            all(value == 1 for value in validated["abstentionReasonCounts"].values())
        )
        self.assertEqual(
            validated["checksum"],
            "a69dc05321600191c90b92c27975f5584b0cdde8ff5515f3411ed5fb122e42b4",
        )

    def test_every_job_covers_bilingual_cross_lingual_and_abstention_queries(self):
        fixture = quality.public_fixture()
        by_job = {}
        for case in fixture["cases"]:
            by_job.setdefault(case["job"], set()).add(case["relationship"])

        self.assertEqual(set(by_job), set(quality.JOBS))
        for relationships in by_job.values():
            self.assertEqual(relationships, set(quality.RELATIONSHIPS))

    def test_answerable_expectations_are_current_and_exactly_sourced(self):
        for case in quality.public_fixture()["cases"]:
            if case["expected"]["answerPolicy"] != "answer":
                continue
            facts = {fact["id"]: fact for fact in case["corpus"]["facts"]}
            evidence = {
                item["id"]: item for item in case["corpus"]["evidence"]
            }
            supported = set()
            for identifier in case["expected"]["resultIDs"]:
                fact = facts[identifier]
                self.assertFalse(fact["stale"])
                self.assertNotEqual(fact["origin"], "generated")
                supported.update(fact["evidenceIDs"])
            self.assertTrue(set(case["expected"]["evidenceIDs"]).issubset(supported))
            self.assertTrue(
                all(identifier in evidence for identifier in supported)
            )

    def test_abstention_cases_keep_only_explicit_forbidden_temptations(self):
        cases = [
            case
            for case in quality.public_fixture()["cases"]
            if case["expected"]["answerPolicy"] == "abstain"
        ]

        self.assertEqual(len(cases), 6)
        self.assertEqual(
            {case["expected"]["abstentionReason"] for case in cases},
            quality.ABSTENTION_REASONS,
        )
        for case in cases:
            expected = case["expected"]
            self.assertEqual(expected["resultIDs"], [])
            self.assertEqual(expected["evidenceIDs"], [])
            self.assertTrue(expected["forbiddenResultIDs"])

    def test_code_switched_cases_require_both_source_languages(self):
        cases = [
            case
            for case in quality.public_fixture()["cases"]
            if case["relationship"] == "codeSwitched"
        ]

        self.assertEqual(len(cases), 6)
        for case in cases:
            self.assertEqual(case["query"]["language"], "mixed")
            languages = {
                item["language"] for item in case["corpus"]["evidence"]
            }
            self.assertTrue({"en", "es"}.issubset(languages))

    def test_public_verifier_rejects_drift(self):
        document = quality.public_fixture()
        document["cases"][0]["query"]["text"] = "A valid but noncanonical query"
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture.json"
            fixture.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                quality.MeetingMemoryGraphQualityError,
                "is not canonical",
            ):
                quality.main_from_args(
                    ["verify-public", "--fixture", str(fixture)]
                )

    def test_loader_rejects_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "fixture.json"
            fixture.write_text('{"schemaVersion": 1, "schemaVersion": 1}')

            with self.assertRaisesRegex(
                quality.MeetingMemoryGraphQualityError,
                "duplicate key: schemaVersion",
            ):
                quality.load_json(fixture, "fixture")

    def test_fixture_rejects_unknown_expected_identity(self):
        document = quality.public_fixture()
        document["cases"][0]["expected"]["resultIDs"] = ["fact-missing"]

        with self.assertRaisesRegex(
            quality.MeetingMemoryGraphQualityError,
            "must reference the case corpus",
        ):
            quality.validate_fixture(document)

    def test_fixture_rejects_generated_or_stale_required_truth(self):
        for mutation in ("generated", "stale"):
            with self.subTest(mutation=mutation):
                document = quality.public_fixture()
                case = document["cases"][0]
                result_id = case["expected"]["resultIDs"][0]
                fact = next(
                    item
                    for item in case["corpus"]["facts"]
                    if item["id"] == result_id
                )
                if mutation == "generated":
                    fact["origin"] = "generated"
                else:
                    fact["stale"] = True

                with self.assertRaisesRegex(
                    quality.MeetingMemoryGraphQualityError,
                    "current confirmed/manual truth",
                ):
                    quality.validate_fixture(document)

    def test_fixture_rejects_evidence_not_owned_by_required_result(self):
        document = quality.public_fixture()
        case = document["cases"][0]
        case["expected"]["evidenceIDs"] = [
            case["corpus"]["evidence"][2]["id"]
        ]

        with self.assertRaisesRegex(
            quality.MeetingMemoryGraphQualityError,
            "must support the required results",
        ):
            quality.validate_fixture(document)

    def test_fixture_rejects_unsupported_abstention_label(self):
        document = quality.public_fixture()
        abstention = next(
            case
            for case in document["cases"]
            if case["relationship"] == "abstention"
        )
        abstention["expected"]["abstentionReason"] = "unsupportedConflict"

        with self.assertRaisesRegex(
            quality.MeetingMemoryGraphQualityError,
            "does not match the job contract",
        ):
            quality.validate_fixture(document)

    def test_fixture_rejects_incomplete_distribution(self):
        document = quality.public_fixture()
        document["cases"].pop()

        with self.assertRaisesRegex(
            quality.MeetingMemoryGraphQualityError,
            "distribution must be exactly",
        ):
            quality.validate_fixture(document)

    def test_fixture_rejects_relationship_language_drift(self):
        document = copy.deepcopy(quality.public_fixture())
        case = next(
            item
            for item in document["cases"]
            if item["relationship"] == "englishToSpanish"
        )
        case["corpus"]["evidence"][0]["language"] = "en"

        with self.assertRaisesRegex(
            quality.MeetingMemoryGraphQualityError,
            "does not match its bilingual relationship",
        ):
            quality.validate_fixture(document)


if __name__ == "__main__":
    unittest.main()
