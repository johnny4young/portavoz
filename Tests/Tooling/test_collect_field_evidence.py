import copy
import contextlib
import importlib.util
import io
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY = Path(__file__).resolve().parents[2]
COLLECTOR = REPOSITORY / "scripts" / "collect-field-evidence.py"
COLLECTOR_SPEC = importlib.util.spec_from_file_location(
    "collect_field_evidence",
    COLLECTOR,
)
assert COLLECTOR_SPEC is not None and COLLECTOR_SPEC.loader is not None
collector = importlib.util.module_from_spec(COLLECTOR_SPEC)
COLLECTOR_SPEC.loader.exec_module(collector)


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
            self.assertEqual(manifest["protocolVersion"], 1)
            self.assertEqual(manifest["outcome"], "pass")
            self.assertEqual(manifest["app"], {"version": "0.7.0", "build": "700"})
            self.assertEqual(
                manifest["macOS"],
                {"productVersion": "26.0", "buildVersion": "25A123"},
            )
            self.assertEqual(manifest["elapsedSeconds"], 12.5)
            self.assertNotIn(str(report), json.dumps(manifest))
            self.assertNotIn(str(app), json.dumps(manifest))
            self.assertEqual(
                json.loads((output / "support-diagnostics.json").read_text()),
                self.valid_report(),
            )
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o700)
            self.assertEqual(os.stat(output / "manifest.json").st_mode & 0o777, 0o600)

    def test_packages_canonical_mixed_language_fixture_before_and_after_refine(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            before_payload = self.valid_report()
            after_payload = copy.deepcopy(before_payload)
            after_payload["generatedAt"] = "2026-07-21T12:05:00Z"
            after_payload["meetings"][0]["transcriptRevision"] = 2
            before = self.write_report(root, before_payload, "before.json")
            after = self.write_report(root, after_payload, "after.json")
            output = root / "evidence"
            result = self.run_fixture(
                before,
                self.write_app(root),
                output,
                "mixed-language",
                "--after-refine-report",
                str(after),
                "--evidence",
                "recording.start.committed=pass",
                "--evidence",
                "recording.stop.durable=pass",
                "--evidence",
                "post-capture.admission.completed=pass",
                "--evidence",
                "translation.live.separated=pass",
                "--evidence",
                "refine.language.preserved=pass",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(manifest["protocolVersion"], 2)
            self.assertEqual(manifest["fixture"], "mixed-language")
            self.assertEqual(manifest["meetingReference"], "meeting-0123456789ab")
            self.assertEqual(manifest["outcome"], "pass")
            self.assertEqual(
                {item["id"]: item["subsystem"] for item in manifest["evidence"]},
                {
                    "recording.start.committed": "recording-start",
                    "recording.stop.durable": "stop-durability",
                    "post-capture.admission.completed": "post-capture-admission",
                    "translation.live.separated": "live-translation",
                    "refine.language.preserved": "refine",
                },
            )
            self.assertEqual(
                manifest["supportReports"]["beforeRefine"]["selectedMeeting"][
                    "transcriptRevision"
                ],
                1,
            )
            self.assertEqual(
                manifest["supportReports"]["afterRefine"]["selectedMeeting"][
                    "transcriptRevision"
                ],
                2,
            )
            self.assertTrue((output / "support-before-refine.json").is_file())
            self.assertTrue((output / "support-after-refine.json").is_file())
            self.assertFalse((output / "support-diagnostics.json").exists())

    def test_mixed_language_fixture_requires_after_refine_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_fixture(
                self.write_report(root),
                self.write_app(root),
                root / "evidence",
                "mixed-language",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("mixed-language requires --after-refine-report", result.stderr)

    def test_fixture_rejects_evidence_owned_by_another_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_fixture(
                self.write_report(root),
                self.write_app(root),
                root / "evidence",
                "built-in-speaker-mic",
                "--evidence",
                "refine.language.preserved=pass",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "unknown evidence for built-in-speaker-mic",
                result.stderr,
            )

    def test_fixture_rejects_refine_pass_without_newer_transcript_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            before = self.write_report(root, name="before.json")
            after = self.write_report(root, name="after.json")
            result = self.run_fixture(
                before,
                self.write_app(root),
                root / "evidence",
                "mixed-language",
                "--after-refine-report",
                str(after),
                "--evidence",
                "refine.language.preserved=pass",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "cannot pass without a newer transcript revision",
                result.stderr,
            )

    def test_fixture_rejects_route_pass_without_both_capture_channels(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = self.run_fixture(
                self.write_report(root),
                self.write_app(root),
                root / "evidence",
                "built-in-speaker-mic",
                "--evidence",
                "capture.route.preserved=pass",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(
                "cannot pass without microphone and system assets",
                result.stderr,
            )

    def test_rejects_timestamp_without_utc_offset(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload = self.valid_report()
            payload["generatedAt"] = "2026-07-21T12:00:00"
            result = self.run_fixture(
                self.write_report(root, payload),
                self.write_app(root),
                root / "evidence",
                "model-cold-start",
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("generatedAt must include a UTC offset", result.stderr)

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

    def test_packages_complete_app_intents_siri_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "evidence"
            result = self.run_collector(
                self.write_report(root),
                self.write_app(root),
                output,
                "--check",
                "shortcuts-action-visible=pass",
                "--check",
                "spotlight-action-visible=pass",
                "--check",
                "siri-phrase-started-recording=pass",
                "--check",
                "recording-stopped-and-saved=pass",
                scenario="app-intents-siri",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(manifest["scenario"], "app-intents-siri")
            self.assertEqual(manifest["outcome"], "pass")
            self.assertEqual(
                set(manifest["checks"].values()),
                {"pass"},
            )

    def test_current_macos_uses_only_the_exact_system_binary(self):
        responses = {
            "-productVersion": "26.0\n",
            "-buildVersion": "25A123\n",
        }

        def run(command, **kwargs):
            self.assertEqual(command[0], "/usr/bin/sw_vers")
            self.assertEqual(
                kwargs,
                {"capture_output": True, "check": True, "text": True},
            )
            return subprocess.CompletedProcess(
                command,
                0,
                stdout=responses[command[1]],
                stderr="",
            )

        with mock.patch.object(collector.subprocess, "run", side_effect=run) as call:
            self.assertEqual(
                collector.current_macos(),
                {"productVersion": "26.0", "buildVersion": "25A123"},
            )
        self.assertEqual(call.call_count, 2)

    def test_injected_macos_observation_remains_fail_closed(self):
        for observation in (
            [],
            {"productVersion": "26.0"},
            {
                "productVersion": "26.0",
                "buildVersion": "25A123",
                "callerOverride": "unsafe",
            },
            {"productVersion": "/tmp/fake", "buildVersion": "25A123"},
        ):
            with self.subTest(observation=observation):
                with self.assertRaises(collector.EvidenceError):
                    collector.validate_macos_observation(observation)

    def run_collector(self, report, app, output, *extra, scenario="cold-live-captions"):
        return self.run_cli(
            [
                "--scenario",
                scenario,
                "--report",
                str(report),
                "--output",
                str(output),
                "--app",
                str(app),
                *extra,
            ],
        )

    def run_fixture(self, report, app, output, fixture, *extra):
        return self.run_cli(
            [
                "--fixture",
                fixture,
                "--report",
                str(report),
                "--meeting-reference",
                "meeting-0123456789ab",
                "--output",
                str(output),
                "--app",
                str(app),
                *extra,
            ],
        )

    @staticmethod
    def run_cli(arguments):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            returncode = collector.main(
                arguments,
                system_observer=lambda: {
                    "productVersion": "26.0",
                    "buildVersion": "25A123",
                },
            )
        return subprocess.CompletedProcess(
            arguments,
            returncode,
            stdout=stdout.getvalue(),
            stderr=stderr.getvalue(),
        )

    @staticmethod
    def write_app(root):
        app = root / "Portavoz Dev.app"
        info = app / "Contents" / "Info.plist"
        info.parent.mkdir(parents=True, exist_ok=True)
        with info.open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "app.portavoz.mac.dev",
                    "CFBundleShortVersionString": "0.7.0",
                    "CFBundleVersion": "700",
                },
                handle,
            )
        return app

    def write_report(self, root, payload=None, name="portavoz-support.json"):
        report = root / name
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
                "schemaVersion": 15,
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
