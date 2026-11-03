import collections
import contextlib
import io
import json
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
PortavozTests.DeltaTests/testOnly
PortavozTests.GammaSuite/runsWithArguments(value:)
PortavozTests.GammaSuite/plain()
"""
PASSING = {"AlphaTests": "2:0:0:ok", "BetaTests": "1:0:0:ok", "DeltaTests": "1:0:0:ok"}

# Reports per class from FAKE_<Class> = "executed:skipped:failures:mode", in the order given.
FAKE_XCTEST = """#!/bin/sh
echo "$3" >> "$FAKE_LOG"
echo "Test Suite 'Selected tests' started at 2026-11-03 00:00:00.000."
echo "Test Suite 'PortavozPackageTests.xctest' started at 2026-11-03 00:00:00.000."
for qualified in $(echo "$3" | tr ',' ' '); do
  selected=${qualified%%/*}
  class=${selected##*.}
  eval spec=\\$FAKE_$class
  IFS=: read executed skipped failures mode <<EOF
$spec
EOF
  if [ "$mode" = silent ]; then continue; fi
  echo "Test Suite '$class' started at 2026-11-03 00:00:00.000."
  case "$mode" in
    crash) echo "Fatal error: synthetic"; exit 11 ;;
    hang) exec sleep 60 ;;
  esac
  verdict=passed
  [ "$failures" = 0 ] || verdict=failed
  echo "Test Suite '$class' $verdict at 2026-11-03 00:00:00.100."
  if [ "$skipped" = 0 ]; then
    echo "\t Executed $executed tests, with $failures failures (0 unexpected) in 0.1 (0.1) seconds"
  else
    echo "\t Executed $executed tests, with $skipped tests skipped and $failures failures (0 unexpected) in 0.1 (0.1) seconds"
  fi
  [ "$mode" != exits ] || exit 3
done
echo "Test Suite 'Selected tests' passed at 2026-11-03 00:00:00.200."
echo "\t Executed 99 tests, with 0 failures (0 unexpected) in 0.2 (0.2) seconds"
exit 0
"""


class XCTestPoolTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, True)
        self.bundle = self.root / "PortavozTests.xctest"
        self.bundle.mkdir()
        self.listing = self.root / "tests.txt"
        self.listing.write_text(LISTING, encoding="utf-8")
        self.log = self.root / "xctest.log"
        binary = self.root / "bin"
        binary.mkdir()
        (binary / "xcrun").write_text(FAKE_XCTEST, encoding="utf-8")
        (binary / "xcrun").chmod(0o755)
        self.environment = {"PATH": f"{binary}:{os.environ['PATH']}", "FAKE_LOG": str(self.log)}

    def run_pool(self, *extra, **classes):
        environment = dict(self.environment)
        environment.update({f"FAKE_{name}": spec for name, spec in {**PASSING, **classes}.items()})
        output = io.StringIO()
        with unittest.mock.patch.dict(os.environ, environment), contextlib.redirect_stdout(output), \
                contextlib.redirect_stderr(io.StringIO()):
            status = pool.main(["--bundle", str(self.bundle), "--listing", str(self.listing),
                                "--workers", "2", *extra])
        return status, output.getvalue()

    def launches(self):
        return [line.split(",") for line in self.log.read_text(encoding="utf-8").splitlines()]

    def test_only_xctest_classes_are_selected(self):
        self.assertEqual(pool.class_counts(pool.xctest_cases(LISTING)),
                         {"PortavozTests.AlphaTests": 2, "PortavozTests.BetaTests": 1, "PortavozTests.DeltaTests": 1})

    def test_a_deferred_case_stays_out_and_its_class_is_selected_by_case(self):
        allowlist = self.root / "nightly.txt"
        allowlist.write_text("# reviewed\nAlphaTests/testTwo\n", encoding="utf-8")

        status, output = self.run_pool("--nightly-only", str(allowlist), AlphaTests="1:0:0:ok")

        self.assertEqual(status, 0)
        self.assertIn("deferred to the nightly run: 1 cases", output)
        self.assertIn("cases: 3 of 3 listed", output)
        selected = self.launches()[0]
        self.assertIn("PortavozTests.AlphaTests/testOne", selected)
        self.assertNotIn("PortavozTests.AlphaTests/testTwo", selected)
        self.assertIn("PortavozTests.BetaTests", selected)

    def test_a_deferred_class_runs_whole_when_the_nightly_run_includes_it(self):
        allowlist = self.root / "nightly.txt"
        allowlist.write_text("AlphaTests/testTwo\n", encoding="utf-8")

        status, output = self.run_pool("--nightly-only", str(allowlist), "--include-nightly-only")

        self.assertEqual(status, 0)
        self.assertIn("deferred to the nightly run: 0 cases", output)
        self.assertIn("PortavozTests.AlphaTests", self.launches()[0])

    def test_the_nightly_allowlist_names_cases_that_exist(self):
        sources = "\n".join(path.read_text(encoding="utf-8") for path in (ROOT / "Tests").rglob("*.swift"))

        missing = [case for case in sorted(pool.nightly_only(pool.NIGHTLY_ONLY))
                   if f"class {case.split('/')[0]}" not in sources or f"func {case.split('/')[1]}(" not in sources]

        self.assertEqual(missing, [])

    def test_every_listed_case_passing_succeeds_in_one_process(self):
        status, output = self.run_pool(AlphaTests="2:1:0:ok")

        self.assertEqual(status, 0)
        self.assertIn("XCTest classes: 3; cases: 4 of 4 listed (1 skipped); failed classes: 0", output)
        self.assertEqual(len(self.launches()), 1)

    def test_a_failing_class_is_named_and_its_neighbours_still_count(self):
        status, output = self.run_pool(BetaTests="1:0:1:ok")

        self.assertEqual(status, 1)
        self.assertIn("FAILED XCTest class: PortavozTests.BetaTests (1 failures)", output)
        self.assertNotIn("FAILED XCTest class: PortavozTests.AlphaTests", output)
        self.assertIn("cases: 4 of 4 listed", output)

    def test_a_crash_fails_the_running_class_and_the_rest_continue_without_it(self):
        status, output = self.run_pool(BetaTests="1:0:0:crash")

        self.assertEqual(status, 1)
        self.assertIn("FAILED XCTest class: PortavozTests.BetaTests (no summary, exit 11)", output)
        self.assertNotIn("FAILED XCTest class: PortavozTests.AlphaTests", output)
        self.assertNotIn("FAILED XCTest class: PortavozTests.DeltaTests", output)
        self.assertIn("cases: 3 of 4 listed", output)
        relaunched = self.launches()[1]
        self.assertNotIn("PortavozTests.BetaTests", relaunched)
        self.assertIn("PortavozTests.DeltaTests", relaunched)

    def test_a_hung_class_times_out_and_the_rest_continue_without_it(self):
        status, output = self.run_pool("--class-timeout", "1", BetaTests="1:0:0:hang")

        self.assertEqual(status, 1)
        self.assertIn("FAILED XCTest class: PortavozTests.BetaTests (no summary after 1 s)", output)
        self.assertIn("cases: 3 of 4 listed", output)
        self.assertEqual(len(self.launches()), 2)

    def test_a_process_failing_after_its_suites_finish_still_fails(self):
        status, output = self.run_pool(DeltaTests="1:0:0:exits")

        self.assertEqual(status, 1)
        self.assertIn("(process exited 3 after this suite)", output)

    def test_a_class_with_fewer_cases_than_listed_fails_even_when_green(self):
        status, output = self.run_pool(AlphaTests="1:0:0:ok")

        self.assertEqual(status, 1)
        self.assertIn("FAILED XCTest class: PortavozTests.AlphaTests (executed 1 of 2 listed cases)", output)
        self.assertIn("cases: 3 of 4 listed", output)

    def test_a_class_xctest_never_reports_fails_without_looping(self):
        status, output = self.run_pool(BetaTests="1:0:0:silent")

        self.assertEqual(status, 1)
        self.assertIn("FAILED XCTest class: PortavozTests.BetaTests (never started, no summary, exit 0)", output)
        self.assertEqual(len(self.launches()), 2)

    def test_the_selected_tests_total_is_not_taken_for_a_class(self):
        status, output = self.run_pool()

        self.assertEqual(status, 0)
        self.assertNotIn("99", output.split("XCTest classes:")[1])

    def test_suites_with_the_same_name_in_two_modules_are_rejected(self):
        self.listing.write_text("KitTests.AlphaTests/testOne\nAppTests.AlphaTests/testOne\n", encoding="utf-8")

        status, _ = self.run_pool()

        self.assertEqual(status, 2)

    def test_missing_bundle_or_empty_listing_is_rejected(self):
        self.listing.write_text("PortavozTests.GammaSuite/plain()\n", encoding="utf-8")
        status, _ = self.run_pool()
        self.assertEqual(status, 2)
        self.bundle.rmdir()
        status, _ = self.run_pool()
        self.assertEqual(status, 2)

    def test_a_seed_changes_which_classes_share_a_process_and_nothing_else(self):
        seconds = {f"M.Class{index}": float(index % 5) + 1 for index in range(40)}

        plain, seeded, again = (pool.partition(seconds), pool.partition(seconds, seed="1"),
                                pool.partition(seconds, seed="1"))

        self.assertEqual(sorted(sum(plain, [])), sorted(seconds))
        self.assertEqual(sorted(sum(seeded, [])), sorted(seconds))
        self.assertEqual(seeded, again)
        self.assertNotEqual(plain, seeded)

    def test_batches_stay_under_the_target_and_a_long_class_runs_alone(self):
        seconds = {"M.Long": pool.TARGET_BATCH_SECONDS * 3, "M.A": 6.0, "M.B": 6.0, "M.C": 6.0, "M.D": 1.0}

        batches = pool.partition(seconds)

        self.assertEqual(batches[0], ["M.Long"])
        for batch in batches[1:]:
            self.assertLessEqual(sum(seconds[name] for name in batch), pool.TARGET_BATCH_SECONDS)

    def test_an_unrecorded_class_is_estimated_from_its_cases(self):
        classes = collections.Counter({"M.Known": 2, "M.Unknown": 10})

        seconds = pool.estimated_seconds(classes, {"Known": 7.5})

        self.assertEqual(seconds, {"M.Known": 7.5, "M.Unknown": 10 * pool.ESTIMATED_CASE_SECONDS})

    def test_the_table_records_only_classes_at_the_floor(self):
        log = ("Test Suite 'SlowTests' passed at x.\n\t Executed 2 tests, with 0 failures (0 unexpected) in 2 (2.04) seconds\n"
               "Test Suite 'QuickTests' passed at x.\n\t Executed 2 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds\n"
               "Test Suite 'PortavozPackageTests.xctest' passed at x.\n\t Executed 4 tests, with 0 failures (0 unexpected) in 9 (9) seconds\n"
               "Test Suite 'Selected tests' passed at x.\n\t Executed 4 tests, with 0 failures (0 unexpected) in 9 (9) seconds\n")

        self.assertEqual(pool.recorded_seconds(log), {"SlowTests": 2.0})

    def test_the_checked_in_table_names_classes_that_exist(self):
        table = json.loads(pool.DURATIONS.read_text(encoding="utf-8"))
        sources = "\n".join(path.read_text(encoding="utf-8") for path in (ROOT / "Tests").rglob("*.swift"))

        missing = [name for name in table if f"class {name}" not in sources]

        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
