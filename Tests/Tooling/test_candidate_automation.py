import copy
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import candidate_automation as candidate  # noqa: E402


class CandidateAutomationTests(unittest.TestCase):
    version = "1.0.0"
    build = "1000"
    commit = "a" * 40
    performance_binary_sha256 = "b" * 64

    def setUp(self):
        self.contract_document = json.loads(candidate.DEFAULT_CONTRACT.read_text())
        self.contract = candidate.load_contract()

    def performance_gate_kwargs(self):
        return {
            "binary_path": ROOT / ".build" / "release" / "portavoz-cli",
            "binary_sha256": self.performance_binary_sha256,
            "build_wall_milliseconds": 1_000.0,
        }

    def performance_build(self):
        return {
            "path": ROOT / ".build" / "release" / "portavoz-cli",
            "sha256": self.performance_binary_sha256,
            "wallMilliseconds": 1_000.0,
        }

    def test_tracked_contract_is_exact_and_complete(self):
        self.assertEqual(self.contract_document["schemaVersion"], 6)
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
            self.contract["modelFixture"]["conversationVoices"],
            candidate.EXPECTED_CONVERSATION_VOICES,
        )
        readiness = self.contract_document["performance"]["hostReadiness"]
        self.assertEqual(
            readiness["version"], "prebuilt-release-host-readiness-v2"
        )
        self.assertEqual(
            readiness["throughputCalibration"],
            {
                "bytesPerSample": 536_870_912,
                "maximumCPUMilliseconds": 200.0,
                "maximumDispersionRatio": 1.15,
                "maximumWallMilliseconds": 200.0,
                "sampleCount": 5,
                "version": "sha256-zero-block-512mib-v1",
            },
        )

        performance_runner = (
            ROOT / "scripts" / "run-perf-ledger.sh"
        ).read_text()
        scale_readiness = performance_runner.index(
            'run_host_readiness "Scale"'
        )
        scale_harness = performance_runner.index(
            'run_stage "Library and detail scale matrix"'
        )
        semantic_readiness = performance_runner.index(
            '"Semantic" "$OUTPUT_DIR/host-readiness-semantic.json"'
        )
        semantic_harness = performance_runner.index(
            'run_stage "Semantic retrieval matrix"'
        )
        spotlight_readiness = performance_runner.index(
            '"Spotlight" "$OUTPUT_DIR/host-readiness-spotlight.json"'
        )
        spotlight_harness = performance_runner.index(
            'run_stage "Spotlight projection matrix"'
        )
        self.assertLess(scale_readiness, scale_harness)
        self.assertLess(scale_harness, semantic_readiness)
        self.assertLess(semantic_readiness, semantic_harness)
        self.assertLess(semantic_harness, spotlight_readiness)
        self.assertLess(spotlight_readiness, spotlight_harness)
        self.assertEqual(
            tuple(
                voice
                for voice, _ in self.contract["modelFixture"]["conversationTurns"]
            ),
            candidate.EXPECTED_CONVERSATION_SEQUENCE,
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
        self.assertEqual(
            self.contract["memoryLeaks"]["contractPath"],
            ROOT / "docs" / "evidence" / "apuntador-leak-baseline.json",
        )
        self.assertEqual(
            self.contract["memoryLeaks"]["scenarioIterations"],
            candidate.apuntador_leak_baseline.EXPECTED_ITERATIONS,
        )
        self.assertEqual(
            self.contract["memoryLeaks"]["requiredScenarios"],
            candidate.EXPECTED_LEAK_SCENARIOS,
        )
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
        self.assertEqual(self.contract["performance"]["confirmationRuns"], 3)
        self.assertEqual(
            self.contract["performance"]["binaryPolicy"],
            "single-exact-release-build-sha256-v1",
        )
        self.assertEqual(
            self.contract["performance"]["hostReadiness"]["version"],
            candidate.perf_host_readiness.POLICY_VERSION,
        )
        self.assertEqual(
            self.contract["performance"]["hostReadiness"][
                "requiredConsecutiveSamples"
            ],
            3,
        )
        self.assertEqual(thresholds["regression"]["confirmationRuns"], 3)

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

        weakened = copy.deepcopy(self.contract_document)
        weakened["performance"]["confirmationRuns"] = 2
        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "three-run PERF-008 contract",
        ):
            candidate.validate_contract(weakened)

        rebuilt = copy.deepcopy(self.contract_document)
        rebuilt["performance"]["binaryPolicy"] = "build-before-each-harness"
        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "one exact Release build",
        ):
            candidate.validate_contract(rebuilt)

        unbounded = copy.deepcopy(self.contract_document)
        unbounded["performance"]["hostReadiness"]["maximumWaitSeconds"] = 901
        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "maximumWaitSeconds is outside its bounds",
        ):
            candidate.validate_contract(unbounded)

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

        weak_leaks = copy.deepcopy(self.contract_document)
        weak_leaks["memoryLeaks"]["requiredScenarios"].pop()
        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "leak scenarios drifted",
        ):
            candidate.validate_contract(weak_leaks)

        weak_leak_iterations = copy.deepcopy(self.contract_document)
        weak_leak_iterations["memoryLeaks"]["scenarioIterations"]["ask"] = 9
        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "leak iterations must match",
        ):
            candidate.validate_contract(weak_leak_iterations)

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

    def test_candidate_performance_gate_stops_after_a_clean_first_run(self):
        with tempfile.TemporaryDirectory() as directory:
            performance = Path(directory) / "performance"
            side_effect = self.performance_run_side_effect({1: ()})
            with mock.patch.object(
                candidate,
                "run_command",
                side_effect=side_effect,
            ) as command:
                candidate.run_candidate_performance_gate(
                    ROOT,
                    self.commit,
                    performance,
                    self.contract,
                    **self.performance_gate_kwargs(),
                    environment={},
                )

            self.assertEqual(command.call_count, 1)
            confirmation = json.loads(
                (performance / "confirmation.json").read_text()
            )
            self.assertEqual(confirmation["outcome"], "clean-first-run")
            self.assertEqual(confirmation["observedRuns"], 1)
            self.assertEqual(confirmation["selectedRun"], 1)
            self.assertTrue((performance / "ledger.json").is_file())
            for name in (
                "host-readiness.json",
                "host-readiness-semantic.json",
                "host-readiness-spotlight.json",
            ):
                self.assertTrue((performance / name).is_file())
            self.assertFalse(
                (Path(directory) / "performance-confirmation" / "run-2").exists()
            )
            environment = command.call_args.kwargs["environment"]
            self.assertEqual(environment["PORTAVOZ_PERF_STRICT"], "0")
            self.assertEqual(
                environment["PORTAVOZ_PERF_BINARY_SHA256"],
                self.performance_binary_sha256,
            )
            self.assertEqual(
                environment["PORTAVOZ_PERF_SOURCE_COMMIT"], self.commit
            )
            self.assertEqual(
                environment[
                    "PORTAVOZ_PERF_HOST_MAXIMUM_CALIBRATION_WALL_MILLISECONDS"
                ],
                "200.0",
            )
            self.assertEqual(
                environment[
                    "PORTAVOZ_PERF_HOST_MAXIMUM_CALIBRATION_DISPERSION_RATIO"
                ],
                "1.15",
            )
            self.assertEqual(command.call_args.kwargs["accepted_exit_codes"], (0, 2))

    def test_run_command_accepts_declared_exit_and_rechecks_source(self):
        completed = mock.Mock(returncode=2)
        with mock.patch.object(
            candidate,
            "exact_checkout",
            return_value=self.commit,
        ) as checkout, mock.patch.object(
            candidate,
            "developer_environment",
            return_value={},
        ), mock.patch.object(
            candidate.subprocess,
            "run",
            return_value=completed,
        ):
            exit_code = candidate.run_command(
                ROOT,
                self.commit,
                "candidate exit",
                ["false"],
                accepted_exit_codes=(0, 2),
            )

        self.assertEqual(exit_code, 2)
        self.assertEqual(checkout.call_count, 2)
        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "invalid accepted exit codes",
        ):
            candidate.run_command(
                ROOT,
                self.commit,
                "invalid exit policy",
                ["false"],
                accepted_exit_codes=(False,),
            )

    def test_candidate_builds_one_exact_release_binary_before_measurement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / ".build" / "release" / "portavoz-cli"

            def build_side_effect(*args, **kwargs):
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"exact release binary")
                binary.chmod(0o700)
                return 0

            with mock.patch.object(
                candidate,
                "run_command",
                side_effect=build_side_effect,
            ) as command, mock.patch.object(
                candidate.time,
                "monotonic_ns",
                side_effect=(1_000_000_000, 2_500_000_000),
            ):
                result = candidate.build_candidate_performance_binary(
                    root,
                    self.commit,
                    environment={},
                )

            command.assert_called_once_with(
                root,
                self.commit,
                "Exact performance Release build",
                ["swift", "build", "-c", "release", "--product", "portavoz-cli"],
                environment={},
            )
            self.assertEqual(result["path"], binary)
            self.assertEqual(result["wallMilliseconds"], 1_500.0)
            self.assertEqual(result["sha256"], candidate.hashlib.sha256(
                b"exact release binary"
            ).hexdigest())

    def test_candidate_performance_gate_retains_fixed_set_and_selects_last_clean(self):
        metric = self.contract["performance"]["requiredMeasuredMetricIDs"][0]
        with tempfile.TemporaryDirectory() as directory:
            performance = Path(directory) / "performance"
            side_effect = self.performance_run_side_effect({
                1: (metric,),
                2: (),
                3: (),
            })
            with mock.patch.object(
                candidate,
                "run_command",
                side_effect=side_effect,
            ) as command:
                candidate.run_candidate_performance_gate(
                    ROOT,
                    self.commit,
                    performance,
                    self.contract,
                    **self.performance_gate_kwargs(),
                    environment={},
                )

            self.assertEqual(command.call_count, 3)
            confirmation = json.loads(
                (performance / "confirmation.json").read_text()
            )
            self.assertEqual(confirmation["outcome"], "unconfirmed-regression")
            self.assertEqual(confirmation["observedRuns"], 3)
            self.assertEqual(confirmation["selectedRun"], 3)
            self.assertEqual(confirmation["initialCandidateMetricIDs"], [metric])
            self.assertEqual(confirmation["confirmedRegressionMetricIDs"], [])
            canonical = json.loads((performance / "ledger.json").read_text())
            measured = next(
                item["measured"] for item in canonical["metrics"]
                if item["id"] == metric
            )
            self.assertEqual(measured, 3.0)
            runs_root = Path(directory) / "performance-confirmation"
            self.assertTrue(all(
                (runs_root / f"run-{run}" / "ledger.json").is_file()
                for run in range(1, 4)
            ))

    def test_candidate_performance_gate_blocks_confirmed_regression(self):
        metric = self.contract["performance"]["requiredMeasuredMetricIDs"][0]
        with tempfile.TemporaryDirectory() as directory:
            performance = Path(directory) / "performance"
            side_effect = self.performance_run_side_effect({
                1: (metric,),
                2: (metric,),
                3: (metric,),
            })
            with mock.patch.object(
                candidate,
                "run_command",
                side_effect=side_effect,
            ), self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "regression confirmed across three runs",
            ):
                candidate.run_candidate_performance_gate(
                    ROOT,
                    self.commit,
                    performance,
                    self.contract,
                    **self.performance_gate_kwargs(),
                    environment={},
                )

            self.assertFalse(performance.exists())
            confirmation = json.loads((
                Path(directory)
                / "performance-confirmation"
                / "confirmation.json"
            ).read_text())
            self.assertEqual(confirmation["outcome"], "confirmed-regression")
            self.assertEqual(confirmation["confirmedRegressionMetricIDs"], [metric])

    def test_candidate_performance_gate_blocks_inconclusive_mixed_candidates(self):
        first, second = self.contract["performance"][
            "requiredMeasuredMetricIDs"
        ][:2]
        with tempfile.TemporaryDirectory() as directory:
            performance = Path(directory) / "performance"
            side_effect = self.performance_run_side_effect({
                1: (first,),
                2: (second,),
                3: (first,),
            })
            with mock.patch.object(
                candidate,
                "run_command",
                side_effect=side_effect,
            ), self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "inconclusive",
            ):
                candidate.run_candidate_performance_gate(
                    ROOT,
                    self.commit,
                    performance,
                    self.contract,
                    **self.performance_gate_kwargs(),
                    environment={},
                )

            confirmation = json.loads((
                Path(directory)
                / "performance-confirmation"
                / "confirmation.json"
            ).read_text())
            self.assertEqual(confirmation["outcome"], "inconclusive")
            self.assertIsNone(confirmation["selectedRun"])

    def test_candidate_performance_gate_rejects_exit_and_identity_mismatch(self):
        metric = self.contract["performance"]["requiredMeasuredMetricIDs"][0]
        with tempfile.TemporaryDirectory() as directory:
            side_effect = self.performance_run_side_effect(
                {1: (metric,)},
                exit_codes={1: 0},
            )
            with mock.patch.object(
                candidate,
                "run_command",
                side_effect=side_effect,
            ), self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "exit status does not match",
            ):
                candidate.run_candidate_performance_gate(
                    ROOT,
                    self.commit,
                    Path(directory) / "performance",
                    self.contract,
                    **self.performance_gate_kwargs(),
                    environment={},
                )

        for identity, message in (
            ("host", "changed host identity"),
            ("toolchain", "changed toolchain identity"),
        ):
            with (
                self.subTest(identity=identity),
                tempfile.TemporaryDirectory() as directory,
            ):
                identities = {2: {identity: {identity: "different"}}}
                side_effect = self.performance_run_side_effect(
                    {1: (metric,), 2: (), 3: ()},
                    identities=identities,
                )
                with mock.patch.object(
                    candidate,
                    "run_command",
                    side_effect=side_effect,
                ), self.assertRaisesRegex(
                    candidate.CandidateAutomationError,
                    message,
                ):
                    candidate.run_candidate_performance_gate(
                        ROOT,
                        self.commit,
                        Path(directory) / "performance",
                        self.contract,
                        **self.performance_gate_kwargs(),
                        environment={},
                    )

    def test_performance_confirmation_detects_retained_ledger_tampering(self):
        metric = self.contract["performance"]["requiredMeasuredMetricIDs"][0]
        with tempfile.TemporaryDirectory() as directory:
            performance = Path(directory) / "performance"
            side_effect = self.performance_run_side_effect({
                1: (metric,),
                2: (),
                3: (),
            })
            with mock.patch.object(
                candidate,
                "run_command",
                side_effect=side_effect,
            ):
                candidate.run_candidate_performance_gate(
                    ROOT,
                    self.commit,
                    performance,
                    self.contract,
                    **self.performance_gate_kwargs(),
                    environment={},
                )
            runs_root = Path(directory) / "performance-confirmation"
            (runs_root / "run-2" / "ledger.json").write_text("{}\n")
            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "digest does not match",
            ):
                candidate.validate_performance_confirmation(
                    performance / "confirmation.json",
                    self.contract,
                    runs_root=runs_root,
                )

    def test_performance_confirmation_detects_readiness_identity_tampering(self):
        with tempfile.TemporaryDirectory() as directory:
            performance = Path(directory) / "performance"
            with mock.patch.object(
                candidate,
                "run_command",
                side_effect=self.performance_run_side_effect({1: ()}),
            ):
                candidate.run_candidate_performance_gate(
                    ROOT,
                    self.commit,
                    performance,
                    self.contract,
                    **self.performance_gate_kwargs(),
                    environment={},
                )
            runs_root = Path(directory) / "performance-confirmation"
            readiness = runs_root / "run-1" / "host-readiness.json"
            document = json.loads(readiness.read_text())
            document["binarySHA256"] = "c" * 64
            readiness.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "binary SHA-256 changed",
            ):
                candidate.validate_performance_confirmation(
                    performance / "confirmation.json",
                    self.contract,
                    runs_root=runs_root,
                )

    def test_performance_confirmation_requires_each_stage_readiness_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            performance = Path(directory) / "performance"
            with mock.patch.object(
                candidate,
                "run_command",
                side_effect=self.performance_run_side_effect({1: ()}),
            ):
                candidate.run_candidate_performance_gate(
                    ROOT,
                    self.commit,
                    performance,
                    self.contract,
                    **self.performance_gate_kwargs(),
                    environment={},
                )
            runs_root = Path(directory) / "performance-confirmation"
            (runs_root / "run-1" / "host-readiness-semantic.json").unlink()

            with self.assertRaises(candidate.CandidateAutomationError):
                candidate.validate_performance_confirmation(
                    performance / "confirmation.json",
                    self.contract,
                    runs_root=runs_root,
                )

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

    def test_memory_leak_receipt_requires_exact_release_and_zero_leak_scenarios(self):
        receipt = self.memory_leak_receipt()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.json"
            path.write_text(json.dumps(receipt))
            candidate.validate_memory_leak_receipt(
                path,
                self.contract,
                version=self.version,
                build=self.build,
                commit=self.commit,
            )

            wrong_release = copy.deepcopy(receipt)
            wrong_release["release"]["commit"] = "b" * 40
            path.write_text(json.dumps(wrong_release))
            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "release identity does not match",
            ):
                candidate.validate_memory_leak_receipt(
                    path,
                    self.contract,
                    version=self.version,
                    build=self.build,
                    commit=self.commit,
                )

            leaking = copy.deepcopy(receipt)
            leaking["scenarios"][0]["leakCount"] = 1
            path.write_text(json.dumps(leaking))
            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "leakCount must be 0",
            ):
                candidate.validate_memory_leak_receipt(
                    path,
                    self.contract,
                    version=self.version,
                    build=self.build,
                    commit=self.commit,
                )

            wrong_iterations = self.memory_leak_receipt()
            wrong_iterations["scenarios"][0]["iterations"] = 99
            path.write_text(json.dumps(wrong_iterations))
            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "iterations must be 100",
            ):
                candidate.validate_memory_leak_receipt(
                    path,
                    self.contract,
                    version=self.version,
                    build=self.build,
                    commit=self.commit,
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

    def test_complete_bilingual_ui_validates_split_harness_attribution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_ui_receipts(root)
            english_path = root / "en-runtime.json"
            english = json.loads(english_path.read_text())
            identifier = english["tests"][0]["identifier"]
            english["runtimeAdjustments"] = [{
                "identifier": identifier,
                "reportedDurationSeconds": 31.0,
                "attributedDurationSeconds": 1.0,
                "excludedPreSetupSeconds": 29.998,
                "excludedPostTeardownSeconds": 0.002,
                "excludedHarnessSeconds": 30.0,
                "reason": "outside-test-activity-boundaries",
            }]
            english_path.write_text(json.dumps(english))

            candidate.validate_ui_receipts(root, self.contract)

            english["runtimeAdjustments"][0]["excludedPostTeardownSeconds"] = 1.0
            english_path.write_text(json.dumps(english))
            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "runtime adjustment values differ",
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

            with mock.patch.object(
                candidate.subprocess,
                "run",
                return_value=completed,
            ), self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "empty or unbounded PCM metadata",
            ):
                candidate.validate_public_model_fixture(
                    path,
                    minimum_duration_seconds=60,
                )

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

    def test_public_conversation_requires_long_distinct_alternating_turns(self):
        fixture = (
            ROOT
            / "Fixtures"
            / "CandidateAutomation"
            / "public-diarization-en-es-v1.txt"
        ).read_text()
        turns = candidate.parse_public_conversation(fixture)
        self.assertEqual(
            tuple(voice for voice, _ in turns),
            candidate.EXPECTED_CONVERSATION_SEQUENCE,
        )
        self.assertTrue(
            all(
                len(text.split()) >= candidate.MINIMUM_CONVERSATION_TURN_WORDS
                for _, text in turns
            )
        )

        same_voice = fixture.replace("[[voice Daniel]]", "[[voice Paulina]]")
        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "alternating Daniel/Paulina",
        ):
            candidate.parse_public_conversation(same_voice)

        short_turn = fixture.replace(
            turns[0][1],
            "This public turn is intentionally too short.",
        )
        with self.assertRaisesRegex(
            candidate.CandidateAutomationError,
            "bounded, long",
        ):
            candidate.parse_public_conversation(short_turn)

    def test_public_conversation_wave_join_is_exact_and_owner_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            segments = []
            frames_per_turn = 16_000
            for index in range(4):
                path = root / f"turn-{index}.wav"
                with wave.open(str(path), "wb") as writer:
                    writer.setnchannels(1)
                    writer.setsampwidth(2)
                    writer.setframerate(16_000)
                    writer.writeframes(b"\0\1" * frames_per_turn)
                segments.append(path)

            output = root / "conversation.wav"
            candidate.concatenate_public_wave_segments(
                segments,
                output,
                silence_milliseconds=(
                    candidate.EXPECTED_CONVERSATION_SILENCE_MILLISECONDS
                ),
            )

            with wave.open(str(output), "rb") as reader:
                expected_silence_frames = round(16_000 * 0.7) * 3
                self.assertEqual(
                    reader.getnframes(),
                    frames_per_turn * 4 + expected_silence_frames,
                )
                self.assertEqual(reader.getnchannels(), 1)
                self.assertEqual(reader.getsampwidth(), 2)
                self.assertEqual(reader.getframerate(), 16_000)
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)
            original = output.read_bytes()
            with self.assertRaisesRegex(
                candidate.CandidateAutomationError,
                "output already exists",
            ):
                candidate.concatenate_public_wave_segments(
                    segments,
                    output,
                    silence_milliseconds=(
                        candidate.EXPECTED_CONVERSATION_SILENCE_MILLISECONDS
                    ),
                )
            self.assertEqual(output.read_bytes(), original)

    def test_public_conversation_renderer_owns_distinct_voice_processes(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "conversation.wav"
            commands = []

            def render_side_effect(_, __, ___, command, **____):
                commands.append(command)
                segment = Path(command[command.index("-o") + 1])
                with wave.open(str(segment), "wb") as writer:
                    writer.setnchannels(1)
                    writer.setsampwidth(2)
                    writer.setframerate(16_000)
                    writer.writeframes(b"\0\1" * 16_000)

            with mock.patch.object(
                candidate,
                "exact_checkout",
                return_value=self.commit,
            ), mock.patch.object(
                candidate,
                "run_command",
                side_effect=render_side_effect,
            ), mock.patch.object(
                candidate,
                "validate_public_model_fixture",
            ):
                candidate.render_public_conversation(
                    ROOT,
                    self.commit,
                    self.contract["modelFixture"],
                    output,
                    environment={},
                )

            self.assertEqual(
                tuple(command[command.index("-v") + 1] for command in commands),
                candidate.EXPECTED_CONVERSATION_SEQUENCE,
            )
            self.assertTrue(
                all("--data-format=LEI16@16000" in command for command in commands)
            )
            self.assertTrue(
                all(
                    "[[" not in command[-1] and "]]" not in command[-1]
                    for command in commands
                )
            )
            self.assertTrue(output.is_file())
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)
            self.assertFalse(any(output.parent.glob(".*-turn-*.wav")))

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
                "render_public_conversation",
            ) as conversation, mock.patch.object(
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
                "build_candidate_performance_binary",
                return_value=self.performance_build(),
            ), mock.patch.object(
                candidate,
                "sha256_file",
                return_value=self.performance_binary_sha256,
            ), mock.patch.object(
                candidate,
                "run_candidate_performance_gate",
            ) as performance, mock.patch.object(
                candidate,
                "validate_resource_receipt",
            ) as resource, mock.patch.object(
                candidate,
                "validate_memory_leak_receipt",
            ) as memory_leaks, mock.patch.object(
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
            self.assertEqual(commands.call_count, 7)
            conversation.assert_called_once()
            self.assertEqual(swift_classes.call_count, 2)
            self.assertEqual(model_fixture.call_count, 2)
            command_by_label = {
                call.args[2]: call for call in commands.call_args_list
            }
            deterministic_environment = command_by_label[
                "Finite deterministic release scope"
            ].kwargs["environment"]
            self.assertIsNone(deterministic_environment["PORTAVOZ_TEST_WAV"])
            performance_environment = performance.call_args.kwargs["environment"]
            self.assertIsNone(performance_environment["PORTAVOZ_TEST_WAV"])
            resource_call = next(
                call for call in commands.call_args_list
                if call.args[2].startswith("Release resource baseline")
            )
            self.assertEqual(
                resource_call.kwargs["environment"]["PORTAVOZ_SIGN_IDENTITY"],
                "-",
            )
            leak_call = command_by_label[
                "Content-free real-app Apuntador leak baseline"
            ]
            self.assertIn(
                "scripts/run-apuntador-leak-baseline.sh",
                leak_call.args[3],
            )
            self.assertIn("--live-assist-iterations", leak_call.args[3])
            self.assertNotIn("--iterations", leak_call.args[3])
            self.assertEqual(
                leak_call.kwargs["environment"]["PORTAVOZ_SIGN_IDENTITY"],
                "-",
            )
            model_environment = swift_classes.call_args_list[0].kwargs[
                "environment"
            ]
            self.assertEqual(model_environment["PORTAVOZ_MODEL_TESTS"], "1")
            self.assertIn("public-model-lane.aiff", model_environment["PORTAVOZ_TEST_WAV"])
            self.assertIn(
                "public-diarization-lane.wav",
                model_environment["PORTAVOZ_TEST_CONVERSATION_WAV"],
            )
            deterministic.assert_called_once()
            performance.assert_called_once()
            resource.assert_called_once()
            memory_leaks.assert_called_once()
            long_capture.assert_called_once()
            ui.assert_called_once()
            self.assertEqual(os.stat(receipt_path).st_mode & 0o777, 0o600)

    def test_run_measures_performance_before_instrumentation_heavy_gates(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "candidate"
            events = []

            def command_side_effect(_, __, label, ___, **____):
                events.append(label)

            def performance_side_effect(*_, **__):
                events.append("performance")

            def performance_build_side_effect(*_, **__):
                events.append("performance-build")
                return self.performance_build()

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
                "render_public_conversation",
            ), mock.patch.object(
                candidate,
                "run_swift_test_classes",
            ), mock.patch.object(
                candidate,
                "validate_public_model_fixture",
            ), mock.patch.object(
                candidate,
                "validate_deterministic_receipt",
            ), mock.patch.object(
                candidate,
                "build_candidate_performance_binary",
                side_effect=performance_build_side_effect,
            ), mock.patch.object(
                candidate,
                "sha256_file",
                return_value=self.performance_binary_sha256,
            ), mock.patch.object(
                candidate,
                "run_candidate_performance_gate",
                side_effect=performance_side_effect,
            ), mock.patch.object(
                candidate,
                "validate_resource_receipt",
            ), mock.patch.object(
                candidate,
                "validate_memory_leak_receipt",
            ), mock.patch.object(
                candidate,
                "validate_long_capture",
            ), mock.patch.object(
                candidate,
                "validate_ui_receipts",
            ), contextlib.redirect_stdout(io.StringIO()):
                candidate.run_candidate(
                    version=self.version,
                    build=self.build,
                    output_path=output,
                )

            self.assertEqual(events[:2], ["performance-build", "performance"])
            self.assertLess(
                events.index("performance"),
                events.index("Finite deterministic release scope"),
            )
            self.assertLess(
                events.index("performance"),
                events.index("Content-free real-app Apuntador leak baseline"),
            )
            self.assertLess(
                events.index("performance"),
                next(
                    index
                    for index, event in enumerate(events)
                    if event.startswith("Release resource baseline")
                ),
            )

    def test_model_failure_removes_both_public_scratch_audio_files(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "candidate"

            def command_side_effect(_, __, label, command, **___):
                if label.startswith("Public synthetic spoken"):
                    target = Path(command[command.index("-o") + 1])
                    target.write_bytes(b"public synthetic audio")

            def conversation_side_effect(_, __, ___, target, **____):
                target.write_bytes(b"public synthetic conversation")

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
                "render_public_conversation",
                side_effect=conversation_side_effect,
            ), mock.patch.object(
                candidate,
                "validate_public_model_fixture",
            ), mock.patch.object(
                candidate,
                "validate_deterministic_receipt",
            ), mock.patch.object(
                candidate,
                "build_candidate_performance_binary",
                return_value=self.performance_build(),
            ), mock.patch.object(
                candidate,
                "sha256_file",
                return_value=self.performance_binary_sha256,
            ), mock.patch.object(
                candidate,
                "run_candidate_performance_gate",
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
            self.assertFalse((output / "public-diarization-lane.wav").exists())
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

    def performance_host_readiness_receipt(self):
        policy = candidate.candidate_performance_readiness_policy(self.contract)
        samples = [
            {
                "sequence": sequence,
                "offsetSeconds": float((sequence - 1) * 2),
                "processorCount": 14,
                "totalCPUPercent": 100.0,
                "loadAverageOneMinute": 2.0,
                "interferenceCPUPercent": 0.0,
                "interferenceContributors": [],
                "powerSource": "ac",
                "powerMode": "automatic",
                "thermalState": "nominal",
                "reasons": [],
            }
            for sequence in range(1, 4)
        ]
        return {
            "schemaVersion": candidate.perf_host_readiness.SCHEMA_VERSION,
            "kind": "performance-host-readiness",
            "generatedAt": "2026-08-30T18:00:00Z",
            "sourceCommit": self.commit,
            "binarySHA256": self.performance_binary_sha256,
            "policy": policy.document(),
            "outcome": "ready",
            "elapsedSeconds": 4.0,
            "observedSampleCount": 3,
            "samples": samples,
            "calibrationAttemptCount": 1,
            "throughputCalibration": (
                candidate.perf_host_readiness.calibration_document(
                    candidate.perf_host_readiness.ThroughputCalibration(
                        wall_milliseconds=(160.0,) * 5,
                        cpu_milliseconds=(159.0,) * 5,
                    ),
                    policy,
                )
            ),
        }

    def performance_run_side_effect(
        self,
        candidates_by_run,
        *,
        exit_codes=None,
        identities=None,
    ):
        exit_codes = exit_codes or {}
        identities = identities or {}

        def side_effect(_, __, ___, command, **____):
            run_root = Path(command[-1])
            run_number = int(run_root.name.removeprefix("run-"))
            run_root.mkdir(parents=True)
            ledger = self.performance_ledger()
            identity = identities.get(run_number, {})
            if "host" in identity:
                ledger["host"] = identity["host"]
            if "toolchain" in identity:
                ledger["toolchain"] = identity["toolchain"]
            candidate_ids = tuple(candidates_by_run.get(run_number, ()))
            for metric in ledger["metrics"]:
                if "measured" in metric:
                    metric["measured"] = float(run_number)
                if metric["id"] in candidate_ids:
                    metric["status"] = "regression-candidate"
            ledger["summary"]["regressionCandidates"] = len(candidate_ids)
            (run_root / "ledger.json").write_text(json.dumps(ledger))
            (run_root / "ledger.md").write_text("# Performance\n")
            for name in ("scale.json", "semantic.json", "spotlight.json"):
                (run_root / name).write_text("{}\n")
            for name in (
                "host-readiness.json",
                "host-readiness-semantic.json",
                "host-readiness-spotlight.json",
            ):
                (run_root / name).write_text(json.dumps(
                    self.performance_host_readiness_receipt()
                ))
            return exit_codes.get(run_number, 2 if candidate_ids else 0)

        return side_effect

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

    def memory_leak_receipt(self):
        leak_contract = self.contract["memoryLeaks"]["contract"]
        return {
            "schemaVersion": candidate.apuntador_leak_baseline.SCHEMA_VERSION,
            "kind": "apuntador-leak-baseline",
            "collectedAt": "2026-08-30T18:00:00Z",
            "release": {
                "version": self.version,
                "build": self.build,
                "commit": self.commit,
            },
            "host": {
                "platform": "macOS",
                "version": "26.5.2",
                "build": "25F84",
                "architecture": "arm64",
            },
            "toolchain": {
                "xcode": "26.6",
                "build": "17F113",
                "leaksMode": "at-exit-no-content-no-stacks",
            },
            "policies": leak_contract["policies"],
            "scenarios": [
                {
                    "id": identifier,
                    "state": "pass",
                    "iterations": leak_contract["scenarios"][identifier][
                        "iterations"
                    ],
                    "leakCount": 0,
                    "leakedBytes": 0,
                    "evidenceSHA256": {
                        key: "b" * 64
                        for key in leak_contract["scenarios"][identifier]["evidence"]
                    },
                }
                for identifier in leak_contract["orderedScenarioIDs"]
            ],
            "summary": {
                "scenarioCount": 4,
                "passed": 4,
                "leakCount": 0,
                "leakedBytes": 0,
            },
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
                "schemaVersion": 3,
                "measurementPolicy": (
                    "xcresult-duration-with-activity-boundary-exclusions-v2"
                ),
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
                "runtimeAdjustments": [],
                "tests": tests,
            }
            (root / f"{locale}-runtime.json").write_text(json.dumps(receipt))


if __name__ == "__main__":
    unittest.main()
