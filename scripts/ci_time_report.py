#!/usr/bin/env python3
"""Report hosted CI time per head, attempt, cohort and critical path.

Reads GitHub run metadata and job logs through `gh api`; it never checks out or
runs anything from the heads it measures. `--until` pins the window, so the same
command reproduces a recorded baseline while GitHub retains the logs (90 days).
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any, Callable, Iterable, Sequence

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from ui_test_runtime import percentile, write_receipt  # noqa: E402

REPOSITORY = "johnny4young/portavoz"
WORKFLOWS = ("ci.yml", "ui-tests.yml")
WORKFLOW_FILES = (ROOT / ".github/workflows/ci.yml",)
# Jobs that no longer exist still have recorded runs, which keep a limit to be judged against.
RETIRED_TIMEOUTS = {"swift-scope": 5, "interruption-controls": 30, "build-ui-products": 30, "scoped-ui-tests": 22,
                    "ui-test-gate": 5}
EVENTS = ("pull_request", "push")
# Jobs a merge or a publish waits for, by base name. Later CI stages keep or add
# to these names, so the same report compares before and after.
BLOCKING = {
    "pull_request": frozenset({
        "repository-hygiene", "lint", "scope", "swift-scope", "build-and-test", "build-ui-products",
        "scoped-ui-tests", "interruption-controls", "ui-test-gate", "ui-tests", "interruption", "gate",
    }),
    "push": frozenset({"repository-hygiene", "lint", "build-and-test", "ios-portability"}),
}
SLO_EXECUTION_SECONDS = 600
SLO_TOTAL_SECONDS = 1200
ACCEPTANCE_HEADS = 30
ACCEPTANCE_DAYS = 7
COHORTS = (
    "ordinary", "cache-exact", "cache-fallback", "cache-miss", "cache-rejected", "cache-cold-policy",
    "toolchain-deps", "xcode-pin", "interruption", "docs-only", "core-change", "app-change", "ui-selected",
    "files-unknown",
)
# Only these two leave the SLO; a dependency bump, a docs head or a cache miss still counts.
SLO_EXEMPT = frozenset({"xcode-pin", "interruption"})
# Fixed here so the cohort stays comparable across changes to what the test scope narrows.
DOCS_ONLY_PREFIXES = ("docs/", "site/", "Tests/Tooling/", ".github/ISSUE_TEMPLATE/")
DEPENDENCY_FILES = frozenset({"Package.swift", "Package.resolved"})
XCODE_PIN_FILE = "scripts/verify-ci-toolchain.sh"
XCODE_PIN = re.compile(r"^[-+].*Xcode_\d", re.MULTILINE)
INFRASTRUCTURE_STEP = re.compile(
    r"^(Set up job|Complete job|Post |Run actions/|Verify fixed|Install checksum|Identify compatible|"
    r"Restore|Verify cached|Unpack|Archive|Publish|Preserve|Upload|Collect|Resolve the last|Explain the selection|"
    r"Check Swift cache|Save successful|Record |Create content-free)")
GATE_JOBS = frozenset({"ui-test-gate", "gate"})
RERUN_REFUSED_STEP = "Refuse to manufacture evidence on a rerun"
UI_LANE_FAILED_STEP = "Fail the lane when its evidence is not complete"
UI_RECEIPTS_STEP = "Collect the UI lane's receipts"
CAPACITY_ANNOTATION = "was not acquired by Runner"
LOG_TIMESTAMP = r"^\S+Z "
EXACT_HIT = re.compile(LOG_TIMESTAMP + r"Cache hit for: ", re.MULTILINE)
FALLBACK_HIT = re.compile(LOG_TIMESTAMP + r"Cache hit for restore-key: ", re.MULTILINE)
CACHE_MISS = re.compile(LOG_TIMESTAMP + r"Cache not found for input keys", re.MULTILINE)
# Main compiled cold behind a lookup-only probe until the build contract let it restore.
LOOKUP_ONLY = re.compile(LOG_TIMESTAMP + r"\s*lookup-only: true\s*$", re.MULTILINE)
# Anchored on the annotation: the log also echoes the workflow script that prints it.
CACHE_REJECTED = re.compile(LOG_TIMESTAMP + r"##\[warning\]Cached Swift build state failed freshness", re.MULTILINE)
BUILD_COMPLETE = re.compile(r"Build complete! \((\d+(?:\.\d+)?)s\)")
SWIFT_SCOPE = re.compile(LOG_TIMESTAMP + r"\s*PORTAVOZ_SWIFT_TEST_SCOPE: ?(.*)$", re.MULTILINE)
UI_SUMMARY = re.compile(LOG_TIMESTAMP + r"\s*SUMMARY: ?(.*)$", re.MULTILINE)
UI_TESTS = re.compile(LOG_TIMESTAMP + r"\s*TESTS: ?(.*)$", re.MULTILINE)
GATE_ADVISORY = re.compile(
    LOG_TIMESTAMP + r"##\[warning\](?:Known hosted UI infrastructure was unavailable|.*functional evidence remains unverified)",
    re.MULTILINE)
SUMMARY_LIMIT = 240
# Bump when a digest or a cached shape changes, or old answers keep being served.
CACHE_VERSION = 3
MISSING_BUILD_LOG = {"cache": "log-unavailable", "compile_s": None, "swift_scope": None}
MISSING_SCOPE_LOG = {"summary": None, "selectors": None}
MISSING_GATE_LOG = {"advisory": False}
WORKERS = 8


class ReportError(RuntimeError):
    pass


class NotFound(ReportError):
    pass


def parse_time(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def seconds_between(start: str | None, end: str | None) -> int | None:
    first, last = parse_time(start), parse_time(end)
    if first is None or last is None:
        return None
    return max(0, round((last - first).total_seconds()))


def base_name(job_name: str) -> str:
    return job_name.split(" (", 1)[0]


def distribution(values: Iterable[int | None]) -> dict[str, int] | None:
    present = [value for value in values if value is not None]
    if not present:
        return None
    return {"n": len(present), "p50": percentile(present, 0.50), "p90": percentile(present, 0.90),
            "p95": percentile(present, 0.95), "max": max(present)}


def declared_timeouts(paths: Iterable[Path] = WORKFLOW_FILES) -> dict[str, int]:
    """A pull request's `timeout-minutes` by job id, read as text to stay stdlib-only."""
    timeouts: dict[str, int] = {}
    for path in paths:
        job = None
        for line in path.read_text(encoding="utf-8").splitlines():
            if declared := re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line):
                job = declared.group(1)
            elif job and (limit := re.match(r"^    timeout-minutes: (?:\$\{\{.*\|\| )?(\d+)(?: \}\})?\s*$", line)):
                timeouts[job] = int(limit.group(1))
    return timeouts


