#!/usr/bin/env python3
"""Create and evaluate privacy-safe Portavoz release reliability receipts."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


SCHEMA_VERSION = 1
DEFAULT_CONTRACT = (
    Path(__file__).resolve().parents[1]
    / "docs"
    / "evidence"
    / "reliability-gates.json"
)
PROOF_CLASSES = {
    "deterministic-automated",
    "signed-build",
    "real-hardware",
    "user-field",
}
DETERMINISTIC_PROOFS = (
    "repository-hygiene",
    "swift-gates",
    "recording-stress",
    "language-corpus",
    "reliability-ui",
)
DISTRIBUTION_PROOFS = ("distribution",)
FIXTURES = {
    "built-in-speaker-mic",
    "airpods",
    "mixed-language",
    "long-call",
    "source-callback-interruption",
    "model-cold-start",
}
EVIDENCE_SUBSYSTEMS = {
    "recording.start.committed": "recording-start",
    "capture.route.preserved": "capture-route",
    "capture.callback.recovered": "callback-recovery",
    "recording.stop.durable": "stop-durability",
    "post-capture.admission.completed": "post-capture-admission",
    "translation.live.separated": "live-translation",
    "refine.language.preserved": "refine",
}
FIXTURE_EVIDENCE = {
    "built-in-speaker-mic": (
        "recording.start.committed",
        "capture.route.preserved",
        "recording.stop.durable",
        "post-capture.admission.completed",
    ),
    "airpods": (
        "recording.start.committed",
        "capture.route.preserved",
        "recording.stop.durable",
        "post-capture.admission.completed",
    ),
    "mixed-language": (
        "recording.start.committed",
        "recording.stop.durable",
        "post-capture.admission.completed",
        "translation.live.separated",
        "refine.language.preserved",
    ),
    "long-call": (
        "recording.start.committed",
        "capture.route.preserved",
        "recording.stop.durable",
        "post-capture.admission.completed",
    ),
    "source-callback-interruption": (
        "recording.start.committed",
        "capture.route.preserved",
        "capture.callback.recovered",
        "recording.stop.durable",
        "post-capture.admission.completed",
    ),
    "model-cold-start": (
        "recording.start.committed",
        "recording.stop.durable",
        "post-capture.admission.completed",
    ),
}
STATE_VALUES = {"pass", "fail", "not-observed"}
FIELD_OUTCOME_VALUES = {"pass", "fail", "incomplete"}
VERSION_PATTERN = re.compile(r"^[A-Za-z0-9._+\-]{1,40}$")
BUILD_PATTERN = re.compile(r"^[A-Za-z0-9._+\-]{1,80}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
TIMESTAMP_PATTERN = re.compile(r"^[0-9T:.+\-Z]{10,64}$")
REFERENCE_PATTERN = re.compile(r"^meeting-[0-9a-f]{12}$")


class ReliabilityError(ValueError):
    """A fail-closed release-reliability validation error."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def object_shape(value, path, required, optional=()):
    if not isinstance(value, dict):
        raise ReliabilityError(f"{path} must be an object")
    required = set(required)
    allowed = required | set(optional)
    missing = required - value.keys()
    extra = value.keys() - allowed
    if missing:
        raise ReliabilityError(f"{path} is missing keys: {', '.join(sorted(missing))}")
    if extra:
        raise ReliabilityError(
            f"{path} contains forbidden keys: {', '.join(sorted(extra))}"
        )
    return value


def safe_string(value, path, pattern):
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise ReliabilityError(f"{path} has an unsafe value")
    return value


def integer(value, path, minimum=0):
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ReliabilityError(f"{path} must be an integer >= {minimum}")
    return value


def number(value, path, minimum=0, maximum=None):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ReliabilityError(f"{path} must be numeric")
    value = float(value)
    if not math.isfinite(value):
        raise ReliabilityError(f"{path} must be finite")
    if value < minimum or (maximum is not None and value > maximum):
        limit = f" and <= {maximum}" if maximum is not None else ""
        raise ReliabilityError(f"{path} must be >= {minimum}{limit}")
    return value


