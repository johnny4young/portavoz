"""CI time report arithmetic and classification (no network)."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ci_time_report", ROOT / "scripts/ci_time_report.py")
report = importlib.util.module_from_spec(SPEC)
sys.modules["ci_time_report"] = report
SPEC.loader.exec_module(report)

SHA = "a" * 40


def job(name, created, started, completed, conclusion="success", job_id=None, runner="macos-26", steps=()):
    return {
        "id": job_id if job_id is not None else abs(hash((name, created))) % 10**9,
        "name": name,
        "conclusion": conclusion,
        "created_at": f"2026-11-02T{created}Z",
        "started_at": f"2026-11-02T{started}Z",
        "completed_at": f"2026-11-02T{completed}Z",
        "runner_name": "GitHub Actions 1" if runner else None,
        "labels": [runner] if runner else [],
        "steps": [{"name": step, "conclusion": result} for step, result in steps],
    }


def head(jobs, *, event="pull_request", number=1, start="10:00:00", workflow="ci.yml"):
    run = {"id": 1, "created_at": f"2026-11-02T{start}Z"}
    attempt = {"run_started_at": f"2026-11-02T{start}Z", "conclusion": "success"}
    return report.HeadAttempt(event, SHA, "feature", number, [report.RunAttempt(workflow, run, attempt, jobs)])


def row(jobs, *, changes=None, build=None, superseded=False, timeouts=None, **kwargs):
    return report.attempt_row(head(jobs, **kwargs), changes=changes or report.HeadChanges(files=["Sources/X/a.swift"]),
                              build=build, scope=None, timeouts=timeouts or {}, superseded=superseded)


class PercentileTests(unittest.TestCase):
    def test_nearest_rank_returns_observed_samples(self):
        values = list(range(1, 21))
        self.assertEqual(report.nearest_rank(values, 50), 10)
        self.assertEqual(report.nearest_rank(values, 90), 18)
        self.assertEqual(report.nearest_rank(values, 95), 19)
        self.assertEqual(report.nearest_rank([7], 95), 7)
        self.assertEqual(report.nearest_rank([3, 1, 2], 50), 2)

    def test_distribution_ignores_missing_samples_and_reports_none_when_empty(self):
        self.assertEqual(report.distribution([None, 5, None]), {"n": 1, "p50": 5, "p90": 5, "p95": 5, "max": 5})
        self.assertIsNone(report.distribution([None]))
        self.assertIsNone(report.distribution([]))


class AttemptMetricTests(unittest.TestCase):
    def test_execution_is_the_longest_blocking_job_and_total_includes_queue(self):
        result = row([
            job("repository-hygiene", "10:00:00", "10:00:05", "10:01:35", runner="ubuntu-latest"),
            job("build-and-test", "10:01:35", "10:06:35", "10:15:35"),
            job("lint", "10:01:35", "10:01:40", "10:02:05", runner="ubuntu-latest"),
        ])
        self.assertEqual(result["t_execution_s"], 540)
        self.assertEqual(result["longest_job"], "build-and-test")
        self.assertEqual(result["t_total_s"], 935)
        self.assertEqual(result["critical_path"], ["repository-hygiene", "build-and-test"])
        self.assertEqual(report.queue_block([result])["macos"]["max"], 300)

    def test_a_critical_path_never_crosses_workflows(self):
        first = head([job("repository-hygiene", "10:00:00", "10:00:00", "10:01:00", runner="ubuntu-latest"),
                      job("build-and-test", "10:01:00", "10:01:00", "10:05:00")])
        first.runs.append(report.RunAttempt("ui-tests.yml", first.runs[0].run, first.runs[0].attempt,
                                            [job("scope", "10:00:00", "10:00:00", "10:01:00", runner="ubuntu-latest"),
                                             job("ui-test-gate", "10:02:00", "10:02:00", "10:03:00",
                                                 runner="ubuntu-latest")]))
        result = report.attempt_row(first, changes=report.HeadChanges(files=[]), build=None, scope=None, timeouts={},
                                    superseded=False)
        self.assertEqual(result["critical_path"], ["repository-hygiene", "build-and-test"])
        self.assertFalse(result["partial"])

    def test_a_longer_job_outside_the_required_set_is_not_execution_time(self):
        result = row([
            job("build-and-test", "10:00:00", "10:00:00", "10:05:00"),
            job("ios-portability", "10:00:00", "10:00:00", "10:20:00"),
        ])
        self.assertEqual(result["t_execution_s"], 300)
        self.assertEqual(result["t_total_s"], 300)

    def test_push_blocks_on_the_release_contract_jobs(self):
        result = row([
            job("build-and-test", "10:00:00", "10:00:00", "10:05:00"),
            job("ios-portability", "10:00:00", "10:00:00", "10:08:00"),
        ], event="push")
        self.assertEqual(result["t_execution_s"], 480)

    def test_matrix_jobs_count_under_their_base_name(self):
        result = row([job("scoped-ui-tests (en)", "10:00:00", "10:00:00", "10:40:00")])
        self.assertEqual(result["t_execution_s"], 2400)

    def test_a_rerun_excludes_jobs_reused_from_the_previous_attempt(self):
        reused = job("build-and-test", "09:00:00", "09:00:00", "09:30:00")
        rerun = job("lint", "10:00:00", "10:00:00", "10:01:00", runner="ubuntu-latest")
        result = row([reused, rerun], number=2)
        self.assertEqual(result["t_execution_s"], 60)
        self.assertEqual(result["t_total_s"], 60)
        self.assertTrue(next(entry for entry in result["jobs"] if entry["name"] == "build-and-test")["carried"])

    def test_a_job_that_never_got_a_runner_has_no_duration_or_queue(self):
        result = row([job("build-and-test", "10:00:00", "10:00:00", "10:10:00", conclusion="cancelled", runner=None)])
        self.assertIsNone(result["t_execution_s"])
        self.assertEqual(report.queue_block([result]), {})


class SupersededTests(unittest.TestCase):
    JOBS = [job("build-and-test", "10:00:00", "10:00:00", "10:20:00")]

    def superseded(self, *created):
        return report.was_superseded(head(self.JOBS), [f"2026-11-02T{time}Z" for time in created])

    def test_only_a_run_created_while_the_attempt_ran_supersedes_it(self):
        self.assertTrue(self.superseded("10:10:00"))
        self.assertFalse(self.superseded("10:00:00"))
        self.assertFalse(self.superseded("10:25:00"))
        self.assertFalse(self.superseded("09:00:00"))
        self.assertFalse(self.superseded())


class OutcomeTests(unittest.TestCase):
    def outcome(self, jobs, **kwargs):
        return row(jobs, **kwargs)["outcome"]

    def test_passed_when_every_blocking_job_succeeded_or_was_skipped(self):
        self.assertEqual(self.outcome([
            job("build-and-test", "10:00:00", "10:00:00", "10:05:00"),
            job("interruption-controls", "10:00:00", "10:00:00", "10:00:00", conclusion="skipped", runner=None),
        ]), "passed")

    def test_a_failing_test_step_is_a_product_failure(self):
        steps = [("Current-SDK build and selected test suite", "failure")]
        self.assertEqual(self.outcome([job("build-and-test", "10:00:00", "10:00:00", "10:05:00",
                                           conclusion="failure", steps=steps)]), "product")

    def test_a_setup_or_cache_failure_is_infrastructure(self):
        for step in ("Set up job", "Run actions/checkout@3d3c", "Restore compatible Swift build state",
                     "Verify fixed Tahoe toolchain"):
            with self.subTest(step=step):
                self.assertEqual(self.outcome([job("build-and-test", "10:00:00", "10:00:00", "10:05:00",
                                                   conclusion="failure", steps=[(step, "failure")])]), "infrastructure")

    def test_a_failed_job_without_a_failed_step_is_infrastructure(self):
        self.assertEqual(self.outcome([job("build-and-test", "10:00:00", "10:00:00", "10:05:00",
                                           conclusion="failure")]), "infrastructure")

    def test_a_refused_rerun_is_named_apart_from_product_failures(self):
        steps = [(report.RERUN_REFUSED_STEP, "failure")]
        self.assertEqual(self.outcome([job("ui-test-gate", "10:00:00", "10:00:00", "10:00:10",
                                           conclusion="failure", steps=steps)], number=2), "rerun-refused")

    def test_a_cancelled_job_at_its_limit_is_a_timeout_unless_a_newer_run_cancelled_it(self):
        jobs = [job("build-and-test", "10:00:00", "10:00:00", "10:30:00", conclusion="cancelled")]
        self.assertEqual(self.outcome(jobs, timeouts={"build-and-test": 30}), "timeout")
        self.assertEqual(self.outcome(jobs, timeouts={"build-and-test": 30}, superseded=True), "superseded")

    def test_a_gate_failing_on_a_cancelled_need_is_not_a_failure_of_its_own(self):
        jobs = [job("scoped-ui-tests (en)", "10:00:00", "10:00:00", "10:05:00", conclusion="cancelled"),
                job("ui-test-gate", "10:05:00", "10:05:00", "10:05:10", conclusion="failure",
                    steps=[("Require selected evidence and allow an honest no-UI skip", "failure")])]
        self.assertEqual(self.outcome(jobs, superseded=True), "superseded")
        self.assertEqual(self.outcome(jobs), "cancelled")

    def test_an_api_timed_out_conclusion_is_a_timeout(self):
        self.assertEqual(self.outcome([job("build-and-test", "10:00:00", "10:00:00", "10:05:00",
                                           conclusion="timed_out")]), "timeout")

    def test_an_early_cancel_is_superseded_only_when_a_newer_run_exists(self):
        jobs = [job("build-and-test", "10:00:00", "10:00:00", "10:05:00", conclusion="cancelled")]
        self.assertEqual(self.outcome(jobs, timeouts={"build-and-test": 30}, superseded=True), "superseded")
        self.assertEqual(self.outcome(jobs, timeouts={"build-and-test": 30}), "cancelled")

    def test_a_product_failure_beats_a_cancelled_sibling(self):
        self.assertEqual(self.outcome([
            job("build-and-test", "10:00:00", "10:00:00", "10:05:00", conclusion="failure",
                steps=[("Current-SDK build and selected test suite", "failure")]),
            job("lint", "10:00:00", "10:00:00", "10:01:00", conclusion="cancelled"),
        ]), "product")


class LogDigestTests(unittest.TestCase):
    STAMP = "2026-11-02T20:39:09.6185560Z "

    def test_cache_states_come_from_the_restore_action_output(self):
        for line, expected in (
            ("Cache hit for: swift-build-v2-x", "exact"),
            ("Cache hit for restore-key: swift-build-v2-x", "fallback"),
            ("Cache not found for input keys: swift-build-v2-x", "miss"),
            ("Cache found and can be restored from key: swift-build-v2-x", "cold-policy"),
        ):
            with self.subTest(line=line):
                self.assertEqual(report.build_log_digest(self.STAMP + line + "\n")["cache"], expected)

    def test_the_echoed_workflow_script_is_not_a_rejected_restore(self):
        log = (self.STAMP + "Cache hit for restore-key: k\n"
               + self.STAMP + '\x1b[36;1m  echo "::warning::Cached Swift build state failed freshness verification; '
               'building cold."\x1b[0m\n')
        self.assertEqual(report.build_log_digest(log)["cache"], "fallback")

    def test_a_rejected_restore_wins_over_its_hit(self):
        log = (self.STAMP + "Cache hit for restore-key: k\n"
               + self.STAMP + "##[warning]Cached Swift build state failed freshness verification; building cold.\n")
        self.assertEqual(report.build_log_digest(log)["cache"], "rejected")

    def test_a_log_without_restore_output_is_unknown_never_a_hit(self):
        self.assertEqual(report.build_log_digest("nothing here\n")["cache"], "unknown")

    def test_compile_time_and_swift_scope(self):
        log = (self.STAMP + "  PORTAVOZ_SWIFT_TEST_SCOPE: \n"
               + self.STAMP + "Build complete! (144.94s)\n")
        digest = report.build_log_digest(log)
        self.assertEqual(digest["compile_s"], 145)
        self.assertEqual(digest["swift_scope"], "full")
        narrowed = report.build_log_digest(self.STAMP + r"  PORTAVOZ_SWIFT_TEST_SCOPE: ^PortavozTests\.(A)/" + "\n")
        self.assertEqual(narrowed["swift_scope"], "contract-only")

    def test_scope_digest_counts_selectors_and_bounds_the_reason(self):
        log = (self.STAMP + "  SUMMARY: " + "x" * 500 + "\n"
               + self.STAMP + "  TESTS: A/a B/b C/c\n")
        digest = report.scope_log_digest(log)
        self.assertEqual(digest["selectors"], 3)
        self.assertEqual(len(digest["summary"]), report.SUMMARY_LIMIT)
        self.assertEqual(report.scope_log_digest(self.STAMP + "  TESTS: \n")["selectors"], 0)


class CohortTests(unittest.TestCase):
    def cohorts(self, files, *, xcode_pin=False, build=None, jobs=None, event="pull_request"):
        jobs = jobs or [job("build-and-test", "10:00:00", "10:00:00", "10:05:00")]
        return row(jobs, changes=report.HeadChanges(files=files, xcode_pin=xcode_pin), build=build, event=event)["cohorts"]

    def test_docs_only_is_not_ordinary(self):
        result = self.cohorts(["docs/GAPS.md", "site/index.html"])
        self.assertIn("docs-only", result)
        self.assertNotIn("ordinary", result)

    def test_an_empty_diff_is_not_docs_only(self):
        self.assertNotIn("docs-only", self.cohorts([]))

    def test_dependency_and_xcode_pin_changes_are_declared_apart(self):
        for files, pin in ((["Package.resolved"], False), (["Package.swift"], False),
                           ([".github/workflows/ci.yml"], True)):
            with self.subTest(files=files):
                result = self.cohorts(files, xcode_pin=pin)
                self.assertIn("toolchain-deps", result)
                self.assertNotIn("ordinary", result)

    def test_core_and_app_changes_stay_ordinary(self):
        result = self.cohorts(["Sources/PortavozCore/a.swift", "Sources/portavoz-app/b.swift"])
        self.assertTrue({"core-change", "app-change", "ordinary"} <= set(result))

    def test_a_miss_on_a_normal_pull_request_stays_ordinary(self):
        result = self.cohorts(["Sources/StorageKit/a.swift"], build={"cache": "miss"})
        self.assertTrue({"cache-miss", "ordinary"} <= set(result))

    def test_interruption_controls_leave_the_ordinary_cohort(self):
        jobs = [job("interruption-controls", "10:00:00", "10:00:00", "10:10:00")]
        result = self.cohorts(["Sources/StorageKit/a.swift"], jobs=jobs)
        self.assertIn("interruption", result)
        self.assertNotIn("ordinary", result)

    def test_unknown_files_are_named_and_never_docs_only(self):
        result = self.cohorts(None)
        self.assertIn("files-unknown", result)
        self.assertNotIn("docs-only", result)

    def test_push_heads_are_never_ordinary_pull_requests(self):
        self.assertNotIn("ordinary", self.cohorts(["Sources/StorageKit/a.swift"], event="push"))


class SummaryTests(unittest.TestCase):
    def ordinary(self, minutes, *, outcome_jobs=None):
        return row(outcome_jobs or [job("build-and-test", "10:00:00", "10:00:00", f"10:{minutes:02d}:00")])

    def test_superseded_attempts_are_counted_but_not_measured(self):
        superseded = row([job("build-and-test", "10:00:00", "10:00:00", "10:02:00", conclusion="cancelled")],
                         superseded=True)
        summary = report.summarize([self.ordinary(5), superseded])["pull_request"]
        self.assertEqual(summary["attempts"], 2)
        self.assertEqual(summary["outcomes"], {"passed": 1, "superseded": 1})
        self.assertEqual(summary["overall"]["attempts"], 1)

    def test_blocking_jobs_get_their_own_distribution(self):
        summary = report.summarize([self.ordinary(5), self.ordinary(7)])["pull_request"]
        self.assertEqual(summary["jobs"]["build-and-test"], {"n": 2, "p50": 300, "p90": 420, "p95": 420, "max": 420})

    def test_a_timeout_still_counts_in_the_distribution(self):
        timed_out = row([job("build-and-test", "10:00:00", "10:00:00", "10:30:00", conclusion="cancelled")],
                        timeouts={"build-and-test": 30})
        summary = report.summarize([self.ordinary(5), timed_out])["pull_request"]
        self.assertEqual(summary["overall"]["t_execution"]["max"], 1800)

    def test_a_cohort_without_samples_reports_no_evidence(self):
        summary = report.summarize([self.ordinary(5)])
        self.assertIsNone(summary["pull_request"]["cohorts"]["cache-miss"])
        rendered = report.render_markdown({"window": {"repository": "r", "heads": 1, "until": None}, "summary": summary})
        self.assertIn("| cache-miss | 0 | no evidence |", rendered)
        self.assertIn("## push\n\nno evidence", rendered)

    def test_slo_is_evaluated_on_ordinary_heads_at_p95(self):
        fast = report.summarize([self.ordinary(5)])["pull_request"]["slo"]
        self.assertEqual(fast, {"execution_met": True, "total_met": True})
        slow = report.summarize([self.ordinary(11)])["pull_request"]["slo"]
        self.assertEqual(slow, {"execution_met": False, "total_met": True})
        docs = row([job("build-and-test", "10:00:00", "10:00:00", "10:50:00")],
                   changes=report.HeadChanges(files=["docs/GAPS.md"]))
        self.assertEqual(report.summarize([docs])["pull_request"]["slo"], {"execution_met": None, "total_met": None})

    def test_acceptance_needs_both_heads_and_days(self):
        acceptance = report.summarize([self.ordinary(5)])["pull_request"]["acceptance"]
        self.assertFalse(acceptance["met"])
        self.assertEqual(acceptance["ordinary_heads"], 1)


class FakeGitHub:
    def __init__(self, runs, attempts, pages=None):
        self.runs, self.attempts, self.pages = runs, attempts, pages or []

    def head_runs(self, sha):
        return self.runs

    def attempt(self, run_id, number):
        return self.attempts[(run_id, number)]

    def changes(self, event, sha, branch):
        return {"files": ["Sources/StorageKit/a.swift"], "xcode_pin": False}

    def cached(self, name, produce):
        return produce()

    def log(self, job_id):
        return None

    def workflow_runs(self, workflow, event, page):
        return self.pages[page - 1] if page <= len(self.pages) else []


def run_entry(run_id, workflow, created, *, attempts=1, status="completed", event="pull_request", sha=SHA):
    return {"id": run_id, "path": f".github/workflows/{workflow}", "event": event, "status": status, "head_sha": sha,
            "head_branch": "feature", "run_attempt": attempts, "created_at": f"2026-11-02T{created}Z"}


class CollectionTests(unittest.TestCase):
    HEAD = {"head_sha": SHA, "head_branch": "feature"}

    @staticmethod
    def attempt_data(started):
        return {"attempt": {"run_started_at": f"2026-11-02T{started}Z", "conclusion": "success"},
                "jobs": [job("lint", started, started, started, runner="ubuntu-latest")]}

    def rows(self, client, until=None):
        return report.head_rows(client, "pull_request", self.HEAD, {}, {}, until)

    def test_a_head_with_a_workflow_still_running_is_not_measured(self):
        client = FakeGitHub([run_entry(1, "ci.yml", "10:00:00"), run_entry(2, "ui-tests.yml", "10:00:00", status="in_progress")],
                            {(1, 1): self.attempt_data("10:00:00")})
        self.assertEqual(self.rows(client), [])

    def test_until_hides_later_runs_and_attempts_of_a_pinned_head(self):
        client = FakeGitHub([run_entry(1, "ci.yml", "10:00:00", attempts=2), run_entry(2, "ui-tests.yml", "12:00:00")],
                            {(1, 1): self.attempt_data("10:00:00"), (1, 2): self.attempt_data("12:00:00"),
                             (2, 1): self.attempt_data("12:00:00")})
        pinned = self.rows(client, until="2026-11-02T11:00:00Z")
        self.assertEqual([row["attempt"] for row in pinned], [1])
        self.assertEqual([run["workflow"] for run in pinned[0]["runs"]], ["ci.yml"])
        self.assertEqual([row["attempt"] for row in self.rows(client)], [1, 2])

    def test_later_runs_stay_visible_to_prove_a_pinned_attempt_was_superseded(self):
        page = [run_entry(2, "ci.yml", "12:00:00", sha="b" * 40), run_entry(1, "ci.yml", "10:00:00")]
        heads, branch_runs = report.latest_heads(FakeGitHub([], {}, [page]), "pull_request", 50, "2026-11-02T11:00:00Z")
        self.assertEqual([head["head_sha"] for head in heads], [SHA])
        self.assertIn("2026-11-02T12:00:00Z", branch_runs["feature"])

    def test_an_expired_log_is_named_instead_of_guessed(self):
        data = {"attempt": {"run_started_at": "2026-11-02T10:00:00Z", "conclusion": "success"},
                "jobs": [job("build-and-test", "10:00:00", "10:00:00", "10:05:00")]}
        client = FakeGitHub([run_entry(1, "ci.yml", "10:00:00")], {(1, 1): data})
        self.assertEqual(self.rows(client)[0]["cache"], "log-unavailable")


class TimeoutParsingTests(unittest.TestCase):
    def test_timeouts_are_read_per_job_and_ignore_step_level_limits(self):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "ci.yml"
            path.write_text("jobs:\n  lint:\n    runs-on: x\n    timeout-minutes: 15\n    steps:\n"
                            "      - run: y\n        timeout-minutes: 2\n  other:\n    runs-on: x\n")
            self.assertEqual(report.declared_timeouts([path]), {"lint": 15})

    def test_every_current_required_job_declares_a_timeout(self):
        timeouts = report.declared_timeouts()
        for name in ("repository-hygiene", "lint", "scope", "build-and-test", "ui-test-gate", "scoped-ui-tests"):
            self.assertIn(name, timeouts)


if __name__ == "__main__":
    unittest.main()
