#!/usr/bin/env python3
"""Collect clean, content-free retrieval-chunk resource/correction evidence."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ROLES = (
    "segment",
    "speaker-turn",
    "conversation-window",
    "semantic-boundary",
)
SCENARIOS = (
    "publication-fences",
    "normalized-equivalent-text",
    "text-replacement",
    "actor-reassignment",
    "language-change",
    "structural-split",
    "structural-merge",
)
FIXED_ADAPTERS = {
    "segment": "segment-source-v1",
    "speaker-turn": "speaker-turn-v1",
    "conversation-window": "conversation-window-v1",
}
SEMANTIC_ADAPTER = re.compile(r"^semantic-v1\.[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SAFE_IDENTITY = re.compile(r"^[A-Za-z0-9.+_-]{1,80}$")
MINIMUM_RUNS = 3
MAXIMUM_RUNS = 5
GIBIBYTE = 1_073_741_824
HOST_PROFILES = {
    "memory-8gb": (7 * GIBIBYTE, 10 * GIBIBYTE),
    "memory-16gb": (14 * GIBIBYTE, 18 * GIBIBYTE),
    "reference": (32 * GIBIBYTE, None),
}
SUPPORTED_OS_MAJOR = {15, 26}
OS_VERSION = re.compile(r"(?:^|\s)(\d{1,2})\.")


class RetrievalChunkEvidenceError(ValueError):
    """A fail-closed evidence contract violation."""


def run_command(command: list[str], root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
    )


def require_command(
    command: list[str],
    root: Path,
    label: str,
    runner=run_command,
) -> subprocess.CompletedProcess[str]:
    result = runner(command, root)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "no diagnostic"
        raise RetrievalChunkEvidenceError(f"{label} failed: {detail}")
    return result


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_digest(document: object) -> str:
    return sha256_bytes(
        json.dumps(
            document,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
    )


def is_within(path: Path, directory: Path) -> bool:
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def require_keys(value: object, expected: set[str], label: str) -> dict:
    if not isinstance(value, dict) or set(value) != expected:
        raise RetrievalChunkEvidenceError(f"{label} has an invalid shape")
    return value


def require_count(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise RetrievalChunkEvidenceError(f"{label} must be a nonnegative integer")
    return value


def require_positive_count(value: object, label: str) -> int:
    result = require_count(value, label)
    if result == 0:
        raise RetrievalChunkEvidenceError(f"{label} must be positive")
    return result


def require_resource(value: object, label: str) -> dict:
    resource = require_keys(
        value,
        {
            "wallMilliseconds",
            "processCPUMilliseconds",
            "baselinePhysicalFootprintBytes",
            "peakPhysicalFootprintBytes",
            "incrementalPeakPhysicalFootprintBytes",
            "endingPhysicalFootprintBytes",
        },
        label,
    )
    for key in ("wallMilliseconds", "processCPUMilliseconds"):
        sample = resource[key]
        if isinstance(sample, bool) or not isinstance(sample, (int, float)):
            raise RetrievalChunkEvidenceError(f"{label}.{key} must be numeric")
        if not math.isfinite(sample) or sample < 0:
            raise RetrievalChunkEvidenceError(f"{label}.{key} must be finite")
    for key in (
        "baselinePhysicalFootprintBytes",
        "peakPhysicalFootprintBytes",
        "incrementalPeakPhysicalFootprintBytes",
        "endingPhysicalFootprintBytes",
    ):
        require_count(resource[key], f"{label}.{key}")
    if resource["peakPhysicalFootprintBytes"] < resource["baselinePhysicalFootprintBytes"]:
        raise RetrievalChunkEvidenceError(f"{label} peak precedes its baseline")
    expected_increment = (
        resource["peakPhysicalFootprintBytes"]
        - resource["baselinePhysicalFootprintBytes"]
    )
    if resource["incrementalPeakPhysicalFootprintBytes"] != expected_increment:
        raise RetrievalChunkEvidenceError(f"{label} incremental peak is inconsistent")
    if resource["endingPhysicalFootprintBytes"] > resource["peakPhysicalFootprintBytes"]:
        raise RetrievalChunkEvidenceError(f"{label} ending footprint exceeds peak")
    return resource


def require_diagnostics(value: object, label: str) -> dict | None:
    if value is None:
        return None
    diagnostics = require_keys(
        value,
        {
            "turnCount",
            "vectorizedTurnCount",
            "joinedBoundaryCount",
            "languageTransitionBoundaryCount",
            "unavailableLanguageBoundaryCount",
            "resourceBoundaryCount",
            "similarityBoundaryCount",
        },
        label,
    )
    for key, count in diagnostics.items():
        require_count(count, f"{label}.{key}")
    if diagnostics["vectorizedTurnCount"] > diagnostics["turnCount"]:
        raise RetrievalChunkEvidenceError(f"{label} vector count exceeds turns")
    return diagnostics


def reject_payload_keys(value: object, label: str = "observation") -> None:
    forbidden = {
        "text",
        "sourceSegmentIDs",
        "meetingID",
        "unitID",
        "vectorValues",
        "modelIdentifier",
        "query",
        "path",
    }
    if isinstance(value, dict):
        overlap = forbidden.intersection(value)
        if overlap:
            raise RetrievalChunkEvidenceError(
                f"{label} contains forbidden payload keys: {sorted(overlap)}"
            )
        for key, nested in value.items():
            reject_payload_keys(nested, f"{label}.{key}")
    elif isinstance(value, list):
        for index, nested in enumerate(value):
            reject_payload_keys(nested, f"{label}[{index}]")


def validate_observation(
    document: object,
    *,
    role: str,
    build: str,
    commit: str,
    fixture_sha256: str,
    toolchain_sha256: str,
    host_profile: str,
) -> dict:
    root = require_keys(
        document,
        {
            "schemaVersion",
            "kind",
            "authority",
            "contentPolicy",
            "lifecycle",
            "assetDownloadPolicy",
            "productComposition",
            "candidateSelection",
            "performanceDecision",
            "subject",
            "host",
            "corpus",
            "construction",
            "corrections",
        },
        "observation",
    )
    expected_constants = {
        "schemaVersion": 1,
        "kind": "retrieval-chunk-resource-correction-observation",
        "authority": "research-resource-correction-only",
        "contentPolicy": "content-free",
        "lifecycle": "candidate-construction-and-one-meeting-rebuild-only",
        "assetDownloadPolicy": "never",
        "productComposition": "unchanged",
        "candidateSelection": "not-evaluated",
        "performanceDecision": "not-evaluated",
    }
    for key, expected in expected_constants.items():
        if root[key] != expected:
            raise RetrievalChunkEvidenceError(f"observation.{key} changed")

    subject = require_keys(
        root["subject"],
        {
            "build",
            "sourceCommit",
            "fixtureGeneration",
            "fixtureSHA256",
            "toolchainSHA256",
            "hostProfile",
            "retrievalUnit",
            "adapter",
        },
        "observation.subject",
    )
    expected_identity = {
        "build": build,
        "sourceCommit": commit,
        "fixtureSHA256": fixture_sha256,
        "toolchainSHA256": toolchain_sha256,
        "hostProfile": host_profile,
        "retrievalUnit": role,
    }
    for key, expected in expected_identity.items():
        if subject[key] != expected:
            raise RetrievalChunkEvidenceError(f"observation.subject.{key} mismatch")
    adapter = subject["adapter"]
    if role == "semantic-boundary":
        if not isinstance(adapter, str) or not SEMANTIC_ADAPTER.fullmatch(adapter):
            raise RetrievalChunkEvidenceError("semantic adapter is not source-bound")
    elif adapter != FIXED_ADAPTERS[role]:
        raise RetrievalChunkEvidenceError(f"{role} adapter mismatch")

    host = require_keys(
        root["host"],
        {
            "operatingSystem",
            "architecture",
            "processorCount",
            "physicalMemoryBytes",
            "evidenceScope",
        },
        "observation.host",
    )
    if host["evidenceScope"] != "single-development-host":
        raise RetrievalChunkEvidenceError("host evidence scope changed")
    if not all(isinstance(host[key], str) and host[key] for key in (
        "operatingSystem", "architecture"
    )):
        raise RetrievalChunkEvidenceError("host identity is incomplete")
    if host["architecture"] != "arm64":
        raise RetrievalChunkEvidenceError("host architecture must be arm64")
    version = OS_VERSION.search(host["operatingSystem"])
    if version is None or int(version.group(1)) not in SUPPORTED_OS_MAJOR:
        raise RetrievalChunkEvidenceError("host must be supported Sequoia or Tahoe")
    require_positive_count(host["processorCount"], "host.processorCount")
    memory = require_positive_count(
        host["physicalMemoryBytes"], "host.physicalMemoryBytes"
    )
    minimum, maximum = HOST_PROFILES[host_profile]
    if memory < minimum or (maximum is not None and memory > maximum):
        raise RetrievalChunkEvidenceError("physical memory does not match host profile")

    corpus = require_keys(
        root["corpus"],
        {
            "contentSource",
            "userLibraryAccess",
            "meetingCount",
            "sourceSegmentCount",
        },
        "observation.corpus",
    )
    if corpus["contentSource"] != "public-synthetic-only":
        raise RetrievalChunkEvidenceError("collector accepts only public synthetic data")
    if corpus["userLibraryAccess"] != "none":
        raise RetrievalChunkEvidenceError("collector may not read the user library")
    meeting_count = require_positive_count(
        corpus["meetingCount"], "corpus.meetingCount"
    )
    source_segment_count = require_positive_count(
        corpus["sourceSegmentCount"], "corpus.sourceSegmentCount"
    )

    construction_keys = {
        "resultingUnitCount",
        "sourceReferenceCount",
        "turnCount",
        "resources",
    }
    if role == "semantic-boundary":
        construction_keys.add("diagnostics")
    construction = require_keys(
        root["construction"],
        construction_keys,
        "observation.construction",
    )
    for key in ("resultingUnitCount", "sourceReferenceCount", "turnCount"):
        require_count(construction[key], f"construction.{key}")
    if construction["resultingUnitCount"] == 0:
        raise RetrievalChunkEvidenceError("construction produced no units")
    if construction["sourceReferenceCount"] != source_segment_count:
        raise RetrievalChunkEvidenceError("construction lost or repeated sources")
    diagnostics = require_diagnostics(
        construction.get("diagnostics"), "construction.diagnostics"
    )
    if (role == "semantic-boundary") != (diagnostics is not None):
        raise RetrievalChunkEvidenceError("diagnostics do not match the role")
    if diagnostics is not None:
        validate_boundary_accounting(
            diagnostics,
            construction["turnCount"],
            meeting_count,
            "construction.diagnostics",
        )
    require_resource(construction["resources"], "construction.resources")

    corrections = root["corrections"]
    if not isinstance(corrections, list) or len(corrections) != len(SCENARIOS):
        raise RetrievalChunkEvidenceError("correction matrix is incomplete")
    for index, expected_scenario in enumerate(SCENARIOS):
        correction_keys = {
            "scenario",
            "inputSegmentCount",
            "resultingUnitCount",
            "sourceReferenceCount",
            "turnCount",
            "retainedUnitCount",
            "candidateEmbeddingUpsertCount",
            "removedUnitCount",
            "resources",
        }
        if role == "semantic-boundary":
            correction_keys.add("diagnostics")
        correction = require_keys(
            corrections[index],
            correction_keys,
            f"corrections[{index}]",
        )
        if correction["scenario"] != expected_scenario:
            raise RetrievalChunkEvidenceError("correction scenario order changed")
        for key in (
            "inputSegmentCount",
            "resultingUnitCount",
            "sourceReferenceCount",
            "turnCount",
            "retainedUnitCount",
            "candidateEmbeddingUpsertCount",
            "removedUnitCount",
        ):
            require_count(correction[key], f"{expected_scenario}.{key}")
        if correction["resultingUnitCount"] == 0:
            raise RetrievalChunkEvidenceError(f"{expected_scenario} produced no units")
        if correction["sourceReferenceCount"] != correction["inputSegmentCount"]:
            raise RetrievalChunkEvidenceError(
                f"{expected_scenario} lost or repeated sources"
            )
        if correction["resultingUnitCount"] != (
            correction["retainedUnitCount"]
            + correction["candidateEmbeddingUpsertCount"]
        ):
            raise RetrievalChunkEvidenceError(
                f"{expected_scenario} delta does not cover current units"
            )
        if expected_scenario in (
            "publication-fences", "normalized-equivalent-text"
        ) and (
            correction["candidateEmbeddingUpsertCount"] != 0
            or correction["removedUnitCount"] != 0
            or correction["retainedUnitCount"]
            != correction["resultingUnitCount"]
        ):
            raise RetrievalChunkEvidenceError(
                f"{expected_scenario} rebuilt equivalent units"
            )
        scenario_diagnostics = require_diagnostics(
            correction.get("diagnostics"), f"{expected_scenario}.diagnostics"
        )
        if (role == "semantic-boundary") != (scenario_diagnostics is not None):
            raise RetrievalChunkEvidenceError("scenario diagnostics do not match role")
        if scenario_diagnostics is not None:
            validate_boundary_accounting(
                scenario_diagnostics,
                correction["turnCount"],
                1,
                f"{expected_scenario}.diagnostics",
            )
        require_resource(correction["resources"], f"{expected_scenario}.resources")

    reject_payload_keys(root)
    return root


def validate_boundary_accounting(
    diagnostics: dict,
    turn_count: int,
    meeting_count: int,
    label: str,
) -> None:
    if diagnostics["turnCount"] != turn_count:
        raise RetrievalChunkEvidenceError(f"{label} turn count changed")
    decisions = sum(
        diagnostics[key]
        for key in (
            "joinedBoundaryCount",
            "languageTransitionBoundaryCount",
            "unavailableLanguageBoundaryCount",
            "resourceBoundaryCount",
            "similarityBoundaryCount",
        )
    )
    if decisions != turn_count - meeting_count:
        raise RetrievalChunkEvidenceError(f"{label} boundary accounting is incomplete")


def structural_projection(document: dict) -> dict:
    value = copy.deepcopy(document)
    value["construction"].pop("resources")
    for correction in value["corrections"]:
        correction.pop("resources")
    return value


def role_receipt(role: str, observations: list[dict], paths: list[Path]) -> dict:
    structures = [canonical_digest(structural_projection(item)) for item in observations]
    if len(set(structures)) != 1:
        raise RetrievalChunkEvidenceError(
            f"{role} structural observations drifted across fresh processes"
        )
    first = observations[0]
    construction = first["construction"]
    correction_receipts = []
    for index, scenario in enumerate(SCENARIOS):
        template = first["corrections"][index]
        correction_receipts.append({
            "scenario": scenario,
            "resultingUnitCount": template["resultingUnitCount"],
            "retainedUnitCount": template["retainedUnitCount"],
            "candidateEmbeddingUpsertCount": template[
                "candidateEmbeddingUpsertCount"
            ],
            "removedUnitCount": template["removedUnitCount"],
            "vectorizedTurnCount": (
                template["diagnostics"]["vectorizedTurnCount"]
                if template.get("diagnostics") is not None
                else 0
            ),
            "wallMilliseconds": [
                item["corrections"][index]["resources"]["wallMilliseconds"]
                for item in observations
            ],
            "processCPUMilliseconds": [
                item["corrections"][index]["resources"]["processCPUMilliseconds"]
                for item in observations
            ],
            "incrementalPeakPhysicalFootprintBytes": [
                item["corrections"][index]["resources"]
                ["incrementalPeakPhysicalFootprintBytes"]
                for item in observations
            ],
        })
    return {
        "retrievalUnit": role,
        "adapter": first["subject"]["adapter"],
        "runs": len(observations),
        "structuralSHA256": structures[0],
        "observationSHA256": [sha256_file(path) for path in paths],
        "construction": {
            "resultingUnitCount": construction["resultingUnitCount"],
            "sourceReferenceCount": construction["sourceReferenceCount"],
            "turnCount": construction["turnCount"],
            "vectorizedTurnCount": (
                construction["diagnostics"]["vectorizedTurnCount"]
                if construction.get("diagnostics") is not None
                else 0
            ),
            "wallMilliseconds": [
                item["construction"]["resources"]["wallMilliseconds"]
                for item in observations
            ],
            "processCPUMilliseconds": [
                item["construction"]["resources"]["processCPUMilliseconds"]
                for item in observations
            ],
            "incrementalPeakPhysicalFootprintBytes": [
                item["construction"]["resources"]
                ["incrementalPeakPhysicalFootprintBytes"]
                for item in observations
            ],
        },
        "corrections": correction_receipts,
    }


def write_private_json(path: Path, document: dict) -> None:
    path.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    path.chmod(0o600)


def collect_evidence(
    root: Path,
    fixture: Path,
    output: Path,
    build: str,
    host_profile: str,
    runs: int = MINIMUM_RUNS,
    runner=run_command,
) -> Path:
    root = root.resolve()
    fixture = fixture.expanduser().resolve()
    output = output.expanduser().resolve()
    if not SAFE_IDENTITY.fullmatch(build):
        raise RetrievalChunkEvidenceError("build must be receipt-safe")
    if host_profile not in HOST_PROFILES:
        raise RetrievalChunkEvidenceError("host profile is not supported")
    if isinstance(runs, bool) or not isinstance(runs, int):
        raise RetrievalChunkEvidenceError("runs must be an integer")
    if not MINIMUM_RUNS <= runs <= MAXIMUM_RUNS:
        raise RetrievalChunkEvidenceError(
            f"runs must be between {MINIMUM_RUNS} and {MAXIMUM_RUNS}"
        )
    if not fixture.is_file():
        raise RetrievalChunkEvidenceError(f"fixture not found: {fixture}")
    if output.exists():
        raise RetrievalChunkEvidenceError(f"output already exists: {output}")

    status = require_command(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        root,
        "worktree inspection",
        runner=runner,
    )
    if status.stdout.strip():
        raise RetrievalChunkEvidenceError("worktree must be clean")
    commit = require_command(
        ["git", "rev-parse", "HEAD"], root, "commit inspection", runner=runner
    ).stdout.strip()
    if not COMMIT.fullmatch(commit):
        raise RetrievalChunkEvidenceError("git returned an invalid commit")
    if is_within(output, root):
        ignored = runner(["git", "check-ignore", "--quiet", str(output)], root)
        if ignored.returncode != 0:
            raise RetrievalChunkEvidenceError("repository output must be ignored")

    require_command(
        [
            sys.executable,
            str(root / "scripts" / "ask_quality.py"),
            "verify-public",
            "--fixture",
            str(fixture),
        ],
        root,
        "fixture verification",
        runner=runner,
    )
    toolchain = require_command(
        ["xcrun", "swiftc", "--version"], root, "toolchain inspection", runner=runner
    )
    toolchain_identity = (
        "stdout:\n"
        + toolchain.stdout
        + "\nstderr:\n"
        + toolchain.stderr
    ).encode("utf-8")
    toolchain_sha256 = sha256_bytes(toolchain_identity)
    fixture_sha256 = sha256_file(fixture)
    require_command(
        ["swift", "build", "-c", "release", "--product", "portavoz-cli"],
        root,
        "Release CLI build",
        runner=runner,
    )
    cli = root / ".build" / "release" / "portavoz-cli"
    if not cli.is_file():
        raise RetrievalChunkEvidenceError("Release CLI was not published")

    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = output.parent / f".{output.name}.lock"
    lock_descriptor = None
    staging = None
    try:
        try:
            lock_descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError as error:
            raise RetrievalChunkEvidenceError("output is reserved") from error
        staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.partial.", dir=output.parent))
        staging.chmod(0o700)
        by_role: dict[str, list[tuple[dict, Path]]] = {role: [] for role in ROLES}
        for run_index in range(runs):
            rotation = run_index % len(ROLES)
            ordered_roles = ROLES[rotation:] + ROLES[:rotation]
            for role in ordered_roles:
                path = staging / f"{role}-run-{run_index + 1}.json"
                require_command(
                    [
                        str(cli),
                        "bench-retrieval-chunks",
                        "--fixture",
                        str(fixture),
                        "--output",
                        str(path),
                        "--build",
                        build,
                        "--commit",
                        commit,
                        "--fixture-sha256",
                        fixture_sha256,
                        "--toolchain-sha256",
                        toolchain_sha256,
                        "--host-profile",
                        host_profile,
                        "--retrieval-unit",
                        role,
                    ],
                    root,
                    f"{role} observation {run_index + 1}",
                    runner=runner,
                )
                if not path.is_file():
                    raise RetrievalChunkEvidenceError(f"{role} output is missing")
                path.chmod(0o600)
                try:
                    document = json.loads(path.read_text(encoding="utf-8"))
                except (OSError, UnicodeError, json.JSONDecodeError) as error:
                    raise RetrievalChunkEvidenceError(f"{role} output is invalid JSON") from error
                validated = validate_observation(
                    document,
                    role=role,
                    build=build,
                    commit=commit,
                    fixture_sha256=fixture_sha256,
                    toolchain_sha256=toolchain_sha256,
                    host_profile=host_profile,
                )
                by_role[role].append((validated, path))

        roles = [
            role_receipt(
                role,
                [item[0] for item in by_role[role]],
                [item[1] for item in by_role[role]],
            )
            for role in ROLES
        ]
        semantic = next(item for item in roles if item["retrievalUnit"] == "semantic-boundary")
        blockers = []
        if semantic["construction"]["vectorizedTurnCount"] == 0:
            blockers.append("public-fixture-has-zero-baseline-semantic-vector-coverage")
        receipt = {
            "schemaVersion": 1,
            "kind": "retrieval-chunk-resource-correction-receipt",
            "authority": "research-resource-correction-only",
            "contentPolicy": "content-free",
            "outcome": "blocked" if blockers else "review-required",
            "blockingReasons": blockers,
            "candidateSelection": "not-evaluated",
            "performanceDecision": "not-evaluated",
            "productComposition": "unchanged",
            "sourceCommit": commit,
            "build": build,
            "fixtureSHA256": fixture_sha256,
            "toolchainSHA256": toolchain_sha256,
            "hostProfile": host_profile,
            "runsPerRole": runs,
            "roles": roles,
        }
        write_private_json(staging / "receipt.json", receipt)
        os.rename(staging, output)
        staging = None
        output.chmod(0o700)
        for path in output.iterdir():
            path.chmod(0o600)
        return output / "receipt.json"
    finally:
        if lock_descriptor is not None:
            os.close(lock_descriptor)
        try:
            lock.unlink()
        except FileNotFoundError:
            pass
        if staging is not None:
            shutil.rmtree(staging, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--host-profile", required=True)
    parser.add_argument("--runs", type=int, default=MINIMUM_RUNS)
    arguments = parser.parse_args()
    try:
        receipt = collect_evidence(
            ROOT,
            arguments.fixture,
            arguments.output,
            arguments.build,
            arguments.host_profile,
            arguments.runs,
        )
    except RetrievalChunkEvidenceError as error:
        print(f"retrieval-chunk-evidence error: {error}", file=sys.stderr)
        return 64
    print(receipt)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
