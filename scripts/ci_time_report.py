#!/usr/bin/env python3
"""Report hosted CI time per head, attempt, cohort and critical path.

Reads GitHub run metadata and job logs through `gh api`; it never checks out or
runs anything from the heads it measures. `--until` pins the window, so the same
command reproduces a recorded baseline while GitHub retains the logs (90 days).
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import time
from typing import Any, Callable, Iterable, Sequence

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from swift_test_scope import contract_only  # noqa: E402

REPOSITORY = "johnny4young/portavoz"
WORKFLOWS = ("ci.yml", "ui-tests.yml")
WORKFLOW_FILES = tuple(ROOT / ".github/workflows" / name for name in WORKFLOWS)
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
    "toolchain-deps", "interruption", "docs-only", "core-change", "app-change", "ui-selected", "files-unknown",
)
TOOLCHAIN_FILES = frozenset({"Package.swift", "Package.resolved", "scripts/verify-ci-toolchain.sh"})
XCODE_PIN = re.compile(r"^[-+].*Xcode_\d", re.MULTILINE)
INFRASTRUCTURE_STEP = re.compile(
    r"^(Set up job|Complete job|Post |Run actions/|Verify fixed|Install checksum|Identify compatible|"
    r"Restore|Verify cached|Unpack|Archive|Publish|Preserve|Upload|Collect)")
GATE_JOBS = frozenset({"ui-test-gate", "gate"})
RERUN_REFUSED_STEP = "Refuse to manufacture evidence on a rerun"
LOG_TIMESTAMP = r"^\S+Z "
EXACT_HIT = re.compile(LOG_TIMESTAMP + r"Cache hit for: ", re.MULTILINE)
FALLBACK_HIT = re.compile(LOG_TIMESTAMP + r"Cache hit for restore-key: ", re.MULTILINE)
CACHE_MISS = re.compile(LOG_TIMESTAMP + r"Cache not found for input keys", re.MULTILINE)
LOOKUP_ONLY = re.compile(LOG_TIMESTAMP + r"Cache found and can be restored from key", re.MULTILINE)
# Anchored on the annotation: the log also echoes the workflow script that prints it.
CACHE_REJECTED = re.compile(LOG_TIMESTAMP + r"##\[warning\]Cached Swift build state failed freshness", re.MULTILINE)
BUILD_COMPLETE = re.compile(r"Build complete! \((\d+(?:\.\d+)?)s\)")
SWIFT_SCOPE = re.compile(LOG_TIMESTAMP + r"\s*PORTAVOZ_SWIFT_TEST_SCOPE: ?(.*)$", re.MULTILINE)
UI_SUMMARY = re.compile(LOG_TIMESTAMP + r"\s*SUMMARY: ?(.*)$", re.MULTILINE)
UI_TESTS = re.compile(LOG_TIMESTAMP + r"\s*TESTS: ?(.*)$", re.MULTILINE)
SUMMARY_LIMIT = 240


class ReportError(RuntimeError):
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


def nearest_rank(values: Sequence[int], percentile: int) -> int:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(percentile / 100 * len(ordered)) - 1)]


def distribution(values: Iterable[int | None]) -> dict[str, int] | None:
    present = [value for value in values if value is not None]
    if not present:
        return None
    return {"n": len(present), "p50": nearest_rank(present, 50), "p90": nearest_rank(present, 90),
            "p95": nearest_rank(present, 95), "max": max(present)}


def declared_timeouts(paths: Iterable[Path] = WORKFLOW_FILES) -> dict[str, int]:
    """Job `timeout-minutes` by job id, read as text to stay stdlib-only."""
    timeouts: dict[str, int] = {}
    for path in paths:
        job = None
        for line in path.read_text(encoding="utf-8").splitlines():
            if declared := re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line):
                job = declared.group(1)
            elif job and (limit := re.match(r"^    timeout-minutes: (\d+)\s*$", line)):
                timeouts[job] = int(limit.group(1))
    return timeouts


def build_log_digest(log: str) -> dict[str, Any]:
    if CACHE_REJECTED.search(log):
        cache = "rejected"
    elif FALLBACK_HIT.search(log):
        cache = "fallback"
    elif EXACT_HIT.search(log):
        cache = "exact"
    elif LOOKUP_ONLY.search(log):
        cache = "cold-policy"
    elif CACHE_MISS.search(log):
        cache = "miss"
    else:
        cache = "unknown"
    compile_seconds = [float(match) for match in BUILD_COMPLETE.findall(log)]
    scope = SWIFT_SCOPE.search(log)
    return {
        "cache": cache,
        "compile_s": round(compile_seconds[0]) if compile_seconds else None,
        "swift_scope": None if scope is None else ("contract-only" if scope.group(1).strip() else "full"),
    }


def scope_log_digest(log: str) -> dict[str, Any]:
    summary = UI_SUMMARY.search(log)
    tests = UI_TESTS.search(log)
    return {
        "summary": summary.group(1).strip()[:SUMMARY_LIMIT] if summary else None,
        "selectors": len(tests.group(1).split()) if tests else 0,
    }


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
        "carried": carried,
    }


def critical_path(jobs: Sequence[dict[str, Any]]) -> list[str]:
    """Walk back from the last job through whichever job's end released it."""
    finished = [job for job in jobs if job["duration_s"] is not None and job["completed_at"]]
    if not finished:
        return []
    current = max(finished, key=lambda job: parse_time(job["completed_at"]))
    # `needs` never crosses workflows, so a simultaneous end in the other one releases nothing.
    pending = [job for job in finished if job["workflow"] == current["workflow"]]
    path = [current["name"]]
    while True:
        released = parse_time(current["created_at"])
        earlier = [job for job in pending if job is not current and parse_time(job["completed_at"]) <= released]
        if not earlier:
            return list(reversed(path))
        previous = max(earlier, key=lambda job: parse_time(job["completed_at"]))
        if (released - parse_time(previous["completed_at"])).total_seconds() > 5:
            return list(reversed(path))
        path.append(previous["name"])
        current = previous


