#!/usr/bin/env python3
"""Own the fixed physical VoiceOver and Voice Control qualification matrix."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import ctypes
import hashlib
import json
import os
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

import release_reliability


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = (
    ROOT / "docs" / "evidence" / "assistive-technology-qualification.json"
)
CONTRACT_SCHEMA_VERSION = 1
RUN_SCHEMA_VERSION = 1
CELL_SCHEMA_VERSION = 1
SESSION_SCHEMA_VERSION = 1
OBSERVATION_SCHEMA_VERSION = 1
COMPLETION_SCHEMA_VERSION = 1
AUTHORITY_SCHEMA_VERSION = 1
RUN_NAME = "run.json"
QUALIFICATION_BUNDLE_ID = "app.portavoz.mac.dev"
QUALIFICATION_DISPLAY_NAME = "Portavoz Dev"
FORBIDDEN_RELEASE_APP = Path("/Applications/Portavoz.app")
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
UUID_PATTERN = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
CODE_PATTERN = re.compile(r"^[a-z][a-z0-9-]{0,63}$")
LOCALE_PATTERN = re.compile(r"^[a-z]{2}$")
OS_BUILD_PATTERN = re.compile(r"^[0-9]{2}[A-Z][0-9A-Za-z]{1,15}$")
TEAM_PATTERN = re.compile(r"^[A-Z0-9]{4,20}$")
SELECTOR_PATTERN = re.compile(
    r"^PortavozUITests/[A-Za-z][A-Za-z0-9]+UITests/test[A-Za-z0-9]+$"
)
EXPECTED_PLATFORMS = (
    ("sequoia", 15, 15),
    ("tahoe", 26, None),
)
EXPECTED_TECHNOLOGIES = (
    (
        "voiceover",
        "nsworkspace-and-human",
        {
            "sequoia": "voiceover-sequoia",
            "tahoe": "voiceover-tahoe",
        },
    ),
    (
        "voice-control",
        "human-observed",
        {
            "sequoia": "voice-control-sequoia",
            "tahoe": "voice-control-tahoe",
        },
    ),
)
EXPECTED_CHECKPOINTS = (
    (
        "library-navigation",
        (
            "PortavozUITests/LibraryUITests/testLibraryRendersRecordButtonAndActionChips",
            "PortavozUITests/LibraryUITests/testSeededMeetingsGroupByRecency",
        ),
    ),
    (
        "meeting-evidence-navigation",
        (
            "PortavozUITests/MeetingDetailUITests/testSummarySourceJumpsToItsTranscriptAndAudio",
            "PortavozUITests/MeetingDetailUITests/testMyNotesSectionShowsRawNotesAndOffersEnhancement",
        ),
    ),
    (
        "ask-citation-navigation",
        (
            "PortavozUITests/LibraryUITests/testAskConversationAnswersAndSeeksToExactCitation",
        ),
    ),
    (
        "skills-review-and-focus",
        (
            "PortavozUITests/SkillsSettingsUITests/testSameSkillProposalsHaveDistinctAccessibleActions",
            "PortavozUITests/SkillsSettingsUITests/testSkillReceiptRestoresKeyboardFocusAndPassesAccessibilityAudit",
        ),
    ),
    (
        "interview-assist-navigation",
        (
            "PortavozUITests/InterviewAssistUITests/testInterviewAssistGroundsTheCurrentQuestionInExactEvidence",
        ),
    ),
    (
        "recording-stop-recovery",
        (
            "PortavozUITests/AutomationUITests/testRecordingAutomationRoutesStartAndStopThroughVisibleApp",
        ),
    ),
)
FORBIDDEN_CONTENT_KEYS = {
    "answer",
    "audio",
    "content",
    "meeting",
    "meetingTitle",
    "note",
    "operator",
    "path",
    "prompt",
    "question",
    "screenRecording",
    "screenshot",
    "speaker",
    "text",
    "transcript",
    "url",
}


class AssistiveQualificationError(ValueError):
    """A fail-closed assistive-technology qualification error."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def canonical_json(document: Any) -> bytes:
    try:
        return json.dumps(
            document,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise AssistiveQualificationError("document is not canonical JSON") from error


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def exact_object(
    value: Any,
    label: str,
    required: Iterable[str],
    optional: Iterable[str] = (),
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AssistiveQualificationError(f"{label} must be an object")
    required_keys = set(required)
    allowed = required_keys | set(optional)
    missing = required_keys - value.keys()
    extra = value.keys() - allowed
    if missing or extra:
        raise AssistiveQualificationError(
            f"{label} has an invalid shape "
            f"(missing={sorted(missing)}, extra={sorted(extra)})"
        )
    return value


def exact_string(
    value: Any,
    label: str,
    pattern: re.Pattern[str] | None = None,
    *,
    maximum: int = 240,
) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise AssistiveQualificationError(
            f"{label} must be a nonempty string of at most {maximum} characters"
        )
    if any(ord(character) < 0x20 for character in value):
        raise AssistiveQualificationError(f"{label} contains control characters")
    if pattern is not None and pattern.fullmatch(value) is None:
        raise AssistiveQualificationError(f"{label} has an invalid format")
    return value


def exact_integer(value: Any, label: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise AssistiveQualificationError(
            f"{label} must be an integer >= {minimum}"
        )
    return value


def exact_boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise AssistiveQualificationError(f"{label} must be a boolean")
    return value


def exact_digest(value: Any, label: str) -> str:
    return exact_string(value, label, DIGEST_PATTERN)


def exact_uuid(value: Any, label: str) -> str:
    return exact_string(value, label, UUID_PATTERN)


def validate_timestamp(value: Any, label: str) -> str:
    text = exact_string(value, label, maximum=64)
    if not text.endswith("Z"):
        raise AssistiveQualificationError(f"{label} must be UTC")
    try:
        parsed = datetime.fromisoformat(text[:-1] + "+00:00")
    except ValueError as error:
        raise AssistiveQualificationError(f"{label} is invalid") from error
    if parsed.tzinfo != timezone.utc:
        raise AssistiveQualificationError(f"{label} must be UTC")
    return text


def load_json(
    path: Path,
    label: str,
    *,
    maximum_bytes: int = 1024 * 1024,
) -> Any:
    if path.is_symlink() or not path.is_file():
        raise AssistiveQualificationError(f"{label} must be a regular file")
    size = path.stat().st_size
    if size <= 0 or size > maximum_bytes:
        raise AssistiveQualificationError(f"{label} has an invalid size")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise AssistiveQualificationError(f"{label} is not valid JSON") from error


def require_owner_file(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise AssistiveQualificationError(f"{label} must be a regular file")
    if stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise AssistiveQualificationError(f"{label} must have mode 0600")


def require_owner_directory(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_dir():
        raise AssistiveQualificationError(f"{label} must be a directory")
    if stat.S_IMODE(path.stat().st_mode) != 0o700:
        raise AssistiveQualificationError(f"{label} must have mode 0700")


def require_evidence_location(path: Path) -> None:
    resolved = path.resolve()
    allowed_roots = (Path.home().resolve(), Path(tempfile.gettempdir()).resolve())
    if not any(
        resolved != root and resolved.is_relative_to(root) for root in allowed_roots
    ):
        raise AssistiveQualificationError(
            "assistive evidence must be below home or the temporary directory"
        )


def normalized_local_path(path: Path) -> Path:
    """Return an absolute path without dereferencing a caller-supplied symlink."""
    return Path(os.path.abspath(os.fspath(path.expanduser())))


def prepare_owner_directory(path: Path, label: str) -> Path:
    if path.is_symlink():
        raise AssistiveQualificationError(f"{label} must not be a symbolic link")
    if path.exists():
        require_owner_directory(path, label)
    else:
        path.mkdir(mode=0o700)
        require_owner_directory(path, label)
    return path


def prepare_owner_subdirectory(parent: Path, name: str) -> Path:
    require_owner_directory(parent, "assistive evidence parent")
    return prepare_owner_directory(parent / name, f"assistive directory {name}")


def atomic_write_json(path: Path, document: Any) -> None:
    require_owner_directory(path.parent, f"parent of {path.name}")
    data = json.dumps(
        document,
        allow_nan=False,
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
        try:
            os.link(temporary_path, path, follow_symlinks=False)
        except FileExistsError as error:
            raise AssistiveQualificationError(f"{path.name} already exists") from error
        temporary_path.unlink()
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        temporary_path.unlink(missing_ok=True)
        raise


@contextmanager
def exclusive_reservation(parent: Path, name: str):
    require_owner_directory(parent, "reservation parent")
    reservation = parent / f".{name}.lock"
    try:
        descriptor = os.open(
            reservation,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
        )
        os.close(descriptor)
    except FileExistsError as error:
        raise AssistiveQualificationError(
            f"assistive operation {name} is already in progress"
        ) from error
    try:
        yield
    finally:
        reservation.unlink(missing_ok=True)


def validate_no_content_keys(value: Any, label: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key in FORBIDDEN_CONTENT_KEYS:
                raise AssistiveQualificationError(
                    f"{label} contains forbidden content key {key}"
                )
            validate_no_content_keys(child, label)
    elif isinstance(value, list):
        for child in value:
            validate_no_content_keys(child, label)


def release_identity(value: Any, label: str = "release") -> dict[str, str]:
    root = exact_object(value, label, ("version", "build", "commit"))
    try:
        return {
            "version": release_reliability.safe_string(
                root["version"],
                f"{label}.version",
                release_reliability.VERSION_PATTERN,
            ),
            "build": release_reliability.safe_string(
                root["build"],
                f"{label}.build",
                release_reliability.BUILD_PATTERN,
            ),
            "commit": release_reliability.safe_string(
                root["commit"],
                f"{label}.commit",
                release_reliability.COMMIT_PATTERN,
            ),
        }
    except release_reliability.ReliabilityError as error:
        raise AssistiveQualificationError(str(error)) from error


def validate_app_identity(value: Any, label: str = "app") -> dict[str, str]:
    root = exact_object(
        value,
        label,
        (
            "bundleIdentifier",
            "executableSHA256",
            "infoPlistSHA256",
            "codeResourcesSHA256",
            "signingKind",
            "signingTeamScopeSHA256",
        ),
    )
    if root["bundleIdentifier"] != QUALIFICATION_BUNDLE_ID:
        raise AssistiveQualificationError(f"{label}.bundleIdentifier is invalid")
    for key in (
        "executableSHA256",
        "infoPlistSHA256",
        "codeResourcesSHA256",
        "signingTeamScopeSHA256",
    ):
        exact_digest(root[key], f"{label}.{key}")
    if root["signingKind"] != "developer-id":
        raise AssistiveQualificationError(f"{label}.signingKind is invalid")
    return root


def validate_os(value: Any, label: str = "os") -> dict[str, Any]:
    root = exact_object(
        value,
        label,
        ("major", "minor", "patch", "build", "architecture"),
    )
    for key in ("major", "minor", "patch"):
        exact_integer(root[key], f"{label}.{key}")
    exact_string(root["build"], f"{label}.build", OS_BUILD_PATTERN)
    if root["architecture"] != "arm64":
        raise AssistiveQualificationError(
            f"{label}.architecture must be arm64 for Portavoz 1.0"
        )
    return root


def validate_contract(document: Any) -> dict[str, Any]:
    root = exact_object(
        document,
        "assistive contract",
        (
            "schemaVersion",
            "kind",
            "scope",
            "candidateScope",
            "app",
            "platforms",
            "technologies",
            "locales",
            "launch",
            "checkpoints",
            "limits",
        ),
    )
    if exact_integer(root["schemaVersion"], "contract.schemaVersion") != 1:
        raise AssistiveQualificationError("contract.schemaVersion must be 1")
    if root["kind"] != "assistive-technology-qualification-contract":
        raise AssistiveQualificationError("contract.kind is invalid")
    if root["scope"] != "assistive-technology":
        raise AssistiveQualificationError("contract.scope is invalid")
    if root["candidateScope"] != "candidate-automation":
        raise AssistiveQualificationError("contract.candidateScope is invalid")

    app = exact_object(
        root["app"],
        "contract.app",
        (
            "bundleIdentifier",
            "displayName",
            "forbiddenPath",
            "requireDeveloperID",
        ),
    )
    if app != {
        "bundleIdentifier": QUALIFICATION_BUNDLE_ID,
        "displayName": QUALIFICATION_DISPLAY_NAME,
        "forbiddenPath": str(FORBIDDEN_RELEASE_APP),
        "requireDeveloperID": True,
    }:
        raise AssistiveQualificationError("contract.app is not the Dev qualification app")

    platforms = root["platforms"]
    if not isinstance(platforms, list) or len(platforms) != 2:
        raise AssistiveQualificationError("contract.platforms must contain two rows")
    observed_platforms = []
    for index, raw in enumerate(platforms):
        platform = exact_object(
            raw,
            f"contract.platforms[{index}]",
            ("id", "minimumMajor", "maximumMajor"),
        )
        identifier = exact_string(
            platform["id"], f"contract.platforms[{index}].id", CODE_PATTERN
        )
        minimum = exact_integer(
            platform["minimumMajor"],
            f"contract.platforms[{index}].minimumMajor",
            minimum=1,
        )
        maximum = platform["maximumMajor"]
        if maximum is not None:
            maximum = exact_integer(
                maximum,
                f"contract.platforms[{index}].maximumMajor",
                minimum=minimum,
            )
        observed_platforms.append((identifier, minimum, maximum))
    if tuple(observed_platforms) != EXPECTED_PLATFORMS:
        raise AssistiveQualificationError("contract platform matrix is invalid")

    technologies = root["technologies"]
    if not isinstance(technologies, list) or len(technologies) != 2:
        raise AssistiveQualificationError(
            "contract.technologies must contain VoiceOver and Voice Control"
        )
    expected_proofs = set(
        release_reliability.QUALIFICATION_RECEIPTS["assistive-technology"][
            "proofs"
        ]
    )
    observed_proofs: set[str] = set()
    observed_technologies = []
    for index, raw in enumerate(technologies):
        technology = exact_object(
            raw,
            f"contract.technologies[{index}]",
            ("id", "activationAuthority", "proofs"),
        )
        identifier = exact_string(
            technology["id"],
            f"contract.technologies[{index}].id",
            CODE_PATTERN,
        )
        authority = exact_string(
            technology["activationAuthority"],
            f"contract.technologies[{index}].activationAuthority",
            CODE_PATTERN,
        )
        proofs = exact_object(
            technology["proofs"],
            f"contract.technologies[{index}].proofs",
            ("sequoia", "tahoe"),
        )
        normalized_proofs = {}
        for platform_identifier, proof in proofs.items():
            normalized_proofs[platform_identifier] = exact_string(
                proof, "contract assistive proof", CODE_PATTERN
            )
            observed_proofs.add(normalized_proofs[platform_identifier])
        observed_technologies.append((identifier, authority, normalized_proofs))
    if tuple(observed_technologies) != EXPECTED_TECHNOLOGIES:
        raise AssistiveQualificationError("contract technology matrix is invalid")
    if observed_proofs != expected_proofs:
        raise AssistiveQualificationError(
            "contract assistive proofs differ from the release ledger"
        )

    locales = root["locales"]
    if not isinstance(locales, list) or len(locales) != 2:
        raise AssistiveQualificationError("contract.locales must be bilingual")
    locale_pairs = []
    for index, raw in enumerate(locales):
        locale = exact_object(
            raw,
            f"contract.locales[{index}]",
            ("id", "appleLocale"),
        )
        locale_pairs.append((locale["id"], locale["appleLocale"]))
    if locale_pairs != [("en", "en_US"), ("es", "es_ES")]:
        raise AssistiveQualificationError("contract locales must be ordered EN then ES")

    launch = exact_object(
        root["launch"],
        "contract.launch",
        ("arguments", "environmentKeys"),
    )
    expected_arguments = [
        "-NSTreatUnknownArgumentsAsOpen",
        "NO",
        "-ApplePersistenceIgnoreState",
        "YES",
        "-use-temp-store",
        "-reset-app-language",
        "-seed-demo",
        "-seed-duplicate-skill-proposals",
        "-seed-skill-waiting",
        "-simulate-interview-assist",
    ]
    if launch["arguments"] != expected_arguments:
        raise AssistiveQualificationError("contract launch arguments are not frozen")
    expected_environment = [
        "PORTAVOZ_AUDIO_ROOT",
        "PORTAVOZ_UI_TEST_DATABASE_PATH",
        "PORTAVOZ_UI_TEST_DEFAULTS",
        "PORTAVOZ_UI_TEST_SEED_READY_PATH",
        "TMPDIR",
    ]
    if launch["environmentKeys"] != expected_environment:
        raise AssistiveQualificationError("contract launch environment is not frozen")

    checkpoints = root["checkpoints"]
    if not isinstance(checkpoints, list) or len(checkpoints) < 1:
        raise AssistiveQualificationError("contract.checkpoints must be nonempty")
    sequences: list[int] = []
    identifiers: set[str] = set()
    selectors: set[str] = set()
    for index, raw in enumerate(checkpoints):
        checkpoint = exact_object(
            raw,
            f"contract.checkpoints[{index}]",
            ("id", "sequence", "automationSelectors"),
        )
        identifier = exact_string(
            checkpoint["id"], f"contract.checkpoints[{index}].id", CODE_PATTERN
        )
        if identifier in identifiers:
            raise AssistiveQualificationError("contract repeats a checkpoint")
        identifiers.add(identifier)
        sequences.append(
            exact_integer(
                checkpoint["sequence"],
                f"contract.checkpoints[{index}].sequence",
                minimum=1,
            )
        )
        raw_selectors = checkpoint["automationSelectors"]
        if not isinstance(raw_selectors, list) or not raw_selectors:
            raise AssistiveQualificationError(
                f"contract checkpoint {identifier} lacks automation evidence"
            )
        for selector in raw_selectors:
            selector = exact_string(
                selector,
                f"contract checkpoint {identifier} selector",
                SELECTOR_PATTERN,
            )
            if selector in selectors:
                raise AssistiveQualificationError(
                    f"contract repeats automation selector {selector}"
                )
            selectors.add(selector)
    if sequences != list(range(1, len(checkpoints) + 1)):
        raise AssistiveQualificationError(
            "contract checkpoint sequence must be contiguous and ordered"
        )
    observed_checkpoints = tuple(
        (checkpoint["id"], tuple(checkpoint["automationSelectors"]))
        for checkpoint in checkpoints
    )
    if observed_checkpoints != EXPECTED_CHECKPOINTS:
        raise AssistiveQualificationError(
            "contract checkpoints differ from the fixed assistive journey"
        )

    limits = exact_object(
        root["limits"],
        "contract.limits",
        (
            "seedReadyTimeoutSeconds",
            "processExitTimeoutSeconds",
            "maximumReceiptBytes",
        ),
    )
    seed_timeout = exact_integer(
        limits["seedReadyTimeoutSeconds"],
        "contract.limits.seedReadyTimeoutSeconds",
        minimum=15,
    )
    exit_timeout = exact_integer(
        limits["processExitTimeoutSeconds"],
        "contract.limits.processExitTimeoutSeconds",
        minimum=5,
    )
    maximum_bytes = exact_integer(
        limits["maximumReceiptBytes"],
        "contract.limits.maximumReceiptBytes",
        minimum=4096,
    )
    if seed_timeout > 300 or exit_timeout > 60 or maximum_bytes > 256 * 1024:
        raise AssistiveQualificationError("contract limits are not bounded")
    return root


def load_contract(path: Path = DEFAULT_CONTRACT) -> tuple[dict[str, Any], str]:
    document = load_json(path, "assistive contract")
    contract = validate_contract(document)
    return contract, sha256_bytes(canonical_json(document))


def platform_catalog(contract: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["id"]: item for item in contract["platforms"]}


def technology_catalog(contract: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["id"]: item for item in contract["technologies"]}


def locale_catalog(contract: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["id"]: item for item in contract["locales"]}


def checkpoint_catalog(contract: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["id"]: item for item in contract["checkpoints"]}


def platform_for_major(contract: dict[str, Any], major: int) -> str:
    matches = []
    for identifier, descriptor in platform_catalog(contract).items():
        maximum = descriptor["maximumMajor"]
        if major >= descriptor["minimumMajor"] and (
            maximum is None or major <= maximum
        ):
            matches.append(identifier)
    if len(matches) != 1:
        raise AssistiveQualificationError(
            "host must run physical macOS Sequoia or Tahoe-or-newer"
        )
    return matches[0]


def proof_for(
    contract: dict[str, Any], technology: str, platform_identifier: str
) -> str:
    descriptor = technology_catalog(contract).get(technology)
    if descriptor is None:
        raise AssistiveQualificationError("technology is not in the contract")
    return descriptor["proofs"][platform_identifier]


def validate_candidate_receipt(path: Path) -> tuple[dict[str, Any], dict[str, str]]:
    require_owner_file(path, "candidate qualification receipt")
    document = load_json(path, "candidate qualification receipt")
    try:
        receipt, release, scope, proofs = (
            release_reliability.validate_qualification_receipt(
                document, "candidate qualification receipt"
            )
        )
    except release_reliability.ReliabilityError as error:
        raise AssistiveQualificationError(str(error)) from error
    if scope != "candidate-automation":
        raise AssistiveQualificationError(
            "assistive qualification requires candidate-automation evidence"
        )
    if any(state != "pass" for state in proofs.values()):
        raise AssistiveQualificationError(
            "candidate qualification receipt must pass every proof"
        )
    return receipt, release_identity(release, "candidate release")


def require_exact_checkout(commit: str) -> None:
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    ).stdout.strip()
    if head != commit:
        raise AssistiveQualificationError("checked-out Git commit differs")
    status_output = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    ).stdout
    if status_output:
        raise AssistiveQualificationError(
            "assistive qualification requires a clean exact checkout"
        )


def inspect_candidate_app(
    app: Path,
    run_nonce: str,
    *,
    runner=subprocess.run,
) -> dict[str, Any]:
    if not app.is_absolute() or app.is_symlink():
        raise AssistiveQualificationError("candidate app must be an absolute real path")
    resolved = app.resolve()
    if resolved == FORBIDDEN_RELEASE_APP.resolve():
        raise AssistiveQualificationError(
            "assistive qualification must never inspect /Applications/Portavoz.app"
        )
    if not resolved.is_dir() or resolved.suffix != ".app":
        raise AssistiveQualificationError("candidate app must be an app bundle")
    info_path = resolved / "Contents" / "Info.plist"
    code_resources = resolved / "Contents" / "_CodeSignature" / "CodeResources"
    for path, label in (
        (info_path, "candidate Info.plist"),
        (code_resources, "candidate CodeResources"),
    ):
        if path.is_symlink() or not path.is_file():
            raise AssistiveQualificationError(f"{label} is invalid")
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise AssistiveQualificationError("candidate Info.plist is invalid") from error
    expected_info = {
        "CFBundleIdentifier": QUALIFICATION_BUNDLE_ID,
        "CFBundleDisplayName": QUALIFICATION_DISPLAY_NAME,
        "CFBundleName": QUALIFICATION_DISPLAY_NAME,
    }
    for key, expected in expected_info.items():
        if info.get(key) != expected:
            raise AssistiveQualificationError(f"candidate app has invalid {key}")
    release = release_identity(
        {
            "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"),
            "commit": info.get("PortavozSourceCommit"),
        },
        "candidate app release",
    )
    executable_name = exact_string(
        info.get("CFBundleExecutable"), "candidate CFBundleExecutable"
    )
    executable = resolved / "Contents" / "MacOS" / executable_name
    if executable.is_symlink() or not executable.is_file():
        raise AssistiveQualificationError("candidate executable is invalid")

    runner(
        ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(resolved)],
        check=True,
        capture_output=True,
        text=True,
        timeout=120,
    )
    details = runner(
        ["codesign", "-dvvv", "--verbose=4", str(resolved)],
        check=True,
        capture_output=True,
        text=True,
        timeout=120,
    )
    signature_text = f"{details.stdout}\n{details.stderr}"
    authorities = [
        line.partition("=")[2]
        for line in signature_text.splitlines()
        if line.startswith("Authority=")
    ]
    if not any(value.startswith("Developer ID Application:") for value in authorities):
        raise AssistiveQualificationError(
            "candidate app must carry a real Developer ID Application signature"
        )
    team_lines = [
        line.partition("=")[2]
        for line in signature_text.splitlines()
        if line.startswith("TeamIdentifier=")
    ]
    if len(team_lines) != 1 or TEAM_PATTERN.fullmatch(team_lines[0]) is None:
        raise AssistiveQualificationError("candidate signing team is unavailable")
    team_scope = sha256_bytes(f"{run_nonce}:{team_lines[0]}".encode("utf-8"))
    app_identity = {
        "bundleIdentifier": QUALIFICATION_BUNDLE_ID,
        "executableSHA256": sha256_file(executable),
        "infoPlistSHA256": sha256_file(info_path),
        "codeResourcesSHA256": sha256_file(code_resources),
        "signingKind": "developer-id",
        "signingTeamScopeSHA256": team_scope,
    }
    validate_app_identity(app_identity, "candidate app")
    return {
        "path": resolved,
        "executable": executable,
        "release": release,
        "identity": app_identity,
    }


def _command_text(arguments: list[str], label: str) -> str:
    result = subprocess.run(
        arguments,
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        timeout=15,
    )
    return exact_string(result.stdout.strip(), label, maximum=512)


def current_system_observation(run_nonce: str) -> dict[str, Any]:
    product_version = _command_text(
        ["/usr/bin/sw_vers", "-productVersion"], "macOS product version"
    )
    parts = product_version.split(".")
    if not 2 <= len(parts) <= 3 or any(not part.isdigit() for part in parts):
        raise AssistiveQualificationError("macOS product version is invalid")
    major, minor = int(parts[0]), int(parts[1])
    patch = int(parts[2]) if len(parts) == 3 else 0
    build = _command_text(
        ["/usr/bin/sw_vers", "-buildVersion"], "macOS build version"
    )
    exact_string(build, "macOS build version", OS_BUILD_PATTERN)
    architecture = _command_text(["/usr/bin/uname", "-m"], "host architecture")
    if architecture != "arm64":
        raise AssistiveQualificationError(
            "assistive qualification requires Apple Silicon"
        )
    ioreg_result = subprocess.run(
        ["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"],
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        timeout=15,
    )
    ioreg = ioreg_result.stdout
    if not ioreg or len(ioreg.encode("utf-8")) > 64 * 1024:
        raise AssistiveQualificationError("platform registry output is invalid")
    match = re.search(r'"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f-]{36})"', ioreg)
    if match is None:
        raise AssistiveQualificationError("Mac host scope is unavailable")
    try:
        platform_uuid = str(uuid.UUID(match.group(1))).lower()
    except ValueError as error:
        raise AssistiveQualificationError("Mac host scope is invalid") from error
    observation = {
        "hostScopeSHA256": sha256_bytes(
            f"{run_nonce}:{platform_uuid}".encode("utf-8")
        ),
        "os": {
            "major": major,
            "minor": minor,
            "patch": patch,
            "build": build,
            "architecture": architecture,
        },
    }
    exact_digest(observation["hostScopeSHA256"], "host scope")
    validate_os(observation["os"])
    return observation


def voiceover_enabled(*, runner=subprocess.run) -> bool:
    script = (
        'ObjC.import("AppKit"); '
        '$.NSWorkspace.sharedWorkspace.isVoiceOverEnabled ? "enabled" : "disabled"'
    )
    result = runner(
        ["/usr/bin/osascript", "-l", "JavaScript", "-e", script],
        check=True,
        capture_output=True,
        text=True,
        timeout=15,
    )
    state = result.stdout.strip()
    if state not in {"enabled", "disabled"}:
        raise AssistiveQualificationError("VoiceOver state probe returned invalid output")
    return state == "enabled"


def require_technology_active(
    technology: str,
    confirmation: str | None,
    *,
    voiceover_probe=voiceover_enabled,
) -> dict[str, Any]:
    if confirmation != technology:
        raise AssistiveQualificationError(
            f"{technology} requires --confirm-technology-active {technology}"
        )
    if technology == "voiceover":
        if not voiceover_probe():
            raise AssistiveQualificationError(
                "NSWorkspace reports that VoiceOver is not running"
            )
        return {
            "authority": "nsworkspace-and-human",
            "systemObserved": True,
        }
    if technology == "voice-control":
        return {
            "authority": "human-observed",
            "systemObserved": None,
        }
    raise AssistiveQualificationError("technology is not in the contract")


def validate_activation(value: Any, technology: str, label: str) -> dict[str, Any]:
    root = exact_object(value, label, ("authority", "systemObserved"))
    if technology == "voiceover":
        if root != {
            "authority": "nsworkspace-and-human",
            "systemObserved": True,
        }:
            raise AssistiveQualificationError(f"{label} is invalid for VoiceOver")
    elif technology == "voice-control":
        if root != {
            "authority": "human-observed",
            "systemObserved": None,
        }:
            raise AssistiveQualificationError(
                f"{label} is invalid for Voice Control"
            )
    else:
        raise AssistiveQualificationError(f"{label} names an unknown technology")
    return root


def validate_run_manifest(document: Any) -> dict[str, Any]:
    root = exact_object(
        document,
        "assistive run",
        (
            "schemaVersion",
            "kind",
            "runID",
            "createdAt",
            "release",
            "contractSHA256",
            "candidateReceiptSHA256",
            "app",
            "runNonce",
        ),
    )
    if exact_integer(root["schemaVersion"], "run.schemaVersion") != RUN_SCHEMA_VERSION:
        raise AssistiveQualificationError("run.schemaVersion is invalid")
    if root["kind"] != "assistive-technology-qualification-run":
        raise AssistiveQualificationError("run.kind is invalid")
    exact_uuid(root["runID"], "run.runID")
    validate_timestamp(root["createdAt"], "run.createdAt")
    root["release"] = release_identity(root["release"], "run.release")
    exact_digest(root["contractSHA256"], "run.contractSHA256")
    exact_digest(root["candidateReceiptSHA256"], "run.candidateReceiptSHA256")
    root["app"] = validate_app_identity(root["app"], "run.app")
    exact_digest(root["runNonce"], "run.runNonce")
    validate_no_content_keys(root, "assistive run")
    return root


def validate_cell_manifest(
    document: Any,
    *,
    manifest: dict[str, Any],
    contract: dict[str, Any],
    label: str = "assistive cell",
) -> dict[str, Any]:
    root = exact_object(
        document,
        label,
        (
            "schemaVersion",
            "kind",
            "createdAt",
            "runID",
            "proof",
            "technology",
            "platform",
            "release",
            "contractSHA256",
            "candidateReceiptSHA256",
            "app",
            "cellNonce",
            "hostScopeSHA256",
            "os",
        ),
    )
    if exact_integer(root["schemaVersion"], f"{label}.schemaVersion") != 1:
        raise AssistiveQualificationError(f"{label}.schemaVersion is invalid")
    if root["kind"] != "assistive-technology-cell":
        raise AssistiveQualificationError(f"{label}.kind is invalid")
    validate_timestamp(root["createdAt"], f"{label}.createdAt")
    if root["runID"] != manifest["runID"]:
        raise AssistiveQualificationError(f"{label}.runID differs")
    technology = exact_string(
        root["technology"], f"{label}.technology", CODE_PATTERN
    )
    platform_identifier = exact_string(
        root["platform"], f"{label}.platform", CODE_PATTERN
    )
    expected_proof = proof_for(contract, technology, platform_identifier)
    if root["proof"] != expected_proof:
        raise AssistiveQualificationError(f"{label}.proof differs")
    if release_identity(root["release"], f"{label}.release") != manifest["release"]:
        raise AssistiveQualificationError(f"{label}.release differs")
    if root["contractSHA256"] != manifest["contractSHA256"]:
        raise AssistiveQualificationError(f"{label}.contractSHA256 differs")
    if root["candidateReceiptSHA256"] != manifest["candidateReceiptSHA256"]:
        raise AssistiveQualificationError(f"{label}.candidate receipt differs")
    if validate_app_identity(root["app"], f"{label}.app") != manifest["app"]:
        raise AssistiveQualificationError(f"{label}.app differs")
    exact_uuid(root["cellNonce"], f"{label}.cellNonce")
    exact_digest(root["hostScopeSHA256"], f"{label}.hostScopeSHA256")
    operating_system = validate_os(root["os"], f"{label}.os")
    if platform_for_major(contract, operating_system["major"]) != platform_identifier:
        raise AssistiveQualificationError(f"{label}.platform differs from macOS")
    validate_no_content_keys(root, label)
    return root


def validate_session(
    document: Any,
    *,
    manifest: dict[str, Any],
    cell: dict[str, Any],
    contract: dict[str, Any],
    label: str,
) -> dict[str, Any]:
    root = exact_object(
        document,
        label,
        (
            "schemaVersion",
            "kind",
            "startedAt",
            "runID",
            "proof",
            "technology",
            "platform",
            "locale",
            "release",
            "contractSHA256",
            "candidateReceiptSHA256",
            "app",
            "cellNonce",
            "processNonce",
            "processID",
            "processStarted",
            "seedReadySHA256",
            "activation",
        ),
    )
    if exact_integer(root["schemaVersion"], f"{label}.schemaVersion") != 1:
        raise AssistiveQualificationError(f"{label}.schemaVersion is invalid")
    if root["kind"] != "assistive-technology-locale-session":
        raise AssistiveQualificationError(f"{label}.kind is invalid")
    validate_timestamp(root["startedAt"], f"{label}.startedAt")
    for key in ("runID", "proof", "technology", "platform", "cellNonce"):
        if root[key] != cell[key]:
            raise AssistiveQualificationError(f"{label}.{key} differs")
    locale = exact_string(root["locale"], f"{label}.locale", LOCALE_PATTERN)
    if locale not in locale_catalog(contract):
        raise AssistiveQualificationError(f"{label}.locale is invalid")
    if release_identity(root["release"], f"{label}.release") != manifest["release"]:
        raise AssistiveQualificationError(f"{label}.release differs")
    if root["contractSHA256"] != manifest["contractSHA256"]:
        raise AssistiveQualificationError(f"{label}.contract differs")
    if root["candidateReceiptSHA256"] != manifest["candidateReceiptSHA256"]:
        raise AssistiveQualificationError(f"{label}.candidate receipt differs")
    if validate_app_identity(root["app"], f"{label}.app") != manifest["app"]:
        raise AssistiveQualificationError(f"{label}.app differs")
    exact_uuid(root["processNonce"], f"{label}.processNonce")
    exact_integer(root["processID"], f"{label}.processID", minimum=1)
    exact_string(root["processStarted"], f"{label}.processStarted", maximum=80)
    exact_digest(root["seedReadySHA256"], f"{label}.seedReadySHA256")
    validate_activation(root["activation"], cell["technology"], f"{label}.activation")
    validate_no_content_keys(root, label)
    return root


def validate_observation(
    document: Any,
    *,
    manifest: dict[str, Any],
    cell: dict[str, Any],
    session: dict[str, Any],
    contract: dict[str, Any],
    label: str,
) -> dict[str, Any]:
    root = exact_object(
        document,
        label,
        (
            "schemaVersion",
            "kind",
            "collectedAt",
            "runID",
            "proof",
            "technology",
            "platform",
            "locale",
            "checkpoint",
            "sequence",
            "state",
            "observationAuthority",
            "release",
            "contractSHA256",
            "candidateReceiptSHA256",
            "app",
            "cellNonce",
            "processNonce",
            "hostScopeSHA256",
            "os",
            "predecessorSHA256",
        ),
    )
    if exact_integer(root["schemaVersion"], f"{label}.schemaVersion") != 1:
        raise AssistiveQualificationError(f"{label}.schemaVersion is invalid")
    if root["kind"] != "assistive-technology-observation":
        raise AssistiveQualificationError(f"{label}.kind is invalid")
    validate_timestamp(root["collectedAt"], f"{label}.collectedAt")
    for key in (
        "runID",
        "proof",
        "technology",
        "platform",
        "cellNonce",
        "hostScopeSHA256",
    ):
        if root[key] != cell[key]:
            raise AssistiveQualificationError(f"{label}.{key} differs")
    if root["locale"] != session["locale"]:
        raise AssistiveQualificationError(f"{label}.locale differs")
    checkpoint = checkpoint_catalog(contract).get(root["checkpoint"])
    if checkpoint is None:
        raise AssistiveQualificationError(f"{label}.checkpoint is invalid")
    if root["sequence"] != checkpoint["sequence"]:
        raise AssistiveQualificationError(f"{label}.sequence differs")
    if root["state"] not in {"pass", "fail"}:
        raise AssistiveQualificationError(f"{label}.state is invalid")
    expected_authority = technology_catalog(contract)[cell["technology"]][
        "activationAuthority"
    ]
    if root["observationAuthority"] != expected_authority:
        raise AssistiveQualificationError(
            f"{label}.observationAuthority is invalid"
        )
    if release_identity(root["release"], f"{label}.release") != manifest["release"]:
        raise AssistiveQualificationError(f"{label}.release differs")
    if root["contractSHA256"] != manifest["contractSHA256"]:
        raise AssistiveQualificationError(f"{label}.contract differs")
    if root["candidateReceiptSHA256"] != manifest["candidateReceiptSHA256"]:
        raise AssistiveQualificationError(f"{label}.candidate receipt differs")
    if validate_app_identity(root["app"], f"{label}.app") != manifest["app"]:
        raise AssistiveQualificationError(f"{label}.app differs")
    if root["processNonce"] != session["processNonce"]:
        raise AssistiveQualificationError(f"{label}.processNonce differs")
    if validate_os(root["os"], f"{label}.os") != cell["os"]:
        raise AssistiveQualificationError(f"{label}.os differs")
    predecessor = root["predecessorSHA256"]
    if predecessor is not None:
        exact_digest(predecessor, f"{label}.predecessorSHA256")
    validate_no_content_keys(root, label)
    return root


def validate_completion(
    document: Any,
    *,
    manifest: dict[str, Any],
    cell: dict[str, Any],
    session: dict[str, Any],
    label: str,
) -> dict[str, Any]:
    root = exact_object(
        document,
        label,
        (
            "schemaVersion",
            "kind",
            "completedAt",
            "runID",
            "proof",
            "technology",
            "platform",
            "locale",
            "release",
            "contractSHA256",
            "candidateReceiptSHA256",
            "app",
            "cellNonce",
            "processNonce",
            "sessionSHA256",
            "lastObservationSHA256",
            "appExited",
        ),
    )
    if exact_integer(root["schemaVersion"], f"{label}.schemaVersion") != 1:
        raise AssistiveQualificationError(f"{label}.schemaVersion is invalid")
    if root["kind"] != "assistive-technology-locale-completion":
        raise AssistiveQualificationError(f"{label}.kind is invalid")
    validate_timestamp(root["completedAt"], f"{label}.completedAt")
    for key in (
        "runID",
        "proof",
        "technology",
        "platform",
        "cellNonce",
    ):
        if root[key] != cell[key]:
            raise AssistiveQualificationError(f"{label}.{key} differs")
    if root["locale"] != session["locale"]:
        raise AssistiveQualificationError(f"{label}.locale differs")
    if release_identity(root["release"], f"{label}.release") != manifest["release"]:
        raise AssistiveQualificationError(f"{label}.release differs")
    if root["contractSHA256"] != manifest["contractSHA256"]:
        raise AssistiveQualificationError(f"{label}.contract differs")
    if root["candidateReceiptSHA256"] != manifest["candidateReceiptSHA256"]:
        raise AssistiveQualificationError(f"{label}.candidate receipt differs")
    if validate_app_identity(root["app"], f"{label}.app") != manifest["app"]:
        raise AssistiveQualificationError(f"{label}.app differs")
    if root["processNonce"] != session["processNonce"]:
        raise AssistiveQualificationError(f"{label}.processNonce differs")
    exact_digest(root["sessionSHA256"], f"{label}.sessionSHA256")
    exact_digest(
        root["lastObservationSHA256"], f"{label}.lastObservationSHA256"
    )
    if exact_boolean(root["appExited"], f"{label}.appExited") is not True:
        raise AssistiveQualificationError(f"{label}.appExited must be true")
    validate_no_content_keys(root, label)
    return root


def load_run(evidence_root: Path) -> tuple[dict[str, Any], dict[str, Any], str]:
    require_evidence_location(evidence_root)
    require_owner_directory(evidence_root, "assistive evidence root")
    path = evidence_root / RUN_NAME
    require_owner_file(path, "assistive run")
    manifest = validate_run_manifest(load_json(path, "assistive run"))
    contract, digest = load_contract()
    if manifest["contractSHA256"] != digest:
        raise AssistiveQualificationError("run contract differs from tracked source")
    return manifest, contract, digest


def cell_root(evidence_root: Path, proof: str) -> Path:
    return evidence_root / "cells" / proof


def session_path(cell: Path, locale: str) -> Path:
    return cell / "sessions" / f"{locale}.json"


def receipt_path(
    cell: Path, locale: str, sequence: int, checkpoint: str
) -> Path:
    return cell / "receipts" / locale / f"{sequence:02d}-{checkpoint}.json"


def completion_path(cell: Path, locale: str) -> Path:
    return cell / "completions" / f"{locale}.json"


def runtime_path(cell: Path, locale: str) -> Path:
    return cell / f".runtime-{locale}"


def prepare_cell_directories(evidence_root: Path, proof: str) -> Path:
    cells = prepare_owner_subdirectory(evidence_root, "cells")
    cell = prepare_owner_subdirectory(cells, proof)
    sessions = prepare_owner_subdirectory(cell, "sessions")
    receipts = prepare_owner_subdirectory(cell, "receipts")
    for locale in ("en", "es"):
        prepare_owner_subdirectory(receipts, locale)
    prepare_owner_subdirectory(cell, "completions")
    require_owner_directory(sessions, "assistive sessions directory")
    return cell


def ensure_app_matches_manifest(
    app: Path, manifest: dict[str, Any]
) -> dict[str, Any]:
    app_info = inspect_candidate_app(app, manifest["runNonce"])
    if app_info["release"] != manifest["release"]:
        raise AssistiveQualificationError("candidate app release differs from run")
    if app_info["identity"] != manifest["app"]:
        raise AssistiveQualificationError("candidate app bits or signature differ from run")
    return app_info


def initialize(args: argparse.Namespace) -> None:
    evidence_root = normalized_local_path(args.evidence_root)
    require_evidence_location(evidence_root)
    if evidence_root.exists():
        if evidence_root.is_symlink() or not evidence_root.is_dir():
            raise AssistiveQualificationError("evidence root must be a directory")
        if any(evidence_root.iterdir()):
            raise AssistiveQualificationError("evidence root must be absent or empty")
        os.chmod(evidence_root, 0o700)
    else:
        evidence_root.mkdir(mode=0o700, parents=True)
    require_owner_directory(evidence_root, "assistive evidence root")
    contract, contract_digest = load_contract()
    candidate_receipt = normalized_local_path(args.candidate_receipt)
    _candidate, candidate_release = validate_candidate_receipt(candidate_receipt)
    requested_release = release_identity(
        {
            "version": args.version,
            "build": args.build,
            "commit": args.commit,
        },
        "requested release",
    )
    if candidate_release != requested_release:
        raise AssistiveQualificationError(
            "candidate receipt release differs from requested release"
        )
    require_exact_checkout(requested_release["commit"])
    run_nonce = os.urandom(32).hex()
    app_info = inspect_candidate_app(normalized_local_path(args.app), run_nonce)
    if app_info["release"] != requested_release:
        raise AssistiveQualificationError(
            "candidate app release differs from requested release"
        )
    manifest = {
        "schemaVersion": RUN_SCHEMA_VERSION,
        "kind": "assistive-technology-qualification-run",
        "runID": str(uuid.uuid4()),
        "createdAt": utc_now(),
        "release": requested_release,
        "contractSHA256": contract_digest,
        "candidateReceiptSHA256": sha256_file(candidate_receipt),
        "app": app_info["identity"],
        "runNonce": run_nonce,
    }
    validate_run_manifest(manifest)
    atomic_write_json(evidence_root / RUN_NAME, manifest)
    print(f"Initialized assistive qualification run {manifest['runID']}")
    print(f"Manifest: {evidence_root / RUN_NAME}")
    print("No physical assistive proof has been recorded yet.")


def create_or_validate_cell(
    evidence_root: Path,
    *,
    manifest: dict[str, Any],
    contract: dict[str, Any],
    technology: str,
    system: dict[str, Any],
) -> tuple[Path, dict[str, Any]]:
    platform_identifier = platform_for_major(contract, system["os"]["major"])
    proof = proof_for(contract, technology, platform_identifier)
    cell = prepare_cell_directories(evidence_root, proof)
    path = cell / "cell.json"
    if path.exists() or path.is_symlink():
        require_owner_file(path, f"assistive cell {proof}")
        document = validate_cell_manifest(
            load_json(path, f"assistive cell {proof}"),
            manifest=manifest,
            contract=contract,
            label=f"assistive cell {proof}",
        )
        expected = (system["hostScopeSHA256"], system["os"])
        if (document["hostScopeSHA256"], document["os"]) != expected:
            raise AssistiveQualificationError(
                "assistive cell moved to another Mac or macOS build"
            )
        return cell, document
    document = {
        "schemaVersion": CELL_SCHEMA_VERSION,
        "kind": "assistive-technology-cell",
        "createdAt": utc_now(),
        "runID": manifest["runID"],
        "proof": proof,
        "technology": technology,
        "platform": platform_identifier,
        "release": manifest["release"],
        "contractSHA256": manifest["contractSHA256"],
        "candidateReceiptSHA256": manifest["candidateReceiptSHA256"],
        "app": manifest["app"],
        "cellNonce": str(uuid.uuid4()),
        "hostScopeSHA256": system["hostScopeSHA256"],
        "os": system["os"],
    }
    validate_cell_manifest(
        document,
        manifest=manifest,
        contract=contract,
        label=f"assistive cell {proof}",
    )
    atomic_write_json(path, document)
    return cell, document


def _proc_pidpath(pid: int) -> str | None:
    if sys.platform != "darwin":
        return None
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    proc_pidpath = library.proc_pidpath
    proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    length = proc_pidpath(pid, buffer, len(buffer))
    if length <= 0:
        return None
    return os.fsdecode(buffer.value)


def process_identity(pid: int, executable: Path) -> str:
    actual_path = _proc_pidpath(pid)
    if actual_path is None:
        raise AssistiveQualificationError("owned app process is not running")
    if Path(actual_path).resolve() != executable.resolve():
        raise AssistiveQualificationError("owned app PID now names another executable")
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "lstart="],
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        timeout=15,
    )
    return exact_string(result.stdout.strip(), "owned app process start", maximum=80)


def running_candidate_pids(executable: Path) -> list[int]:
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid="],
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, "LC_ALL": "C", "LANG": "C"},
        timeout=15,
    )
    matches = []
    for token in result.stdout.split():
        try:
            pid = int(token)
        except ValueError:
            continue
        actual = _proc_pidpath(pid)
        if actual is not None and Path(actual).resolve() == executable.resolve():
            matches.append(pid)
    return matches


