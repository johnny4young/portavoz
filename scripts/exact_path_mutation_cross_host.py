#!/usr/bin/env python3
"""Build a threshold-free cross-host review of mutation evidence."""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import sys
from pathlib import Path
from typing import Any


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))

import exact_path_mutation_matrix as host_matrix


foundation = host_matrix.foundation
REPOSITORY = SCRIPT_DIRECTORY.parent
DEFAULT_CONTRACT = (
    REPOSITORY
    / "docs"
    / "evidence"
    / "exact-path-mutation-cross-host-matrix.json"
)

CROSS_HOST_CONTRACT_KEYS = {
    "schemaVersion",
    "scorecardSchemaVersion",
    "hostReceiptContractSchemaVersion",
    "hostReceiptSchemaVersion",
    "hostReviewPolicyVersion",
    "crossHostReviewPolicyVersion",
    "requiredHostProfiles",
    "requiredOperatingSystemMajors",
}
SCORECARD_KEYS = {
    "schemaVersion",
    "kind",
    "generatedAt",
    "fixtureVersion",
    "measurementPolicyVersion",
    "hostReviewPolicyVersion",
    "crossHostReviewPolicyVersion",
    "buildConfiguration",
    "outcome",
    "coverage",
    "comparability",
    "profiles",
}


class CrossHostMutationError(ValueError):
    """The supplied receipts cannot form a trustworthy review scorecard."""


def parse_receipts(text: str) -> list[Any]:
    receipts = []
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        if not raw_line.strip():
            continue
        try:
            receipts.append(
                json.loads(
                    raw_line,
                    object_pairs_hook=foundation.reject_duplicate_keys,
                    parse_constant=lambda value: (_ for _ in ()).throw(
                        CrossHostMutationError(
                            "mutation host receipt line "
                            f"{line_number} contains non-finite JSON: {value}"
                        )
                    ),
                )
            )
        except json.JSONDecodeError as error:
            raise CrossHostMutationError(
                f"mutation host receipt line {line_number} is not valid JSON"
            ) from error
        except host_matrix.MatrixError as error:
            raise CrossHostMutationError(str(error)) from error
    return receipts


def read_receipts(path: Path) -> list[Any]:
    try:
        text = sys.stdin.read() if str(path) == "-" else path.read_text(
            encoding="utf-8"
        )
    except OSError as error:
        raise CrossHostMutationError(
            "cannot read mutation host receipt stream"
        ) from error
    return parse_receipts(text)


def load_contract(
    path: Path,
    host_contract: dict[str, Any],
) -> dict[str, Any]:
    try:
        raw = foundation.exact_object(
            foundation.read_json(path, "mutation cross-host contract"),
            CROSS_HOST_CONTRACT_KEYS,
            "mutation cross-host contract",
        )
        for key in (
            "schemaVersion",
            "scorecardSchemaVersion",
            "hostReceiptContractSchemaVersion",
            "hostReceiptSchemaVersion",
        ):
            foundation.integer(raw[key], f"mutation cross-host contract.{key}", 1)
    except host_matrix.MatrixError as error:
        raise CrossHostMutationError(str(error)) from error

    if raw["schemaVersion"] != 1 or raw["scorecardSchemaVersion"] != 1:
        raise CrossHostMutationError(
            "mutation cross-host scorecard contract is not supported"
        )
    if raw["hostReceiptContractSchemaVersion"] != host_contract["schemaVersion"]:
        raise CrossHostMutationError(
            "mutation host contract schema is inconsistent"
        )
    if raw["hostReceiptSchemaVersion"] != host_contract["hostReceiptSchemaVersion"]:
        raise CrossHostMutationError(
            "mutation host receipt schema is inconsistent"
        )
    if raw["hostReviewPolicyVersion"] != host_contract["reviewPolicyVersion"]:
        raise CrossHostMutationError(
            "mutation host review policy is inconsistent"
        )
    if (
        raw["crossHostReviewPolicyVersion"]
        != "human-threshold-free-mutation-cross-host-review-v1"
    ):
        raise CrossHostMutationError(
            "mutation cross-host review policy is not supported"
        )
    if raw["requiredHostProfiles"] != [
        "memory-8gb",
        "memory-16gb",
        "reference",
    ]:
        raise CrossHostMutationError(
            "mutation cross-host profiles are not supported"
        )
    majors = raw["requiredOperatingSystemMajors"]
    if (
        not isinstance(majors, list)
        or any(isinstance(value, bool) or not isinstance(value, int) for value in majors)
        or majors != host_contract["supportedOperatingSystemMajors"]
    ):
        raise CrossHostMutationError(
            "mutation cross-host operating-system coverage is inconsistent"
        )
    return raw


def operating_system_major(receipt: dict[str, Any]) -> int:
    match = foundation.OPERATING_SYSTEM.fullmatch(
        receipt["host"]["operatingSystem"]
    )
    if match is None:
        raise CrossHostMutationError(
            "validated mutation receipt lost its operating-system identity"
        )
    return int(match.group(1))


def scale_row(scale: dict[str, Any]) -> dict[str, Any]:
    return {
        "corpusSize": scale["corpusSize"],
        "state": scale["state"],
        "observationCount": scale["observationCount"],
        "rawEmbeddingBytes": scale["rawEmbeddingBytes"],
        "fixturePreparationMilliseconds": copy.deepcopy(
            scale["fixturePreparationMilliseconds"]
        ),
        "engines": copy.deepcopy(scale["engines"]),
        "agreement": copy.deepcopy(scale["agreement"]),
    }


