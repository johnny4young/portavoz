"""Content-free, bounded observational evidence is never resource authority."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import resource_host_observation as observation  # noqa: E402


class Clock:
    def __init__(self):
        self.instant = 0.0
        self.stopped = False

    def now(self):
        return self.instant

    def wait(self, seconds):
        self.instant += seconds

    def is_set(self):
        return self.stopped


class ResourceHostObservationTests(unittest.TestCase):
    def test_snapshot_retains_only_closed_classes_and_numeric_counts(self):
        raw = "30.0 /private/user/secret/node\n10.0 /secret/portavoz-app\n0.5 private-document\n"
        with mock.patch.object(observation.subprocess, "run") as run:
            run.return_value.stdout = raw
            result = observation.snapshot()
        self.assertEqual(result["contributors"], {"javascript-runtime": 30.0})
        self.assertEqual(result["activePortavozAppCount"], 1)
        self.assertEqual(result["totalCPUPercent"], 40.5)
        encoded = json.dumps(result)
        for content in ("secret", "private", "node", "document"):
            self.assertNotIn(content, encoded)
        self.assertEqual(run.call_args.kwargs["timeout"], 2)
        self.assertNotIn("args=", " ".join(run.call_args.args[0]))

    def test_finite_window_has_bounded_samples_and_no_qualification_authority(self):
        clock = Clock()
        receipt = observation.observe(6, clock, read=lambda: {"totalCPUPercent": 1}, now=clock.now)
        self.assertEqual(len(receipt["samples"]), 3)
        self.assertEqual(receipt["elapsedMilliseconds"], 6_000)
        self.assertEqual(receipt["outcome"], "window-ended")
        self.assertFalse(receipt["qualificationAuthority"])
        self.assertFalse(receipt["phaseAttributionAvailable"])
        self.assertEqual(receipt["sampleErrors"], 0)

    def test_missing_ps_and_cancellation_or_parent_loss_remain_adverse(self):
        clock = Clock()
        with mock.patch.object(observation, "snapshot", side_effect=OSError("private")) as read:
            receipt = observation.observe(4, clock, read=read, now=clock.now)
        self.assertEqual(receipt["sampleErrors"], 2)
        self.assertEqual(receipt["samples"], [])
        self.assertNotIn("private", json.dumps(receipt))
        clock.stopped = True
        self.assertEqual(observation.observe(4, clock, now=clock.now)["outcome"], "interrupted")
        clock.stopped = False
        self.assertEqual(observation.observe(
            4, clock, now=clock.now, parent_alive=lambda: False)["outcome"], "parent-lost")

    def test_duration_and_stalled_clock_cannot_create_unbounded_sampling(self):
        for value in (True, 1, 901, float("inf"), 4.0):
            with self.assertRaises(ValueError):
                observation.observe(value, Clock())
        clock = Clock()
        clock.wait = lambda _: None
        receipt = observation.observe(4, clock, read=lambda: {}, now=clock.now)
        self.assertEqual(len(receipt["samples"]), 2)
        self.assertEqual(receipt["outcome"], "incomplete-window")

    def test_atomic_write_never_overwrites_existing_evidence(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "host.json"
            observation.write({"valid": True}, path)
            original = path.read_bytes()
            with self.assertRaises(FileExistsError):
                observation.write({"valid": False}, path)
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(root.iterdir()), [path])
            with self.assertRaises(ValueError):
                observation.write({}, Path("relative.json"))

    def test_cli_refuses_invalid_duration_without_creating_output(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "host.json"
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/resource_host_observation.py"),
                 "--duration", "901", "--output", str(path)],
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(result.returncode, 64)
            self.assertFalse(path.exists())
            self.assertNotIn(temp, result.stderr)

    def test_resource_collection_requires_sidecars_for_each_recording_family(self):
        source = (ROOT / "scripts/run-resource-baseline.sh").read_text()
        self.assertEqual(source.count("--bench-resource-live-work"), 3)
        for name in ("recording", "recording-plus-indexing", "recording-plus-batch"):
            self.assertIn(f'$fragments/{name}-live-work-$run.json', source)
        self.assertNotIn("--host-observation", source)


if __name__ == "__main__":
    unittest.main()
