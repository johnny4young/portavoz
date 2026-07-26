#!/usr/bin/env python3
"""Evaluate Portavoz's release performance ledger (PERF-001/PERF-008).

The benchmark harnesses already measure the product. What this tool adds is
RETENTION: it reads the declared threshold contract, pulls each metric out of
the harness reports it was given, compares them against their budget and
against the committed baseline, and answers with one scorecard and one exit
code.

Two rules keep the answer honest:

* A metric whose harness report was not supplied is reported as
  `not-measured`, never silently dropped. A scorecard that skipped half the
  journeys must say so.
* Only an absolute budget miss fails the run. A regression against the
  baseline is reported as a candidate, because PERF-008 requires three stable
  runs before calling it real — `--strict` is how a release turns candidates
  into failures.

Exit codes: 0 when every measured journey is inside its budget; 1 on a budget
miss or on an unresolved metric (a contract that cannot be evaluated is not a
pass); 2 when the only findings are regression candidates, or 1 for those too
under `--strict`.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Sequence

CONTRACT_SCHEMA_VERSION = 1
LEDGER_SCHEMA_VERSION = 1

PASS = "pass"
FAIL = "fail"
REGRESSION = "regression-candidate"
DIAGNOSTIC = "diagnostic"
NOT_MEASURED = "not-measured"
UNRESOLVED = "unresolved"
UNSTABLE = "unstable"


class ContractError(Exception):
    """The threshold contract itself is malformed."""


@dataclass
class MetricResult:
    identifier: str
    journey: str
    title: str
    unit: str
    status: str
    harness: str
    measured: float | None = None
    budget_maximum: float | None = None
    budget_minimum: float | None = None
    baseline: float | None = None
    change_fraction: float | None = None
    #: p95 / p50 of this metric's own samples. Above the contract's limit the
    #: 20 iterations disagreed with each other, so the number is not evidence.
    dispersion: float | None = None
    detail: str = ""

    def as_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "id": self.identifier,
            "journey": self.journey,
            "title": self.title,
            "unit": self.unit,
            "harness": self.harness,
            "status": self.status,
        }
        for key, value in (
            ("measured", self.measured),
            ("budgetMaximum", self.budget_maximum),
            ("budgetMinimum", self.budget_minimum),
            ("baseline", self.baseline),
            ("changeFraction", self.change_fraction),
            ("dispersion", self.dispersion),
        ):
            if value is not None:
                payload[key] = value
        if self.detail:
            payload["detail"] = self.detail
        return payload


@dataclass
class Ledger:
    results: list[MetricResult] = field(default_factory=list)
    authority: str = "informational"
    authority_reason: str = ""
    hosts: dict[str, Any] = field(default_factory=dict)
    toolchain: dict[str, Any] = field(default_factory=dict)
    #: Why a difference against the baseline may not be attributable to the
    #: product code. Empty when the comparison is clean.
    comparability: str = ""

    @property
    def failures(self) -> list[MetricResult]:
        return [r for r in self.results if r.status == FAIL]

    @property
    def regressions(self) -> list[MetricResult]:
        return [r for r in self.results if r.status == REGRESSION]

    @property
    def unresolved(self) -> list[MetricResult]:
        return [r for r in self.results if r.status == UNRESOLVED]

    @property
    def not_measured(self) -> list[MetricResult]:
        return [r for r in self.results if r.status == NOT_MEASURED]

    @property
    def unstable(self) -> list[MetricResult]:
        return [r for r in self.results if r.status == UNSTABLE]

    @property
    def dispersed(self) -> list[MetricResult]:
        """Every metric whose samples disagreed, verdict withheld or not."""
        return [r for r in self.results if r.dispersion is not None]


# MARK: - Contract


def load_contract(path: Path) -> dict[str, Any]:
    contract = json.loads(path.read_text())
    version = contract.get("schemaVersion")
    if version != CONTRACT_SCHEMA_VERSION:
        raise ContractError(
            f"threshold contract schemaVersion {version!r} is not "
            f"{CONTRACT_SCHEMA_VERSION}")
    metrics = contract.get("metrics")
    if not isinstance(metrics, list) or not metrics:
        raise ContractError("threshold contract declares no metrics")
    seen: set[str] = set()
    for metric in metrics:
        for key in ("id", "journey", "title", "unit", "harness"):
            if not metric.get(key):
                raise ContractError(f"metric is missing {key!r}: {metric!r}")
        identifier = metric["id"]
        if identifier in seen:
            raise ContractError(f"duplicate metric id {identifier!r}")
        seen.add(identifier)
        if metric.get("select") is None and metric["harness"] != "manual":
            raise ContractError(
                f"metric {identifier!r} has no selector and is not manual")
    return contract


# MARK: - Selection


def select_value(report: Any, selector: dict[str, Any]) -> float | None:
    """Resolve one number inside a harness report.

    `list` + `where` pick the checkpoint (a corpus size, a meeting length);
    `path` walks into it. Returns None when the report simply does not carry
    that checkpoint — a smaller corpus than the contract asks for is a real
    and reportable situation, not a crash.
    """
    node: Any = report
    list_key = selector.get("list")
    if list_key is not None:
        entries = node.get(list_key) if isinstance(node, dict) else None
        if not isinstance(entries, list):
            return None
        where = selector.get("where") or {}
        node = next(
            (e for e in entries
             if isinstance(e, dict)
             and all(e.get(k) == v for k, v in where.items())),
            None)
        if node is None:
            return None
    for step in selector.get("path", []):
        if not isinstance(node, dict) or step not in node:
            return None
        node = node[step]
    if isinstance(node, bool) or not isinstance(node, (int, float)):
        return None
    return float(node)


def median_selector(selector: dict[str, Any]) -> dict[str, Any] | None:
    """The p50 counterpart of a p95 selector, when the schema carries one.

    Every harness reports `p50…`/`p95…` side by side, so the median of the
    very same distribution is one substitution away. Metrics that select a
    single scalar (a first-run wall time, a hang count) have no counterpart
    and simply carry no dispersion.
    """
    path = list(selector.get("path", []))
    if not path or "p95" not in path[-1]:
        return None
    path[-1] = path[-1].replace("p95", "p50")
    return {**selector, "path": path}


# MARK: - Evaluation


def _change_fraction(measured: float, baseline: float) -> float | None:
    """Signed change against the baseline; None when the baseline is zero."""
    if baseline == 0:
        return None
    return (measured - baseline) / baseline


def _tolerance_for(unit: str, regression: dict[str, Any]) -> float:
    if unit == "bytes":
        return float(regression.get("footprintToleranceFraction", 0.20))
    return float(regression.get("latencyToleranceFraction", 0.15))


def evaluate(
    contract: dict[str, Any],
    reports: dict[str, Any],
    baselines: dict[str, Any] | None = None,
) -> Ledger:
    baselines = baselines or {}
    regression_rules = contract.get("regression") or {}
    ledger = Ledger()

    for metric in contract["metrics"]:
        harness = metric["harness"]
        result = MetricResult(
            identifier=metric["id"],
            journey=metric["journey"],
            title=metric["title"],
            unit=metric["unit"],
            harness=harness,
            status=NOT_MEASURED,
            budget_maximum=metric.get("budgetMaximum"),
            budget_minimum=metric.get("budgetMinimum"),
        )

        report = reports.get(harness)
        selector = metric.get("select")
        if report is None or selector is None:
            # A manual metric carries no selector, so a report handed to it
            # cannot resolve it: say it is unmeasured rather than crash.
            result.detail = metric.get(
                "source", "no report supplied for this harness in this run")
            ledger.results.append(result)
            continue

        measured = select_value(report, selector)
        if measured is None:
            result.status = UNRESOLVED
            result.detail = "the supplied report carries no such checkpoint"
            ledger.results.append(result)
            continue
        result.measured = measured
        result.dispersion = _dispersion(
            report, selector, measured, metric["unit"],
            contract.get("stability") or {})

        baseline_report = baselines.get(harness)
        if baseline_report is not None:
            result.baseline = select_value(baseline_report, metric["select"])
            if result.baseline is not None:
                result.change_fraction = _change_fraction(
                    measured, result.baseline)

        result.status = _status_for(result, regression_rules)
        ledger.results.append(result)

    _apply_authority(ledger, contract, reports, baselines)
    _apply_comparability(ledger, reports, baselines)
    return ledger


def _toolchain_of(reports: dict[str, Any]) -> dict[str, Any]:
    """The most complete toolchain any report in the set declared."""
    declared = [r.get("toolchain") for r in reports.values() if isinstance(r, dict)]
    declared = [t for t in declared if isinstance(t, dict) and t]
    return max(declared, key=len) if declared else {}


def _apply_comparability(
    ledger: Ledger,
    reports: dict[str, Any],
    baselines: dict[str, Any],
) -> None:
    """State plainly when a delta may be codegen rather than product code.

    A different toolchain does NOT cost the run its authority — the machine
    is what PERF-001 makes authoritative. It costs the COMPARISON its
    attribution, and saying so is the difference between evidence and a
    number that merely looks like one.
    """
    ledger.toolchain = _toolchain_of(reports)
    current = ledger.toolchain.get("swift")
    baseline = _toolchain_of(baselines).get("swift")
    if not baselines:
        return
    if baseline is None:
        ledger.comparability = (
            "the baseline predates toolchain recording, so a codegen "
            "difference cannot be ruled out")
    elif current and baseline != current:
        ledger.comparability = (
            f"built with Swift {current}; the baseline used {baseline}, so a "
            "difference may be codegen rather than product code")


#: Units where a wide p95/p50 spread means the process was descheduled.
#: Byte deltas are lumpy by nature — page granularity and allocator behavior
#: move them without the machine being busy at all.
TIMED_UNITS = frozenset({"ms", "s"})


def _dispersion(
    report: Any,
    selector: dict[str, Any],
    measured: float,
    unit: str,
    stability: dict[str, Any],
) -> float | None:
    """How far this metric's own samples spread, when that is meaningful.

    Returned only when the spread exceeds the contract's limit: a tight
    distribution needs no comment. Three guards keep the signal honest —
    only timed units, only enough samples for p95 to differ from the maximum,
    and only measurements large enough for a ratio to mean anything (0.4 ms
    bouncing to 0.6 ms is 1.5x and says nothing about the machine).
    """
    if unit not in TIMED_UNITS:
        return None
    counterpart = median_selector(selector)
    if counterpart is None:
        return None

    samples = select_value(
        report, {**selector, "path": selector["path"][:-1] + ["sampleCount"]})
    minimum = float(stability.get("minimumSamplesForDispersion", 10))
    if samples is None or samples < minimum:
        # With a handful of runs p95 IS the maximum, so the ratio is not a
        # statistic about the machine.
        return None

    median = select_value(report, counterpart)
    floor = float(stability.get("minimumMedianForDispersion", 1.0))
    if median is None or median <= 0 or median < floor:
        return None
    ratio = measured / median
    limit = float(stability.get("maximumDispersionRatio", 1.25))
    return ratio if ratio > limit else None


def _status_for(result: MetricResult, regression_rules: dict[str, Any]) -> str:
    measured = result.measured
    assert measured is not None
    over_budget = (
        (result.budget_maximum is not None and measured > result.budget_maximum)
        or (result.budget_minimum is not None
            and measured < result.budget_minimum))
    if over_budget:
        # A sample that disagrees with itself cannot convict. Withholding the
        # verdict is the honest answer — not a pass, not a failure.
        return UNSTABLE if result.dispersion is not None else FAIL
    if result.change_fraction is not None:
        tolerance = _tolerance_for(result.unit, regression_rules)
        if result.change_fraction > tolerance:
            return REGRESSION
    if result.budget_maximum is None and result.budget_minimum is None:
        return DIAGNOSTIC
    return PASS


def _apply_authority(
    ledger: Ledger,
    contract: dict[str, Any],
    reports: dict[str, Any],
    baselines: dict[str, Any],
) -> None:
    """PERF-001: a stable Apple Silicon Mac is the release authority.

    A run only claims authority when every report came from one host that
    matches the baseline host and the required architecture. Anything else —
    hosted CI, a different Mac, mixed hosts — stays informational, which is
    exactly how the strategy asks noisy environments to be treated.
    """
    hosts = [r.get("host") for r in reports.values() if isinstance(r, dict)]
    hosts = [h for h in hosts if isinstance(h, dict)]
    if not hosts:
        ledger.authority_reason = "no report carried host metadata"
        return
    first = max(hosts, key=len)
    ledger.hosts = first
    # Harness reports declare different amounts of host detail, and they spell
    # the OS differently ("26.5.2" vs "Version 26.5.2 (Build 25F84)"). Machine
    # identity is therefore architecture, memory, and cores: two reports are
    # from one Mac when they agree on every such field they BOTH carry.
    # Demanding identical dictionaries would call one Mac two.
    if any(not _hosts_agree(h, first, ignoring=OS_KEYS) for h in hosts):
        ledger.authority_reason = "reports came from more than one host"
        return

    required = (contract.get("authority") or {}).get("requiredArchitecture")
    if required and first.get("architecture") != required:
        ledger.authority_reason = (
            f"architecture {first.get('architecture')!r} is not {required!r}")
        return

    configurations = {
        r.get("buildConfiguration") for r in reports.values()
        if isinstance(r, dict) and r.get("buildConfiguration") is not None
    }
    if configurations and configurations != {"release"}:
        ledger.authority_reason = (
            f"build configuration {sorted(configurations)} is not release")
        return

    baseline_hosts = [
        b.get("host") for b in baselines.values() if isinstance(b, dict)]
    for baseline_host in baseline_hosts:
        if not isinstance(baseline_host, dict):
            continue
        if not _hosts_agree(baseline_host, first, ignoring=OS_KEYS):
            ledger.authority_reason = (
                "the baseline was measured on a different machine")
            return

    # PERF-001 names a STABLE machine as the authority. Identity is not
    # enough: samples that disagree with each other prove the machine was
    # busy while it measured, whatever Mac it is.
    if ledger.dispersed:
        worst = max(ledger.dispersed, key=lambda r: r.dispersion or 0)
        ledger.authority_reason = (
            f"samples disagreed with themselves (worst: {worst.title} at "
            f"{worst.dispersion:.2f}x its median) — the machine was busy")
        return

    ledger.authority = "authoritative"


#: Upgrading macOS on the same Mac must not silently discard the baseline —
#: it must surface as whatever change it actually causes in the numbers.
OS_KEYS = frozenset({"operatingSystem", "operatingSystemBuild"})


def _hosts_agree(
    host: dict[str, Any],
    other: dict[str, Any],
    ignoring: frozenset[str] = frozenset(),
) -> bool:
    """True when two host descriptions never contradict each other."""
    shared = (set(host) & set(other)) - ignoring
    return all(host[key] == other[key] for key in shared)


# MARK: - Rendering


def _format_value(value: float | None, unit: str) -> str:
    if value is None:
        return "—"
    if unit == "bytes":
        return f"{value / (1024 * 1024):.2f} MiB"
    if unit == "ms":
        return f"{value:.2f} ms"
    if unit == "s":
        return f"{value:.2f} s"
    if unit == "fraction":
        return f"{value * 100:.2f}%"
    if unit == "factor":
        return f"{value:.1f}x"
    return f"{value:g} {unit}"


def _format_budget(result: MetricResult) -> str:
    # The comparison is inclusive, and saying so matters for a count budget:
    # "≤ 0 hangs" is a real target, "< 0 hangs" is impossible.
    if result.budget_maximum is not None:
        return f"≤ {_format_value(result.budget_maximum, result.unit)}"
    if result.budget_minimum is not None:
        return f"≥ {_format_value(result.budget_minimum, result.unit)}"
    return "diagnostic"


STATUS_MARK = {
    PASS: "✅ pass",
    FAIL: "❌ FAIL",
    REGRESSION: "⚠️ regression candidate",
    DIAGNOSTIC: "· diagnostic",
    NOT_MEASURED: "— not measured",
    UNRESOLVED: "? unresolved",
    UNSTABLE: "🎲 unstable — no verdict",
}


def render_markdown(ledger: Ledger, generated_at: str | None = None) -> str:
    lines = ["# Portavoz release performance ledger", ""]
    if generated_at:
        lines.append(f"Generated: {generated_at}")
    host = ledger.hosts
    if host:
        lines.append(
            f"Host: {host.get('architecture')} · "
            f"{host.get('processorCount')} cores · "
            f"{int(host.get('physicalMemoryBytes', 0)) // (1024 ** 3)} GiB · "
            f"{host.get('operatingSystem')}")
    if ledger.toolchain:
        chain = ledger.toolchain
        parts = [f"Swift {chain['swift']}"] if chain.get("swift") else []
        for key in ("target", "xcode"):
            if chain.get(key):
                parts.append(str(chain[key]))
        if parts:
            lines.append("Toolchain: " + " · ".join(parts))
    authority = (
        "**authoritative**" if ledger.authority == "authoritative"
        else f"**informational** ({ledger.authority_reason})")
    lines.append(f"Authority: {authority}")
    if ledger.comparability:
        lines.append(f"Comparability: ⚠️ {ledger.comparability}")
    lines.append("")

    lines += ["| Journey | Metric | Target | Measured | Baseline | Δ | Status |",
              "|---|---|---|---|---|---|---|"]
    for result in ledger.results:
        change = (
            f"{result.change_fraction * 100:+.1f}%"
            if result.change_fraction is not None else "—")
        lines.append(
            f"| {result.journey} | {result.title} | {_format_budget(result)} "
            f"| {_format_value(result.measured, result.unit)} "
            f"| {_format_value(result.baseline, result.unit)} "
            f"| {change} | {STATUS_MARK.get(result.status, result.status)} |")

    lines.append("")
    if ledger.failures:
        lines.append("## Budget failures")
        for result in ledger.failures:
            lines.append(
                f"- **{result.title}**: "
                f"{_format_value(result.measured, result.unit)} vs "
                f"{_format_budget(result)}")
        lines.append("")
    if ledger.regressions:
        lines.append("## Regression candidates")
        lines.append(
            "PERF-008 needs three stable runs before a regression is real; "
            "re-run before treating these as release blockers.")
        for result in ledger.regressions:
            assert result.change_fraction is not None
            lines.append(
                f"- **{result.title}**: {result.change_fraction * 100:+.1f}% "
                f"against the baseline")
        lines.append("")
    if ledger.unstable:
        lines.append("## Verdict withheld — unstable samples")
        lines.append(
            "These metrics missed their budget, but their own 20 iterations "
            "disagreed with each other, so the run cannot convict them. "
            "Re-measure on a quiet machine.")
        for result in ledger.unstable:
            assert result.dispersion is not None
            lines.append(
                f"- **{result.title}**: "
                f"{_format_value(result.measured, result.unit)} vs "
                f"{_format_budget(result)}, but p95 is "
                f"{result.dispersion:.2f}x its own median")
        lines.append("")
    noisy = [r for r in ledger.dispersed if r.status != UNSTABLE]
    if noisy:
        lines.append("## Noisy but inside budget")
        for result in noisy:
            assert result.dispersion is not None
            lines.append(
                f"- **{result.title}** — p95 is {result.dispersion:.2f}x its "
                "own median; the budget held anyway")
        lines.append("")
    if ledger.unresolved:
        lines.append("## Unresolved")
        lines.append(
            "These metrics fail the run: the harness reported, but the "
            "declared checkpoint was absent — usually a corpus smaller than "
            "the contract asks for.")
        for result in ledger.unresolved:
            lines.append(f"- **{result.title}** — {result.detail}")
        lines.append("")
    if ledger.not_measured:
        lines.append("## Declared but not measured in this run")
        for result in ledger.not_measured:
            lines.append(f"- **{result.title}** — {result.detail}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def build_document(
    ledger: Ledger, generated_at: str | None = None
) -> dict[str, Any]:
    document: dict[str, Any] = {
        "schemaVersion": LEDGER_SCHEMA_VERSION,
        "authority": ledger.authority,
        "metrics": [r.as_dict() for r in ledger.results],
        "summary": {
            "failures": len(ledger.failures),
            "regressionCandidates": len(ledger.regressions),
            "notMeasured": len(ledger.not_measured),
            "unresolved": len(ledger.unresolved),
            "unstable": len(ledger.unstable),
            "dispersed": len(ledger.dispersed),
        },
    }
    if generated_at:
        document["generatedAt"] = generated_at
    if ledger.authority_reason:
        document["authorityReason"] = ledger.authority_reason
    if ledger.hosts:
        document["host"] = ledger.hosts
    if ledger.toolchain:
        document["toolchain"] = ledger.toolchain
    if ledger.comparability:
        document["comparability"] = ledger.comparability
    return document


def exit_code(ledger: Ledger, strict: bool = False) -> int:
    if ledger.failures or ledger.unresolved or ledger.unstable:
        return 1
    if ledger.regressions:
        return 1 if strict else 2
    return 0


# MARK: - CLI


def _parse_reports(values: Sequence[str]) -> dict[str, Any]:
    reports: dict[str, Any] = {}
    for raw in values:
        harness, separator, path = raw.partition("=")
        if not separator:
            raise SystemExit(
                f"error: --report expects harness=path, got {raw!r}")
        reports[harness] = json.loads(Path(path).read_text())
    return reports


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thresholds", required=True, type=Path)
    parser.add_argument(
        "--report", action="append", default=[], metavar="HARNESS=PATH",
        help="a harness report to evaluate; repeatable")
    parser.add_argument(
        "--baseline", action="append", default=[], metavar="HARNESS=PATH",
        help="the committed baseline for a harness; repeatable")
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--markdown-output", type=Path)
    parser.add_argument("--generated-at")
    parser.add_argument(
        "--strict", action="store_true",
        help="treat regression candidates as failures")
    arguments = parser.parse_args(list(argv) if argv is not None else None)

    contract = load_contract(arguments.thresholds)
    ledger = evaluate(
        contract,
        _parse_reports(arguments.report),
        _parse_reports(arguments.baseline))

    markdown = render_markdown(ledger, arguments.generated_at)
    document = build_document(ledger, arguments.generated_at)
    if arguments.json_output:
        arguments.json_output.write_text(
            json.dumps(document, indent=2, sort_keys=True) + "\n")
    if arguments.markdown_output:
        arguments.markdown_output.write_text(markdown)
    print(markdown)
    return exit_code(ledger, strict=arguments.strict)


if __name__ == "__main__":
    sys.exit(main())
