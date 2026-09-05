import copy
import importlib.util
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "long_capture_evidence.py"
SPEC = importlib.util.spec_from_file_location("long_capture_evidence", SCRIPT)
evidence = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(evidence)


class LongCaptureEvidenceTests(unittest.TestCase):
    commit = "a" * 40
    expected_frames = 10_800 * 16_000

    def test_exact_canonical_report_passes(self):
        evidence.validate_report(self.report(), self.commit)

    def test_unknown_or_content_bearing_fields_fail_closed(self):
        report = self.report()
        report["meetingTitle"] = "private meeting"
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_report(report, self.commit)

        report = self.report()
        report["channels"][0]["path"] = "/Users/person/meeting.caf"
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_report(report, self.commit)

    def test_source_identity_and_release_build_are_mandatory(self):
        report = self.report()
        report["sourceCommit"] = "b" * 40
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_report(report, self.commit)

        report = self.report()
        report["buildConfiguration"] = "debug"
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_report(report, self.commit)

    def test_every_channel_must_conserve_exact_frames_and_order(self):
        report = self.report()
        report["channels"][1]["acceptedFrames"] -= 1
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_report(report, self.commit)

        report = self.report()
        report["channels"].reverse()
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_report(report, self.commit)

    def test_nonfinite_and_inconsistent_footprints_fail_closed(self):
        report = self.report()
        report["result"]["stopWallDurationMilliseconds"] = float("nan")
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_report(report, self.commit)

        report = self.report()
        report["result"]["peakHeapBytesInUse"] = 120_000_000
        report["result"]["incrementalPeakHeapBytesInUse"] = 20_000_000
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_report(report, self.commit)

        report = self.report()
        report["result"]["incrementalPeakHeapBytesInUse"] = 1
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_report(report, self.commit)

        report = self.report()
        report["result"]["endingHeapBytesInUse"] = 110_000_001
        with self.assertRaises(evidence.EvidenceError):
            evidence.validate_report(report, self.commit)

    def report(self):
        channel = {
            "id": "microphone",
            "expectedFrames": self.expected_frames,
            "acceptedFrames": self.expected_frames,
            "publishedFrames": self.expected_frames,
            "durationSeconds": 10_800,
            "byteCount": self.expected_frames * 2 + 4_096,
            "healthStatus": "healthy",
        }
        system = copy.deepcopy(channel)
        system["id"] = "system"
        baseline = 100_000_000
        peak = 110_000_000
        return {
            "schemaVersion": 1,
            "generatedAt": "2026-07-31T18:00:00Z",
            "buildConfiguration": "release",
            "sourceCommit": self.commit,
            "contentSource": "synthetic-only",
            "host": {
                "operatingSystem": "macOS 26.5",
                "architecture": "arm64",
                "physicalMemoryBytes": 16 * 1024**3,
            },
            "configuration": {
                "requestedDurationSeconds": 10_800,
                "sampleRate": 16_000,
                "chunkFrames": 4_800,
                "expectedFramesPerChannel": self.expected_frames,
                "logicalChunksPerChannel": 36_000,
                "canonicalThreeHourRun": True,
            },
            "channels": [channel, system],
            "result": {
                "passed": True,
                "driftFrames": 0,
                "captureWallDurationMilliseconds": 20_000.0,
                "stopWallDurationMilliseconds": 3_000.0,
                "baselineHeapBytesInUse": baseline,
                "peakHeapBytesInUse": peak,
                "incrementalPeakHeapBytesInUse": peak - baseline,
                "maximumIncrementalHeapBytesInUse": 16 * 1024**2,
                "endingHeapBytesInUse": 105_000_000,
            },
        }


if __name__ == "__main__":
    unittest.main()
