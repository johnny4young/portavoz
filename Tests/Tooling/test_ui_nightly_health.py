"""Nightly and push-run alert and freshness decisions (no network)."""

from datetime import datetime, timedelta, timezone
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ui_nightly_health", ROOT / "scripts/ui_nightly_health.py")
health = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(health)

NOW = datetime(2026, 11, 2, 12, tzinfo=timezone.utc)


class FakeGitHub:
    def __init__(self, issues=(), runs=(), jobs=()):
        self.issues, self.runs, self.jobs, self.calls = list(issues), list(runs), list(jobs), []

    def __call__(self, *arguments):
        self.calls.append(arguments)
        if arguments[:2] == ("issue", "list"):
            return json.dumps(self.issues)
        if arguments[0] == "api":
            return json.dumps({"workflow_runs": self.runs, "jobs": self.jobs})
        return ""

    def writes(self):
        return [call[:2] for call in self.calls if call[:2] != ("issue", "list") and call[0] != "api"]


def needs(**results):
    return {job: {"result": result} for job, result in results.items()}


def run_entry(**overrides):
    return {"created_at": "2026-11-02T11:00:00Z", "html_url": "https://example.test/9", "event": "schedule",
            "head_repository": {"full_name": "o/r"}, **overrides}


def alert(results, run):
    return health.alert(results, ref="main", sha="abc", run_url="https://example.test/1", run=run)


class AlertTests(unittest.TestCase):
    def test_a_green_night_touches_no_issue(self):
        fake = FakeGitHub()

        alert(needs(build="success", shard="success"), fake)

        self.assertEqual(fake.calls, [])

    def test_a_cancelled_job_opens_an_issue_like_a_failed_one(self):
        for result in ("failure", "cancelled", "skipped", "timed_out"):
            with self.subTest(result=result):
                fake = FakeGitHub()

                alert(needs(build=result, shard="success"), fake)

                self.assertEqual(fake.writes(), [("issue", "create")])
                body = fake.calls[-1][fake.calls[-1].index("--body") + 1]
                self.assertIn(f"build: {result}", body)
                self.assertNotIn("shard", body)
                self.assertIn("https://example.test/1", body)

    def test_a_later_night_updates_the_open_issue_instead_of_opening_another(self):
        fake = FakeGitHub(issues=[{"number": 7, "title": health.UNVERIFIED_TITLE}])

        alert(needs(build="failure"), fake)

        self.assertEqual(fake.writes(), [("issue", "comment")])
        self.assertEqual(fake.calls[-1][2], "7")

    def test_a_similar_title_is_not_the_open_issue(self):
        fake = FakeGitHub(issues=[{"number": 7, "title": f"{health.UNVERIFIED_TITLE} on a branch"}])

        alert(needs(build="failure"), fake)

        self.assertEqual(fake.writes(), [("issue", "create")])

    def test_no_needed_jobs_is_unknown_never_green(self):
        with self.assertRaises(health.HealthError):
            alert({}, FakeGitHub())

    def test_a_job_without_a_result_counts_as_unverified(self):
        self.assertEqual(health.unverified_jobs({"build": {}, "shard": None}), {"build": "None", "shard": "None"})


