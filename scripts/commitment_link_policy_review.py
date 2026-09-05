#!/usr/bin/env python3
"""Retain one explicit, non-serving commitment-link calibration review."""

from __future__ import annotations

import argparse
import copy
import os
import stat
import sys
from pathlib import Path
from typing import Any


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))

import commitment_link_quality as quality
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


REPOSITORY = SCRIPT_DIRECTORY.parent
DEFAULT_CONTRACT = (
    REPOSITORY
    / "docs"
    / "evidence"
    / "commitment-link-policy-review-admission.json"
)
PUBLIC_FIXTURE = (
    REPOSITORY
    / "Fixtures"
    / "CommitmentLinkQuality"
    / "public-synthetic-v1.json"
)
REVIEW_KIND = "commitment-link-policy-calibration-review"
BUNDLE_FILES = {
    "publicObservations": "public-similarity.json",
    "publicReplay": "public-policy-replay.json",
    "privateObservations": "private-similarity.json",
    "privateReplay": "private-policy-replay.json",
    "matrix": "profile-matrix.json",
}
CONTRACT_KEYS = {
    "schemaVersion",
    "receiptSchemaVersion",
    "matrixSchemaVersion",
    "reviewPolicyVersion",
    "requiredReviewAcknowledgement",
    "requiredMatrixEvaluationStatus",
    "requiredMatrixSelectionStatus",
    "authority",
    "selectionStatus",
    "qualityFloorStatus",
    "qualityFloorMeaning",
    "productDecision",
    "servingStatus",
    "maximumArtifactBytes",
    "maximumReceiptBytes",
}
RECEIPT_KEYS = {
    "schemaVersion",
    "kind",
    "reviewPolicyVersion",
    "reviewAcknowledgement",
    "authority",
    "sourceCommit",
    "build",
    "embeddingProfileFingerprint",
    "matrixFileSHA256",
    "matrixDocumentSHA256",
    "matrixAuthorities",
    "selectedCandidateID",
    "minimumSimilarity",
    "acceptedQualityFloor",
    "qualityFloorMeaning",
    "selectionStatus",
    "qualityFloorStatus",
    "productDecision",
    "servingStatus",
}


class ReviewError(BaselineError):
    """The requested commitment-link review violated its closed contract."""


class ReviewNotAdmissible(BaselineNotAdmissible, ReviewError):
    """The evidence is valid but cannot become a calibration review."""


def load_contract(path: Path = DEFAULT_CONTRACT) -> dict[str, Any]:
    try:
        contract = quality.exact_object(
            quality.load_json(path, "commitment-link review admission contract"),
            "commitment-link review admission contract",
            CONTRACT_KEYS,
        )
    except quality.CommitmentLinkQualityError as error:
        raise ReviewError(str(error)) from error
    integer_values = {
        "schemaVersion": 1,
        "receiptSchemaVersion": 1,
        "matrixSchemaVersion": 1,
        "maximumArtifactBytes": 4_194_304,
        "maximumReceiptBytes": 2_097_152,
    }
    for key, expected in integer_values.items():
        value = contract[key]
        if isinstance(value, bool) or not isinstance(value, int) or value != expected:
            raise ReviewError(f"commitment-link review {key} is not supported")
    expected_values = {
        "reviewPolicyVersion": (
            "explicit-human-matrix-digest-source-and-candidate-v1"
        ),
        "requiredReviewAcknowledgement": (
            "selected-candidate-metrics-reviewed-no-serving-approval-v1"
        ),
        "requiredMatrixEvaluationStatus": "review-required",
        "requiredMatrixSelectionStatus": "not-selected",
        "authority": "private-commitment-link-calibration-only",
        "selectionStatus": "owner-selected-for-evaluation",
        "qualityFloorStatus": "accepted-for-confirmation-evaluation",
        "qualityFloorMeaning": "selected-candidate-observed-metrics-v1",
        "productDecision": "not-evaluated",
        "servingStatus": "not-approved",
    }
    for key, expected in expected_values.items():
        if contract[key] != expected:
            raise ReviewError(f"commitment-link review {key} is not supported")
    return contract