def classify_outcome(jobs: Sequence[dict[str, Any]], raw_jobs: dict[int, dict[str, Any]], *,
                     timeouts: dict[str, int], superseded: bool) -> str:
    """Name why an attempt ended: passed, or the most actionable failure."""
    failed, cancelled, timed_out = [], [], False
    for job in jobs:
        conclusion = job["conclusion"]
        limit = timeouts.get(base_name(job["name"]))
        # GitHub reports most job timeouts as cancelled; only a limit reached with no newer run proves one.
        if conclusion == "timed_out" or (conclusion == "cancelled" and not superseded and limit
                                         and job["duration_s"] is not None and job["duration_s"] >= limit * 60 - 60):
            timed_out = True
        elif conclusion == "failure":
            failed.append(job)
        elif conclusion == "cancelled":
            cancelled.append(job)
    if timed_out:
        return "timeout"
    if cancelled:
        # A gate fails when a job it needs was cancelled; that names no failure of its own.
        failed = [job for job in failed if base_name(job["name"]) not in GATE_JOBS]
    if failed:
        steps = [step["name"] for job in failed for step in raw_jobs.get(job["id"], {}).get("steps") or []
                 if step.get("conclusion") == "failure"]
        if RERUN_REFUSED_STEP in steps and all(step == RERUN_REFUSED_STEP for step in steps):
            return "rerun-refused"
        if steps and not all(INFRASTRUCTURE_STEP.match(step) for step in steps):
            return "product"
        return "infrastructure"
    if cancelled:
        return "superseded" if superseded else "cancelled"
    return "passed"


@dataclass
class HeadChanges:
    files: list[str] | None = None
    xcode_pin: bool = False


def change_cohorts(changes: HeadChanges) -> set[str]:
    if changes.files is None:
        return {"files-unknown"}
    cohorts: set[str] = set()
    if changes.xcode_pin or TOOLCHAIN_FILES.intersection(changes.files):
        cohorts.add("toolchain-deps")
    if changes.files and all(contract_only(path) for path in changes.files):
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


@dataclass
class HeadAttempt:
    event: str
    head_sha: str
    branch: str
    number: int
    runs: list[RunAttempt] = field(default_factory=list)


