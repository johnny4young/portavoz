#!/usr/bin/env python3
"""Select the smallest safe Portavoz XCUITest set for a Git diff.

The selector is intentionally conservative: known presentation files map to
feature-level smoke tests, localization and shared composition changes run the
whole bilingual suite, and an unknown production Swift path falls back to the
whole English suite. Documentation, governance, CLI, and package-test-only
changes do not spend a macOS UI runner.
"""

from __future__ import annotations

import argparse
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


TARGET = "PortavozUITests"


def test_id(test_class: str, method: str) -> str:
    return f"{TARGET}/{test_class}/{method}"


FEATURE_TESTS: dict[str, tuple[str, ...]] = {
    "library": (
        test_id("LibraryUITests", "testLibraryRendersRecordButtonAndActionChips"),
        test_id("LibraryUITests", "testSeededMeetingsGroupByRecency"),
    ),
    "meeting-brief": (
        test_id("LibraryUITests", "testUpcomingMeetingBriefShowsRelatedEvidenceAndOpenCommitment"),
    ),
    "recording-recovery": (
        test_id("LibraryUITests", "testRecordingStartFailureOffersTypedRecovery"),
        test_id("LibraryUITests", "testRecordingWarnsWhenRemoteAudioCallbacksStop"),
        test_id("LibraryUITests", "testColdRecordingStartsLiveCaptionsWhenModelBecomesReady"),
        test_id("LibraryUITests", "testLaunchRecoversInterruptedStagingAudio"),
        test_id("LibraryUITests", "testLaunchResumesDurablePostCaptureProcessing"),
    ),
    "ask": (
        test_id("LibraryUITests", "testAskConversationAnswersAndSeeksToExactCitation"),
        test_id("LibraryUITests", "testCommandPaletteSearchAnswerAndCitationSurviveNoStaleState"),
    ),
    "insights": (
        test_id("InsightsUITests", "testInsightsRendersHeatmap"),
        test_id("InsightsUITests", "testInsightsShowsWhoYouTalkWith"),
    ),
    "onboarding": (
        test_id("OnboardingUITests", "testOpensOnTheFirstListenStep"),
        test_id("OnboardingUITests", "testContinueAdvancesPastTheFirstListen"),
        test_id("OnboardingUITests", "testVoiceStepOffersLocalEnrollmentWithoutStartingCapture"),
    ),
    "meeting-performance": (
        test_id("MeetingDetailUITests", "testFiveThousandSegmentDetailRendersFromDisposableScaleFixture"),
    ),
    "meeting-naming": (
        test_id("MeetingDetailUITests", "testExportMenuOffersSubtitleFormats"),
        test_id("MeetingDetailUITests", "testUnnamedSpeakerOffersExplicitNameSuggestions"),
        test_id("MeetingDetailUITests", "testNamedSpeakerCanBeRememberedAsCanonicalPerson"),
    ),
    "meeting-processing": (
        test_id("MeetingDetailUITests", "testFailedDurableProcessingOffersOneRecoveryAction"),
        test_id("MeetingDetailUITests", "testSequoiaSummaryFailureOpensExactSetupAndExplainsApuntador"),
        test_id("MeetingDetailUITests", "testRunningRefineCanBeCanceledWithoutChangingTheTranscript"),
    ),
    "meeting-summary": (
        test_id("MeetingDetailUITests", "testTabbedSummaryRevealsTheCoauthoringBullet"),
        test_id("MeetingDetailUITests", "testMostRecentRecipeRemainsVisibleAfterReload"),
    ),
    "meeting-evidence": (
        test_id("MeetingDetailUITests", "testSummarySourceJumpsToItsTranscriptAndAudio"),
        test_id("MeetingDetailUITests", "testDecisionSourceJumpsToItsTranscriptAndAudio"),
        test_id("MeetingDetailUITests", "testActionItemSourceJumpsToItsTranscriptAndAudio"),
        test_id("MeetingDetailUITests", "testApuntadorAnswerSourceJumpsToItsTranscriptAndAudio"),
        test_id("MeetingDetailUITests", "testSummaryFeedbackIsExplicitReversibleAndLocal"),
    ),
    "meeting-health": (
        test_id("MeetingDetailUITests", "testRightRailShowsHealthAndChapters"),
        test_id("MeetingDetailUITests", "testFreshQualifyingMeetingShowsThePostMeetingMirror"),
    ),
    "meeting-audio": (
        test_id("MeetingDetailUITests", "testSummarySourceJumpsToItsTranscriptAndAudio"),
        test_id("MeetingDetailUITests", "testPlayerExposesSkipAndOnlyMyVoice"),
        test_id("MeetingDetailUITests", "testClipMarkingRevealsExport"),
    ),
    "settings-navigation": (
        test_id("SettingsUITests", "testCategoryNavigationRevealsEachPane"),
        test_id("SettingsUITests", "testLanguageToggleSwitchesVisibleTextWithoutRelaunch"),
    ),
    "settings-data": (
        test_id("SettingsUITests", "testLocalDataLedgerShowsExactCountsAndHonestNetworkPolicy"),
        test_id("SettingsUITests", "testSyncPaneKeepsOptInAndExistingLibrarySeparate"),
        test_id("SettingsUITests", "testDataPaneExportsARedactedLocalSupportFile"),
        test_id("SettingsUITests", "testDataPaneExportsAReadableWholeLibraryMarkdownBackup"),
    ),
    "settings-intelligence": (
        test_id("SettingsUITests", "testIntelligencePaneCreatesACustomStructure"),
    ),
    "settings-audio": (
        test_id("SettingsUITests", "testAudioPaneOffersCaptureSourceControls"),
    ),
    "settings-voice": (
        test_id("SettingsUITests", "testVoicePaneOffersTheMirrorOptIn"),
    ),
}

