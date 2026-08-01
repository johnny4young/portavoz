#!/usr/bin/env python3
"""Snapshot and verify the reviewed Meeting Detail interaction boundary."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any


REPOSITORY = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = (
    REPOSITORY / "docs" / "evidence" / "meeting-detail-interaction-contract.json"
)
UI_TEST_SOURCE = REPOSITORY / "Tests" / "PortavozUITests" / "MeetingDetailUITests.swift"

INTERACTION_SOURCE_PATHS = (
    "Sources/portavoz-app/AutoSelectTextField.swift",
    "Sources/portavoz-app/ChipLabel.swift",
    "Sources/portavoz-app/CustomStructureSheet.swift",
    "Sources/portavoz-app/MeetingDetailView.swift",
    "Sources/portavoz-app/MeetingHealthView.swift",
    "Sources/portavoz-app/MeetingPlayerBar.swift",
    "Sources/portavoz-app/MeetingRecapSheet.swift",
    "Sources/portavoz-app/MirrorCard.swift",
    "Sources/portavoz-app/SpeakerPill.swift",
    "Sources/portavoz-app/SummaryClaimFeedbackView.swift",
    "Sources/portavoz-app/TranscriptSegmentsView.swift",
)

PERFORMANCE_EVIDENCE_PATHS = (
    "docs/evidence/meeting-detail-performance-baseline-20260801.json",
    "scripts/meeting_detail_performance.py",
    "scripts/run-detail-ui-baseline.sh",
)

PERFORMANCE_MEASUREMENT_LIMITATIONS = (
    "SwiftUI body invalidation rows depend on xctrace toolchain availability; "
    "a missing export is recorded as unavailable and never interpreted as zero.",
)

SIGNAL_PATTERNS = (
    ("state", re.compile(r"@(State|AppStorage|FocusState)\b")),
    (
        "control",
        re.compile(
            r"\b(Button|Menu|Toggle|Picker|TextField|TextEditor|Slider|Link|"
            r"AutoSelectTextField|SpeakerPill|DismissibleSuggestionChip|DragGesture)\b"
        ),
    ),
    (
        "presentation",
        re.compile(
            r"\.(sheet|alert|confirmationDialog|fileExporter|fileImporter|"
            r"popover|fullScreenCover)\b"
        ),
    ),
    ("keyboard", re.compile(r"\.keyboardShortcut\b")),
    (
        "identifier",
        re.compile(r"\.(accessibilityIdentifier|setAccessibilityIdentifier)\b"),
    ),
    (
        "navigation",
        re.compile(
            r"\b(openSettings|NSWorkspace\.shared\.(?:open|"
            r"activateFileViewerSelecting))\b|\broute\s*=|\.seek\b|\bonSeek\s*:"
        ),
    ),
)

TOP_LEVEL_KEYS = {
    "schemaVersion",
    "kind",
    "requiredLocales",
    "interactionSources",
    "interactionSignals",
    "featureOwnership",
    "performanceEvidence",
    "performanceMeasurementLimitations",
}
SIGNAL_KEYS = {"path", "category", "source", "occurrences"}
OWNER_KEYS = {"feature", "tests", "sourceAnchors", "screenshots"}
ANCHOR_KEYS = {"path", "anchor"}
EVIDENCE_KEYS = {"path", "sha256"}


DEFAULT_FEATURE_OWNERSHIP = (
    {
        "feature": "detail-scale",
        "tests": [
            "testFiveThousandSegmentDetailRendersFromDisposableScaleFixture",
            "testTwentyThousandSegmentDetailRendersFromDisposableScaleFixture",
        ],
        "sourceAnchors": [
            {
                "path": "Sources/portavoz-app/MeetingDetailView.swift",
                "anchor": '"detail-transcript-title"',
            },
        ],
    },
    {
        "feature": "dismissible-suggestions-and-feedback",
        "tests": [
            "testAISuggestionsCanBeIgnoredAndPlaybackOffersClearMix",
            "testSummaryFeedbackIsExplicitReversibleAndLocal",
        ],
        "sourceAnchors": [
            {
                "path": "Sources/portavoz-app/ChipLabel.swift",
                "anchor": "DismissibleSuggestionChip",
            },
            {
                "path": "Sources/portavoz-app/SummaryClaimFeedbackView.swift",
                "anchor": '"summary-feedback-correction"',
            },
        ],
    },
    {
        "feature": "evidence-navigation",
        "tests": [
            "testActionItemSourceJumpsToItsTranscriptAndAudio",
            "testApuntadorAnswerSourceJumpsToItsTranscriptAndAudio",
            "testDecisionSourceJumpsToItsTranscriptAndAudio",
            "testSummarySourceJumpsToItsTranscriptAndAudio",
        ],
        "sourceAnchors": [
            {
                "path": "Sources/portavoz-app/MeetingDetailView.swift",
                "anchor": "evidenceFocusSegmentID",
            },
        ],
    },
    {
        "feature": "exports",
        "tests": ["testExportMenuOffersSubtitleFormats"],
        "sourceAnchors": [
            {
                "path": "Sources/portavoz-app/MeetingDetailView.swift",
                "anchor": '"detail-export-menu"',
            },
        ],
    },
    {
        "feature": "notes-and-recap",
        "tests": [
            "testMyNotesSectionShowsRawNotesAndOffersEnhancement",
            "testRecapSheetDraftsFromTheSummaryWithoutTheTranscript",
        ],
        "sourceAnchors": [
            {
                "path": "Sources/portavoz-app/MeetingDetailView.swift",
                "anchor": '"detail-enhance-notes"',
            },
            {
                "path": "Sources/portavoz-app/MeetingRecapSheet.swift",
                "anchor": '"recap-title"',
            },
        ],
    },
    {
        "feature": "playback-and-clips",
        "tests": [
            "testClipMarkingRevealsExport",
            "testPlayerExposesSkipAndOnlyMyVoice",
        ],
        "sourceAnchors": [
            {
                "path": "Sources/portavoz-app/MeetingPlayerBar.swift",
                "anchor": '"player-play-pause"',
            },
            {
                "path": "Sources/portavoz-app/MeetingPlayerBar.swift",
                "anchor": '"clip-export"',
            },
        ],
    },
    {
        "feature": "processing-and-refine",
        "tests": [
            "testFailedDurableProcessingOffersOneRecoveryAction",
            "testRunningRefineCanBeCanceledWithoutChangingTheTranscript",
        ],
        "sourceAnchors": [
            {
                "path": "Sources/portavoz-app/MeetingDetailView.swift",
                "anchor": '"detail-recover-with-refine"',
            },
            {
                "path": "Sources/portavoz-app/MeetingDetailView.swift",
                "anchor": '"detail-refine"',
            },
        ],
    },
    {
        "feature": "right-rail-and-mirror",
        "tests": [
            "testFreshQualifyingMeetingShowsThePostMeetingMirror",
            "testRightRailShowsHealthAndChapters",
        ],
        "sourceAnchors": [
            {
                "path": "Sources/portavoz-app/MeetingHealthView.swift",
                "anchor": '"detail-meeting-health"',
            },
            {
                "path": "Sources/portavoz-app/MirrorCard.swift",
                "anchor": '"mirror-card"',
            },
        ],
    },
    {
        "feature": "speaker-identity",
        "tests": [
            "testNamedSpeakerCanBeRememberedAsCanonicalPerson",
            "testUnnamedSpeakerOffersExplicitNameSuggestions",
        ],
        "sourceAnchors": [
            {
                "path": "Sources/portavoz-app/MeetingDetailView.swift",
                "anchor": '"detail-suggest-names"',
            },
            {
                "path": "Sources/portavoz-app/MeetingDetailView.swift",
                "anchor": '"person-remember-offer"',
            },
        ],
    },
    {
        "feature": "summary-and-structures",
        "tests": [
            "testMostRecentRecipeRemainsVisibleAfterReload",
            "testSequoiaSummaryFailureOpensExactSetupAndExplainsApuntador",
            "testStructureMenuOffersSeededTemplates",
            "testTabbedSummaryRevealsTheCoauthoringBullet",
        ],
        "sourceAnchors": [
            {
                "path": "Sources/portavoz-app/MeetingDetailView.swift",
                "anchor": '"detail-generate-summary"',
            },
            {
                "path": "Sources/portavoz-app/MeetingDetailView.swift",
                "anchor": '"detail-structure-menu"',
            },
        ],
    },
)


class ContractError(ValueError):
    """The Meeting Detail contract is malformed or no longer current."""


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda value: (_ for _ in ()).throw(
                ContractError(f"non-finite JSON value: {value}")
            ),
        )
    except OSError as error:
        raise ContractError(f"cannot read contract: {path}") from error
    except json.JSONDecodeError as error:
        raise ContractError(f"invalid contract JSON: {error.msg}") from error


def exact_object(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be an object")
    actual = set(value)
    if actual != keys:
        missing = sorted(keys - actual)
        unknown = sorted(actual - keys)
        raise ContractError(
            f"{label} keys differ; missing={missing}, unknown={unknown}"
        )
    return value


def string_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise ContractError(f"{label} must be a non-empty string array")
    if not all(isinstance(item, str) and item for item in value):
        raise ContractError(f"{label} must contain non-empty strings")
    if value != sorted(set(value)):
        raise ContractError(f"{label} must be sorted and unique")
    return value


def source_text(root: Path, relative_path: str) -> str:
    path = root / relative_path
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise ContractError(f"cannot read source: {relative_path}") from error


def interaction_signals(root: Path) -> list[dict[str, Any]]:
    observed: Counter[tuple[str, str, str]] = Counter()
    for relative_path in INTERACTION_SOURCE_PATHS:
        for raw_line in source_text(root, relative_path).splitlines():
            line = raw_line.split("//", 1)[0].strip()
            if not line:
                continue
            for category, pattern in SIGNAL_PATTERNS:
                if pattern.search(line):
                    observed[(relative_path, category, line)] += 1
    return [
        {
            "path": path,
            "category": category,
            "source": source,
            "occurrences": occurrences,
        }
        for (path, category, source), occurrences in sorted(observed.items())
    ]


def ui_test_catalog(root: Path) -> dict[str, list[str]]:
    source = source_text(
        root,
        str(UI_TEST_SOURCE.relative_to(REPOSITORY)),
    )
    matches = list(re.finditer(r"^\s*func\s+(test\w+)\s*\(", source, re.MULTILINE))
    if not matches:
        raise ContractError("MeetingDetailUITests contains no test methods")
    catalog: dict[str, list[str]] = {}
    for index, match in enumerate(matches):
        name = match.group(1)
        if name in catalog:
            raise ContractError(f"duplicate UI test method: {name}")
        end = matches[index + 1].start() if index + 1 < len(matches) else len(source)
        body = source[match.start():end]
        screenshots = sorted(
            set(
                re.findall(
                    r'attachScreenshot\([^\n]*named:\s*"([^"]+)"',
                    body,
                )
            )
        )
        catalog[name] = screenshots
    return catalog


def file_sha256(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as error:
        raise ContractError(f"cannot read performance evidence: {path}") from error


def snapshot(root: Path) -> dict[str, Any]:
    catalog = ui_test_catalog(root)
    owners: list[dict[str, Any]] = []
    for raw_owner in DEFAULT_FEATURE_OWNERSHIP:
        tests = sorted(raw_owner["tests"])
        owners.append(
            {
                "feature": raw_owner["feature"],
                "tests": tests,
                "sourceAnchors": sorted(
                    raw_owner["sourceAnchors"],
                    key=lambda item: (item["path"], item["anchor"]),
                ),
                "screenshots": sorted(
                    screenshot
                    for test in tests
                    for screenshot in catalog.get(test, [])
                ),
            }
        )
    return {
        "schemaVersion": 2,
        "kind": "meeting-detail-interaction-baseline",
        "requiredLocales": ["en", "es"],
        "interactionSources": list(INTERACTION_SOURCE_PATHS),
        "interactionSignals": interaction_signals(root),
        "featureOwnership": sorted(owners, key=lambda item: item["feature"]),
        "performanceEvidence": [
            {"path": path, "sha256": file_sha256(root / path)}
            for path in PERFORMANCE_EVIDENCE_PATHS
        ],
        "performanceMeasurementLimitations": list(
            PERFORMANCE_MEASUREMENT_LIMITATIONS
        ),
    }


def validate_contract(raw: Any, root: Path) -> dict[str, Any]:
    contract = exact_object(raw, TOP_LEVEL_KEYS, "contract")
    if contract["schemaVersion"] != 2:
        raise ContractError("unsupported contract schemaVersion")
    if contract["kind"] != "meeting-detail-interaction-baseline":
        raise ContractError("unsupported contract kind")
    if contract["requiredLocales"] != ["en", "es"]:
        raise ContractError("Meeting Detail evidence must cover en and es")
    if contract["interactionSources"] != list(INTERACTION_SOURCE_PATHS):
        raise ContractError("interactionSources do not match the reviewed boundary")
    if contract["performanceMeasurementLimitations"] != list(
        PERFORMANCE_MEASUREMENT_LIMITATIONS
    ):
        raise ContractError(
            "performance measurement limitations were changed or hidden"
        )

    expected_signals = interaction_signals(root)
    signals = contract["interactionSignals"]
    if not isinstance(signals, list) or not signals:
        raise ContractError("interactionSignals must be a non-empty array")
    for index, signal in enumerate(signals):
        item = exact_object(signal, SIGNAL_KEYS, f"interactionSignals[{index}]")
        if item["category"] not in {category for category, _ in SIGNAL_PATTERNS}:
            raise ContractError(f"interactionSignals[{index}] has unknown category")
        if not isinstance(item["occurrences"], int) or isinstance(
            item["occurrences"], bool
        ) or item["occurrences"] < 1:
            raise ContractError(f"interactionSignals[{index}] has invalid occurrences")
        for key in ("path", "source"):
            if not isinstance(item[key], str) or not item[key]:
                raise ContractError(f"interactionSignals[{index}].{key} is invalid")
    if signals != expected_signals:
        raise ContractError("interaction signals differ from the reviewed source baseline")

    catalog = ui_test_catalog(root)
    owners = contract["featureOwnership"]
    if not isinstance(owners, list) or not owners:
        raise ContractError("featureOwnership must be a non-empty array")
    if owners != sorted(owners, key=lambda item: item.get("feature", "")):
        raise ContractError("featureOwnership must be sorted by feature")
    claimed_tests: list[str] = []
    claimed_features: list[str] = []
    for index, owner in enumerate(owners):
        item = exact_object(owner, OWNER_KEYS, f"featureOwnership[{index}]")
        feature = item["feature"]
        if not isinstance(feature, str) or not feature:
            raise ContractError(f"featureOwnership[{index}].feature is invalid")
        claimed_features.append(feature)
        tests = string_list(item["tests"], f"featureOwnership[{index}].tests")
        screenshots = item["screenshots"]
        if not isinstance(screenshots, list) or not all(
            isinstance(name, str) and name for name in screenshots
        ):
            raise ContractError(f"featureOwnership[{index}].screenshots is invalid")
        if screenshots != sorted(set(screenshots)):
            raise ContractError(f"featureOwnership[{index}].screenshots must be sorted and unique")
        expected_screenshots = sorted(
            screenshot for test in tests for screenshot in catalog.get(test, [])
        )
        if screenshots != expected_screenshots:
            raise ContractError(f"featureOwnership[{index}] screenshot ownership differs")
        anchors = item["sourceAnchors"]
        if not isinstance(anchors, list) or not anchors:
            raise ContractError(f"featureOwnership[{index}] needs source anchors")
        if anchors != sorted(anchors, key=lambda value: (value.get("path", ""), value.get("anchor", ""))):
            raise ContractError(f"featureOwnership[{index}].sourceAnchors must be sorted")
        for anchor_index, anchor in enumerate(anchors):
            entry = exact_object(
                anchor,
                ANCHOR_KEYS,
                f"featureOwnership[{index}].sourceAnchors[{anchor_index}]",
            )
            if entry["path"] not in INTERACTION_SOURCE_PATHS:
                raise ContractError("feature source anchor is outside the reviewed boundary")
            if not isinstance(entry["anchor"], str) or not entry["anchor"]:
                raise ContractError("feature source anchor is empty")
            if entry["anchor"] not in source_text(root, entry["path"]):
                raise ContractError(
                    f"feature source anchor is missing: {entry['path']}::{entry['anchor']}"
                )
        claimed_tests.extend(tests)
    if len(claimed_features) != len(set(claimed_features)):
        raise ContractError("featureOwnership repeats a feature")
    duplicate_tests = sorted(
        name for name, count in Counter(claimed_tests).items() if count > 1
    )
    if duplicate_tests:
        raise ContractError(f"UI tests have multiple owners: {duplicate_tests}")
    actual_tests = set(catalog)
    claimed_test_set = set(claimed_tests)
    if claimed_test_set != actual_tests:
        missing = sorted(actual_tests - claimed_test_set)
        unknown = sorted(claimed_test_set - actual_tests)
        raise ContractError(
            f"UI test ownership differs; missing={missing}, unknown={unknown}"
        )

    evidence = contract["performanceEvidence"]
    if not isinstance(evidence, list):
        raise ContractError("performanceEvidence must be an array")
    expected_evidence = []
    for index, raw_evidence in enumerate(evidence):
        item = exact_object(raw_evidence, EVIDENCE_KEYS, f"performanceEvidence[{index}]")
        if not isinstance(item["path"], str) or not isinstance(item["sha256"], str):
            raise ContractError(f"performanceEvidence[{index}] is invalid")
        if re.fullmatch(r"[0-9a-f]{64}", item["sha256"]) is None:
            raise ContractError(f"performanceEvidence[{index}].sha256 is invalid")
        expected_evidence.append(
            {"path": item["path"], "sha256": file_sha256(root / item["path"])}
        )
    if [item["path"] for item in evidence] != list(PERFORMANCE_EVIDENCE_PATHS):
        raise ContractError("performanceEvidence paths do not match the reviewed boundary")
    if evidence != expected_evidence:
        raise ContractError("performance evidence digest changed")
    return contract


def write_snapshot(path: Path, root: Path) -> None:
    document = snapshot(root)
    validate_contract(document, root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(document, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    verify = subparsers.add_parser("verify", help="verify the tracked baseline")
    verify.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    snapshot_parser = subparsers.add_parser(
        "snapshot", help="write a reviewed baseline candidate"
    )
    snapshot_parser.add_argument("--output", type=Path, default=DEFAULT_CONTRACT)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        if arguments.command == "snapshot":
            write_snapshot(arguments.output, REPOSITORY)
            print(arguments.output)
            return 0
        contract = validate_contract(read_json(arguments.contract), REPOSITORY)
        print(
            "Meeting Detail contract verified: "
            f"{len(contract['interactionSignals'])} signals, "
            f"{len(contract['featureOwnership'])} owners, "
            f"{sum(len(owner['tests']) for owner in contract['featureOwnership'])} UI tests."
        )
        return 0
    except ContractError as error:
        print(f"meeting-detail-contract: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