def build_log_digest(log: str) -> dict[str, Any]:
    if LOOKUP_ONLY.search(log):
        cache = "cold-policy"
    elif CACHE_REJECTED.search(log):
        cache = "rejected"
    elif FALLBACK_HIT.search(log):
        cache = "fallback"
    elif EXACT_HIT.search(log):
        cache = "exact"
    elif CACHE_MISS.search(log):
        cache = "miss"
    else:
        cache = "unknown"
    compile_seconds = BUILD_COMPLETE.search(log)
    scope = SWIFT_SCOPE.search(log)
    return {
        "cache": cache,
        "compile_s": round(float(compile_seconds.group(1))) if compile_seconds else None,
        "swift_scope": None if scope is None else ("contract-only" if scope.group(1).strip() else "full"),
    }


def scope_log_digest(log: str) -> dict[str, Any]:
    summary = UI_SUMMARY.search(log)
    tests = UI_TESTS.search(log)
    return {
        "summary": summary.group(1).strip()[:SUMMARY_LIMIT] if summary else None,
        "selectors": len(tests.group(1).split()) if tests else 0,
    }


def gate_log_digest(log: str) -> dict[str, Any]:
    return {"advisory": bool(GATE_ADVISORY.search(log))}


def ran_in_attempt(job: dict[str, Any], attempt_start: str | None) -> bool:
    # A rerun lists the jobs it reused with their original timestamps.
    start, completed = parse_time(attempt_start), parse_time(job.get("completed_at"))
    return start is None or completed is None or completed >= start


def job_row(job: dict[str, Any], *, workflow: str, carried: bool) -> dict[str, Any]:
    labels = job.get("labels") or []
    started = job.get("runner_name") is not None
    return {
        "name": job["name"],
        "workflow": workflow,
        "id": job["id"],
        "conclusion": job.get("conclusion"),
        "created_at": job.get("created_at"),
        "started_at": job.get("started_at"),
        "completed_at": job.get("completed_at"),
        "queue_s": seconds_between(job.get("created_at"), job.get("started_at")) if started else None,
        "duration_s": seconds_between(job.get("started_at"), job.get("completed_at")) if started else None,
        "runner": next((label.split("-")[0] for label in labels if label.startswith(("macos", "ubuntu"))), None),
        "failed_steps": [step["name"] for step in job.get("steps") or [] if step.get("conclusion") == "failure"],
        "carried": carried,
    }


