import copy
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "exact_path_matrix.py"
SPEC = importlib.util.spec_from_file_location("exact_path_matrix", SCRIPT)
matrix = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(matrix)


class ExactPathMatrixTests(unittest.TestCase):
    commit = "a" * 40
    toolchain = "Apple Swift version 6.2.3 (swiftlang-6.2.3.1.4 clang-1700.6.3.2)"

    def setUp(self):
        self.contract = matrix.load_contract(matrix.DEFAULT_CONTRACT)
        self.profiles = matrix.load_profiles(matrix.DEFAULT_RESOURCE_CONTRACT)

    def test_complete_stable_matrix_passes_and_emits_only_aggregates(self):
        receipt = self.receipt(self.observations())

        self.assertEqual(receipt["schemaVersion"], 2)
        self.assertEqual(receipt["outcome"], "pass")
        self.assertEqual(receipt["hostProfile"], "memory-16gb")
        self.assertEqual(
            [row["corpusSize"] for row in receipt["scales"]],
            [1_000, 10_000, 50_000, 100_000],
        )
        self.assertTrue(all(row["state"] == "pass" for row in receipt["scales"]))
        first = receipt["scales"][0]
        self.assertEqual(first["observationCount"], 3)
        self.assertEqual(first["engines"][0]["engine"], "accelerateExact")
        self.assertEqual(first["engines"][1]["engine"], "sqliteVecExact")
        self.assertLessEqual(
            first["engines"][0][
                "maximumWithinObservationTimingP95ToP50Ratio"
            ],
            1.25,
        )
        self.assertEqual(first["agreement"]["comparisonCount"], 120)
        self.assertEqual(first["agreement"]["overlapAtKCount"], 1_200)

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
        ):
            self.assertNotIn(forbidden, encoded)
        self.assertEqual(
            matrix.validate_host_receipt(
                receipt,
                self.contract,
                self.profiles,
            ),
            receipt,
        )

    def test_missing_scale_is_a_complete_blocked_receipt(self):
        observations = self.observations()
        observations.pop()

        receipt = self.receipt(observations)

        self.assertEqual(receipt["outcome"], "blocked")
        last = receipt["scales"][-1]
        self.assertEqual(last["state"], "incomplete")
        self.assertEqual(last["observationCount"], 2)
        self.assertIsNone(last["agreement"])

    def test_unstable_query_or_build_timing_blocks_the_scale(self):
        observations = self.observations()
        observations[0]["engines"][0]["queryWallMilliseconds"][
            "p95Milliseconds"
        ] = 20.0
        observations[0]["engines"][0]["queryWallMilliseconds"][
            "maximumMilliseconds"
        ] = 20.0

        receipt = self.receipt(observations)

        self.assertEqual(receipt["outcome"], "blocked")
        self.assertEqual(receipt["scales"][0]["state"], "unstable")
        self.assertGreater(
            receipt["scales"][0]["engines"][0][
                "maximumWithinObservationTimingP95ToP50Ratio"
            ],
            1.25,
        )
        matrix.validate_host_receipt(receipt, self.contract, self.profiles)

    def test_host_receipt_rejects_tampered_state_and_unbounded_numeric_output(self):
        receipt = self.receipt(self.observations())
        receipt["scales"][0]["state"] = "unstable"
        with self.assertRaisesRegex(matrix.MatrixError, "state is inconsistent"):
            matrix.validate_host_receipt(receipt, self.contract, self.profiles)

        receipt = self.receipt(self.observations())
        receipt["scales"][0]["engines"][0][
            "maximumWithinObservationTimingP95ToP50Ratio"
        ] = 1.0
        with self.assertRaisesRegex(matrix.MatrixError, "aggregate lower bound"):
            matrix.validate_host_receipt(receipt, self.contract, self.profiles)

        observations = self.observations()
        observations[0]["engines"][0]["queryWallMilliseconds"][
            "p50Milliseconds"
        ] = 0.0
        receipt = self.receipt(observations)
        ratio = receipt["scales"][0]["engines"][0][
            "maximumWithinObservationTimingP95ToP50Ratio"
        ]
        self.assertIsNone(ratio)
        self.assertNotIn("Infinity", json.dumps(receipt))
        matrix.validate_host_receipt(receipt, self.contract, self.profiles)

    def test_lower_rank_drift_remains_visible_without_invalidating_same_top_k(self):
        observations = self.observations()
        observations[0]["agreement"]["exactRankMatchCount"] = 39

        receipt = self.receipt(observations)

        self.assertEqual(receipt["outcome"], "pass")
        self.assertEqual(receipt["scales"][0]["state"], "pass")
        self.assertEqual(receipt["scales"][0]["agreement"]["exactRankMatchCount"], 119)

    def test_top_hit_or_top_k_set_disagreement_blocks_the_scale(self):
        observations = self.observations()
        observations[0]["agreement"]["overlapAtKCount"] -= 1

        receipt = self.receipt(observations)

        self.assertEqual(receipt["outcome"], "blocked")
        self.assertEqual(receipt["scales"][0]["state"], "agreement-failed")

    def test_unknown_content_fields_and_nonfinite_numbers_fail_closed(self):
        observations = self.observations()
        observations[0]["meetingTitle"] = "private meeting"
        with self.assertRaisesRegex(matrix.MatrixError, "forbidden meetingTitle"):
            self.receipt(observations)

        observations = self.observations()
        observations[0]["engines"][0]["buildMilliseconds"] = float("nan")
        with self.assertRaisesRegex(matrix.MatrixError, "must be finite"):
            self.receipt(observations)

    def test_configuration_engine_order_and_counts_fail_closed(self):
        observations = self.observations()
        observations[0]["configuration"]["runsPerQuery"] = 3
        with self.assertRaisesRegex(matrix.MatrixError, "runsPerQuery"):
            self.receipt(observations)

        observations = self.observations()
        observations[0]["engines"].reverse()
        with self.assertRaisesRegex(matrix.MatrixError, "canonical order"):
            self.receipt(observations)

        observations = self.observations()
        observations[0]["engines"][0]["queryWallMilliseconds"]["sampleCount"] = 39
        with self.assertRaisesRegex(matrix.MatrixError, "sampleCount"):
            self.receipt(observations)

    def test_integer_fields_reject_boolean_and_float_spellings(self):
        observations = self.observations()
        observations[0]["schemaVersion"] = True
        with self.assertRaisesRegex(matrix.MatrixError, "schemaVersion"):
            self.receipt(observations)

        observations = self.observations()
        observations[0]["configuration"]["dimension"] = 512.0
        with self.assertRaisesRegex(matrix.MatrixError, "dimension"):
            self.receipt(observations)

        observations = self.observations()
        observations[0]["agreement"]["comparisonCount"] = 40.0
        with self.assertRaisesRegex(matrix.MatrixError, "comparisonCount"):
            self.receipt(observations)

    def test_mixed_host_wrong_profile_and_duplicate_observation_fail_closed(self):
        observations = self.observations()
        observations[-1]["host"]["processorCount"] = 12
        with self.assertRaisesRegex(matrix.MatrixError, "different hosts"):
            self.receipt(observations)

        with self.assertRaisesRegex(matrix.MatrixError, "does not match host profile"):
            matrix.build_receipt(
                self.observations(),
                self.contract,
                self.profiles,
                "memory-8gb",
                self.commit,
                self.toolchain,
            )

        observations = self.observations()
        observations[1] = copy.deepcopy(observations[0])
        with self.assertRaisesRegex(matrix.MatrixError, "repeats an identical"):
            self.receipt(observations)

    def test_duplicate_json_keys_are_rejected_before_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "observations.jsonl"
            path.write_text('{"schemaVersion":1,"schemaVersion":1}\n')

            with self.assertRaisesRegex(matrix.MatrixError, "duplicate JSON key"):
                matrix.read_observations(path)

    def test_resource_profiles_require_the_shared_schema_three_contract(self):
        self.assertEqual(
            set(self.profiles),
            {"memory-8gb", "memory-16gb", "reference"},
        )
        source = json.loads(matrix.DEFAULT_RESOURCE_CONTRACT.read_text())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "resource-contract.json"

            stale = copy.deepcopy(source)
            stale["schemaVersion"] = 2
            path.write_text(json.dumps(stale))
            with self.assertRaisesRegex(matrix.MatrixError, "schemaVersion must be 3"):
                matrix.load_profiles(path)

            unsupported = copy.deepcopy(source)
            unsupported["preparations"][0]["marker"] = "stale-marker\n"
            path.write_text(json.dumps(unsupported))
            with self.assertRaisesRegex(matrix.MatrixError, "supported preparation"):
                matrix.load_profiles(path)

    def test_direct_empty_input_and_invalid_timestamp_fail_closed(self):
        with self.assertRaisesRegex(matrix.MatrixError, "observation stream is empty"):
            self.receipt([])

        with self.assertRaisesRegex(matrix.MatrixError, "UTC timestamp"):
            matrix.build_receipt(
                self.observations(),
                self.contract,
                self.profiles,
                "memory-16gb",
                self.commit,
                self.toolchain,
                generated_at="2026-99-01T00:00:00Z",
            )

    def test_cli_exit_codes_distinguish_pass_blocked_and_malformed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "observations.jsonl"
            observations = self.observations()

            passing = self.run_cli(path, observations)
            self.assertEqual(passing.returncode, 0)
            self.assertEqual(json.loads(passing.stdout)["outcome"], "pass")

            blocked = self.run_cli(path, observations[:-1])
            self.assertEqual(blocked.returncode, 1)
            self.assertEqual(json.loads(blocked.stdout)["outcome"], "blocked")

            path.write_text('{"schemaVersion":1,"schemaVersion":1}\n')
            malformed = self.cli(path)
            self.assertEqual(malformed.returncode, 2)
            self.assertEqual(malformed.stdout, "")
            self.assertIn("duplicate JSON key", malformed.stderr)

    def receipt(self, observations):
        return matrix.build_receipt(
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
        query_base = 10.0 + scale_index * 2.0 + repetition * 0.1
        candidate_base = 12.0 + scale_index * 3.0 + repetition * 0.1
        comparison_count = self.contract["queryCount"] * self.contract["runsPerQuery"]
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
                "queryCount": self.contract["queryCount"],
                "runsPerQuery": self.contract["runsPerQuery"],
                "resultLimit": self.contract["resultLimit"],
                "rawEmbeddingBytes": scale * self.contract["dimension"] * 4,
                "controlDatabaseBytes": scale * 2_200 + repetition * 4_096,
                "fixturePreparationMilliseconds": 20.0 + repetition,
                "buildOrder": matrix.BUILD_ORDER,
            },
            "engines": [
                self.engine("accelerateExact", 100.0 + repetition, query_base),
                self.engine("sqliteVecExact", 80.0 + repetition, candidate_base),
            ],
            "agreement": {
                "comparisonCount": comparison_count,
                "expectedTopHitCount": comparison_count,
                "topHitMatchCount": comparison_count,
                "exactRankMatchCount": comparison_count,
                "overlapAtKCount": comparison_count * self.contract["resultLimit"],
            },
        }

    def engine(self, name, build, query):
        return {
            "engine": name,
            "buildMilliseconds": build,
            "queryWallMilliseconds": {
                "sampleCount": self.contract["queryCount"]
                * self.contract["runsPerQuery"],
                "p50Milliseconds": query,
                "p95Milliseconds": query * 1.1,
                "maximumMilliseconds": query * 1.2,
            },
            "resultCount": self.contract["resultLimit"],
        }


if __name__ == "__main__":
    unittest.main()
