import copy
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import apuntador_leak_baseline as leaks  # noqa: E402


COMMIT = "a" * 40
BUILD = "202608301200"


class ApuntadorLeakBaselineTests(unittest.TestCase):
    def setUp(self):
        self.contract = leaks.load_contract()
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def write_json(self, name, document):
        path = self.root / name
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def write_log(self, text):
        path = self.root / "leaks.log"
        path.write_text(text, encoding="utf-8")
        return path

    @staticmethod
    def resource_sample():
        return {
            "run": 1,
            "wallDurationMilliseconds": 20.0,
            "cpuTimeMilliseconds": 10.0,
            "peakPhysicalFootprintBytes": 1024,
            "energyNanojoules": 0,
            "diskReadBytes": 0,
            "diskWrittenBytes": 0,
            "minimumAvailableDiskBytes": 1024,
            "maximumThermalState": "nominal",
            "powerSource": "ac",
            "lowPowerModeEnabled": False,
            "workloads": [],
        }

    @staticmethod
    def fragment(identifier):
        evidence = {
            key: "b" * 64
            for key in leaks.load_contract()["scenarios"][identifier]["evidence"]
        }
        return {
            "schemaVersion": leaks.SCHEMA_VERSION,
            "kind": "apuntador-leak-observation",
            "scenario": identifier,
            "iterations": (
                leaks.LIVE_ASSIST_ITERATIONS
                if leaks.load_contract()["scenarios"][identifier]["kind"]
                == "live-assist"
                else leaks.SINGLE_WORKLOAD_ITERATIONS
            ),
            "leaksExitCode": 0,
            "leakCount": 0,
            "leakedBytes": 0,
            "evidenceSHA256": evidence,
        }

    def observe_indexing(self, log_text=None, exit_code=0):
        resource = self.write_json("indexing-1.json", self.resource_sample())
        log = self.write_log(
            log_text or "bench-indexing: resource sample complete\n"
        )
        return leaks.observe_run(
            self.contract,
            scenario_id="semantic-indexing",
            log_path=log,
            evidence={"resource": resource},
            exit_code=exit_code,
            commit=COMMIT,
            build=BUILD,
        )

    def test_contract_is_exact_and_content_free(self):
        self.assertEqual(
            self.contract["orderedScenarioIDs"], leaks.EXPECTED_SCENARIOS
        )
        self.assertEqual(self.contract["policies"], leaks.EXPECTED_POLICIES)
        self.assertEqual(
            self.contract["liveAssistIterations"],
            leaks.LIVE_ASSIST_ITERATIONS,
        )
        self.assertEqual(self.contract["maximumLeaks"], 0)
        self.assertEqual(self.contract["maximumLeakedBytes"], 0)

    def test_observe_accepts_completed_zero_leak_indexing(self):
        fragment = self.observe_indexing()
        self.assertEqual(fragment["scenario"], "semantic-indexing")
        self.assertEqual(fragment["leakCount"], 0)
        self.assertRegex(fragment["evidenceSHA256"]["resource"], r"^[0-9a-f]{64}$")

    def test_observe_rejects_nonzero_exit(self):
        with self.assertRaisesRegex(
            leaks.ApuntadorLeakBaselineError, "reported leaks"
        ):
            self.observe_indexing(exit_code=1)

    def test_observe_rejects_fatal_tool_output_even_with_zero_exit(self):
        with self.assertRaisesRegex(
            leaks.ApuntadorLeakBaselineError, "fatal process/tool"
        ):
            self.observe_indexing(
                "bench-indexing: resource sample complete\n"
                "leaks[1]: [fatal] Couldn't get task port\n"
            )

    def test_observe_rejects_reported_leak(self):
        with self.assertRaisesRegex(
            leaks.ApuntadorLeakBaselineError, "nonzero leaked memory"
        ):
            self.observe_indexing(
                "bench-indexing: resource sample complete\n"
                "Process 1: 1 leak for 16384 total leaked bytes.\n"
            )

    def test_observe_rejects_missing_completion_marker(self):
        with self.assertRaisesRegex(
            leaks.ApuntadorLeakBaselineError, "completion marker"
        ):
            self.observe_indexing("process exited\n")

    def test_observe_rejects_symlinked_evidence(self):
        target = self.write_json("target.json", self.resource_sample())
        link = self.root / "indexing-1.json"
        link.symlink_to(target)
        log = self.write_log("bench-indexing: resource sample complete\n")
        with self.assertRaises((leaks.ApuntadorLeakBaselineError, ValueError)):
            leaks.observe_run(
                self.contract,
                scenario_id="semantic-indexing",
                log_path=log,
                evidence={"resource": link},
                exit_code=0,
                commit=COMMIT,
                build=BUILD,
            )

    def test_live_assist_evidence_must_match_contract_iterations(self):
        evidence = self.write_json("live-assist.json", {})
        observation = {
            "run": {
                "commit": COMMIT,
                "build": BUILD,
                "sourceState": "clean",
            },
            "adapter": {"class": "released-prefilter"},
            "resources": {"iterations": leaks.LIVE_ASSIST_ITERATIONS - 1},
        }
        with mock.patch.object(
            leaks.live_assist_validation,
            "validate_observations",
            return_value=observation,
        ), self.assertRaisesRegex(
            leaks.ApuntadorLeakBaselineError,
            "iteration count does not match",
        ):
            leaks.validate_live_assist_evidence(
                evidence,
                adapter="released-prefilter",
                commit=COMMIT,
                build=BUILD,
                expected_iterations=leaks.LIVE_ASSIST_ITERATIONS,
            )

    def test_assemble_and_validate_exact_four_scenario_receipt(self):
        fragments = [self.fragment(identifier) for identifier in leaks.EXPECTED_SCENARIOS]
        with mock.patch.object(
            leaks,
            "host_identity",
            return_value={
                "platform": "macOS",
                "version": "26.5.2",
                "build": "25F84",
                "architecture": "arm64",
            },
        ), mock.patch.object(
            leaks,
            "toolchain_identity",
            return_value={
                "xcode": "26.6",
                "build": "17F113",
                "leaksMode": "at-exit-no-content-no-stacks",
            },
        ):
            receipt = leaks.assemble_receipt(
                self.contract,
                version="1.0.0",
                build=BUILD,
                commit=COMMIT,
                fragments=fragments,
            )
        validated = leaks.validate_receipt(receipt, self.contract)
        self.assertEqual(validated["summary"]["scenarioCount"], 4)
        self.assertEqual(validated["summary"]["leakCount"], 0)
        self.assertEqual(
            [item["iterations"] for item in validated["scenarios"]],
            [
                leaks.LIVE_ASSIST_ITERATIONS,
                leaks.LIVE_ASSIST_ITERATIONS,
                leaks.SINGLE_WORKLOAD_ITERATIONS,
                leaks.SINGLE_WORKLOAD_ITERATIONS,
            ],
        )
        self.assertEqual(
            [item["id"] for item in validated["scenarios"]],
            list(leaks.EXPECTED_SCENARIOS),
        )

    def test_receipt_rejects_nonzero_leak_even_when_state_says_pass(self):
        fragments = [self.fragment(identifier) for identifier in leaks.EXPECTED_SCENARIOS]
        with mock.patch.object(
            leaks,
            "host_identity",
            return_value={
                "platform": "macOS",
                "version": "26.5.2",
                "build": "25F84",
                "architecture": "arm64",
            },
        ), mock.patch.object(
            leaks,
            "toolchain_identity",
            return_value={
                "xcode": "26.6",
                "build": "17F113",
                "leaksMode": "at-exit-no-content-no-stacks",
            },
        ):
            receipt = leaks.assemble_receipt(
                self.contract,
                version="1.0.0",
                build=BUILD,
                commit=COMMIT,
                fragments=fragments,
            )
        receipt["scenarios"][0]["leakCount"] = 1
        with self.assertRaisesRegex(
            leaks.ApuntadorLeakBaselineError, "leakCount must be 0"
        ):
            leaks.validate_receipt(receipt, self.contract)

    def test_receipt_rejects_forged_iteration_count(self):
        fragments = [self.fragment(identifier) for identifier in leaks.EXPECTED_SCENARIOS]
        with mock.patch.object(
            leaks,
            "host_identity",
            return_value={
                "platform": "macOS",
                "version": "26.5.2",
                "build": "25F84",
                "architecture": "arm64",
            },
        ), mock.patch.object(
            leaks,
            "toolchain_identity",
            return_value={
                "xcode": "26.6",
                "build": "17F113",
                "leaksMode": "at-exit-no-content-no-stacks",
            },
        ):
            receipt = leaks.assemble_receipt(
                self.contract,
                version="1.0.0",
                build=BUILD,
                commit=COMMIT,
                fragments=fragments,
            )
        receipt["scenarios"][0]["iterations"] -= 1
        with self.assertRaisesRegex(
            leaks.ApuntadorLeakBaselineError,
            "iterations must be 100",
        ):
            leaks.validate_receipt(receipt, self.contract)

    def test_atomic_writer_uses_owner_only_permissions(self):
        destination = self.root / "private" / "receipt.json"
        leaks.write_json(destination, {"ok": True})
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
        with self.assertRaisesRegex(
            leaks.ApuntadorLeakBaselineError, "already exists"
        ):
            leaks.write_json(destination, {"ok": True})

    def test_shell_runner_never_touches_installed_release_app(self):
        runner = (ROOT / "scripts" / "run-apuntador-leak-baseline.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("xcrun leaks -q --noContent --nostacks --atExit", runner)
        self.assertIn("Portavoz Leak Bench.app", runner)
        self.assertIn("portavoz-resource-bench.entitlements", runner)
        self.assertIn("git status --porcelain --untracked-files=all", runner)
        cleanup = runner.split("cleanup() {", 1)[1].split("}\n", 1)[0]
        self.assertIn("terminate_probe_processes", cleanup)
        self.assertEqual(runner.count("scripts/apuntador_leak_baseline.py observe"), 4)
        self.assertNotIn("/Applications/Portavoz.app", runner)
        self.assertNotIn("curl ", runner)
        self.assertNotIn("--fullContent", runner)


if __name__ == "__main__":
    unittest.main()
