#!/usr/bin/env python3
"""Own the staged, two-Mac production CloudKit qualification protocol."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

import release_reliability


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = ROOT / "docs" / "evidence" / "production-sync-qualification.json"
CONTRACT_SCHEMA_VERSION = 1
MANIFEST_SCHEMA_VERSION = 1
STAGE_RECEIPT_SCHEMA_VERSION = 1
AUTHORITY_SCHEMA_VERSION = 1
MANIFEST_NAME = "run.json"
CONTRACT_RESOURCE_NAME = "production-sync-qualification.json"
FROZEN_CONTRACT_SHA256 = "2f6fb818d79dde06f8334203a807e0f8e34d2eae926d22facbd2b7cc2a2d967b"
QUALIFICATION_BUNDLE_ID = "app.portavoz.mac"
QUALIFICATION_DISPLAY_NAME = "Portavoz Sync Qualification"
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
OS_BUILD_PATTERN = re.compile(r"^[0-9]{2}[A-Z][0-9A-Za-z]{1,15}$")
UUID_PATTERN = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
ROLE_PATTERN = re.compile(r"^[ab]$")
STAGE_PATTERN = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
EXTERNAL_ACTIONS = {
    "none",
    "disable-network",
    "restore-network",
    "sign-out-original-account",
    "sign-in-original-account",
    "switch-to-secondary-account",
    "restore-original-account",
}
FORBIDDEN_CONTENT_KEYS = {
    "accountFingerprint",
    "audio",
    "content",
    "meetingTitle",
    "note",
    "path",
    "platformUUID",
    "prompt",
    "question",
    "recordName",
    "serialNumber",
    "text",
    "transcript",
    "url",
}


class ProductionSyncQualificationError(ValueError):
    """A fail-closed production-sync qualification error."""


def canonical_json(document: Any) -> bytes:
    return json.dumps(
        document,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def exact_object(
    value: Any,
    label: str,
    keys: Iterable[str],
    optional: Iterable[str] = (),
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ProductionSyncQualificationError(f"{label} must be an object")
    expected = set(keys)
    allowed = expected | set(optional)
    actual = set(value)
    if not expected.issubset(actual) or not actual.issubset(allowed):
        missing = sorted(expected - actual)
        extra = sorted(actual - allowed)
        raise ProductionSyncQualificationError(
            f"{label} has an invalid shape (missing={missing}, extra={extra})"
        )
    return value


def exact_string(
    value: Any,
    label: str,
    pattern: re.Pattern[str] | None = None,
) -> str:
    if not isinstance(value, str) or not value:
        raise ProductionSyncQualificationError(f"{label} must be a nonempty string")
    if pattern is not None and pattern.fullmatch(value) is None:
        raise ProductionSyncQualificationError(f"{label} has an invalid format")
    return value


def exact_integer(value: Any, label: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ProductionSyncQualificationError(
            f"{label} must be an integer >= {minimum}"
        )
    return value


def exact_boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise ProductionSyncQualificationError(f"{label} must be a boolean")
    return value


def validate_timestamp(value: Any, label: str) -> str:
    text = exact_string(value, label)
    if not text.endswith("Z"):
        raise ProductionSyncQualificationError(f"{label} must be UTC")
    try:
        parsed = datetime.fromisoformat(text[:-1] + "+00:00")
    except ValueError as error:
        raise ProductionSyncQualificationError(f"{label} is invalid") from error
    if parsed.tzinfo != timezone.utc:
        raise ProductionSyncQualificationError(f"{label} must be UTC")
    return text


def load_json(path: Path, label: str, *, maximum_bytes: int = 1024 * 1024) -> Any:
    if path.is_symlink() or not path.is_file():
        raise ProductionSyncQualificationError(f"{label} must be a regular file")
    size = path.stat().st_size
    if size <= 0 or size > maximum_bytes:
        raise ProductionSyncQualificationError(f"{label} has an invalid size")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ProductionSyncQualificationError(f"{label} is not valid JSON") from error


def require_owner_only(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise ProductionSyncQualificationError(f"{label} must be a regular file")
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode != 0o600:
        raise ProductionSyncQualificationError(f"{label} must have mode 0600")


def require_owner_directory(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_dir():
        raise ProductionSyncQualificationError(f"{label} must be a directory")
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode != 0o700:
        raise ProductionSyncQualificationError(f"{label} must have mode 0700")


def require_stage_workspace_location(path: Path) -> None:
    allowed_roots = (Path.home().resolve(), Path(tempfile.gettempdir()).resolve())
    if not any(path != root and path.is_relative_to(root) for root in allowed_roots):
        raise ProductionSyncQualificationError(
            "production-sync stage workspace must be below home or the temporary directory"
        )


def prepare_owner_subdirectory(parent: Path, name: str) -> Path:
    require_owner_directory(parent, "production-sync directory parent")
    child = parent / name
    if child.is_symlink():
        raise ProductionSyncQualificationError(
            f"production-sync directory {child} must not be a symbolic link"
        )
    if child.exists():
        require_owner_directory(child, f"production-sync directory {child}")
    else:
        child.mkdir(mode=0o700)
        require_owner_directory(child, f"production-sync directory {child}")
    return child


def prepare_stage_directories(workspace: Path, role: str) -> Path:
    roles = prepare_owner_subdirectory(workspace, "roles")
    prepare_owner_subdirectory(roles, role)
    receipts = prepare_owner_subdirectory(workspace, "receipts")
    for receipt_role in ("a", "b"):
        prepare_owner_subdirectory(receipts, receipt_role)
    prepare_owner_subdirectory(workspace, "live")
    app_shell = prepare_owner_subdirectory(workspace, "app-shell")
    return prepare_owner_subdirectory(app_shell, role)


def atomic_write_json(path: Path, document: Any) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    data = json.dumps(
        document,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    ).encode("utf-8") + b"\n"
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.",
        dir=path.parent,
    )
    temporary_path = Path(temporary)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
        os.chmod(path, 0o600)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        temporary_path.unlink(missing_ok=True)
        raise


def release_identity(value: Any, label: str = "release") -> dict[str, str]:
    root = exact_object(value, label, ("version", "build", "commit"))
    try:
        return {
            "version": release_reliability.safe_string(
                root["version"], f"{label}.version", release_reliability.VERSION_PATTERN
            ),
            "build": release_reliability.safe_string(
                root["build"], f"{label}.build", release_reliability.BUILD_PATTERN
            ),
            "commit": release_reliability.safe_string(
                root["commit"], f"{label}.commit", release_reliability.COMMIT_PATTERN
            ),
        }
    except release_reliability.ReliabilityError as error:
        raise ProductionSyncQualificationError(str(error)) from error


def validate_contract(document: Any) -> dict[str, Any]:
    root = exact_object(
        document,
        "production-sync contract",
        (
            "schemaVersion",
            "kind",
            "scope",
            "proof",
            "corpus",
            "roles",
            "stages",
            "limits",
        ),
    )
    if exact_integer(root["schemaVersion"], "contract.schemaVersion", minimum=1) != 1:
        raise ProductionSyncQualificationError("contract.schemaVersion must be 1")
    if root["kind"] != "production-sync-qualification-contract":
        raise ProductionSyncQualificationError("contract.kind is invalid")
    if root["scope"] != "production-sync" or root["proof"] != "admission":
        raise ProductionSyncQualificationError("contract release authority is invalid")
    corpus = exact_object(
        root["corpus"],
        "contract.corpus",
        ("schemaVersion", "sha256", "languages"),
    )
    if exact_integer(corpus["schemaVersion"], "contract.corpus.schemaVersion", minimum=1) != 1:
        raise ProductionSyncQualificationError("contract corpus schema is invalid")
    exact_string(corpus["sha256"], "contract.corpus.sha256", DIGEST_PATTERN)
    if corpus["languages"] != ["en", "es"]:
        raise ProductionSyncQualificationError("contract corpus must be bilingual EN/ES")
    if root["roles"] != ["a", "b"]:
        raise ProductionSyncQualificationError("contract roles must be a then b")
    if not isinstance(root["stages"], list) or not root["stages"]:
        raise ProductionSyncQualificationError("contract.stages must be nonempty")
    stages: dict[str, dict[str, Any]] = {}
    role_sequences: dict[str, list[int]] = {"a": [], "b": []}
    for index, raw in enumerate(root["stages"]):
        stage = exact_object(
            raw,
            f"contract.stages[{index}]",
            ("id", "role", "roleSequence", "requires", "externalAction"),
            ("requiresLiveStage",),
        )
        stage_id = exact_string(stage["id"], f"contract.stages[{index}].id", STAGE_PATTERN)
        role = exact_string(stage["role"], f"contract.stages[{index}].role", ROLE_PATTERN)
        sequence = exact_integer(
            stage["roleSequence"],
            f"contract.stages[{index}].roleSequence",
            minimum=1,
        )
        key = f"{role}.{stage_id}"
        if key in stages:
            raise ProductionSyncQualificationError(f"contract repeats stage {key}")
        if not isinstance(stage["requires"], list) or any(
            not isinstance(item, str) for item in stage["requires"]
        ):
            raise ProductionSyncQualificationError(f"contract stage {key} requires is invalid")
        action = exact_string(
            stage["externalAction"],
            f"contract.stages[{index}].externalAction",
            STAGE_PATTERN,
        )
        if action not in EXTERNAL_ACTIONS:
            raise ProductionSyncQualificationError(
                f"contract stage {key} has unknown external action {action}"
            )
        stages[key] = stage
        role_sequences[role].append(sequence)
    for role, sequences in role_sequences.items():
        if sorted(sequences) != list(range(1, len(sequences) + 1)):
            raise ProductionSyncQualificationError(
                f"contract role {role} stages are not contiguous"
            )
    for key, stage in stages.items():
        if len(set(stage["requires"])) != len(stage["requires"]):
            raise ProductionSyncQualificationError(
                f"contract stage {key} repeats a requirement"
            )
        for requirement in stage["requires"]:
            if requirement not in stages or requirement == key:
                raise ProductionSyncQualificationError(
                    f"contract stage {key} has invalid requirement {requirement}"
                )
        live_requirement = stage.get("requiresLiveStage")
        if live_requirement is not None:
            if not isinstance(live_requirement, str) or live_requirement not in stages:
                raise ProductionSyncQualificationError(
                    f"contract stage {key} has invalid live-stage requirement"
                )
    live_requirements = {
        key: stage["requiresLiveStage"]
        for key, stage in stages.items()
        if "requiresLiveStage" in stage
    }
    if live_requirements != {"a.push-source": "b.await-push"}:
        raise ProductionSyncQualificationError(
            "contract must freeze the silent-push live-stage boundary"
        )
    unresolved = {key: set(stage["requires"]) for key, stage in stages.items()}
    resolved: set[str] = set()
    while unresolved:
        ready = sorted(
            key for key, requirements in unresolved.items()
            if requirements <= resolved
        )
        if not ready:
            raise ProductionSyncQualificationError("contract stage graph is cyclic")
        for key in ready:
            resolved.add(key)
            del unresolved[key]
    limits = exact_object(
        root["limits"],
        "contract.limits",
        (
            "maximumReceiptBytes",
            "maximumPushWakes",
            "defaultStageTimeoutSeconds",
            "pushStageTimeoutSeconds",
        ),
    )
    for key in limits:
        exact_integer(limits[key], f"contract.limits.{key}", minimum=1)
    if limits["maximumReceiptBytes"] > 1024 * 1024:
        raise ProductionSyncQualificationError("contract receipt ceiling is too large")
    if limits["pushStageTimeoutSeconds"] < limits["defaultStageTimeoutSeconds"]:
        raise ProductionSyncQualificationError("contract push timeout is too small")
    return root


def load_contract(path: Path = DEFAULT_CONTRACT) -> tuple[dict[str, Any], str]:
    try:
        if path.is_symlink() or not path.is_file():
            raise ProductionSyncQualificationError(
                "production-sync contract must be a regular file"
            )
        data = path.read_bytes()
        if not data or len(data) > 1024 * 1024:
            raise ProductionSyncQualificationError(
                "production-sync contract has an invalid size"
            )
        document = json.loads(data)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ProductionSyncQualificationError(
            "production-sync contract is not valid JSON"
        ) from error
    digest = sha256_bytes(data)
    if digest != FROZEN_CONTRACT_SHA256:
        raise ProductionSyncQualificationError(
            "production-sync contract digest is not the frozen contract"
        )
    return validate_contract(document), digest


def stage_catalog(contract: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        f"{stage['role']}.{stage['id']}": stage
        for stage in contract["stages"]
    }


def validate_manifest(document: Any) -> dict[str, Any]:
    root = exact_object(
        document,
        "production-sync manifest",
        (
            "schemaVersion",
            "kind",
            "runID",
            "createdAt",
            "release",
            "contractSHA256",
            "executableSHA256",
            "codeResourcesSHA256",
            "provisioningProfileSHA256",
            "runNonce",
            "corpus",
        ),
    )
    if exact_integer(root["schemaVersion"], "manifest.schemaVersion", minimum=1) != 1:
        raise ProductionSyncQualificationError("manifest.schemaVersion must be 1")
    if root["kind"] != "production-sync-qualification-run":
        raise ProductionSyncQualificationError("manifest.kind is invalid")
    exact_string(root["runID"], "manifest.runID", UUID_PATTERN)
    validate_timestamp(root["createdAt"], "manifest.createdAt")
    root["release"] = release_identity(root["release"], "manifest.release")
    exact_string(root["contractSHA256"], "manifest.contractSHA256", DIGEST_PATTERN)
    exact_string(root["executableSHA256"], "manifest.executableSHA256", DIGEST_PATTERN)
    exact_string(
        root["codeResourcesSHA256"],
        "manifest.codeResourcesSHA256",
        DIGEST_PATTERN,
    )
    exact_string(
        root["provisioningProfileSHA256"],
        "manifest.provisioningProfileSHA256",
        DIGEST_PATTERN,
    )
    exact_string(root["runNonce"], "manifest.runNonce", DIGEST_PATTERN)
    corpus = exact_object(
        root["corpus"],
        "manifest.corpus",
        ("sha256", "meetingID", "speakerIDs", "segmentIDs"),
    )
    exact_string(corpus["sha256"], "manifest.corpus.sha256", DIGEST_PATTERN)
    exact_string(corpus["meetingID"], "manifest.corpus.meetingID", UUID_PATTERN)
    if not isinstance(corpus["speakerIDs"], list) or len(corpus["speakerIDs"]) != 2:
        raise ProductionSyncQualificationError("manifest corpus requires two speakers")
    if not isinstance(corpus["segmentIDs"], list) or len(corpus["segmentIDs"]) != 2:
        raise ProductionSyncQualificationError("manifest corpus requires two segments")
    identities = [corpus["meetingID"], *corpus["speakerIDs"], *corpus["segmentIDs"]]
    for index, identity in enumerate(identities):
        exact_string(identity, f"manifest.corpus identity {index}", UUID_PATTERN)
    if len(set(identities)) != len(identities):
        raise ProductionSyncQualificationError("manifest corpus identities must be unique")
    return root


def inspect_qualification_app(app: Path) -> dict[str, Any]:
    if not app.is_absolute() or app.is_symlink() or not app.is_dir() or app.suffix != ".app":
        raise ProductionSyncQualificationError("qualification app must be an absolute app path")
    info_path = app / "Contents" / "Info.plist"
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ProductionSyncQualificationError("qualification app Info.plist is invalid") from error
    expected = {
        "CFBundleIdentifier": QUALIFICATION_BUNDLE_ID,
        "CFBundleDisplayName": QUALIFICATION_DISPLAY_NAME,
        "CFBundleName": QUALIFICATION_DISPLAY_NAME,
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise ProductionSyncQualificationError(f"qualification app has invalid {key}")
    release = release_identity(
        {
            "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"),
            "commit": info.get("PortavozSourceCommit"),
        },
        "qualification app release",
    )
    executable_name = exact_string(info.get("CFBundleExecutable"), "CFBundleExecutable")
    executable = app / "Contents" / "MacOS" / executable_name
    if executable.is_symlink() or not executable.is_file():
        raise ProductionSyncQualificationError("qualification app executable is invalid")
    resource = app / "Contents" / "Resources" / CONTRACT_RESOURCE_NAME
    if resource.is_symlink() or not resource.is_file():
        raise ProductionSyncQualificationError("qualification app lacks its contract resource")
    bundled_contract, bundled_digest = load_contract(resource)
    code_resources = app / "Contents" / "_CodeSignature" / "CodeResources"
    profile = app / "Contents" / "embedded.provisionprofile"
    for path, label in (
        (code_resources, "qualification app code resources"),
        (profile, "qualification app provisioning profile"),
    ):
        if path.is_symlink() or not path.is_file():
            raise ProductionSyncQualificationError(f"{label} is invalid")
    return {
        "release": release,
        "executable": executable,
        "executableSHA256": sha256_file(executable),
        "codeResourcesSHA256": sha256_file(code_resources),
        "provisioningProfileSHA256": sha256_file(profile),
        "contract": bundled_contract,
        "contractSHA256": bundled_digest,
    }


def require_exact_checkout(commit: str) -> None:
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if head != commit:
        raise ProductionSyncQualificationError("checked-out Git commit differs from the run")
    status_output = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    if status_output:
        raise ProductionSyncQualificationError("production-sync qualification requires clean tracked source")


def initialize(args: argparse.Namespace) -> None:
    workspace = args.workspace.resolve()
    require_stage_workspace_location(workspace)
    if workspace.exists():
        if not workspace.is_dir() or any(workspace.iterdir()):
            raise ProductionSyncQualificationError("qualification workspace must be absent or empty")
    app_info = inspect_qualification_app(args.app.resolve())
    local_contract, local_digest = load_contract()
    if app_info["contractSHA256"] != local_digest or app_info["contract"] != local_contract:
        raise ProductionSyncQualificationError("app contract differs from tracked source")
    release = app_info["release"]
    expected = {
        "version": args.version,
        "build": args.build,
        "commit": args.commit,
    }
    if release != release_identity(expected, "requested release"):
        raise ProductionSyncQualificationError("qualification app release identity differs from requested release")
    require_exact_checkout(release["commit"])
    if not workspace.exists():
        workspace.mkdir(mode=0o700, parents=True)
    os.chmod(workspace, 0o700)
    require_owner_directory(workspace, "production-sync workspace")
    manifest = {
        "schemaVersion": MANIFEST_SCHEMA_VERSION,
        "kind": "production-sync-qualification-run",
        "runID": str(uuid.uuid4()),
        "createdAt": utc_now(),
        "release": release,
        "contractSHA256": local_digest,
        "executableSHA256": app_info["executableSHA256"],
        "codeResourcesSHA256": app_info["codeResourcesSHA256"],
        "provisioningProfileSHA256": app_info["provisioningProfileSHA256"],
        "runNonce": os.urandom(32).hex(),
        "corpus": {
            "sha256": local_contract["corpus"]["sha256"],
            "meetingID": str(uuid.uuid4()),
            "speakerIDs": [str(uuid.uuid4()), str(uuid.uuid4())],
            "segmentIDs": [str(uuid.uuid4()), str(uuid.uuid4())],
        },
    }
    validate_manifest(manifest)
    atomic_write_json(workspace / MANIFEST_NAME, manifest)
    print(f"Initialized production-sync run {manifest['runID']}")
    print(f"Manifest: {workspace / MANIFEST_NAME}")


def validate_no_content_keys(value: Any, label: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key in FORBIDDEN_CONTENT_KEYS:
                raise ProductionSyncQualificationError(
                    f"{label} contains forbidden content key {key}"
                )
            validate_no_content_keys(child, f"{label}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            validate_no_content_keys(child, f"{label}[{index}]")


def validate_stage_receipt(
    document: Any,
    *,
    manifest: dict[str, Any],
    contract: dict[str, Any],
    label: str,
) -> dict[str, Any]:
    validate_no_content_keys(document, label)
    root = exact_object(
        document,
        label,
        (
            "schemaVersion",
            "kind",
            "collectedAt",
            "runID",
            "contractSHA256",
            "release",
            "executableSHA256",
            "codeResourcesSHA256",
            "provisioningProfileSHA256",
            "role",
            "stage",
            "roleSequence",
            "processNonce",
            "hostScopeSHA256",
            "accountScopeSHA256",
            "predecessorSHA256",
            "liveStageMarkerSHA256",
            "corpus",
            "lifecycle",
            "pushWakes",
            "os",
        ),
    )
    if exact_integer(root["schemaVersion"], f"{label}.schemaVersion", minimum=1) != 1:
        raise ProductionSyncQualificationError(f"{label}.schemaVersion must be 1")
    if root["kind"] != "production-sync-stage":
        raise ProductionSyncQualificationError(f"{label}.kind is invalid")
    validate_timestamp(root["collectedAt"], f"{label}.collectedAt")
    if root["runID"] != manifest["runID"]:
        raise ProductionSyncQualificationError(f"{label}.runID differs")
    if root["contractSHA256"] != manifest["contractSHA256"]:
        raise ProductionSyncQualificationError(f"{label}.contractSHA256 differs")
    if release_identity(root["release"], f"{label}.release") != manifest["release"]:
        raise ProductionSyncQualificationError(f"{label}.release differs")
    if root["executableSHA256"] != manifest["executableSHA256"]:
        raise ProductionSyncQualificationError(f"{label}.executableSHA256 differs")
    if root["codeResourcesSHA256"] != manifest["codeResourcesSHA256"]:
        raise ProductionSyncQualificationError(f"{label}.codeResourcesSHA256 differs")
    if root["provisioningProfileSHA256"] != manifest["provisioningProfileSHA256"]:
        raise ProductionSyncQualificationError(
            f"{label}.provisioningProfileSHA256 differs"
        )
    role = exact_string(root["role"], f"{label}.role", ROLE_PATTERN)
    stage = exact_string(root["stage"], f"{label}.stage", STAGE_PATTERN)
    stage_key = f"{role}.{stage}"
    descriptor = stage_catalog(contract).get(stage_key)
    if descriptor is None:
        raise ProductionSyncQualificationError(f"{label} names unknown stage {stage_key}")
    sequence = exact_integer(root["roleSequence"], f"{label}.roleSequence", minimum=1)
    if sequence != descriptor["roleSequence"]:
        raise ProductionSyncQualificationError(f"{label}.roleSequence differs")
    exact_string(root["processNonce"], f"{label}.processNonce", UUID_PATTERN)
    exact_string(root["hostScopeSHA256"], f"{label}.hostScopeSHA256", DIGEST_PATTERN)
    if root["accountScopeSHA256"] is not None:
        exact_string(
            root["accountScopeSHA256"],
            f"{label}.accountScopeSHA256",
            DIGEST_PATTERN,
        )
    if root["predecessorSHA256"] is not None:
        exact_string(
            root["predecessorSHA256"],
            f"{label}.predecessorSHA256",
            DIGEST_PATTERN,
        )
    if root["liveStageMarkerSHA256"] is not None:
        exact_string(
            root["liveStageMarkerSHA256"],
            f"{label}.liveStageMarkerSHA256",
            DIGEST_PATTERN,
        )
    corpus = exact_object(
        root["corpus"],
        f"{label}.corpus",
        ("sha256", "state", "liveMeetings", "deletedMeetings"),
    )
    if corpus["sha256"] != manifest["corpus"]["sha256"]:
        raise ProductionSyncQualificationError(f"{label}.corpus.sha256 differs")
    if corpus["state"] not in {"absent", "seed", "editA", "editB", "retry", "push", "deleted"}:
        raise ProductionSyncQualificationError(f"{label}.corpus.state is invalid")
    exact_integer(corpus["liveMeetings"], f"{label}.corpus.liveMeetings")
    exact_integer(corpus["deletedMeetings"], f"{label}.corpus.deletedMeetings")
    lifecycle = exact_object(
        root["lifecycle"],
        f"{label}.lifecycle",
        (
            "phase",
            "accountStatus",
            "isEnabled",
            "initialSeedState",
            "pendingLocalChanges",
            "queuedTransfers",
            "retryingTransfers",
            "failedTransfers",
        ),
    )
    if lifecycle["phase"] not in {"localOnly", "pending", "synchronized", "paused", "retrying", "failed"}:
        raise ProductionSyncQualificationError(f"{label}.lifecycle.phase is invalid")
    if lifecycle["accountStatus"] not in {"unknown", "available", "signedOut", "restricted", "temporarilyUnavailable"}:
        raise ProductionSyncQualificationError(f"{label}.lifecycle.accountStatus is invalid")
    exact_boolean(lifecycle["isEnabled"], f"{label}.lifecycle.isEnabled")
    if lifecycle["initialSeedState"] not in {"blocked", "notRequested", "requested", "complete"}:
        raise ProductionSyncQualificationError(f"{label}.lifecycle.initialSeedState is invalid")
    for key in (
        "pendingLocalChanges",
        "queuedTransfers",
        "retryingTransfers",
        "failedTransfers",
    ):
        exact_integer(lifecycle[key], f"{label}.lifecycle.{key}")
    pushes = exact_integer(root["pushWakes"], f"{label}.pushWakes")
    if pushes > contract["limits"]["maximumPushWakes"]:
        raise ProductionSyncQualificationError(f"{label}.pushWakes exceeds contract")
    os_value = exact_object(root["os"], f"{label}.os", ("major", "minor", "patch", "build", "architecture"))
    for key in ("major", "minor", "patch"):
        exact_integer(os_value[key], f"{label}.os.{key}")
    exact_string(os_value["build"], f"{label}.os.build", OS_BUILD_PATTERN)
    major = os_value["major"]
    if major != 15 and major < 26:
        raise ProductionSyncQualificationError(
            f"{label}.os.major is not Sequoia, Tahoe, or newer"
        )
    if os_value["architecture"] not in {"arm64", "x86_64"}:
        raise ProductionSyncQualificationError(f"{label}.os.architecture is invalid")
    validate_stage_semantics(root, stage_key, contract)
    return root


EXPECTED_CORPUS_STATE = {
    "a.prepare-existing": "seed",
    "a.enable": "seed",
    "b.enable": "absent",
    "a.include-existing": "seed",
    "b.receive-existing": "seed",
    "a.edit-a": "editA",
    "b.receive-a-edit": "editA",
    "b.edit-b": "editB",
    "a.receive-b-edit": "editB",
    "a.offline-prepare": "retry",
    "a.offline-attempt": "retry",
    "a.retry-relaunch": "retry",
    "b.receive-retry": "retry",
    "a.push-source": "push",
    "b.await-push": "push",
    "b.delete-tombstone": "deleted",
    "a.receive-tombstone": "deleted",
    "a.observe-signout": "deleted",
    "a.resume-signin": "deleted",
    "a.observe-account-switch": "deleted",
    "a.enable-switched-account": "deleted",
    "a.observe-account-restore": "deleted",
    "a.enable-restored-account": "deleted",
    "a.pause": "deleted",
    "a.remove-device": "deleted",
    "b.pause": "deleted",
    "b.remove-device": "deleted",
}


def validate_stage_semantics(
    receipt: dict[str, Any],
    stage_key: str,
    contract: dict[str, Any],
) -> None:
    corpus = receipt["corpus"]
    lifecycle = receipt["lifecycle"]
    if corpus["state"] != EXPECTED_CORPUS_STATE[stage_key]:
        raise ProductionSyncQualificationError(f"{stage_key} has the wrong corpus state")
    if corpus["state"] == "absent":
        expected_counts = (0, 0)
    elif corpus["state"] == "deleted":
        expected_counts = (0, 1)
    else:
        expected_counts = (1, 0)
    if (corpus["liveMeetings"], corpus["deletedMeetings"]) != expected_counts:
        raise ProductionSyncQualificationError(f"{stage_key} has invalid corpus counts")
    if stage_key == "a.prepare-existing":
        if receipt["accountScopeSHA256"] is not None:
            raise ProductionSyncQualificationError("prepare-existing cannot carry account scope")
        expected = ("localOnly", "unknown", False, "blocked")
    elif stage_key == "a.offline-prepare":
        expected = ("pending", "available", True, "complete")
        if lifecycle["pendingLocalChanges"] < 1:
            raise ProductionSyncQualificationError("offline preparation lacks a pending change")
    elif stage_key == "a.offline-attempt":
        if lifecycle["phase"] not in {"failed", "retrying"}:
            raise ProductionSyncQualificationError("offline attempt did not fail or retry")
        if (
            lifecycle["accountStatus"],
            lifecycle["isEnabled"],
            lifecycle["initialSeedState"],
        ) != ("available", True, "complete"):
            raise ProductionSyncQualificationError(
                "offline attempt has invalid account or seed state"
            )
        if lifecycle["pendingLocalChanges"] + lifecycle["queuedTransfers"] < 1:
            raise ProductionSyncQualificationError("offline attempt retained no durable work")
        expected = None
    elif stage_key == "a.observe-signout":
        expected = ("paused", "signedOut", True, "blocked")
    elif stage_key in {"a.observe-account-switch", "a.observe-account-restore"}:
        expected = ("localOnly", "available", False, "blocked")
    elif stage_key in {"a.pause", "b.pause"}:
        expected = ("localOnly", "available", False, "blocked")
    elif stage_key in {"a.remove-device", "b.remove-device"}:
        expected = ("localOnly", "unknown", False, "blocked")
    else:
        initial_seed = "complete" if stage_key == "a.include-existing" else "notRequested"
        if stage_key.startswith("a.") and stage_key not in {
            "a.enable",
            "a.enable-switched-account",
            "a.enable-restored-account",
        }:
            initial_seed = "complete"
        expected = ("synchronized", "available", True, initial_seed)
    if expected is not None:
        actual = (
            lifecycle["phase"],
            lifecycle["accountStatus"],
            lifecycle["isEnabled"],
            lifecycle["initialSeedState"],
        )
        if actual != expected:
            raise ProductionSyncQualificationError(
                f"{stage_key} has invalid lifecycle state {actual}"
            )
    if stage_key == "b.await-push":
        if not 1 <= receipt["pushWakes"] <= contract["limits"]["maximumPushWakes"]:
            raise ProductionSyncQualificationError("silent-push stage lacks an APNs wake")
    elif receipt["pushWakes"] != 0:
        raise ProductionSyncQualificationError(f"{stage_key} cannot carry push wakes")
    if stage_key in {"a.push-source", "b.await-push"}:
        if receipt["liveStageMarkerSHA256"] is None:
            raise ProductionSyncQualificationError(
                f"{stage_key} lacks its live-stage marker"
            )
    elif receipt["liveStageMarkerSHA256"] is not None:
        raise ProductionSyncQualificationError(
            f"{stage_key} cannot carry a live-stage marker"
        )
    if stage_key not in {"a.prepare-existing"} and receipt["accountScopeSHA256"] is None:
        raise ProductionSyncQualificationError(f"{stage_key} lacks account scope")
    if stage_key not in {"a.offline-prepare", "a.offline-attempt"}:
        if lifecycle["phase"] == "synchronized" and any(
            lifecycle[key] != 0
            for key in (
                "pendingLocalChanges",
                "queuedTransfers",
                "retryingTransfers",
                "failedTransfers",
            )
        ):
            raise ProductionSyncQualificationError(f"{stage_key} did not converge")


def receipt_path(workspace: Path, role: str, sequence: int, stage: str) -> Path:
    return workspace / "receipts" / role / f"{sequence:02d}-{stage}.json"


def live_stage_marker_path(workspace: Path, stage_key: str) -> Path:
    return workspace / "live" / f"{stage_key.replace('.', '-')}.json"


def validate_live_stage_marker(
    workspace: Path,
    stage_key: str,
    *,
    manifest: dict[str, Any],
    contract: dict[str, Any],
) -> tuple[dict[str, Any], str]:
    descriptor = stage_catalog(contract).get(stage_key)
    if descriptor is None:
        raise ProductionSyncQualificationError("live-stage marker names unknown stage")
    path = live_stage_marker_path(workspace, stage_key)
    require_owner_only(path, f"live-stage marker {stage_key}")
    marker = exact_object(
        load_json(
            path,
            f"live-stage marker {stage_key}",
            maximum_bytes=contract["limits"]["maximumReceiptBytes"],
        ),
        f"live-stage marker {stage_key}",
        (
            "schemaVersion",
            "kind",
            "collectedAt",
            "runID",
            "contractSHA256",
            "release",
            "executableSHA256",
            "codeResourcesSHA256",
            "provisioningProfileSHA256",
            "role",
            "stage",
            "processNonce",
            "hostScopeSHA256",
        ),
    )
    if exact_integer(marker["schemaVersion"], "live-stage marker.schemaVersion", minimum=1) != 1:
        raise ProductionSyncQualificationError("live-stage marker schema is invalid")
    if marker["kind"] != "production-sync-live-stage":
        raise ProductionSyncQualificationError("live-stage marker kind is invalid")
    validate_timestamp(marker["collectedAt"], "live-stage marker.collectedAt")
    if marker["runID"] != manifest["runID"]:
        raise ProductionSyncQualificationError("live-stage marker run differs")
    if marker["contractSHA256"] != manifest["contractSHA256"]:
        raise ProductionSyncQualificationError("live-stage marker contract differs")
    if release_identity(marker["release"], "live-stage marker.release") != manifest["release"]:
        raise ProductionSyncQualificationError("live-stage marker release differs")
    if marker["executableSHA256"] != manifest["executableSHA256"]:
        raise ProductionSyncQualificationError("live-stage marker executable differs")
    if marker["codeResourcesSHA256"] != manifest["codeResourcesSHA256"]:
        raise ProductionSyncQualificationError("live-stage marker code resources differ")
    if marker["provisioningProfileSHA256"] != manifest["provisioningProfileSHA256"]:
        raise ProductionSyncQualificationError(
            "live-stage marker provisioning profile differs"
        )
    if marker["role"] != descriptor["role"] or marker["stage"] != descriptor["id"]:
        raise ProductionSyncQualificationError("live-stage marker identity differs")
    exact_string(marker["processNonce"], "live-stage marker.processNonce", UUID_PATTERN)
    exact_string(marker["hostScopeSHA256"], "live-stage marker.hostScopeSHA256", DIGEST_PATTERN)
    return marker, sha256_file(path)


def validate_stage_prerequisites(
    workspace: Path,
    *,
    descriptor: dict[str, Any],
    manifest: dict[str, Any],
    contract: dict[str, Any],
) -> None:
    catalog = stage_catalog(contract)
    for requirement in descriptor["requires"]:
        required = catalog[requirement]
        role, stage = requirement.split(".", 1)
        path = receipt_path(
            workspace,
            role,
            required["roleSequence"],
            stage,
        )
        if not path.exists():
            raise ProductionSyncQualificationError(
                f"requested stage requires completed receipt {requirement}"
            )
        require_owner_only(path, f"stage prerequisite {requirement}")
        receipt = validate_stage_receipt(
            load_json(
                path,
                f"stage prerequisite {requirement}",
                maximum_bytes=contract["limits"]["maximumReceiptBytes"],
            ),
            manifest=manifest,
            contract=contract,
            label=f"stage prerequisite {requirement}",
        )
        if receipt["role"] != role or receipt["stage"] != stage:
            raise ProductionSyncQualificationError(
                f"stage prerequisite {requirement} has wrong identity"
            )


def validate_external_action(
    stage_key: str,
    descriptor: dict[str, Any],
    confirmation: str | None,
) -> None:
    expected = descriptor["externalAction"]
    if expected == "none":
        if confirmation is not None:
            raise ProductionSyncQualificationError(
                f"stage {stage_key} accepts no external-action confirmation"
            )
        return
    if confirmation != expected:
        raise ProductionSyncQualificationError(
            f"stage {stage_key} requires --confirm-external-action {expected}"
        )


def qualification_environment(shell_database: Path) -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("PORTAVOZ_")
    }
    environment["PORTAVOZ_UI_TEST_DATABASE_PATH"] = str(shell_database)
    return environment


@contextmanager
def reserve_stage(workspace: Path, role: str, stage: str):
    reservation = workspace / f".production-sync-{role}-{stage}.lock"
    try:
        descriptor = os.open(
            reservation,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        os.close(descriptor)
    except FileExistsError as error:
        raise ProductionSyncQualificationError(
            f"stage {role}.{stage} is already running"
        ) from error
    try:
        yield
    finally:
        reservation.unlink(missing_ok=True)


def run_stage(args: argparse.Namespace) -> None:
    app = args.app.resolve()
    workspace = args.workspace.resolve()
    require_stage_workspace_location(workspace)
    require_owner_directory(workspace, "production-sync workspace")
    manifest_path = workspace / MANIFEST_NAME
    manifest = validate_manifest(load_json(manifest_path, "production-sync manifest"))
    require_owner_only(manifest_path, "production-sync manifest")
    app_info = inspect_qualification_app(app)
    if app_info["release"] != manifest["release"]:
        raise ProductionSyncQualificationError("qualification app release differs from manifest")
    if app_info["executableSHA256"] != manifest["executableSHA256"]:
        raise ProductionSyncQualificationError("qualification app executable differs from manifest")
    if app_info["codeResourcesSHA256"] != manifest["codeResourcesSHA256"]:
        raise ProductionSyncQualificationError(
            "qualification app code resources differ from manifest"
        )
    if app_info["provisioningProfileSHA256"] != manifest["provisioningProfileSHA256"]:
        raise ProductionSyncQualificationError(
            "qualification app provisioning profile differs from manifest"
        )
    if app_info["contractSHA256"] != manifest["contractSHA256"]:
        raise ProductionSyncQualificationError("qualification app contract differs from manifest")
    role = exact_string(args.role, "role", ROLE_PATTERN)
    stage = exact_string(args.stage, "stage", STAGE_PATTERN)
    descriptor = stage_catalog(app_info["contract"]).get(f"{role}.{stage}")
    if descriptor is None:
        raise ProductionSyncQualificationError("requested stage is not in the contract")
    validate_external_action(
        f"{role}.{stage}",
        descriptor,
        getattr(args, "confirm_external_action", None),
    )
    with reserve_stage(workspace, role, stage):
        run_admitted_stage(
            args,
            workspace=workspace,
            manifest_path=manifest_path,
            manifest=manifest,
            app_info=app_info,
            role=role,
            stage=stage,
            descriptor=descriptor,
        )


def run_admitted_stage(
    args: argparse.Namespace,
    *,
    workspace: Path,
    manifest_path: Path,
    manifest: dict[str, Any],
    app_info: dict[str, Any],
    role: str,
    stage: str,
    descriptor: dict[str, Any],
) -> None:
    shell_root = prepare_stage_directories(workspace, role)
    output = receipt_path(workspace, role, descriptor["roleSequence"], stage)
    if output.exists():
        raise ProductionSyncQualificationError("requested stage already has a receipt")
    validate_stage_prerequisites(
        workspace,
        descriptor=descriptor,
        manifest=manifest,
        contract=app_info["contract"],
    )
    live_requirement = descriptor.get("requiresLiveStage")
    if live_requirement is not None:
        validate_live_stage_marker(
            workspace,
            live_requirement,
            manifest=manifest,
            contract=app_info["contract"],
        )
    elif f"{role}.{stage}" == "b.await-push" and live_stage_marker_path(
        workspace, "b.await-push"
    ).exists():
        raise ProductionSyncQualificationError(
            "await-push cannot reuse an earlier live-stage marker"
        )
    default_timeout = (
        app_info["contract"]["limits"]["pushStageTimeoutSeconds"]
        if stage == "await-push"
        else app_info["contract"]["limits"]["defaultStageTimeoutSeconds"]
    )
    timeout = args.timeout if args.timeout is not None else default_timeout
    if timeout < 30 or timeout > 3600:
        raise ProductionSyncQualificationError("stage timeout must be between 30 and 3600 seconds")
    shell_database = shell_root / f"{uuid.uuid4()}.sqlite"
    environment = qualification_environment(shell_database)
    command = [
        str(app_info["executable"]),
        "-NSTreatUnknownArgumentsAsOpen",
        "NO",
        "-ApplePersistenceIgnoreState",
        "YES",
        "-use-temp-store",
        "--production-sync-qualification",
        "--production-sync-manifest",
        str(manifest_path),
        "--production-sync-workspace",
        str(workspace),
        "--production-sync-role",
        role,
        "--production-sync-stage",
        stage,
        "--production-sync-timeout-seconds",
        str(timeout),
    ]
    try:
        result = subprocess.run(
            command,
            env=environment,
            timeout=timeout + 15,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise ProductionSyncQualificationError(
            "qualification app exceeded the external stage timeout"
        ) from error
    finally:
        shell_database.unlink(missing_ok=True)
        Path(f"{shell_database}-shm").unlink(missing_ok=True)
        Path(f"{shell_database}-wal").unlink(missing_ok=True)
    if result.returncode != 0:
        raise ProductionSyncQualificationError(
            f"qualification app failed with status {result.returncode}"
        )
    if not output.exists():
        raise ProductionSyncQualificationError("qualification app wrote no stage receipt")
    require_owner_only(output, "stage receipt")
    receipt = validate_stage_receipt(
        load_json(
            output,
            "stage receipt",
            maximum_bytes=app_info["contract"]["limits"]["maximumReceiptBytes"],
        ),
        manifest=manifest,
        contract=app_info["contract"],
        label="stage receipt",
    )
    if receipt["role"] != role or receipt["stage"] != stage:
        raise ProductionSyncQualificationError("stage receipt differs from request")
    print(f"PASS {role}.{stage} -> {output}")


def collect_receipts(
    evidence_root: Path,
    *,
    manifest: dict[str, Any],
    contract: dict[str, Any],
) -> tuple[dict[str, dict[str, Any]], dict[str, str]]:
    receipts: dict[str, dict[str, Any]] = {}
    digests: dict[str, str] = {}
    catalog = stage_catalog(contract)
    for key, descriptor in catalog.items():
        role, stage = key.split(".", 1)
        path = receipt_path(evidence_root, role, descriptor["roleSequence"], stage)
        if not path.exists():
            raise ProductionSyncQualificationError(f"missing stage receipt {key}")
        require_owner_only(path, f"stage receipt {key}")
        receipt = validate_stage_receipt(
            load_json(
                path,
                f"stage receipt {key}",
                maximum_bytes=contract["limits"]["maximumReceiptBytes"],
            ),
            manifest=manifest,
            contract=contract,
            label=f"stage receipt {key}",
        )
        if receipt["role"] != role or receipt["stage"] != stage:
            raise ProductionSyncQualificationError(f"stage receipt {key} has wrong identity")
        receipts[key] = receipt
        digests[key] = sha256_file(path)
    receipt_files = {
        path.resolve()
        for path in (evidence_root / "receipts").glob("*/*.json")
        if path.is_file()
    }
    expected_files = {
        receipt_path(evidence_root, key.split(".", 1)[0], value["roleSequence"], key.split(".", 1)[1]).resolve()
        for key, value in catalog.items()
    }
    if receipt_files != expected_files:
        raise ProductionSyncQualificationError("evidence root has unexpected stage receipts")
    for role in contract["roles"]:
        role_items = sorted(
            (
                (receipt["roleSequence"], key, receipt)
                for key, receipt in receipts.items()
                if receipt["role"] == role
            ),
            key=lambda item: item[0],
        )
        predecessor: str | None = None
        for _, key, receipt in role_items:
            if receipt["predecessorSHA256"] != predecessor:
                raise ProductionSyncQualificationError(f"stage chain breaks at {key}")
            predecessor = digests[key]
    for key, descriptor in catalog.items():
        for requirement in descriptor["requires"]:
            if requirement not in receipts:
                raise ProductionSyncQualificationError(f"stage {key} lacks {requirement}")
    process_nonces = [receipt["processNonce"] for receipt in receipts.values()]
    if len(set(process_nonces)) != len(process_nonces):
        raise ProductionSyncQualificationError("each stage must run in a distinct app process")
    return receipts, digests


def validate_authority_relationships(receipts: dict[str, dict[str, Any]]) -> dict[str, str]:
    host_a = {receipt["hostScopeSHA256"] for receipt in receipts.values() if receipt["role"] == "a"}
    host_b = {receipt["hostScopeSHA256"] for receipt in receipts.values() if receipt["role"] == "b"}
    if len(host_a) != 1 or len(host_b) != 1:
        raise ProductionSyncQualificationError("each role must retain one Mac host scope")
    if host_a == host_b:
        raise ProductionSyncQualificationError(
            "production sync requires two distinct Mac host scopes"
        )
    role_os_majors: dict[str, int] = {}
    for role in ("a", "b"):
        operating_systems = {
            (
                receipt["os"]["major"],
                receipt["os"]["minor"],
                receipt["os"]["patch"],
                receipt["os"]["build"],
                receipt["os"]["architecture"],
            )
            for receipt in receipts.values()
            if receipt["role"] == role
        }
        if len(operating_systems) != 1:
            raise ProductionSyncQualificationError(
                f"role {role} changed operating system during qualification"
            )
        role_os_majors[role] = next(iter(operating_systems))[0]
    if 15 not in role_os_majors.values() or not any(
        major >= 26 for major in role_os_majors.values()
    ):
        raise ProductionSyncQualificationError(
            "production sync must pair Sequoia with Tahoe or newer"
        )
    original_keys = {
        key
        for key in receipts
        if key not in {
            "a.prepare-existing",
            "a.observe-account-switch",
            "a.enable-switched-account",
        }
    }
    original_accounts = {
        receipts[key]["accountScopeSHA256"]
        for key in original_keys
    }
    if None in original_accounts or len(original_accounts) != 1:
        raise ProductionSyncQualificationError("original iCloud account scope is inconsistent")
    switched_accounts = {
        receipts[key]["accountScopeSHA256"]
        for key in ("a.observe-account-switch", "a.enable-switched-account")
    }
    if None in switched_accounts or len(switched_accounts) != 1:
        raise ProductionSyncQualificationError("switched iCloud account scope is inconsistent")
    original = next(iter(original_accounts))
    switched = next(iter(switched_accounts))
    if original == switched:
        raise ProductionSyncQualificationError("account-switch stages did not use another account")
    return {
        "hostA": next(iter(host_a)),
        "hostB": next(iter(host_b)),
        "originalAccount": original,
        "switchedAccount": switched,
    }


def validate_live_stage_relationship(
    evidence_root: Path,
    *,
    manifest: dict[str, Any],
    contract: dict[str, Any],
    receipts: dict[str, dict[str, Any]],
) -> str:
    marker, digest = validate_live_stage_marker(
        evidence_root,
        "b.await-push",
        manifest=manifest,
        contract=contract,
    )
    source = receipts["a.push-source"]
    waiter = receipts["b.await-push"]
    if source["liveStageMarkerSHA256"] != digest:
        raise ProductionSyncQualificationError(
            "push-source did not consume the live await-push marker"
        )
    if waiter["liveStageMarkerSHA256"] != digest:
        raise ProductionSyncQualificationError(
            "await-push receipt differs from its live-stage marker"
        )
    if marker["processNonce"] != waiter["processNonce"]:
        raise ProductionSyncQualificationError(
            "await-push marker came from another app process"
        )
    if marker["hostScopeSHA256"] != waiter["hostScopeSHA256"]:
        raise ProductionSyncQualificationError(
            "await-push marker came from another host scope"
        )
    return digest


def validate_evidence_inventory(
    evidence_root: Path,
    *,
    contract: dict[str, Any],
) -> None:
    catalog = stage_catalog(contract)
    expected_files = {
        (evidence_root / MANIFEST_NAME).resolve(),
        live_stage_marker_path(evidence_root, "b.await-push").resolve(),
    }
    expected_files.update(
        receipt_path(
            evidence_root,
            key.split(".", 1)[0],
            descriptor["roleSequence"],
            key.split(".", 1)[1],
        ).resolve()
        for key, descriptor in catalog.items()
    )
    expected_entries = set(expected_files)
    for path in expected_files:
        parent = path.parent
        while parent != evidence_root:
            expected_entries.add(parent)
            parent = parent.parent
    entries = list(evidence_root.rglob("*"))
    if any(path.is_symlink() for path in entries):
        raise ProductionSyncQualificationError("evidence root contains a symbolic link")
    if any(not path.is_file() and not path.is_dir() for path in entries):
        raise ProductionSyncQualificationError("evidence root has an invalid entry type")
    actual_entries = {path.resolve() for path in entries}
    if actual_entries != expected_entries:
        raise ProductionSyncQualificationError("evidence root has unexpected files")


def qualification_receipt(
    release: dict[str, str],
    collected_at: str,
    authority_sha256: str,
) -> dict[str, Any]:
    receipt = {
        "schemaVersion": release_reliability.RECEIPT_SCHEMA_VERSION,
        "kind": "qualification",
        "scope": "production-sync",
        "authoritySHA256": release_reliability.safe_string(
            authority_sha256,
            "production sync authority digest",
            release_reliability.DIGEST_PATTERN,
        ),
        "collectedAt": collected_at,
        "release": release,
        "proofs": [{"id": "admission", "state": "pass"}],
    }
    try:
        release_reliability.validate_qualification_receipt(
            receipt,
            "production sync qualification receipt",
        )
    except release_reliability.ReliabilityError as error:
        raise ProductionSyncQualificationError(str(error)) from error
    return receipt


def finalize(args: argparse.Namespace) -> None:
    evidence_root = args.evidence_root.resolve()
    output = args.output.resolve()
    if output == evidence_root or output.is_relative_to(evidence_root):
        raise ProductionSyncQualificationError(
            "qualification output must be outside the evidence root"
        )
    require_owner_directory(evidence_root, "production-sync evidence root")
    manifest_path = evidence_root / MANIFEST_NAME
    manifest = validate_manifest(load_json(manifest_path, "production-sync manifest"))
    require_owner_only(manifest_path, "production-sync manifest")
    contract, contract_digest = load_contract()
    if manifest["contractSHA256"] != contract_digest:
        raise ProductionSyncQualificationError("manifest contract differs from tracked source")
    if manifest["corpus"]["sha256"] != contract["corpus"]["sha256"]:
        raise ProductionSyncQualificationError("manifest corpus differs from contract")
    require_exact_checkout(manifest["release"]["commit"])
    receipts, digests = collect_receipts(
        evidence_root,
        manifest=manifest,
        contract=contract,
    )
    scopes = validate_authority_relationships(receipts)
    live_marker_digest = validate_live_stage_relationship(
        evidence_root,
        manifest=manifest,
        contract=contract,
        receipts=receipts,
    )
    validate_evidence_inventory(evidence_root, contract=contract)
    collected_at = utc_now()
    authority = {
        "schemaVersion": AUTHORITY_SCHEMA_VERSION,
        "kind": "production-sync-authority",
        "collectedAt": collected_at,
        "release": manifest["release"],
        "runID": manifest["runID"],
        "contractSHA256": contract_digest,
        "executableSHA256": manifest["executableSHA256"],
        "codeResourcesSHA256": manifest["codeResourcesSHA256"],
        "provisioningProfileSHA256": manifest["provisioningProfileSHA256"],
        "corpusSHA256": manifest["corpus"]["sha256"],
        "liveStageMarkerSHA256": live_marker_digest,
        "hostScopes": [scopes["hostA"], scopes["hostB"]],
        "accountScopes": {
            "original": scopes["originalAccount"],
            "switched": scopes["switchedAccount"],
        },
        "stages": [
            {
                "role": stage["role"],
                "id": stage["id"],
                "receiptSHA256": digests[f"{stage['role']}.{stage['id']}"],
                "osMajor": receipts[f"{stage['role']}.{stage['id']}"]["os"]["major"],
            }
            for stage in contract["stages"]
        ],
    }
    receipt = qualification_receipt(
        manifest["release"],
        collected_at,
        release_reliability.canonical_document_sha256(authority),
    )
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock = output.parent / f".{output.name}.publish.lock"
    try:
        descriptor = os.open(
            lock,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        os.close(descriptor)
    except FileExistsError as error:
        raise ProductionSyncQualificationError(
            "qualification publication is already in progress"
        ) from error
    staging = output.parent / f".{output.name}.{uuid.uuid4()}"
    try:
        if output.exists():
            raise ProductionSyncQualificationError(
                "qualification output must be absent"
            )
        staging.mkdir(mode=0o700)
        atomic_write_json(staging / "authority.json", authority)
        atomic_write_json(staging / "qualification.json", receipt)
        if output.exists():
            raise ProductionSyncQualificationError(
                "qualification output must be absent"
            )
        os.replace(staging, output)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    finally:
        lock.unlink(missing_ok=True)
    print(f"PASS production-sync admission -> {output / 'qualification.json'}")


def status(args: argparse.Namespace) -> None:
    evidence_root = args.evidence_root.resolve()
    require_owner_directory(evidence_root, "production-sync evidence root")
    manifest_path = evidence_root / MANIFEST_NAME
    manifest = validate_manifest(load_json(manifest_path, "production-sync manifest"))
    require_owner_only(manifest_path, "production-sync manifest")
    contract, digest = load_contract()
    if manifest["contractSHA256"] != digest:
        raise ProductionSyncQualificationError("manifest contract differs from tracked source")
    invalid: list[str] = []
    for stage in contract["stages"]:
        path = receipt_path(
            evidence_root,
            stage["role"],
            stage["roleSequence"],
            stage["id"],
        )
        marker = "MISSING"
        if path.exists():
            key = f"{stage['role']}.{stage['id']}"
            try:
                require_owner_only(path, f"stage receipt {key}")
                receipt = validate_stage_receipt(
                    load_json(
                        path,
                        f"stage receipt {key}",
                        maximum_bytes=contract["limits"]["maximumReceiptBytes"],
                    ),
                    manifest=manifest,
                    contract=contract,
                    label=f"stage receipt {key}",
                )
                if (
                    receipt["role"] != stage["role"]
                    or receipt["stage"] != stage["id"]
                ):
                    raise ProductionSyncQualificationError(
                        f"stage receipt {key} has wrong identity"
                    )
                marker = "PASS"
            except ProductionSyncQualificationError:
                marker = "INVALID"
                invalid.append(key)
        print(f"{marker:7} {stage['role']}.{stage['id']}")
    if invalid:
        raise ProductionSyncQualificationError(
            "invalid stage receipts: " + ", ".join(invalid)
        )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    initialize_parser = subparsers.add_parser("init", help="create one exact run manifest")
    initialize_parser.add_argument("--app", type=Path, required=True)
    initialize_parser.add_argument("--workspace", type=Path, required=True)
    initialize_parser.add_argument("--version", required=True)
    initialize_parser.add_argument("--build", required=True)
    initialize_parser.add_argument("--commit", required=True)
    initialize_parser.set_defaults(handler=initialize)

    stage_parser = subparsers.add_parser("stage", help="run one real-app stage")
    stage_parser.add_argument("--app", type=Path, required=True)
    stage_parser.add_argument("--workspace", type=Path, required=True)
    stage_parser.add_argument("--role", required=True)
    stage_parser.add_argument("--stage", required=True)
    stage_parser.add_argument("--timeout", type=int)
    stage_parser.add_argument("--confirm-external-action")
    stage_parser.set_defaults(handler=run_stage)

    status_parser = subparsers.add_parser("status", help="show the finite stage inventory")
    status_parser.add_argument("--evidence-root", type=Path, required=True)
    status_parser.set_defaults(handler=status)

    finalize_parser = subparsers.add_parser("finalize", help="mint admission from complete evidence")
    finalize_parser.add_argument("--evidence-root", type=Path, required=True)
    finalize_parser.add_argument("--output", type=Path, required=True)
    finalize_parser.set_defaults(handler=finalize)
    return result


def main(argv: list[str] | None = None) -> int:
    try:
        arguments = parser().parse_args(argv)
        arguments.handler(arguments)
        return 0
    except (
        ProductionSyncQualificationError,
        OSError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"production-sync qualification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
