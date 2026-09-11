import copy
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import ask_quality as quality
import ask_quality_attribution as attribution


class AskQualityAttributionTests(unittest.TestCase):
    def test_natural_reference_fixture_rejects_pinned_digest_drift(self):
        with patch.object(quality, "PUBLIC_NATURAL_CHECKSUM", "0" * 64):
            with self.assertRaises(quality.AskQualityError):
                quality.public_fixture(quality.PUBLIC_NATURAL_GENERATION)

    def test_natural_reference_fixture_is_frozen_and_never_a_release_corpus(self):
        raw = quality.public_fixture(quality.PUBLIC_NATURAL_GENERATION)
        fixture = quality.validate_fixture(raw, exact_distribution=False)
        self.assertEqual(len(fixture["queries"]), 24)
        self.assertEqual(len(fixture["segments"]), 44)
        self.assertEqual(raw, json.loads((ROOT / "Fixtures/AskQuality/public-natural-reference-v1.json").read_text()))
        self.assertGreaterEqual(sum(not re.search(r"[A-Za-z]+-\d+", query["text"])
                                    for query in raw["queries"]), 14)
        self.assertEqual(set(query["intent"] for query in raw["queries"]), quality.INTENTS)
        self.assertEqual(sum(query["answerPolicy"] == "abstain" for query in raw["queries"]), 2)
        self.assertEqual(quality.main_from_args(["verify-public", "--fixture",
            str(ROOT / "Fixtures/AskQuality/public-natural-reference-v1.json")]), 0)
        with self.assertRaises(quality.AskQualityError):
            quality.validate_fixture(raw)
        raw["queries"][0]["text"] = "A convenient replacement question"
        with self.assertRaises(quality.AskQualityError):
            quality.validate_fixture(raw, exact_distribution=False)

    def test_diagnostic_cli_accepts_small_frozen_corpus_without_qualifying_it(self):
        self.raw_fixture = quality.public_fixture(quality.PUBLIC_NATURAL_GENERATION)
        self.fixture = quality.validate_fixture(self.raw_fixture, exact_distribution=False)
        rows = len(self.fixture["segments"])
        self.document["corpus"].update(projectedUnitCount=rows, embeddedRows=rows,
                                       embeddingResults=self.counts(rows))
        self.document["observation"].update(fixtureGeneration=self.fixture["generation"], queries=[])
        self.document["stages"] = []
        for query in self.raw_fixture["queries"]:
            hits = [self.hit(query["relevant"][0]["segmentID"])] if query["relevant"] else []
            self.document["observation"]["queries"].append(dict(queryID=query["id"], hits=hits,
                answer=dict(outcome="notEvaluated", factuality=None, citationCoverage=None, unsupportedClaims=0)))
            self.document["stages"].append(dict(queryID=query["id"], lexical=hits, semanticRequests=[]))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture, observation, output = [root / name for name in ("fixture.json", "input.json", "output.json")]
            fixture.write_text(json.dumps(self.raw_fixture))
            observation.write_text(json.dumps(self.document))
            result = subprocess.run([sys.executable, str(ROOT / "scripts/ask_quality_attribution.py"),
                "--fixture", str(fixture), "--observations", str(observation), "--output", str(output)],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads(output.read_text())
            self.assertEqual(summary["outcome"], "diagnostic-only")
            self.assertNotIn("gates", summary)
            self.assertIsNone(summary["stages"]["fused"]["overall"]["factuality"])

    def setUp(self):
        self.raw_fixture = quality.public_fixture()
        self.fixture = quality.validate_fixture(self.raw_fixture)
        profile = dict(modelIdentifier="Apple.Test-Model", modelRevision=1, vectorDimension=2,
                       pipelineIdentifier="test", pipelineRevision=1, vectorSchemaVersion=1)
        rows = len(self.fixture["segments"])
        corpus = dict(profile=profile, profileFingerprint=attribution.profile_fingerprint(profile),
                      projectedUnitCount=rows, embeddedRows=rows, excludedRows=0, skippedRows=0,
                      invalidatedRows=0, pendingRowsRemain=False, pausedByPolicy=False,
                      embeddingResults=self.counts(rows))
        queries, stages = [], []
        for query in self.raw_fixture["queries"]:
            hits = [self.hit(query["relevant"][0]["segmentID"])] if query["relevant"] else []
            queries.append(dict(queryID=query["id"], hits=hits, answer=dict(
                outcome="notEvaluated", factuality=None, citationCoverage=None, unsupportedClaims=0)))
            stages.append(dict(queryID=query["id"], lexical=copy.deepcopy(hits), semanticRequests=[dict(
                outcome="succeeded", profileFingerprint=corpus["profileFingerprint"], candidateLimit=12,
                queryVectors=self.counts(1), variants=[copy.deepcopy(hits)])]))
        self.document = dict(schemaVersion=1, kind="ask-quality-attribution", outcome="diagnostic-only",
            corpus=corpus, stages=stages, observation=dict(schemaVersion=2, kind="ask-quality-observations",
                fixtureGeneration=self.fixture["generation"], adapter="test", build="test",
                commit="a" * 40, queries=queries))

    @staticmethod
    def counts(number):
        return dict(requestedTexts=number, returnedVectors=number, nonzeroFiniteVectors=number,
                    zeroVectors=0, malformedVectors=0)

    def hit(self, segment_id):
        segment = self.fixture["segments"][segment_id]
        return dict(unitID=segment_id, sourceSegmentIDs=[segment_id], meetingID=segment["meetingID"],
                    timestampMilliseconds=segment["timestampMilliseconds"],
                    transcriptRevision=segment["transcriptRevision"])

    def test_summary_is_non_serving_and_reuses_canonical_scoring_without_mutation(self):
        original = copy.deepcopy(self.document)
        result = attribution.summarize(self.fixture, self.document)
        expected = quality.evaluate(self.fixture, quality.validate_observations(
            self.document["observation"], self.fixture))
        self.assertEqual(result["stages"]["fused"]["overall"], expected["overall"])
        self.assertEqual(result["outcome"], "diagnostic-only")
        self.assertNotIn("gates", result)
        self.assertEqual(result["semanticOutcomes"], dict(notInvoked=0, failed=0, succeeded=240))
        self.assertIsNone(result["stages"]["fused"]["overall"]["factuality"])
        self.assertEqual(self.document, original)

    def test_unavailable_and_failed_scans_are_excluded_from_successful_semantic_cohort(self):
        self.document["stages"][0]["semanticRequests"] = []
        request = self.document["stages"][1]["semanticRequests"][0]
        request.update(outcome="failed", variants=[])
        result = attribution.summarize(self.fixture, self.document)
        self.assertEqual(result["semanticOutcomes"], dict(notInvoked=1, failed=1, succeeded=238))
        self.assertEqual(result["stages"]["successfulOriginalSemanticTop10"]["overall"]["queryCount"], 238)
        self.assertEqual(result["stages"]["fused"]["overall"]["queryCount"], 240)

    def test_all_raw_candidates_are_validated_but_not_merged_into_original_ranking(self):
        request = self.document["stages"][0]["semanticRequests"][0]
        hits = [self.hit(segment_id) for segment_id in list(self.fixture["segments"])[:12]]
        request.update(queryVectors=self.counts(2), variants=[hits, list(reversed(hits))])
        attribution.summarize(self.fixture, self.document)
        self.assertEqual(request["variants"][0], hits)
        request["variants"][0][11]["transcriptRevision"] += 1
        with self.assertRaises(quality.AskQualityError):
            attribution.summarize(self.fixture, self.document)

    def test_duplicate_across_validation_batches_is_rejected(self):
        request = self.document["stages"][0]["semanticRequests"][0]
        hits = [self.hit(segment_id) for segment_id in list(self.fixture["segments"])[:11]]
        hits.append(copy.deepcopy(hits[0]))
        request["variants"] = [hits]
        with self.assertRaises(quality.AskQualityError):
            attribution.validate(self.document, self.fixture)

    def test_contract_rejects_tampered_profiles_coverage_shapes_and_stage_order(self):
        mutations = [
            lambda doc: doc.update(outcome="pass"),
            lambda doc: doc.update(schemaVersion=True),
            lambda doc: doc.update(transcript="secret"),
            lambda doc: doc["corpus"].update(profileFingerprint="a" * 64),
            lambda doc: doc["corpus"].update(pendingRowsRemain=True),
            lambda doc: doc["corpus"].update(pausedByPolicy=0),
            lambda doc: doc["corpus"].update(embeddedRows=0),
            lambda doc: doc["corpus"]["embeddingResults"].update(zeroVectors=1),
            lambda doc: doc["stages"].pop(),
            lambda doc: doc["stages"].reverse(),
            lambda doc: doc["stages"][0]["semanticRequests"][0].update(variants=[]),
            lambda doc: doc["stages"][0]["semanticRequests"][0].update(candidateLimit=True),
            lambda doc: doc["stages"][0]["semanticRequests"][0].update(profileFingerprint="b" * 64),
            lambda doc: doc["stages"][0]["semanticRequests"][0].update(error="private provider error"),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                document = copy.deepcopy(self.document)
                mutate(document)
                with self.assertRaises(quality.AskQualityError):
                    attribution.validate(document, self.fixture)

    def test_zero_vectors_are_honest_published_rows_not_positive_coverage(self):
        counts = self.document["corpus"]["embeddingResults"]
        counts["zeroVectors"] = counts["nonzeroFiniteVectors"]
        counts["nonzeroFiniteVectors"] = 0
        result = attribution.summarize(self.fixture, self.document)
        self.assertEqual(result["corpus"]["embeddingResults"]["nonzeroFiniteVectors"], 0)
        self.assertEqual(result["outcome"], "diagnostic-only")

    def test_command_publishes_owner_only_atomically_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture, observation, output = [root / name for name in ("fixture.json", "input.json", "output.json")]
            fixture.write_text(json.dumps(self.raw_fixture))
            observation.write_text(json.dumps(self.document))
            command = [sys.executable, str(ROOT / "scripts/ask_quality_attribution.py"),
                       "--fixture", str(fixture), "--observations", str(observation), "--output", str(output)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            before = output.read_bytes()
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(output.read_bytes(), before)
            self.assertEqual(list(root.glob(".*.tmp")), [])

    def test_command_rejects_duplicate_keys_and_does_not_echo_hostile_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture, observation, output = [root / name for name in ("fixture.json", "input.json", "output.json")]
            fixture.write_text(json.dumps(self.raw_fixture))
            observation.write_text('{"secret-transcript":1,"secret-transcript":2}')
            result = subprocess.run([sys.executable, str(ROOT / "scripts/ask_quality_attribution.py"),
                "--fixture", str(fixture), "--observations", str(observation), "--output", str(output)],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn("secret-transcript", result.stderr + result.stdout)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