def critical_path(jobs: Sequence[dict[str, Any]]) -> list[str]:
    """Walk back from the last job through whichever job's end released it."""
    finished = [job for job in jobs if job["duration_s"] is not None]
    if not finished:
        return []
    current = max(finished, key=lambda job: parse_time(job["completed_at"]))
    # `needs` never crosses workflows, so a simultaneous end in the other one releases nothing.
    pending = [job for job in finished if job["workflow"] == current["workflow"]]
    path = [current["name"]]
    while True:
        released = parse_time(current["created_at"])
        earlier = [job for job in pending if job is not current and parse_time(job["completed_at"]) <= released]
        previous = max(earlier, key=lambda job: parse_time(job["completed_at"]), default=None)
        if previous is None or (released - parse_time(previous["completed_at"])).total_seconds() > 5:
            return path[::-1]
        path.append(previous["name"])
        current = previous


def classify_outcome(jobs: Sequence[dict[str, Any]], *, timeouts: dict[str, int], superseded: bool,
                     run_cancelled: bool, advisory: bool, capacity: bool) -> str:
    """Name why an attempt ended: passed, or the most actionable failure."""
    failed, cancelled = [], []
    for job in jobs:
        conclusion = job["conclusion"]
        limit = timeouts.get(base_name(job["name"]))
        # GitHub reports most job timeouts as cancelled; only a limit reached with no newer run proves one.
        if conclusion == "timed_out" or (conclusion == "cancelled" and not superseded and limit
                                         and job["duration_s"] is not None and job["duration_s"] >= limit * 60 - 60):
            return "timeout"
        if conclusion == "failure":
            failed.append(job)
        elif conclusion == "cancelled":
            cancelled.append(job)
    # A gate fails when a job it needs failed or was cancelled; that names no cause of its own.
    causes = [job for job in failed if base_name(job["name"]) not in GATE_JOBS]
    if causes or cancelled:
        failed = causes
    if failed:
        steps = {step for job in failed for step in job["failed_steps"]}
        if steps == {RERUN_REFUSED_STEP}:
            return "rerun-refused"
        if UI_RECEIPTS_STEP in steps or (advisory and steps <= {UI_LANE_FAILED_STEP}):
            return "infrastructure"
        if steps and not all(INFRASTRUCTURE_STEP.match(step) for step in steps):
            return "product"
        return "infrastructure"
    if capacity:
        return "infrastructure"
    if cancelled or run_cancelled:
        return "superseded" if superseded else "cancelled"
    return "infrastructure" if advisory else "passed"


@dataclass
class HeadChanges:
    files: list[str] | None = None
    xcode_pin: bool = False


def docs_only(path: str) -> bool:
    return path == "LICENSE" or path.startswith(DOCS_ONLY_PREFIXES) or ("/" not in path and path.endswith(".md"))


def change_cohorts(changes: HeadChanges) -> set[str]:
    if changes.files is None:
        return {"files-unknown"}
    cohorts: set[str] = set()
    if changes.xcode_pin or XCODE_PIN_FILE in changes.files:
        cohorts |= {"xcode-pin", "toolchain-deps"}
    if DEPENDENCY_FILES.intersection(changes.files):
        cohorts.add("toolchain-deps")
    if changes.files and all(docs_only(path) for path in changes.files):
        cohorts.add("docs-only")
    if any(path.startswith("Sources/PortavozCore/") for path in changes.files):
        cohorts.add("core-change")
    if any(path.startswith("Sources/portavoz-app/") for path in changes.files):
        cohorts.add("app-change")
    return cohorts


@dataclass
class RunAttempt:
    workflow: str
    run: dict[str, Any]
    attempt: dict[str, Any]
    jobs: list[dict[str, Any]]
    number: int = 1

    @property
    def start(self) -> str | None:
        return self.attempt.get("run_started_at") or self.run.get("created_at")


@dataclass
class HeadAttempt:
    event: str
    head_sha: str
    branch: str
    number: int
    runs: list[RunAttempt] = field(default_factory=list)

    def fresh_jobs(self) -> list[dict[str, Any]]:
        """The raw jobs this attempt really ran; a reused job says nothing about it."""
        return [job for run in self.runs for job in run.jobs if ran_in_attempt(job, run.start)]