def launch_environment(runtime: Path) -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("PORTAVOZ_")
        and not key.startswith("TEST_RUNNER_")
        and not key.startswith("XCTest")
    }
    environment.update(
        {
            "TMPDIR": str(runtime / "tmp") + "/",
            "PORTAVOZ_AUDIO_ROOT": str(runtime / "audio"),
            "PORTAVOZ_UI_TEST_DATABASE_PATH": str(runtime / "library.sqlite"),
            "PORTAVOZ_UI_TEST_DEFAULTS": json.dumps(
                {"menuBarEnabled": False}, separators=(",", ":")
            ),
            "PORTAVOZ_UI_TEST_SEED_READY_PATH": str(runtime / "seed-ready"),
        }
    )
    return environment


def reject_failed_cell(
    cell: Path,
    *,
    manifest: dict[str, Any],
    cell_document: dict[str, Any],
    contract: dict[str, Any],
) -> None:
    for locale in locale_catalog(contract):
        session_file = session_path(cell, locale)
        if not session_file.exists():
            continue
        require_owner_file(session_file, f"assistive session {locale}")
        session = validate_session(
            load_json(session_file, f"assistive session {locale}"),
            manifest=manifest,
            cell=cell_document,
            contract=contract,
            label=f"assistive session {locale}",
        )
        observations, _ = collect_observations(
            cell,
            locale,
            manifest=manifest,
            cell_document=cell_document,
            session=session,
            contract=contract,
            require_complete=False,
        )
        if any(item["state"] == "fail" for item in observations):
            raise AssistiveQualificationError(
                "a failed observation makes the cell immutable; start a new run"
            )


