import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
COLLECTOR = REPOSITORY / "scripts" / "collect-field-evidence.py"


class CollectFieldEvidenceTests(unittest.TestCase):
    def test_packages_valid_report_without_source_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = self.write_report(root)
            app = self.write_app(root)
            output = root / "evidence"
            result = self.run_collector(
                report,
                app,
                output,
                "--check",
                "recording-started-before-ready=pass",
                "--check",
                "captions-attached-without-restart=pass",
                "--check",
                "pre-attach-audio-recovered=pass",
                "--check",
                "failure-state-visible=pass",
                "--elapsed-seconds",
                "12.5",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(manifest["outcome"], "pass")
            self.assertEqual(manifest["app"], {"version": "0.7.0", "build": "700"})
            self.assertEqual(manifest["elapsedSeconds"], 12.5)
            self.assertNotIn(str(report), json.dumps(manifest))
            self.assertNotIn(str(app), json.dumps(manifest))
            self.assertEqual(
                json.loads((output / "support-diagnostics.json").read_text()),
                self.valid_report(),
            )
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o700)
            self.assertEqual(os.stat(output / "manifest.json").st_mode & 0o777, 0o600)

    def test_rejects_unknown_content_bearing_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = self.valid_report()
            payload["meetings"][0]["title"] = "SECRET meeting title"
            report = self.write_report(root, payload)
            result = self.run_collector(report, self.write_app(root), root / "evidence")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("forbidden keys: title", result.stderr)
            self.assertFalse((root / "evidence").exists())

    def test_rejects_wrong_support_format(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = self.valid_report()
            payload["formatVersion"] = 1
            result = self.run_collector(
                self.write_report(root, payload),
                self.write_app(root),
                root / "evidence",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("formatVersion must be 2", result.stderr)

    def test_rejects_natural_language_in_identifier_field(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = self.valid_report()
            payload["environment"]["models"][0]["capability"] = "SECRET spoken words"
            result = self.run_collector(
                self.write_report(root, payload),
                self.write_app(root),
                root / "evidence",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("capability has an unsafe value", result.stderr)

    def test_refuses_the_installed_release_app_before_reading_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_collector(
                self.write_report(root),
                Path("/Applications/Portavoz.app"),
                root / "evidence",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("refusing to inspect /Applications/Portavoz.app", result.stderr)

    def test_rejects_check_from_another_scenario(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_collector(
                self.write_report(root),
                self.write_app(root),
                root / "evidence",
                "--check",
                "warning-cleared=pass",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unknown check for cold-live-captions", result.stderr)

    def run_collector(self, report, app, output, *extra):
        return subprocess.run(
            [
                "python3",
                str(COLLECTOR),
                "--scenario",
                "cold-live-captions",
                "--report",
                str(report),
                "--output",
                str(output),
                "--app",
                str(app),
                *extra,
            ],
            capture_output=True,
            check=False,
            text=True,
        )

    @staticmethod
    def write_app(root):
        app = root / "Portavoz Dev.app"
        info = app / "Contents" / "Info.plist"
        info.parent.mkdir(parents=True, exist_ok=True)
        with info.open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "app.portavoz.mac",
                    "CFBundleShortVersionString": "0.7.0",
                    "CFBundleVersion": "700",
                },
                handle,
            )
        return app

    def write_report(self, root, payload=None):
        report = root / "portavoz-support.json"
        report.write_text(json.dumps(payload or self.valid_report()), encoding="utf-8")
        return report

    @staticmethod
    def valid_report():
        return {
            "formatVersion": 2,
            "generatedAt": "2026-07-21T12:00:00Z",
            "environment": {
                "appVersion": "0.7.0",
                "buildVersion": "700",
                "operatingSystem": "Version 26.0 (Build 25A123)",
                "models": [{"capability": "live-transcription", "state": "installed"}],
            },
            "storage": {
                "schemaVersion": 14,
                "privacyTrackingStartedAt": "2026-07-01T12:00:00Z",
                "meetingCount": 1,
            },
            "meetings": [
                {
                    "reference": "meeting-0123456789ab",
                    "lifecycleState": "needsAttention",
                    "transcriptRevision": 1,
                    "lastProcessingError": "processing.transcription.failed",
                    "audioAssets": [
                        {
                            "channel": "microphone",
                            "role": "local",
                            "container": "caf",
                            "codec": "lpcm",
                            "sampleRate": 48000,
                            "channelCount": 1,
                            "durationSeconds": 120,
                            "byteCount": 1000,
                            "healthStatus": "healthy",
                            "peakDBFS": -1.2,
                            "rmsDBFS": -22.0,
                        }
                    ],
                    "transcript": {
                        "segmentCount": 2,
                        "microphoneSegmentCount": 1,
                        "systemSegmentCount": 1,
                        "attributedSegmentCount": 2,
                    },
                    "processingJobs": [
                        {
                            "kind": "initial-transcription",
                            "inputFingerprintDigest": "a" * 64,
                            "state": "succeeded",
                            "progress": 1,
                            "attempt": 1,
                            "maxAttempts": 3,
                            "createdAt": "2026-07-21T12:00:00Z",
                            "updatedAt": "2026-07-21T12:01:00Z",
                        }
                    ],
                    "generationRuns": [
                        {
                            "kind": "summary",
                            "providerID": "foundation-models",
                            "modelID": "local-model",
                            "modelRevision": "1",
                            "inputFingerprintDigest": "b" * 64,
                            "outputLanguage": "en",
                            "startedAt": "2026-07-21T12:01:00Z",
                            "finishedAt": "2026-07-21T12:01:01Z",
                            "outcome": "succeeded",
                        }
                    ],
                    "privacyReceipt": {
                        "status": "all-content-stayed-on-device",
                        "coverage": "complete",
                        "syncDisclosure": "no-cloud-copy-recorded",
                        "trackingStartedAt": "2026-07-01T12:00:00Z",
                        "events": [
                            {
                                "operation": "summary-generation",
                                "destinationScope": "remote",
                                "destinationHost": "api.example.com",
                                "dataClassification": "meeting-summary-material",
                                "consentSource": "summary-engine-settings",
                                "providerID": "api.example.com",
                                "modelID": "support-model",
                                "attemptedAt": "2026-07-21T12:01:00Z",
                            }
                        ],
                    },
                }
            ],
        }


if __name__ == "__main__":
    unittest.main()