def attempt_cohorts(head: HeadAttempt, changes: HeadChanges, cache: str | None,
                    fresh: Sequence[dict[str, Any]]) -> list[str]:
    def ran(*names: str) -> bool:
        return any(base_name(row["name"]) in names and row["duration_s"] is not None for row in fresh)

    cohorts = change_cohorts(changes)
    if cache in {"exact", "fallback", "miss", "rejected", "cold-policy"}:
        cohorts.add(f"cache-{cache}")
    if ran("interruption-controls", "interruption"):
        cohorts.add("interruption")
    if ran("build-ui-products", "scoped-ui-tests", "ui-tests"):
        cohorts.add("ui-selected")
    if head.event == "pull_request" and not cohorts & SLO_EXEMPT:
        cohorts.add("ordinary")
    return sorted(cohorts)


def suite_seconds(head: HeadAttempt) -> int | None:
    step = next((step for job in head.fresh_jobs() if base_name(job["name"]) == "build-and-test"
                 for step in job.get("steps") or [] if step["name"].startswith("Current-SDK build")), None)
    return seconds_between(step.get("started_at"), step.get("completed_at")) if step else None


def attempt_row(head: HeadAttempt, *, changes: HeadChanges, build: dict[str, Any] | None,
                scope: dict[str, Any] | None, timeouts: dict[str, int], superseded: bool,
                advisory: bool = False, capacity: bool = False) -> dict[str, Any]:
    build = build or {}
    rows = [job_row(job, workflow=run.workflow, carried=not ran_in_attempt(job, run.start))
            for run in head.runs for job in run.jobs]
    fresh = [row for row in rows if not row["carried"]]
    blocking = [row for row in fresh if base_name(row["name"]) in BLOCKING[head.event]]
    timed = [row for row in blocking if row["duration_s"] is not None]
    longest = max(timed, key=lambda row: row["duration_s"], default=None)
    start = min((run.start for run in head.runs), key=parse_time, default=None)
    end = max((row["completed_at"] for row in timed), key=parse_time, default=None)
    suite, compile_s = suite_seconds(head), build.get("compile_s")
    return {
        "event": head.event,
        "head_sha": head.head_sha,
        "branch": head.branch,
        "attempt": head.number,
        "runs": [{"workflow": run.workflow, "run_id": run.run["id"], "run_attempt": run.number,
                  "conclusion": run.attempt.get("conclusion")} for run in head.runs],
        "start": start,
        "t_execution_s": longest["duration_s"] if longest else None,
        "t_total_s": seconds_between(start, end),
        "longest_job": longest["name"] if longest else None,
        "critical_path": critical_path(blocking),
        "outcome": classify_outcome(blocking, timeouts=timeouts, superseded=superseded, advisory=advisory,
                                    capacity=capacity,
                                    run_cancelled=any(run.attempt.get("conclusion") == "cancelled" for run in head.runs)),
        "cache": build.get("cache"),
        "compile_s": compile_s,
        "test_s": max(0, suite - compile_s) if suite is not None and compile_s is not None else None,
        "swift_scope": build.get("swift_scope"),
        "ui_selection": scope,
        "cohorts": attempt_cohorts(head, changes, build.get("cache"), fresh),
        "jobs": rows,
    }


def was_superseded(head: HeadAttempt, branch_runs: Sequence[str]) -> bool:
    """A new run on a pull request cancels the old one, so it must appear while the old one ran."""
    if head.event != "pull_request":
        return False
    starts = [parse_time(run.start) for run in head.runs]
    ends = [parse_time(job["completed_at"]) for run in head.runs for job in run.jobs if job.get("completed_at")]
    # A run cancelled before any job started has only its own end.
    ends = ends or [parse_time(run.attempt["updated_at"]) for run in head.runs if run.attempt.get("updated_at")]
    if not starts or not ends:
        return False
    start, end = min(starts), max(ends)
    return any(start < created <= end for created in map(parse_time, branch_runs))


def metric_block(rows: Sequence[dict[str, Any]]) -> dict[str, Any] | None:
    if not rows:
        return None
    return {"attempts": len(rows), "t_execution": distribution(row["t_execution_s"] for row in rows),
            "t_total": distribution(row["t_total_s"] for row in rows)}


def slo_status(block: dict[str, Any] | None) -> dict[str, Any]:
    if not block or not block["t_execution"] or not block["t_total"]:
        return {"execution_met": None, "total_met": None}
    return {"execution_met": block["t_execution"]["p95"] <= SLO_EXECUTION_SECONDS,
            "total_met": block["t_total"]["p95"] <= SLO_TOTAL_SECONDS}


