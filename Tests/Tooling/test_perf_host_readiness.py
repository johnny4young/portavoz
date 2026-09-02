import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from subprocess import CompletedProcess


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
        "active_portavoz_app_count": 0,
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


def calibration(*, wall=160.0, cpu=159.0):
    return readiness.ThroughputCalibration(
        wall_milliseconds=(wall,) * 5,
        cpu_milliseconds=(cpu,) * 5,
    )


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

    def run_wait(self, samples, calibrations=None):
        iterator = iter(samples)
        calibration_iterator = iter(calibrations or [calibration()])
        clock = FakeClock()
        return readiness.wait_for_readiness(
            policy=self.policy,
            source_commit=self.commit,
            binary_sha256=self.binary,
            sampler=lambda: next(iterator),
            calibrator=lambda: next(calibration_iterator),
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
        self.assertEqual(receipt["calibrationAttemptCount"], 1)
        self.assertEqual(receipt["throughputCalibration"]["reasons"], [])

    def test_default_dense_window_rejects_periodic_symbolication_bursts(self):
        policy = readiness.ReadinessPolicy(maximum_wait_seconds=4.5)
        clock = FakeClock()
        periodic = iter(
            [
                observation(),
                observation(),
                observation(
                    interference_cpu_percent=10.0,
                    interference_contributors=(("symbolication", 10.0),),
                ),
            ]
            * 3
            + [observation()]
        )

        receipt = readiness.wait_for_readiness(
            policy=policy,
            source_commit=self.commit,
            binary_sha256=self.binary,
            sampler=lambda: next(periodic),
            calibrator=lambda: self.fail("periodic host must not calibrate"),
            clock=clock,
            sleeper=clock.sleep,
            generated_at="2026-09-02T17:00:00Z",
        )

        self.assertEqual(readiness.DEFAULT_SAMPLE_INTERVAL_SECONDS, 0.5)
        self.assertEqual(readiness.DEFAULT_REQUIRED_CONSECUTIVE_SAMPLES, 10)
        self.assertEqual(receipt["outcome"], "blocked")
        self.assertEqual(receipt["observedSampleCount"], 10)
        self.assertEqual(receipt["calibrationAttemptCount"], 0)
        self.assertTrue(any(item["reasons"] for item in receipt["samples"]))

    def test_slow_calibration_resets_passive_window_before_admission(self):
        receipt = self.run_wait(
            [observation() for _ in range(6)],
            calibrations=[calibration(wall=240, cpu=230), calibration()],
        )

        self.assertEqual(receipt["outcome"], "ready")
        self.assertEqual(receipt["observedSampleCount"], 6)
        self.assertEqual(receipt["calibrationAttemptCount"], 2)
        self.assertEqual(
            [item["sequence"] for item in receipt["samples"]],
            [4, 5, 6],
        )
        self.assertEqual(receipt["throughputCalibration"]["reasons"], [])

    def test_calibration_dispersion_blocks_at_the_bounded_deadline(self):
        receipt = self.run_wait(
            [observation() for _ in range(9)],
            calibrations=[calibration(wall=240, cpu=230)] * 3,
        )

        self.assertEqual(receipt["outcome"], "blocked")
        self.assertEqual(receipt["calibrationAttemptCount"], 2)
        self.assertEqual(
            receipt["throughputCalibration"]["reasons"],
            ["cpu-ceiling", "wall-ceiling"],
        )

    def test_clean_calibration_finishing_after_deadline_cannot_admit_host(self):
        clock = FakeClock()

        def calibrator():
            clock.value += 6.5
            return calibration()

        receipt = readiness.wait_for_readiness(
            policy=self.policy,
            source_commit=self.commit,
            binary_sha256=self.binary,
            sampler=observation,
            calibrator=calibrator,
            clock=clock,
            sleeper=clock.sleep,
            generated_at="2026-08-30T20:00:00Z",
        )

        self.assertEqual(receipt["outcome"], "blocked")
        self.assertEqual(receipt["elapsedSeconds"], 8.5)
        self.assertEqual(receipt["calibrationAttemptCount"], 1)
        self.assertEqual(receipt["throughputCalibration"]["reasons"], [])

    def test_passive_window_at_deadline_does_not_start_calibration(self):
        clock = FakeClock()
        calibration_calls = 0
        policy = readiness.ReadinessPolicy(
            maximum_wait_seconds=2.0,
            sample_interval_seconds=1.0,
            required_consecutive_samples=3,
        )

        def calibrator():
            nonlocal calibration_calls
            calibration_calls += 1
            return calibration()

        receipt = readiness.wait_for_readiness(
            policy=policy,
            source_commit=self.commit,
            binary_sha256=self.binary,
            sampler=observation,
            calibrator=calibrator,
            clock=clock,
            sleeper=clock.sleep,
            generated_at="2026-08-30T20:00:00Z",
        )

        self.assertEqual(receipt["outcome"], "blocked")
        self.assertEqual(receipt["elapsedSeconds"], 2.0)
        self.assertEqual(calibration_calls, 0)
        self.assertEqual(receipt["calibrationAttemptCount"], 0)
        self.assertIsNone(receipt["throughputCalibration"])

    def test_calibration_summary_is_recomputed_and_flags_dispersion(self):
        document = readiness.calibration_document(
            readiness.ThroughputCalibration(
                wall_milliseconds=(150, 150, 151, 152, 180),
                cpu_milliseconds=(149, 150, 150, 151, 151),
            ),
            self.policy,
        )

        self.assertEqual(document["wallP50Milliseconds"], 151)
        self.assertEqual(document["wallP95Milliseconds"], 180)
        self.assertEqual(document["reasons"], ["dispersion"])
        self.assertEqual(
            readiness.validate_calibration_document(document, self.policy),
            document,
        )

    def test_calibration_work_and_sample_count_cannot_be_weakened(self):
        for policy in (
            readiness.ReadinessPolicy(calibration_sample_count=4),
            readiness.ReadinessPolicy(calibration_bytes_per_sample=1024),
        ):
            with self.assertRaises(readiness.ReadinessError):
                policy.validate()

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
            "portavoz-app-active": observation(active_portavoz_app_count=1),
            "power-source": observation(power_source="battery"),
            "power-mode": observation(power_mode="low-power"),
            "thermal-state": observation(thermal_state="pressured"),
        }
        for reason, sample in cases.items():
            with self.subTest(reason=reason):
                self.assertIn(reason, readiness.reasons_for(sample, self.policy))

    def test_process_parser_is_content_free_and_counts_interference(self):
        total, interference, contributors, active_portavoz_apps = (
            readiness.parse_process_cpu(
                " 35.0 /Applications/ChatGPT.app/codex\n"
                " 12.5 /usr/libexec/coresymbolicationd\n"
                " 50.0 /usr/bin/swift-frontend\n"
                " 7.0 /usr/bin/xcodebuild\n"
                " 0.0 /Applications/Portavoz Dev.app/Contents/MacOS/portavoz-app\n"
                " 0.0 /tmp/portavoz-app-helper\n"
            )
        )
        self.assertEqual(total, 104.5)
        self.assertEqual(interference, 69.5)
        self.assertEqual(contributors, (
            ("build-driver", 7.0),
            ("swift-compiler", 50.0),
            ("symbolication", 12.5),
        ))
        self.assertEqual(active_portavoz_apps, 1)

    def test_active_app_probe_matches_only_the_exact_executable_basename(self):
        def runner(command, **kwargs):
            self.assertEqual(command, ["/bin/ps", "-A", "-o", "comm="])
            self.assertEqual(kwargs["timeout"], 5)
            return CompletedProcess(
                command,
                0,
                stdout=(
                    "/Applications/Portavoz.app/Contents/MacOS/portavoz-app\n"
                    "/tmp/portavoz-app-helper\n"
                    "/usr/bin/python3\n"
                ),
                stderr="",
            )

        self.assertEqual(
            readiness.probe_active_portavoz_app_count(command_runner=runner),
            1,
        )

    def test_active_app_probe_fails_closed_when_inventory_is_unavailable(self):
        def runner(command, **kwargs):
            return CompletedProcess(command, 1, stdout="", stderr="denied")

        with self.assertRaisesRegex(
            readiness.ReadinessError,
            "process executable probe unavailable",
        ):
            readiness.probe_active_portavoz_app_count(command_runner=runner)

    def test_zero_cpu_portavoz_app_blocks_without_starting_calibration(self):
        clock = FakeClock()
        policy = readiness.ReadinessPolicy(maximum_wait_seconds=1.0)
        receipt = readiness.wait_for_readiness(
            policy=policy,
            source_commit=self.commit,
            binary_sha256=self.binary,
            sampler=lambda: observation(active_portavoz_app_count=1),
            calibrator=lambda: self.fail("active app must not calibrate"),
            clock=clock,
            sleeper=clock.sleep,
            generated_at="2026-09-02T20:00:00Z",
        )

        self.assertEqual(receipt["outcome"], "blocked")
        self.assertEqual(receipt["calibrationAttemptCount"], 0)
        self.assertTrue(all(
            sample["activePortavozAppCount"] == 1
            and sample["reasons"] == ["portavoz-app-active"]
            for sample in receipt["samples"]
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
        unreported_app = copy.deepcopy(receipt)
        unreported_app["samples"][0]["activePortavozAppCount"] = 1
        cases.append((unreported_app, "reasons do not match"))
        invalid_app_count = copy.deepcopy(receipt)
        invalid_app_count["samples"][0]["activePortavozAppCount"] = True
        cases.append((invalid_app_count, "must be an integer"))
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
        inconsistent_calibration = copy.deepcopy(receipt)
        inconsistent_calibration["throughputCalibration"][
            "wallP95Milliseconds"
        ] = 1.0
        cases.append((inconsistent_calibration, "summary is inconsistent"))
        deadline_overrun = copy.deepcopy(receipt)
        deadline_overrun["elapsedSeconds"] = self.policy.maximum_wait_seconds + 0.1
        cases.append((deadline_overrun, "exceeded the admission deadline"))
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
