import copy
import hashlib
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "dictation_search_quality", ROOT / "scripts" / "dictation_search_quality.py"
)
quality = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(quality)


def observations_for(fixture, lexical_hits, semantic_hits, p95=10.0):
    """Builds observations where each query's lists come from the given callables."""
    queries = []
    for query in fixture["queries"]:
        hits = semantic_hits(query)
        queries.append({
            "id": query["id"], "lexical": lexical_hits(query), "semantic": hits, "semanticCentered": hits,
            "lexicalExpandedMeeting": None, "lexicalExpandedDictation": None,
        })
    return {
        "schemaVersion": 1, "kind": quality.OBSERVATION_KIND, "fixtureSHA256": "0" * 64,
        "build": "test", "commit": "a" * 40, "embeddingProfileFingerprint": "f" * 64, "dimension": 4,
        "queries": queries,
        "resources": {"scale": [{"dictations": 10000, "lexicalP95Milliseconds": 1.0,
                                 "semanticP95Milliseconds": p95, "vectorBytes": 1}]},
    }


class DictationSearchQualityTests(unittest.TestCase):
    def setUp(self):
        self.fixture = quality.generate_public()

    def test_the_public_fixture_is_deterministic_valid_and_committed(self):
        self.assertEqual(self.fixture, quality.generate_public())
        quality.validate_fixture(self.fixture)
        counts = {}
        for query in self.fixture["queries"]:
            counts[query["relationship"]] = counts.get(query["relationship"], 0) + 1
        self.assertEqual(counts, quality.RELATIONSHIP_COUNTS)
        self.assertEqual(quality.PUBLIC_FIXTURE.read_bytes(), quality.canonical_bytes(self.fixture))

    def test_a_meaning_query_that_shares_a_word_with_its_dictation_is_rejected(self):
        broken = copy.deepcopy(self.fixture)
        query = next(q for q in broken["queries"] if q["relationship"] == "paraphraseSpanish")
        target = next(d for d in broken["dictations"] if d["id"] == query["relevant"][0])
        query["text"] += " " + sorted(quality.tokens(target["text"]))[0]
        with self.assertRaises(quality.FixtureError):
            quality.validate_fixture(broken)

    def test_reciprocal_rank_fusion_matches_the_shipped_formula(self):
        fused = quality.reciprocal_rank_fusion(["b", "a"], ["a", "c"])
        self.assertEqual(fused, ["a", "b", "c"])
        self.assertEqual(quality.reciprocal_rank_fusion(["x"], ["y"]), ["x", "y"])

    def test_a_perfect_semantic_lane_with_a_clean_threshold_proceeds(self):
        def lexical(query):
            return query["relevant"] if query["relationship"] == "exact" else []

        def semantic(query):
            if query["relationship"] == "abstain":
                return [{"id": self.fixture["dictations"][0]["id"], "similarity": 0.2}]
            return [{"id": query["relevant"][0], "similarity": 0.9}]

        scorecard = quality.evaluate(self.fixture, observations_for(self.fixture, lexical, semantic))

        self.assertEqual(scorecard["verdict"], "proceed")
        lane = scorecard["lanes"]["semantic"]
        self.assertEqual(lane["hybrid"]["exact"]["hitAt1"], 1.0)
        self.assertEqual(quality.meaning_recall(lane["hybrid"]), 1.0)
        self.assertLessEqual(lane["chosenThreshold"], 0.9)
        self.assertGreater(lane["chosenThreshold"], 0.2)

    def test_slow_semantic_search_or_no_gain_stops(self):
        def lexical(query):
            return query["relevant"]

        def semantic(query):
            return [{"id": query["relevant"][0], "similarity": 0.9}] if query["relevant"] else []

        no_gain = quality.evaluate(self.fixture, observations_for(self.fixture, lexical, semantic))
        slow = quality.evaluate(
            self.fixture, observations_for(self.fixture, lambda q: [], semantic, p95=400.0))

        self.assertEqual(no_gain["verdict"], "stop")
        self.assertIn("hybrid meaning recall gain is below the gate", no_gain["lanes"]["semantic"]["reasons"])
        self.assertEqual(slow["verdict"], "stop")
        self.assertIn("semantic query p95 at the largest scale is above the gate", slow["reasons"])

    def test_noisy_semantic_hits_on_unanswerable_questions_cap_the_threshold(self):
        def semantic(query):
            if query["relationship"] == "abstain":
                return [{"id": self.fixture["dictations"][0]["id"], "similarity": 0.95}]
            return [{"id": query["relevant"][0], "similarity": 0.9}]

        scorecard = quality.evaluate(self.fixture, observations_for(self.fixture, lambda q: [], semantic))

        self.assertEqual(scorecard["verdict"], "stop")
        self.assertIsNone(scorecard["lanes"]["semantic"]["chosenThreshold"])

    def test_an_expansion_lane_that_finds_paraphrases_proceeds_and_an_absent_one_is_reported(self):
        observations = observations_for(self.fixture, lambda q: q["relevant"] if q["relationship"] == "exact" else [],
                                        lambda q: [])
        for item, query in zip(observations["queries"], self.fixture["queries"]):
            item["lexicalExpandedDictation"] = query["relevant"]
        observations["resources"]["expansionDictationMilliseconds"] = {"p50": 600.0, "p95": 900.0}

        scorecard = quality.evaluate(self.fixture, observations)

        self.assertIn("lexicalExpandedDictation", scorecard["passingLanes"])
        self.assertEqual(scorecard["expansions"]["lexicalExpandedDictation"]["meaningRecallAt5"], 1.0)
        self.assertFalse(scorecard["expansions"]["lexicalExpandedMeeting"]["available"])

    def test_the_scorecard_is_private_and_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nested" / "scorecard.json"
            quality.write_private(path, {"kind": "x"})
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            with self.assertRaises(quality.FixtureError):
                quality.write_private(path, {"kind": "y"})

    def test_evaluate_refuses_observations_of_another_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            observations = Path(directory) / "observations.json"
            document = observations_for(self.fixture, lambda q: [], lambda q: [])
            observations.write_text(json.dumps(document))
            status = quality.main([
                "evaluate", "--observations", str(observations), "--output", str(Path(directory) / "s.json")])
            self.assertEqual(status, 1)
            self.assertNotEqual(document["fixtureSHA256"], hashlib.sha256(quality.PUBLIC_FIXTURE.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
