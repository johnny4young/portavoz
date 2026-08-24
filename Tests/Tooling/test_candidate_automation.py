import copy
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import candidate_automation as candidate  # noqa: E402


class CandidateAutomationTests(unittest.TestCase):
    version = "1.0.0"
    build = "1000"
    commit = "a" * 40

    def setUp(self):
        self.contract_document = json.loads(candidate.DEFAULT_CONTRACT.read_text())
        self.contract = candidate.load_contract()

    def test_tracked_contract_is_exact_and_complete(self):
        self.assertEqual(
            self.contract["proofs"],
            (
                "finite-scope",
                "autonomous-validation",
                "model-gated",
                "performance-ledger",
                "resource-baseline",
                "long-capture",
                "upgrade-recovery",
                "complete-bilingual-ui",
            ),
        )
        self.assertEqual(self.contract["modelClasses"], candidate.EXPECTED_MODEL_CLASSES)
        self.assertEqual(
            self.contract["modelFixture"]["textPath"],
            ROOT / "Fixtures" / "CandidateAutomation" / "public-model-lane-en-v1.txt",
        )
        self.assertEqual(
            self.contract["modelFixture"]["conversationTextPath"],
            ROOT / "Fixtures" / "CandidateAutomation" / "public-diarization-en-es-v1.txt",
        )
        self.assertEqual(
            self.contract["upgradeRecoveryClasses"],
            candidate.EXPECTED_UPGRADE_RECOVERY_CLASSES,
        )
        self.assertEqual(
            self.contract["resource"]["requiredScenarios"],
            candidate.EXPECTED_RESOURCE_SCENARIOS,
        )
        self.assertEqual(self.contract["resource"]["samplesPerScenario"], 3)
        measured = set(
            self.contract["performance"]["requiredMeasuredMetricIDs"]
        )
        unmeasured = set(
            self.contract["performance"]["allowedNotMeasuredMetricIDs"]
        )
        thresholds = json.loads(
            self.contract["performance"]["thresholdContract"].read_text()
        )
        self.assertEqual(measured | unmeasured, {
            metric["id"] for metric in thresholds["metrics"]
        })
        self.assertFalse(measured & unmeasured)

    def test_contract_rejects_proof_order_drift_and_extra_content(self):
        drifted = copy.deepcopy(self.contract_document)
        drifted["proofs"].reverse()
        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "release-admission scope exactly",
        ):
            candidate.validate_contract(drifted)

        content_bearing = copy.deepcopy(self.contract_document)
        content_bearing["meetingNotes"] = "private"
        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "forbidden keys: meetingNotes",
        ):
            candidate.validate_contract(content_bearing)

    def test_contract_rejects_incomplete_performance_partition(self):
        drifted = copy.deepcopy(self.contract_document)
        drifted["performance"]["requiredMeasuredMetricIDs"].pop()

        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "partition every threshold metric",
        ):
            candidate.validate_contract(drifted)

    def test_contract_rejects_weaker_resource_or_ui_scope(self):
        weak_resource = copy.deepcopy(self.contract_document)
        weak_resource["resource"]["samplesPerScenario"] = 2
        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "accepted minimum",
        ):
            candidate.validate_contract(weak_resource)

        weak_ui = copy.deepcopy(self.contract_document)
        weak_ui["ui"]["locales"] = ["en"]
        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "exactly en and es",
        ):
            candidate.validate_contract(weak_ui)

    def test_duplicate_json_keys_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"schemaVersion": 1, "schemaVersion": 1}')

            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "repeats key: schemaVersion",
            ):
                candidate.load_json(path, "candidate fixture")

    def test_authoritative_performance_ledger_accepts_only_exact_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ledger.json"
            path.write_text(json.dumps(self.performance_ledger()))

            candidate.validate_performance_ledger(path, self.contract)

    def test_performance_ledger_rejects_non_authority_and_blocking_metric(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ledger = self.performance_ledger()
            ledger["authority"] = "informational"
            ledger["authorityReason"] = "mixed hosts"
            path = root / "informational.json"
            path.write_text(json.dumps(ledger))
            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "not authoritative|forbidden keys",
            ):
                candidate.validate_performance_ledger(path, self.contract)

            ledger = self.performance_ledger()
            required = self.contract["performance"]["requiredMeasuredMetricIDs"][0]
            metric = next(item for item in ledger["metrics"] if item["id"] == required)
            metric["status"] = "regression-candidate"
            metric.pop("measured")
            ledger["summary"]["regressionCandidates"] = 1
            path = root / "regression.json"
            path.write_text(json.dumps(ledger))
            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "blocking state regression-candidate",
            ):
                candidate.validate_performance_ledger(path, self.contract)

    def test_performance_ledger_rejects_silent_or_inconsistent_omissions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ledger = self.performance_ledger()
            required = self.contract["performance"]["requiredMeasuredMetricIDs"][0]
            metric = next(item for item in ledger["metrics"] if item["id"] == required)
            metric["status"] = "not-measured"
            metric.pop("measured")
            ledger["summary"]["notMeasured"] += 1
            path = root / "missing-required.json"
            path.write_text(json.dumps(ledger))
            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "blocking state not-measured",
            ):
                candidate.validate_performance_ledger(path, self.contract)

            ledger = self.performance_ledger()
            ledger["summary"]["notMeasured"] = 0
            path = root / "bad-summary.json"
            path.write_text(json.dumps(ledger))
            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "notMeasured is inconsistent",
            ):
                candidate.validate_performance_ledger(path, self.contract)

    def test_resource_receipt_requires_exact_release_profile_samples_and_ask(self):
        validated = self.validated_resource_receipt()
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "receipt.json"
            receipt.write_text("{}")
            with mock.patch.object(
                candidate.resource_baseline,
                "validate_receipt",
                return_value=validated,
            ):
                candidate.validate_resource_receipt(
                    receipt,
                    self.contract,
                    version=self.version,
                    build=self.build,
                    commit=self.commit,
                    profile="reference",
                )

                incomplete = copy.deepcopy(validated)
                incomplete["scenarios"]["idle"]["runs"].pop(3)
                with mock.patch.object(
                    candidate.resource_baseline,
                    "validate_receipt",
                    return_value=incomplete,
                ), self.assertRaisesRegex(
                    candidate.CandidateAutomationError,
                    "idle must have exact runs 1...3",
                ):
                    candidate.validate_resource_receipt(
                        receipt,
                        self.contract,
                        version=self.version,
                        build=self.build,
                        commit=self.commit,
                        profile="reference",
                    )

                unstable = copy.deepcopy(validated)
                unstable["scenarios"]["idle"]["runs"][3]["metrics"][
                    "wallDurationMilliseconds"
                ] = 10_000.0
                with mock.patch.object(
                    candidate.resource_baseline,
                    "validate_receipt",
                    return_value=unstable,
                ), self.assertRaisesRegex(
                    candidate.CandidateAutomationError,
                    "idle has blocking state unstable",
                ):
                    candidate.validate_resource_receipt(
                        receipt,
                        self.contract,
                        version=self.version,
                        build=self.build,
                        commit=self.commit,
                        profile="reference",
                    )

                nondeterministic = copy.deepcopy(validated)
                nondeterministic["askPipeline"]["runs"][3]["citations"][
                    "digest"
                ] = "e" * 64
                with mock.patch.object(
                    candidate.resource_baseline,
                    "validate_receipt",
                    return_value=nondeterministic,
                ), self.assertRaisesRegex(
                    candidate.CandidateAutomationError,
                    "citations are nondeterministic",
                ):
                    candidate.validate_resource_receipt(
                        receipt,
                        self.contract,
                        version=self.version,
                        build=self.build,
                        commit=self.commit,
                        profile="reference",
                    )

                failed_ask = copy.deepcopy(validated)
                failed_ask["askPipeline"]["state"] = "fail"
                with mock.patch.object(
                    candidate.resource_baseline,
                    "validate_receipt",
                    return_value=failed_ask,
                ), self.assertRaisesRegex(
                    candidate.CandidateAutomationError,
                    "Ask pipeline has blocking state fail",
                ):
                    candidate.validate_resource_receipt(
                        receipt,
                        self.contract,
                        version=self.version,
                        build=self.build,
                        commit=self.commit,
                        profile="reference",
                    )

    def test_long_capture_requires_exact_commit_and_canonical_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "long.json"
            path.write_text(json.dumps(self.long_capture_report()))
            candidate.validate_long_capture(path, self.commit)

            report = self.long_capture_report()
            report["sourceCommit"] = "b" * 40
            path.write_text(json.dumps(report))
            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "not bound to the requested source commit",
            ):
                candidate.validate_long_capture(path, self.commit)

    def test_complete_bilingual_ui_requires_exact_catalog_and_shared_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_ui_receipts(root)
            candidate.validate_ui_receipts(root, self.contract)

            spanish = json.loads((root / "es-runtime.json").read_text())
            spanish["tests"].pop()
            spanish["caseCount"] -= 1
            (root / "es-runtime.json").write_text(json.dumps(spanish))
            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "cases; expected",
            ):
                candidate.validate_ui_receipts(root, self.contract)

    def test_complete_bilingual_ui_rejects_budget_failure_and_two_builds(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_ui_receipts(root)
            spanish_path = root / "es-runtime.json"
            spanish = json.loads(spanish_path.read_text())
            spanish["budgetStatus"] = "failed"
            spanish["budgetViolations"] = ["slow"]
            spanish_path.write_text(json.dumps(spanish))
            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "failed its budget",
            ):
                candidate.validate_ui_receipts(root, self.contract)

            self.write_ui_receipts(root)
            spanish = json.loads(spanish_path.read_text())
            spanish["buildDurationSeconds"] = 13.0
            spanish_path.write_text(json.dumps(spanish))
            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "do not share one build duration",
            ):
                candidate.validate_ui_receipts(root, self.contract)

    def test_test_summary_rejects_zero_or_missing_discovery(self):
        self.assertEqual(
            candidate.test_summary(
                "Executed 4 tests, with 1 test skipped and 0 failures in 1.0 seconds"
            ),
            (4, 1),
        )
        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "no XCTest summary",
        ):
            candidate.test_summary("Build complete")

    def test_public_model_fixture_requires_real_bounded_audio_frames(self):
        metadata = """<?xml version="1.0"?>
        <audio_info><audio_file><tracks><track>
        <num_channels>1</num_channels><sample_rate>22050</sample_rate>
        <audio_bytes>220500</audio_bytes><duration>5.0</duration>
        </track></tracks></audio_file></audio_info>"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.aiff"
            path.write_bytes(b"0" * 8_192)
            completed = mock.Mock(stdout=metadata)
            with mock.patch.object(
                candidate.subprocess,
                "run",
                return_value=completed,
            ):
                candidate.validate_public_model_fixture(path)

            empty = metadata.replace("220500", "0").replace("5.0", "0.0")
            with mock.patch.object(
                candidate.subprocess,
                "run",
                return_value=mock.Mock(stdout=empty),
            ), self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "empty or unbounded PCM metadata",
            ):
                candidate.validate_public_model_fixture(path)

    def test_profile_detection_is_exact_and_rejects_contract_gaps(self):
        self.assertEqual(
            candidate.detect_profile(self.contract, 8 * 1024**3),
            "memory-8gb",
        )
        self.assertEqual(
            candidate.detect_profile(self.contract, 16 * 1024**3),
            "memory-16gb",
        )
        self.assertEqual(
            candidate.detect_profile(self.contract, 36 * 1024**3),
            "reference",
        )
        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "does not map to exactly one",
        ):
            candidate.detect_profile(self.contract, 24 * 1024**3)

    def test_receipt_has_no_arbitrary_state_input_and_is_owner_only(self):
        receipt = candidate.candidate_receipt(
            version=self.version,
            build=self.build,
            commit=self.commit,
            proofs=self.contract["proofs"],
        )
        self.assertEqual(receipt["scope"], "candidate-automation")
        self.assertTrue(all(proof["state"] == "pass" for proof in receipt["proofs"]))
        self.assertNotIn("notes", json.dumps(receipt).lower())
        source = (ROOT / "scripts" / "candidate_automation.py").read_text()
        self.assertNotIn("--proof", source)
        self.assertNotIn("record-qualification", source)

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "qualification.json"
            candidate.release_reliability.write_json(path, receipt)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_run_never_emits_qualification_after_a_gate_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "candidate"
            with mock.patch.object(
                candidate,
                "exact_checkout",
                return_value=self.commit,
            ), mock.patch.object(
                candidate,
                "physical_memory_bytes",
                return_value=36 * 1024**3,
            ), mock.patch.object(
                candidate,
                "run_command",
                side_effect=candidate.CandidateAutomationError("gate failed"),
            ), self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "gate failed",
            ):
                candidate.run_candidate(
                    version=self.version,
                    build=self.build,
                    output_path=output,
                )

            self.assertFalse((output / "qualification.json").exists())

    def test_run_emits_receipt_only_after_every_specialized_validator(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "candidate"
            with mock.patch.object(
                candidate,
                "exact_checkout",
                return_value=self.commit,
            ), mock.patch.object(
                candidate,
                "physical_memory_bytes",
                return_value=36 * 1024**3,
            ), mock.patch.object(
                candidate,
                "run_command",
            ) as commands, mock.patch.object(
                candidate,
                "run_swift_test_classes",
            ) as swift_classes, mock.patch.object(
                candidate,
                "validate_public_model_fixture",
            ) as model_fixture, mock.patch.object(
                candidate,
                "validate_deterministic_receipt",
            ) as deterministic, mock.patch.object(
                candidate,
                "validate_performance_ledger",
            ) as performance, mock.patch.object(
                candidate,
                "validate_resource_receipt",
            ) as resource, mock.patch.object(
                candidate,
                "validate_long_capture",
            ) as long_capture, mock.patch.object(
                candidate,
                "validate_ui_receipts",
            ) as ui:
                with contextlib.redirect_stdout(io.StringIO()):
                    receipt_path = candidate.run_candidate(
                        version=self.version,
                        build=self.build,
                        output_path=output,
                    )

            receipt = json.loads(receipt_path.read_text())
            self.assertEqual(receipt["release"]["commit"], self.commit)
            self.assertEqual(len(receipt["proofs"]), 8)
            self.assertEqual(commands.call_count, 8)
            self.assertEqual(swift_classes.call_count, 2)
            self.assertEqual(model_fixture.call_count, 2)
            command_by_label = {
                call.args[2]: call for call in commands.call_args_list
            }
            deterministic_environment = command_by_label[
                "Finite deterministic release scope"
            ].kwargs["environment"]
            self.assertIsNone(deterministic_environment["PORTAVOZ_TEST_WAV"])
            performance_environment = command_by_label[
                "Strict authoritative performance ledger"
            ].kwargs["environment"]
            self.assertIsNone(
                performance_environment["PORTAVOZ_PERF_WAVEFORM_MIC"]
            )
            resource_call = next(
                call for call in commands.call_args_list
                if call.args[2].startswith("Release resource baseline")
            )
            self.assertEqual(
                resource_call.kwargs["environment"]["PORTAVOZ_SIGN_IDENTITY"],
                "-",
            )
            model_environment = swift_classes.call_args_list[0].kwargs[
                "environment"
            ]
            self.assertEqual(model_environment["PORTAVOZ_MODEL_TESTS"], "1")
            self.assertIn("public-model-lane.aiff", model_environment["PORTAVOZ_TEST_WAV"])
            self.assertIn(
                "public-diarization-lane.aiff",
                model_environment["PORTAVOZ_TEST_CONVERSATION_WAV"],
            )
            deterministic.assert_called_once()
            performance.assert_called_once()
            resource.assert_called_once()
            long_capture.assert_called_once()
            ui.assert_called_once()
            self.assertEqual(os.stat(receipt_path).st_mode & 0o777, 0o600)

    def test_model_failure_removes_both_public_scratch_audio_files(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "candidate"

            def command_side_effect(_, __, label, command, **___):
                if label.startswith("Public synthetic spoken") or label.startswith(
                    "Public bilingual two-voice"
                ):
                    target = Path(command[command.index("-o") + 1])
                    target.write_bytes(b"public synthetic audio")

            with mock.patch.object(
                candidate,
                "exact_checkout",
                return_value=self.commit,
            ), mock.patch.object(
                candidate,
                "physical_memory_bytes",
                return_value=36 * 1024**3,
            ), mock.patch.object(
                candidate,
                "run_command",
                side_effect=command_side_effect,
            ), mock.patch.object(
                candidate,
                "validate_public_model_fixture",
            ), mock.patch.object(
                candidate,
                "validate_deterministic_receipt",
            ), mock.patch.object(
                candidate,
                "run_swift_test_classes",
                side_effect=candidate.CandidateAutomationError("model failed"),
            ), self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "model failed",
            ), contextlib.redirect_stdout(io.StringIO()):
                candidate.run_candidate(
                    version=self.version,
                    build=self.build,
                    output_path=output,
                )

            self.assertFalse((output / "public-model-lane.aiff").exists())
            self.assertFalse((output / "public-diarization-lane.aiff").exists())
            self.assertFalse((output / "qualification.json").exists())

    def test_invalid_release_identity_fails_before_creating_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "candidate"
            with mock.patch.object(
                candidate,
                "exact_checkout",
                return_value=self.commit,
            ), self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "release.version has an unsafe value",
            ):
                candidate.run_candidate(
                    version="private version with spaces",
                    build=self.build,
                    output_path=output,
                )

            self.assertFalse(output.exists())

    def test_run_restores_process_umask_after_failure(self):
        original = os.umask(0o027)
        os.umask(original)
        try:
            with mock.patch.object(
                candidate,
                "_run_candidate",
                side_effect=candidate.CandidateAutomationError("gate failed"),
            ), self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "gate failed",
            ):
                candidate.run_candidate(version=self.version, build=self.build)

            observed = os.umask(0o077)
            os.umask(observed)
            self.assertEqual(observed, original)
        finally:
            os.umask(original)

    def performance_ledger(self):
        required = self.contract["performance"]["requiredMeasuredMetricIDs"]
        allowed = self.contract["performance"]["allowedNotMeasuredMetricIDs"]
        metrics = [
            {"id": identifier, "status": "pass", "measured": 1.0}
            for identifier in required
        ] + [
            {"id": identifier, "status": "not-measured"}
            for identifier in allowed
        ]
        return {
            "schemaVersion": 1,
            "authority": "authoritative",
            "generatedAt": "2026-08-24T18:00:00Z",
            "host": {"architecture": "arm64"},
            "toolchain": {"swift": "6.2"},
            "metrics": metrics,
            "summary": {
                "failures": 0,
                "regressionCandidates": 0,
                "notMeasured": len(allowed),
                "unresolved": 0,
                "unstable": 0,
                "dispersed": 0,
            },
        }

    def validated_resource_receipt(self):
        runs = {
            run: {
                "metrics": {
                    "wallDurationMilliseconds": 1000.0 + run,
                    "cpuTimeMilliseconds": 500.0 + run,
                    "peakPhysicalFootprintBytes": 512 * 1024**2 + run,
                    "energyNanojoules": 1_000_000 + run,
                    "diskReadBytes": 2_000 + run,
                    "diskWrittenBytes": 3_000 + run,
                    "minimumAvailableDiskBytes": 40 * 1024**3 - run,
                    "maximumThermalState": "nominal",
                    "powerSource": "ac",
                    "lowPowerModeEnabled": False,
                },
                "workloads": {},
            }
            for run in range(1, 4)
        }
        ask_runs = {
            run: {
                "total": {
                    "wallDurationMilliseconds": 1000.0 + run,
                    "cpuTimeMilliseconds": 500.0 + run,
                },
                "firstEvidence": {
                    "wallDurationMilliseconds": 600.0 + run,
                    "cpuTimeMilliseconds": 300.0 + run,
                },
                "firstToken": {
                    "wallDurationMilliseconds": 900.0 + run,
                    "cpuTimeMilliseconds": 450.0 + run,
                },
                "stages": {
                    stage: {
                        "wallDurationMilliseconds": 100.0 + run,
                        "cpuTimeMilliseconds": 50.0 + run,
                    }
                    for stage in candidate.resource_baseline.ASK_PIPELINE_STAGES
                },
                "corpus": {
                    "generation": "ask-resource-v2",
                    "checksum": "c" * 64,
                    "fixtureSegmentCount": 10,
                    "warmup": "preindexed",
                },
                "citations": {"count": 3, "digest": "d" * 64},
            }
            for run in range(1, 4)
        }
        return {
            "build": {
                "version": self.version,
                "build": self.build,
                "commit": self.commit,
                "configuration": "release",
            },
            "host": {"profile": "reference"},
            "toolchain": {},
            "scenarios": {
                identifier: {"state": "pass", "runs": copy.deepcopy(runs)}
                for identifier in candidate.EXPECTED_RESOURCE_SCENARIOS
            },
            "askPipeline": {"state": "pass", "runs": ask_runs},
        }

    def long_capture_report(self):
        expected_frames = 10_800 * 16_000
        channel = {
            "id": "microphone",
            "expectedFrames": expected_frames,
            "acceptedFrames": expected_frames,
            "publishedFrames": expected_frames,
            "durationSeconds": 10_800,
            "byteCount": expected_frames * 2 + 4_096,
            "healthStatus": "healthy",
        }
        system = copy.deepcopy(channel)
        system["id"] = "system"
        return {
            "schemaVersion": 1,
            "generatedAt": "2026-08-24T18:00:00Z",
            "buildConfiguration": "release",
            "sourceCommit": self.commit,
            "contentSource": "synthetic-only",
            "host": {
                "operatingSystem": "macOS 26.0",
                "architecture": "arm64",
                "physicalMemoryBytes": 36 * 1024**3,
            },
            "configuration": {
                "requestedDurationSeconds": 10_800,
                "sampleRate": 16_000,
                "chunkFrames": 4_800,
                "expectedFramesPerChannel": expected_frames,
                "logicalChunksPerChannel": 36_000,
                "canonicalThreeHourRun": True,
            },
            "channels": [channel, system],
            "result": {
                "passed": True,
                "driftFrames": 0,
                "captureWallDurationMilliseconds": 20_000.0,
                "stopWallDurationMilliseconds": 3_000.0,
                "baselineHeapBytesInUse": 100_000_000,
                "peakHeapBytesInUse": 110_000_000,
                "incrementalPeakHeapBytesInUse": 10_000_000,
                "maximumIncrementalHeapBytesInUse": 16 * 1024**2,
                "endingHeapBytesInUse": 105_000_000,
            },
        }

    def write_ui_receipts(self, root):
        budget = json.loads(self.contract["ui"]["budgetPath"].read_text())
        identifiers = sorted(budget["testBudgetsSeconds"])
        for locale in candidate.EXPECTED_UI_LOCALES:
            tests = [
                {
                    "identifier": identifier,
                    "durationSeconds": 1.0,
                    "result": "Passed",
                }
                for identifier in identifiers
            ]
            receipt = {
                "schemaVersion": 1,
                "locale": locale,
                "selectorCount": 0,
                "caseCount": len(tests),
                "buildDurationSeconds": 12.0,
                "testWallDurationSeconds": 120.0,
                "testDurationSeconds": float(len(tests)),
                "p50Seconds": 1.0,
                "p95Seconds": 1.0,
                "maximumSeconds": 1.0,
                "budgetStatus": "passed",
                "budgetViolations": [],
                "tests": tests,
            }
            (root / f"{locale}-runtime.json").write_text(json.dumps(receipt))


if __name__ == "__main__":
    unittest.main()