def timestamp(value, path):
    value = safe_string(value, path, TIMESTAMP_PATTERN)
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ReliabilityError(f"{path} must be an ISO-8601 timestamp") from error
    if parsed.utcoffset() is None:
        raise ReliabilityError(f"{path} must include a UTC offset")
    return value


def load_json(path, label, maximum_bytes=2 * 1024 * 1024):
    path = Path(path).expanduser()
    if not path.is_file():
        raise ReliabilityError(f"{label} not found: {path}")
    if path.stat().st_size > maximum_bytes:
        raise ReliabilityError(f"{label} exceeds the size limit")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReliabilityError(f"{label} is not valid UTF-8 JSON") from error


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def write_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(text, encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def receipt_identity(document, label):
    identity = object_shape(
        document,
        label,
        ("schemaVersion", "kind", "collectedAt", "release", "proofs"),
    )
    if integer(identity["schemaVersion"], f"{label}.schemaVersion") != SCHEMA_VERSION:
        raise ReliabilityError(f"{label}.schemaVersion must be {SCHEMA_VERSION}")
    timestamp(identity["collectedAt"], f"{label}.collectedAt")
    release = object_shape(
        identity["release"],
        f"{label}.release",
        ("version", "build"),
        ("commit",),
    )
    safe_string(release["version"], f"{label}.release.version", VERSION_PATTERN)
    safe_string(release["build"], f"{label}.release.build", BUILD_PATTERN)
    if "commit" in release:
        safe_string(release["commit"], f"{label}.release.commit", COMMIT_PATTERN)
    if not isinstance(identity["proofs"], list):
        raise ReliabilityError(f"{label}.proofs must be an array")
    return identity, release


def validate_proofs(raw_proofs, expected, label):
    proofs = {}
    for index, raw in enumerate(raw_proofs):
        proof = object_shape(
            raw,
            f"{label}.proofs[{index}]",
            ("id", "state"),
        )
        identifier = safe_string(
            proof["id"],
            f"{label}.proofs[{index}].id",
            BUILD_PATTERN,
        )
        if identifier in proofs:
            raise ReliabilityError(f"{label} repeats proof: {identifier}")
        if proof["state"] not in STATE_VALUES:
            raise ReliabilityError(
                f"{label}.proofs[{index}].state must be pass, fail, or not-observed"
            )
        proofs[identifier] = proof["state"]
    unknown = set(proofs) - set(expected)
    if unknown:
        raise ReliabilityError(f"{label} has unknown proofs: {', '.join(sorted(unknown))}")
    return proofs


def validate_deterministic_receipt(document):
    receipt, release = receipt_identity(document, "deterministic receipt")
    if receipt["kind"] != "deterministic":
        raise ReliabilityError("deterministic receipt.kind must be deterministic")
    if "commit" not in release:
        raise ReliabilityError("deterministic receipt.release.commit is required")
    proofs = validate_proofs(
        receipt["proofs"],
        DETERMINISTIC_PROOFS,
        "deterministic receipt",
    )
    return receipt, release, proofs


def validate_distribution_receipt(document):
    receipt = object_shape(
        document,
        "distribution receipt",
        (
            "schemaVersion",
            "kind",
            "collectedAt",
            "release",
            "artifact",
            "proofs",
        ),
    )
    identity, release = receipt_identity(
        {
            key: receipt[key]
            for key in ("schemaVersion", "kind", "collectedAt", "release", "proofs")
        },
        "distribution receipt",
    )
    if identity["kind"] != "distribution":
        raise ReliabilityError("distribution receipt.kind must be distribution")
    artifact = object_shape(
        receipt["artifact"],
        "distribution receipt.artifact",
        ("sha256",),
    )
    safe_string(
        artifact["sha256"],
        "distribution receipt.artifact.sha256",
        DIGEST_PATTERN,
    )
    proofs = validate_proofs(
        receipt["proofs"],
        DISTRIBUTION_PROOFS,
        "distribution receipt",
    )
    return receipt, release, proofs


def validate_contract(document):
    root = object_shape(document, "contract", ("schemaVersion", "proofs"))
    if integer(root["schemaVersion"], "contract.schemaVersion") != SCHEMA_VERSION:
        raise ReliabilityError(f"contract.schemaVersion must be {SCHEMA_VERSION}")
    if not isinstance(root["proofs"], list) or not root["proofs"]:
        raise ReliabilityError("contract.proofs must be a non-empty array")
    proofs = []
    identifiers = set()
    for index, raw in enumerate(root["proofs"]):
        proof = object_shape(
            raw,
            f"contract.proofs[{index}]",
            ("id", "class", "source"),
        )
        identifier = safe_string(
            proof["id"],
            f"contract.proofs[{index}].id",
            BUILD_PATTERN,
        )
        if identifier in identifiers:
            raise ReliabilityError(f"contract repeats proof: {identifier}")
        identifiers.add(identifier)
        if proof["class"] not in PROOF_CLASSES:
            raise ReliabilityError(f"contract proof {identifier} has unknown class")
        source = proof["source"]
        if not isinstance(source, dict):
            raise ReliabilityError(f"contract proof {identifier} source must be an object")
        kind = source.get("kind")
        if kind in {"deterministic-receipt", "distribution-receipt"}:
            object_shape(source, f"contract proof {identifier}.source", ("kind", "proof"))
            source_proof = safe_string(
                source["proof"],
                f"contract proof {identifier}.source.proof",
                BUILD_PATTERN,
            )
            allowed_proofs = (
                DETERMINISTIC_PROOFS
                if kind == "deterministic-receipt"
                else DISTRIBUTION_PROOFS
            )
            if source_proof not in allowed_proofs:
                raise ReliabilityError(
                    f"contract proof {identifier} references unknown "
                    f"{kind} proof: {source_proof}"
                )
        elif kind == "field-fixture":
            object_shape(
                source,
                f"contract proof {identifier}.source",
                ("kind", "fixture"),
                ("macOSMajor",),
            )
            if source["fixture"] not in FIXTURES:
                raise ReliabilityError(f"contract proof {identifier} has unknown fixture")
            if "macOSMajor" in source:
                integer(
                    source["macOSMajor"],
                    f"contract proof {identifier}.source.macOSMajor",
                    1,
                )
        else:
            raise ReliabilityError(f"contract proof {identifier} has unknown source kind")
        proofs.append(proof)
    return proofs


def validate_field_manifest(document, label):
    root = object_shape(
        document,
        label,
        (
            "protocolVersion",
            "collectedAt",
            "fixture",
            "meetingReference",
            "outcome",
            "evidence",
            "elapsedSeconds",
            "app",
            "macOS",
            "supportReports",
        ),
    )
    if integer(root["protocolVersion"], f"{label}.protocolVersion") != 2:
        raise ReliabilityError(f"{label}.protocolVersion must be 2")
    timestamp(root["collectedAt"], f"{label}.collectedAt")
    if root["fixture"] not in FIXTURES:
        raise ReliabilityError(f"{label}.fixture is unknown")
    safe_string(
        root["meetingReference"],
        f"{label}.meetingReference",
        REFERENCE_PATTERN,
    )
    if root["outcome"] not in FIELD_OUTCOME_VALUES:
        raise ReliabilityError(f"{label}.outcome is invalid")
    if root["elapsedSeconds"] is not None:
        number(root["elapsedSeconds"], f"{label}.elapsedSeconds", 0, 86_400)
    app = object_shape(root["app"], f"{label}.app", ("version", "build"))
    safe_string(app["version"], f"{label}.app.version", VERSION_PATTERN)
    safe_string(app["build"], f"{label}.app.build", BUILD_PATTERN)
    operating_system = object_shape(
        root["macOS"],
        f"{label}.macOS",
        ("productVersion", "buildVersion"),
    )
    product_version = safe_string(
        operating_system["productVersion"],
        f"{label}.macOS.productVersion",
        VERSION_PATTERN,
    )
    safe_string(
        operating_system["buildVersion"],
        f"{label}.macOS.buildVersion",
        BUILD_PATTERN,
    )
    try:
        os_major = int(product_version.split(".", maxsplit=1)[0])
    except ValueError as error:
        raise ReliabilityError(
            f"{label}.macOS.productVersion must begin with a major version"
        ) from error
    if not isinstance(root["evidence"], list) or not root["evidence"]:
        raise ReliabilityError(f"{label}.evidence must be a non-empty array")
    evidence_by_id = {}
    for index, raw in enumerate(root["evidence"]):
        evidence = object_shape(
            raw,
            f"{label}.evidence[{index}]",
            ("id", "subsystem", "state"),
        )
        identifier = safe_string(
            evidence["id"],
            f"{label}.evidence[{index}].id",
            BUILD_PATTERN,
        )
        subsystem = safe_string(
            evidence["subsystem"],
            f"{label}.evidence[{index}].subsystem",
            BUILD_PATTERN,
        )
        if identifier in evidence_by_id:
            raise ReliabilityError(f"{label} repeats evidence: {identifier}")
        if EVIDENCE_SUBSYSTEMS.get(identifier) != subsystem:
            raise ReliabilityError(
                f"{label}.evidence[{index}] has an invalid subsystem for {identifier}"
            )
        if evidence["state"] not in STATE_VALUES:
            raise ReliabilityError(f"{label}.evidence[{index}].state is invalid")
        evidence_by_id[identifier] = evidence["state"]
    expected_evidence = set(FIXTURE_EVIDENCE[root["fixture"]])
    if set(evidence_by_id) != expected_evidence:
        missing = expected_evidence - evidence_by_id.keys()
        extra = evidence_by_id.keys() - expected_evidence
        details = []
        if missing:
            details.append(f"missing {', '.join(sorted(missing))}")
        if extra:
            details.append(f"unknown {', '.join(sorted(extra))}")
        raise ReliabilityError(f"{label}.evidence is invalid: {'; '.join(details)}")

    calculated_outcome = "incomplete"
    if "fail" in evidence_by_id.values():
        calculated_outcome = "fail"
    elif all(state == "pass" for state in evidence_by_id.values()):
        calculated_outcome = "pass"
    if root["outcome"] != calculated_outcome:
        raise ReliabilityError(
            f"{label}.outcome does not match its evidence states"
        )

    reports = validate_support_reports(
        root["supportReports"],
        f"{label}.supportReports",
    )
    if root["fixture"] == "mixed-language" and reports["afterRefine"] is None:
        raise ReliabilityError(
            f"{label}.supportReports.afterRefine is required for mixed-language"
        )
    return {
        "fixture": root["fixture"],
        "outcome": (
            "not-observed" if root["outcome"] == "incomplete" else root["outcome"]
        ),
        "version": app["version"],
        "build": app["build"],
        "osMajor": os_major,
        "osVersion": product_version,
        "collectedAt": root["collectedAt"],
    }


def validate_support_reports(value, path):
    reports = object_shape(value, path, ("beforeRefine", "afterRefine"))
    validate_support_report(reports["beforeRefine"], f"{path}.beforeRefine")
    if reports["afterRefine"] is not None:
        validate_support_report(reports["afterRefine"], f"{path}.afterRefine")
    return reports


def validate_support_report(value, path):
    report = object_shape(
        value,
        path,
        ("formatVersion", "generatedAt", "meetingCount", "selectedMeeting"),
    )
    if integer(report["formatVersion"], f"{path}.formatVersion") != 2:
        raise ReliabilityError(f"{path}.formatVersion must be 2")
    timestamp(report["generatedAt"], f"{path}.generatedAt")
    integer(report["meetingCount"], f"{path}.meetingCount")
    meeting = object_shape(
        report["selectedMeeting"],
        f"{path}.selectedMeeting",
        (
            "lifecycleState",
            "transcriptRevision",
            "audioAssetCount",
            "segmentCount",
            "processingJobCount",
        ),
    )
    safe_string(
        meeting["lifecycleState"],
        f"{path}.selectedMeeting.lifecycleState",
        BUILD_PATTERN,
    )
    for key in (
        "transcriptRevision",
        "audioAssetCount",
        "segmentCount",
        "processingJobCount",
    ):
        integer(meeting[key], f"{path}.selectedMeeting.{key}")


def release_matches(actual, expected, label, include_commit=False):
    keys = ("version", "build", "commit") if include_commit else ("version", "build")
    for key in keys:
        if actual.get(key) != expected[key]:
            raise ReliabilityError(
                f"{label} {key} {actual.get(key)!r} does not match "
                f"requested release {expected[key]!r}"
            )


def field_key(fixture, os_major):
    return (fixture, os_major)


def evaluate(args):
    expected_release = {
        "version": safe_string(args.version, "release.version", VERSION_PATTERN),
        "build": safe_string(args.build, "release.build", BUILD_PATTERN),
        "commit": safe_string(args.commit, "release.commit", COMMIT_PATTERN),
    }
    contract = validate_contract(load_json(args.contract, "reliability contract"))

    deterministic_proofs = {}
    if args.deterministic_receipt and Path(
        args.deterministic_receipt
    ).expanduser().is_file():
        _, release, deterministic_proofs = validate_deterministic_receipt(
            load_json(args.deterministic_receipt, "deterministic receipt")
        )
        release_matches(release, expected_release, "deterministic receipt", True)

    distribution_proofs = {}
    distribution_digest = None
    if args.distribution_receipt and Path(
        args.distribution_receipt
    ).expanduser().is_file():
        receipt, release, distribution_proofs = validate_distribution_receipt(
            load_json(args.distribution_receipt, "distribution receipt")
        )
        release_matches(release, expected_release, "distribution receipt")
        distribution_digest = receipt["artifact"]["sha256"]

    field_manifests = []
    seen = set()
    for index, raw_path in enumerate(args.field_evidence):
        path = Path(raw_path).expanduser()
        manifest_path = path / "manifest.json" if path.is_dir() else path
        field = validate_field_manifest(
            load_json(manifest_path, f"field evidence {index + 1}"),
            f"field evidence {index + 1}",
        )
        release_matches(field, expected_release, f"field evidence {index + 1}")
        key = field_key(field["fixture"], field["osMajor"])
        if key in seen:
            raise ReliabilityError(
                "field evidence repeats fixture/platform: "
                f"{field['fixture']} on macOS {field['osMajor']}"
            )
        seen.add(key)
        field_manifests.append(field)

    rows = []
    for proof in contract:
        source = proof["source"]
        state = "missing"
        evidence = "not provided"
        if source["kind"] == "deterministic-receipt":
            state = deterministic_proofs.get(source["proof"], "missing")
            evidence = "deterministic receipt" if state != "missing" else evidence
        elif source["kind"] == "distribution-receipt":
            state = distribution_proofs.get(source["proof"], "missing")
            evidence = (
                f"DMG {distribution_digest[:12]}"
                if state != "missing" and distribution_digest
                else evidence
            )
        else:
            candidates = [
                field
                for field in field_manifests
                if field["fixture"] == source["fixture"]
                and (
                    "macOSMajor" not in source
                    or field["osMajor"] == source["macOSMajor"]
                )
            ]
            if len(candidates) > 1:
                raise ReliabilityError(
                    f"multiple field packages satisfy proof {proof['id']}"
                )
            if candidates:
                candidate = candidates[0]
                state = candidate["outcome"]
                evidence = (
                    f"{candidate['fixture']} · macOS {candidate['osVersion']} · "
                    f"{candidate['collectedAt']}"
                )
        rows.append(
            {
                "id": proof["id"],
                "class": proof["class"],
                "state": state,
                "evidence": evidence,
            }
        )

    outcome = "pass" if all(row["state"] == "pass" for row in rows) else "blocked"
    scorecard = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": utc_now(),
        "release": expected_release,
        "outcome": outcome,
        "proofs": rows,
    }
    output = Path(args.output).expanduser()
    write_json(output / "readiness.json", scorecard)
    write_text(output / "readiness.md", markdown(scorecard))
    print(f"{outcome.upper()} -> {output / 'readiness.md'}")
    return 0 if outcome == "pass" else 1