def validate_review_acknowledgement(
    value: str,
    contract: dict[str, Any],
) -> str:
    try:
        acknowledgement = quality.bounded_text(
            value,
            "accepted commitment-link review acknowledgement",
            96,
        )
    except quality.CommitmentLinkQualityError as error:
        raise ReviewError(str(error)) from error
    if acknowledgement != contract["requiredReviewAcknowledgement"]:
        raise ReviewError("commitment-link review acknowledgement is inconsistent")
    return acknowledgement


def validate_candidate_id(value: str) -> str:
    try:
        return quality.safe_id(value, "selected commitment-link candidate")
    except quality.CommitmentLinkQualityError as error:
        raise ReviewError(str(error)) from error


def validate_bundle_directory(path: Path) -> Path:
    path = path.expanduser()
    if path.is_symlink():
        raise ReviewError(
            "commitment-link profile matrix bundle must not be a symbolic link"
        )
    try:
        metadata = os.lstat(path)
    except OSError as error:
        raise ReviewError("commitment-link profile matrix bundle was not found") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ReviewError("commitment-link profile matrix bundle must be a directory")
    if stat.S_IMODE(metadata.st_mode) != 0o700:
        raise ReviewError("commitment-link profile matrix bundle must be mode 0700")
    try:
        return path.resolve()
    except OSError as error:
        raise ReviewError(
            "commitment-link profile matrix bundle could not be resolved"
        ) from error


def load_review_sources(
    bundle_path: Path,
    private_fixture_path: Path,
    contract: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Path], bytes]:
    bundle = validate_bundle_directory(bundle_path)
    try:
        private_path = quality.validate_private_fixture_path(private_fixture_path)
        paths = {
            key: quality.validate_owner_only_private_path(
                bundle / filename,
                f"commitment-link review {key}",
            )
            for key, filename in BUNDLE_FILES.items()
        }
        public_fixture = quality.validate_fixture(
            quality.load_json(PUBLIC_FIXTURE, "public fixture")
        )
        if public_fixture != quality.public_fixture():
            raise quality.CommitmentLinkQualityError(
                "public fixture does not match the canonical authority"
            )
        private_fixture = quality.validate_private_fixture(
            quality.load_json(private_path, "private fixture")
        )
        documents = {
            key: quality.load_json(
                path,
                f"commitment-link review {key}",
                maximum_bytes=contract["maximumArtifactBytes"],
            )
            for key, path in paths.items()
        }
        matrix = quality.validate_public_private_profile_matrix(
            documents["matrix"],
            public_fixture,
            documents["publicObservations"],
            documents["publicReplay"],
            private_fixture,
            documents["privateObservations"],
            documents["privateReplay"],
        )
    except quality.CommitmentLinkQualityError as error:
        raise ReviewError(str(error)) from error
    try:
        matrix_file = read_bounded_bytes(
            paths["matrix"],
            "commitment-link profile matrix",
            contract["maximumArtifactBytes"],
        )
    except BaselineError as error:
        raise ReviewError(str(error)) from error
    return {
        "publicFixture": public_fixture,
        "privateFixture": private_fixture,
        **documents,
        "matrix": matrix,
    }, {"privateFixture": private_path, **paths}, matrix_file


