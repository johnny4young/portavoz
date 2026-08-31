import contextlib
import copy
import io
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
    def resource_sample(iterations=10):
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
            "workloads": [
                {
                    "workloadClass": "maintenance",
                    "kind": "searchIndex",
                    "operation": "execute",
                    "outcome": "completed",
                    "count": iterations,
                    "durationMilliseconds": {
                        "p50": 1.0,
                        "p95": 2.0,
                        "maximum": 3.0,
                    },
                }
            ],
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
            "iterations": leaks.EXPECTED_ITERATIONS[identifier],
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
            {
                identifier: scenario["iterations"]
                for identifier, scenario in self.contract["scenarios"].items()
            },
            leaks.EXPECTED_ITERATIONS,
        )
        self.assertEqual(self.contract["maximumLeaks"], 0)
        self.assertEqual(self.contract["maximumLeakedBytes"], 0)

    def test_observe_accepts_completed_zero_leak_indexing(self):
        fragment = self.observe_indexing()
        self.assertEqual(fragment["scenario"], "semantic-indexing")
        self.assertEqual(fragment["leakCount"], 0)
        self.assertRegex(fragment["evidenceSHA256"]["resource"], r"^[0-9a-f]{64}$")

    def test_observe_rejects_forged_repeated_workload_count(self):
        with self.assertRaisesRegex(
            leaks.ApuntadorLeakBaselineError,
            "resource workload count must be 10",
        ):
            self.observe_indexing_with_iterations(9)

    def observe_indexing_with_iterations(self, iterations):
        resource = self.write_json(
            "indexing-forged-1.json",
            self.resource_sample(iterations=iterations),
        )
        log = self.write_log("bench-indexing: resource sample complete\n")
        return leaks.observe_run(
            self.contract,
            scenario_id="semantic-indexing",
            log_path=log,
            evidence={"resource": resource},
            exit_code=0,
            commit=COMMIT,
            build=BUILD,
        )

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
            "resources": {
                "iterations": leaks.EXPECTED_ITERATIONS["live-assist-released"] - 1
            },
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
                expected_iterations=leaks.EXPECTED_ITERATIONS[
                    "live-assist-released"
                ],
            )

    def test_live_assist_validator_failure_is_a_closed_domain_error(self):
        evidence = self.write_json("live-assist-invalid.json", {})
        with mock.patch.object(
            leaks.live_assist_validation,
            "validate_observations",
            side_effect=leaks.live_assist_validation.LiveAssistValidationError(
                "malformed imported evidence"
            ),
        ), self.assertRaisesRegex(
            leaks.ApuntadorLeakBaselineError,
            "live-assist evidence is invalid",
        ):
            leaks.validate_live_assist_evidence(
                evidence,
                adapter="released-prefilter",
                commit=COMMIT,
                build=BUILD,
                expected_iterations=leaks.EXPECTED_ITERATIONS[
                    "live-assist-released"
                ],
            )

    def test_cli_reports_malformed_live_assist_evidence_without_traceback(self):
        evidence = self.write_json("malformed-live-assist.json", {})
        log = self.write_log(
            "live-assist-validation: observations written\n"
        )
        output = self.root / "fragment.json"
        stderr = io.StringIO()

        with contextlib.redirect_stderr(stderr):
            result = leaks.main([
                "observe",
                "--scenario", "live-assist-released",
                "--log", str(log),
                "--evidence", f"observations={evidence}",
                "--exit-code", "0",
                "--commit", COMMIT,
                "--build", BUILD,
                "--output", str(output),
            ])

        self.assertEqual(result, 1)
        self.assertEqual(
            stderr.getvalue(),
            "apuntador leak baseline error: live-assist evidence is invalid\n",
        )
        self.assertNotIn("Traceback", stderr.getvalue())
        self.assertFalse(output.exists())

    def test_evidence_digest_failure_is_a_closed_domain_error(self):
        with self.assertRaisesRegex(
            leaks.ApuntadorLeakBaselineError,
            "leak evidence could not be hashed",
        ):
            leaks.file_sha256(self.root / "missing-evidence.json")

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
                100,
                100,
                10,
                10,
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
        self.assertRegex(runner, r"(?m)^ASK_ITERATIONS=10$")
        self.assertRegex(runner, r"(?m)^INDEXING_ITERATIONS=10$")
        self.assertIn('--bench-resource-iterations "$ASK_ITERATIONS"', runner)
        self.assertIn('--bench-resource-iterations "$INDEXING_ITERATIONS"', runner)
        self.assertIn("git status --porcelain --untracked-files=all", runner)
        cleanup = runner.split("cleanup() {", 1)[1].split("}\n", 1)[0]
        self.assertIn("terminate_probe_processes", cleanup)
        self.assertEqual(runner.count("scripts/apuntador_leak_baseline.py observe"), 4)
        self.assertNotIn("/Applications/Portavoz.app", runner)
        self.assertNotIn("curl ", runner)
        self.assertNotIn("--fullContent", runner)


if __name__ == "__main__":
    unittest.main()