def launch_arguments(
    contract: dict[str, Any], locale: str
) -> list[str]:
    locale_value = locale_catalog(contract)[locale]["appleLocale"]
    return [
        *contract["launch"]["arguments"],
        "-AppleLanguages",
        f"({locale})",
        "-AppleLocale",
        locale_value,
    ]


def terminate_owned_process(
    pid: int,
    executable: Path,
    process_started: str,
    timeout: int,
) -> None:
    if process_identity(pid, executable) != process_started:
        raise AssistiveQualificationError("owned app process identity changed")
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if _proc_pidpath(pid) is None:
            return
        time.sleep(0.1)
    raise AssistiveQualificationError(
        "owned app did not exit after a graceful termination request"
    )


def start_locale(args: argparse.Namespace) -> None:
    evidence_root = normalized_local_path(args.evidence_root)
    manifest, contract, _ = load_run(evidence_root)
    require_exact_checkout(manifest["release"]["commit"])
    technology = exact_string(args.technology, "technology", CODE_PATTERN)
    if technology not in technology_catalog(contract):
        raise AssistiveQualificationError("technology is not in the contract")
    locale = exact_string(args.locale, "locale", LOCALE_PATTERN)
    if locale not in locale_catalog(contract):
        raise AssistiveQualificationError("locale is not in the contract")
    app_info = ensure_app_matches_manifest(
        normalized_local_path(args.app), manifest
    )
    system = current_system_observation(manifest["runNonce"])
    activation = require_technology_active(
        technology, args.confirm_technology_active
    )
    with exclusive_reservation(evidence_root, "cell-setup"):
        cell, cell_document = create_or_validate_cell(
            evidence_root,
            manifest=manifest,
            contract=contract,
            technology=technology,
            system=system,
        )
    reject_failed_cell(
        cell,
        manifest=manifest,
        cell_document=cell_document,
        contract=contract,
    )
    locale_order = list(locale_catalog(contract))
    for prior_locale in locale_order[: locale_order.index(locale)]:
        try:
            collect_completed_locale(
                cell,
                prior_locale,
                manifest=manifest,
                cell_document=cell_document,
                contract=contract,
            )
        except AssistiveQualificationError as error:
            raise AssistiveQualificationError(
                f"locale {locale} requires completed locale {prior_locale}"
            ) from error
    session_output = session_path(cell, locale)
    completion_output = completion_path(cell, locale)
    if session_output.exists() or completion_output.exists():
        raise AssistiveQualificationError(
            "locale already started; failed observations require a new run"
        )
    receipts = cell / "receipts" / locale
    if any(receipts.iterdir()):
        raise AssistiveQualificationError("locale has unexpected existing observations")
    runtime = runtime_path(cell, locale)
    with exclusive_reservation(evidence_root, "start-locale"):
        if session_output.exists() or completion_output.exists():
            raise AssistiveQualificationError(
                "locale already started; failed observations require a new run"
            )
        if any(receipts.iterdir()):
            raise AssistiveQualificationError(
                "locale has unexpected existing observations"
            )
        if running_candidate_pids(app_info["executable"]):
            raise AssistiveQualificationError(
                "the exact candidate app is already running; quit only that Dev app first"
            )
        if runtime.exists() or runtime.is_symlink():
            raise AssistiveQualificationError("locale runtime must be absent")
        runtime.mkdir(mode=0o700)
        for name in ("tmp", "audio"):
            (runtime / name).mkdir(mode=0o700)
        log_path = runtime / "app.log"
        log_descriptor = os.open(
            log_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
        )
        process: subprocess.Popen[bytes] | None = None
        try:
            command = [
                str(app_info["executable"]),
                *launch_arguments(contract, locale),
            ]
            with os.fdopen(log_descriptor, "wb") as log:
                process = subprocess.Popen(
                    command,
                    env=launch_environment(runtime),
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
            process_started = process_identity(process.pid, app_info["executable"])
            ready = runtime / "seed-ready"
            deadline = time.monotonic() + contract["limits"][
                "seedReadyTimeoutSeconds"
            ]
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise AssistiveQualificationError(
                        "candidate app exited before the public seed was ready"
                    )
                if ready.is_symlink():
                    raise AssistiveQualificationError(
                        "public seed marker must not be a symbolic link"
                    )
                if ready.is_file():
                    break
                time.sleep(0.05)
            else:
                raise AssistiveQualificationError(
                    "candidate app did not finish the public seed in time"
                )
            if ready.stat().st_size != 0:
                raise AssistiveQualificationError("public seed marker is invalid")
            activation = require_technology_active(
                technology, args.confirm_technology_active
            )
            session = {
                "schemaVersion": SESSION_SCHEMA_VERSION,
                "kind": "assistive-technology-locale-session",
                "startedAt": utc_now(),
                "runID": manifest["runID"],
                "proof": cell_document["proof"],
                "technology": technology,
                "platform": cell_document["platform"],
                "locale": locale,
                "release": manifest["release"],
                "contractSHA256": manifest["contractSHA256"],
                "candidateReceiptSHA256": manifest["candidateReceiptSHA256"],
                "app": manifest["app"],
                "cellNonce": cell_document["cellNonce"],
                "processNonce": str(uuid.uuid4()),
                "processID": process.pid,
                "processStarted": process_started,
                "seedReadySHA256": sha256_file(ready),
                "activation": activation,
            }
            validate_session(
                session,
                manifest=manifest,
                cell=cell_document,
                contract=contract,
                label="assistive session",
            )
            atomic_write_json(session_output, session)
        except BaseException as launch_error:
            cleanup_error: BaseException | None = None
            if process is not None and process.poll() is None:
                try:
                    os.kill(process.pid, signal.SIGTERM)
                    process.wait(timeout=5)
                except ProcessLookupError:
                    pass
                except (OSError, subprocess.TimeoutExpired):
                    cleanup_error = AssistiveQualificationError(
                        "failed candidate launch did not exit after graceful cleanup"
                    )
            if not session_output.exists() and cleanup_error is None:
                shutil.rmtree(runtime, ignore_errors=True)
            if cleanup_error is not None:
                raise cleanup_error from launch_error
            raise
    first = contract["checkpoints"][0]["id"]
    print(f"PASS started {cell_document['proof']} locale {locale}")
    print(f"Next checkpoint: {first}")
    print("Use only the named assistive technology; do not use the pointer.")


def load_active_context(
    evidence_root: Path,
    app: Path,
    technology: str,
    locale: str,
) -> tuple[
    dict[str, Any],
    dict[str, Any],
    dict[str, Any],
    dict[str, Any],
    dict[str, Any],
    Path,
]:
    manifest, contract, _ = load_run(evidence_root)
    app_info = ensure_app_matches_manifest(normalized_local_path(app), manifest)
    system = current_system_observation(manifest["runNonce"])
    platform_identifier = platform_for_major(contract, system["os"]["major"])
    proof = proof_for(contract, technology, platform_identifier)
    cell = cell_root(evidence_root, proof)
    require_owner_directory(cell, f"assistive cell {proof}")
    cell_file = cell / "cell.json"
    require_owner_file(cell_file, f"assistive cell {proof}")
    cell_document = validate_cell_manifest(
        load_json(cell_file, f"assistive cell {proof}"),
        manifest=manifest,
        contract=contract,
        label=f"assistive cell {proof}",
    )
    if (cell_document["hostScopeSHA256"], cell_document["os"]) != (
        system["hostScopeSHA256"],
        system["os"],
    ):
        raise AssistiveQualificationError(
            "assistive locale moved to another Mac or macOS build"
        )
    session_file = session_path(cell, locale)
    require_owner_file(session_file, f"assistive session {proof}/{locale}")
    session = validate_session(
        load_json(session_file, f"assistive session {proof}/{locale}"),
        manifest=manifest,
        cell=cell_document,
        contract=contract,
        label=f"assistive session {proof}/{locale}",
    )
    if process_identity(session["processID"], app_info["executable"]) != session[
        "processStarted"
    ]:
        raise AssistiveQualificationError("owned app process identity changed")
    return manifest, contract, app_info, system, cell_document, cell


def collect_observations(
    cell: Path,
    locale: str,
    *,
    manifest: dict[str, Any],
    cell_document: dict[str, Any],
    session: dict[str, Any],
    contract: dict[str, Any],
    require_complete: bool,
) -> tuple[list[dict[str, Any]], list[str]]:
    observations = []
    digests = []
    predecessor: str | None = None
    for checkpoint in contract["checkpoints"]:
        path = receipt_path(
            cell,
            locale,
            checkpoint["sequence"],
            checkpoint["id"],
        )
        if not path.exists():
            if require_complete:
                raise AssistiveQualificationError(
                    f"missing observation {locale}/{checkpoint['id']}"
                )
            break
        require_owner_file(path, f"observation {locale}/{checkpoint['id']}")
        observation = validate_observation(
            load_json(
                path,
                f"observation {locale}/{checkpoint['id']}",
                maximum_bytes=contract["limits"]["maximumReceiptBytes"],
            ),
            manifest=manifest,
            cell=cell_document,
            session=session,
            contract=contract,
            label=f"observation {locale}/{checkpoint['id']}",
        )
        if observation["predecessorSHA256"] != predecessor:
            raise AssistiveQualificationError(
                f"observation chain breaks at {locale}/{checkpoint['id']}"
            )
        digest = sha256_file(path)
        observations.append(observation)
        digests.append(digest)
        predecessor = digest
    receipt_directory = cell / "receipts" / locale
    require_owner_directory(
        receipt_directory, f"assistive receipt directory {locale}"
    )
    actual_entries = list(receipt_directory.iterdir())
    if any(path.is_symlink() or not path.is_file() for path in actual_entries):
        raise AssistiveQualificationError(
            f"locale {locale} contains an invalid observation entry"
        )
    actual = {path.resolve() for path in actual_entries}
    expected = {
        receipt_path(
            cell,
            locale,
            checkpoint["sequence"],
            checkpoint["id"],
        ).resolve()
        for checkpoint in contract["checkpoints"][: len(observations)]
    }
    if actual != expected:
        raise AssistiveQualificationError(
            f"locale {locale} contains unexpected observation files"
        )
    return observations, digests


def collect_completed_locale(
    cell: Path,
    locale: str,
    *,
    manifest: dict[str, Any],
    cell_document: dict[str, Any],
    contract: dict[str, Any],
) -> dict[str, Any]:
    session_file = session_path(cell, locale)
    require_owner_file(session_file, f"assistive session {locale}")
    session = validate_session(
        load_json(session_file, f"assistive session {locale}"),
        manifest=manifest,
        cell=cell_document,
        contract=contract,
        label=f"assistive session {locale}",
    )
    observations, digests = collect_observations(
        cell,
        locale,
        manifest=manifest,
        cell_document=cell_document,
        session=session,
        contract=contract,
        require_complete=True,
    )
    if any(item["state"] != "pass" for item in observations):
        raise AssistiveQualificationError(
            f"assistive locale {locale} contains a failed observation"
        )
    completion_file = completion_path(cell, locale)
    require_owner_file(completion_file, f"assistive completion {locale}")
    completion = validate_completion(
        load_json(completion_file, f"assistive completion {locale}"),
        manifest=manifest,
        cell=cell_document,
        session=session,
        label=f"assistive completion {locale}",
    )
    session_digest = sha256_file(session_file)
    if completion["sessionSHA256"] != session_digest:
        raise AssistiveQualificationError(
            f"assistive completion {locale} session digest differs"
        )
    if completion["lastObservationSHA256"] != digests[-1]:
        raise AssistiveQualificationError(
            f"assistive completion {locale} chain digest differs"
        )
    runtime = runtime_path(cell, locale)
    if runtime.exists() or runtime.is_symlink():
        raise AssistiveQualificationError(
            f"assistive completion {locale} retains runtime state"
        )
    return {
        "session": session,
        "sessionSHA256": session_digest,
        "lastObservationSHA256": digests[-1],
        "completionSHA256": sha256_file(completion_file),
    }


def observe_checkpoint(args: argparse.Namespace) -> None:
    evidence_root = normalized_local_path(args.evidence_root)
    technology = exact_string(args.technology, "technology", CODE_PATTERN)
    locale = exact_string(args.locale, "locale", LOCALE_PATTERN)
    checkpoint_id = exact_string(args.checkpoint, "checkpoint", CODE_PATTERN)
    state = exact_string(args.outcome, "outcome", CODE_PATTERN)
    if state not in {"pass", "fail"}:
        raise AssistiveQualificationError("outcome must be pass or fail")
    confirmation = f"{checkpoint_id}:{state}"
    if args.confirm_observation != confirmation:
        raise AssistiveQualificationError(
            f"checkpoint requires --confirm-observation {confirmation}"
        )
    (
        manifest,
        contract,
        app_info,
        system,
        cell_document,
        cell,
    ) = load_active_context(
        evidence_root,
        args.app,
        technology,
        locale,
    )
    require_exact_checkout(manifest["release"]["commit"])
    if technology not in technology_catalog(contract):
        raise AssistiveQualificationError("technology is not in the contract")
    if locale not in locale_catalog(contract):
        raise AssistiveQualificationError("locale is not in the contract")
    activation = require_technology_active(
        technology, args.confirm_technology_active
    )
    session_file = session_path(cell, locale)
    session = validate_session(
        load_json(session_file, f"assistive session {locale}"),
        manifest=manifest,
        cell=cell_document,
        contract=contract,
        label=f"assistive session {locale}",
    )
    observations, digests = collect_observations(
        cell,
        locale,
        manifest=manifest,
        cell_document=cell_document,
        session=session,
        contract=contract,
        require_complete=False,
    )
    if any(item["state"] == "fail" for item in observations):
        raise AssistiveQualificationError(
            "a failed observation is immutable; begin a new cell run"
        )
    next_index = len(observations)
    if next_index >= len(contract["checkpoints"]):
        raise AssistiveQualificationError("locale already completed every checkpoint")
    checkpoint = contract["checkpoints"][next_index]
    if checkpoint["id"] != checkpoint_id:
        raise AssistiveQualificationError(
            f"next checkpoint must be {checkpoint['id']}"
        )
    if completion_path(cell, locale).exists():
        raise AssistiveQualificationError("locale already has a completion receipt")
    output = receipt_path(
        cell,
        locale,
        checkpoint["sequence"],
        checkpoint["id"],
    )
    with exclusive_reservation(cell, f"observe-{locale}"):
        if output.exists() or output.is_symlink():
            raise AssistiveQualificationError("checkpoint already has an observation")
        observation = {
            "schemaVersion": OBSERVATION_SCHEMA_VERSION,
            "kind": "assistive-technology-observation",
            "collectedAt": utc_now(),
            "runID": manifest["runID"],
            "proof": cell_document["proof"],
            "technology": technology,
            "platform": cell_document["platform"],
            "locale": locale,
            "checkpoint": checkpoint_id,
            "sequence": checkpoint["sequence"],
            "state": state,
            "observationAuthority": activation["authority"],
            "release": manifest["release"],
            "contractSHA256": manifest["contractSHA256"],
            "candidateReceiptSHA256": manifest["candidateReceiptSHA256"],
            "app": manifest["app"],
            "cellNonce": cell_document["cellNonce"],
            "processNonce": session["processNonce"],
            "hostScopeSHA256": system["hostScopeSHA256"],
            "os": system["os"],
            "predecessorSHA256": digests[-1] if digests else None,
        }
        validate_observation(
            observation,
            manifest=manifest,
            cell=cell_document,
            session=session,
            contract=contract,
            label="assistive observation",
        )
        atomic_write_json(output, observation)
    print(f"{state.upper()} {cell_document['proof']} {locale}/{checkpoint_id}")
    if state == "fail":
        terminate_owned_process(
            session["processID"],
            app_info["executable"],
            session["processStarted"],
            contract["limits"]["processExitTimeoutSeconds"],
        )
        runtime = runtime_path(cell, locale)
        if runtime.is_symlink() or not runtime.is_dir():
            raise AssistiveQualificationError("failed locale runtime is invalid")
        shutil.rmtree(runtime)
        print("The failure is retained. Start a new run for any rerun.")
    elif next_index + 1 < len(contract["checkpoints"]):
        print(f"Next checkpoint: {contract['checkpoints'][next_index + 1]['id']}")
    else:
        print(f"All {locale} checkpoints observed; run finish-locale next.")


def finish_locale(args: argparse.Namespace) -> None:
    evidence_root = normalized_local_path(args.evidence_root)
    technology = exact_string(args.technology, "technology", CODE_PATTERN)
    locale = exact_string(args.locale, "locale", LOCALE_PATTERN)
    (
        manifest,
        contract,
        app_info,
        _,
        cell_document,
        cell,
    ) = load_active_context(
        evidence_root,
        args.app,
        technology,
        locale,
    )
    require_exact_checkout(manifest["release"]["commit"])
    require_technology_active(technology, args.confirm_technology_active)
    session_file = session_path(cell, locale)
    session = validate_session(
        load_json(session_file, f"assistive session {locale}"),
        manifest=manifest,
        cell=cell_document,
        contract=contract,
        label=f"assistive session {locale}",
    )
    observations, digests = collect_observations(
        cell,
        locale,
        manifest=manifest,
        cell_document=cell_document,
        session=session,
        contract=contract,
        require_complete=True,
    )
    if any(item["state"] != "pass" for item in observations):
        raise AssistiveQualificationError(
            "failed observations cannot complete a locale; start a new cell run"
        )
    output = completion_path(cell, locale)
    with exclusive_reservation(cell, f"finish-{locale}"):
        if output.exists() or output.is_symlink():
            raise AssistiveQualificationError("locale already completed")
        terminate_owned_process(
            session["processID"],
            app_info["executable"],
            session["processStarted"],
            contract["limits"]["processExitTimeoutSeconds"],
        )
        runtime = runtime_path(cell, locale)
        if runtime.is_symlink() or not runtime.is_dir():
            raise AssistiveQualificationError("locale runtime is invalid")
        shutil.rmtree(runtime)
        completion = {
            "schemaVersion": COMPLETION_SCHEMA_VERSION,
            "kind": "assistive-technology-locale-completion",
            "completedAt": utc_now(),
            "runID": manifest["runID"],
            "proof": cell_document["proof"],
            "technology": technology,
            "platform": cell_document["platform"],
            "locale": locale,
            "release": manifest["release"],
            "contractSHA256": manifest["contractSHA256"],
            "candidateReceiptSHA256": manifest["candidateReceiptSHA256"],
            "app": manifest["app"],
            "cellNonce": cell_document["cellNonce"],
            "processNonce": session["processNonce"],
            "sessionSHA256": sha256_file(session_file),
            "lastObservationSHA256": digests[-1],
            "appExited": True,
        }
        validate_completion(
            completion,
            manifest=manifest,
            cell=cell_document,
            session=session,
            label=f"assistive completion {locale}",
        )
        atomic_write_json(output, completion)
    print(f"PASS completed {cell_document['proof']} locale {locale}")


def expected_cell_entries(
    cell: Path, contract: dict[str, Any]
) -> set[Path]:
    expected = {
        (cell / "cell.json").resolve(),
        (cell / "sessions").resolve(),
        (cell / "receipts").resolve(),
        (cell / "completions").resolve(),
    }
    for locale in locale_catalog(contract):
        expected.add(session_path(cell, locale).resolve())
        expected.add((cell / "receipts" / locale).resolve())
        expected.add(completion_path(cell, locale).resolve())
        for checkpoint in contract["checkpoints"]:
            expected.add(
                receipt_path(
                    cell,
                    locale,
                    checkpoint["sequence"],
                    checkpoint["id"],
                ).resolve()
            )
    return expected


def collect_complete_cell(
    evidence_root: Path,
    proof: str,
    *,
    manifest: dict[str, Any],
    contract: dict[str, Any],
) -> dict[str, Any]:
    cell = cell_root(evidence_root, proof)
    require_owner_directory(cell, f"assistive cell {proof}")
    require_owner_directory(cell / "sessions", f"assistive sessions {proof}")
    require_owner_directory(cell / "receipts", f"assistive receipts {proof}")
    require_owner_directory(cell / "completions", f"assistive completions {proof}")
    manifest_path = cell / "cell.json"
    require_owner_file(manifest_path, f"assistive cell {proof}")
    cell_document = validate_cell_manifest(
        load_json(manifest_path, f"assistive cell {proof}"),
        manifest=manifest,
        contract=contract,
        label=f"assistive cell {proof}",
    )
    if cell_document["proof"] != proof:
        raise AssistiveQualificationError(f"assistive cell {proof} has wrong identity")
    locale_results = []
    process_nonces = []
    for locale in locale_catalog(contract):
        require_owner_directory(
            cell / "receipts" / locale,
            f"assistive receipts {proof}/{locale}",
        )
        result = collect_completed_locale(
            cell,
            locale,
            manifest=manifest,
            cell_document=cell_document,
            contract=contract,
        )
        process_nonces.append(result["session"]["processNonce"])
        locale_results.append(
            {
                "locale": locale,
                "sessionSHA256": result["sessionSHA256"],
                "lastObservationSHA256": result["lastObservationSHA256"],
                "completionSHA256": result["completionSHA256"],
            }
        )
    entries = list(cell.rglob("*"))
    if any(path.is_symlink() for path in entries):
        raise AssistiveQualificationError(
            f"assistive cell {proof} contains a symbolic link"
        )
    if any(not path.is_file() and not path.is_dir() for path in entries):
        raise AssistiveQualificationError(
            f"assistive cell {proof} contains a special entry"
        )
    if {path.resolve() for path in entries} != expected_cell_entries(cell, contract):
        raise AssistiveQualificationError(
            f"assistive cell {proof} contains unexpected evidence"
        )
    return {
        "document": cell_document,
        "cellSHA256": sha256_file(manifest_path),
        "locales": locale_results,
        "processNonces": process_nonces,
    }


def validate_root_inventory(
    evidence_root: Path, proofs: Iterable[str]
) -> None:
    expected = {
        (evidence_root / RUN_NAME).resolve(),
        (evidence_root / "cells").resolve(),
    }
    expected.update(cell_root(evidence_root, proof).resolve() for proof in proofs)
    for proof in proofs:
        cell = cell_root(evidence_root, proof)
        expected.update(path.resolve() for path in cell.rglob("*"))
    entries = list(evidence_root.rglob("*"))
    if any(path.is_symlink() for path in entries):
        raise AssistiveQualificationError("evidence root contains a symbolic link")
    if any(not path.is_file() and not path.is_dir() for path in entries):
        raise AssistiveQualificationError("evidence root contains a special entry")
    if {path.resolve() for path in entries} != expected:
        raise AssistiveQualificationError("evidence root contains unexpected entries")


def qualification_receipt(
    release: dict[str, str], collected_at: str, authority_sha256: str
) -> dict[str, Any]:
    proofs = release_reliability.QUALIFICATION_RECEIPTS["assistive-technology"][
        "proofs"
    ]
    receipt = {
        "schemaVersion": release_reliability.RECEIPT_SCHEMA_VERSION,
        "kind": "qualification",
        "scope": "assistive-technology",
        "authoritySHA256": release_reliability.safe_string(
            authority_sha256,
            "assistive authority digest",
            release_reliability.DIGEST_PATTERN,
        ),
        "collectedAt": collected_at,
        "release": release,
        "proofs": [{"id": proof, "state": "pass"} for proof in proofs],
    }
    try:
        release_reliability.validate_qualification_receipt(
            receipt, "assistive qualification receipt"
        )
    except release_reliability.ReliabilityError as error:
        raise AssistiveQualificationError(str(error)) from error
    return receipt


def publish_authority(
    output: Path,
    authority: dict[str, Any],
    receipt: dict[str, Any],
) -> None:
    output = normalized_local_path(output)
    require_evidence_location(output)
    if output.is_symlink():
        raise AssistiveQualificationError("assistive output must not be a symlink")
    if output.parent.exists():
        require_owner_directory(output.parent, "assistive output parent")
    else:
        output.parent.mkdir(mode=0o700)
        require_owner_directory(output.parent, "assistive output parent")
    lock = output.parent / f".{output.name}.publish.lock"
    try:
        descriptor = os.open(
            lock,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
        )
        os.close(descriptor)
    except FileExistsError as error:
        raise AssistiveQualificationError(
            "assistive authority publication is already in progress"
        ) from error
    staging = output.parent / f".{output.name}.{uuid.uuid4()}"
    try:
        if output.exists() or output.is_symlink():
            raise AssistiveQualificationError("assistive output must be absent")
        staging.mkdir(mode=0o700)
        atomic_write_json(staging / "authority.json", authority)
        atomic_write_json(staging / "qualification.json", receipt)
        if output.exists() or output.is_symlink():
            raise AssistiveQualificationError("assistive output must remain absent")
        os.replace(staging, output)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    finally:
        lock.unlink(missing_ok=True)


def finalize(args: argparse.Namespace) -> None:
    evidence_root = normalized_local_path(args.evidence_root)
    output = normalized_local_path(args.output)
    if output == evidence_root or output.is_relative_to(evidence_root):
        raise AssistiveQualificationError(
            "assistive authority output must be outside the evidence root"
        )
    manifest, contract, contract_digest = load_run(evidence_root)
    require_exact_checkout(manifest["release"]["commit"])
    candidate_receipt = normalized_local_path(args.candidate_receipt)
    _candidate, candidate_release = validate_candidate_receipt(candidate_receipt)
    if candidate_release != manifest["release"]:
        raise AssistiveQualificationError("candidate receipt release differs from run")
    if sha256_file(candidate_receipt) != manifest[
        "candidateReceiptSHA256"
    ]:
        raise AssistiveQualificationError("candidate receipt digest differs from run")
    proofs = tuple(
        release_reliability.QUALIFICATION_RECEIPTS["assistive-technology"][
            "proofs"
        ]
    )
    cells = {
        proof: collect_complete_cell(
            evidence_root,
            proof,
            manifest=manifest,
            contract=contract,
        )
        for proof in proofs
    }
    if len({cell["document"]["cellNonce"] for cell in cells.values()}) != len(
        cells
    ):
        raise AssistiveQualificationError("each assistive cell needs a unique nonce")
    process_nonces = [
        nonce for cell in cells.values() for nonce in cell["processNonces"]
    ]
    if len(set(process_nonces)) != len(process_nonces):
        raise AssistiveQualificationError(
            "each locale must run in a unique app process"
        )
    platform_hosts: dict[str, set[str]] = {"sequoia": set(), "tahoe": set()}
    platform_os: dict[str, set[tuple[Any, ...]]] = {
        "sequoia": set(),
        "tahoe": set(),
    }
    for cell in cells.values():
        document = cell["document"]
        platform_identifier = document["platform"]
        platform_hosts[platform_identifier].add(document["hostScopeSHA256"])
        operating_system = document["os"]
        platform_os[platform_identifier].add(
            (
                operating_system["major"],
                operating_system["minor"],
                operating_system["patch"],
                operating_system["build"],
                operating_system["architecture"],
            )
        )
    if any(len(values) != 1 for values in platform_hosts.values()):
        raise AssistiveQualificationError(
            "VoiceOver and Voice Control must share one host scope per platform"
        )
    if any(len(values) != 1 for values in platform_os.values()):
        raise AssistiveQualificationError(
            "VoiceOver and Voice Control must share one macOS build per platform"
        )
    host_values = [next(iter(values)) for values in platform_hosts.values()]
    if len(set(host_values)) != 2:
        raise AssistiveQualificationError(
            "Sequoia and Tahoe must use distinct Mac host scopes"
        )
    validate_root_inventory(evidence_root, proofs)
    collected_at = utc_now()
    authority = {
        "schemaVersion": AUTHORITY_SCHEMA_VERSION,
        "kind": "assistive-technology-authority",
        "collectedAt": collected_at,
        "release": manifest["release"],
        "runID": manifest["runID"],
        "contractSHA256": contract_digest,
        "candidateReceiptSHA256": manifest["candidateReceiptSHA256"],
        "app": manifest["app"],
        "platforms": [
            {
                "id": platform_identifier,
                "hostScopeSHA256": next(iter(platform_hosts[platform_identifier])),
                "os": dict(
                    zip(
                        ("major", "minor", "patch", "build", "architecture"),
                        next(iter(platform_os[platform_identifier])),
                    )
                ),
            }
            for platform_identifier in ("sequoia", "tahoe")
        ],
        "cells": [
            {
                "proof": proof,
                "cellSHA256": cells[proof]["cellSHA256"],
                "locales": cells[proof]["locales"],
            }
            for proof in proofs
        ],
    }
    validate_no_content_keys(authority, "assistive authority")
    receipt = qualification_receipt(
        manifest["release"],
        collected_at,
        release_reliability.canonical_document_sha256(authority),
    )
    publish_authority(output, authority, receipt)
    print(f"PASS assistive-technology -> {output / 'qualification.json'}")
    print(
        "The authority records fixed human observations; host scopes do not "
        "cryptographically attest physical hardware."
    )


def status(args: argparse.Namespace) -> None:
    evidence_root = normalized_local_path(args.evidence_root)
    manifest, contract, _ = load_run(evidence_root)
    cells_directory = evidence_root / "cells"
    for technology in technology_catalog(contract):
        for platform_identifier in ("sequoia", "tahoe"):
            proof = proof_for(contract, technology, platform_identifier)
            cell = cell_root(evidence_root, proof)
            if not cell.exists():
                print(f"MISSING {proof}")
                continue
            try:
                require_owner_directory(cell, f"assistive cell {proof}")
                cell_document = validate_cell_manifest(
                    load_json(cell / "cell.json", f"assistive cell {proof}"),
                    manifest=manifest,
                    contract=contract,
                    label=f"assistive cell {proof}",
                )
                for locale in locale_catalog(contract):
                    session_file = session_path(cell, locale)
                    if not session_file.exists():
                        print(f"PENDING {proof}/{locale}: not started")
                        continue
                    require_owner_file(
                        session_file, f"assistive session {proof}/{locale}"
                    )
                    session = validate_session(
                        load_json(session_file, f"assistive session {proof}/{locale}"),
                        manifest=manifest,
                        cell=cell_document,
                        contract=contract,
                        label=f"assistive session {proof}/{locale}",
                    )
                    observations, _ = collect_observations(
                        cell,
                        locale,
                        manifest=manifest,
                        cell_document=cell_document,
                        session=session,
                        contract=contract,
                        require_complete=False,
                    )
                    failure = next(
                        (item for item in observations if item["state"] == "fail"),
                        None,
                    )
                    completion = completion_path(cell, locale)
                    if failure is not None:
                        print(
                            f"FAILED  {proof}/{locale}: "
                            f"{failure['checkpoint']}"
                        )
                    elif completion.exists() or completion.is_symlink():
                        collect_completed_locale(
                            cell,
                            locale,
                            manifest=manifest,
                            cell_document=cell_document,
                            contract=contract,
                        )
                        print(f"PASS    {proof}/{locale}")
                    elif len(observations) == len(contract["checkpoints"]):
                        print(f"PENDING {proof}/{locale}: finish-locale")
                    else:
                        next_checkpoint = contract["checkpoints"][
                            len(observations)
                        ]["id"]
                        print(
                            f"PENDING {proof}/{locale}: {next_checkpoint}"
                        )
            except AssistiveQualificationError:
                print(f"INVALID {proof}")
    if cells_directory.exists():
        require_owner_directory(cells_directory, "assistive cells directory")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)

    initialize_parser = subparsers.add_parser(
        "init", help="create one exact candidate-bound assistive run"
    )
    initialize_parser.add_argument("--app", type=Path, required=True)
    initialize_parser.add_argument("--evidence-root", type=Path, required=True)
    initialize_parser.add_argument("--candidate-receipt", type=Path, required=True)
    initialize_parser.add_argument("--version", required=True)
    initialize_parser.add_argument("--build", required=True)
    initialize_parser.add_argument("--commit", required=True)
    initialize_parser.set_defaults(handler=initialize)

    start_parser = subparsers.add_parser(
        "start-locale", help="launch one disposable public-seed locale session"
    )
    start_parser.add_argument("--app", type=Path, required=True)
    start_parser.add_argument("--evidence-root", type=Path, required=True)
    start_parser.add_argument("--technology", required=True)
    start_parser.add_argument("--locale", required=True)
    start_parser.add_argument("--confirm-technology-active", required=True)
    start_parser.set_defaults(handler=start_locale)

    observe_parser = subparsers.add_parser(
        "observe", help="record one fixed human-observed checkpoint"
    )
    observe_parser.add_argument("--app", type=Path, required=True)
    observe_parser.add_argument("--evidence-root", type=Path, required=True)
    observe_parser.add_argument("--technology", required=True)
    observe_parser.add_argument("--locale", required=True)
    observe_parser.add_argument("--checkpoint", required=True)
    observe_parser.add_argument("--outcome", choices=("pass", "fail"), required=True)
    observe_parser.add_argument("--confirm-technology-active", required=True)
    observe_parser.add_argument("--confirm-observation", required=True)
    observe_parser.set_defaults(handler=observe_checkpoint)

    finish_parser = subparsers.add_parser(
        "finish-locale", help="close one complete passing locale session"
    )
    finish_parser.add_argument("--app", type=Path, required=True)
    finish_parser.add_argument("--evidence-root", type=Path, required=True)
    finish_parser.add_argument("--technology", required=True)
    finish_parser.add_argument("--locale", required=True)
    finish_parser.add_argument("--confirm-technology-active", required=True)
    finish_parser.set_defaults(handler=finish_locale)

    status_parser = subparsers.add_parser(
        "status", help="show the finite assistive matrix"
    )
    status_parser.add_argument("--evidence-root", type=Path, required=True)
    status_parser.set_defaults(handler=status)

    finalize_parser = subparsers.add_parser(
        "finalize", help="mint authority from all four complete physical cells"
    )
    finalize_parser.add_argument("--evidence-root", type=Path, required=True)
    finalize_parser.add_argument("--candidate-receipt", type=Path, required=True)
    finalize_parser.add_argument("--output", type=Path, required=True)
    finalize_parser.set_defaults(handler=finalize)
    return result


def main(argv: list[str] | None = None) -> int:
    try:
        arguments = parser().parse_args(argv)
        arguments.handler(arguments)
        return 0
    except (
        AssistiveQualificationError,
        OSError,
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
    ) as error:
        print(f"assistive qualification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
