#!/usr/bin/env python3
"""Validate and package content-free Portavoz field evidence."""

import argparse
import json
import math
import os
import plistlib
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


FORMAT_VERSION = 2
PROTOCOL_VERSION = 1
MAX_REPORT_BYTES = 25 * 1024 * 1024
RELEASE_APP = Path("/Applications/Portavoz.app")
DEFAULT_APP = Path("/Applications/Portavoz Dev.app")
CHECK_STATES = ("pass", "fail", "not-observed")
SCENARIOS = {
    "callback-recovery": (
        "warning-within-eight-seconds",
        "microphone-continued",
        "system-timeline-resumed",
        "warning-cleared",
    ),
    "airpods-process-tap": (
        "recognized-app-shown",
        "microphone-nonsilent",
        "system-nonsilent",
        "silent-channel-created-no-text",
    ),
    "cold-live-captions": (
        "recording-started-before-ready",
        "captions-attached-without-restart",
        "pre-attach-audio-recovered",
        "failure-state-visible",
    ),
    "live-translation": (
        "same-language-row-unchanged",
        "opposite-language-row-translated",
        "target-switch-invalidated-cache",
        "failure-state-visible",
    ),
    "post-capture-refine": (
        "audio-playable-after-stop",
        "transcript-nonempty",
        "speaker-language-preserved",
        "silent-channel-created-no-text",
        "no-repeated-politeness-hallucination",
    ),
    "companion-and-names": (
        "question-card-under-five-seconds",
        "directed-ping-detected",
        "calendar-suggestion-offered",
        "remembered-person-offered-not-auto-linked",
    ),
}

CODE_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,120}$")
HOST_PATTERN = re.compile(r"^[a-z0-9.:[\]-]{1,253}$")
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
REFERENCE_PATTERN = re.compile(r"^meeting-[0-9a-f]{12}$")
LABEL_PATTERN = re.compile(r"^[A-Za-z0-9 ._/+()\-]{1,160}$")
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9._/+()\-]{1,160}$")
VERSION_PATTERN = re.compile(r"^[A-Za-z0-9._+\-]{1,40}$")
OPERATING_SYSTEM_PATTERN = re.compile(
    r"^(?:Version [0-9.]+ \(Build [A-Za-z0-9]+\)|macOS [0-9.]+)$"
)


class EvidenceError(ValueError):
    """A fail-closed field-evidence validation error."""


def object_shape(value, path, required, optional=()):
    if not isinstance(value, dict):
        raise EvidenceError(f"{path} must be an object")
    required = set(required)
    allowed = required | set(optional)
    missing = required - value.keys()
    extra = value.keys() - allowed
    if missing:
        raise EvidenceError(f"{path} is missing keys: {', '.join(sorted(missing))}")
    if extra:
        raise EvidenceError(f"{path} contains forbidden keys: {', '.join(sorted(extra))}")
    return value


def array(value, path, maximum=None):
    if not isinstance(value, list):
        raise EvidenceError(f"{path} must be an array")
    if maximum is not None and len(value) > maximum:
        raise EvidenceError(f"{path} exceeds the {maximum}-item safety limit")
    return value


def integer(value, path, minimum=0):
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise EvidenceError(f"{path} must be an integer >= {minimum}")
    return value


def number(value, path, minimum=None, maximum=None):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvidenceError(f"{path} must be numeric")
    value = float(value)
    if not math.isfinite(value):
        raise EvidenceError(f"{path} must be finite")
    if minimum is not None and value < minimum:
        raise EvidenceError(f"{path} must be >= {minimum}")
    if maximum is not None and value > maximum:
        raise EvidenceError(f"{path} must be <= {maximum}")
    return value


def string(value, path, pattern=None):
    if not isinstance(value, str) or not value:
        raise EvidenceError(f"{path} must be a non-empty string")
    if pattern is not None and pattern.fullmatch(value) is None:
        raise EvidenceError(f"{path} has an unsafe value")
    return value


def label(value, path):
    value = string(value, path, LABEL_PATTERN)
    if value.startswith("/") or "://" in value or "\\" in value or "../" in value:
        raise EvidenceError(f"{path} resembles a path or URL")
    return value


def timestamp(value, path):
    value = string(value, path)
    if len(value) > 64:
        raise EvidenceError(f"{path} exceeds the timestamp safety limit")
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise EvidenceError(f"{path} must be an ISO-8601 timestamp") from error
    return value


