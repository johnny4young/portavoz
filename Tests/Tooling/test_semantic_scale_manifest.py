import copy
import importlib.util
import json
import math
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "semantic_scale_manifest.py"
RUNNER = ROOT / "scripts" / "run-semantic-scale-baseline.sh"
PERF_RUNNER = ROOT / "scripts" / "run-perf-ledger.sh"
SWIFT_PROBE = ROOT / "Sources" / "portavoz-cli" / "CLIBenchSemantic.swift"
SPEC = importlib.util.spec_from_file_location("semantic_scale_manifest", SCRIPT)
manifest = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = manifest
SPEC.loader.exec_module(manifest)


def millisecond_distribution(count, value):
    return {
        "sampleCount": count,
        "p50Milliseconds": value,
        "p95Milliseconds": value + 0.1,
        "maximumMilliseconds": value + 0.2,
    }


def byte_distribution(count, value):
    return {
        "sampleCount": count,
        "p50Bytes": value,
        "p95Bytes": value + 1,
        "maximumBytes": value + 2,
    }


def stage(count, value):
    return {
        "wallTime": millisecond_distribution(count, value),
        "processCPUTime": millisecond_distribution(count, value + 0.5),
    }


def checkpoint_report(scale, *, runs=20, variants=1, wall=10.0):
    configuration = {
        "measurementRuns": runs,
        "warmupRuns": 2,
        "embeddingDimension": 512,
        "resultLimit": 12,
        "segmentsPerMeeting": 200,
        "queryVariants": variants,
    }
    seed = stage(1, 100.0)
    measured = stage(runs, wall)
    report = {
        "schemaVersion": 2,
        "generatedAt": "2026-08-13T08:00:00Z",
        "buildConfiguration": "release",
        "host": {
            "operatingSystem": "Version 26.5.2 (Build 25F84)",
            "architecture": "arm64",
            "processorCount": 14,
            "physicalMemoryBytes": 38_654_705_664,
        },
        "configuration": configuration,
        "semanticProfile": {
            "modelIdentifier": "apple-latin-v1",
            "modelRevision": 1,
            "vectorDimension": 512,
            "pipelineIdentifier": "token-mean-pooling-l2",
            "pipelineRevision": 1,
            "vectorSchemaVersion": 1,
            "fingerprint": "",
        },
        "semanticAssets": {
            "provider": "apple-natural-language",
            "script": "latin",
            "availability": "installed",
            "downloadPolicy": "never",
            "usedByMeasuredVectors": False,
        },
        "fixture": {
            "version": "semantic-scale-synthetic-v1",
            "contentSource": "synthetic-only",
            "userLibraryAccess": "none",
            "vectorGenerator": "lcg-normalized-float32-v1",
            "transcriptGenerator": "ordinal-placeholder-v1",
            "ephemeralIdentityPolicy": "excluded-from-comparison-v1",
        },
        "queryPack": {
            "version": "semantic-present-vector-queries-v1",
            "selectionPolicy": "midpoint-consecutive-wrap-v1",
            "firstQueryIndex": scale // 2,
        },
        "checkpoint": {
            "totalSegments": scale,
            "meetingCount": math.ceil(scale / 200),
            "seedMilliseconds": 100.0,
            "databaseBytes": scale * 4_400,
            "rawEmbeddingBytes": scale * 512 * 4,
            "resultCount": min(scale, 12),
            "stageTimings": {
                "storeOpen": stage(1, 2.0),
                "corpusSeed": seed,
                "warmupQueries": stage(2, 5.0),
                "measuredQueries": measured,
            },
            "wallTime": measured["wallTime"],
            "processCPUTime": measured["processCPUTime"],
            "baselinePhysicalFootprint": byte_distribution(runs, 8_000_000),
            "peakPhysicalFootprint": byte_distribution(runs, 16_000_000),
            "incrementalPeakPhysicalFootprint": byte_distribution(runs, 8_000_000),
            "endingPhysicalFootprint": byte_distribution(runs, 9_000_000),
        },
    }
    report["semanticProfile"]["fingerprint"] = manifest.semantic_profile_fingerprint(
        report["semanticProfile"]
    )
    return report


