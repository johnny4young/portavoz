import copy
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "exact_path_mutation_cross_host.py"
SPEC = importlib.util.spec_from_file_location(
    "exact_path_mutation_cross_host",
    SCRIPT,
)
cross_host = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(cross_host)


class ExactPathMutationCrossHostTests(unittest.TestCase):
    commit = "c" * 40
    toolchain = "Apple Swift version 6.2.3 (swiftlang-6.2.3.1.4 clang-1700.6.3.2)"

    def setUp(self):
        self.host_contract = cross_host.host_matrix.load_contract(
            cross_host.host_matrix.DEFAULT_CONTRACT
        )
        self.profiles = cross_host.foundation.load_profiles(
            cross_host.host_matrix.DEFAULT_RESOURCE_CONTRACT
        )
        self.contract = cross_host.load_contract(
            cross_host.DEFAULT_CONTRACT,
            self.host_contract,
        )

    def test_complete_comparable_matrix_requires_review_and_has_no_ratios(self):
        receipts = self.receipts()

        scorecard = self.scorecard(receipts)

        self.assertEqual(scorecard["schemaVersion"], 1)
        self.assertEqual(scorecard["outcome"], "review-required")
        self.assertEqual(
            scorecard["crossHostReviewPolicyVersion"],
            "human-threshold-free-mutation-cross-host-review-v1",
        )
        self.assertEqual(
            scorecard["coverage"]["presentHostProfiles"],
            ["memory-8gb", "memory-16gb", "reference"],
        )
        self.assertEqual(
            scorecard["coverage"]["presentOperatingSystemMajors"],
            [15, 26],
        )
        self.assertTrue(scorecard["comparability"]["sameSourceCommit"])
        self.assertTrue(scorecard["comparability"]["sameToolchain"])
        self.assertTrue(
            all(row["state"] == "review-required" for row in scorecard["profiles"])
        )
        encoded = json.dumps(scorecard, sort_keys=True)
        for forbidden in (
            "segmentID",
            "meetingID",
            "transcript",
            "queryVector",
            "modelIdentifier",
            "databasePath",
            "filePath",
            "rawError",
            "candidateToControl",
            "performanceRatio",
            "speedup",
            "minimumPerformanceImprovement",
            "maximumTimingP95ToP50Ratio",
        ):
            self.assertNotIn(forbidden, encoded)
        self.assertEqual(
            cross_host.validate_scorecard_against_receipts(
                scorecard,
                receipts,
                self.contract,
                self.host_contract,
                self.profiles,
            ),
            scorecard,
        )

    def test_missing_profile_or_os_coverage_is_blocked(self):
        scorecard = self.scorecard(self.receipts()[:-1])
        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertEqual(scorecard["coverage"]["missingHostProfiles"], ["reference"])
        self.assertEqual(scorecard["profiles"][-1]["state"], "missing")

        receipts = self.receipts()
        receipts[0] = self.receipt("memory-8gb", 8, 26, 8)
        scorecard = self.scorecard(receipts)
        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertEqual(scorecard["coverage"]["missingOperatingSystemMajors"], [15])

    def test_source_or_toolchain_mismatch_is_visible_and_blocked(self):
        receipts = self.receipts()
        receipts[-1]["sourceCommit"] = "d" * 40
        scorecard = self.scorecard(receipts)
        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertFalse(scorecard["comparability"]["sameSourceCommit"])

        receipts = self.receipts()
        receipts[-1]["toolchain"] = (
            "Apple Swift version 6.2.4 (swiftlang-6.2.4 clang-1700.6.4)"
        )
        scorecard = self.scorecard(receipts)
        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertFalse(scorecard["comparability"]["sameToolchain"])

    def test_blocked_host_receipt_blocks_cross_host_review(self):
        receipts = self.receipts()
        receipts[1] = self.receipt("memory-16gb", 16, 26, 10, complete=False)

        scorecard = self.scorecard(receipts)

        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertEqual(scorecard["profiles"][1]["state"], "blocked")

    def test_tampered_host_receipt_is_malformed_not_merely_blocked(self):
        receipts = self.receipts()
        receipts[0]["profiles"] = []
        with self.assertRaisesRegex(
            cross_host.CrossHostMutationError,
            "forbidden profiles",
        ):
            self.scorecard(receipts)

        receipts = self.receipts()
        receipts[0]["scales"][0]["state"] = "agreement-failed"
        with self.assertRaisesRegex(
            cross_host.CrossHostMutationError,
            "state is inconsistent",
        ):
            self.scorecard(receipts)

    def test_duplicate_receipt_or_profile_is_malformed(self):
        receipts = self.receipts()
        with self.assertRaisesRegex(
            cross_host.CrossHostMutationError,
            "repeats an identical receipt",
        ):
            self.scorecard([*receipts, copy.deepcopy(receipts[0])])

        duplicate_profile = self.receipt("memory-8gb", 8, 15, 8)
        duplicate_profile["generatedAt"] = "2026-08-01T13:00:00Z"
        with self.assertRaisesRegex(
            cross_host.CrossHostMutationError,
            "repeats profile",
        ):
            self.scorecard([*receipts, duplicate_profile])

    def test_empty_stream_is_a_complete_blocked_scorecard(self):
        scorecard = self.scorecard([])

        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertEqual(
            scorecard["coverage"]["missingHostProfiles"],
            ["memory-8gb", "memory-16gb", "reference"],
        )
        self.assertFalse(scorecard["comparability"]["sameSourceCommit"])
        self.assertFalse(scorecard["comparability"]["sameToolchain"])

    def test_contract_identity_and_coverage_cannot_be_weakened(self):
        contract = copy.deepcopy(self.contract)
        contract["requiredHostProfiles"] = ["memory-16gb"]
        with self.assertRaisesRegex(
            cross_host.CrossHostMutationError,
            "profiles are not supported",
        ):
            self.load_contract_value(contract)

        contract = copy.deepcopy(self.contract)
        contract["hostReviewPolicyVersion"] = "automatic-pass-v1"
        with self.assertRaisesRegex(
            cross_host.CrossHostMutationError,
            "host review policy is inconsistent",
        ):
            self.load_contract_value(contract)

        contract = copy.deepcopy(self.contract)
        contract["minimumPerformanceImprovement"] = 0.3
        with self.assertRaisesRegex(
            cross_host.CrossHostMutationError,
            "forbidden minimumPerformanceImprovement",
        ):
            self.load_contract_value(contract)

    def test_scorecard_timestamp_must_be_real_utc(self):
        with self.assertRaisesRegex(
            cross_host.CrossHostMutationError,
            "UTC timestamp",
        ):
            cross_host.build_scorecard(
                self.receipts(),
                self.contract,
                self.host_contract,
                self.profiles,
                generated_at="2026-99-01T00:00:00Z",
            )

    def test_scorecard_recomputes_exactly_and_rejects_tampering(self):
        receipts = self.receipts()
        original_receipts = copy.deepcopy(receipts)
        scorecard = self.scorecard(receipts)
        scorecard["profiles"][0]["host"]["processorCount"] += 1
        scorecard["profiles"][0]["scales"][0][
            "fixturePreparationMilliseconds"
        ]["p50"] += 1
        scorecard["profiles"][0]["scales"][0]["engines"][0][
            "fullRebuildMilliseconds"
        ]["p50"] += 1

        self.assertEqual(receipts, original_receipts)

        with self.assertRaisesRegex(
            cross_host.CrossHostMutationError,
            "does not exactly match",
        ):
            cross_host.validate_scorecard_against_receipts(
                scorecard,
                receipts,
                self.contract,
                self.host_contract,
                self.profiles,
            )

    def test_duplicate_json_keys_are_rejected_before_validation(self):
        with self.assertRaisesRegex(
            cross_host.CrossHostMutationError,
            "duplicate JSON key",
        ):
            cross_host.parse_receipts('{"schemaVersion":1,"schemaVersion":1}\n')

    def test_cli_exit_codes_distinguish_review_blocked_and_malformed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipts.jsonl"
            review = self.run_cli(path, self.receipts())
            self.assertEqual(review.returncode, 0)
            self.assertEqual(json.loads(review.stdout)["outcome"], "review-required")

            blocked = self.run_cli(path, self.receipts()[:-1])
            self.assertEqual(blocked.returncode, 1)
            self.assertEqual(json.loads(blocked.stdout)["outcome"], "blocked")

            path.write_text('{"schemaVersion":1,"schemaVersion":1}\n')
            malformed = self.cli(path)
            self.assertEqual(malformed.returncode, 2)
            self.assertEqual(malformed.stdout, "")
            self.assertIn("duplicate JSON key", malformed.stderr)

    def scorecard(self, receipts):
        return cross_host.build_scorecard(
            receipts,
            self.contract,
            self.host_contract,
            self.profiles,
            generated_at="2026-08-01T14:00:00Z",
        )

    def receipts(self):
        return [
            self.receipt("memory-8gb", 8, 15, 8),
            self.receipt("memory-16gb", 16, 26, 10),
            self.receipt("reference", 64, 26, 12),
        ]

    def receipt(
        self,
        profile,
        memory_gib,
        os_major,
        processor_count,
        complete=True,
    ):
        observations = []
        for scale_index, scale in enumerate(self.host_contract["canonicalScales"]):
            for repetition in range(3):
                observations.append(
                    self.observation(
                        scale,
                        scale_index,
                        repetition,
                        memory_gib,
                        os_major,
                        processor_count,
                    )
                )
        if not complete:
            observations.pop()
        return cross_host.host_matrix.build_receipt(
            observations,
            self.host_contract,
            self.profiles,
            profile,
            self.commit,
            self.toolchain,
            generated_at=f"2026-08-01T1{os_major % 10}:00:00Z",
        )

    def observation(
        self,
        scale,
        scale_index,
        repetition,
        memory_gib,
        os_major,
        processor_count,
    ):
        comparisons, expected_hits = cross_host.host_matrix.expected_agreement(
            self.host_contract
        )
        return {
            "schemaVersion": 1,
            "fixtureVersion": self.host_contract["fixtureVersion"],
            "measurementPolicyVersion": self.host_contract[
                "measurementPolicyVersion"
            ],
            "buildConfiguration": "release",
            "host": {
                "operatingSystem": f"Version {os_major}.0 (Build 25A123)",
                "architecture": "arm64",
                "processorCount": processor_count,
                "physicalMemoryBytes": memory_gib * 1024**3,
            },
            "configuration": {
                "corpusSize": scale,
                "dimension": self.host_contract["dimension"],
                "runsPerBatch": self.host_contract["runsPerBatch"],
                "resultLimit": self.host_contract["resultLimit"],
                "batchSizes": self.host_contract["batchSizes"],
                "rawEmbeddingBytes": scale * self.host_contract["dimension"] * 4,
                "fixturePreparationMilliseconds": 2.0 + repetition * 0.1,
                "rebuildLifecycle": self.host_contract["rebuildLifecycle"],
                "mutationLifecycle": self.host_contract["mutationLifecycle"],
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
        for batch_index, batch_size in enumerate(self.host_contract["batchSizes"]):
            for operation_index, operation in enumerate(
                cross_host.host_matrix.OPERATION_ORDER
            ):
                base = rebuild / 100 + batch_index + operation_index * 0.1
                mutations.append({
                    "operation": operation,
                    "batchSize": batch_size,
                    "wallMilliseconds": {
                        "sampleCount": self.host_contract["runsPerBatch"],
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

    def load_contract_value(self, value):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "contract.json"
            path.write_text(json.dumps(value))
            return cross_host.load_contract(path, self.host_contract)

    def run_cli(self, path, receipts):
        path.write_text(
            "".join(json.dumps(receipt) + "\n" for receipt in receipts)
        )
        return self.cli(path)

    def cli(self, path):
        return subprocess.run(
            ["python3", str(SCRIPT), "--input", str(path)],
            check=False,
            capture_output=True,
            text=True,
        )


if __name__ == "__main__":
    unittest.main()