def optional(document, key, validator, path):
    if key in document and document[key] is not None:
        validator(document[key], f"{path}.{key}")


def validate_report(report):
    root = object_shape(
        report,
        "report",
        ("formatVersion", "generatedAt", "environment", "storage", "meetings"),
    )
    if integer(root["formatVersion"], "report.formatVersion") != FORMAT_VERSION:
        raise EvidenceError(f"report.formatVersion must be {FORMAT_VERSION}")
    timestamp(root["generatedAt"], "report.generatedAt")
    validate_environment(root["environment"])
    validate_storage(root["storage"])
    meetings = array(root["meetings"], "report.meetings", maximum=100_000)
    for index, meeting in enumerate(meetings):
        validate_meeting(meeting, f"report.meetings[{index}]")
    if root["storage"]["meetingCount"] != len(meetings):
        raise EvidenceError("report.storage.meetingCount does not match meetings")


def validate_environment(value):
    path = "report.environment"
    value = object_shape(
        value,
        path,
        ("appVersion", "buildVersion", "operatingSystem", "models"),
    )
    string(value["appVersion"], f"{path}.appVersion", VERSION_PATTERN)
    string(value["buildVersion"], f"{path}.buildVersion", VERSION_PATTERN)
    string(
        value["operatingSystem"],
        f"{path}.operatingSystem",
        OPERATING_SYSTEM_PATTERN,
    )
    for index, model in enumerate(array(value["models"], f"{path}.models", maximum=100)):
        model_path = f"{path}.models[{index}]"
        model = object_shape(model, model_path, ("capability", "state"))
        string(model["capability"], f"{model_path}.capability", CODE_PATTERN)
        string(model["state"], f"{model_path}.state", CODE_PATTERN)


def validate_storage(value):
    path = "report.storage"
    value = object_shape(
        value,
        path,
        ("schemaVersion", "privacyTrackingStartedAt", "meetingCount"),
    )
    integer(value["schemaVersion"], f"{path}.schemaVersion", minimum=1)
    timestamp(value["privacyTrackingStartedAt"], f"{path}.privacyTrackingStartedAt")
    integer(value["meetingCount"], f"{path}.meetingCount")


def validate_meeting(value, path):
    value = object_shape(
        value,
        path,
        (
            "reference",
            "lifecycleState",
            "transcriptRevision",
            "audioAssets",
            "transcript",
            "processingJobs",
            "generationRuns",
            "privacyReceipt",
        ),
        ("lastProcessingError",),
    )
    string(value["reference"], f"{path}.reference", REFERENCE_PATTERN)
    string(value["lifecycleState"], f"{path}.lifecycleState", CODE_PATTERN)
    integer(value["transcriptRevision"], f"{path}.transcriptRevision")
    optional(value, "lastProcessingError", lambda item, item_path: string(item, item_path, CODE_PATTERN), path)
    for index, asset in enumerate(array(value["audioAssets"], f"{path}.audioAssets", 10)):
        validate_audio(asset, f"{path}.audioAssets[{index}]")
    validate_transcript(value["transcript"], f"{path}.transcript")
    for index, job in enumerate(array(value["processingJobs"], f"{path}.processingJobs", 10_000)):
        validate_job(job, f"{path}.processingJobs[{index}]")
    for index, run in enumerate(array(value["generationRuns"], f"{path}.generationRuns", 10_000)):
        validate_generation(run, f"{path}.generationRuns[{index}]")
    validate_privacy(value["privacyReceipt"], f"{path}.privacyReceipt")


def validate_audio(value, path):
    value = object_shape(
        value,
        path,
        ("channel", "role", "healthStatus"),
        (
            "container",
            "codec",
            "sampleRate",
            "channelCount",
            "durationSeconds",
            "byteCount",
            "peakDBFS",
            "rmsDBFS",
        ),
    )
    for key in ("channel", "role", "healthStatus"):
        string(value[key], f"{path}.{key}", CODE_PATTERN)
    for key in ("container", "codec"):
        optional(value, key, lambda item, item_path: string(item, item_path, CODE_PATTERN), path)
    optional(value, "sampleRate", lambda item, item_path: number(item, item_path, 1), path)
    optional(value, "channelCount", lambda item, item_path: integer(item, item_path, 1), path)
    for key in ("durationSeconds", "byteCount"):
        optional(value, key, lambda item, item_path: number(item, item_path, 0), path)
    for key in ("peakDBFS", "rmsDBFS"):
        optional(value, key, number, path)


