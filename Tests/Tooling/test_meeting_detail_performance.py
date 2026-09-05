import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "meeting_detail_performance.py"
SPEC = importlib.util.spec_from_file_location("meeting_detail_performance", SCRIPT)
performance = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = performance
SPEC.loader.exec_module(performance)


class MeetingDetailPerformanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "xcode-version.txt").write_text(
            "Xcode 26.6\nBuild version 17F113\n",
            encoding="utf-8",
        )
        (self.root / "xctrace-version.txt").write_text(
            "xctrace version 16.0 (17F113)\n",
            encoding="utf-8",
        )
        (self.root / "sw-vers.txt").write_text(
            "ProductName:\t\tmacOS\nProductVersion:\t\t26.5.2\n"
            "BuildVersion:\t\t25F84\n",
            encoding="utf-8",
        )
        for slug, _, interaction in performance.PROFILES:
            self.write_signposts(slug, interaction)
            self.write_table(slug, "swiftui-updates", "<row><name>body</name></row>")
            self.write_table(
                slug,
                "hitches",
                "<row><duration>12000000</duration><process>Portavoz Dev</process></row>"
                "<row><duration>999000000</duration><process>WindowServer</process></row>",
            )
            self.write_table(
                slug,
                "potential-hangs",
                "<row><duration>260000000</duration><process>Portavoz Dev</process></row>",
            )
            (self.root / f"{slug}-time-profile.xml").write_text(
                "MeetingDetailView.body.getter TranscriptSegmentsView",
                encoding="utf-8",
            )
            (self.root / f"{slug}-swiftui.log").write_text("", encoding="utf-8")

    def tearDown(self):
        self.temporary.cleanup()

    def write_table(self, slug: str, name: str, rows: str) -> None:
        (self.root / f"{slug}-{name}.xml").write_text(
            f"<trace-query-result>{rows}</trace-query-result>",
            encoding="utf-8",
        )

    def write_signposts(self, slug: str, interaction: str, sample_count: int = 5) -> None:
        rows = [
            "<row><start-time>1000</start-time><duration>91000000</duration>"
            "<string>Meeting Detail First Content</string></row>"
        ]
        for index in range(sample_count):
            name = (
                f"<string id='interaction-name'>{interaction}</string>"
                if index == 0
                else "<string ref='interaction-name'/>"
            )
            rows.append(
                f"<row><start-time>{2000 + index}</start-time>"
                f"<duration>{(index + 1) * 1000000}</duration>"
                f"{name}</row>"
            )
        self.write_table(slug, "os-signpost-interval", "".join(rows))

    def test_builds_two_profile_baseline_without_counting_system_events(self):
        document = performance.build_document(self.root, trace_duration_seconds=10)

        self.assertEqual(document["schemaVersion"], 2)
        self.assertEqual(
            [profile["fixture"]["segmentCount"] for profile in document["profiles"]],
            [5_000, 20_000],
        )
        for profile in document["profiles"]:
            self.assertEqual(profile["interaction"]["sampleCount"], 5)
            self.assertEqual(profile["interaction"]["p50Milliseconds"], 3)
            self.assertEqual(profile["interaction"]["p95Milliseconds"], 5)
            self.assertEqual(profile["animationHitches"]["count"], 1)
            self.assertEqual(profile["responsiveness"]["potentialHangCount"], 1)
            self.assertTrue(
                profile["fixture"]["summaryMutation"][
                    "excludedFromInteractionTrace"
                ]
            )
        self.assertEqual(document["limitations"], [])
        self.assertEqual(
            document["reproduction"]["applicationKind"],
            "installed-dev-bundle",
        )
        self.assertEqual(document["reproduction"]["userLibraryAccess"], "none")

    def test_scratch_bundle_capture_is_disclosed_without_a_local_path(self):
        document = performance.build_document(
            self.root,
            trace_duration_seconds=10,
            application_kind="development-bundle-override",
        )

        self.assertEqual(
            document["reproduction"]["applicationKind"],
            "development-bundle-override",
        )
        self.assertNotIn("application", document["reproduction"])

        with self.assertRaisesRegex(performance.EvidenceError, "unsupported application kind"):
            performance.build_document(
                self.root,
                trace_duration_seconds=10,
                application_kind="release",
            )

    def test_empty_swiftui_export_is_explicitly_unavailable_not_zero(self):
        slug = performance.PROFILES[1][0]
        self.write_table(slug, "swiftui-updates", "")
        (self.root / f"{slug}-swiftui.log").write_text(
            "Trace file had no SwiftUI data",
            encoding="utf-8",
        )

        document = performance.build_document(self.root, trace_duration_seconds=10)
        profile = document["profiles"][1]
        self.assertEqual(profile["bodyInvalidations"]["status"], "unavailable-toolchain")
        self.assertEqual(profile["bodyInvalidations"]["updateRowCount"], 0)
        self.assertTrue(profile["bodyInvalidations"]["xctraceWarningPresent"])
        self.assertIn("does not represent body invalidations as zero", document["limitations"][0])

    def test_incomplete_interaction_samples_fail_closed(self):
        slug, _, interaction = performance.PROFILES[0]
        self.write_signposts(slug, interaction, sample_count=4)

        with self.assertRaisesRegex(performance.EvidenceError, "at least 5"):
            performance.build_document(self.root, trace_duration_seconds=10)

    def test_excess_interaction_samples_fail_closed(self):
        slug, _, interaction = performance.PROFILES[0]
        self.write_signposts(slug, interaction, sample_count=6)

        with self.assertRaisesRegex(performance.EvidenceError, "at most 5"):
            performance.build_document(self.root, trace_duration_seconds=10)

    def test_trace_references_are_resolved_and_cycles_fail(self):
        path = self.root / "references.xml"
        path.write_text(
            "<trace-query-result><row><duration id='d1'>5000000</duration></row>"
            "<row><duration ref='d1'/></row></trace-query-result>",
            encoding="utf-8",
        )
        table = performance.XMLTable.read(path)
        self.assertEqual(table.nanoseconds(table.rows[1], "duration"), 5_000_000)

        path.write_text(
            "<trace-query-result><duration id='a' ref='b'/><duration id='b' ref='a'/>"
            "<row><duration ref='a'/></row></trace-query-result>",
            encoding="utf-8",
        )
        table = performance.XMLTable.read(path)
        with self.assertRaisesRegex(performance.EvidenceError, "invalid duration reference"):
            table.nanoseconds(table.rows[0], "duration")

    def test_cli_writes_canonical_json(self):
        output = self.root / "baseline.json"
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--input",
                str(self.root),
                "--output",
                str(output),
                "--trace-duration",
                "10",
            ],
            cwd=REPOSITORY,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(output.read_text())["schemaVersion"], 2)
        self.assertTrue(output.read_text(encoding="utf-8").endswith("\n"))


if __name__ == "__main__":
    unittest.main()
