#!/usr/bin/env python3
"""Turn an unverified or missing nightly UI run, or a red push run on main, into a visible GitHub issue.

`alert` runs at the end of the nightly workflow and treats anything but success
in a needed job as unverified, cancellation included. `freshness` runs outside
it, because a schedule that never fires cannot report its own absence. `push-alert`
ends every push run on main, and `push-watch` repairs the issue when that job could
not. An unreadable API is an unknown state, so it fails rather than reading as healthy.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import subprocess
import sys
from typing import Any, Callable, Sequence

NIGHTLY_WORKFLOW = "ui-nightly.yml"
MAX_AGE_HOURS = 48
UNVERIFIED_TITLE = "Nightly UI is not verified"
STALE_TITLE = "Nightly UI evidence is stale"
CI_WORKFLOW = "ci.yml"
RED_PUSH_TITLE = "CI on main is red"
PUSH_JOBS = ("repository-hygiene", "lint", "build-and-test", "ios-portability")
# Issues this workflow owns; anyone can open another with the same title.
ISSUE_AUTHOR = "github-actions[bot]"
VERIFIED_EVENTS = frozenset({"schedule", "workflow_dispatch"})


class HealthError(RuntimeError):
    pass


def gh(*arguments: str) -> str:
    result = subprocess.run(["gh", *arguments], capture_output=True, text=True, timeout=60, check=False)
    if result.returncode != 0:
        raise HealthError(f"gh {arguments[0]}: {result.stderr.strip()}")
    return result.stdout


def unverified_jobs(needs: dict[str, Any]) -> dict[str, str]:
    if not needs:
        raise HealthError("the nightly run reported no needed jobs")
    return {job: str((data or {}).get("result")) for job, data in sorted(needs.items())
            if (data or {}).get("result") != "success"}


def open_issue_number(title: str, run: Callable[..., str] = gh) -> int | None:
    # A plain listing, because the search index can lag behind an issue opened moments ago.
    found = json.loads(run("issue", "list", "--state", "open", "--author", ISSUE_AUTHOR,
                           "--limit", "100", "--json", "number,title"))
    return next((issue["number"] for issue in found if issue["title"] == title), None)


def alert(needs: dict[str, Any], *, ref: str, sha: str, run_url: str, run: Callable[..., str] = gh) -> str:
    bad = unverified_jobs(needs)
    if not bad:
        return "Every needed job succeeded."
    details = ", ".join(f"{job}: {result}" for job, result in bad.items())
    body = f"{details}\n\nRef `{ref}` at `{sha}`: {run_url}"
    number = open_issue_number(UNVERIFIED_TITLE, run)
    if number is None:
        run("issue", "create", "--title", UNVERIFIED_TITLE, "--body", body)
        return f"Opened an issue: {details}"
    run("issue", "comment", str(number), "--body", body)
    return f"Updated issue #{number}: {details}"


def newest_verified_run(repository: str, run: Callable[..., str] = gh) -> dict[str, Any] | None:
    runs = json.loads(run("api", f"repos/{repository}/actions/workflows/{NIGHTLY_WORKFLOW}/runs"
                                 "?branch=main&status=success&per_page=50"))["workflow_runs"]
    # `branch` matches the name only, so a fork's own `main` must not pass as this repository's.
    return next((candidate for candidate in runs if candidate.get("event") in VERIFIED_EVENTS
                 and (candidate.get("head_repository") or {}).get("full_name") == repository), None)


def stale_message(verified: dict[str, Any] | None, now: datetime, max_age_hours: float) -> str | None:
    """Why the evidence is stale, or None while it is fresh."""
    if verified is None:
        return "No nightly UI run on `main` has ever been verified."
    # The latest attempt, so a nightly rerun to green counts from when it really ran.
    started = datetime.fromisoformat((verified.get("run_started_at") or verified["created_at"]).replace("Z", "+00:00"))
    age_hours = (now - started).total_seconds() / 3600
    if age_hours <= max_age_hours:
        return None
    return (f"The newest verified nightly UI run on `main` is {age_hours:.0f} hours old (limit {max_age_hours:g}): "
            f"{verified['html_url']}\n\nPause further scope reductions and dispatch it: "
            f"`gh workflow run {NIGHTLY_WORKFLOW} --ref main`.")


def freshness(repository: str, *, now: datetime, max_age_hours: float, run: Callable[..., str] = gh) -> str:
    message = stale_message(newest_verified_run(repository, run), now, max_age_hours)
    number = open_issue_number(STALE_TITLE, run)
    if message is None:
        if number is not None:
            run("issue", "close", str(number), "--comment", "A verified nightly UI run is within the limit again.")
        return "Nightly UI evidence is fresh."
    # Every push reaches this; editing keeps the current age without a notification each time.
    if number is None:
        run("issue", "create", "--title", STALE_TITLE, "--body", message)
    else:
        run("issue", "edit", str(number), "--body", message)
    return f"::warning::{message.splitlines()[0]}"


def newest_push_run(repository: str, run: Callable[..., str] = gh) -> dict[str, Any]:
    runs = json.loads(run("api", f"repos/{repository}/actions/workflows/{CI_WORKFLOW}/runs"
                                 "?branch=main&event=push&per_page=10"))["workflow_runs"]
    pushes = [candidate for candidate in runs if candidate.get("event") == "push"]
    if not pushes:
        raise HealthError("no push run on main is readable")
    # The number survives a rerun, so an older commit run again never reads as newer.
    return max(pushes, key=lambda candidate: candidate["run_number"])


def red_push_body(bad: dict[str, str], sha: str, run_url: str) -> str:
    details = ", ".join(f"{job}: {result}" for job, result in bad.items())
    return f"{details}\n\n`main` at `{sha}`: {run_url}"


def push_alert(needs: dict[str, Any], *, repository: str, run_number: int, sha: str, run_url: str,
               run: Callable[..., str] = gh) -> str:
    bad = unverified_jobs(needs)
    # Each main commit runs on its own, so an older run can finish last and must not overwrite a newer verdict.
    newest = newest_push_run(repository, run)
    if newest["run_number"] > run_number:
        return f"Push run {newest['run_number']} is newer and speaks for main."
    number = open_issue_number(RED_PUSH_TITLE, run)
    if not bad:
        if number is None:
            return "Every push job succeeded."
        run("issue", "close", str(number), "--comment", f"`main` passed at `{sha}`: {run_url}")
        return f"Closed issue #{number}."
    body = red_push_body(bad, sha, run_url)
    if number is None:
        run("issue", "create", "--title", RED_PUSH_TITLE, "--body", body)
        return f"::error::{RED_PUSH_TITLE}: {body.splitlines()[0]}"
    run("issue", "comment", str(number), "--body", body)
    return f"::error::{RED_PUSH_TITLE}, updated issue #{number}: {body.splitlines()[0]}"


def push_watch(repository: str, run: Callable[..., str] = gh) -> str:
    """Repair the issue when push-alert could not: its own failure, or a run that started no job."""
    newest = newest_push_run(repository, run)
    if newest.get("status") != "completed":
        return "The newest push run is still running and reports itself."
    jobs = json.loads(run("api", f"repos/{repository}/actions/runs/{newest['id']}/jobs?per_page=100"))["jobs"]
    conclusions = {job["name"]: job.get("conclusion") for job in jobs}
    bad = unverified_jobs({job: {"result": conclusions.get(job, "did not run")} for job in PUSH_JOBS})
    number = open_issue_number(RED_PUSH_TITLE, run)
    if not bad:
        if number is None:
            return "The newest push run passed."
        run("issue", "close", str(number), "--comment", f"`main` passed: {newest['html_url']}")
        return f"Closed issue #{number}."
    # An open issue already says so; repeating it on every push would only notify again.
    if number is None:
        run("issue", "create", "--title", RED_PUSH_TITLE, "--body",
            red_push_body(bad, newest["head_sha"], newest["html_url"]))
    return f"::warning::{RED_PUSH_TITLE}: {newest['html_url']}"


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    alerting = commands.add_parser("alert")
    alerting.add_argument("--needs", required=True, help="the workflow's toJSON(needs)")
    alerting.add_argument("--ref", required=True)
    alerting.add_argument("--sha", required=True)
    alerting.add_argument("--run-url", required=True)
    checking = commands.add_parser("freshness")
    checking.add_argument("--repository", required=True)
    checking.add_argument("--max-age-hours", type=float, default=MAX_AGE_HOURS)
    pushing = commands.add_parser("push-alert")
    pushing.add_argument("--needs", required=True, help="the workflow's toJSON(needs)")
    pushing.add_argument("--repository", required=True)
    pushing.add_argument("--run-number", required=True, type=int)
    pushing.add_argument("--sha", required=True)
    pushing.add_argument("--run-url", required=True)
    watching = commands.add_parser("push-watch")
    watching.add_argument("--repository", required=True)
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "alert":
            print(alert(json.loads(arguments.needs), ref=arguments.ref, sha=arguments.sha, run_url=arguments.run_url))
        elif arguments.command == "push-alert":
            print(push_alert(json.loads(arguments.needs), repository=arguments.repository,
                             run_number=arguments.run_number, sha=arguments.sha, run_url=arguments.run_url))
        elif arguments.command == "push-watch":
            print(push_watch(arguments.repository))
        else:
            print(freshness(arguments.repository, now=datetime.now(timezone.utc),
                            max_age_hours=arguments.max_age_hours))
    except (HealthError, OSError, subprocess.SubprocessError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        print(f"::error::CI health is unknown: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