def build_review_receipt(
    matrix: dict[str, Any],
    contract: dict[str, Any],
    *,
    matrix_file_sha256: str,
    accepted_matrix_sha256: str,
    accepted_source_commit: str,
    selected_candidate_id: str,
    accepted_review_acknowledgement: str,
) -> dict[str, Any]:
    if matrix["schemaVersion"] != contract["matrixSchemaVersion"]:
        raise ReviewError("commitment-link matrix schema is inconsistent")
    if matrix["evaluationStatus"] != contract[
        "requiredMatrixEvaluationStatus"
    ]:
        raise ReviewNotAdmissible("commitment-link matrix is not review-required")
    if matrix["selectionStatus"] != contract[
        "requiredMatrixSelectionStatus"
    ]:
        raise ReviewNotAdmissible("commitment-link matrix already has a selection")
    if matrix["productDecision"] != "not-evaluated" or matrix[
        "servingStatus"
    ] != "not-approved":
        raise ReviewNotAdmissible("commitment-link matrix has product authority")

    matrix_file_sha256 = validate_sha256(
        matrix_file_sha256,
        "commitment-link matrix file digest",
    )
    accepted_matrix_sha256 = validate_sha256(
        accepted_matrix_sha256,
        "accepted commitment-link matrix digest",
    )
    if matrix_file_sha256 != accepted_matrix_sha256:
        raise ReviewError("accepted commitment-link matrix digest is inconsistent")
    accepted_source_commit = validate_commit(
        accepted_source_commit,
        "accepted source commit",
    )
    if matrix["sourceCommit"] != accepted_source_commit:
        raise ReviewError("accepted source commit does not match the matrix")
    acknowledgement = validate_review_acknowledgement(
        accepted_review_acknowledgement,
        contract,
    )
    selected_candidate_id = validate_candidate_id(selected_candidate_id)
    matches = [
        candidate for candidate in matrix["candidates"]
        if candidate["candidateID"] == selected_candidate_id
    ]
    if len(matches) != 1:
        raise ReviewNotAdmissible(
            "selected commitment-link candidate is absent from the matrix"
        )
    candidate = matches[0]
    if candidate["public"]["admittedSuggestions"] < 1 or candidate[
        "private"
    ]["admittedSuggestions"] < 1:
        raise ReviewNotAdmissible(
            "selected commitment-link candidate admits no suggestions"
        )

    return {
        "schemaVersion": contract["receiptSchemaVersion"],
        "kind": REVIEW_KIND,
        "reviewPolicyVersion": contract["reviewPolicyVersion"],
        "reviewAcknowledgement": acknowledgement,
        "authority": contract["authority"],
        "sourceCommit": matrix["sourceCommit"],
        "build": matrix["build"],
        "embeddingProfileFingerprint": matrix[
            "embeddingProfileFingerprint"
        ],
        "matrixFileSHA256": matrix_file_sha256,
        "matrixDocumentSHA256": quality.document_digest(matrix),
        "matrixAuthorities": {
            "public": copy.deepcopy(matrix["public"]),
            "private": copy.deepcopy(matrix["private"]),
        },
        "selectedCandidateID": selected_candidate_id,
        "minimumSimilarity": candidate["minimumSimilarity"],
        "acceptedQualityFloor": {
            "public": copy.deepcopy(candidate["public"]),
            "private": copy.deepcopy(candidate["private"]),
        },
        "qualityFloorMeaning": contract["qualityFloorMeaning"],
        "selectionStatus": contract["selectionStatus"],
        "qualityFloorStatus": contract["qualityFloorStatus"],
        "productDecision": contract["productDecision"],
        "servingStatus": contract["servingStatus"],
    }


def validate_review_receipt(
    document: dict[str, Any],
    matrix: dict[str, Any],
    contract: dict[str, Any],
    *,
    matrix_file_sha256: str,
) -> dict[str, Any]:
    try:
        quality.exact_object(document, "commitment-link review receipt", RECEIPT_KEYS)
    except quality.CommitmentLinkQualityError as error:
        raise ReviewError(str(error)) from error
    expected = build_review_receipt(
        matrix,
        contract,
        matrix_file_sha256=matrix_file_sha256,
        accepted_matrix_sha256=document["matrixFileSHA256"],
        accepted_source_commit=document["sourceCommit"],
        selected_candidate_id=document["selectedCandidateID"],
        accepted_review_acknowledgement=document["reviewAcknowledgement"],
    )
    if document != expected:
        raise ReviewError(
            "commitment-link review does not match deterministic recomputation"
        )
    return document


