import copy
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "meeting_memory_graph_query_receipt.py"
RUNNER = REPOSITORY / "scripts" / "run-meeting-memory-graph-query-receipt.sh"
SPEC = importlib.util.spec_from_file_location(
    "meeting_memory_graph_query_receipt", SCRIPT
)
receipt = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(receipt)


class MeetingMemoryGraphQueryReceiptTests(unittest.TestCase):
    def test_three_strict_fragments_form_content_free_exact_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = self.write_fragments(Path(directory))
            document = receipt.assemble(paths, "1.2.3", "456", "a" * 40)

        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["build"]["commit"], "a" * 40)
        self.assertEqual([run["run"] for run in document["runs"]], [1, 2, 3])
        self.assertEqual(
            [job["job"] for job in document["runs"][0]["jobs"]],
            receipt.JOBS,
        )
        encoded = json.dumps(document, sort_keys=True)
        for forbidden in (
            "meetingID",
            "segmentID",
            "trace",
            "transcript",
            "Ana",
            "Planning baseline",
            "databasePath",
            "rawError",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_requires_contiguous_runs_and_matching_host(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = self.write_fragments(root)
            changed_run = self.fragment(4)
            paths[2].write_text(json.dumps(changed_run))
            with self.assertRaisesRegex(receipt.GraphQueryReceiptError, "contiguous"):
                receipt.assemble(paths, "1.0", "2", "a" * 40)

            paths = self.write_fragments(root, prefix="host")
            changed_host = self.fragment(3)
            changed_host["host"]["hardwareModel"] = "Mac99,1"
            paths[2].write_text(json.dumps(changed_host))
            with self.assertRaisesRegex(receipt.GraphQueryReceiptError, "hosts"):
                receipt.assemble(paths, "1.0", "2", "a" * 40)

    def test_rejects_schema_drift_duplicates_and_nonfinite_values(self):
        fragment = self.fragment(1)
        fragment["meetingID"] = "private"
        with self.assertRaisesRegex(receipt.GraphQueryReceiptError, "schema"):
            receipt.validate_fragment(fragment, "extra")

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"schemaVersion":1,"schemaVersion":1}')
            with self.assertRaisesRegex(receipt.GraphQueryReceiptError, "duplicate"):
                receipt.read_fragment(path)

        fragment = self.fragment(1)
        fragment["jobs"][0]["wall"]["p95Milliseconds"] = float("inf")
        with self.assertRaisesRegex(receipt.GraphQueryReceiptError, "finite"):
            receipt.validate_fragment(fragment, "nonfinite")

    def test_rejects_missing_nonfactful_or_inconsistent_job_samples(self):
        missing = self.fragment(1)
        missing["jobs"].pop()
        with self.assertRaisesRegex(receipt.GraphQueryReceiptError, "job matrix"):
            receipt.validate_fragment(missing, "missing")

        failed = self.fragment(1)
        failed["jobs"][2]["outcome"] = "failed"
        with self.assertRaisesRegex(receipt.GraphQueryReceiptError, "factful"):
            receipt.validate_fragment(failed, "failed")

        inconsistent = self.fragment(1)
        inconsistent["jobs"][4]["sampleCount"] = 30
        with self.assertRaisesRegex(receipt.GraphQueryReceiptError, "inconsistent"):
            receipt.validate_fragment(inconsistent, "inconsistent")

    def test_rejects_unready_host_invalid_provenance_or_too_few_runs(self):
        fragment = self.fragment(1)
        fragment["host"]["powerSource"] = "battery"
        with self.assertRaisesRegex(receipt.GraphQueryReceiptError, "measurement-ready"):
            receipt.validate_fragment(fragment, "battery")
        with self.assertRaisesRegex(receipt.GraphQueryReceiptError, "three"):
            receipt.assemble([], "1.0", "2", "a" * 40)

        with tempfile.TemporaryDirectory() as directory:
            paths = self.write_fragments(Path(directory))
            with self.assertRaisesRegex(receipt.GraphQueryReceiptError, "commit"):
                receipt.assemble(paths, "1.0", "2", "A" * 40)
            with self.assertRaisesRegex(receipt.GraphQueryReceiptError, "version"):
                receipt.assemble(paths, "private", "2", "a" * 40)
            with self.assertRaisesRegex(receipt.GraphQueryReceiptError, "build"):
                receipt.assemble(paths, "1.2.3", "secret", "a" * 40)

    def test_private_writer_is_mode_0600_and_never_replaces(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "nested" / "receipt.json"
            receipt.write_private_json(output, {"schemaVersion": 1})
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(output.read_text()), {"schemaVersion": 1})
            with self.assertRaisesRegex(receipt.GraphQueryReceiptError, "exists"):
                receipt.write_private_json(output, {"schemaVersion": 2})
            self.assertEqual(json.loads(output.read_text()), {"schemaVersion": 1})

    def test_runner_rejects_invalid_arguments_and_ad_hoc_signing_before_build(self):
        help_result = subprocess.run(
            [RUNNER, "--help"], capture_output=True, text=True, check=False
        )
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("--iterations <5...1000>", help_result.stderr)

        cases = [
            ([], "--version is required"),
            (["--version", "1.0", "--build", "1", "--runs", "2"], "--runs"),
            (
                [
                    "--version",
                    "1.0",
                    "--build",
                    "1",
                    "--iterations",
                    "1001",
                ],
                "--iterations",
            ),
        ]
        for arguments, expected in cases:
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [RUNNER, *arguments],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 64)
                self.assertIn(expected, result.stderr)

        ad_hoc_environment = os.environ.copy()
        ad_hoc_environment["PORTAVOZ_SIGN_IDENTITY"] = "-"
        ad_hoc_result = subprocess.run(
            [RUNNER, "--version", "1.0", "--build", "1"],
            capture_output=True,
            text=True,
            check=False,
            env=ad_hoc_environment,
        )
        self.assertEqual(ad_hoc_result.returncode, 64)
        self.assertIn("real Developer ID identity", ad_hoc_result.stderr)

        make_result = subprocess.run(
            [
                "make",
                "-n",
                "meeting-memory-graph-query-receipt",
                "PORTAVOZ_GRAPH_QUERY_VERSION=1.0",
                "PORTAVOZ_GRAPH_QUERY_BUILD=1",
                "PORTAVOZ_SIGN_IDENTITY=TEST-SIGNING-IDENTITY",
            ],
            cwd=REPOSITORY,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(make_result.returncode, 0, make_result.stderr)
        self.assertIn(
            "PORTAVOZ_SIGN_IDENTITY=TEST-SIGNING-IDENTITY",
            make_result.stdout,
        )

    @staticmethod
    def fragment(run):
        summary = {
            "p50Milliseconds": 1.0,
            "p95Milliseconds": 2.0,
            "maximumMilliseconds": 3.0,
        }
        return {
            "schemaVersion": 1,
            "run": run,
            "fixtureGeneration": "public-synthetic-graph-product-v1",
            "iterationsPerJob": 31,
            "host": {
                "architecture": "arm64",
                "hardwareModel": "Mac16,6",
                "operatingSystem": "26.5.2",
                "operatingSystemBuild": "25F84",
                "physicalMemoryBytes": 36_000_000_000,
                "powerSource": "ac",
                "thermalState": "nominal",
                "lowPowerModeEnabled": False,
            },
            "jobs": [
                {
                    "job": job,
                    "outcome": "facts",
                    "sampleCount": 31,
                    "wall": copy.deepcopy(summary),
                    "cpu": copy.deepcopy(summary),
                }
                for job in receipt.JOBS
            ],
        }

    def write_fragments(self, root, prefix="run"):
        paths = []
        for run in range(1, 4):
            path = root / f"{prefix}-{run}.json"
            path.write_text(json.dumps(self.fragment(run)))
            paths.append(path)
        return paths


if __name__ == "__main__":
    unittest.main()