def markdown(scorecard):
    lines = [
        "# Portavoz release reliability",
        "",
        (
            f"Release `{scorecard['release']['version']}` "
            f"(build `{scorecard['release']['build']}`, "
            f"commit `{scorecard['release']['commit'][:12]}`): "
            f"**{scorecard['outcome'].upper()}**"
        ),
        "",
        "| Proof class | Gate | State | Evidence |",
        "|---|---|---:|---|",
    ]
    for proof in scorecard["proofs"]:
        lines.append(
            f"| {proof['class']} | `{proof['id']}` | "
            f"**{proof['state']}** | {proof['evidence']} |"
        )
    lines.extend(
        [
            "",
            "Missing, failed, and not-observed evidence are release-blocking. "
            "The scorecard contains no meeting content.",
            "",
        ]
    )
    return "\n".join(lines)


def record_deterministic(args):
    release = {
        "version": safe_string(args.version, "release.version", VERSION_PATTERN),
        "build": safe_string(args.build, "release.build", BUILD_PATTERN),
        "commit": safe_string(args.commit, "release.commit", COMMIT_PATTERN),
    }
    receipt = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "deterministic",
        "collectedAt": utc_now(),
        "release": release,
        "proofs": [
            {"id": identifier, "state": "pass"}
            for identifier in DETERMINISTIC_PROOFS
        ],
    }
    write_json(Path(args.output).expanduser(), receipt)
    print(f"OK -> {args.output}")
    return 0