def validate_transcript(value, path):
    value = object_shape(
        value,
        path,
        (
            "segmentCount",
            "microphoneSegmentCount",
            "systemSegmentCount",
            "attributedSegmentCount",
        ),
    )
    counts = {key: integer(item, f"{path}.{key}") for key, item in value.items()}
    total = counts["segmentCount"]
    if counts["microphoneSegmentCount"] + counts["systemSegmentCount"] > total:
        raise EvidenceError(f"{path} channel counts exceed segmentCount")
    if counts["attributedSegmentCount"] > total:
        raise EvidenceError(f"{path}.attributedSegmentCount exceeds segmentCount")


def validate_job(value, path):
    value = object_shape(
        value,
        path,
        (
            "kind",
            "inputFingerprintDigest",
            "state",
            "progress",
            "attempt",
            "maxAttempts",
            "createdAt",
            "updatedAt",
        ),
        ("notBefore", "errorCode", "startedAt", "finishedAt"),
    )
    for key in ("kind", "state"):
        string(value[key], f"{path}.{key}", CODE_PATTERN)
    string(value["inputFingerprintDigest"], f"{path}.inputFingerprintDigest", DIGEST_PATTERN)
    number(value["progress"], f"{path}.progress", 0, 1)
    attempt = integer(value["attempt"], f"{path}.attempt")
    maximum = integer(value["maxAttempts"], f"{path}.maxAttempts", minimum=1)
    if attempt > maximum:
        raise EvidenceError(f"{path}.attempt exceeds maxAttempts")
    for key in ("createdAt", "updatedAt", "notBefore", "startedAt", "finishedAt"):
        optional(value, key, timestamp, path)
    optional(value, "errorCode", lambda item, item_path: string(item, item_path, CODE_PATTERN), path)


def validate_generation(value, path):
    value = object_shape(
        value,
        path,
        ("kind", "providerID", "modelID", "inputFingerprintDigest", "startedAt"),
        ("modelRevision", "outputLanguage", "finishedAt", "outcome"),
    )
    string(value["kind"], f"{path}.kind", CODE_PATTERN)
    string(value["providerID"], f"{path}.providerID", IDENTIFIER_PATTERN)
    string(value["modelID"], f"{path}.modelID", IDENTIFIER_PATTERN)
    string(value["inputFingerprintDigest"], f"{path}.inputFingerprintDigest", DIGEST_PATTERN)
    timestamp(value["startedAt"], f"{path}.startedAt")
    for key in ("modelRevision", "outputLanguage"):
        optional(
            value,
            key,
            lambda item, item_path: string(item, item_path, IDENTIFIER_PATTERN),
            path,
        )
    optional(value, "finishedAt", timestamp, path)
    optional(value, "outcome", lambda item, item_path: string(item, item_path, CODE_PATTERN), path)


def validate_privacy(value, path):
    value = object_shape(
        value,
        path,
        ("status", "coverage", "syncDisclosure", "trackingStartedAt", "events"),
    )
    for key in ("status", "coverage", "syncDisclosure"):
        string(value[key], f"{path}.{key}", CODE_PATTERN)
    timestamp(value["trackingStartedAt"], f"{path}.trackingStartedAt")
    for index, event in enumerate(array(value["events"], f"{path}.events", 10_000)):
        event_path = f"{path}.events[{index}]"
        event = object_shape(
            event,
            event_path,
            (
                "operation",
                "destinationScope",
                "destinationHost",
                "dataClassification",
                "consentSource",
                "providerID",
                "attemptedAt",
            ),
            ("modelID",),
        )
        for key in ("operation", "destinationScope", "dataClassification", "consentSource"):
            string(event[key], f"{event_path}.{key}", CODE_PATTERN)
        for key in ("destinationHost", "providerID"):
            string(event[key], f"{event_path}.{key}", HOST_PATTERN)
        optional(
            event,
            "modelID",
            lambda item, item_path: string(item, item_path, IDENTIFIER_PATTERN),
            event_path,
        )
        timestamp(event["attemptedAt"], f"{event_path}.attemptedAt")