def identity_snapshot(*, clean=True, binary="b" * 64):
    return {
        "schemaVersion": 1,
        "source": {
            "commit": "c" * 40,
            "worktreeClean": clean,
            "worktreeStateSHA256": manifest.EMPTY_SHA256 if clean else "d" * 64,
        },
        "binary": {"sha256": binary, "sizeBytes": 80_000_000},
        "toolchain": {
            "swift": "6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)",
            "target": "arm64-apple-macosx26.0",
            "xcode": "Xcode 26.6",
            "xcodeBuild": "17F113",
        },
        "host": {
            "operatingSystem": "Version 26.5.2 (Build 25F84)",
            "operatingSystemBuild": "25F84",
            "architecture": "arm64",
            "hardwareModel": "Mac16,6",
            "processorCount": 14,
            "physicalMemoryBytes": 38_654_705_664,
        },
        "releaseBuild": {"wallMilliseconds": 1_000.0},
    }


def canonical_manifest(*, clean=True, binary="b" * 64, wall=10.0):
    reports = [
        checkpoint_report(scale, wall=wall + index)
        for index, scale in enumerate(manifest.CANONICAL_SCALES)
    ]
    return manifest.assemble_manifest(
        identity_snapshot(clean=clean, binary=binary),
        reports,
        "2026-08-13T08:00:00Z",
    )


