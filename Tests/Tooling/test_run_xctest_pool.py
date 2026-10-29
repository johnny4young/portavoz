import contextlib
import io
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
import unittest.mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import run_xctest_pool as pool  # noqa: E402

LISTING = """PortavozTests.AlphaTests/testOne
PortavozTests.AlphaTests/testTwo
PortavozTests.BetaTests/testOnly
PortavozTests.GammaSuite/runsWithArguments(value:)
PortavozTests.GammaSuite/plain()
"""


class XCTestPoolTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, True)
        self.bundle = self.root / "PortavozTests.xctest"
        self.bundle.mkdir()
        self.listing = self.root / "tests.txt"
        self.listing.write_text(LISTING, encoding="utf-8")
        binary = self.root / "bin"
        binary.mkdir()
        # The fake xctest reports per class from FAKE_<Class> = "executed:skipped:failures:exit".
        (binary / "xcrun").write_text(
            "#!/bin/sh\n"
            "class=$(echo \"$3\" | sed 's/.*\\.//')\n"
            "eval spec=\\$FAKE_$class\n"
            "IFS=: read executed skipped failures status <<EOF\n$spec\nEOF\n"
            "if [ \"$executed\" != none ]; then\n"
            "  if [ \"$skipped\" = 0 ]; then\n"
            "    echo \"Executed $executed tests, with $failures failures (0 unexpected) in 0.1 (0.1) seconds\"\n"
            "  else\n"
            "    echo \"Executed $executed tests, with $skipped tests skipped and $failures failures (0 unexpected) in 0.1 (0.1) seconds\"\n"
            "  fi\n"
            "fi\n"
            "exit $status\n",
            encoding="utf-8")
        (binary / "xcrun").chmod(0o755)
        self.environment = {"PATH": f"{binary}:{os.environ['PATH']}"}

    def run_pool(self, **classes):
        environment = dict(self.environment)
        environment.update({f"FAKE_{name}": spec for name, spec in classes.items()})
        output = io.StringIO()
        with unittest.mock.patch.dict(os.environ, environment), contextlib.redirect_stdout(output), \
                contextlib.redirect_stderr(io.StringIO()):
            status = pool.main(["--bundle", str(self.bundle), "--listing", str(self.listing), "--workers", "2"])
        return status, output.getvalue()

    def test_only_xctest_classes_are_selected(self):
        self.assertEqual(pool.xctest_classes(LISTING), {"PortavozTests.AlphaTests": 2, "PortavozTests.BetaTests": 1})

    def test_summary_reads_skipped_and_unexpected_failures(self):
        self.assertEqual(pool.summary("Executed 12 tests, with 3 tests skipped and 1 failure (2 unexpected) in 1 (1) seconds"),
                         (12, 3, 3))
        self.assertEqual(pool.summary("Executed 1 test, with 0 failures (0 unexpected) in 1 (1) seconds"), (1, 0, 0))
        self.assertIsNone(pool.summary("crashed before any summary"))

    def test_every_listed_case_passing_succeeds(self):
        status, output = self.run_pool(AlphaTests="2:1:0:0", BetaTests="1:0:0:0")
        self.assertEqual(status, 0)
        self.assertIn("XCTest classes: 2; cases: 3 of 3 listed (1 skipped); failed classes: 0", output)

    def test_a_failing_or_crashed_class_fails_the_run(self):
        for beta in ("1:0:1:1", "1:0:0:1", "none:0:0:0"):
            with self.subTest(beta=beta):
                status, output = self.run_pool(AlphaTests="2:0:0:0", BetaTests=beta)
                self.assertEqual(status, 1)
                self.assertIn("FAILED XCTest class: PortavozTests.BetaTests", output)

    def test_fewer_executed_cases_than_listed_fail_even_when_green(self):
        status, output = self.run_pool(AlphaTests="1:0:0:0", BetaTests="1:0:0:0")
        self.assertEqual(status, 1)
        self.assertIn("cases: 2 of 3 listed", output)

    def test_missing_bundle_or_empty_listing_is_rejected(self):
        self.listing.write_text("PortavozTests.GammaSuite/plain()\n", encoding="utf-8")
        status, _ = self.run_pool()
        self.assertEqual(status, 2)
        self.bundle.rmdir()
        status, _ = self.run_pool()
        self.assertEqual(status, 2)


if __name__ == "__main__":
    unittest.main()
