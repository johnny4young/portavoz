import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from Tests.Tooling import test_exact_path_matrix as host_test


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "exact_path_cross_host.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("exact_path_cross_host", SCRIPT)
cross_host = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(cross_host)


class ExactPathCrossHostTests(unittest.TestCase):
    commit = "a" * 40
    toolchain = host_test.ExactPathMatrixTests.toolchain
    memory = {
        "memory-8gb": 8 * 1024**3,
        "memory-16gb": 16 * 1024**3,
        "reference": 36 * 1024**3,
    }

    def setUp(self):
        self.host_case = host_test.ExactPathMatrixTests()
        self.host_case.setUp()
        self.host_contract = self.host_case.contract
        self.profiles = self.host_case.profiles
        self.contract = cross_host.load_contract(
            cross_host.DEFAULT_CONTRACT,
            self.host_contract,
        )

    def test_complete_comparable_three_profile_two_os_matrix_passes(self):
        scorecard = self.scorecard(self.receipts())

        self.assertEqual(scorecard["outcome"], "pass")
        self.assertEqual(scorecard["coverage"]["missingHostProfiles"], [])
        self.assertEqual(scorecard["coverage"]["presentOperatingSystemMajors"], [15, 26])
        self.assertTrue(scorecard["comparability"]["sameSourceCommit"])
        self.assertTrue(scorecard["comparability"]["sameToolchain"])
        self.assertEqual(
            scorecard["comparisonPolicyVersion"],
            "within-host-query-p50-p95-ratio-v1",
        )
        self.assertEqual([row["state"] for row in scorecard["profiles"]], ["pass"] * 3)
        first_scale = scorecard["profiles"][0]["scales"][0]
        self.assertGreater(first_scale["candidateToControlQueryP50Ratio"], 0)
        self.assertEqual(first_scale["exactRankAgreementRate"], 1.0)

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
            "operatorNotes",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_missing_profile_or_os_coverage_produces_blocked_scorecard(self):
        receipts = self.receipts()
        missing_profile = self.scorecard(receipts[:-1])
        self.assertEqual(missing_profile["outcome"], "blocked")
        self.assertEqual(missing_profile["coverage"]["missingHostProfiles"], ["reference"])
        self.assertEqual(missing_profile["profiles"][-1]["state"], "missing")

        tahoe_only = self.receipts(os_majors=(26, 26, 26))
        missing_os = self.scorecard(tahoe_only)
        self.assertEqual(missing_os["outcome"], "blocked")
        self.assertEqual(missing_os["coverage"]["missingOperatingSystemMajors"], [15])

    def test_source_or_toolchain_mismatch_is_visible_and_blocks_comparison(self):
        receipts = self.receipts()
        receipts[-1] = self.receipt(
            "reference",
            26,
            commit="b" * 40,
            toolchain="Apple Swift version 6.3.0 (swiftlang-6.3.0.1 clang-1800.1)",
        )

        scorecard = self.scorecard(receipts)

        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertFalse(scorecard["comparability"]["sameSourceCommit"])
        self.assertFalse(scorecard["comparability"]["sameToolchain"])
        self.assertEqual(len(scorecard["comparability"]["sourceCommits"]), 2)
        self.assertEqual(len(scorecard["comparability"]["toolchains"]), 2)

    def test_valid_blocked_host_receipt_blocks_without_becoming_malformed(self):
        receipts = self.receipts()
        receipts[1] = self.receipt("memory-16gb", 26, agreement_failure=True)

        scorecard = self.scorecard(receipts)

        self.assertEqual(scorecard["outcome"], "blocked")
        profile = scorecard["profiles"][1]
        self.assertEqual(profile["state"], "blocked")
        self.assertEqual(profile["scales"][0]["state"], "agreement-failed")
        self.assertGreater(
            profile["scales"][0]["candidateToControlQueryP50Ratio"],
            0,
        )

    def test_zero_control_timing_is_not_reported_as_equal_performance(self):
        receipts = self.receipts()
        receipts[0] = self.receipt("memory-8gb", 15, zero_control_timing=True)

        scorecard = self.scorecard(receipts)

        self.assertEqual(scorecard["outcome"], "blocked")
        profile = scorecard["profiles"][0]
        self.assertEqual(profile["state"], "not-comparable")
        self.assertEqual(profile["scales"][0]["state"], "not-comparable")
        self.assertIsNone(
            profile["scales"][0]["candidateToControlQueryP50Ratio"]
        )

    def test_tampered_receipt_payload_and_state_fail_closed(self):
        receipts = self.receipts()
        receipts[0]["meetingTitle"] = "private meeting"
        with self.assertRaisesRegex(cross_host.CrossHostError, "forbidden meetingTitle"):
            self.scorecard(receipts)

        receipts = self.receipts()
        receipts[0]["outcome"] = "blocked"
        with self.assertRaisesRegex(cross_host.CrossHostError, "outcome is inconsistent"):
            self.scorecard(receipts)

        receipts = self.receipts()
        receipts[0]["generatedAt"] = "2026-99-01T00:00:00Z"
        with self.assertRaisesRegex(cross_host.CrossHostError, "UTC timestamp"):
            self.scorecard(receipts)

        receipts = self.receipts()
        receipts[0]["scales"][0]["engines"][0][
            "maximumWithinObservationTimingP95ToP50Ratio"
        ] = True
        with self.assertRaisesRegex(cross_host.CrossHostError, "must be numeric"):
            self.scorecard(receipts)

        receipts = self.receipts()
        p50 = receipts[0]["scales"][0]["engines"][0][
            "queryWallMilliseconds"
        ]["p50Observation"]
        p50.update({"p50": 100.0, "p95": 101.0, "maximum": 102.0})
        with self.assertRaisesRegex(cross_host.CrossHostError, "not monotonic"):
            self.scorecard(receipts)

    def test_duplicate_receipt_or_profile_is_malformed(self):
        receipts = self.receipts()
        receipts.append(copy.deepcopy(receipts[0]))
        with self.assertRaisesRegex(cross_host.CrossHostError, "identical receipt"):
            self.scorecard(receipts)

        receipts = self.receipts()
        receipts[-1] = self.receipt("memory-16gb", 15)
        with self.assertRaisesRegex(cross_host.CrossHostError, "repeats profile"):
            self.scorecard(receipts)

    def test_empty_stream_is_a_complete_blocked_scorecard(self):
        scorecard = self.scorecard([])

        self.assertEqual(scorecard["outcome"], "blocked")
        self.assertEqual(
            scorecard["coverage"]["missingHostProfiles"],
            ["memory-8gb", "memory-16gb", "reference"],
        )
        self.assertEqual(scorecard["coverage"]["missingOperatingSystemMajors"], [15, 26])

    def test_contract_coverage_and_comparison_policy_cannot_be_weakened(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "contract.json"
            raw = json.loads(cross_host.DEFAULT_CONTRACT.read_text())
            for key in ("requiredHostProfiles", "requiredOperatingSystemMajors"):
                weakened = copy.deepcopy(raw)
                weakened[key].pop()
                path.write_text(json.dumps(weakened))
                with self.assertRaises(cross_host.CrossHostError):
                    cross_host.load_contract(path, self.host_contract)

            weakened = copy.deepcopy(raw)
            weakened["comparisonPolicyVersion"] = "unversioned"
            path.write_text(json.dumps(weakened))
            with self.assertRaisesRegex(cross_host.CrossHostError, "comparison policy"):
                cross_host.load_contract(path, self.host_contract)

    def test_scorecard_timestamp_must_be_real_utc(self):
        with self.assertRaisesRegex(cross_host.CrossHostError, "UTC timestamp"):
            cross_host.build_scorecard(
                self.receipts(),
                self.contract,
                self.host_contract,
                self.profiles,
                generated_at="2026-99-01T00:00:00Z",
            )

    def test_duplicate_json_keys_are_rejected_before_receipt_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipts.jsonl"
            path.write_text('{"schemaVersion":2,"schemaVersion":2}\n')

            with self.assertRaisesRegex(cross_host.CrossHostError, "duplicate JSON key"):
                cross_host.read_receipts(path)

    def test_cli_exit_codes_distinguish_pass_blocked_and_malformed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipts.jsonl"

            passing = self.run_cli(path, self.receipts())
            self.assertEqual(passing.returncode, 0)
            self.assertEqual(json.loads(passing.stdout)["outcome"], "pass")

            blocked = self.run_cli(path, self.receipts()[:-1])
            self.assertEqual(blocked.returncode, 1)
            self.assertEqual(json.loads(blocked.stdout)["outcome"], "blocked")

            path.write_text('{"schemaVersion":2,"schemaVersion":2}\n')
            malformed = self.cli(path)
            self.assertEqual(malformed.returncode, 2)
            self.assertEqual(malformed.stdout, "")
            self.assertIn("duplicate JSON key", malformed.stderr)

    def receipts(self, os_majors=(15, 26, 26)):
        return [
            self.receipt("memory-8gb", os_majors[0]),
            self.receipt("memory-16gb", os_majors[1]),
            self.receipt("reference", os_majors[2]),
        ]

    def receipt(
        self,
        profile,
        os_major,
        *,
        commit=None,
        toolchain=None,
        agreement_failure=False,
        zero_control_timing=False,
    ):
        observations = self.host_case.observations()
        for observation in observations:
            observation["host"] = {
                "operatingSystem": f"Version {os_major}.1 (Build 25A123)",
                "architecture": "arm64",
                "processorCount": 10,
                "physicalMemoryBytes": self.memory[profile],
            }
        if agreement_failure:
            observations[0]["agreement"]["overlapAtKCount"] -= 1
        if zero_control_timing:
            for observation in observations:
                distribution = observation["engines"][0]["queryWallMilliseconds"]
                distribution.update(
                    {
                        "p50Milliseconds": 0.0,
                        "p95Milliseconds": 0.0,
                        "maximumMilliseconds": 0.0,
                    }
                )
        return cross_host.host_matrix.build_receipt(
            observations,
            self.host_contract,
            self.profiles,
            profile,
            commit or self.commit,
            toolchain or self.toolchain,
            generated_at="2026-08-01T12:00:00Z",
        )

    def scorecard(self, receipts):
        return cross_host.build_scorecard(
            receipts,
            self.contract,
            self.host_contract,
            self.profiles,
            generated_at="2026-08-01T13:00:00Z",
        )

    def run_cli(self, path, receipts):
        path.write_text("".join(json.dumps(receipt) + "\n" for receipt in receipts))
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