class SemanticScaleManifestTests(unittest.TestCase):
    def test_canonical_manifest_binds_every_comparability_surface(self):
        document = canonical_manifest()

        self.assertEqual(document["schemaVersion"], 2)
        self.assertEqual(document["kind"], "semantic-scale-run-manifest")
        self.assertEqual(
            [item["totalSegments"] for item in document["checkpoints"]],
            [1_000, 10_000, 50_000, 100_000],
        )
        self.assertEqual(document["comparability"]["measurementScope"], "canonical")
        self.assertTrue(document["comparability"]["retentionEligible"])
        self.assertRegex(document["comparability"]["identitySHA256"], r"^[0-9a-f]{64}$")
        self.assertEqual(document, manifest.validate_manifest(document, "manifest"))

    def test_custom_dirty_run_is_explicitly_diagnostic(self):
        document = manifest.assemble_manifest(
            identity_snapshot(clean=False),
            [checkpoint_report(1_000, runs=3)],
            "2026-08-13T08:00:00Z",
        )

        self.assertEqual(document["comparability"]["measurementScope"], "custom")
        self.assertFalse(document["comparability"]["retentionEligible"])
        self.assertEqual(
            document["comparability"]["reasons"],
            ["noncanonical-scales", "noncanonical-configuration", "dirty-worktree"],
        )

    def test_checkpoint_identity_must_remain_exact_across_processes(self):
        reports = [checkpoint_report(1_000), checkpoint_report(10_000)]
        for key, replacement in (
            ("host", {**reports[1]["host"], "processorCount": 12}),
            (
                "semanticProfile",
                {**reports[1]["semanticProfile"], "modelRevision": 2},
            ),
            (
                "semanticAssets",
                {**reports[1]["semanticAssets"], "availability": "missing"},
            ),
        ):
            with self.subTest(key=key):
                changed = copy.deepcopy(reports)
                changed[1][key] = replacement
                if key == "semanticProfile":
                    changed[1][key]["fingerprint"] = (
                        manifest.semantic_profile_fingerprint(changed[1][key])
                    )
                with self.assertRaisesRegex(manifest.ManifestError, f"changed {key}"):
                    manifest.assemble_manifest(
                        identity_snapshot(), changed, "2026-08-13T08:00:00Z"
                    )

    def test_checkpoint_must_match_wrapper_host(self):
        report = checkpoint_report(1_000)
        snapshot = identity_snapshot()
        snapshot["host"]["hardwareModel"] = "Mac16,5"
        snapshot["host"]["processorCount"] = 12

        with self.assertRaisesRegex(manifest.ManifestError, "host disagrees"):
            manifest.assemble_manifest(
                snapshot, [report], "2026-08-13T08:00:00Z"
            )

    def test_query_top_k_and_raw_bytes_are_fail_closed(self):
        for key, value, message in (
            ("resultCount", 11, "resultCount"),
            ("rawEmbeddingBytes", 10, "rawEmbeddingBytes"),
        ):
            with self.subTest(key=key):
                report = checkpoint_report(1_000)
                report["checkpoint"][key] = value
                with self.assertRaisesRegex(manifest.ManifestError, message):
                    manifest.validate_report(report, "report")

        for key in ("meetingCount", "resultCount"):
            with self.subTest(key=key, value="boolean"):
                report = checkpoint_report(1)
                report["checkpoint"][key] = True
                with self.assertRaisesRegex(manifest.ManifestError, "integer"):
                    manifest.validate_report(report, "report")

    def test_query_index_and_profile_dimension_are_fail_closed(self):
        report = checkpoint_report(1_000)
        report["queryPack"]["firstQueryIndex"] = 9
        with self.assertRaisesRegex(manifest.ManifestError, "firstQueryIndex"):
            manifest.validate_report(report, "report")

        report = checkpoint_report(1_000)
        report["semanticProfile"]["vectorDimension"] = 384
        report["semanticProfile"]["fingerprint"] = (
            manifest.semantic_profile_fingerprint(report["semanticProfile"])
        )
        with self.assertRaisesRegex(manifest.ManifestError, "dimensions differ"):
            manifest.validate_report(report, "report")

        report = checkpoint_report(1_000)
        report["semanticProfile"]["fingerprint"] = "f" * 64
        with self.assertRaisesRegex(manifest.ManifestError, "fingerprint is inconsistent"):
            manifest.validate_report(report, "report")

    def test_distributions_reject_wrong_count_nonfinite_and_nonmonotonic_values(self):
        cases = (
            ({**millisecond_distribution(20, 1), "sampleCount": True}, "integer"),
            ({**millisecond_distribution(20, 1), "p95Milliseconds": math.inf}, "finite"),
            (
                {
                    **millisecond_distribution(20, 1),
                    "p50Milliseconds": 5,
                    "p95Milliseconds": 4,
                },
                "monotonic",
            ),
        )
        for distribution, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(manifest.ManifestError, message):
                    manifest.validate_distribution(
                        distribution, "timing", expected_count=20
                    )

    def test_measured_stage_must_equal_legacy_query_distributions(self):
        report = checkpoint_report(1_000)
        report["checkpoint"]["stageTimings"]["measuredQueries"]["wallTime"] = (
            millisecond_distribution(20, 99)
        )

        with self.assertRaisesRegex(manifest.ManifestError, "disagrees"):
            manifest.validate_report(report, "report")

    def test_schema_rejects_extra_fields_and_duplicate_scales(self):
        report = checkpoint_report(1_000)
        report["question"] = "forbidden payload"
        with self.assertRaisesRegex(manifest.ManifestError, "forbidden question"):
            manifest.validate_report(report, "report")

        report = checkpoint_report(1_000)
        report["schemaVersion"] = 2.0
        with self.assertRaisesRegex(manifest.ManifestError, "integer"):
            manifest.validate_report(report, "report")

        reports = [checkpoint_report(1_000), checkpoint_report(1_000)]
        with self.assertRaisesRegex(manifest.ManifestError, "repeated"):
            manifest.assemble_manifest(
                identity_snapshot(), reports, "2026-08-13T08:00:00Z"
            )

    def test_assets_disclose_no_download_and_synthetic_vector_boundary(self):
        report = checkpoint_report(1_000)
        report["semanticAssets"]["downloadPolicy"] = "if-needed"
        with self.assertRaisesRegex(manifest.ManifestError, "must be never"):
            manifest.validate_report(report, "report")

        report = checkpoint_report(1_000)
        report["semanticAssets"]["usedByMeasuredVectors"] = True
        with self.assertRaisesRegex(manifest.ManifestError, "synthetic"):
            manifest.validate_report(report, "report")

    def test_same_identity_manifests_are_comparable_without_declaring_a_winner(self):
        first = canonical_manifest(wall=60)
        second = canonical_manifest(wall=62)
        comparison = manifest.compare_documents(
            [first, second], "2026-08-13T08:00:00Z"
        )

        self.assertEqual(comparison["outcome"], "comparable-retainable")
        self.assertEqual(comparison["decisionAuthority"], "none")
        self.assertEqual(comparison["reasons"], [])
        self.assertEqual(comparison["p95AcrossObservations"]["sampleCount"], 2)
        self.assertNotIn("winner", json.dumps(comparison).lower())

    def test_dirty_identical_manifests_are_development_comparable_only(self):
        first = canonical_manifest(clean=False, wall=60)
        second = canonical_manifest(clean=False, wall=61)
        comparison = manifest.compare_documents(
            [first, second], "2026-08-13T08:00:00Z"
        )

        self.assertEqual(comparison["outcome"], "comparable-development")
        self.assertEqual(comparison["reasons"], ["dirty-worktree"])

    def test_binary_or_host_identity_mismatch_blocks_comparison(self):
        first = canonical_manifest(binary="a" * 64)
        second = canonical_manifest(binary="b" * 64)

        comparison = manifest.compare_documents(
            [first, second], "2026-08-13T08:00:00Z"
        )

        self.assertEqual(comparison["outcome"], "not-comparable")
        self.assertEqual(comparison["reasons"], ["comparability-identity-mismatch"])
        self.assertIsNone(comparison["p95AcrossObservations"])

    def test_same_identity_but_different_measured_scale_blocks_comparison(self):
        first = manifest.assemble_manifest(
            identity_snapshot(),
            [checkpoint_report(1_000, runs=3)],
            "2026-08-13T08:00:00Z",
        )
        second = manifest.assemble_manifest(
            identity_snapshot(),
            [checkpoint_report(10_000, runs=3)],
            "2026-08-13T08:00:00Z",
        )
        # Scale belongs to the identity, so current manifests differ before the
        # explicit scale check can ever be reached.
        comparison = manifest.compare_documents(
            [first, second], "2026-08-13T08:00:00Z"
        )
        self.assertEqual(comparison["outcome"], "not-comparable")
        self.assertIn("comparability-identity-mismatch", comparison["reasons"])

    def test_historical_90_and_92_ms_reports_are_explicitly_not_comparable(self):
        documents = [
            manifest.read_json(
                ROOT / "docs/evidence/semantic-scale-after-adapter-20260717.json",
                "90 ms history",
            ),
            manifest.read_json(
                ROOT / "docs/evidence/semantic-scale-20260726.json",
                "92 ms history",
            ),
        ]
        comparison = manifest.compare_documents(
            documents, "2026-08-13T08:00:00Z"
        )

        self.assertEqual(comparison["outcome"], "not-comparable")
        self.assertEqual(
            comparison["reasons"], ["legacy-schema-lacks-comparability-identity"]
        )
        self.assertAlmostEqual(
            comparison["observations"][0]["wallP95Milliseconds"], 90.218417
        )
        self.assertAlmostEqual(
            comparison["observations"][1]["wallP95Milliseconds"], 92.849542
        )
        self.assertIn("toolchain", comparison["observations"][0]["missingComparabilityFields"])
        self.assertNotIn("toolchain", comparison["observations"][1]["missingComparabilityFields"])

    def test_tracked_historical_reconciliation_is_exactly_recomputable(self):
        documents = [
            manifest.read_json(
                ROOT / "docs/evidence/semantic-scale-after-adapter-20260717.json",
                "90 ms history",
            ),
            manifest.read_json(
                ROOT / "docs/evidence/semantic-scale-20260726.json",
                "92 ms history",
            ),
        ]
        tracked = manifest.read_json(
            ROOT / "docs/evidence/semantic-scale-history-reconciliation-20260813.json",
            "tracked reconciliation",
        )

        self.assertEqual(
            tracked,
            manifest.compare_documents(documents, tracked["generatedAt"]),
        )

    def test_malformed_legacy_report_does_not_produce_a_scorecard(self):
        with self.assertRaisesRegex(manifest.ManifestError, "unique 100k"):
            manifest.compare_documents(
                [{"schemaVersion": 1, "host": {}, "configuration": {}, "checkpoints": []}] * 2,
                "2026-08-13T08:00:00Z",
            )

    def test_json_reader_rejects_duplicate_keys_and_nonfinite_constants(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.json"
            for payload, message in (
                ('{"schemaVersion": 2, "schemaVersion": 2}', "duplicate"),
                ('{"value": NaN}', "non-finite"),
            ):
                with self.subTest(message=message):
                    path.write_text(payload, encoding="utf-8")
                    with self.assertRaisesRegex(manifest.ManifestError, message):
                        manifest.read_json(path, "input")

    def test_snapshot_rejects_python_bool_and_inconsistent_os_build(self):
        snapshot = identity_snapshot()
        snapshot["binary"]["sizeBytes"] = True
        with self.assertRaisesRegex(manifest.ManifestError, "integer"):
            manifest.validate_snapshot(snapshot, "snapshot")

        snapshot = identity_snapshot()
        snapshot["host"]["operatingSystemBuild"] = "25F85"
        with self.assertRaisesRegex(manifest.ManifestError, "inconsistent"):
            manifest.validate_snapshot(snapshot, "snapshot")

        snapshot = identity_snapshot()
        snapshot["schemaVersion"] = True
        with self.assertRaisesRegex(manifest.ManifestError, "integer"):
            manifest.validate_snapshot(snapshot, "snapshot")

    def test_source_digest_binds_tracked_and_untracked_file_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*arguments):
                return subprocess.run(
                    ["/usr/bin/git", *arguments],
                    cwd=root,
                    check=True,
                    capture_output=True,
                    env={
                        **os.environ,
                        "GIT_AUTHOR_NAME": "Portavoz Tests",
                        "GIT_AUTHOR_EMAIL": "tests@portavoz.local",
                        "GIT_COMMITTER_NAME": "Portavoz Tests",
                        "GIT_COMMITTER_EMAIL": "tests@portavoz.local",
                    },
                )

            git("init", "-q")
            tracked = root / "tracked.txt"
            tracked.write_text("baseline\n", encoding="utf-8")
            git("add", "tracked.txt")
            git("-c", "commit.gpgsign=false", "commit", "-qm", "baseline")
            clean = manifest.collect_source(root)
            self.assertTrue(clean["worktreeClean"])
            self.assertEqual(clean["worktreeStateSHA256"], manifest.EMPTY_SHA256)

            tracked.write_text("first tracked contents\n", encoding="utf-8")
            first_tracked = manifest.collect_source(root)
            tracked.write_text("second tracked contents\n", encoding="utf-8")
            second_tracked = manifest.collect_source(root)
            self.assertNotEqual(
                first_tracked["worktreeStateSHA256"],
                second_tracked["worktreeStateSHA256"],
            )

            git("checkout", "--", "tracked.txt")
            untracked = root / "untracked.txt"
            untracked.write_text("first untracked contents\n", encoding="utf-8")
            first_untracked = manifest.collect_source(root)
            untracked.write_text("second untracked contents\n", encoding="utf-8")
            second_untracked = manifest.collect_source(root)
            self.assertNotEqual(
                first_untracked["worktreeStateSHA256"],
                second_untracked["worktreeStateSHA256"],
            )

    def test_atomic_output_is_owner_only_and_round_trips(self):
        document = canonical_manifest()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            manifest.write_json(path, document)

            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), document)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_runner_fences_source_before_build_and_after_collection(self):
        source = RUNNER.read_text(encoding="utf-8")

        before_build = source.index("semantic_scale_manifest.py source")
        build = source.index("swift build -c release --product portavoz-cli")
        snapshot = source.index("semantic_scale_manifest.py snapshot")
        measurement = source.index('"$ROOT/.build/release/portavoz-cli" bench-semantic')
        assemble = source.index("semantic_scale_manifest.py assemble")
        self.assertLess(before_build, build)
        self.assertLess(build, snapshot)
        self.assertLess(snapshot, measurement)
        self.assertLess(measurement, assemble)
        self.assertIn('--expected-source "$PARTS/source.snapshot"', source)
        self.assertIn('--snapshot "$PARTS/run.snapshot"', source)

        perf_source = PERF_RUNNER.read_text(encoding="utf-8")
        self.assertIn('payload.get("kind") == "semantic-scale-run-manifest"', perf_source)
        self.assertIn("semantic manifest toolchain changed", perf_source)

    def test_swift_probe_is_content_free_and_measures_all_stage_boundaries(self):
        source = SWIFT_PROBE.read_text(encoding="utf-8")

        self.assertIn("schemaVersion: 2", source)
        self.assertIn("semanticProfile: .init(input.profile)", source)
        self.assertIn('downloadPolicy: "never"', source)
        self.assertIn("usedByMeasuredVectors: false", source)
        self.assertIn("let stageTimings: StageTimings", source)
        for stage_name in (
            "storeOpen",
            "corpusSeed",
            "warmupQueries",
            "measuredQueries",
        ):
            self.assertIn(stage_name, source)
        self.assertNotIn("try await embedder.prepare", source)
        self.assertNotIn("questionText", source)
        self.assertNotIn("databasePath", source)
        self.assertGreaterEqual(source.count("sampler.cancel()"), 2)
        self.assertIn("_ = await sampler.value", source)


if __name__ == "__main__":
    unittest.main()
