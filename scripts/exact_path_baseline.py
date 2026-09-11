#!/usr/bin/env python3
"""Explicitly review and retain one exact-path research baseline."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path
from typing import Any

import exact_path_cross_host as cross_host
import exact_path_matrix as host_matrix
from private_research_baseline import (
    BaselineError,
    BaselineNotAdmissible,
    CommandRunner,
    read_bounded_bytes,
    require_source_checkout,
    run_command,
    sha256_bytes,
    validate_commit,
    validate_output_destination,
    validate_sha256,
    withdraw_output,
    write_owner_only,
)


REPOSITORY = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = (
    REPOSITORY / "docs" / "evidence" / "exact-path-baseline-admission.json"
)
ADMISSION_CONTRACT_KEYS = {
    "schemaVersion",
    "baselineSchemaVersion",
    "scorecardSchemaVersion",
    "hostReceiptSchemaVersion",
    "reviewPolicyVersion",
    "authority",
    "engineDecision",
    "maximumReceiptStreamBytes",
    "maximumScorecardBytes",
    "maximumBaselineBytes",
}
BASELINE_KEYS = {
    "schemaVersion",
    "kind",
    "retainedAt",
    "reviewPolicyVersion",
    "authority",
    "engineDecision",
    "sourceCommit",
    "scorecardFileSHA256",
    "hostReceiptSetSHA256",
    "scorecard",
    "hostReceipts",
}


def load_contract(
    path: Path,
    cross_contract: dict[str, Any],
    host_contract: dict[str, Any],
) -> dict[str, Any]:
    try:
        raw = host_matrix.exact_object(
            host_matrix.read_json(path, "baseline admission contract"),
            ADMISSION_CONTRACT_KEYS,
            "baseline admission contract",
        )
        if host_matrix.integer(raw["schemaVersion"], "admission.schemaVersion", 1) != 1:
            raise BaselineError("baseline admission schema is not supported")
        if (
            host_matrix.integer(
                raw["baselineSchemaVersion"],
                "admission.baselineSchemaVersion",
                1,
            )
            != 1
        ):
            raise BaselineError("baseline document schema is not supported")
        if (
            host_matrix.integer(
                raw["scorecardSchemaVersion"],
                "admission.scorecardSchemaVersion",
                1,
            )
            != cross_contract["scorecardSchemaVersion"]
        ):
            raise BaselineError("baseline scorecard schema is inconsistent")
        if (
            host_matrix.integer(
                raw["hostReceiptSchemaVersion"],
                "admission.hostReceiptSchemaVersion",
                1,
            )
            != host_contract["hostReceiptSchemaVersion"]
        ):
            raise BaselineError("baseline host receipt schema is inconsistent")
        if raw["reviewPolicyVersion"] != "explicit-scorecard-digest-and-source-v1":
            raise BaselineError("baseline review policy is not supported")
        if raw["authority"] != "research-comparison-only":
            raise BaselineError("baseline authority cannot select a product engine")
        if raw["engineDecision"] != "not-evaluated":
            raise BaselineError("baseline contract cannot contain an engine decision")
        for key, expected in (
            ("maximumReceiptStreamBytes", 1_048_576),
            ("maximumScorecardBytes", 524_288),
            ("maximumBaselineBytes", 2_097_152),
        ):
            if host_matrix.integer(raw[key], f"admission.{key}", 1) != expected:
                raise BaselineError(f"baseline {key} is not supported")
    except host_matrix.MatrixError as error:
        raise BaselineError(str(error)) from error
    return raw


def parse_json_bytes(data: bytes, label: str) -> Any:
    try:
        text = data.decode("utf-8")
        return json.loads(
            text,
            object_pairs_hook=host_matrix.reject_duplicate_keys,
            parse_constant=lambda value: (_ for _ in ()).throw(
                BaselineError(f"{label} contains non-finite JSON: {value}")
            ),
        )
    except UnicodeDecodeError as error:
        raise BaselineError(f"{label} is not valid UTF-8 JSON") from error
    except json.JSONDecodeError as error:
        raise BaselineError(f"{label} is not valid JSON") from error
    except host_matrix.MatrixError as error:
        raise BaselineError(str(error)) from error


def read_bounded_json(
    path: Path,
    label: str,
    maximum_bytes: int,
) -> tuple[Any, bytes]:
    data = read_bounded_bytes(path, label, maximum_bytes)
    return parse_json_bytes(data, label), data


def read_bounded_receipts(path: Path, maximum_bytes: int) -> list[Any]:
    data = read_bounded_bytes(path, "host receipt stream", maximum_bytes)
    try:
        text = data.decode("utf-8")
        return cross_host.parse_receipts(text)
    except UnicodeDecodeError as error:
        raise BaselineError(
            "host receipt stream is not valid UTF-8 JSONL"
        ) from error
    except cross_host.CrossHostError as error:
        raise BaselineError(str(error)) from error


def canonical_bytes(value: Any, label: str) -> bytes:
    return cross_host.canonical_document(value, label).encode("utf-8")


def canonical_scorecard_file_bytes(value: Any) -> bytes:
    return canonical_bytes(value, "cross-host scorecard") + b"\n"


def retained_timestamp(value: str | None = None) -> str:
    timestamp = value or dt.datetime.now(dt.timezone.utc).isoformat().replace(
        "+00:00", "Z"
    )
    try:
        return host_matrix.utc_timestamp(timestamp, "baseline.retainedAt")
    except host_matrix.MatrixError as error:
        raise BaselineError(str(error)) from error


def validated_receipts_in_profile_order(
    raw_receipts: list[Any],
    cross_contract: dict[str, Any],
    host_contract: dict[str, Any],
    profiles: dict[str, tuple[int, int | None]],
) -> list[dict[str, Any]]:
    validated = []
    for index, raw in enumerate(raw_receipts):
        try:
            validated.append(
                host_matrix.validate_host_receipt(
                    raw,
                    host_contract,
                    profiles,
                    f"host receipts[{index}]",
                )
            )
        except host_matrix.MatrixError as error:
            raise BaselineError(str(error)) from error
    by_profile = {receipt["hostProfile"]: receipt for receipt in validated}
    required = cross_contract["requiredHostProfiles"]
    if len(validated) != len(required) or set(by_profile) != set(required):
        raise BaselineError("baseline host receipts lost canonical profile coverage")
    return [by_profile[profile] for profile in required]


def scorecard_source_commit(scorecard: dict[str, Any]) -> str:
    commits = scorecard["comparability"]["sourceCommits"]
    if not isinstance(commits, list) or len(commits) != 1:
        raise BaselineNotAdmissible(
            "cross-host scorecard does not identify one source commit"
        )
    return validate_commit(commits[0], "scorecard source commit")


def build_baseline(
    raw_scorecard: Any,
    raw_receipts: list[Any],
    admission_contract: dict[str, Any],
    cross_contract: dict[str, Any],
    host_contract: dict[str, Any],
    profiles: dict[str, tuple[int, int | None]],
    *,
    scorecard_file_sha256: str,
    accepted_source_commit: str,
    retained_at: str | None = None,
) -> dict[str, Any]:
    try:
        scorecard = cross_host.validate_scorecard_against_receipts(
            raw_scorecard,
            raw_receipts,
            cross_contract,
            host_contract,
            profiles,
        )
    except cross_host.CrossHostError as error:
        raise BaselineError(str(error)) from error
    if scorecard["outcome"] != "pass":
        raise BaselineNotAdmissible("cross-host scorecard is blocked")
    source_commit = scorecard_source_commit(scorecard)
    accepted_source_commit = validate_commit(
        accepted_source_commit,
        "accepted source commit",
    )
    if source_commit != accepted_source_commit:
        raise BaselineError("accepted source commit does not match the scorecard")
    scorecard_file_sha256 = validate_sha256(
        scorecard_file_sha256,
        "accepted scorecard digest",
    )
    expected_scorecard_sha256 = sha256_bytes(
        canonical_scorecard_file_bytes(scorecard)
    )
    if scorecard_file_sha256 != expected_scorecard_sha256:
        raise BaselineError("accepted scorecard digest is inconsistent")
    receipts = validated_receipts_in_profile_order(
        raw_receipts,
        cross_contract,
        host_contract,
        profiles,
    )
    baseline = {
        "schemaVersion": admission_contract["baselineSchemaVersion"],
        "kind": "exact-path-shadow-cross-host-research-baseline",
        "retainedAt": retained_timestamp(retained_at),
        "reviewPolicyVersion": admission_contract["reviewPolicyVersion"],
        "authority": admission_contract["authority"],
        "engineDecision": admission_contract["engineDecision"],
        "sourceCommit": source_commit,
        "scorecardFileSHA256": scorecard_file_sha256,
        "hostReceiptSetSHA256": sha256_bytes(
            canonical_bytes(receipts, "host receipt set")
        ),
        "scorecard": scorecard,
        "hostReceipts": receipts,
    }
    if len(canonical_bytes(baseline, "baseline")) > admission_contract[
        "maximumBaselineBytes"
    ]:
        raise BaselineError("baseline exceeds its size limit")
    return baseline


def validate_baseline(
    raw: Any,
    admission_contract: dict[str, Any],
    cross_contract: dict[str, Any],
    host_contract: dict[str, Any],
    profiles: dict[str, tuple[int, int | None]],
) -> dict[str, Any]:
    try:
        baseline = host_matrix.exact_object(raw, BASELINE_KEYS, "baseline")
        if (
            host_matrix.integer(
                baseline["schemaVersion"],
                "baseline.schemaVersion",
                1,
            )
            != admission_contract["baselineSchemaVersion"]
        ):
            raise BaselineError("baseline schema is not supported")
        if baseline["kind"] != "exact-path-shadow-cross-host-research-baseline":
            raise BaselineError("baseline kind is not supported")
        host_matrix.utc_timestamp(baseline["retainedAt"], "baseline.retainedAt")
    except host_matrix.MatrixError as error:
        raise BaselineError(str(error)) from error
    for key in ("reviewPolicyVersion", "authority", "engineDecision"):
        if baseline[key] != admission_contract[key]:
            raise BaselineError(f"baseline {key} is inconsistent")
    source_commit = validate_commit(baseline["sourceCommit"], "baseline sourceCommit")
    receipts = baseline["hostReceipts"]
    if not isinstance(receipts, list):
        raise BaselineError("baseline hostReceipts must be an array")
    canonical_receipts = validated_receipts_in_profile_order(
        receipts,
        cross_contract,
        host_contract,
        profiles,
    )
    if canonical_bytes(receipts, "baseline host receipts") != canonical_bytes(
        canonical_receipts,
        "canonical host receipts",
    ):
        raise BaselineError("baseline host receipts are not in canonical profile order")
    try:
        scorecard = cross_host.validate_scorecard_against_receipts(
            baseline["scorecard"],
            receipts,
            cross_contract,
            host_contract,
            profiles,
        )
    except cross_host.CrossHostError as error:
        raise BaselineError(str(error)) from error
    if scorecard["outcome"] != "pass":
        raise BaselineNotAdmissible("baseline scorecard is blocked")
    if scorecard_source_commit(scorecard) != source_commit:
        raise BaselineError("baseline sourceCommit is inconsistent")
    expected_digests = (
        (
            "scorecardFileSHA256",
            sha256_bytes(canonical_scorecard_file_bytes(scorecard)),
        ),
        (
            "hostReceiptSetSHA256",
            sha256_bytes(canonical_bytes(receipts, "baseline host receipt set")),
        ),
    )
    for key, expected in expected_digests:
        value = validate_sha256(baseline[key], f"baseline {key}")
        if value != expected:
            raise BaselineError(f"baseline {key} is inconsistent")
    if len(canonical_bytes(baseline, "baseline")) > admission_contract[
        "maximumBaselineBytes"
    ]:
        raise BaselineError("baseline exceeds its size limit")
    return baseline


def admit_baseline(
    receipt_path: Path,
    scorecard_path: Path,
    output_path: Path,
    *,
    accepted_scorecard_sha256: str,
    accepted_source_commit: str,
    root: Path = REPOSITORY,
    contract_path: Path = DEFAULT_CONTRACT,
    cross_contract_path: Path = cross_host.DEFAULT_CONTRACT,
    host_contract_path: Path = host_matrix.DEFAULT_CONTRACT,
    resource_contract_path: Path = host_matrix.DEFAULT_RESOURCE_CONTRACT,
    runner: CommandRunner = run_command,
    retained_at: str | None = None,
) -> tuple[dict[str, Any], Path]:
    accepted_scorecard_sha256 = validate_sha256(
        accepted_scorecard_sha256,
        "accepted scorecard digest",
    )
    accepted_source_commit = validate_commit(
        accepted_source_commit,
        "accepted source commit",
    )
    root = root.resolve()
    require_source_checkout(root, accepted_source_commit, runner)
    try:
        host_contract = host_matrix.load_contract(host_contract_path)
        profiles = host_matrix.load_profiles(resource_contract_path)
        cross_contract = cross_host.load_contract(
            cross_contract_path,
            host_contract,
        )
    except (host_matrix.MatrixError, cross_host.CrossHostError) as error:
        raise BaselineError(str(error)) from error
    admission_contract = load_contract(
        contract_path,
        cross_contract,
        host_contract,
    )
    receipts = read_bounded_receipts(
        receipt_path,
        admission_contract["maximumReceiptStreamBytes"],
    )
    scorecard, scorecard_file = read_bounded_json(
        scorecard_path,
        "cross-host scorecard",
        admission_contract["maximumScorecardBytes"],
    )
    if scorecard_file != canonical_scorecard_file_bytes(scorecard):
        raise BaselineError("cross-host scorecard file is not canonical D216 stdout")
    actual_scorecard_sha256 = sha256_bytes(scorecard_file)
    if actual_scorecard_sha256 != accepted_scorecard_sha256:
        raise BaselineError("accepted scorecard digest does not match the file")
    baseline = build_baseline(
        scorecard,
        receipts,
        admission_contract,
        cross_contract,
        host_contract,
        profiles,
        scorecard_file_sha256=actual_scorecard_sha256,
        accepted_source_commit=accepted_source_commit,
        retained_at=retained_at,
    )
    validate_baseline(
        baseline,
        admission_contract,
        cross_contract,
        host_contract,
        profiles,
    )
    output = validate_output_destination(
        output_path,
        (receipt_path, scorecard_path),
        root,
        runner,
    )
    require_source_checkout(root, accepted_source_commit, runner)
    write_owner_only(
        output,
        baseline,
        admission_contract["maximumBaselineBytes"],
    )
    try:
        require_source_checkout(root, accepted_source_commit, runner)
    except BaselineError:
        withdraw_output(output)
        raise
    return baseline, output


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipts", type=Path, required=True)
    parser.add_argument("--scorecard", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--accept-scorecard-sha256", required=True)
    parser.add_argument("--accept-source-commit", required=True)
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument(
        "--cross-host-contract",
        type=Path,
        default=cross_host.DEFAULT_CONTRACT,
    )
    parser.add_argument(
        "--host-contract",
        type=Path,
        default=host_matrix.DEFAULT_CONTRACT,
    )
    parser.add_argument(
        "--resource-contract",
        type=Path,
        default=host_matrix.DEFAULT_RESOURCE_CONTRACT,
    )
    return parser


def main_from_args(
    arguments: list[str] | None = None,
    *,
    root: Path = REPOSITORY,
    runner: CommandRunner = run_command,
) -> int:
    options = build_parser().parse_args(arguments)
    _, output = admit_baseline(
        options.receipts,
        options.scorecard,
        options.output,
        accepted_scorecard_sha256=options.accept_scorecard_sha256,
        accepted_source_commit=options.accept_source_commit,
        root=root,
        contract_path=options.contract,
        cross_contract_path=options.cross_host_contract,
        host_contract_path=options.host_contract,
        resource_contract_path=options.resource_contract,
        runner=runner,
    )
    print(f"Retained exact-path research baseline: {output}")
    return 0


def main(
    arguments: list[str] | None = None,
    *,
    root: Path = REPOSITORY,
    runner: CommandRunner = run_command,
) -> int:
    try:
        return main_from_args(arguments, root=root, runner=runner)
    except BaselineNotAdmissible as error:
        print(f"exact-path baseline not admitted: {error}", file=sys.stderr)
        return 1
    except BaselineError as error:
        print(f"exact-path baseline error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