def attempt_row(head: HeadAttempt, *, changes: HeadChanges, build: dict[str, Any] | None,
                scope: dict[str, Any] | None, timeouts: dict[str, int], superseded: bool) -> dict[str, Any]:
    blocking_names = BLOCKING[head.event]
    raw_jobs: dict[int, dict[str, Any]] = {}
    rows: list[dict[str, Any]] = []
    starts: list[str] = []
    for run in head.runs:
        start = run.attempt.get("run_started_at") or run.run.get("created_at")
        starts.append(start)
        for job in run.jobs:
            raw_jobs[job["id"]] = job
            rows.append(job_row(job, workflow=run.workflow, carried=not ran_in_attempt(job, start)))
    fresh = [row for row in rows if not row["carried"]]
    blocking = [row for row in fresh if base_name(row["name"]) in blocking_names]
    timed = [row for row in blocking if row["duration_s"] is not None]
    longest = max(timed, key=lambda row: row["duration_s"], default=None)
    start = min(starts, key=parse_time) if starts else None
    ended = [row["completed_at"] for row in timed if row["completed_at"]]
    end = max(ended, key=parse_time) if ended else None
    interruption = any(base_name(row["name"]) in {"interruption-controls", "interruption"}
                       and row["duration_s"] is not None for row in fresh)
    ui_ran = any(base_name(row["name"]) in {"build-ui-products", "scoped-ui-tests", "ui-tests"}
                 and row["duration_s"] is not None for row in fresh)
    cache = build["cache"] if build else None
    cohorts = change_cohorts(changes)
    # A main push compiles cold by policy, so its lookup-only probe says nothing about reuse.
    if head.event == "push" and cache:
        cohorts.add("cache-cold-policy")
    elif cache in {"exact", "fallback", "miss", "rejected"}:
        cohorts.add(f"cache-{cache}")
    if interruption:
        cohorts.add("interruption")
    if ui_ran:
        cohorts.add("ui-selected")
    if head.event == "pull_request" and not cohorts & {"toolchain-deps", "interruption", "docs-only"}:
        cohorts.add("ordinary")
    step = next((step for job in raw_jobs.values() if base_name(job["name"]) == "build-and-test"
                 for step in job.get("steps") or [] if step["name"].startswith("Current-SDK build")), None)
    suite = seconds_between(step.get("started_at"), step.get("completed_at")) if step else None
    compile_s = build.get("compile_s") if build else None
    expected = {"ci.yml"} if head.event == "push" else set(WORKFLOWS)
    return {
        "event": head.event,
        "head_sha": head.head_sha,
        "branch": head.branch,
        "attempt": head.number,
        "partial": bool(expected - {run.workflow for run in head.runs}),
        "runs": [{"workflow": run.workflow, "run_id": run.run["id"], "conclusion": run.attempt.get("conclusion")}
                 for run in head.runs],
        "start": start,
        "end": end,
        "t_execution_s": longest["duration_s"] if longest else None,
        "t_total_s": seconds_between(start, end),
        "longest_job": longest["name"] if longest else None,
        "critical_path": critical_path(blocking),
        "outcome": classify_outcome(blocking, raw_jobs, timeouts=timeouts, superseded=superseded),
        "cache": cache,
        "compile_s": compile_s,
        "test_s": max(0, suite - compile_s) if suite is not None and compile_s is not None else None,
        "swift_scope": build.get("swift_scope") if build else None,
        "ui_selection": scope,
        "cohorts": sorted(cohorts),
        "jobs": rows,
    }


def was_superseded(head: HeadAttempt, branch_runs: Sequence[str]) -> bool:
    """A new run on the branch cancels the old one, so it must appear while the old one ran."""
    starts = [parse_time(run.attempt.get("run_started_at") or run.run.get("created_at")) for run in head.runs]
    ends = [parse_time(job["completed_at"]) for run in head.runs for job in run.jobs if job.get("completed_at")]
    if not starts or not ends:
        return False
    start, end = min(starts), max(ends)
    return any(start < created <= end for created in map(parse_time, branch_runs))