def event_summary(event: str, scoped: Sequence[dict[str, Any]]) -> dict[str, Any]:
    # A superseded attempt never finished; a timeout or failure still counts.
    included = [row for row in scoped if row["outcome"] != "superseded"]
    by_critical: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
    by_job: defaultdict[str, list[int]] = defaultdict(list)
    by_runner: defaultdict[str, list[int]] = defaultdict(list)
    for row in included:
        if row["critical_path"]:
            by_critical[" > ".join(base_name(name) for name in row["critical_path"])].append(row)
        for job in row["jobs"]:
            if job["carried"]:
                continue
            if job["duration_s"] is not None and base_name(job["name"]) in BLOCKING[event]:
                by_job[base_name(job["name"])].append(job["duration_s"])
            if job["queue_s"] is not None and job["runner"]:
                by_runner[job["runner"]].append(job["queue_s"])
    starts = [parse_time(row["start"]) for row in included if row["start"]]
    ordinary = [row for row in included if "ordinary" in row["cohorts"]]
    ordinary_heads = {row["head_sha"] for row in ordinary}
    span_days = round((max(starts) - min(starts)).total_seconds() / 86400, 1) if starts else 0
    overall = metric_block(included)
    return {
        "heads": len({row["head_sha"] for row in scoped}),
        "attempts": len(scoped),
        "span_days": span_days,
        "outcomes": dict(sorted(Counter(row["outcome"] for row in scoped).items())),
        "cache_states": dict(sorted(Counter(row["cache"] or "not-run" for row in included).items())),
        "overall": overall,
        "cohorts": {name: metric_block([row for row in included if name in row["cohorts"]]) for name in COHORTS},
        "critical_paths": {name: metric_block(group) for name, group in sorted(by_critical.items())},
        "jobs": {name: distribution(values) for name, values in sorted(by_job.items())},
        "queue": {name: distribution(values) for name, values in sorted(by_runner.items())},
        "ui_selectors": distribution((row["ui_selection"] or {}).get("selectors") for row in included
                                     if "ui-selected" in row["cohorts"]),
        "compile_s": distribution(row["compile_s"] for row in included),
        "test_s": distribution(row["test_s"] for row in included),
        "slo": slo_status(metric_block(ordinary) if event == "pull_request" else overall),
        "acceptance": {
            "ordinary_heads": len(ordinary_heads), "required_heads": ACCEPTANCE_HEADS,
            "span_days": span_days, "required_days": ACCEPTANCE_DAYS,
            "met": len(ordinary_heads) >= ACCEPTANCE_HEADS and span_days >= ACCEPTANCE_DAYS,
        },
    }


def summarize(rows: Sequence[dict[str, Any]]) -> dict[str, Any]:
    return {event: event_summary(event, [row for row in rows if row["event"] == event]) for event in EVENTS}


def clock(seconds: int | None) -> str:
    return "-" if seconds is None else f"{seconds // 60}:{seconds % 60:02d}"


def distribution_cells(values: dict[str, int] | None) -> str:
    if not values:
        return "- | - | - | -"
    return " | ".join(clock(values[key]) for key in ("p50", "p90", "p95", "max"))


def metric_table(title: str, blocks: dict[str, dict[str, Any] | None]) -> list[str]:
    lines = [f"### {title}", "", "| Group | N | Exec p50 | p90 | p95 | max | Total p50 | p90 | p95 | max |",
             "|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|"]
    for name, block in blocks.items():
        if block is None:
            lines.append(f"| {name} | 0 | no evidence | | | | | | | |")
        else:
            lines.append(f"| {name} | {block['attempts']} | {distribution_cells(block['t_execution'])} | "
                         f"{distribution_cells(block['t_total'])} |")
    return [*lines, ""]


def distribution_table(title: str, label: str, values: dict[str, dict[str, int] | None]) -> list[str]:
    lines = [f"### {title}", "", f"| {label} | N | p50 | p90 | p95 | max |", "|---|--:|--:|--:|--:|--:|"]
    lines += [f"| {name} | {entry['n'] if entry else 0} | {distribution_cells(entry)} |" for name, entry in values.items()]
    return [*lines, ""]


def met_label(value: bool | None) -> str:
    return "no evidence" if value is None else "met" if value else "missed"