ALL_TESTS = tuple(dict.fromkeys(test for tests in FEATURE_TESTS.values() for test in tests))
ALL_FEATURES = frozenset(FEATURE_TESTS)
MEETING_FEATURES = frozenset(feature for feature in ALL_FEATURES if feature.startswith("meeting-"))
SETTINGS_FEATURES = frozenset(feature for feature in ALL_FEATURES if feature.startswith("settings-"))
HARNESS_TESTS = (
    test_id("LibraryUITests", "testLibraryRendersRecordButtonAndActionChips"),
    test_id("SettingsUITests", "testCategoryNavigationRevealsEachPane"),
)

NO_UI_PREFIXES = (
    ".design-sync/",
    ".github/ISSUE_TEMPLATE/",
    "Tests/Tooling/",
    "Tests/PortavozTests/",
    "Sources/portavoz-cli/",
    "docs/",
    "site/",
    "packaging/",
)
NO_UI_FILES = {
    ".gitignore",
    ".swiftlint.yml",
    "AGENTS.md",
    "CLAUDE.md",
    "CHANGELOG.md",
    "CODE_OF_CONDUCT.md",
    "CONTRIBUTING.md",
    "LICENSE",
    "README.md",
    "SECURITY.md",
    "Package.resolved",
    "Package.swift",
}


@dataclass(frozen=True)
class Selection:
    tests: tuple[str, ...]
    locales: tuple[str, ...]
    reasons: tuple[str, ...]

    @property
    def required(self) -> bool:
        return bool(self.tests)


def feature_tests(features: Iterable[str]) -> set[str]:
    return {test for feature in features for test in FEATURE_TESTS[feature]}


def tests_for_ui_test_file(path: str) -> set[str]:
    match = re.fullmatch(r"Tests/PortavozUITests/(\w+UITests)\.swift", path)
    if match is None:
        return set()
    prefix = f"{TARGET}/{match.group(1)}/"
    return {test for test in ALL_TESTS if test.startswith(prefix)}