def measured(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    # A superseded attempt never finished; a timeout or failure still counts.
    return [row for row in rows if row["outcome"] != "superseded"]


def metric_block(rows: Sequence[dict[str, Any]]) -> dict[str, Any] | None:
    if not rows:
        return None
    return {"attempts": len(rows), "t_execution": distribution(row["t_execution_s"] for row in rows),
            "t_total": distribution(row["t_total_s"] for row in rows)}


def queue_block(rows: Sequence[dict[str, Any]]) -> dict[str, Any]:
    by_runner: dict[str, list[int]] = {}
    for row in rows:
        for job in row["jobs"]:
            if not job["carried"] and job["queue_s"] is not None and job["runner"]:
                by_runner.setdefault(job["runner"], []).append(job["queue_s"])
    return {runner: distribution(values) for runner, values in sorted(by_runner.items())}


def summarize(rows: Sequence[dict[str, Any]]) -> dict[str, Any]:
    summary: dict[str, Any] = {}
    for event in EVENTS:
        scoped = [row for row in rows if row["event"] == event]
        heads = {row["head_sha"] for row in scoped}
        included = measured(scoped)
        by_critical: dict[str, list[dict[str, Any]]] = {}
        by_job: dict[str, list[int]] = {}
        for row in included:
            for job in row["jobs"]:
                if not job["carried"] and job["duration_s"] is not None and base_name(job["name"]) in BLOCKING[event]:
                    by_job.setdefault(base_name(job["name"]), []).append(job["duration_s"])
        for row in included:
            if row["critical_path"]:
                by_critical.setdefault(" > ".join(base_name(name) for name in row["critical_path"]), []).append(row)
        outcomes: dict[str, int] = {}
        for row in scoped:
            outcomes[row["outcome"]] = outcomes.get(row["outcome"], 0) + 1
        starts = [parse_time(row["start"]) for row in included if row["start"]]
        ordinary = [row for row in included if "ordinary" in row["cohorts"]]
        ordinary_heads = {row["head_sha"] for row in ordinary}
        span_days = round((max(starts) - min(starts)).total_seconds() / 86400, 1) if starts else 0
        overall = metric_block(included)
        reference = metric_block(ordinary) if event == "pull_request" else overall
        summary[event] = {
            "heads": len(heads),
            "attempts": len(scoped),
            "span_days": span_days,
            "outcomes": dict(sorted(outcomes.items())),
            "overall": overall,
            "cohorts": {name: metric_block([row for row in included if name in row["cohorts"]]) for name in COHORTS},
            "critical_paths": {name: metric_block(group) for name, group in sorted(by_critical.items())},
            "jobs": {name: distribution(values) for name, values in sorted(by_job.items())},
            "queue": queue_block(included),
            "ui_selectors": distribution((row["ui_selection"] or {}).get("selectors") for row in included
                                         if "ui-selected" in row["cohorts"]),
            "compile_s": distribution(row["compile_s"] for row in included),
            "test_s": distribution(row["test_s"] for row in included),
            "slo": slo_status(reference),
            "acceptance": {
                "ordinary_heads": len(ordinary_heads), "required_heads": ACCEPTANCE_HEADS,
                "span_days": span_days, "required_days": ACCEPTANCE_DAYS,
                "met": len(ordinary_heads) >= ACCEPTANCE_HEADS and span_days >= ACCEPTANCE_DAYS,
            },
        }
    return summary


def slo_status(block: dict[str, Any] | None) -> dict[str, Any]:
    if not block or not block["t_execution"] or not block["t_total"]:
        return {"execution_met": None, "total_met": None}
    return {"execution_met": block["t_execution"]["p95"] <= SLO_EXECUTION_SECONDS,
            "total_met": block["t_total"]["p95"] <= SLO_TOTAL_SECONDS}


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


def met_label(value: bool | None) -> str:
    return "no evidence" if value is None else "met" if value else "missed"


def render_markdown(report: dict[str, Any]) -> str:
    window = report["window"]
    lines = ["# CI time report", "", f"Repository `{window['repository']}`; last {window['heads']} heads per event"
             f"{'; until ' + window['until'] if window['until'] else ''}.",
             "Execution is the longest blocking job of an attempt; total runs from attempt start to the last blocking "
             "job. Cohorts overlap. Superseded attempts are counted but not measured.", ""]
    for event in EVENTS:
        data = report["summary"][event]
        if not data["attempts"]:
            lines += [f"## {event}", "", "no evidence", ""]
            continue
        lines += [f"## {event}", "",
                  f"{data['heads']} heads, {data['attempts']} attempts over {data['span_days']} days.",
                  f"SLO on {'ordinary heads' if event == 'pull_request' else 'all heads'}: execution p95 "
                  f"{met_label(data['slo']['execution_met'])} (limit {clock(SLO_EXECUTION_SECONDS)}), total p95 "
                  f"{met_label(data['slo']['total_met'])} (limit {clock(SLO_TOTAL_SECONDS)}).",
                  f"Acceptance window: {data['acceptance']['ordinary_heads']} of {ACCEPTANCE_HEADS} ordinary heads, "
                  f"{data['acceptance']['span_days']} of {ACCEPTANCE_DAYS} days: "
                  f"{'met' if data['acceptance']['met'] else 'not met'}.",
                  "", "### Outcomes", ""]
        lines += [f"- {name}: {count}" for name, count in data["outcomes"].items()]
        lines.append("")
        lines += metric_table("Cohorts", {"all": data["overall"], **data["cohorts"]})
        lines += metric_table("Critical paths", data["critical_paths"])
        lines += ["### Blocking jobs", "", "| Job | N | p50 | p90 | p95 | max |", "|---|--:|--:|--:|--:|--:|"]
        lines += [f"| {name} | {values['n']} | {distribution_cells(values)} |" for name, values in data["jobs"].items()]
        lines += ["", "### Queue by runner", "", "| Runner | N | p50 | p90 | p95 | max |", "|---|--:|--:|--:|--:|--:|"]
        lines += [f"| {runner} | {values['n']} | {distribution_cells(values)} |"
                  for runner, values in data["queue"].items()]
        lines += ["", "### build-and-test phases", "", "| Phase | N | p50 | p90 | p95 | max |",
                  "|---|--:|--:|--:|--:|--:|"]
        for phase in ("compile_s", "test_s"):
            values = data[phase]
            lines.append(f"| {phase[:-2]} | {values['n'] if values else 0} | {distribution_cells(values)} |")
        selectors = data["ui_selectors"]
        lines += ["", f"UI selectors per selected attempt: p50 {selectors['p50']}, p90 {selectors['p90']}, "
                  f"max {selectors['max']} (N {selectors['n']})." if selectors else "UI selectors: no evidence.", ""]
    return "\n".join(lines)


class GitHub:
    """Read-only `gh api` client with a disk cache for finished, immutable answers."""

    def __init__(self, repository: str, cache_dir: Path | None) -> None:
        self.repository = repository
        self.cache_dir = cache_dir

    def _run(self, path: str) -> str:
        delay = 2
        for attempt in range(4):
            result = subprocess.run(["gh", "api", "--allow-escape-sequences", path], capture_output=True,
                                    text=True, errors="replace", timeout=180, check=False)
            if result.returncode == 0:
                return result.stdout
            if "HTTP 404" in result.stderr or "HTTP 410" in result.stderr or attempt == 3:
                raise ReportError(f"gh api {path}: {result.stderr.strip()}")
            time.sleep(delay)
            delay *= 2
        raise ReportError(f"gh api {path}: exhausted retries")

    def get(self, path: str) -> Any:
        return json.loads(self._run(f"repos/{self.repository}/{path}"))

    def cached(self, name: str, produce: Callable[[], Any]) -> Any:
        if self.cache_dir is None:
            return produce()
        path = self.cache_dir / f"{hashlib.sha256(name.encode()).hexdigest()}.json"
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
        value = produce()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")
        return value

    def log(self, job_id: int) -> str | None:
        try:
            return self._run(f"repos/{self.repository}/actions/jobs/{job_id}/logs")
        except ReportError:
            return None

    def workflow_runs(self, workflow: str, event: str, page: int) -> list[dict[str, Any]]:
        return self.get(f"actions/workflows/{workflow}/runs?event={event}&per_page=100&page={page}")["workflow_runs"]

    def head_runs(self, sha: str) -> list[dict[str, Any]]:
        return self.get(f"actions/runs?head_sha={sha}&per_page=100")["workflow_runs"]

    def attempt(self, run_id: int, number: int) -> dict[str, Any]:
        return self.cached(f"attempt-{run_id}-{number}", lambda: self._attempt(run_id, number))

    def _attempt(self, run_id: int, number: int) -> dict[str, Any]:
        attempt = self.get(f"actions/runs/{run_id}/attempts/{number}")
        jobs = self.get(f"actions/runs/{run_id}/attempts/{number}/jobs?per_page=100")["jobs"]
        return {"attempt": {key: attempt.get(key) for key in ("run_started_at", "conclusion")}, "jobs": jobs}

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
            except ReportError:
                continue
            workflow_patches = "".join(entry.get("patch") or "" for entry in files
                                       if entry["filename"].startswith(".github/workflows/"))
            return {"files": [entry["filename"] for entry in files],
                    "xcode_pin": bool(XCODE_PIN.search(workflow_patches))}
        return {"files": None, "xcode_pin": False}

    def _pull_bases(self, sha: str, branch: str) -> list[str]:
        try:
            pulls = self.get(f"commits/{sha}/pulls")
        except ReportError:
            pulls = []
        return [pull["base"]["ref"] for pull in pulls if pull["head"]["ref"] == branch] + ["main"]


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


def head_rows(client: GitHub, event: str, head: dict[str, Any], branch_runs: dict[str, list[str]],
              timeouts: dict[str, int], until: str | None) -> list[dict[str, Any]]:
    sha, branch = head["head_sha"], head["head_branch"]
    wanted = {f".github/workflows/{name}": name for name in WORKFLOWS}
    runs = [run for run in client.head_runs(sha) if run.get("event") == event and run.get("path") in wanted
            and within(run["created_at"], until)]
    # A head counts once every workflow finished, or its critical path would be cut short.
    if any(run.get("status") != "completed" for run in runs):
        return []
    grouped: dict[str, dict[str, Any]] = {}
    for run in sorted(runs, key=lambda run: parse_time(run["created_at"])):
        grouped[wanted[run["path"]]] = run
    attempts: dict[int, HeadAttempt] = {}
    for workflow, run in grouped.items():
        for number in range(1, run["run_attempt"] + 1):
            data = client.attempt(run["id"], number)
            if not within(data["attempt"]["run_started_at"], until):
                continue
            attempts.setdefault(number, HeadAttempt(event, sha, branch, number)).runs.append(
                RunAttempt(workflow, run, data["attempt"], data["jobs"]))
    changes = HeadChanges(**client.changes(event, sha, branch))
    rows = []
    for number in sorted(attempts):
        attempt = attempts[number]
        build_job = next((job for run in attempt.runs for job in run.jobs
                          if job["name"] == "build-and-test" and job.get("runner_name")), None)
        scope_job = next((job for run in attempt.runs for job in run.jobs
                          if job["name"] == "scope" and job.get("runner_name")), None)
        build = scope = None
        if build_job:
            build = client.cached(f"build-{build_job['id']}", lambda: _digest(client, build_job["id"], build_log_digest))
        if scope_job:
            scope = client.cached(f"scope-{scope_job['id']}", lambda: _digest(client, scope_job["id"], scope_log_digest))
        rows.append(attempt_row(attempt, changes=changes, build=build, scope=scope, timeouts=timeouts,
                                superseded=was_superseded(attempt, branch_runs.get(branch, []))))
    return rows


def _digest(client: GitHub, job_id: int, digest: Callable[[str], dict[str, Any]]) -> dict[str, Any]:
    log = client.log(job_id)
    if log is None:
        return {"cache": "log-unavailable", "compile_s": None, "swift_scope": None} if digest is build_log_digest \
            else {"summary": None, "selectors": None}
    return digest(log)


def collect(client: GitHub, count: int, until: str | None, *, workers: int = 8) -> list[dict[str, Any]]:
    timeouts = declared_timeouts()
    rows: list[dict[str, Any]] = []
    for event in EVENTS:
        heads, branch_runs = latest_heads(client, event, count, until)
        with ThreadPoolExecutor(max_workers=workers) as pool:
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
    parser.add_argument("--until", help="past ISO time; only runs started at or before it, to pin the window")
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