def record_distribution(args):
    release = {
        "version": safe_string(args.version, "release.version", VERSION_PATTERN),
        "build": safe_string(args.build, "release.build", BUILD_PATTERN),
    }
    digest = safe_string(args.sha256, "artifact.sha256", DIGEST_PATTERN)
    receipt = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "distribution",
        "collectedAt": utc_now(),
        "release": release,
        "artifact": {"sha256": digest},
        "proofs": [{"id": "distribution", "state": "pass"}],
    }
    write_json(Path(args.output).expanduser(), receipt)
    print(f"OK -> {args.output}")
    return 0


def parser():
    result = argparse.ArgumentParser(
        description="Generate and evaluate content-free release reliability receipts."
    )
    commands = result.add_subparsers(dest="command", required=True)

    deterministic = commands.add_parser("record-deterministic")
    deterministic.add_argument("--version", required=True)
    deterministic.add_argument("--build", required=True)
    deterministic.add_argument("--commit", required=True)
    deterministic.add_argument("--output", required=True)
    deterministic.set_defaults(action=record_deterministic)

    distribution = commands.add_parser("record-distribution")
    distribution.add_argument("--version", required=True)
    distribution.add_argument("--build", required=True)
    distribution.add_argument("--sha256", required=True)
    distribution.add_argument("--output", required=True)
    distribution.set_defaults(action=record_distribution)

    evaluation = commands.add_parser("evaluate")
    evaluation.add_argument("--version", required=True)
    evaluation.add_argument("--build", required=True)
    evaluation.add_argument("--commit", required=True)
    evaluation.add_argument("--contract", default=str(DEFAULT_CONTRACT))
    evaluation.add_argument("--deterministic-receipt")
    evaluation.add_argument("--distribution-receipt")
    evaluation.add_argument("--field-evidence", action="append", default=[])
    evaluation.add_argument("--output", required=True)
    evaluation.set_defaults(action=evaluate)
    return result


def execute(argv=None):
    args = parser().parse_args(argv)
    return args.action(args)


def evaluate_namespace(argv):
    args = parser().parse_args(argv)
    if args.command != "evaluate":
        raise ReliabilityError("evaluate_namespace requires the evaluate command")
    return evaluate(args)


def main_from_args(argv=None):
    try:
        return execute(argv)
    except (ReliabilityError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


def main():
    return main_from_args()


if __name__ == "__main__":
    raise SystemExit(main())