def app_features(filename: str) -> set[str]:
    lowered = filename.lower()
    if any(token in lowered for token in ("l10n", "applanguage")):
        return set(ALL_FEATURES)
    if any(token in lowered for token in ("ask", "commandpalette")):
        return {"ask", "library"}
    if any(token in lowered for token in ("insight",)):
        return {"insights"}
    if any(token in lowered for token in ("onboarding", "firstrun", "firstlisten")):
        return {"onboarding", "settings-voice", "settings-intelligence"}
    if any(token in lowered for token in ("recording", "startrecording", "stoprecording", "postcapture")):
        return {"library", "recording-recovery"}
    if any(token in lowered for token in ("library", "trash", "voicemix")):
        return {"library"}
    if any(token in lowered for token in ("meetingbrief", "meetingreminder")):
        return {"meeting-brief", "library"}
    if any(token in lowered for token in ("focusedtranscript", "meetingplayer", "audioworkflow", "meetingaudio")):
        return {"meeting-audio"}
    if any(token in lowered for token in ("summary", "companion")):
        return {"meeting-summary", "meeting-evidence", "meeting-processing", "settings-intelligence"}
    if any(token in lowered for token in ("speaker", "meetingname", "voicememory")):
        return {"meeting-naming", "meeting-health", "settings-voice"}
    if any(token in lowered for token in ("meetingdetail", "meetinghealth", "mirrorcard", "refine")):
        return set(MEETING_FEATURES)
    if any(token in lowered for token in ("settings", "section", "localdata", "whispermodel", "mlxmodel")):
        return set(SETTINGS_FEATURES)
    return set(ALL_FEATURES)


def lower_layer_features(path: str) -> set[str]:
    lowered = path.lower()
    if "insight" in lowered:
        return {"insights"}
    if any(token in lowered for token in ("ask", "brief")):
        return {"ask", "meeting-brief"}
    if any(token in lowered for token in ("recording", "capture", "postcapture")):
        return {"library", "recording-recovery", "settings-audio"}
    if any(token in lowered for token in ("playback", "waveform", "audio")):
        return {"meeting-audio", "settings-audio"}
    if any(token in lowered for token in ("summary", "companion", "intelligence")):
        return {"meeting-summary", "meeting-evidence", "meeting-processing", "settings-intelligence"}
    if any(token in lowered for token in ("voice", "speaker", "person")):
        return {"meeting-naming", "meeting-health", "settings-voice", "onboarding"}
    if "sync" in lowered:
        return {"settings-data"}
    return set(ALL_FEATURES)


def select_paths(paths: Iterable[str]) -> Selection:
    selected: set[str] = set()
    locales: set[str] = {"en"}
    reasons: list[str] = []

    for raw_path in paths:
        path = raw_path.strip().removeprefix("./")
        if not path:
            continue

        if path == "Resources/Localization/Portavoz/Localizable.xcstrings":
            selected.update(HARNESS_TESTS)
            locales.add("es")
            reasons.append(f"{path}: bilingual localization canaries")
            continue

        if path in {"Makefile", "project.yml", "scripts/run-ui-tests.sh"} or path == "Tests/PortavozUITests/UITestSupport.swift":
            selected.update(HARNESS_TESTS)
            locales.add("es")
            reasons.append(f"{path}: shared UI harness")
            continue

        changed_ui_tests = tests_for_ui_test_file(path)
        if changed_ui_tests:
            selected.update(changed_ui_tests)
            reasons.append(f"{path}: changed UI-test contract")
            continue

        if path.startswith("Sources/portavoz-app/") and path.endswith(".swift"):
            features = app_features(Path(path).name)
            selected.update(feature_tests(features))
            reasons.append(f"{path}: {', '.join(sorted(features))}")
            continue

        if path.startswith("Sources/") and path.endswith(".swift"):
            features = lower_layer_features(path)
            selected.update(feature_tests(features))
            reasons.append(f"{path}: {', '.join(sorted(features))}")
            continue

        if path.startswith(NO_UI_PREFIXES) or path in NO_UI_FILES or path.startswith(".github/") or path.startswith("scripts/"):
            continue

        # Unknown build/configuration changes may alter the executable even if
        # they do not look like a view. Prefer one full English pass to a false
        # claim that UI evidence was unnecessary.
        selected.update(ALL_TESTS)
        reasons.append(f"{path}: unknown executable impact (full fallback)")

    ordered_tests = tuple(test for test in ALL_TESTS if test in selected)
    ordered_locales = tuple(locale for locale in ("en", "es") if locale in locales) if ordered_tests else ()
    return Selection(ordered_tests, ordered_locales, tuple(dict.fromkeys(reasons)))


def changed_paths(base: str, head: str) -> list[str]:
    command = ["git", "diff", "--name-only", "--diff-filter=ACDMRTUXB", base, head, "--"]
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return result.stdout.splitlines()