def event_section(event: str, data: dict[str, Any]) -> list[str]:
    if not data["attempts"]:
        return ["no evidence", ""]
    lines = [f"{data['heads']} heads, {data['attempts']} attempts over {data['span_days']} days.",
             f"SLO on {'ordinary heads' if event == 'pull_request' else 'all heads'}: execution p95 "
             f"{met_label(data['slo']['execution_met'])} (limit {clock(SLO_EXECUTION_SECONDS)}), total p95 "
             f"{met_label(data['slo']['total_met'])} (limit {clock(SLO_TOTAL_SECONDS)})."]
    if event == "pull_request":
        acceptance = data["acceptance"]
        lines.append(f"Acceptance window: {acceptance['ordinary_heads']} of {ACCEPTANCE_HEADS} ordinary heads, "
                     f"{acceptance['span_days']} of {ACCEPTANCE_DAYS} days: {'met' if acceptance['met'] else 'not met'}.")
    lines += ["", "### Outcomes", ""]
    lines += [f"- {name}: {count}" for name, count in data["outcomes"].items()]
    lines += ["", "### Cache states", ""]
    lines += [f"- {name}: {count}" for name, count in data["cache_states"].items()]
    lines.append("")
    lines += metric_table("Cohorts", {"all": data["overall"], **data["cohorts"]})
    lines += metric_table("Critical paths", data["critical_paths"])
    lines += distribution_table("Blocking jobs", "Job", data["jobs"])
    lines += distribution_table("Queue by runner", "Runner", data["queue"])
    lines += distribution_table("build-and-test phases", "Phase", {"compile": data["compile_s"], "test": data["test_s"]})
    selectors = data["ui_selectors"]
    # Scope names every candidate; the job cuts some of them, and its lane receipt says which.
    lines += [f"UI candidates per selected attempt: p50 {selectors['p50']}, p90 {selectors['p90']}, "
              f"max {selectors['max']} (N {selectors['n']})." if selectors else "UI candidates: no evidence.", ""]
    return lines


def render_markdown(report: dict[str, Any]) -> str:
    window = report["window"]
    lines = ["# CI time report", "", f"Repository `{window['repository']}`; last {window['heads']} heads per event"
             f"{'; until ' + window['until'] if window['until'] else ''}.",
             "Execution is the longest blocking job of an attempt; total runs from attempt start to the last blocking "
             "job. Cohorts overlap. Superseded attempts are counted but not measured.", ""]
    for event in EVENTS:
        lines += [f"## {event}", "", *event_section(event, report["summary"][event])]
    return "\n".join(lines)