class FreshnessTests(unittest.TestCase):
    def run_at_age(self, hours, *, issues=()):
        created = (NOW - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
        fake = FakeGitHub(issues=issues, runs=[run_entry(created_at=created)])
        return health.freshness("o/r", now=NOW, max_age_hours=48, run=fake), fake

    def test_evidence_at_the_limit_is_fresh(self):
        message, fake = self.run_at_age(48)

        self.assertEqual(message, "Nightly UI evidence is fresh.")
        self.assertEqual(fake.writes(), [])

    def test_older_evidence_opens_an_issue_with_the_age_and_the_action(self):
        message, fake = self.run_at_age(49)

        self.assertTrue(message.startswith("::warning::"))
        self.assertEqual(fake.writes(), [("issue", "create")])
        body = fake.calls[-1][fake.calls[-1].index("--body") + 1]
        self.assertIn("49 hours old", body)
        self.assertIn("gh workflow run ui-nightly.yml --ref main", body)

    def test_each_push_edits_the_open_issue_without_notifying_again(self):
        _, fake = self.run_at_age(60, issues=[{"number": 3, "title": health.STALE_TITLE}])

        self.assertEqual(fake.writes(), [("issue", "edit")])

    def test_fresh_evidence_closes_the_stale_issue(self):
        _, fake = self.run_at_age(1, issues=[{"number": 3, "title": health.STALE_TITLE}])

        self.assertEqual(fake.writes(), [("issue", "close")])

    def test_no_verified_run_ever_is_stale(self):
        fake = FakeGitHub()

        message = health.freshness("o/r", now=NOW, max_age_hours=48, run=fake)

        self.assertTrue(message.startswith("::warning::"))
        self.assertEqual(fake.writes(), [("issue", "create")])

    def test_only_a_successful_run_on_main_counts(self):
        fake = FakeGitHub()

        health.newest_verified_run("o/r", fake)

        path = next(call[1] for call in fake.calls if call[0] == "api")
        self.assertIn("branch=main", path)
        self.assertIn("status=success", path)

    def test_a_fork_or_pull_request_run_on_a_branch_named_main_never_counts(self):
        own = run_entry(event="workflow_dispatch")
        fake = FakeGitHub(runs=[run_entry(head_repository={"full_name": "fork/r"}), run_entry(event="pull_request"),
                                run_entry(head_repository=None), own])

        self.assertEqual(health.newest_verified_run("o/r", fake), own)
        self.assertIsNone(health.newest_verified_run("o/r", FakeGitHub(runs=[run_entry(event="pull_request")])))

    def test_only_issues_this_workflow_opened_are_reused(self):
        fake = FakeGitHub()

        alert(needs(build="failure"), fake)

        listing = next(call for call in fake.calls if call[:2] == ("issue", "list"))
        self.assertEqual(listing[listing.index("--author") + 1], "github-actions[bot]")

    def test_the_lookup_never_depends_on_the_search_index(self):
        fake = FakeGitHub()

        alert(needs(build="failure"), fake)

        listing = next(call for call in fake.calls if call[:2] == ("issue", "list"))
        self.assertNotIn("--search", listing)

    def test_a_rerun_is_aged_from_its_latest_attempt(self):
        rerun = run_entry(created_at="2026-10-20T00:00:00Z", run_started_at="2026-11-02T11:00:00Z")

        self.assertIsNone(health.stale_message(rerun, NOW, 48))


def green_push_needs():
    return needs(**{job: "success" for job in health.PUSH_JOBS})


def push_run(number, **overrides):
    return {"id": number * 10, "run_number": number, "event": "push", "status": "completed", "head_sha": "abc",
            "html_url": f"https://example.test/{number}", **overrides}


def push_alert(results, fake, number=5):
    return health.push_alert(results, repository="o/r", run_number=number, sha="abc",
                             run_url=f"https://example.test/{number}", run=fake)


RED_ISSUE = {"number": 7, "title": health.RED_PUSH_TITLE}


class PushAlertTests(unittest.TestCase):
    def test_the_jobs_it_watches_are_the_release_contract(self):
        contract = json.loads((ROOT / "docs/evidence/source-integration-qualification.json").read_text(encoding="utf-8"))

        self.assertEqual(sorted(health.PUSH_JOBS), contract["hostedCI"]["requiredJobs"])

    def test_each_job_that_did_not_pass_opens_the_issue(self):
        for job in health.PUSH_JOBS:
            for result in ("failure", "cancelled", "skipped"):
                with self.subTest(job=job, result=result):
                    fake = FakeGitHub(runs=[push_run(5)])

                    message = push_alert({**green_push_needs(), job: {"result": result}}, fake)

                    self.assertEqual(fake.writes(), [("issue", "create")])
                    create = fake.calls[-1]
                    self.assertEqual(create[create.index("--title") + 1], health.RED_PUSH_TITLE)
                    body = create[create.index("--body") + 1]
                    self.assertIn(f"{job}: {result}", body)
                    self.assertIn("https://example.test/5", body)
                    self.assertIn("abc", body)
                    for passed in set(health.PUSH_JOBS) - {job}:
                        self.assertNotIn(passed, body)
                    self.assertTrue(message.startswith("::error::"))

    def test_a_green_run_with_no_issue_writes_nothing(self):
        fake = FakeGitHub(runs=[push_run(5)])

        push_alert(green_push_needs(), fake)

        self.assertEqual(fake.writes(), [])

    def test_a_later_green_run_closes_the_issue(self):
        fake = FakeGitHub(issues=[RED_ISSUE], runs=[push_run(5)])

        push_alert(green_push_needs(), fake)

        self.assertEqual(fake.writes(), [("issue", "close")])
        self.assertEqual(fake.calls[-1][2], "7")

    def test_a_later_red_run_updates_the_one_open_issue(self):
        fake = FakeGitHub(issues=[RED_ISSUE], runs=[push_run(5)])

        push_alert({**green_push_needs(), "lint": {"result": "failure"}}, fake)

        self.assertEqual(fake.writes(), [("issue", "comment")])
        self.assertEqual(fake.calls[-1][2], "7")

    def test_the_nightly_issue_is_not_this_issue(self):
        fake = FakeGitHub(issues=[{"number": 7, "title": health.UNVERIFIED_TITLE}], runs=[push_run(5)])

        push_alert(green_push_needs(), fake)
        self.assertEqual(fake.writes(), [])

        push_alert({**green_push_needs(), "lint": {"result": "failure"}}, fake)
        self.assertEqual(fake.writes(), [("issue", "create")])

    def test_an_older_run_finishing_last_never_overwrites_the_newest_verdict(self):
        red = {**green_push_needs(), "lint": {"result": "failure"}}
        for results, issues in ((green_push_needs(), [RED_ISSUE]), (red, []), (red, [RED_ISSUE])):
            with self.subTest(results=results, issues=issues):
                fake = FakeGitHub(issues=issues, runs=[push_run(6, status="in_progress", conclusion=None), push_run(5)])

                message = push_alert(results, fake, number=5)

                self.assertEqual(fake.writes(), [])
                self.assertIn("run 6", message)

    def test_a_rerun_of_the_newest_run_can_close_the_issue(self):
        fake = FakeGitHub(issues=[RED_ISSUE], runs=[push_run(5, run_attempt=2, status="in_progress")])

        push_alert(green_push_needs(), fake)

        self.assertEqual(fake.writes(), [("issue", "close")])

    def test_only_a_push_on_main_can_be_the_newest_run(self):
        fake = FakeGitHub(runs=[push_run(9, event="pull_request"), push_run(8, event="workflow_dispatch"), push_run(5)])

        self.assertEqual(health.newest_push_run("o/r", fake)["run_number"], 5)
        path = next(call[1] for call in fake.calls if call[0] == "api")
        self.assertIn("workflows/ci.yml/runs", path)
        self.assertIn("branch=main", path)
        self.assertIn("event=push", path)

    def test_no_needed_jobs_or_no_readable_run_is_unknown_never_green(self):
        with self.assertRaises(health.HealthError):
            push_alert({}, FakeGitHub(runs=[push_run(5)]))
        with self.assertRaises(health.HealthError):
            push_alert(green_push_needs(), FakeGitHub())


class PushWatchTests(unittest.TestCase):
    @staticmethod
    def jobs(**changes):
        results = {**{job: "success" for job in health.PUSH_JOBS}, "scope": "skipped", "alert": "failure", **changes}
        return [{"name": name, "conclusion": result} for name, result in results.items()]

    def test_a_run_in_flight_is_left_to_report_itself(self):
        fake = FakeGitHub(runs=[push_run(5, status="in_progress")], jobs=self.jobs(lint="failure"))

        health.push_watch("o/r", fake)

        self.assertEqual(fake.writes(), [])
        self.assertEqual([call for call in fake.calls if "/jobs" in call[1]], [])

    def test_a_red_run_its_alert_missed_opens_the_issue(self):
        fake = FakeGitHub(runs=[push_run(5)], jobs=self.jobs(lint="failure"))

        message = health.push_watch("o/r", fake)

        self.assertEqual(fake.writes(), [("issue", "create")])
        body = fake.calls[-1][fake.calls[-1].index("--body") + 1]
        self.assertIn("lint: failure", body)
        self.assertIn("https://example.test/5", body)
        self.assertTrue(message.startswith("::warning::"))

    def test_an_open_issue_is_not_notified_again_on_every_push(self):
        fake = FakeGitHub(issues=[RED_ISSUE], runs=[push_run(5)], jobs=self.jobs(lint="failure"))

        health.push_watch("o/r", fake)

        self.assertEqual(fake.writes(), [])

    def test_a_run_that_started_no_job_is_red(self):
        fake = FakeGitHub(runs=[push_run(5)], jobs=[])

        health.push_watch("o/r", fake)

        body = fake.calls[-1][fake.calls[-1].index("--body") + 1]
        for job in health.PUSH_JOBS:
            self.assertIn(f"{job}: did not run", body)

    def test_a_failed_alert_alone_does_not_make_main_red(self):
        fake = FakeGitHub(runs=[push_run(5)], jobs=self.jobs())

        health.push_watch("o/r", fake)

        self.assertEqual(fake.writes(), [])

    def test_a_green_run_closes_an_issue_its_alert_could_not(self):
        fake = FakeGitHub(issues=[RED_ISSUE], runs=[push_run(5)], jobs=self.jobs())

        health.push_watch("o/r", fake)

        self.assertEqual(fake.writes(), [("issue", "close")])


class CommandLineTests(unittest.TestCase):
    PUSH_ALERT = ["push-alert", "--repository", "o/r", "--run-number", "5", "--sha", "s", "--run-url", "u"]

    def test_an_unreadable_api_fails_every_push_command(self):
        failure = subprocess.CompletedProcess([], 1, stdout="", stderr="HTTP 403")
        with patch.object(health.subprocess, "run", return_value=failure):
            self.assertEqual(health.main(["push-watch", "--repository", "o/r"]), 1)
            self.assertEqual(health.main([*self.PUSH_ALERT, "--needs", json.dumps(green_push_needs())]), 1)

    def test_an_unexpected_api_shape_fails_every_push_command(self):
        reply = subprocess.CompletedProcess([], 0, stdout="{}", stderr="")
        with patch.object(health.subprocess, "run", return_value=reply):
            self.assertEqual(health.main(["push-watch", "--repository", "o/r"]), 1)
            self.assertEqual(health.main([*self.PUSH_ALERT, "--needs", json.dumps(green_push_needs())]), 1)

    def test_malformed_push_needs_fail(self):
        self.assertEqual(health.main([*self.PUSH_ALERT, "--needs", "not json"]), 1)

    def test_an_unreadable_api_fails_instead_of_reading_as_healthy(self):
        failure = subprocess.CompletedProcess([], 1, stdout="", stderr="HTTP 403")
        with patch.object(health.subprocess, "run", return_value=failure):
            self.assertEqual(health.main(["freshness", "--repository", "o/r"]), 1)

    def test_malformed_needs_fail(self):
        self.assertEqual(health.main(["alert", "--needs", "not json", "--ref", "r", "--sha", "s", "--run-url", "u"]), 1)

    def test_a_green_night_exits_cleanly(self):
        arguments = ["alert", "--needs", json.dumps(needs(build="success")), "--ref", "r", "--sha", "s", "--run-url", "u"]
        self.assertEqual(health.main(arguments), 0)


if __name__ == "__main__":
    unittest.main()