def working_tree_paths(base: str, *, cwd: Path | None = None) -> list[str]:
    """Return index, working-tree, and untracked paths that differ from base."""
    working_tree = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=ACDMRTUXB", base, "--"],
        check=True,
        capture_output=True,
        text=True,
        cwd=cwd,
    ).stdout.splitlines()
    staged = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACDMRTUXB", base, "--"],
        check=True,
        capture_output=True,
        text=True,
        cwd=cwd,
    ).stdout.splitlines()
    untracked = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard"],
        check=True,
        capture_output=True,
        text=True,
        cwd=cwd,
    ).stdout.splitlines()
    return list(dict.fromkeys((*working_tree, *staged, *untracked)))


def discovered_test_catalog(root: Path) -> set[str]:
    discovered: set[str] = set()
    for source in sorted((root / "Tests/PortavozUITests").glob("*UITests.swift")):
        content = source.read_text(encoding="utf-8")
        class_match = re.search(r"final class\s+(\w+UITests)\s*:", content)
        if class_match is None:
            continue
        for method in re.findall(r"func\s+(test\w+)\s*\(", content):
            discovered.add(test_id(class_match.group(1), method))
    return discovered


def validate_catalog(root: Path) -> None:
    expected = set(ALL_TESTS)
    discovered = discovered_test_catalog(root)
    missing = sorted(discovered - expected)
    stale = sorted(expected - discovered)
    if missing or stale:
        details = []
        if missing:
            details.append("unscoped tests: " + ", ".join(missing))
        if stale:
            details.append("stale selectors: " + ", ".join(stale))
        raise RuntimeError("UI-test scope catalog is stale; " + "; ".join(details))


def render(selection: Selection, output_format: str) -> str:
    tests = " ".join(selection.tests)
    locales = " ".join(selection.locales)
    summary = "; ".join(selection.reasons) if selection.reasons else "no UI-impacting paths"
    if output_format == "github":
        return "\n".join(
            (
                f"required={'true' if selection.required else 'false'}",
                f"tests={tests}",
                f"locales={locales}",
                f"summary={summary}",
            )
        )
    if output_format == "shell":
        return "\n".join(
            (
                f"export UI_TEST_REQUIRED={'true' if selection.required else 'false'}",
                f"export UI_TESTS={shlex.quote(tests)}",
                f"export UI_TEST_LOCALES={shlex.quote(locales)}",
                f"export UI_TEST_SCOPE_SUMMARY={shlex.quote(summary)}",
            )
        )
    if not selection.required:
        return "No UI tests required."
    return (
        f"UI tests: {len(selection.tests)}/{len(ALL_TESTS)}\n"
        f"Locales: {locales}\n"
        f"Selectors:\n  " + "\n  ".join(selection.tests) + f"\nReasons: {summary}"
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("paths", nargs="*", help="Changed paths; otherwise --base and --head are diffed")
    result.add_argument("--base", help="Base Git revision")
    result.add_argument("--head", default="HEAD", help="Head Git revision (default: HEAD)")
    result.add_argument(
        "--working-tree",
        action="store_true",
        help="Compare --base with the current index, working tree, and untracked files",
    )
    result.add_argument("--all", action="store_true", help="Select every UI test in both locales")
    result.add_argument("--format", choices=("human", "github", "shell"), default="human")
    result.add_argument("--validate-catalog", action="store_true", help="Fail if a UI test lacks a selector")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    root = Path(__file__).resolve().parent.parent
    if arguments.validate_catalog:
        validate_catalog(root)
        if not arguments.paths and not arguments.base and not arguments.all:
            print(f"UI-test scope catalog is complete ({len(ALL_TESTS)} tests).")
            return 0

    if arguments.all:
        selection = Selection(ALL_TESTS, ("en", "es"), ("explicit full-suite request",))
    else:
        paths = arguments.paths
        if arguments.working_tree:
            if not arguments.base:
                print("--working-tree requires --base.", file=sys.stderr)
                return 2
            paths = working_tree_paths(arguments.base)
        elif arguments.base:
            paths = changed_paths(arguments.base, arguments.head)
        elif not paths:
            print("Provide changed paths, --base, or --all.", file=sys.stderr)
            return 2
        selection = select_paths(paths)
    print(render(selection, arguments.format))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
