import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import swift_test_failure_summary as summary  # noqa: E402


class SwiftTestFailureSummaryTests(unittest.TestCase):
    def test_assertion_and_case_lines_collapse_to_one_identifier(self):
        log = """
/repo/Tests/ExampleTests.swift:42: error: -[PortavozTests.ExampleTests testFails] : XCTAssertEqual failed: (\"private payload\")
Test Case '-[PortavozTests.ExampleTests testFails]' failed (0.100 seconds).
"""
        self.assertEqual(
            summary.failed_test_identifiers(log),
            ("PortavozTests.ExampleTests/testFails",),
        )

    def test_multiple_failures_keep_first_observed_order(self):
        log = """
Test Case '-[PortavozTests.SecondTests testB]' failed (0.100 seconds).
/repo/Tests.swift:2: error: -[PortavozTests.FirstTests testA] : failure
Test Case '-[PortavozTests.FirstTests testA]' failed (0.100 seconds).
"""
        self.assertEqual(
            summary.failed_test_identifiers(log),
            (
                "PortavozTests.SecondTests/testB",
                "PortavozTests.FirstTests/testA",
            ),
        )

    def test_malformed_failure_text_is_not_reflected(self):
        payload = "private transcript must never be printed"
        log = f"Fatal error: {payload}\n"
        self.assertEqual(summary.failed_test_identifiers(log), ())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "swift.log"
            path.write_text(log)
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                result = summary.main([str(path)])

        output = stderr.getvalue()
        self.assertEqual(result, 0)
        self.assertIn("failed_test=unavailable", output)
        self.assertNotIn(payload, output)

    def test_log_loader_rejects_missing_empty_and_oversized_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(summary.FailureSummaryError):
                summary.load_private_log(root / "missing.log")

            empty = root / "empty.log"
            empty.write_bytes(b"")
            with self.assertRaises(summary.FailureSummaryError):
                summary.load_private_log(empty)

            oversized = root / "oversized.log"
            with oversized.open("wb") as output:
                output.truncate(summary.MAXIMUM_LOG_BYTES + 1)
            with self.assertRaises(summary.FailureSummaryError):
                summary.load_private_log(oversized)

    def test_cli_emits_only_content_free_identifier(self):
        payload = "private transcript must never be printed"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "swift.log"
            path.write_text(
                "/repo/Test.swift:1: error: "
                "-[PortavozTests.ExampleTests testFails] : "
                f"XCTAssertEqual failed: {payload}\n"
            )
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                result = summary.main([str(path)])

        output = stderr.getvalue()
        self.assertEqual(result, 0)
        self.assertIn("failed_test=PortavozTests.ExampleTests/testFails", output)
        self.assertNotIn(payload, output)


if __name__ == "__main__":
    unittest.main()
