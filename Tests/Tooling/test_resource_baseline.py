import importlib.util
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "resource_baseline.py"
SPEC = importlib.util.spec_from_file_location("resource_baseline", SCRIPT)
baseline = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(baseline)


class ResourceBaselineTests(unittest.TestCase):
    version = "0.9.0"
    build = "202607280002"
    commit = "a" * 40
    profile_memory = {
        "memory-8gb": 8 * 1024**3,
        "memory-16gb": 16 * 1024**3,
        "reference": 36 * 1024**3,
    }

    def test_complete_matrix_passes_and_uses_nearest_rank_aggregates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipts = [
                self.write_receipt(root, profile)
                for profile in self.profile_memory
            ]
            output = root / "scorecard"

            result = baseline.main_from_args(self.evaluate_args(receipts, output))

            self.assertEqual(result, 0)
            scorecard = self.read_scorecard(output)
            self.assertEqual(scorecard["outcome"], "pass")
            self.assertEqual(scorecard["schemaVersion"], 4)
            self.assertEqual(
                scorecard["minimumBlockingTimingDeltaMilliseconds"],
                100,
            )
            self.assertEqual(
                scorecard["recordingInput"],
                {
                    "generation": "public-synthetic-dual-channel-v2",
                    "sampleRate": 16_000,
                    "chunkFrames": 1_600,
                },
            )
            self.assertEqual(
                scorecard["preparations"],
                [{
                    "id": "refine-runtime",
                    "generation": "refine-runtime-preparation-v1",
                }],
            )
            self.assertEqual(len(scorecard["measurements"]), 27)
            recording = next(
                row
                for row in scorecard["measurements"]
                if row["profile"] == "memory-8gb"
                and row["scenario"] == "recording"
            )
            self.assertEqual(recording["sampleCount"], 3)
            self.assertEqual(
                recording["metrics"]["wallDurationMilliseconds"],
                {"maximum": 1030.0, "p50": 1020.0, "p95": 1030.0},
            )
            ask = next(
                row
                for row in scorecard["askPipelineMeasurements"]
                if row["profile"] == "memory-8gb"
            )
            self.assertEqual(ask["state"], "pass")
            self.assertEqual(
                ask["metrics"]["firstEvidence"]["wallDurationMilliseconds"],
                {"maximum": 615.0, "p50": 610.0, "p95": 615.0},
            )
            self.assertEqual(ask["corpus"]["checksum"], "c" * 64)
            self.assertEqual(
                os.stat(output / "resource-baseline.json").st_mode & 0o777,
                0o600,
            )

    def test_no_receipts_produces_complete_blocked_matrix(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "scorecard"

            result = baseline.main_from_args(self.evaluate_args([], output))

            self.assertEqual(result, 1)
            scorecard = self.read_scorecard(output)
            self.assertEqual(scorecard["outcome"], "blocked")
            self.assertEqual(len(scorecard["measurements"]), 27)
            self.assertTrue(
                all(row["state"] == "missing" for row in scorecard["measurements"])
            )
            self.assertTrue(
                all(
                    row["state"] == "missing"
                    for row in scorecard["askPipelineMeasurements"]
                )
            )

    def test_pass_with_too_few_samples_is_incomplete_not_malformed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_receipt(root, "memory-8gb")
            document = json.loads(receipt.read_text())
            document["scenarios"][0]["samples"] = document["scenarios"][0]["samples"][:2]
            receipt.write_text(json.dumps(document))

            output = root / "scorecard"
            result = baseline.main_from_args(self.evaluate_args([receipt], output))

            self.assertEqual(result, 1)
            scorecard = self.read_scorecard(output)
            idle = next(
                row
                for row in scorecard["measurements"]
                if row["profile"] == "memory-8gb"
                and row["scenario"] == "idle"
            )
            self.assertEqual(idle["state"], "incomplete")
            self.assertEqual(idle["sampleCount"], 2)

    def test_inconsistent_timing_samples_are_unstable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_receipt(root, "memory-8gb")
            document = json.loads(receipt.read_text())
            document["scenarios"][0]["samples"][2][
                "wallDurationMilliseconds"
            ] = 10_000
            receipt.write_text(json.dumps(document))

            output = root / "scorecard"
            result = baseline.main_from_args(self.evaluate_args([receipt], output))

            self.assertEqual(result, 1)
            idle = next(
                row
                for row in self.read_scorecard(output)["measurements"]
                if row["profile"] == "memory-8gb"
                and row["scenario"] == "idle"
            )
            self.assertEqual(idle["state"], "unstable")

    def test_dual_timing_stability_ignores_noise_but_blocks_regressions(self):
        def metrics(wall_p50, wall_p95, cpu_p50, cpu_p95):
            return {
                "wallDurationMilliseconds": {
                    "p50": wall_p50,
                    "p95": wall_p95,
                },
                "cpuTimeMilliseconds": {
                    "p50": cpu_p50,
                    "p95": cpu_p95,
                },
            }

        # Exact cc9d2e4 candidate Stop evidence. The CPU ratio is 1.282589,
        # but its 47.0938 ms absolute delta is below the blocking floor.
        self.assertTrue(baseline.timing_is_stable(
            metrics(
                126.939333,
                128.05175,
                166.65133333333335,
                213.74516666666665,
            ),
            maximum_ratio=1.25,
            minimum_blocking_delta=100,
        ))
        # Exact cc9d2e4 Ask fusion evidence: a large ratio over a 0.021791 ms
        # delta is timer noise, not a release-blocking resource regression.
        self.assertTrue(baseline.timing_is_stable(
            metrics(
                0.068667,
                0.090458,
                0.06870833333333333,
                0.0905,
            ),
            maximum_ratio=1.25,
            minimum_blocking_delta=100,
        ))
        # D398's first-use Refine regression remains actionable by both tests.
        self.assertFalse(baseline.timing_is_stable(
            metrics(
                4_751.910334,
                137_808.281667,
                2_780.8050416666665,
                46_452.165791666666,
            ),
            maximum_ratio=1.25,
            minimum_blocking_delta=100,
        ))
        # The floor is inclusive when the relative ratio also exceeds 1.25.
        self.assertFalse(baseline.timing_is_stable(
            metrics(300, 400, 300, 400),
            maximum_ratio=1.25,
            minimum_blocking_delta=100,
        ))
        self.assertTrue(baseline.timing_is_stable(
            metrics(0, 99.999, 0, 99.999),
            maximum_ratio=1.25,
            minimum_blocking_delta=100,
        ))
        self.assertFalse(baseline.timing_is_stable(
            metrics(0, 100, 0, 100),
            maximum_ratio=1.25,
            minimum_blocking_delta=100,
        ))

    def test_failed_and_not_observed_scenarios_remain_blocking(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_receipt(root, "memory-8gb")
            document = json.loads(receipt.read_text())
            document["scenarios"][0]["state"] = "fail"
            document["scenarios"][1]["state"] = "not-observed"
            document["scenarios"][1]["samples"] = []
            receipt.write_text(json.dumps(document))

            output = root / "scorecard"
            result = baseline.main_from_args(self.evaluate_args([receipt], output))

            self.assertEqual(result, 1)
            states = {
                row["scenario"]: row["state"]
                for row in self.read_scorecard(output)["measurements"]
                if row["profile"] == "memory-8gb"
            }
            self.assertEqual(states["idle"], "fail")
            self.assertEqual(states["recording"], "not-observed")

    def test_duplicate_profile_receipts_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self.write_receipt(root, "memory-8gb", suffix="first")
            second = self.write_receipt(root, "memory-8gb", suffix="second")

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "repeats profile: memory-8gb",
            ):
                baseline.evaluate_namespace(
                    baseline.build_parser().parse_args(
                        self.evaluate_args([first, second], root / "scorecard")
                    )
                )

    def test_build_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_receipt(root, "memory-8gb")
            document = json.loads(receipt.read_text())
            document["build"]["commit"] = "b" * 40
            receipt.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "does not match requested build",
            ):
                baseline.evaluate_namespace(
                    baseline.build_parser().parse_args(
                        self.evaluate_args([receipt], root / "scorecard")
                    )
                )

    def test_memory_profile_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_receipt(root, "memory-8gb")
            document = json.loads(receipt.read_text())
            document["host"]["physicalMemoryBytes"] = 16 * 1024**3
            receipt.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "does not match profile memory-8gb",
            ):
                baseline.evaluate_namespace(
                    baseline.build_parser().parse_args(
                        self.evaluate_args([receipt], root / "scorecard")
                    )
                )

    def test_content_bearing_addition_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_receipt(root, "memory-8gb")
            document = json.loads(receipt.read_text())
            document["meetingTitle"] = "private"
            receipt.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "forbidden keys: meetingTitle",
            ):
                baseline.evaluate_namespace(
                    baseline.build_parser().parse_args(
                        self.evaluate_args([receipt], root / "scorecard")
                    )
                )

    def test_nonfinite_metric_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_receipt(root, "memory-8gb")
            document = json.loads(receipt.read_text())
            document["scenarios"][0]["samples"][0][
                "wallDurationMilliseconds"
            ] = float("nan")
            receipt.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "wallDurationMilliseconds must be finite",
            ):
                baseline.evaluate_namespace(
                    baseline.build_parser().parse_args(
                        self.evaluate_args([receipt], root / "scorecard")
                    )
                )

    def test_invalid_ask_citation_evidence_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_receipt(root, "memory-8gb")
            document = json.loads(receipt.read_text())
            document["askPipeline"]["samples"][0]["citations"][
                "valid"
            ] = False
            receipt.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "citations.valid must be true",
            ):
                baseline.evaluate_namespace(
                    baseline.build_parser().parse_args(
                        self.evaluate_args([receipt], root / "scorecard")
                    )
                )

    def test_nondeterministic_ask_citations_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_receipt(root, "memory-8gb")
            document = json.loads(receipt.read_text())
            document["askPipeline"]["samples"][1]["citations"][
                "digest"
            ] = "e" * 64
            receipt.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "citations are nondeterministic",
            ):
                baseline.evaluate_namespace(
                    baseline.build_parser().parse_args(
                        self.evaluate_args([receipt], root / "scorecard")
                    )
                )

    def test_ask_pipeline_rejects_content_bearing_addition(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_receipt(root, "memory-8gb")
            document = json.loads(receipt.read_text())
            document["askPipeline"]["samples"][0][
                "question"
            ] = "private"
            receipt.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "forbidden keys: question",
            ):
                baseline.evaluate_namespace(
                    baseline.build_parser().parse_args(
                        self.evaluate_args([receipt], root / "scorecard")
                    )
                )

    def test_ask_pipeline_rejects_request_time_corpus_backfill(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_receipt(root, "memory-8gb")
            document = json.loads(receipt.read_text())
            corpus = document["askPipeline"]["samples"][0]["corpus"]
            corpus["pendingBefore"] = 1
            corpus["readyBefore"] = False
            receipt.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "setup-only indexing and query-time readiness",
            ):
                baseline.evaluate_namespace(
                    baseline.build_parser().parse_args(
                        self.evaluate_args([receipt], root / "scorecard")
                    )
                )

    def test_duplicate_run_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_receipt(root, "memory-8gb")
            document = json.loads(receipt.read_text())
            document["scenarios"][0]["samples"][1]["run"] = 1
            receipt.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "repeats run: 1",
            ):
                baseline.evaluate_namespace(
                    baseline.build_parser().parse_args(
                        self.evaluate_args([receipt], root / "scorecard")
                    )
                )

    def test_pass_sample_missing_required_workload_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_receipt(root, "memory-8gb")
            document = json.loads(receipt.read_text())
            document["scenarios"][1]["samples"][0]["workloads"] = []
            receipt.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "missing workloads: .*recordingCritical/audioCapture/execute",
            ):
                baseline.evaluate_namespace(
                    baseline.build_parser().parse_args(
                        self.evaluate_args([receipt], root / "scorecard")
                    )
                )

    def test_contract_rejects_unknown_workload_enum(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contract = json.loads(baseline.DEFAULT_CONTRACT.read_text())
            contract["scenarios"][1]["requiredWorkloads"][0][
                "workloadClass"
            ] = "urgent"
            contract_path = root / "contract.json"
            contract_path.write_text(json.dumps(contract))

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "workloadClass must be one of",
            ):
                baseline.validate_contract(
                    baseline.load_json(contract_path, "resource contract")
                )

    def test_contract_cannot_weaken_stability_rules(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mutations = (
                (
                    "minimumStableSamples",
                    1,
                    "minimumStableSamples must be an integer >= 3",
                ),
                (
                    "maximumTimingP95ToP50Ratio",
                    2.0,
                    "maximumTimingP95ToP50Ratio must be <= 1.25",
                ),
                (
                    "minimumBlockingTimingDeltaMilliseconds",
                    101,
                    "minimumBlockingTimingDeltaMilliseconds must be <= 100",
                ),
            )
            for key, value, message in mutations:
                with self.subTest(key=key):
                    contract = json.loads(baseline.DEFAULT_CONTRACT.read_text())
                    contract[key] = value
                    contract_path = root / f"{key}.json"
                    contract_path.write_text(json.dumps(contract))

                    with self.assertRaisesRegex(
                        baseline.ResourceBaselineError,
                        message,
                    ):
                        baseline.validate_contract(
                            baseline.load_json(
                                contract_path,
                                "resource contract",
                            )
                        )

    def test_contract_requires_every_hardware_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contract = json.loads(baseline.DEFAULT_CONTRACT.read_text())
            contract["profiles"] = contract["profiles"][:-1]
            contract_path = root / "contract.json"
            contract_path.write_text(json.dumps(contract))

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "profiles must be exactly",
            ):
                baseline.validate_contract(
                    baseline.load_json(contract_path, "resource contract")
                )

    def test_tracked_contract_pins_the_required_matrix(self):
        contract = baseline.validate_contract(
            baseline.load_json(baseline.DEFAULT_CONTRACT, "resource contract")
        )
        self.assertEqual(contract["minimumSamples"], 3)
        self.assertEqual(contract["minimumBlockingTimingDelta"], 100)
        self.assertEqual(contract["maximumTimingRatio"], 1.25)
        self.assertEqual(
            contract["preparations"],
            baseline.REQUIRED_PREPARATIONS,
        )
        self.assertEqual(
            contract["profiles"],
            {
                "memory-8gb": {
                    "minimum": 7 * 1024**3,
                    "maximum": 10 * 1024**3,
                },
                "memory-16gb": {
                    "minimum": 14 * 1024**3,
                    "maximum": 18 * 1024**3,
                },
                "reference": {
                    "minimum": 32 * 1024**3,
                    "maximum": None,
                },
            },
        )
        self.assertEqual(
            contract["scenarios"],
            {
                "idle": (),
                "recording": (
                    ("recordingCritical", "audioCapture", "execute"),
                    ("liveInteractive", "liveTranscription", "execute"),
                ),
                "stop": (
                    ("recordingCritical", "audioCapture", "execute"),
                ),
                "refine": (
                    ("userInitiated", "qualityTranscription", "execute"),
                    ("userInitiated", "speakerDiarization", "execute"),
                ),
                "summary": (
                    ("userInitiated", "languageInference", "queueWait"),
                    ("userInitiated", "languageInference", "execute"),
                ),
                "ask": (
                    ("userInitiated", "languageInference", "queueWait"),
                    ("userInitiated", "languageInference", "execute"),
                ),
                "indexing": (
                    ("maintenance", "searchIndex", "execute"),
                ),
                "recording-indexing": (
                    ("recordingCritical", "audioCapture", "execute"),
                    ("liveInteractive", "liveTranscription", "execute"),
                    ("maintenance", "searchIndex", "execute"),
                ),
                "recording-batch": (
                    ("recordingCritical", "audioCapture", "execute"),
                    ("liveInteractive", "liveTranscription", "execute"),
                    ("postCapture", "qualityTranscription", "execute"),
                ),
            },
        )

    def test_duplicate_json_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "duplicate.json"
            receipt.write_text('{"schemaVersion": 1, "schemaVersion": 1}')

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "duplicate key: schemaVersion",
            ):
                baseline.load_json(receipt, "resource receipt")

    def test_scorecard_never_contains_source_paths_or_payload_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_receipt(root, "memory-8gb")
            output = root / "private-scorecard"

            baseline.main_from_args(self.evaluate_args([receipt], output))

            rendered = (output / "resource-baseline.md").read_text()
            encoded = (output / "resource-baseline.json").read_text()
            self.assertIn("## Ask pipeline", rendered)
            self.assertIn("| Profile | Stage |", rendered)
            self.assertIn("`ask-resource-v2`", rendered)
            self.assertNotIn(str(receipt), rendered)
            self.assertNotIn(str(receipt), encoded)
            self.assertNotIn("meeting", encoded.lower())
            self.assertNotIn("transcript", encoded.lower())

    def test_assemble_builds_an_exact_owner_only_host_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            recording = root / "recording-1.json"
            refine = root / "refine-1.json"
            summary = root / "summary-1.json"
            ask = root / "ask-1.json"
            ask_pipeline = root / "ask-pipeline-1.json"
            indexing = root / "indexing-1.json"
            recording_indexing = root / "recording-indexing-1.json"
            recording_batch = root / "recording-batch-1.json"
            stop = root / "stop-1.json"
            idle = root / "idle-1.json"
            scenarios = dict(self.required_scenarios())
            idle.write_text(json.dumps(
                self.sample(1, scenarios["idle"])))
            recording.write_text(json.dumps(
                self.sample(1, scenarios["recording"])))
            refine.write_text(json.dumps(
                self.sample(1, scenarios["refine"])))
            summary.write_text(json.dumps(
                self.sample(1, scenarios["summary"])))
            ask.write_text(json.dumps(
                self.sample(1, scenarios["ask"])))
            ask_pipeline.write_text(json.dumps(
                self.ask_pipeline_sample(1)))
            indexing.write_text(json.dumps(
                self.sample(1, scenarios["indexing"])))
            recording_indexing.write_text(json.dumps(
                self.sample(1, scenarios["recording-indexing"])))
            recording_batch.write_text(json.dumps(
                self.sample(1, scenarios["recording-batch"])))
            stop.write_text(json.dumps(
                self.sample(1, scenarios["stop"])))
            preparation = self.write_preparation_marker(root)
            output = root / "receipt.json"

            with mock.patch.object(
                baseline,
                "detect_machine_metadata",
                return_value=self.machine_metadata("memory-8gb"),
            ):
                result = baseline.main_from_args([
                    "assemble",
                    "--version",
                    self.version,
                    "--build",
                    self.build,
                    "--commit",
                    self.commit,
                    "--profile",
                    "memory-8gb",
                    "--preparation",
                    f"refine-runtime={preparation}",
                    "--sample",
                    f"idle={idle}",
                    "--sample",
                    f"recording={recording}",
                    "--sample",
                    f"refine={refine}",
                    "--sample",
                    f"summary={summary}",
                    "--sample",
                    f"ask={ask}",
                    "--ask-pipeline-sample",
                    str(ask_pipeline),
                    "--sample",
                    f"indexing={indexing}",
                    "--sample",
                    f"recording-indexing={recording_indexing}",
                    "--sample",
                    f"recording-batch={recording_batch}",
                    "--sample",
                    f"stop={stop}",
                    "--output",
                    str(output),
                ])

            self.assertEqual(result, 0)
            receipt = json.loads(output.read_text())
            self.assertEqual(receipt["kind"], "resource-baseline")
            self.assertEqual(receipt["schemaVersion"], 4)
            self.assertEqual(
                receipt["recordingInput"]["generation"],
                "public-synthetic-dual-channel-v2",
            )
            self.assertEqual(
                receipt["askPipeline"]["samples"][0]["run"], 1
            )
            self.assertEqual(
                receipt["preparations"],
                [{
                    "id": "refine-runtime",
                    "generation": "refine-runtime-preparation-v1",
                    "state": "completed",
                }],
            )
            self.assertEqual(receipt["host"]["profile"], "memory-8gb")
            self.assertEqual(
                [scenario["id"] for scenario in receipt["scenarios"]],
                [
                    "ask", "idle", "indexing", "recording",
                    "recording-batch", "recording-indexing", "refine",
                    "stop", "summary",
                ],
            )
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)
            baseline.validate_receipt(
                receipt,
                baseline.validate_contract(
                    baseline.load_json(
                        baseline.DEFAULT_CONTRACT,
                        "resource contract",
                    )
                ),
                "assembled receipt",
            )

    def test_assemble_rejects_duplicate_scenario_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scenarios = dict(self.required_scenarios())
            first = root / "recording-first.json"
            second = root / "recording-second.json"
            sample = self.sample(1, scenarios["recording"])
            first.write_text(json.dumps(sample))
            second.write_text(json.dumps(sample))
            preparation = self.write_preparation_marker(root)

            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "repeat recording run: 1",
            ):
                baseline.assemble_namespace(
                    baseline.build_parser().parse_args([
                        "assemble",
                        "--version",
                        self.version,
                        "--build",
                        self.build,
                        "--commit",
                        self.commit,
                        "--profile",
                        "memory-8gb",
                        "--preparation",
                        f"refine-runtime={preparation}",
                        "--sample",
                        f"recording={first}",
                        "--sample",
                        f"recording={second}",
                        "--output",
                        str(root / "receipt.json"),
                    ])
                )

    def test_assemble_requires_exact_owner_only_runtime_preparation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            idle = root / "idle.json"
            idle.write_text(json.dumps(self.sample(1, [])))
            base = [
                "assemble",
                "--version",
                self.version,
                "--build",
                self.build,
                "--commit",
                self.commit,
                "--profile",
                "memory-8gb",
                "--sample",
                f"idle={idle}",
                "--output",
                str(root / "receipt.json"),
            ]
            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "must cover every contracted id",
            ):
                baseline.assemble_namespace(
                    baseline.build_parser().parse_args(base)
                )

            marker = root / "bad-marker"
            marker.write_text("unexpected\n", encoding="utf-8")
            marker.chmod(0o600)
            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "marker is invalid",
            ):
                baseline.assemble_namespace(
                    baseline.build_parser().parse_args(
                        base[:-2]
                        + [
                            "--preparation",
                            f"refine-runtime={marker}",
                        ]
                        + base[-2:]
                    )
                )

            marker.write_text(
                baseline.REQUIRED_PREPARATIONS["refine-runtime"]["marker"],
                encoding="utf-8",
            )
            marker.chmod(0o644)
            with self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "mode 0600",
            ):
                baseline.assemble_namespace(
                    baseline.build_parser().parse_args(
                        base[:-2]
                        + [
                            "--preparation",
                            f"refine-runtime={marker}",
                        ]
                        + base[-2:]
                    )
                )

    def test_assemble_rejects_sample_without_required_workload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sample = root / "recording.json"
            sample.write_text(json.dumps(self.sample(1, [])))
            preparation = self.write_preparation_marker(root)

            with mock.patch.object(
                baseline,
                "detect_machine_metadata",
                return_value=self.machine_metadata("memory-8gb"),
            ), self.assertRaisesRegex(
                baseline.ResourceBaselineError,
                "missing workloads: .*liveTranscription.*audioCapture",
            ):
                baseline.assemble_namespace(
                    baseline.build_parser().parse_args([
                        "assemble",
                        "--version",
                        self.version,
                        "--build",
                        self.build,
                        "--commit",
                        self.commit,
                        "--profile",
                        "memory-8gb",
                        "--preparation",
                        f"refine-runtime={preparation}",
                        "--sample",
                        f"recording={sample}",
                        "--output",
                        str(root / "receipt.json"),
                    ])
                )

    def test_machine_metadata_uses_native_version_and_hardware_surfaces(self):
        outputs = {
            ("sw_vers", "-productVersion"): "26.0",
            ("sw_vers", "-buildVersion"): "25A5316i",
            ("sysctl", "-n", "hw.memsize"): str(8 * 1024**3),
            ("sysctl", "-n", "hw.model"): "Mac16,5",
            ("xcodebuild", "-version"): "Xcode 26.0\nBuild version 17A123",
            ("swift", "--version"): (
                "Apple Swift version 6.2 (swiftlang-6.2.0.1 clang-1700.0.1)"
            ),
        }

        with mock.patch.object(
            baseline.platform,
            "system",
            return_value="Darwin",
        ), mock.patch.object(
            baseline.platform,
            "machine",
            return_value="arm64",
        ), mock.patch.object(
            baseline,
            "command_output",
            side_effect=lambda command, _: outputs[tuple(command)],
        ):
            contract = baseline.validate_contract(
                baseline.load_json(
                    baseline.DEFAULT_CONTRACT,
                    "resource contract",
                )
            )
            host, toolchain = baseline.detect_machine_metadata(
                "memory-8gb",
                contract,
            )

        self.assertEqual(host["physicalMemoryBytes"], 8 * 1024**3)
        self.assertEqual(host["hardwareModel"], "Mac16,5")
        self.assertEqual(toolchain["xcodeVersion"], "26.0")
        self.assertEqual(toolchain["swiftVersion"], "6.2")

    def test_resource_runner_is_release_bound_isolated_and_builds_once(self):
        runner = (
            REPOSITORY / "scripts" / "run-resource-baseline.sh"
        ).read_text()
        local_entitlements = plistlib.loads(
            (
                REPOSITORY / "packaging" / "portavoz-local.entitlements"
            ).read_bytes()
        )
        bench_entitlements = plistlib.loads(
            (
                REPOSITORY
                / "packaging"
                / "portavoz-resource-bench.entitlements"
            ).read_bytes()
        )

        self.assertIn("git status --porcelain --untracked-files=all", runner)
        self.assertIn("scripts/make-app.sh --release", runner)
        self.assertIn("app.portavoz.mac.resource-bench", runner)
        self.assertEqual(
            bench_entitlements,
            {
                **local_entitlements,
                "com.apple.security.cs.disable-library-validation": True,
            },
        )
        self.assertNotIn(
            "com.apple.security.cs.disable-library-validation",
            local_entitlements,
        )
        self.assertIn(
            'if [[ "$SIGN_ID" == "-" ]]; then',
            runner,
        )
        self.assertIn(
            "packaging/portavoz-resource-bench.entitlements",
            runner,
        )
        self.assertIn(
            "Developer-ID resource evidence must retain library validation",
            runner,
        )
        self.assertIn('python3 - "$SIGNED_ENTITLEMENTS"', runner)
        self.assertIn("entitlements = plistlib.load(handle)", runner)
        self.assertIn("if key not in entitlements:", runner)
        self.assertIn('print("absent")', runner)
        self.assertIn("entitlements[key] is True", runner)
        self.assertIn("entitlements[key] is False", runner)
        self.assertIn(
            "could not inspect the signed library-validation entitlement",
            runner,
        )
        self.assertNotIn(
            "plutil -extract com.apple.security.cs.disable-library-validation",
            runner,
        )
        self.assertIn("--bench-resource-launch-probe", runner)
        self.assertIn("portavoz-resource-benchmark-ready-v1", runner)
        self.assertIn('stat -f %Lp "$launch_probe"', runner)
        self.assertIn("--bench-resource-prepare-refine", runner)
        self.assertIn(
            "portavoz-resource-refine-runtime-prepared-v1",
            runner,
        )
        self.assertIn(
            '--preparation "refine-runtime=$refine_runtime_marker"',
            runner,
        )
        self.assertLess(
            runner.index("Preparing Refine runtime before repeated measurement"),
            runner.index("for ((run = 1; run <= RUNS; run++))"),
        )
        loop_marker = "for ((run = 1; run <= RUNS; run++)); do"
        scenario_loops = runner.split(loop_marker)[1:]
        expected_grouped_samples = [
            (
                "Collecting idle/recording/Stop resource sample",
                ("idle=$idle_sample", "recording=$recording_sample", "stop=$stop_sample"),
            ),
            (
                "Collecting recording plus indexing resource sample",
                ("recording-indexing=$recording_indexing_sample",),
            ),
            (
                "Collecting recording plus batch resource sample",
                ("recording-batch=$recording_batch_sample",),
            ),
            ("Collecting Refine resource sample", ("refine=$refine_sample",)),
            ("Collecting Summary resource sample", ("summary=$summary_sample",)),
            (
                "Collecting Ask resource sample",
                ("ask=$ask_sample", "--ask-pipeline-sample"),
            ),
            (
                "Collecting semantic indexing resource sample",
                ("indexing=$indexing_sample",),
            ),
        ]
        self.assertEqual(len(scenario_loops), len(expected_grouped_samples))
        for loop, (message, samples) in zip(
            scenario_loops,
            expected_grouped_samples,
            strict=True,
        ):
            body = loop.split("\ndone", 1)[0]
            self.assertIn(message, body)
            self.assertIn('export PORTAVOZ_AUDIO_ROOT=', body)
            for sample in samples:
                self.assertIn(sample, body)
        self.assertIn("-use-temp-store", runner)
        self.assertIn("--bench-resource-output", runner)
        self.assertIn("--bench-resource-run", runner)
        self.assertIn("--bench-resource-idle-duration", runner)
        self.assertIn("--bench-resource-refine", runner)
        self.assertIn("--bench-resource-summary", runner)
        self.assertIn("--bench-resource-ask", runner)
        self.assertIn("--bench-resource-indexing", runner)
        self.assertIn("--bench-resource-recording-indexing", runner)
        self.assertIn("--bench-resource-recording-batch", runner)
        self.assertEqual(
            runner.count("--bench-resource-synthetic-capture"),
            3,
        )
        self.assertIn("PROCESS_TIMEOUT=1800", runner)
        self.assertIn("--bench-resource-process-timeout", runner)
        self.assertIn("MAX_BENCHMARK_PHASE_TIMEOUT", runner)
        self.assertIn(
            "PROCESS_TIMEOUT >= MAX_BENCHMARK_PHASE_TIMEOUT + 420",
            runner,
        )
        self.assertIn("guard_timeout=$((PROCESS_TIMEOUT + 30))", runner)
        self.assertIn('ACTIVE_LAUNCH_PID="$launch_pid"', runner)
        self.assertIn('ACTIVE_GUARD_PID="$guard_pid"', runner)
        self.assertIn("terminate_benchmark_processes", runner)
        self.assertIn('"$ROOT/scripts/benchmark_watchdog.py"', runner)
        self.assertIn('--pid "$launch_pid" --timeout "$guard_timeout"', runner)
        self.assertIn('if [[ -f "$timed_out_marker" ]]; then', runner)
        self.assertIn("launch_status=124", runner)
        self.assertIn("if (( launch_status != 0 )); then", runner)
        self.assertIn(
            'pgrep -f -- "$APP/Contents/MacOS/portavoz-app"',
            runner,
        )
        self.assertIn("--bench-resource-timeout", runner)
        self.assertIn('idle_sample="$fragments/idle-$run.json"', runner)
        self.assertIn('sample_arguments+=(--sample "idle=$idle_sample")', runner)
        self.assertIn('refine_sample="$fragments/refine-$run.json"', runner)
        self.assertIn(
            'sample_arguments+=(--sample "refine=$refine_sample")',
            runner,
        )
        self.assertIn('summary_sample="$fragments/summary-$run.json"', runner)
        self.assertIn(
            'sample_arguments+=(--sample "summary=$summary_sample")',
            runner,
        )
        self.assertIn('ask_sample="$fragments/ask-$run.json"', runner)
        self.assertIn(
            'ask_pipeline_sample="$fragments/ask-pipeline-$run.json"',
            runner,
        )
        self.assertIn(
            'sample_arguments+=(--sample "ask=$ask_sample")',
            runner,
        )
        self.assertIn(
            '--ask-pipeline-sample "$ask_pipeline_sample"',
            runner,
        )
        self.assertIn(
            'indexing_sample="$fragments/indexing-$run.json"',
            runner,
        )
        self.assertIn(
            'sample_arguments+=(--sample "indexing=$indexing_sample")',
            runner,
        )
        self.assertIn(
            'recording_indexing_sample="$fragments/'
            'recording-indexing-$run.json"',
            runner,
        )
        self.assertIn(
            '"recording-indexing=$recording_indexing_sample"',
            runner,
        )
        self.assertIn(
            'recording_batch_sample="$fragments/'
            'recording-batch-$run.json"',
            runner,
        )
        self.assertIn(
            '"recording-batch=$recording_batch_sample"',
            runner,
        )
        self.assertIn("say -v Samantha -r 170", runner)
        self.assertIn("fixture_audio_bytes", runner)
        self.assertIn("(( fixture_audio_bytes > 0 ))", runner)
        self.assertNotIn("$RUNS…", runner)
        self.assertEqual(runner.count("${RUNS}…"), 7)
        self.assertIn("RUNS=3", runner)
        self.assertIn("(( RUNS >= 3 ))", runner)
        self.assertIn("MODEL_TIMEOUT=900", runner)
        self.assertIn("(( MODEL_TIMEOUT >= 60 ))", runner)
        self.assertIn("(( MODEL_TIMEOUT <= 3600 ))", runner)
        self.assertIn('if [[ "$OUTPUT" != /* ]]; then', runner)
        self.assertIn('OUTPUT="$ROOT/$OUTPUT"', runner)
        # One launch preflight, one Refine-runtime preparation, and one
        # measured app invocation declaration per grouped scenario family.
        self.assertEqual(runner.count("run_benchmark_app"), 10)
        self.assertNotIn(
            'open -W -n "$APP/Contents/MacOS/portavoz-app"',
            runner,
        )
        self.assertIn("resource_baseline.py assemble", runner)
        self.assertNotIn("/Applications/Portavoz.app", runner)
        self.assertLess(
            runner.index("scripts/make-app.sh --release"),
            runner.index("for ((run = 1; run <= RUNS; run++))"),
        )

    def test_failed_collection_preserves_only_incomplete_content_free_evidence(self):
        runner = (REPOSITORY / "scripts" / "run-resource-baseline.sh").read_text()
        cleanup = runner[runner.index("cleanup() {"):runner.index("\ntrap cleanup EXIT")]
        traps = runner[runner.index("trap cleanup EXIT"):runner.index("\n\nPORTAVOZ_SIGN_IDENTITY")]
        cases = [(0, ""), (64, ""), (130, ""), (129, "HUP"), (130, "INT"), (143, "TERM")]
        for exit_status, signal in cases:
            with self.subTest(exit_status=exit_status, signal=signal), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                collection = root / "evidence.partial.fixture"
                fragments = collection / "fragments"
                fragments.mkdir(parents=True, mode=0o700)
                collection.chmod(0o700)
                sample = fragments / "idle-1.json"
                sample.write_text('{"run":1}\n')
                sample.chmod(0o600)
                scratch = root / "scratch"
                scratch.mkdir()
                (scratch / "raw-fixture.txt").write_text("never retain raw fixtures")
                process = subprocess.run(
                    ["bash", "-c", "set -euo pipefail\n" + cleanup
                     + "\n" + traps
                     + '\nif [[ -n "$TEST_SIGNAL" ]]; then kill -s "$TEST_SIGNAL" "$$"; exit 77; fi'
                     + '\nexit "$TEST_EXIT_STATUS"'],
                    env={**os.environ, "COLLECTION": str(collection),
                         "RUN_ROOT": str(scratch), "ACTIVE_GUARD_PID": "",
                         "ACTIVE_LAUNCH_PID": "", "PORTAVOZ_KEEP_RESOURCE_BENCH": "0",
                         "TEST_EXIT_STATUS": str(exit_status), "TEST_SIGNAL": signal},
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(process.returncode, exit_status)
                self.assertFalse(scratch.exists())
                self.assertEqual(collection.exists(), exit_status != 0)
                self.assertFalse((root / "evidence").exists())
                if exit_status:
                    self.assertIn("not qualification", process.stderr)
                    self.assertEqual(sample.read_text(), '{"run":1}\n')
                    self.assertEqual(collection.stat().st_mode & 0o777, 0o700)
                    self.assertEqual(sample.stat().st_mode & 0o777, 0o600)

    def test_recording_runner_delegates_to_canonical_resource_runner(self):
        wrapper = (
            REPOSITORY / "scripts" / "run-resource-recording-baseline.sh"
        ).read_text()

        self.assertIn(
            'exec "$ROOT/scripts/run-resource-baseline.sh" "$@"',
            wrapper,
        )
        self.assertNotIn("scripts/make-app.sh", wrapper)

    def evaluate_args(self, receipts, output):
        arguments = [
            "evaluate",
            "--version",
            self.version,
            "--build",
            self.build,
            "--commit",
            self.commit,
            "--output",
            str(output),
        ]
        for receipt in receipts:
            arguments += ["--receipt", str(receipt)]
        return arguments

    @staticmethod
    def read_scorecard(output):
        return json.loads((output / "resource-baseline.json").read_text())

    def machine_metadata(self, profile):
        return (
            {
                "profile": profile,
                "osVersion": "26.0",
                "osBuild": "25A5316i",
                "architecture": "arm64",
                "physicalMemoryBytes": self.profile_memory[profile],
                "hardwareModel": "Mac16,5",
            },
            {
                "xcodeVersion": "26.0",
                "xcodeBuild": "17A123",
                "swiftVersion": "6.2",
            },
        )

    def write_receipt(self, root, profile, suffix=None):
        path = root / f"{profile}{'-' + suffix if suffix else ''}.json"
        payload = {
            "schemaVersion": 4,
            "kind": "resource-baseline",
            "collectedAt": "2026-07-28T18:00:00Z",
            "build": {
                "version": self.version,
                "build": self.build,
                "commit": self.commit,
                "configuration": "release",
            },
            "host": {
                "profile": profile,
                "osVersion": "26.0",
                "osBuild": "25A5316i",
                "architecture": "arm64",
                "physicalMemoryBytes": self.profile_memory[profile],
                "hardwareModel": "Mac16,5",
            },
            "toolchain": {
                "xcodeVersion": "26.0",
                "xcodeBuild": "17A123",
                "swiftVersion": "6.2",
            },
            "recordingInput": {
                "generation": "public-synthetic-dual-channel-v2",
                "sampleRate": 16_000,
                "chunkFrames": 1_600,
            },
            "preparations": [{
                "id": "refine-runtime",
                "generation": "refine-runtime-preparation-v1",
                "state": "completed",
            }],
            "scenarios": [
                self.scenario(identifier, required)
                for identifier, required in self.required_scenarios()
            ],
            "askPipeline": {
                "state": "pass",
                "samples": [
                    self.ask_pipeline_sample(run)
                    for run in range(1, 4)
                ],
            },
        }
        path.write_text(json.dumps(payload))
        return path

    @staticmethod
    def write_preparation_marker(root):
        path = root / "refine-runtime-prepared"
        path.write_text(
            baseline.REQUIRED_PREPARATIONS["refine-runtime"]["marker"],
            encoding="utf-8",
        )
        path.chmod(0o600)
        return path

    def scenario(self, identifier, required):
        return {
            "id": identifier,
            "state": "pass",
            "samples": [
                self.sample(run, required)
                for run in range(1, 4)
            ],
        }

    @staticmethod
    def sample(run, required):
        workload_summaries = []
        for descriptor in required:
            workload_summaries.append(
                {
                    **descriptor,
                    "outcome": "completed",
                    "count": 2,
                    "durationMilliseconds": {
                        "p50": 10.0,
                        "p95": 20.0,
                        "maximum": 25.0,
                    },
                }
            )
        return {
            "run": run,
            "wallDurationMilliseconds": 1000.0 + run * 10,
            "cpuTimeMilliseconds": 500.0 + run,
            "peakPhysicalFootprintBytes": 512 * 1024**2 + run,
            "energyNanojoules": 1_000_000 + run,
            "diskReadBytes": 2_000 + run,
            "diskWrittenBytes": 3_000 + run,
            "minimumAvailableDiskBytes": 40 * 1024**3 - run,
            "maximumThermalState": "nominal",
            "powerSource": "ac",
            "lowPowerModeEnabled": False,
            "workloads": workload_summaries,
        }

    @staticmethod
    def ask_pipeline_sample(run):
        return {
            "schemaVersion": 2,
            "run": run,
            "operation": "answer",
            "outcome": "completed",
            "total": {
                "wallDurationMilliseconds": 1000.0 + run * 10,
                "cpuTimeMilliseconds": 500.0 + run * 5,
            },
            "firstEvidence": {
                "wallDurationMilliseconds": 600.0 + run * 5,
                "cpuTimeMilliseconds": 300.0 + run * 3,
            },
            "firstToken": {
                "wallDurationMilliseconds": 950.0 + run * 8,
                "cpuTimeMilliseconds": 475.0 + run * 4,
            },
            "stages": [
                {
                    "stage": stage,
                    "outcome": "completed",
                    "wallDurationMilliseconds": 100.0 + run,
                    "cpuTimeMilliseconds": 50.0 + run,
                }
                for stage in sorted(baseline.ASK_PIPELINE_STAGES)
            ],
            "corpus": {
                "generation": "ask-resource-v2",
                "checksum": "c" * 64,
                "fixtureSegmentCount": 10,
                "pendingAtSeed": 10,
                "pendingBefore": 0,
                "pendingAfter": 0,
                "readyBefore": True,
                "readyAfter": True,
                "warmup": "preindexed",
            },
            "citations": {
                "count": 3,
                "digest": "d" * 64,
                "valid": True,
            },
        }

    @staticmethod
    def required_scenarios():
        contract = json.loads(baseline.DEFAULT_CONTRACT.read_text())
        return [
            (scenario["id"], scenario["requiredWorkloads"])
            for scenario in contract["scenarios"]
        ]


if __name__ == "__main__":
    unittest.main()
