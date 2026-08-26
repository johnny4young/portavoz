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
LEGACY_PROTOCOL_VERSION = 1
PROTOCOL_VERSION = 2
MAX_REPORT_BYTES = 25 * 1024 * 1024
RELEASE_APP = Path("/Applications/Portavoz.app")
DEFAULT_APP = Path("/Applications/Portavoz Dev.app")
CHECK_STATES = ("pass", "fail", "not-observed")
LEGACY_SCENARIOS = {
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
    "app-intents-siri": (
        "shortcuts-action-visible",
        "spotlight-action-visible",
        "siri-phrase-started-recording",
        "recording-stopped-and-saved",
    ),
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
FIXTURES = {
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
FIXTURES_REQUIRING_AFTER_REFINE = {"mixed-language"}

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
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise EvidenceError(f"{path} must be an ISO-8601 timestamp") from error
    if parsed.utcoffset() is None:
        raise EvidenceError(f"{path} must include a UTC offset")
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
    if info.get("CFBundleIdentifier") != "app.portavoz.mac.dev":
        raise EvidenceError("app bundle identifier is not app.portavoz.mac.dev")
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


def current_macos():
    return {
        "productVersion": sw_vers("-productVersion"),
        "buildVersion": sw_vers("-buildVersion"),
    }


def validate_macos_observation(value):
    value = object_shape(
        value,
        "macOS",
        ("productVersion", "buildVersion"),
    )
    return {
        "productVersion": label(value["productVersion"], "macOS.productVersion"),
        "buildVersion": label(value["buildVersion"], "macOS.buildVersion"),
    }


def parse_checks(raw_checks, scenario):
    allowed = set(LEGACY_SCENARIOS[scenario])
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
    return {
        name: parsed.get(name, "not-observed")
        for name in LEGACY_SCENARIOS[scenario]
    }


def parse_evidence(raw_evidence, fixture):
    allowed = set(FIXTURES[fixture])
    parsed = {}
    for raw in raw_evidence:
        if "=" not in raw:
            raise EvidenceError(f"evidence must use id=state: {raw}")
        identifier, state = raw.split("=", 1)
        if identifier not in allowed:
            raise EvidenceError(f"unknown evidence for {fixture}: {identifier}")
        if state not in CHECK_STATES:
            raise EvidenceError(f"invalid evidence state for {identifier}: {state}")
        if identifier in parsed:
            raise EvidenceError(f"duplicate evidence: {identifier}")
        parsed[identifier] = state
    return {
        identifier: parsed.get(identifier, "not-observed")
        for identifier in FIXTURES[fixture]
    }


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


def load_report(path, label):
    report_path = Path(path).expanduser()
    if not report_path.is_file():
        raise EvidenceError(f"{label} support report not found: {report_path}")
    if report_path.stat().st_size > MAX_REPORT_BYTES:
        raise EvidenceError(f"{label} support report exceeds the 25 MiB safety limit")
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"{label} support report is not valid UTF-8 JSON") from error
    validate_report(report)
    return report


def report_meeting(report, reference, label):
    matches = [
        meeting for meeting in report["meetings"]
        if meeting["reference"] == reference
    ]
    if len(matches) != 1:
        raise EvidenceError(
            f"{label} support report must contain meeting reference exactly once: "
            f"{reference}"
        )
    return matches[0]


def report_metadata(report, meeting):
    return {
        "formatVersion": report["formatVersion"],
        "generatedAt": report["generatedAt"],
        "meetingCount": report["storage"]["meetingCount"],
        "selectedMeeting": {
            "lifecycleState": meeting["lifecycleState"],
            "transcriptRevision": meeting["transcriptRevision"],
            "audioAssetCount": len(meeting["audioAssets"]),
            "segmentCount": meeting["transcript"]["segmentCount"],
            "processingJobCount": len(meeting["processingJobs"]),
        },
    }


def ensure_report_matches_app(report, app, label):
    environment = report["environment"]
    if environment["appVersion"] != app["version"]:
        raise EvidenceError(f"{label} support report app version does not match bundle")
    if environment["buildVersion"] != app["build"]:
        raise EvidenceError(f"{label} support report build does not match bundle")


def ensure_evidence_matches_report(evidence, meeting):
    if (
        evidence.get("recording.stop.durable") == "pass"
        and meeting["lifecycleState"] == "recording"
    ):
        raise EvidenceError(
            "recording.stop.durable cannot pass while the meeting is still recording"
        )
    if (
        evidence.get("post-capture.admission.completed") == "pass"
        and not meeting["audioAssets"]
    ):
        raise EvidenceError(
            "post-capture.admission.completed cannot pass without an audio asset"
        )
    if evidence.get("capture.route.preserved") == "pass":
        channels = {asset["channel"] for asset in meeting["audioAssets"]}
        if not {"microphone", "system"}.issubset(channels):
            raise EvidenceError(
                "capture.route.preserved cannot pass without microphone and system assets"
            )


def publish_package(output, manifest, reports):
    output = Path(output).expanduser()
    if output.exists():
        raise EvidenceError(f"output directory already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = output.parent / f".{output.name}.field-evidence-{os.getpid()}"
    if staging.exists():
        raise EvidenceError(f"temporary evidence directory already exists: {staging}")
    staging.mkdir(mode=0o700)
    try:
        write_json(staging / "manifest.json", manifest)
        for filename, report in reports.items():
            write_json(staging / filename, report)
        os.rename(staging, output)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return output


def collect_legacy(args, app, system_observer):
    if args.evidence or args.after_refine_report or args.meeting_reference:
        raise EvidenceError(
            "legacy --scenario accepts only --report and --check evidence"
        )
    report = load_report(args.report, "scenario")
    checks = parse_checks(args.check, args.scenario)
    elapsed = None
    if args.elapsed_seconds is not None:
        elapsed = number(args.elapsed_seconds, "elapsedSeconds", 0, 86_400)

    manifest = {
        "protocolVersion": LEGACY_PROTOCOL_VERSION,
        "collectedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "scenario": args.scenario,
        "outcome": outcome(checks),
        "checks": checks,
        "elapsedSeconds": elapsed,
        "app": app,
        "macOS": validate_macos_observation(system_observer()),
        "supportReport": {
            "formatVersion": report["formatVersion"],
            "generatedAt": report["generatedAt"],
            "meetingCount": report["storage"]["meetingCount"],
        },
    }
    output = publish_package(
        args.output,
        manifest,
        {"support-diagnostics.json": report},
    )
    return output, manifest


def collect_fixture(args, app, system_observer):
    if args.check:
        raise EvidenceError("canonical --fixture accepts --evidence, not --check")
    if not args.meeting_reference:
        raise EvidenceError("canonical --fixture requires --meeting-reference")
    reference = string(
        args.meeting_reference,
        "meetingReference",
        REFERENCE_PATTERN,
    )
    before = load_report(args.report, "before-Refine")
    ensure_report_matches_app(before, app, "before-Refine")
    before_meeting = report_meeting(before, reference, "before-Refine")
    evidence = parse_evidence(args.evidence, args.fixture)
    ensure_evidence_matches_report(evidence, before_meeting)

    after = None
    after_meeting = None
    if args.after_refine_report:
        after = load_report(args.after_refine_report, "after-Refine")
        ensure_report_matches_app(after, app, "after-Refine")
        after_meeting = report_meeting(after, reference, "after-Refine")
        before_generated_at = datetime.fromisoformat(
            before["generatedAt"].replace("Z", "+00:00")
        )
        after_generated_at = datetime.fromisoformat(
            after["generatedAt"].replace("Z", "+00:00")
        )
        if after_generated_at < before_generated_at:
            raise EvidenceError(
                "after-Refine support report predates the before-Refine report"
            )
    elif args.fixture in FIXTURES_REQUIRING_AFTER_REFINE:
        raise EvidenceError(f"{args.fixture} requires --after-refine-report")

    if evidence.get("refine.language.preserved") == "pass":
        if after_meeting is None:
            raise EvidenceError(
                "refine.language.preserved requires --after-refine-report"
            )
        if (
            after_meeting["transcriptRevision"]
            <= before_meeting["transcriptRevision"]
        ):
            raise EvidenceError(
                "refine.language.preserved cannot pass without a newer "
                "transcript revision"
            )

    elapsed = None
    if args.elapsed_seconds is not None:
        elapsed = number(args.elapsed_seconds, "elapsedSeconds", 0, 86_400)
    manifest = {
        "protocolVersion": PROTOCOL_VERSION,
        "collectedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "fixture": args.fixture,
        "meetingReference": reference,
        "outcome": outcome(evidence),
        "evidence": [
            {
                "id": identifier,
                "subsystem": EVIDENCE_SUBSYSTEMS[identifier],
                "state": state,
            }
            for identifier, state in evidence.items()
        ],
        "elapsedSeconds": elapsed,
        "app": app,
        "macOS": validate_macos_observation(system_observer()),
        "supportReports": {
            "beforeRefine": report_metadata(before, before_meeting),
            "afterRefine": (
                report_metadata(after, after_meeting)
                if after is not None and after_meeting is not None
                else None
            ),
        },
    }
    reports = {"support-before-refine.json": before}
    if after is not None:
        reports["support-after-refine.json"] = after
    output = publish_package(args.output, manifest, reports)
    return output, manifest


def collect(args, system_observer=current_macos):
    app = safe_app_metadata(args.app)
    if args.fixture:
        return collect_fixture(args, app, system_observer)
    return collect_legacy(args, app, system_observer)


def parser():
    result = argparse.ArgumentParser(
        description="Package content-free Portavoz field evidence without audio or text."
    )
    mode = result.add_mutually_exclusive_group(required=True)
    mode.add_argument("--fixture", choices=tuple(FIXTURES))
    mode.add_argument(
        "--scenario",
        choices=tuple(LEGACY_SCENARIOS),
        help="Legacy protocol-v1 scenario retained for one release",
    )
    result.add_argument(
        "--report",
        required=True,
        help="Exported format-v2 support JSON; before-Refine in fixture mode",
    )
    result.add_argument(
        "--after-refine-report",
        help="Optional paired format-v2 support JSON exported after Refine",
    )
    result.add_argument(
        "--meeting-reference",
        help="Pseudonymous meeting reference from the support report",
    )
    result.add_argument("--output", required=True, help="New evidence directory")
    result.add_argument("--app", default=str(DEFAULT_APP), help="Portavoz Dev.app bundle")
    result.add_argument(
        "--check",
        action="append",
        default=[],
        help="Legacy scenario check as name=pass|fail|not-observed",
    )
    result.add_argument(
        "--evidence",
        action="append",
        default=[],
        help="Canonical fixture evidence as id=pass|fail|not-observed",
    )
    result.add_argument("--elapsed-seconds", type=float)
    return result


def main(argv=None, system_observer=current_macos):
    args = parser().parse_args(argv)
    try:
        output, manifest = collect(args, system_observer)
    except (EvidenceError, OSError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    print(f"OK -> {output}")
    mode = "fixture" if "fixture" in manifest else "scenario"
    print(f"{mode}={manifest[mode]} outcome={manifest['outcome']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