class GitHub:
    """Read-only `gh api` client with a disk cache for finished, immutable answers."""

    def __init__(self, repository: str, cache_dir: Path | None) -> None:
        self.repository = repository
        self.cache_dir = cache_dir

    def _run(self, path: str) -> str:
        for delay in (2, 4, 8, 0):
            result = subprocess.run(["gh", "api", "--allow-escape-sequences", path], capture_output=True,
                                    text=True, errors="replace", timeout=180, check=False)
            if result.returncode == 0:
                return result.stdout
            if any(f"HTTP {code}" in result.stderr for code in (404, 410, 422)):
                raise NotFound(f"gh api {path}: {result.stderr.strip()}")
            time.sleep(delay)
        raise ReportError(f"gh api {path}: {result.stderr.strip()}")

    def get(self, path: str) -> Any:
        return json.loads(self._run(f"repos/{self.repository}/{path}"))

    def cached(self, name: str, produce: Callable[[], dict[str, Any]]) -> dict[str, Any]:
        if self.cache_dir is None:
            return produce()
        digest = hashlib.sha256(f"{CACHE_VERSION}-{name}".encode()).hexdigest()
        path = self.cache_dir / f"{digest}.json"
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
        value = produce()
        write_receipt(path, value)
        return value

    def log(self, job_id: int) -> str | None:
        try:
            return self._run(f"repos/{self.repository}/actions/jobs/{job_id}/logs")
        except NotFound:
            return None

    def annotations(self, job_id: int) -> list[str]:
        def produce() -> dict[str, Any]:
            try:
                return {"messages": [entry.get("message") or "" for entry in self.get(f"check-runs/{job_id}/annotations")]}
            except NotFound:
                return {"messages": []}

        return self.cached(f"annotations-{job_id}", produce)["messages"]

    def workflow_runs(self, workflow: str, event: str, page: int) -> list[dict[str, Any]]:
        return self.get(f"actions/workflows/{workflow}/runs?event={event}&per_page=100&page={page}")["workflow_runs"]

    def head_runs(self, sha: str) -> list[dict[str, Any]]:
        return self.get(f"actions/runs?head_sha={sha}&per_page=100")["workflow_runs"]

    def attempt(self, run: dict[str, Any], number: int) -> dict[str, Any]:
        return self.cached(f"attempt-{run['id']}-{number}", lambda: self._attempt(run, number))

    def _attempt(self, run: dict[str, Any], number: int) -> dict[str, Any]:
        # The run object already describes its latest attempt, the only one most runs have.
        attempt = run if number == run["run_attempt"] else self.get(f"actions/runs/{run['id']}/attempts/{number}")
        jobs = self.get(f"actions/runs/{run['id']}/attempts/{number}/jobs?per_page=100")["jobs"]
        kept = ("run_started_at", "updated_at", "conclusion")
        return {"attempt": {key: attempt.get(key) for key in kept}, "jobs": jobs}

    def changes(self, event: str, sha: str, branch: str) -> dict[str, Any]:
        return self.cached(f"changes-{event}-{sha}", lambda: self._changes(event, sha, branch))

    def _changes(self, event: str, sha: str, branch: str) -> dict[str, Any]:
        if event == "push":
            candidates = [f"commits/{sha}"]
        else:
            # Three dots stay on the fork point, so a later squash on the base changes nothing.
            candidates = [f"compare/{base}...{sha}" for base in dict.fromkeys(self._pull_bases(sha, branch))]
        for path in candidates:
            try:
                files = self.get(path).get("files") or []
            except NotFound:
                continue
            workflow_patches = "".join(entry.get("patch") or "" for entry in files
                                       if entry["filename"].startswith(".github/workflows/"))
            return {"files": [entry["filename"] for entry in files],
                    "xcode_pin": bool(XCODE_PIN.search(workflow_patches))}
        return {"files": None, "xcode_pin": False}

    def _pull_bases(self, sha: str, branch: str) -> list[str]:
        try:
            pulls = self.get(f"commits/{sha}/pulls")
        except NotFound:
            pulls = []
        return [pull["base"]["ref"] for pull in pulls if pull["head"]["ref"] == branch] + ["main"]


def past_time(value: str) -> str:
    try:
        moment = parse_time(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"not an ISO time: {value}") from error
    if moment is None or moment.tzinfo is None:
        raise argparse.ArgumentTypeError(f"needs a timezone: {value}")
    # Runs still in flight at a future moment would change the report between two reads.
    if moment > datetime.now(timezone.utc):
        raise argparse.ArgumentTypeError(f"must be in the past: {value}")
    return value


def within(moment: str | None, until: str | None) -> bool:
    return until is None or moment is None or parse_time(moment) <= parse_time(until)


def latest_heads(client: GitHub, event: str, count: int,
                 until: str | None) -> tuple[list[dict[str, Any]], dict[str, list[str]]]:
    """The newest finished heads of the event, and the creation times of each branch's runs."""
    heads: dict[str, dict[str, Any]] = {}
    branch_runs: dict[str, list[str]] = {}
    for page in range(1, 21):
        runs = client.workflow_runs("ci.yml", event, page)
        for run in runs:
            # Later runs stay visible: the run that cancelled a pinned attempt may fall after `until`.
            branch_runs.setdefault(run["head_branch"], []).append(run["created_at"])
            if (run["status"] == "completed" and within(run["created_at"], until)
                    and run["head_sha"] not in heads and len(heads) < count):
                heads[run["head_sha"]] = run
        if len(heads) >= count or len(runs) < 100:
            break
    return list(heads.values()), branch_runs


def group_attempts(client: GitHub, event: str, head: dict[str, Any], runs: Sequence[dict[str, Any]],
                   wanted: dict[str, str], until: str | None) -> list[HeadAttempt]:
    # Attempts are numbered across every run of a workflow, so a reopened head keeps its first run.
    attempts: dict[int, HeadAttempt] = {}
    ordinals: Counter[str] = Counter()
    for run in sorted(runs, key=lambda run: parse_time(run["created_at"])):
        workflow = wanted[run["path"]]
        for number in range(1, run["run_attempt"] + 1):
            data = client.attempt(run, number)
            if not within(data["attempt"]["run_started_at"], until):
                continue
            ordinals[workflow] += 1
            ordinal = ordinals[workflow]
            if ordinal not in attempts:
                attempts[ordinal] = HeadAttempt(event, head["head_sha"], head["head_branch"], ordinal)
            attempts[ordinal].runs.append(RunAttempt(workflow, run, data["attempt"], data["jobs"], number))
    return [attempts[ordinal] for ordinal in sorted(attempts)]


