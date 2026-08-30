#!/usr/bin/env python3
"""Validate content-free, real-app Apuntador leak evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Sequence

import live_assist_validation
import resource_baseline


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = ROOT / "docs" / "evidence" / "apuntador-leak-baseline.json"
SCHEMA_VERSION = 1
CONTRACT_KIND = "apuntador-leak-baseline-contract"
FRAGMENT_KIND = "apuntador-leak-observation"
RECEIPT_KIND = "apuntador-leak-baseline"
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,95}$")
LEAK_SUMMARY = re.compile(
    r"\b([0-9]+) leaks? for ([0-9]+) total leaked bytes\b",
    re.IGNORECASE,
)
FORBIDDEN_LOG_MARKERS = (
    "[fatal]",
    "Library not loaded:",
    "Segmentation fault",
    "Abort trap",
    "Trace/BPT trap",
)
EXPECTED_SCENARIOS = (
    "live-assist-released",
    "live-assist-bundled-question",
    "ask",
    "semantic-indexing",
)
EXPECTED_POLICIES = {
    "application": "release-disposable-ad-hoc-copy",
    "memoryContent": "withheld",
    "network": "not-required",
    "privateLibrary": "forbidden",
    "source": "public-synthetic-only",
    "stacks": "withheld",
}


class ApuntadorLeakBaselineError(ValueError):
    """A malformed, incomplete, or leaking product-path observation."""


def reject_duplicate_keys(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ApuntadorLeakBaselineError(f"duplicate key: {key}")
        result[key] = value
    return result


def load_json(
    path: Path | str,
    label: str,
    maximum_bytes: int = 2 * 1024 * 1024,
) -> Any:
    source = Path(path)
    try:
        if source.is_symlink() or not source.is_file():
            raise ApuntadorLeakBaselineError(f"{label} must be a regular file")
        size = source.stat().st_size
        if not 1 <= size <= maximum_bytes:
            raise ApuntadorLeakBaselineError(f"{label} is empty or too large")
        return json.loads(
            source.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except OSError as error:
        raise ApuntadorLeakBaselineError(f"{label} could not be read") from error
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ApuntadorLeakBaselineError(
            f"{label} is not valid UTF-8 JSON"
        ) from error


def exact_object(
    value: Any,
    label: str,
    required: Iterable[str],
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ApuntadorLeakBaselineError(f"{label} must be an object")
    expected = set(required)
    if set(value) != expected:
        missing = expected - set(value)
        extra = set(value) - expected
        details: list[str] = []
        if missing:
            details.append("missing " + ", ".join(sorted(missing)))
        if extra:
            details.append("forbidden " + ", ".join(sorted(extra)))
        raise ApuntadorLeakBaselineError(
            f"{label} shape differs: {'; '.join(details)}"
        )
    return value


def exact_integer(value: Any, label: str, expected: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ApuntadorLeakBaselineError(f"{label} must be an integer")
    if expected is not None and value != expected:
        raise ApuntadorLeakBaselineError(f"{label} must be {expected}")
    return value


def safe_identifier(value: Any, label: str) -> str:
    if not isinstance(value, str) or SAFE_ID.fullmatch(value) is None:
        raise ApuntadorLeakBaselineError(f"{label} is not a safe identifier")
    return value


def exact_string_array(value: Any, label: str) -> tuple[str, ...]:
    if (
        not isinstance(value, list)
        or not value
        or any(not isinstance(item, str) or not item for item in value)
    ):
        raise ApuntadorLeakBaselineError(
            f"{label} must be a non-empty string array"
        )
    if len(set(value)) != len(value):
        raise ApuntadorLeakBaselineError(f"{label} contains duplicates")
    return tuple(value)


def validate_contract(document: Any) -> dict[str, Any]:
    contract = exact_object(
        document,
        "leak contract",
        (
            "schemaVersion",
            "kind",
            "liveAssistIterations",
            "maximumLeaks",
            "maximumLeakedBytes",
            "policies",
            "scenarios",
        ),
    )
    exact_integer(contract["schemaVersion"], "leak contract.schemaVersion", 1)
    if contract["kind"] != CONTRACT_KIND:
        raise ApuntadorLeakBaselineError("leak contract kind drifted")
    exact_integer(
        contract["liveAssistIterations"],
        "leak contract.liveAssistIterations",
        5,
    )
    exact_integer(contract["maximumLeaks"], "leak contract.maximumLeaks", 0)
    exact_integer(
        contract["maximumLeakedBytes"],
        "leak contract.maximumLeakedBytes",
        0,
    )
    if contract["policies"] != EXPECTED_POLICIES:
        raise ApuntadorLeakBaselineError("leak contract policies drifted")
    raw_scenarios = contract["scenarios"]
    if not isinstance(raw_scenarios, list):
        raise ApuntadorLeakBaselineError("leak contract.scenarios must be an array")
    scenarios: dict[str, dict[str, Any]] = {}
    ordered_ids: list[str] = []
    for index, raw in enumerate(raw_scenarios):
        scenario = exact_object(
            raw,
            f"leak contract.scenarios[{index}]",
            ("id", "kind", "adapter", "successMarker", "evidence"),
        )
        identifier = safe_identifier(
            scenario["id"], f"leak contract.scenarios[{index}].id"
        )
        if identifier in scenarios:
            raise ApuntadorLeakBaselineError(
                f"leak contract repeats scenario: {identifier}"
            )
        kind = safe_identifier(
            scenario["kind"], f"leak contract.scenarios[{index}].kind"
        )
        adapter = safe_identifier(
            scenario["adapter"], f"leak contract.scenarios[{index}].adapter"
        )
        marker = scenario["successMarker"]
        if (
            not isinstance(marker, str)
            or marker != marker.strip()
            or not 8 <= len(marker) <= 120
            or "\n" in marker
        ):
            raise ApuntadorLeakBaselineError(
                f"leak contract.scenarios[{index}].successMarker is invalid"
            )
        evidence = exact_string_array(
            scenario["evidence"],
            f"leak contract.scenarios[{index}].evidence",
        )
        expected_shape = {
            "live-assist-released": ("live-assist", "released-prefilter", ("observations",)),
            "live-assist-bundled-question": (
                "live-assist",
                "bundled-question",
                ("observations",),
            ),
            "ask": ("ask", "not-applicable", ("pipeline", "resource")),
            "semantic-indexing": (
                "semantic-indexing",
                "not-applicable",
                ("resource",),
            ),
        }.get(identifier)
        if expected_shape != (kind, adapter, evidence):
            raise ApuntadorLeakBaselineError(
                f"leak contract scenario {identifier} drifted"
            )
        ordered_ids.append(identifier)
        scenarios[identifier] = {
            **scenario,
            "evidence": evidence,
        }
    if tuple(ordered_ids) != EXPECTED_SCENARIOS:
        raise ApuntadorLeakBaselineError("leak contract scenario order drifted")
    return {**contract, "scenarios": scenarios, "orderedScenarioIDs": tuple(ordered_ids)}


def load_contract(path: Path | str = DEFAULT_CONTRACT) -> dict[str, Any]:
    return validate_contract(load_json(path, "leak contract"))


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(64 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def evidence_arguments(values: Sequence[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for raw in values:
        key, separator, value = raw.partition("=")
        if not separator or SAFE_ID.fullmatch(key) is None or not value:
            raise ApuntadorLeakBaselineError(
                "evidence must use a safe key=path value"
            )
        if key in result:
            raise ApuntadorLeakBaselineError(f"duplicate evidence key: {key}")
        result[key] = Path(value)
    return result


def validate_live_assist_evidence(
    path: Path,
    *,
    adapter: str,
    commit: str,
    build: str,
) -> None:
    fixture_path = ROOT / "Fixtures" / "LiveAssistValidation" / "public-bilingual-v1.json"
    fixture_document = live_assist_validation.load_json(
        fixture_path, "live-assist fixture"
    )
    fixture = live_assist_validation.validate_fixture(fixture_document)
    fixture_checksum = live_assist_validation.file_sha256(fixture_path)
    observations = live_assist_validation.validate_observations(
        live_assist_validation.load_json(path, "live-assist observations"),
        fixture,
        fixture_checksum,
    )
    run = observations["run"]
    if (
        run["commit"] != commit
        or run["build"] != build
        or run["sourceState"] != "clean"
    ):
        raise ApuntadorLeakBaselineError(
            "live-assist evidence does not match the clean leak run"
        )
    expected_class = {
        "released-prefilter": "released-prefilter",
        "bundled-question": "bundled-model",
    }[adapter]
    if observations["adapter"]["class"] != expected_class:
        raise ApuntadorLeakBaselineError("live-assist adapter does not match")


def validate_resource_evidence(
    scenario_id: str,
    evidence: dict[str, Path],
) -> None:
    try:
        run, _, _ = resource_baseline.validate_sample(
            resource_baseline.load_json(
                evidence["resource"], f"{scenario_id} resource evidence"
            ),
            f"{scenario_id} resource evidence",
        )
    except resource_baseline.ResourceBaselineError as error:
        raise ApuntadorLeakBaselineError(str(error)) from error
    if run != 1:
        raise ApuntadorLeakBaselineError(
            f"{scenario_id} resource evidence must be run 1"
        )
    if scenario_id == "ask":
        try:
            pipeline_run, _ = resource_baseline.validate_ask_pipeline_sample(
                resource_baseline.load_json(
                    evidence["pipeline"], "Ask pipeline evidence"
                ),
                "Ask pipeline evidence",
            )
        except resource_baseline.ResourceBaselineError as error:
            raise ApuntadorLeakBaselineError(str(error)) from error
        if pipeline_run != 1:
            raise ApuntadorLeakBaselineError("Ask pipeline evidence must be run 1")


def read_log(path: Path) -> str:
    try:
        if path.is_symlink() or not path.is_file():
            raise ApuntadorLeakBaselineError("leaks log must be a regular file")
        if not 0 < path.stat().st_size <= 2 * 1024 * 1024:
            raise ApuntadorLeakBaselineError("leaks log is empty or too large")
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise ApuntadorLeakBaselineError("leaks log could not be read") from error
    except UnicodeDecodeError as error:
        raise ApuntadorLeakBaselineError("leaks log is not UTF-8") from error


def observe_run(
    contract: dict[str, Any],
    *,
    scenario_id: str,
    log_path: Path,
    evidence: dict[str, Path],
    exit_code: int,
    commit: str,
    build: str,
) -> dict[str, Any]:
    if COMMIT.fullmatch(commit) is None:
        raise ApuntadorLeakBaselineError("observation commit is invalid")
    safe_identifier(build, "observation build")
    if scenario_id not in contract["scenarios"]:
        raise ApuntadorLeakBaselineError("observation scenario is unknown")
    scenario = contract["scenarios"][scenario_id]
    if tuple(evidence) != scenario["evidence"]:
        raise ApuntadorLeakBaselineError(
            "observation evidence inventory does not match the scenario"
        )
    for key, path in evidence.items():
        try:
            if path.is_symlink() or not path.is_file():
                raise ApuntadorLeakBaselineError(
                    f"scenario {scenario_id} evidence {key} must be a regular file"
                )
            if not 1 <= path.stat().st_size <= 2 * 1024 * 1024:
                raise ApuntadorLeakBaselineError(
                    f"scenario {scenario_id} evidence {key} is empty or too large"
                )
        except OSError as error:
            raise ApuntadorLeakBaselineError(
                f"scenario {scenario_id} evidence {key} could not be inspected"
            ) from error
    if exit_code != 0:
        raise ApuntadorLeakBaselineError(
            f"scenario {scenario_id} reported leaks or a tool failure"
        )
    log = read_log(log_path)
    if log.count(scenario["successMarker"]) != 1:
        raise ApuntadorLeakBaselineError(
            f"scenario {scenario_id} has no unique product completion marker"
        )
    if any(marker in log for marker in FORBIDDEN_LOG_MARKERS):
        raise ApuntadorLeakBaselineError(
            f"scenario {scenario_id} contains a fatal process/tool marker"
        )
    summaries = LEAK_SUMMARY.findall(log)
    if summaries:
        leak_count, leaked_bytes = (int(value) for value in summaries[-1])
        if leak_count != 0 or leaked_bytes != 0:
            raise ApuntadorLeakBaselineError(
                f"scenario {scenario_id} reported nonzero leaked memory"
            )
    if scenario["kind"] == "live-assist":
        validate_live_assist_evidence(
            evidence["observations"],
            adapter=scenario["adapter"],
            commit=commit,
            build=build,
        )
    else:
        validate_resource_evidence(scenario_id, evidence)
    digests = {key: file_sha256(path) for key, path in evidence.items()}
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": FRAGMENT_KIND,
        "scenario": scenario_id,
        "leaksExitCode": exit_code,
        "leakCount": 0,
        "leakedBytes": 0,
        "evidenceSHA256": digests,
    }


def validate_fragment(
    document: Any,
    contract: dict[str, Any],
    label: str,
) -> dict[str, Any]:
    fragment = exact_object(
        document,
        label,
        (
            "schemaVersion",
            "kind",
            "scenario",
            "leaksExitCode",
            "leakCount",
            "leakedBytes",
            "evidenceSHA256",
        ),
    )
    exact_integer(fragment["schemaVersion"], f"{label}.schemaVersion", 1)
    if fragment["kind"] != FRAGMENT_KIND:
        raise ApuntadorLeakBaselineError(f"{label}.kind drifted")
    scenario_id = fragment["scenario"]
    if scenario_id not in contract["scenarios"]:
        raise ApuntadorLeakBaselineError(f"{label}.scenario is unknown")
    exact_integer(fragment["leaksExitCode"], f"{label}.leaksExitCode", 0)
    exact_integer(fragment["leakCount"], f"{label}.leakCount", 0)
    exact_integer(fragment["leakedBytes"], f"{label}.leakedBytes", 0)
    raw_digests = fragment["evidenceSHA256"]
    if not isinstance(raw_digests, dict):
        raise ApuntadorLeakBaselineError(f"{label}.evidenceSHA256 must be an object")
    expected_evidence = contract["scenarios"][scenario_id]["evidence"]
    if tuple(raw_digests) != expected_evidence:
        raise ApuntadorLeakBaselineError(
            f"{label}.evidenceSHA256 inventory does not match"
        )
    if any(
        not isinstance(value, str) or SHA256.fullmatch(value) is None
        for value in raw_digests.values()
    ):
        raise ApuntadorLeakBaselineError(
            f"{label}.evidenceSHA256 contains an invalid digest"
        )
    return fragment


def safe_release_identity(version: Any, build: Any, commit: Any) -> dict[str, str]:
    version = safe_identifier(version, "release.version")
    build = safe_identifier(build, "release.build")
    if not isinstance(commit, str) or COMMIT.fullmatch(commit) is None:
        raise ApuntadorLeakBaselineError("release.commit is invalid")
    return {"version": version, "build": build, "commit": commit}


def command_output(arguments: Sequence[str], label: str) -> str:
    try:
        result = subprocess.run(
            arguments,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ApuntadorLeakBaselineError(f"{label} is unavailable") from error
    value = result.stdout.strip()
    if not value:
        raise ApuntadorLeakBaselineError(f"{label} is empty")
    return value


def host_identity() -> dict[str, str]:
    version = command_output(("sw_vers", "-productVersion"), "macOS version")
    build = command_output(("sw_vers", "-buildVersion"), "macOS build")
    architecture = platform.machine()
    if not architecture or len(architecture) > 32:
        raise ApuntadorLeakBaselineError("host architecture is invalid")
    return {
        "platform": "macOS",
        "version": version,
        "build": build,
        "architecture": architecture,
    }


def toolchain_identity() -> dict[str, str]:
    lines = command_output(("xcodebuild", "-version"), "Xcode version").splitlines()
    if len(lines) != 2 or not lines[0].startswith("Xcode ") or not lines[1].startswith(
        "Build version "
    ):
        raise ApuntadorLeakBaselineError("Xcode version output is malformed")
    return {
        "xcode": lines[0].removeprefix("Xcode "),
        "build": lines[1].removeprefix("Build version "),
        "leaksMode": "at-exit-no-content-no-stacks",
    }


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def assemble_receipt(
    contract: dict[str, Any],
    *,
    version: str,
    build: str,
    commit: str,
    fragments: Sequence[dict[str, Any]],
) -> dict[str, Any]:
    release = safe_release_identity(version, build, commit)
    by_scenario: dict[str, dict[str, Any]] = {}
    for index, raw_fragment in enumerate(fragments):
        fragment = validate_fragment(raw_fragment, contract, f"fragment[{index}]")
        identifier = fragment["scenario"]
        if identifier in by_scenario:
            raise ApuntadorLeakBaselineError(
                f"receipt repeats scenario: {identifier}"
            )
        by_scenario[identifier] = fragment
    if tuple(by_scenario) != contract["orderedScenarioIDs"]:
        raise ApuntadorLeakBaselineError(
            "receipt fragments must cover every scenario in canonical order"
        )
    scenarios = []
    for identifier in contract["orderedScenarioIDs"]:
        fragment = by_scenario[identifier]
        scenarios.append(
            {
                "id": identifier,
                "state": "pass",
                "leakCount": fragment["leakCount"],
                "leakedBytes": fragment["leakedBytes"],
                "evidenceSHA256": fragment["evidenceSHA256"],
            }
        )
    receipt = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": RECEIPT_KIND,
        "collectedAt": utc_now(),
        "release": release,
        "host": host_identity(),
        "toolchain": toolchain_identity(),
        "policies": contract["policies"],
        "scenarios": scenarios,
        "summary": {
            "scenarioCount": len(scenarios),
            "passed": len(scenarios),
            "leakCount": 0,
            "leakedBytes": 0,
        },
    }
    return validate_receipt(receipt, contract)


def validate_receipt(document: Any, contract: dict[str, Any]) -> dict[str, Any]:
    receipt = exact_object(
        document,
        "leak receipt",
        (
            "schemaVersion",
            "kind",
            "collectedAt",
            "release",
            "host",
            "toolchain",
            "policies",
            "scenarios",
            "summary",
        ),
    )
    exact_integer(receipt["schemaVersion"], "leak receipt.schemaVersion", 1)
    if receipt["kind"] != RECEIPT_KIND:
        raise ApuntadorLeakBaselineError("leak receipt kind drifted")
    collected_at = receipt["collectedAt"]
    if not isinstance(collected_at, str):
        raise ApuntadorLeakBaselineError("leak receipt.collectedAt is invalid")
    try:
        parsed = datetime.fromisoformat(collected_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise ApuntadorLeakBaselineError(
            "leak receipt.collectedAt is invalid"
        ) from error
    if parsed.tzinfo is None:
        raise ApuntadorLeakBaselineError("leak receipt.collectedAt has no timezone")
    release = exact_object(
        receipt["release"],
        "leak receipt.release",
        ("version", "build", "commit"),
    )
    safe_release_identity(release["version"], release["build"], release["commit"])
    host = exact_object(
        receipt["host"],
        "leak receipt.host",
        ("platform", "version", "build", "architecture"),
    )
    if host["platform"] != "macOS":
        raise ApuntadorLeakBaselineError("leak receipt host must be macOS")
    for key in ("version", "build", "architecture"):
        safe_identifier(host[key], f"leak receipt.host.{key}")
    toolchain = exact_object(
        receipt["toolchain"],
        "leak receipt.toolchain",
        ("xcode", "build", "leaksMode"),
    )
    safe_identifier(toolchain["xcode"], "leak receipt.toolchain.xcode")
    safe_identifier(toolchain["build"], "leak receipt.toolchain.build")
    if toolchain["leaksMode"] != "at-exit-no-content-no-stacks":
        raise ApuntadorLeakBaselineError("leak receipt tool mode drifted")
    if receipt["policies"] != contract["policies"]:
        raise ApuntadorLeakBaselineError("leak receipt policies drifted")
    raw_scenarios = receipt["scenarios"]
    if not isinstance(raw_scenarios, list):
        raise ApuntadorLeakBaselineError("leak receipt.scenarios must be an array")
    scenario_ids: list[str] = []
    for index, raw in enumerate(raw_scenarios):
        scenario = exact_object(
            raw,
            f"leak receipt.scenarios[{index}]",
            ("id", "state", "leakCount", "leakedBytes", "evidenceSHA256"),
        )
        identifier = scenario["id"]
        if identifier not in contract["scenarios"] or identifier in scenario_ids:
            raise ApuntadorLeakBaselineError(
                f"leak receipt.scenarios[{index}].id is invalid"
            )
        scenario_ids.append(identifier)
        if scenario["state"] != "pass":
            raise ApuntadorLeakBaselineError(
                f"leak receipt scenario {identifier} did not pass"
            )
        exact_integer(
            scenario["leakCount"],
            f"leak receipt scenario {identifier}.leakCount",
            contract["maximumLeaks"],
        )
        exact_integer(
            scenario["leakedBytes"],
            f"leak receipt scenario {identifier}.leakedBytes",
            contract["maximumLeakedBytes"],
        )
        digests = scenario["evidenceSHA256"]
        expected_evidence = contract["scenarios"][identifier]["evidence"]
        if not isinstance(digests, dict) or tuple(digests) != expected_evidence:
            raise ApuntadorLeakBaselineError(
                f"leak receipt scenario {identifier} evidence inventory drifted"
            )
        if any(
            not isinstance(value, str) or SHA256.fullmatch(value) is None
            for value in digests.values()
        ):
            raise ApuntadorLeakBaselineError(
                f"leak receipt scenario {identifier} has an invalid digest"
            )
    if tuple(scenario_ids) != contract["orderedScenarioIDs"]:
        raise ApuntadorLeakBaselineError("leak receipt scenario order drifted")
    summary = exact_object(
        receipt["summary"],
        "leak receipt.summary",
        ("scenarioCount", "passed", "leakCount", "leakedBytes"),
    )
    expected_count = len(contract["orderedScenarioIDs"])
    exact_integer(summary["scenarioCount"], "leak receipt.summary.scenarioCount", expected_count)
    exact_integer(summary["passed"], "leak receipt.summary.passed", expected_count)
    exact_integer(summary["leakCount"], "leak receipt.summary.leakCount", 0)
    exact_integer(summary["leakedBytes"], "leak receipt.summary.leakedBytes", 0)
    return receipt


def write_json(path: Path, document: Any) -> None:
    if path.exists() or path.is_symlink():
        raise ApuntadorLeakBaselineError(f"output already exists: {path}")
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def parse(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    subparsers = parser.add_subparsers(dest="command", required=True)

    observe = subparsers.add_parser("observe")
    observe.add_argument("--scenario", required=True)
    observe.add_argument("--log", required=True, type=Path)
    observe.add_argument("--evidence", action="append", default=[])
    observe.add_argument("--exit-code", required=True, type=int)
    observe.add_argument("--commit", required=True)
    observe.add_argument("--build", required=True)
    observe.add_argument("--output", required=True, type=Path)

    assemble = subparsers.add_parser("assemble")
    assemble.add_argument("--version", required=True)
    assemble.add_argument("--build", required=True)
    assemble.add_argument("--commit", required=True)
    assemble.add_argument("--fragment", action="append", type=Path, default=[])
    assemble.add_argument("--output", required=True, type=Path)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--receipt", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse(argv)
    try:
        contract = load_contract(arguments.contract)
        if arguments.command == "observe":
            document = observe_run(
                contract,
                scenario_id=arguments.scenario,
                log_path=arguments.log,
                evidence=evidence_arguments(arguments.evidence),
                exit_code=arguments.exit_code,
                commit=arguments.commit,
                build=arguments.build,
            )
            write_json(arguments.output, document)
        elif arguments.command == "assemble":
            fragments = [
                load_json(path, f"leak fragment {index}")
                for index, path in enumerate(arguments.fragment)
            ]
            document = assemble_receipt(
                contract,
                version=arguments.version,
                build=arguments.build,
                commit=arguments.commit,
                fragments=fragments,
            )
            write_json(arguments.output, document)
        else:
            validate_receipt(
                load_json(arguments.receipt, "leak receipt"), contract
            )
        return 0
    except ApuntadorLeakBaselineError as error:
        print(f"apuntador leak baseline error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
