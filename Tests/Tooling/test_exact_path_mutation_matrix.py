import copy
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "exact_path_mutation_matrix.py"
SPEC = importlib.util.spec_from_file_location("exact_path_mutation_matrix", SCRIPT)
mutation_matrix = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(mutation_matrix)


class ExactPathMutationMatrixTests(unittest.TestCase):
    commit = "b" * 40
    toolchain = "Apple Swift version 6.2.3 (swiftlang-6.2.3.1.4 clang-1700.6.3.2)"

    def setUp(self):
        self.contract = mutation_matrix.load_contract(
            mutation_matrix.DEFAULT_CONTRACT
        )
        self.profiles = mutation_matrix.foundation.load_profiles(
            mutation_matrix.DEFAULT_RESOURCE_CONTRACT
        )

    def test_complete_matrix_requires_review_and_remains_content_free(self):
        receipt = self.receipt(self.observations())

        self.assertEqual(receipt["schemaVersion"], 1)
        self.assertEqual(receipt["outcome"], "review-required")
        self.assertEqual(
            receipt["reviewPolicyVersion"],
            "human-threshold-free-mutation-review-v1",
        )
        self.assertEqual(receipt["hostProfile"], "memory-16gb")
        self.assertTrue(
            all(scale["state"] == "review-required" for scale in receipt["scales"])
        )
        first = receipt["scales"][0]
        self.assertEqual(first["observationCount"], 3)
        self.assertEqual(first["agreement"]["comparisonCount"], 138)
        self.assertEqual(first["agreement"]["expectedTopHitCount"], 93)
        self.assertEqual(first["engines"][0]["engine"], "accelerateExact")
        self.assertEqual(first["engines"][1]["engine"], "sqliteVecExact")
        self.assertEqual(
            len(first["engines"][0]["mutations"]),
            len(self.contract["batchSizes"]) * 3,
        )

        encoded = json.dumps(receipt, sort_keys=True)
        for forbidden in (
            "segmentID",
            "meetingID",
            "transcript",
            "queryVector",
            "modelIdentifier",
            "databasePath",
            "filePath",
            "rawError",
            "operatorNotes",
            "candidateToControl",
            "performanceRatio",
            "speedup",
        ):
            self.assertNotIn(forbidden, encoded)
        self.assertEqual(
            mutation_matrix.validate_host_receipt(
                receipt,
                self.contract,
                self.profiles,
            ),
            receipt,
        )

    def test_contract_has_no_performance_threshold(self):
        self.assertNotIn("maximumTimingP95ToP50Ratio", self.contract)
        self.assertNotIn("minimumPerformanceImprovement", self.contract)
        self.assertEqual(
            self.contract["reviewPolicyVersion"],
            "human-threshold-free-mutation-review-v1",
        )

    def test_missing_scale_is_a_complete_blocked_receipt(self):
        observations = self.observations()
        observations.pop()

        receipt = self.receipt(observations)

        self.assertEqual(receipt["outcome"], "blocked")
        last = receipt["scales"][-1]
        self.assertEqual(last["state"], "incomplete")
        self.assertEqual(last["observationCount"], 2)
        self.assertEqual(last["engines"], [])
        self.assertIsNone(last["agreement"])

    def test_timing_variability_remains_visible_without_automatic_verdict(self):
        observations = self.observations()
        distribution = observations[0]["engines"][0]["mutations"][0][
            "wallMilliseconds"
        ]
        distribution["p50Milliseconds"] = 1.0
        distribution["p95Milliseconds"] = 1000.0
        distribution["maximumMilliseconds"] = 1000.0

        receipt = self.receipt(observations)

        self.assertEqual(receipt["outcome"], "review-required")
        ratios = receipt["scales"][0]["engines"][0]["mutations"][0][
            "wallMilliseconds"
        ]["withinObservationP95ToP50Ratio"]
        self.assertEqual(ratios["maximum"], 1000.0)

    def test_top_hit_or_top_k_disagreement_blocks_the_scale(self):
        observations = self.observations()
        observations[0]["agreement"]["topKSetMatchCount"] -= 1

        receipt = self.receipt(observations)

        self.assertEqual(receipt["outcome"], "blocked")
        self.assertEqual(receipt["scales"][0]["state"], "agreement-failed")

    def test_lower_rank_drift_remains_reviewable(self):
        observations = self.observations()
        observations[0]["agreement"]["exactRankMatchCount"] -= 1

        receipt = self.receipt(observations)

        self.assertEqual(receipt["outcome"], "review-required")
        self.assertEqual(receipt["scales"][0]["state"], "review-required")
        self.assertEqual(receipt["scales"][0]["agreement"]["exactRankMatchCount"], 137)

    def test_unknown_content_fields_and_nonfinite_numbers_fail_closed(self):
        observations = self.observations()
        observations[0]["meetingTitle"] = "private meeting"
        with self.assertRaisesRegex(
            mutation_matrix.MatrixError,
            "forbidden meetingTitle",
        ):
            self.receipt(observations)

        observations = self.observations()
        observations[0]["engines"][0]["fullRebuildMilliseconds"] = float("nan")
        with self.assertRaisesRegex(mutation_matrix.MatrixError, "must be finite"):
            self.receipt(observations)

    def test_configuration_engine_order_and_counts_fail_closed(self):
        observations = self.observations()
        observations[0]["configuration"]["runsPerBatch"] = 3
        with self.assertRaisesRegex(mutation_matrix.MatrixError, "runsPerBatch"):
            self.receipt(observations)

        observations = self.observations()
        observations[0]["engines"].reverse()
        with self.assertRaisesRegex(mutation_matrix.MatrixError, "canonical order"):
            self.receipt(observations)

        observations = self.observations()
        observations[0]["engines"][0]["mutations"][0]["wallMilliseconds"][
            "sampleCount"
        ] = 4
        with self.assertRaisesRegex(mutation_matrix.MatrixError, "sampleCount"):
            self.receipt(observations)

        observations = self.observations()
        observations[0]["configuration"]["mutationLifecycle"] = "mislabelled"
        with self.assertRaisesRegex(mutation_matrix.MatrixError, "mutationLifecycle"):
            self.receipt(observations)

    def test_integer_fields_reject_boolean_and_float_spellings(self):
        observations = self.observations()
        observations[0]["schemaVersion"] = True
        with self.assertRaisesRegex(mutation_matrix.MatrixError, "schemaVersion"):
            self.receipt(observations)

        observations = self.observations()
        observations[0]["configuration"]["dimension"] = 512.0
        with self.assertRaisesRegex(mutation_matrix.MatrixError, "dimension"):
            self.receipt(observations)

        observations = self.observations()
        observations[0]["agreement"]["comparisonCount"] = 46.0
        with self.assertRaisesRegex(mutation_matrix.MatrixError, "comparisonCount"):
            self.receipt(observations)

    def test_mixed_host_wrong_profile_and_duplicate_observation_fail_closed(self):
        observations = self.observations()
        observations[-1]["host"]["processorCount"] = 12
        with self.assertRaisesRegex(mutation_matrix.MatrixError, "different hosts"):
            self.receipt(observations)

        with self.assertRaisesRegex(
            mutation_matrix.MatrixError,
            "does not match host profile",
        ):
            mutation_matrix.build_receipt(
                self.observations(),
                self.contract,
                self.profiles,
                "memory-8gb",
                self.commit,
                self.toolchain,
            )

        observations = self.observations()
        observations[1] = copy.deepcopy(observations[0])
        with self.assertRaisesRegex(
            mutation_matrix.MatrixError,
            "repeats an identical",
        ):
            self.receipt(observations)

        observations = self.observations()
        observations.append(copy.deepcopy(observations[0]))
        observations[-1]["configuration"]["fixturePreparationMilliseconds"] += 1
        with self.assertRaisesRegex(
            mutation_matrix.MatrixError,
            "excess observations",
        ):
            self.receipt(observations)

    def test_receipt_rejects_tampered_state_and_ratio_shape(self):
        receipt = self.receipt(self.observations())
        receipt["scales"][0]["state"] = "agreement-failed"
        with self.assertRaisesRegex(mutation_matrix.MatrixError, "state is inconsistent"):
            mutation_matrix.validate_host_receipt(
                receipt,
                self.contract,
                self.profiles,
            )

        receipt = self.receipt(self.observations())
        receipt["scales"][0]["state"] = []
        with self.assertRaisesRegex(mutation_matrix.MatrixError, "bounded string"):
            mutation_matrix.validate_host_receipt(
                receipt,
                self.contract,
                self.profiles,
            )

        receipt = self.receipt(self.observations())
        ratios = receipt["scales"][0]["engines"][0]["mutations"][0][
            "wallMilliseconds"
        ]["withinObservationP95ToP50Ratio"]
        ratios["p50"] = 0.5
        with self.assertRaisesRegex(mutation_matrix.MatrixError, "finite and >= 1"):
            mutation_matrix.validate_host_receipt(
                receipt,
                self.contract,
                self.profiles,
            )

    def test_duplicate_json_keys_empty_input_and_timestamp_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "observations.jsonl"
            path.write_text('{"schemaVersion":1,"schemaVersion":1}\n')
            with self.assertRaisesRegex(
                mutation_matrix.MatrixError,
                "duplicate JSON key",
            ):
                mutation_matrix.foundation.read_observations(path)

        with self.assertRaisesRegex(mutation_matrix.MatrixError, "stream is empty"):
            self.receipt([])

        with self.assertRaisesRegex(mutation_matrix.MatrixError, "UTC timestamp"):
            mutation_matrix.build_receipt(
                self.observations(),
                self.contract,
                self.profiles,
                "memory-16gb",
                self.commit,
                self.toolchain,
                generated_at="2026-99-01T00:00:00Z",
            )

        with self.assertRaisesRegex(mutation_matrix.MatrixError, "source commit"):
            mutation_matrix.build_receipt(
                self.observations(),
                self.contract,
                self.profiles,
                "memory-16gb",
                123,
                self.toolchain,
            )

        with self.assertRaisesRegex(mutation_matrix.MatrixError, "toolchain"):
            mutation_matrix.build_receipt(
                self.observations(),
                self.contract,
                self.profiles,
                "memory-16gb",
                self.commit,
                123,
            )

    def test_cli_exit_codes_distinguish_review_blocked_and_malformed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "observations.jsonl"
            review = self.run_cli(path, self.observations())
            self.assertEqual(review.returncode, 0)
            self.assertEqual(json.loads(review.stdout)["outcome"], "review-required")

            blocked = self.run_cli(path, self.observations()[:-1])
            self.assertEqual(blocked.returncode, 1)
            self.assertEqual(json.loads(blocked.stdout)["outcome"], "blocked")

            path.write_text('{"schemaVersion":1,"schemaVersion":1}\n')
            malformed = self.cli(path)
            self.assertEqual(malformed.returncode, 2)
            self.assertEqual(malformed.stdout, "")
            self.assertIn("duplicate JSON key", malformed.stderr)

    def receipt(self, observations):
        return mutation_matrix.build_receipt(
            observations,
            self.contract,
            self.profiles,
            "memory-16gb",
            self.commit,
            self.toolchain,
            generated_at="2026-08-01T12:00:00Z",
        )

    def run_cli(self, path, observations):
        path.write_text(
            "".join(json.dumps(observation) + "\n" for observation in observations)
        )
        return self.cli(path)

    def cli(self, path):
        return subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "--input",
                str(path),
                "--profile",
                "memory-16gb",
                "--commit",
                self.commit,
                "--toolchain",
                self.toolchain,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def observations(self):
        result = []
        for scale_index, scale in enumerate(self.contract["canonicalScales"]):
            for repetition in range(3):
                result.append(self.observation(scale, scale_index, repetition))
        return result

    def observation(self, scale, scale_index, repetition):
        comparisons, expected_hits = mutation_matrix.expected_agreement(self.contract)
        return {
            "schemaVersion": 1,
            "fixtureVersion": self.contract["fixtureVersion"],
            "measurementPolicyVersion": self.contract["measurementPolicyVersion"],
            "buildConfiguration": "release",
            "host": {
                "operatingSystem": "Version 26.0 (Build 25A123)",
                "architecture": "arm64",
                "processorCount": 10,
                "physicalMemoryBytes": 16 * 1024**3,
            },
            "configuration": {
                "corpusSize": scale,
                "dimension": self.contract["dimension"],
                "runsPerBatch": self.contract["runsPerBatch"],
                "resultLimit": self.contract["resultLimit"],
                "batchSizes": self.contract["batchSizes"],
                "rawEmbeddingBytes": scale * self.contract["dimension"] * 4,
                "fixturePreparationMilliseconds": 2.0 + repetition * 0.1,
                "rebuildLifecycle": self.contract["rebuildLifecycle"],
                "mutationLifecycle": self.contract["mutationLifecycle"],
            },
            "engines": [
                self.engine("accelerateExact", 200.0 + scale_index + repetition),
                self.engine("sqliteVecExact", 20.0 + scale_index + repetition),
            ],
            "agreement": {
                "comparisonCount": comparisons,
                "expectedTopHitCount": expected_hits,
                "topHitMatchCount": comparisons,
                "exactRankMatchCount": comparisons,
                "topKSetMatchCount": comparisons,
            },
        }

    def engine(self, name, rebuild):
        mutations = []
        for batch_index, batch_size in enumerate(self.contract["batchSizes"]):
            for operation_index, operation in enumerate(
                mutation_matrix.OPERATION_ORDER
            ):
                base = rebuild / 100 + batch_index + operation_index * 0.1
                mutations.append({
                    "operation": operation,
                    "batchSize": batch_size,
                    "wallMilliseconds": {
                        "sampleCount": self.contract["runsPerBatch"],
                        "p50Milliseconds": base,
                        "p95Milliseconds": base * 1.1,
                        "maximumMilliseconds": base * 1.2,
                    },
                })
        return {
            "engine": name,
            "fullRebuildMilliseconds": rebuild,
            "mutations": mutations,
        }


if __name__ == "__main__":
    unittest.main()