def head_rows(client: GitHub, event: str, head: dict[str, Any], branch_runs: dict[str, list[str]],
              timeouts: dict[str, int], until: str | None) -> list[dict[str, Any]]:
    sha, branch = head["head_sha"], head["head_branch"]
    wanted = {f".github/workflows/{name}": name for name in WORKFLOWS}
    runs = [run for run in client.head_runs(sha) if run.get("event") == event and run.get("path") in wanted
            and within(run["created_at"], until)]
    # A head counts once every workflow finished, or its critical path would be cut short.
    if any(run.get("status") != "completed" for run in runs):
        return []
    changes = HeadChanges(**client.changes(event, sha, branch))
    rows = []
    for attempt in group_attempts(client, event, head, runs, wanted, until):
        gate = (_digest(client, attempt, "gate", gate_log_digest, MISSING_GATE_LOG)
                or _digest(client, attempt, "ui-test-gate", gate_log_digest, MISSING_GATE_LOG))
        rows.append(attempt_row(
            attempt, changes=changes, timeouts=timeouts,
            build=_digest(client, attempt, "build-and-test", build_log_digest, MISSING_BUILD_LOG),
            scope=_digest(client, attempt, "scope", scope_log_digest, MISSING_SCOPE_LOG),
            superseded=was_superseded(attempt, branch_runs.get(branch, [])),
            advisory=bool(gate and gate["advisory"]),
            capacity=_lacked_capacity(client, attempt, event)))
    return rows


def _lacked_capacity(client: GitHub, attempt: HeadAttempt, event: str) -> bool:
    # GitHub reports a job no runner ever took as a plain cancel; only its annotation says why.
    return any(CAPACITY_ANNOTATION in message for job in attempt.fresh_jobs()
               if job.get("conclusion") == "cancelled" and base_name(job["name"]) in BLOCKING[event]
               for message in client.annotations(job["id"]))


def _digest(client: GitHub, attempt: HeadAttempt, job_name: str, digest: Callable[[str], dict[str, Any]],
            missing: dict[str, Any]) -> dict[str, Any] | None:
    job = next((job for job in attempt.fresh_jobs() if job["name"] == job_name and job.get("runner_name")), None)
    if job is None:
        return None

    def produce() -> dict[str, Any]:
        log = client.log(job["id"])
        return missing if log is None else digest(log)

    return client.cached(f"{job_name}-{job['id']}", produce)


def collect(client: GitHub, count: int, until: str | None) -> list[dict[str, Any]]:
    timeouts = {**RETIRED_TIMEOUTS, **declared_timeouts()}
    rows: list[dict[str, Any]] = []
    for event in EVENTS:
        heads, branch_runs = latest_heads(client, event, count, until)
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            for result in pool.map(lambda head: head_rows(client, event, head, branch_runs, timeouts, until), heads):
                rows.extend(result)
    return rows


def build_report(rows: Sequence[dict[str, Any]], *, repository: str, heads: int, until: str | None) -> dict[str, Any]:
    return {"window": {"repository": repository, "heads": heads, "until": until}, "summary": summarize(rows),
            "attempts": list(rows)}


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=REPOSITORY)
    parser.add_argument("--heads", type=int, default=50, help="newest finished heads per event")
    parser.add_argument("--until", type=past_time,
                        help="past ISO time with a timezone; only runs started at or before it, to pin the window")
    parser.add_argument("--cache-dir", type=Path, default=ROOT / "dist/ci-time-report-cache",
                        help="answers for finished attempts, so repeated reports are cheap")
    parser.add_argument("--json", type=Path, dest="json_path", help="write the full report with every attempt")
    parser.add_argument("--summary-json", type=Path, help="write only the window and the summary, for a baseline")
    arguments = parser.parse_args(argv)
    try:
        client = GitHub(arguments.repository, arguments.cache_dir)
        rows = collect(client, arguments.heads, arguments.until)
    except (ReportError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f"ci_time_report: {error}", file=sys.stderr)
        return 1
    report = build_report(rows, repository=arguments.repository, heads=arguments.heads, until=arguments.until)
    if arguments.json_path:
        arguments.json_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if arguments.summary_json:
        compact = {"window": report["window"], "summary": report["summary"]}
        arguments.summary_json.write_text(json.dumps(compact, indent=2) + "\n", encoding="utf-8")
    print(render_markdown(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