def safe_app_metadata(app_path):
    unresolved = Path(app_path).expanduser()
    if unresolved == RELEASE_APP or unresolved.resolve(strict=False) == RELEASE_APP:
        raise EvidenceError("refusing to inspect /Applications/Portavoz.app; use Portavoz Dev.app")
    info_path = unresolved / "Contents" / "Info.plist"
    if not info_path.is_file():
        raise EvidenceError(f"app Info.plist not found: {info_path}")
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != "app.portavoz.mac":
        raise EvidenceError("app bundle identifier is not app.portavoz.mac")
    return {
        "version": string(
            info.get("CFBundleShortVersionString"), "app.version", VERSION_PATTERN
        ),
        "build": string(info.get("CFBundleVersion"), "app.build", VERSION_PATTERN),
    }


def sw_vers(flag):
    result = subprocess.run(
        ["/usr/bin/sw_vers", flag],
        capture_output=True,
        check=True,
        text=True,
    )
    return label(result.stdout.strip(), f"macOS.{flag}")


def parse_checks(raw_checks, scenario):
    allowed = set(SCENARIOS[scenario])
    parsed = {}
    for raw in raw_checks:
        if "=" not in raw:
            raise EvidenceError(f"check must use name=state: {raw}")
        name, state = raw.split("=", 1)
        if name not in allowed:
            raise EvidenceError(f"unknown check for {scenario}: {name}")
        if state not in CHECK_STATES:
            raise EvidenceError(f"invalid check state for {name}: {state}")
        if name in parsed:
            raise EvidenceError(f"duplicate check: {name}")
        parsed[name] = state
    return {name: parsed.get(name, "not-observed") for name in SCENARIOS[scenario]}


def outcome(checks):
    if "fail" in checks.values():
        return "fail"
    if all(state == "pass" for state in checks.values()):
        return "pass"
    return "incomplete"


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=True, indent=2, sort_keys=True)
        handle.write("\n")
    temporary.chmod(0o600)
    os.replace(temporary, path)


def collect(args):
    app = safe_app_metadata(args.app)
    report_path = Path(args.report).expanduser()
    if not report_path.is_file():
        raise EvidenceError(f"support report not found: {report_path}")
    if report_path.stat().st_size > MAX_REPORT_BYTES:
        raise EvidenceError("support report exceeds the 25 MiB safety limit")
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError("support report is not valid UTF-8 JSON") from error
    validate_report(report)
    checks = parse_checks(args.check, args.scenario)
    elapsed = None
    if args.elapsed_seconds is not None:
        elapsed = number(args.elapsed_seconds, "elapsedSeconds", 0, 86_400)

    output = Path(args.output).expanduser()
    if output.exists():
        raise EvidenceError(f"output directory already exists: {output}")
    manifest = {
        "protocolVersion": PROTOCOL_VERSION,
        "collectedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "scenario": args.scenario,
        "outcome": outcome(checks),
        "checks": checks,
        "elapsedSeconds": elapsed,
        "app": app,
        "macOS": {
            "productVersion": sw_vers("-productVersion"),
            "buildVersion": sw_vers("-buildVersion"),
        },
        "supportReport": {
            "formatVersion": report["formatVersion"],
            "generatedAt": report["generatedAt"],
            "meetingCount": report["storage"]["meetingCount"],
        },
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = output.parent / f".{output.name}.field-evidence-{os.getpid()}"
    if staging.exists():
        raise EvidenceError(f"temporary evidence directory already exists: {staging}")
    staging.mkdir(mode=0o700)
    try:
        write_json(staging / "manifest.json", manifest)
        write_json(staging / "support-diagnostics.json", report)
        os.rename(staging, output)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return output, manifest


def parser():
    result = argparse.ArgumentParser(
        description="Package content-free Portavoz field evidence without audio or text."
    )
    result.add_argument("--scenario", choices=tuple(SCENARIOS), required=True)
    result.add_argument("--report", required=True, help="Exported format-v2 support JSON")
    result.add_argument("--output", required=True, help="New evidence directory")
    result.add_argument("--app", default=str(DEFAULT_APP), help="Portavoz Dev.app bundle")
    result.add_argument(
        "--check",
        action="append",
        default=[],
        help="Scenario check as name=pass|fail|not-observed; repeat as needed",
    )
    result.add_argument("--elapsed-seconds", type=float)
    return result


def main():
    args = parser().parse_args()
    try:
        output, manifest = collect(args)
    except (EvidenceError, OSError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(f"OK -> {output}")
    print(f"scenario={manifest['scenario']} outcome={manifest['outcome']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