def admit_review(
    bundle_path: Path,
    private_fixture_path: Path,
    output_path: Path,
    *,
    accepted_matrix_sha256: str,
    accepted_source_commit: str,
    selected_candidate_id: str,
    accepted_review_acknowledgement: str,
    root: Path = REPOSITORY,
    contract_path: Path = DEFAULT_CONTRACT,
    runner: CommandRunner = run_command,
) -> tuple[dict[str, Any], Path]:
    contract = load_contract(contract_path)
    accepted_matrix_sha256 = validate_sha256(
        accepted_matrix_sha256,
        "accepted commitment-link matrix digest",
    )
    accepted_source_commit = validate_commit(
        accepted_source_commit,
        "accepted source commit",
    )
    selected_candidate_id = validate_candidate_id(selected_candidate_id)
    accepted_review_acknowledgement = validate_review_acknowledgement(
        accepted_review_acknowledgement,
        contract,
    )
    root = root.resolve()
    require_source_checkout(root, accepted_source_commit, runner)
    sources, paths, matrix_file = load_review_sources(
        bundle_path,
        private_fixture_path,
        contract,
    )
    matrix_file_sha256 = sha256_bytes(matrix_file)
    receipt = build_review_receipt(
        sources["matrix"],
        contract,
        matrix_file_sha256=matrix_file_sha256,
        accepted_matrix_sha256=accepted_matrix_sha256,
        accepted_source_commit=accepted_source_commit,
        selected_candidate_id=selected_candidate_id,
        accepted_review_acknowledgement=accepted_review_acknowledgement,
    )
    validate_review_receipt(
        receipt,
        sources["matrix"],
        contract,
        matrix_file_sha256=matrix_file_sha256,
    )
    output = validate_output_destination(
        output_path,
        tuple(paths.values()),
        root,
        runner,
    )
    require_source_checkout(root, accepted_source_commit, runner)
    write_owner_only(output, receipt, contract["maximumReceiptBytes"])
    try:
        require_source_checkout(root, accepted_source_commit, runner)
    except BaselineError:
        withdraw_output(output)
        raise
    return receipt, output


def validate_retained_review(
    bundle_path: Path,
    private_fixture_path: Path,
    receipt_path: Path,
    *,
    contract_path: Path = DEFAULT_CONTRACT,
) -> dict[str, Any]:
    contract = load_contract(contract_path)
    sources, _, matrix_file = load_review_sources(
        bundle_path,
        private_fixture_path,
        contract,
    )
    try:
        review_path = quality.validate_owner_only_private_path(
            receipt_path,
            "commitment-link review receipt",
        )
        review = quality.load_json(
            review_path,
            "commitment-link review receipt",
            maximum_bytes=contract["maximumReceiptBytes"],
        )
    except quality.CommitmentLinkQualityError as error:
        raise ReviewError(str(error)) from error
    return validate_review_receipt(
        review,
        sources["matrix"],
        contract,
        matrix_file_sha256=sha256_bytes(matrix_file),
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    admit = subparsers.add_parser("admit")
    validate = subparsers.add_parser("validate")
    for subparser in (admit, validate):
        subparser.add_argument("--bundle", type=Path, required=True)
        subparser.add_argument("--private-fixture", type=Path, required=True)
        subparser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    admit.add_argument("--output", type=Path, required=True)
    admit.add_argument("--accept-matrix-sha256", required=True)
    admit.add_argument("--accept-source-commit", required=True)
    admit.add_argument("--select-candidate", required=True)
    admit.add_argument("--accept-review-acknowledgement", required=True)
    validate.add_argument("--receipt", type=Path, required=True)
    return parser


def main_from_args(
    arguments: list[str] | None = None,
    *,
    root: Path = REPOSITORY,
    runner: CommandRunner = run_command,
) -> int:
    options = build_parser().parse_args(arguments)
    if options.command == "admit":
        _, output = admit_review(
            options.bundle,
            options.private_fixture,
            options.output,
            accepted_matrix_sha256=options.accept_matrix_sha256,
            accepted_source_commit=options.accept_source_commit,
            selected_candidate_id=options.select_candidate,
            accepted_review_acknowledgement=options.accept_review_acknowledgement,
            root=root,
            contract_path=options.contract,
            runner=runner,
        )
        print(f"Retained commitment-link calibration review: {output}")
        return 0
    review = validate_retained_review(
        options.bundle,
        options.private_fixture,
        options.receipt,
        contract_path=options.contract,
    )
    print(
        "Validated commitment-link calibration review: "
        f"{review['selectedCandidateID']}"
    )
    return 0


def main(
    arguments: list[str] | None = None,
    *,
    root: Path = REPOSITORY,
    runner: CommandRunner = run_command,
) -> int:
    try:
        return main_from_args(arguments, root=root, runner=runner)
    except ReviewNotAdmissible as error:
        print(f"commitment-link review not admitted: {error}", file=sys.stderr)
        return 1
    except (ReviewError, BaselineError) as error:
        print(f"commitment-link review error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
