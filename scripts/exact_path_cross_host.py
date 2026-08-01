#!/usr/bin/env python3
"""Validate comparable content-free exact-path receipts across supported Macs."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import sys
from pathlib import Path
from typing import Any

import exact_path_matrix as host_matrix


REPOSITORY = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = (
    REPOSITORY / "docs" / "evidence" / "exact-path-cross-host-matrix.json"
)
CROSS_HOST_CONTRACT_KEYS = {
    "schemaVersion",
    "scorecardSchemaVersion",
    "hostReceiptContractSchemaVersion",
    "hostReceiptSchemaVersion",
    "comparisonPolicyVersion",
    "requiredHostProfiles",
    "requiredOperatingSystemMajors",
}
SCORECARD_KEYS = {
    "schemaVersion",
    "kind",
    "generatedAt",
    "comparisonPolicyVersion",
    "outcome",
    "coverage",
    "comparability",
    "profiles",
}


class CrossHostError(ValueError):
    """The supplied receipts cannot form a trustworthy cross-host scorecard."""


def parse_receipts(text: str) -> list[Any]:
    receipts = []
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        if not raw_line.strip():
            continue
        try:
            receipts.append(
                json.loads(
                    raw_line,
                    object_pairs_hook=host_matrix.reject_duplicate_keys,
                    parse_constant=lambda value: (_ for _ in ()).throw(
                        CrossHostError(
                            f"host receipt line {line_number} contains non-finite JSON: {value}"
                        )
                    ),
                )
            )
        except json.JSONDecodeError as error:
            raise CrossHostError(
                f"host receipt line {line_number} is not valid JSON"
            ) from error
        except host_matrix.MatrixError as error:
            raise CrossHostError(str(error)) from error
    return receipts


def read_receipts(path: Path) -> list[Any]:
    try:
        text = sys.stdin.read() if str(path) == "-" else path.read_text(encoding="utf-8")
    except OSError as error:
        raise CrossHostError("cannot read host receipt stream") from error
    return parse_receipts(text)


def load_contract(path: Path, host_contract: dict[str, Any]) -> dict[str, Any]:
    try:
        raw = host_matrix.exact_object(
            host_matrix.read_json(path, "cross-host contract"),
            CROSS_HOST_CONTRACT_KEYS,
            "cross-host contract",
        )
        if host_matrix.integer(raw["schemaVersion"], "cross-host schemaVersion", 1) != 1:
            raise CrossHostError("cross-host schemaVersion must be 1")
        if (
            host_matrix.integer(
                raw["scorecardSchemaVersion"],
                "cross-host scorecardSchemaVersion",
                1,
            )
            != 1
        ):
            raise CrossHostError("cross-host scorecard schema is not supported")
        if (
            host_matrix.integer(
                raw["hostReceiptContractSchemaVersion"],
                "cross-host hostReceiptContractSchemaVersion",
                1,
            )
            != host_contract["schemaVersion"]
        ):
            raise CrossHostError("cross-host host contract schema is inconsistent")
        if (
            host_matrix.integer(
                raw["hostReceiptSchemaVersion"],
                "cross-host hostReceiptSchemaVersion",
                1,
            )
            != host_contract["hostReceiptSchemaVersion"]
        ):
            raise CrossHostError("cross-host host receipt schema is inconsistent")
        if raw["comparisonPolicyVersion"] != "within-host-query-p50-p95-ratio-v1":
            raise CrossHostError("cross-host comparison policy is not supported")
    except host_matrix.MatrixError as error:
        raise CrossHostError(str(error)) from error

    profiles = raw["requiredHostProfiles"]
    if profiles != ["memory-8gb", "memory-16gb", "reference"]:
        raise CrossHostError("cross-host profiles are not supported")
    majors = raw["requiredOperatingSystemMajors"]
    if (
        not isinstance(majors, list)
        or any(isinstance(value, bool) or not isinstance(value, int) for value in majors)
        or majors != host_contract["supportedOperatingSystemMajors"]
    ):
        raise CrossHostError("cross-host operating-system coverage is inconsistent")
    return raw


def operating_system_major(receipt: dict[str, Any]) -> int:
    match = host_matrix.OPERATING_SYSTEM.fullmatch(receipt["host"]["operatingSystem"])
    if match is None:
        raise CrossHostError("validated host receipt lost its operating-system identity")
    return int(match.group(1))


def query_ratio(candidate: float | int, control: float | int) -> float | None:
    control_value = float(control)
    if control_value == 0:
        return None
    ratio = float(candidate) / control_value
    return ratio if math.isfinite(ratio) else None


def scale_row(scale: dict[str, Any]) -> dict[str, Any]:
    if scale["state"] == "incomplete":
        return {
            "corpusSize": scale["corpusSize"],
            "state": scale["state"],
            "rawEmbeddingBytes": scale["rawEmbeddingBytes"],
            "controlDatabaseBytes": scale["controlDatabaseBytes"],
            "engines": [],
            "candidateToControlQueryP50Ratio": None,
            "candidateToControlQueryP95Ratio": None,
            "exactRankAgreementRate": None,
        }
    engines = []
    for engine in scale["engines"]:
        engines.append(
            {
                "engine": engine["engine"],
                "buildP50Milliseconds": engine["buildMilliseconds"]["p50"],
                "queryP50Milliseconds": engine["queryWallMilliseconds"][
                    "p50Observation"
                ]["p50"],
                "queryP95Milliseconds": engine["queryWallMilliseconds"][
                    "p95Observation"
                ]["p95"],
            }
        )
    agreement = scale["agreement"]
    p50_ratio = query_ratio(
        engines[1]["queryP50Milliseconds"],
        engines[0]["queryP50Milliseconds"],
    )
    p95_ratio = query_ratio(
        engines[1]["queryP95Milliseconds"],
        engines[0]["queryP95Milliseconds"],
    )
    state = scale["state"]
    if state == "pass" and (p50_ratio is None or p95_ratio is None):
        state = "not-comparable"
    return {
        "corpusSize": scale["corpusSize"],
        "state": state,
        "rawEmbeddingBytes": scale["rawEmbeddingBytes"],
        "controlDatabaseBytes": scale["controlDatabaseBytes"],
        "engines": engines,
        "candidateToControlQueryP50Ratio": p50_ratio,
        "candidateToControlQueryP95Ratio": p95_ratio,
        "exactRankAgreementRate": (
            agreement["exactRankMatchCount"] / agreement["comparisonCount"]
        ),
    }


def profile_row(profile: str, receipt: dict[str, Any] | None) -> dict[str, Any]:
    if receipt is None:
        return {
            "profile": profile,
            "state": "missing",
            "operatingSystemMajor": None,
            "host": None,
            "scales": [],
        }
    scales = [scale_row(scale) for scale in receipt["scales"]]
    state = receipt["outcome"]
    if state == "pass" and any(scale["state"] != "pass" for scale in scales):
        state = "not-comparable"
    return {
        "profile": profile,
        "state": state,
        "operatingSystemMajor": operating_system_major(receipt),
        "host": receipt["host"],
        "scales": scales,
    }


def build_scorecard(
    raw_receipts: list[Any],
    cross_contract: dict[str, Any],
    host_contract: dict[str, Any],
    profiles: dict[str, tuple[int, int | None]],
    generated_at: str | None = None,
) -> dict[str, Any]:
    canonical = [
        json.dumps(value, sort_keys=True, separators=(",", ":"))
        for value in raw_receipts
    ]
    if len(set(canonical)) != len(canonical):
        raise CrossHostError("host receipt stream repeats an identical receipt")
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
            raise CrossHostError(str(error)) from error

    by_profile = {}
    for receipt in validated:
        profile = receipt["hostProfile"]
        if profile in by_profile:
            raise CrossHostError(f"host receipt stream repeats profile: {profile}")
        by_profile[profile] = receipt

    required_profiles = cross_contract["requiredHostProfiles"]
    present_profiles = [profile for profile in required_profiles if profile in by_profile]
    missing_profiles = [profile for profile in required_profiles if profile not in by_profile]
    present_majors = sorted({operating_system_major(receipt) for receipt in validated})
    required_majors = cross_contract["requiredOperatingSystemMajors"]
    missing_majors = [major for major in required_majors if major not in present_majors]
    source_commits = sorted({receipt["sourceCommit"] for receipt in validated})
    toolchains = sorted({receipt["toolchain"] for receipt in validated})
    rows = [profile_row(profile, by_profile.get(profile)) for profile in required_profiles]
    comparable = len(source_commits) == 1 and len(toolchains) == 1
    complete = not missing_profiles and not missing_majors
    outcome = (
        "pass"
        if complete and comparable and all(row["state"] == "pass" for row in rows)
        else "blocked"
    )
    if generated_at is None:
        timestamp = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    else:
        try:
            timestamp = host_matrix.utc_timestamp(generated_at, "scorecard.generatedAt")
        except host_matrix.MatrixError as error:
            raise CrossHostError(str(error)) from error
    return {
        "schemaVersion": cross_contract["scorecardSchemaVersion"],
        "kind": "exact-path-shadow-cross-host-scorecard",
        "generatedAt": timestamp,
        "comparisonPolicyVersion": cross_contract["comparisonPolicyVersion"],
        "outcome": outcome,
        "coverage": {
            "requiredHostProfiles": required_profiles,
            "presentHostProfiles": present_profiles,
            "missingHostProfiles": missing_profiles,
            "requiredOperatingSystemMajors": required_majors,
            "presentOperatingSystemMajors": present_majors,
            "missingOperatingSystemMajors": missing_majors,
        },
        "comparability": {
            "sameSourceCommit": len(source_commits) == 1,
            "sourceCommits": source_commits,
            "sameToolchain": len(toolchains) == 1,
            "toolchains": toolchains,
        },
        "profiles": rows,
    }


def canonical_document(value: Any, label: str) -> str:
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
    except (TypeError, ValueError) as error:
        raise CrossHostError(f"{label} is not canonical JSON") from error


def validate_scorecard_against_receipts(
    raw: Any,
    raw_receipts: list[Any],
    cross_contract: dict[str, Any],
    host_contract: dict[str, Any],
    profiles: dict[str, tuple[int, int | None]],
    label: str = "cross-host scorecard",
) -> dict[str, Any]:
    try:
        scorecard = host_matrix.exact_object(raw, SCORECARD_KEYS, label)
        generated_at = host_matrix.utc_timestamp(
            scorecard["generatedAt"],
            f"{label}.generatedAt",
        )
    except host_matrix.MatrixError as error:
        raise CrossHostError(str(error)) from error
    expected = build_scorecard(
        raw_receipts,
        cross_contract,
        host_contract,
        profiles,
        generated_at=generated_at,
    )
    if canonical_document(scorecard, label) != canonical_document(
        expected,
        "recomputed cross-host scorecard",
    ):
        raise CrossHostError(
            f"{label} does not exactly match its receipts and active contracts"
        )
    return scorecard


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate content-free exact-path receipts across supported Macs."
    )
    parser.add_argument("--input", type=Path, required=True, help="JSONL receipts or -")
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
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


def main_from_args(arguments: list[str] | None = None) -> int:
    options = build_parser().parse_args(arguments)
    try:
        host_contract = host_matrix.load_contract(options.host_contract)
        profiles = host_matrix.load_profiles(options.resource_contract)
        cross_contract = load_contract(options.contract, host_contract)
        receipts = read_receipts(options.input)
        scorecard = build_scorecard(
            receipts,
            cross_contract,
            host_contract,
            profiles,
        )
    except host_matrix.MatrixError as error:
        raise CrossHostError(str(error)) from error
    print(json.dumps(scorecard, sort_keys=True, separators=(",", ":")))
    return 0 if scorecard["outcome"] == "pass" else 1


def main() -> int:
    try:
        return main_from_args()
    except CrossHostError as error:
        print(f"exact-path cross-host error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