def profile_row(
    profile: str,
    receipt: dict[str, Any] | None,
) -> dict[str, Any]:
    if receipt is None:
        return {
            "profile": profile,
            "state": "missing",
            "receiptGeneratedAt": None,
            "operatingSystemMajor": None,
            "host": None,
            "scales": [],
        }
    return {
        "profile": profile,
        "state": receipt["outcome"],
        "receiptGeneratedAt": receipt["generatedAt"],
        "operatingSystemMajor": operating_system_major(receipt),
        "host": copy.deepcopy(receipt["host"]),
        "scales": [scale_row(scale) for scale in receipt["scales"]],
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
        raise CrossHostMutationError(
            "mutation host receipt stream repeats an identical receipt"
        )

    validated = []
    for index, raw in enumerate(raw_receipts):
        try:
            validated.append(
                host_matrix.validate_host_receipt(
                    raw,
                    host_contract,
                    profiles,
                    f"mutation host receipts[{index}]",
                )
            )
        except host_matrix.MatrixError as error:
            raise CrossHostMutationError(str(error)) from error

    by_profile = {}
    for receipt in validated:
        profile = receipt["hostProfile"]
        if profile in by_profile:
            raise CrossHostMutationError(
                f"mutation host receipt stream repeats profile: {profile}"
            )
        by_profile[profile] = receipt

    required_profiles = list(cross_contract["requiredHostProfiles"])
    present_profiles = [
        profile for profile in required_profiles if profile in by_profile
    ]
    missing_profiles = [
        profile for profile in required_profiles if profile not in by_profile
    ]
    present_majors = sorted({
        operating_system_major(receipt) for receipt in validated
    })
    required_majors = list(cross_contract["requiredOperatingSystemMajors"])
    missing_majors = [
        major for major in required_majors if major not in present_majors
    ]
    source_commits = sorted({receipt["sourceCommit"] for receipt in validated})
    toolchains = sorted({receipt["toolchain"] for receipt in validated})
    rows = [
        profile_row(profile, by_profile.get(profile))
        for profile in required_profiles
    ]
    comparable = len(source_commits) == 1 and len(toolchains) == 1
    complete = not missing_profiles and not missing_majors
    outcome = (
        "review-required"
        if complete
        and comparable
        and all(row["state"] == "review-required" for row in rows)
        else "blocked"
    )

    if generated_at is None:
        timestamp = (
            dt.datetime.now(dt.timezone.utc)
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z")
        )
    else:
        try:
            timestamp = foundation.utc_timestamp(
                generated_at,
                "mutation cross-host scorecard.generatedAt",
            )
        except host_matrix.MatrixError as error:
            raise CrossHostMutationError(str(error)) from error

    return {
        "schemaVersion": cross_contract["scorecardSchemaVersion"],
        "kind": "exact-path-mutation-cross-host-review",
        "generatedAt": timestamp,
        "fixtureVersion": host_contract["fixtureVersion"],
        "measurementPolicyVersion": host_contract["measurementPolicyVersion"],
        "hostReviewPolicyVersion": cross_contract["hostReviewPolicyVersion"],
        "crossHostReviewPolicyVersion": cross_contract[
            "crossHostReviewPolicyVersion"
        ],
        "buildConfiguration": host_contract["buildConfiguration"],
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
        raise CrossHostMutationError(f"{label} is not canonical JSON") from error


def validate_scorecard_against_receipts(
    raw: Any,
    raw_receipts: list[Any],
    cross_contract: dict[str, Any],
    host_contract: dict[str, Any],
    profiles: dict[str, tuple[int, int | None]],
    label: str = "mutation cross-host scorecard",
) -> dict[str, Any]:
    try:
        scorecard = foundation.exact_object(raw, SCORECARD_KEYS, label)
        generated_at = foundation.utc_timestamp(
            scorecard["generatedAt"],
            f"{label}.generatedAt",
        )
    except host_matrix.MatrixError as error:
        raise CrossHostMutationError(str(error)) from error
    expected = build_scorecard(
        raw_receipts,
        cross_contract,
        host_contract,
        profiles,
        generated_at=generated_at,
    )
    if canonical_document(scorecard, label) != canonical_document(
        expected,
        "recomputed mutation cross-host scorecard",
    ):
        raise CrossHostMutationError(
            f"{label} does not exactly match its receipts and active contracts"
        )
    return scorecard


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Review threshold-free exact-path mutation receipts across supported Macs."
        )
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
        profiles = foundation.load_profiles(options.resource_contract)
        cross_contract = load_contract(options.contract, host_contract)
        receipts = read_receipts(options.input)
        scorecard = build_scorecard(
            receipts,
            cross_contract,
            host_contract,
            profiles,
        )
    except host_matrix.MatrixError as error:
        raise CrossHostMutationError(str(error)) from error
    print(json.dumps(scorecard, sort_keys=True, separators=(",", ":")))
    return 0 if scorecard["outcome"] == "review-required" else 1


def main() -> int:
    try:
        return main_from_args()
    except CrossHostMutationError as error:
        print(f"exact-path mutation cross-host error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
