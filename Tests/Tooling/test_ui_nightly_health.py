"""Nightly alert and freshness decisions (no network)."""

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
    def __init__(self, issues=(), runs=()):
        self.issues, self.runs, self.calls = list(issues), list(runs), []

    def __call__(self, *arguments):
        self.calls.append(arguments)
        if arguments[:2] == ("issue", "list"):
            return json.dumps(self.issues)
        if arguments[0] == "api":
            return json.dumps({"workflow_runs": self.runs})
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
        self.assertEqual(listing[listing.index("--author") + 1], "app/github-actions")


class CommandLineTests(unittest.TestCase):
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
