"""Unit tests for the release performance ledger (PERF-001/PERF-008).

The gate decides whether a release ships, so its rules are tested against
synthetic reports rather than only against a real benchmark run.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import perf_ledger  # noqa: E402


HOST = {
    "architecture": "arm64",
    "operatingSystem": "Version 26.5.2 (Build 25F84)",
    "physicalMemoryBytes": 38654705664,
    "processorCount": 14,
}


def contract(*metrics: dict) -> dict:
    return {
        "schemaVersion": 1,
        "authority": {"requiredArchitecture": "arm64"},
        "regression": {
            "latencyToleranceFraction": 0.15,
            "footprintToleranceFraction": 0.20,
        },
        "metrics": list(metrics),
    }


def latency_metric(**overrides: object) -> dict:
    metric = {
        "id": "search.exact.p95",
        "journey": "Search",
        "title": "Exact search",
        "harness": "scale",
        "unit": "ms",
        "budgetMaximum": 50,
        "select": {
            "list": "library",
            "where": {"totalSegments": 100000},
            "path": ["exactSearch", "p95Milliseconds"],
        },
    }
    metric.update(overrides)
    return metric


def scale_report(p95: float, host: dict | None = None) -> dict:
    return {
        "buildConfiguration": "release",
        "host": dict(host or HOST),
        "library": [
            {"totalSegments": 1000, "exactSearch": {"p95Milliseconds": 0.5}},
            {"totalSegments": 100000, "exactSearch": {"p95Milliseconds": p95}},
        ],
    }


class BudgetTests(unittest.TestCase):
    def test_value_within_its_budget_passes(self):
        ledger = perf_ledger.evaluate(
            contract(latency_metric()), {"scale": scale_report(30.0)})
        self.assertEqual(ledger.results[0].status, perf_ledger.PASS)
        self.assertEqual(perf_ledger.exit_code(ledger), 0)

    def test_value_over_its_budget_fails_the_run(self):
        ledger = perf_ledger.evaluate(
            contract(latency_metric()), {"scale": scale_report(50.01)})
        self.assertEqual(ledger.results[0].status, perf_ledger.FAIL)
        self.assertEqual(perf_ledger.exit_code(ledger), 1)

    def test_budget_is_inclusive(self):
        ledger = perf_ledger.evaluate(
            contract(latency_metric()), {"scale": scale_report(50.0)})
        self.assertEqual(ledger.results[0].status, perf_ledger.PASS)

    def test_minimum_budget_fails_below_the_floor(self):
        metric = latency_metric(
            id="refine.speed", unit="factor",
            budgetMaximum=None, budgetMinimum=15)
        del metric["budgetMaximum"]
        ledger = perf_ledger.evaluate(
            contract(metric), {"scale": scale_report(9.0)})
        self.assertEqual(ledger.results[0].status, perf_ledger.FAIL)

    def test_metric_without_a_budget_is_diagnostic_and_never_fails(self):
        metric = latency_metric()
        del metric["budgetMaximum"]
        ledger = perf_ledger.evaluate(
            contract(metric), {"scale": scale_report(9_999.0)})
        self.assertEqual(ledger.results[0].status, perf_ledger.DIAGNOSTIC)
        self.assertEqual(perf_ledger.exit_code(ledger), 0)


class RegressionTests(unittest.TestCase):
    def test_latency_beyond_tolerance_is_a_candidate_not_a_failure(self):
        ledger = perf_ledger.evaluate(
            contract(latency_metric()),
            {"scale": scale_report(24.0)},
            {"scale": scale_report(20.0)})
        result = ledger.results[0]
        self.assertEqual(result.status, perf_ledger.REGRESSION)
        self.assertAlmostEqual(result.change_fraction, 0.20, places=6)
        # PERF-008 needs three stable runs, so one run reports rather than
        # blocks — unless the release asks for strictness.
        self.assertEqual(perf_ledger.exit_code(ledger), 2)
        self.assertEqual(perf_ledger.exit_code(ledger, strict=True), 1)

    def test_tolerance_is_exclusive_exactly_as_perf_008_words_it(self):
        # PERF-008 fails a release when p95 "regresses by >15%", so landing
        # exactly on the tolerance is not yet a regression.
        ledger = perf_ledger.evaluate(
            contract(latency_metric()),
            {"scale": scale_report(23.0)},
            {"scale": scale_report(20.0)})
        self.assertAlmostEqual(ledger.results[0].change_fraction, 0.15)
        self.assertEqual(ledger.results[0].status, perf_ledger.PASS)

    def test_latency_inside_tolerance_still_passes(self):
        ledger = perf_ledger.evaluate(
            contract(latency_metric()),
            {"scale": scale_report(22.9)},
            {"scale": scale_report(20.0)})
        self.assertEqual(ledger.results[0].status, perf_ledger.PASS)

    def test_improvement_is_never_a_regression(self):
        ledger = perf_ledger.evaluate(
            contract(latency_metric()),
            {"scale": scale_report(5.0)},
            {"scale": scale_report(40.0)})
        self.assertEqual(ledger.results[0].status, perf_ledger.PASS)
        self.assertLess(ledger.results[0].change_fraction, 0)

    def test_footprint_uses_the_wider_memory_tolerance(self):
        metric = latency_metric(unit="bytes", budgetMaximum=10 ** 9)
        # +18% memory is inside PERF-008's 20% memory rule but would have
        # tripped the 15% latency rule.
        ledger = perf_ledger.evaluate(
            contract(metric),
            {"scale": scale_report(1_180_000)},
            {"scale": scale_report(1_000_000)})
        self.assertEqual(ledger.results[0].status, perf_ledger.PASS)

    def test_budget_failure_outranks_a_regression(self):
        ledger = perf_ledger.evaluate(
            contract(latency_metric()),
            {"scale": scale_report(80.0)},
            {"scale": scale_report(20.0)})
        self.assertEqual(ledger.results[0].status, perf_ledger.FAIL)


class HonestyTests(unittest.TestCase):
    def test_missing_harness_is_reported_not_dropped(self):
        declared = latency_metric(
            harness="manual", source="portavoz-cli bench-m2")
        del declared["select"]
        ledger = perf_ledger.evaluate(contract(declared), {})
        result = ledger.results[0]
        self.assertEqual(result.status, perf_ledger.NOT_MEASURED)
        self.assertIn("bench-m2", result.detail)
        # A scorecard that measured nothing must not read as a green run.
        self.assertIn("not measured", perf_ledger.render_markdown(ledger))
        self.assertEqual(perf_ledger.exit_code(ledger), 0)

    def test_report_without_the_declared_checkpoint_is_unresolved(self):
        report = scale_report(30.0)
        report["library"] = [report["library"][0]]
        ledger = perf_ledger.evaluate(
            contract(latency_metric()), {"scale": report})
        self.assertEqual(ledger.results[0].status, perf_ledger.UNRESOLVED)
        # A contract that cannot be evaluated is not a pass.
        self.assertEqual(perf_ledger.exit_code(ledger), 1)

    def test_unresolved_metrics_are_explained_in_the_scorecard(self):
        report = scale_report(30.0)
        report["library"] = [report["library"][0]]
        ledger = perf_ledger.evaluate(
            contract(latency_metric()), {"scale": report})
        markdown = perf_ledger.render_markdown(ledger)
        # The run fails on these, so the scorecard must name them and say why
        # rather than leaving a bare marker in the table.
        self.assertIn("## Unresolved", markdown)
        self.assertIn("Exact search", markdown.split("## Unresolved")[1])
        self.assertIn("no such checkpoint", markdown)

    def test_a_report_handed_to_a_manual_metric_does_not_crash(self):
        # The CLI accepts any --report name; a manual metric has no selector,
        # so it must stay unmeasured instead of raising KeyError.
        manual = latency_metric(harness="manual", source="portavoz-cli der")
        del manual["select"]
        ledger = perf_ledger.evaluate(
            contract(manual), {"manual": scale_report(30.0)})
        self.assertEqual(ledger.results[0].status, perf_ledger.NOT_MEASURED)
        self.assertIn("der", ledger.results[0].detail)

    def test_every_declared_metric_appears_in_the_scorecard(self):
        manual = latency_metric(id="manual.metric", harness="manual")
        del manual["select"]
        ledger = perf_ledger.evaluate(
            contract(latency_metric(), manual), {"scale": scale_report(10.0)})
        markdown = perf_ledger.render_markdown(ledger)
        self.assertIn("Exact search", markdown)
        self.assertEqual(len(ledger.results), 2)


class AuthorityTests(unittest.TestCase):
    def test_single_release_host_is_authoritative(self):
        ledger = perf_ledger.evaluate(
            contract(latency_metric()), {"scale": scale_report(10.0)})
        self.assertEqual(ledger.authority, "authoritative")

    def test_mixed_machines_are_only_informational(self):
        other = dict(HOST, processorCount=8, physicalMemoryBytes=8 * 1024 ** 3)
        metric = latency_metric(id="second", harness="semantic")
        ledger = perf_ledger.evaluate(
            contract(latency_metric(), metric),
            {"scale": scale_report(10.0),
             "semantic": scale_report(10.0, host=other)})
        self.assertEqual(ledger.authority, "informational")
        self.assertIn("more than one host", ledger.authority_reason)

    def test_differently_spelled_os_on_one_machine_keeps_authority(self):
        # The Instruments harness writes "26.5.2"; the CLI harnesses write
        # "Version 26.5.2 (Build 25F84)". Same Mac, two conventions.
        terse = {"architecture": "arm64", "operatingSystem": "26.5.2"}
        metric = latency_metric(id="second", harness="detail-ui")
        ledger = perf_ledger.evaluate(
            contract(latency_metric(), metric),
            {"scale": scale_report(10.0),
             "detail-ui": scale_report(10.0, host=terse)})
        self.assertEqual(ledger.authority, "authoritative")

    def test_non_apple_silicon_is_informational(self):
        intel = dict(HOST, architecture="x86_64")
        ledger = perf_ledger.evaluate(
            contract(latency_metric()), {"scale": scale_report(10.0, intel)})
        self.assertEqual(ledger.authority, "informational")

    def test_debug_build_is_informational(self):
        report = scale_report(10.0)
        report["buildConfiguration"] = "debug"
        ledger = perf_ledger.evaluate(
            contract(latency_metric()), {"scale": report})
        self.assertEqual(ledger.authority, "informational")
        self.assertIn("release", ledger.authority_reason)

    def test_baseline_from_another_machine_is_informational(self):
        other = dict(HOST, processorCount=8)
        ledger = perf_ledger.evaluate(
            contract(latency_metric()),
            {"scale": scale_report(10.0)},
            {"scale": scale_report(10.0, host=other)})
        self.assertEqual(ledger.authority, "informational")
        self.assertIn("different machine", ledger.authority_reason)

    def test_os_upgrade_on_the_same_mac_keeps_the_baseline(self):
        upgraded = dict(HOST, operatingSystem="Version 27.0 (Build 27A1)")
        ledger = perf_ledger.evaluate(
            contract(latency_metric()),
            {"scale": scale_report(10.0, host=upgraded)},
            {"scale": scale_report(10.0)})
        self.assertEqual(ledger.authority, "authoritative")


class ToolchainTests(unittest.TestCase):
    """A codegen change must be visible, not silently blamed on the code."""

    def _report(self, swift: str | None) -> dict:
        report = scale_report(30.0)
        if swift is not None:
            report["toolchain"] = {
                "swift": swift, "target": "arm64-apple-macosx26.0"}
        return report

    def test_toolchain_is_recorded_and_shown(self):
        ledger = perf_ledger.evaluate(
            contract(latency_metric()), {"scale": self._report("6.3.3")})
        self.assertEqual(ledger.toolchain.get("swift"), "6.3.3")
        self.assertIn("Swift 6.3.3", perf_ledger.render_markdown(ledger))
        self.assertEqual(
            perf_ledger.build_document(ledger)["toolchain"]["swift"], "6.3.3")

    def test_a_baseline_without_a_toolchain_says_so(self):
        # Every baseline committed before this existed is in that state.
        ledger = perf_ledger.evaluate(
            contract(latency_metric()),
            {"scale": self._report("6.3.3")},
            {"scale": self._report(None)})
        self.assertIn("predates toolchain recording", ledger.comparability)
        self.assertIn("Comparability", perf_ledger.render_markdown(ledger))

    def test_a_different_toolchain_is_flagged_as_an_attribution_caveat(self):
        ledger = perf_ledger.evaluate(
            contract(latency_metric()),
            {"scale": self._report("6.3.3")},
            {"scale": self._report("6.2.0")})
        self.assertIn("6.2.0", ledger.comparability)
        self.assertIn("codegen", ledger.comparability)
        # The machine is what grants authority; the toolchain only qualifies
        # what a delta can be blamed on.
        self.assertEqual(ledger.authority, "authoritative")

    def test_the_same_toolchain_leaves_the_comparison_clean(self):
        ledger = perf_ledger.evaluate(
            contract(latency_metric()),
            {"scale": self._report("6.3.3")},
            {"scale": self._report("6.3.3")})
        self.assertEqual(ledger.comparability, "")
        self.assertNotIn("Comparability", perf_ledger.render_markdown(ledger))

    def test_a_run_without_a_baseline_raises_no_caveat(self):
        ledger = perf_ledger.evaluate(
            contract(latency_metric()), {"scale": self._report("6.3.3")})
        self.assertEqual(ledger.comparability, "")


class SelectorTests(unittest.TestCase):
    def test_where_clause_picks_the_declared_checkpoint(self):
        report = scale_report(42.0)
        value = perf_ledger.select_value(
            report,
            {"list": "library", "where": {"totalSegments": 100000},
             "path": ["exactSearch", "p95Milliseconds"]})
        self.assertEqual(value, 42.0)

    def test_absent_path_resolves_to_none_rather_than_raising(self):
        self.assertIsNone(perf_ledger.select_value(
            scale_report(1.0),
            {"list": "library", "where": {"totalSegments": 100000},
             "path": ["nope", "p95Milliseconds"]}))

    def test_booleans_are_not_measurements(self):
        self.assertIsNone(perf_ledger.select_value(
            {"ok": True}, {"path": ["ok"]}))


class ContractTests(unittest.TestCase):
    def _write(self, payload: dict) -> Path:
        directory = Path(tempfile.mkdtemp())
        path = directory / "thresholds.json"
        path.write_text(json.dumps(payload))
        return path

    def test_unknown_schema_version_is_refused(self):
        with self.assertRaises(perf_ledger.ContractError):
            perf_ledger.load_contract(
                self._write(dict(contract(latency_metric()), schemaVersion=99)))

    def test_duplicate_metric_ids_are_refused(self):
        with self.assertRaises(perf_ledger.ContractError):
            perf_ledger.load_contract(
                self._write(contract(latency_metric(), latency_metric())))

    def test_automated_metric_without_a_selector_is_refused(self):
        metric = latency_metric()
        del metric["select"]
        with self.assertRaises(perf_ledger.ContractError):
            perf_ledger.load_contract(self._write(contract(metric)))

    def test_the_shipped_contract_is_valid_and_covers_every_journey(self):
        root = Path(__file__).resolve().parents[2]
        shipped = perf_ledger.load_contract(
            root / "docs" / "evidence" / "perf-thresholds.json")
        journeys = {m["journey"] for m in shipped["metrics"]}
        for required in ("Search", "Meeting Detail", "Recording", "Capture"):
            self.assertIn(required, journeys)
        # Every automated selector must name a harness the runner can produce.
        for metric in shipped["metrics"]:
            self.assertIn(
                metric["harness"],
                {"scale", "semantic", "spotlight", "waveform", "detail-ui",
                 "manual"},
                metric["id"])


if __name__ == "__main__":
    unittest.main()
