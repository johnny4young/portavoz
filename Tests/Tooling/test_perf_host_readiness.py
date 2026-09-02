import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "perf_host_readiness.py"
SPEC = importlib.util.spec_from_file_location("perf_host_readiness", SCRIPT)
readiness = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = readiness
SPEC.loader.exec_module(readiness)


class FakeClock:
    def __init__(self):
        self.value = 0.0

    def __call__(self):
        return self.value

    def sleep(self, seconds):
        self.value += seconds


def observation(**overrides):
    values = {
        "processor_count": 14,
        "total_cpu_percent": 120.0,
        "load_average_one_minute": 2.0,
        "interference_cpu_percent": 0.0,
        "power_source": "ac",
        "power_mode": "automatic",
        "thermal_state": "nominal",
        "interference_contributors": (),
    }
    values.update(overrides)
    if (
        "interference_contributors" not in overrides
        and values["interference_cpu_percent"] > 0
    ):
        values["interference_contributors"] = (
            ("swift-compiler", values["interference_cpu_percent"]),
        )
    return readiness.HostObservation(**values)


class PerformanceHostReadinessTests(unittest.TestCase):
    commit = "a" * 40
    binary = "b" * 64

    def setUp(self):
        self.policy = readiness.ReadinessPolicy(
            maximum_wait_seconds=8.0,
            sample_interval_seconds=1.0,
            required_consecutive_samples=3,
            maximum_cpu_capacity_fraction=0.25,
            maximum_load_per_processor=0.50,
            maximum_interference_cpu_percent=2.0,
        )

    def run_wait(self, samples):
        iterator = iter(samples)
        clock = FakeClock()
        return readiness.wait_for_readiness(
            policy=self.policy,
            source_commit=self.commit,
            binary_sha256=self.binary,
            sampler=lambda: next(iterator),
            clock=clock,
            sleeper=clock.sleep,
            generated_at="2026-08-30T20:00:00Z",
        )

    def test_ready_requires_three_consecutive_clean_samples(self):
        receipt = self.run_wait([
            observation(interference_cpu_percent=8.0),
            observation(),
            observation(),
            observation(),
        ])

        self.assertEqual(receipt["outcome"], "ready")
        self.assertEqual(receipt["observedSampleCount"], 4)
        self.assertEqual([item["sequence"] for item in receipt["samples"]], [2, 3, 4])
        self.assertTrue(all(not item["reasons"] for item in receipt["samples"]))

    def test_late_interference_resets_the_consecutive_window(self):
        receipt = self.run_wait([
            observation(),
            observation(),
            observation(load_average_one_minute=9.0),
            observation(),
            observation(),
            observation(),
        ])

        self.assertEqual(receipt["outcome"], "ready")
        self.assertEqual([item["sequence"] for item in receipt["samples"]], [4, 5, 6])

    def test_timeout_is_retained_as_blocked_not_retried_green(self):
        receipt = self.run_wait([
            observation(interference_cpu_percent=5.0) for _ in range(9)
        ])

        self.assertEqual(receipt["outcome"], "blocked")
        self.assertEqual(receipt["observedSampleCount"], 9)
        self.assertTrue(all(
            "build-or-symbolication" in item["reasons"]
            for item in receipt["samples"]
        ))
        self.assertTrue(all(
            item["interferenceContributors"] == [
                {"class": "swift-compiler", "cpuPercent": 5.0}
            ]
            for item in receipt["samples"]
        ))
        with self.assertRaisesRegex(readiness.ReadinessError, "did not become ready"):
            readiness.validate_receipt(
                receipt,
                policy=self.policy,
                expected_commit=self.commit,
                expected_binary_sha256=self.binary,
            )

    def test_every_host_dimension_is_part_of_the_predicate(self):
        cases = {
            "total-cpu": observation(total_cpu_percent=351.0),
            "load-average": observation(load_average_one_minute=7.1),
            "build-or-symbolication": observation(interference_cpu_percent=2.1),
            "power-source": observation(power_source="battery"),
            "power-mode": observation(power_mode="low-power"),
            "thermal-state": observation(thermal_state="pressured"),
        }
        for reason, sample in cases.items():
            with self.subTest(reason=reason):
                self.assertIn(reason, readiness.reasons_for(sample, self.policy))

    def test_process_parser_is_content_free_and_counts_interference(self):
        total, interference, contributors = readiness.parse_process_cpu(
            " 35.0 /Applications/ChatGPT.app/codex\n"
            " 12.5 /usr/libexec/coresymbolicationd\n"
            " 50.0 /usr/bin/swift-frontend\n"
            " 7.0 /usr/bin/xcodebuild\n"
        )
        self.assertEqual(total, 104.5)
        self.assertEqual(interference, 69.5)
        self.assertEqual(contributors, (
            ("build-driver", 7.0),
            ("swift-compiler", 50.0),
            ("symbolication", 12.5),
        ))

    def test_host_parsers_accept_current_nominal_macos_shapes(self):
        self.assertEqual(readiness.parse_load_average("{ 3.87 4.48 4.89 }\n"), 3.87)
        self.assertEqual(
            readiness.parse_power_source("Now drawing from 'AC Power'\n"),
            "ac",
        )
        self.assertEqual(
            readiness.parse_power_mode(
                "Battery Power:\n powermode 1\nAC Power:\n powermode 0\n",
                "ac",
            ),
            "automatic",
        )
        self.assertEqual(
            readiness.parse_thermal_state(
                "Note: No thermal warning level has been recorded\n"
                "Note: No performance warning level has been recorded\n"
            ),
            "nominal",
        )
        self.assertEqual(
            readiness.parse_thermal_state("CPU_Speed_Limit = 80\n"),
            "pressured",
        )
        self.assertEqual(
            readiness.parse_thermal_state(
                "CPU_Available_CPUs = 14\nCPU_Speed_Limit = 100\n"
            ),
            "nominal",
        )

    def test_receipt_rejects_tampered_identity_policy_and_reasons(self):
        receipt = self.run_wait([observation(), observation(), observation()])
        cases = []
        wrong_commit = copy.deepcopy(receipt)
        wrong_commit["sourceCommit"] = "c" * 40
        cases.append((wrong_commit, "source commit changed"))
        wrong_binary = copy.deepcopy(receipt)
        wrong_binary["binarySHA256"] = "d" * 64
        cases.append((wrong_binary, "binary SHA-256 changed"))
        wrong_policy = copy.deepcopy(receipt)
        wrong_policy["policy"]["maximumWaitSeconds"] = 5.0
        cases.append((wrong_policy, "policy drifted"))
        wrong_reasons = copy.deepcopy(receipt)
        wrong_reasons["samples"][0]["reasons"] = ["total-cpu"]
        cases.append((wrong_reasons, "reasons do not match"))
        unknown_contributor = copy.deepcopy(receipt)
        unknown_contributor["samples"][0]["interferenceContributors"] = [
            {"class": "private-process-name", "cpuPercent": 1.0}
        ]
        cases.append((unknown_contributor, "interference class is invalid"))
        mismatched_contribution = copy.deepcopy(receipt)
        mismatched_contribution["samples"][0]["interferenceContributors"] = [
            {"class": "swift-compiler", "cpuPercent": 1.0}
        ]
        cases.append((mismatched_contribution, "contributions do not sum"))
        for document, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(
                readiness.ReadinessError, message
            ):
                readiness.validate_receipt(
                    document,
                    policy=self.policy,
                    expected_commit=self.commit,
                    expected_binary_sha256=self.binary,
                )

    def test_private_writer_refuses_to_overwrite_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "readiness.json"
            readiness.write_private_json(path, {"schemaVersion": 1})
            self.assertEqual(json.loads(path.read_text()), {"schemaVersion": 1})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaisesRegex(readiness.ReadinessError, "already exists"):
                readiness.write_private_json(path, {"schemaVersion": 1})


if __name__ == "__main__":
    unittest.main()
