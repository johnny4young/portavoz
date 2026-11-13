#!/usr/bin/env python3
"""Select the smallest safe Portavoz XCUITest set for a Git diff.

Known presentation files map to their feature's tests, an edited UI test to that
method and the tests using an edited helper, and localized copy to the tests quoting
it. Lower-layer Swift and unrecognized app files run the smoke canaries plus any
owner they name; shared harness files add the harness self-test. A path nothing can
map is reported as scope-unknown, never as zero tests. With --budget, a pull request
always runs the canaries, and candidates that do not fit its test budget are cut and
reported for nightly to own. No path selects the complete catalog by itself. Every
selection runs in English only. Documentation, governance, CLI, and
package-test-only changes do not spend a macOS UI runner.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Iterable, Mapping, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ui_test_catalog import (  # noqa: E402
    ALL_FEATURES,
    ALL_TESTS,
    DEPENDENCY_FEATURES,
    FEATURE_SOURCE_SENTINELS,
    FEATURE_TESTS,
    FEATURE_TIERS,
    HARNESS_SELF_TESTS,
    MEETING_DETAIL_EXTRA_JOURNEYS,
    MEETING_FEATURES,
    NIGHTLY_ONLY_TESTS,
    ON_DEMAND_TESTS,
    PR_TESTS,
    RETIRED_DUPLICATE_TESTS,
    SMOKE_TESTS,
    TARGET,
    UI_TEST_BUDGET_SECONDS,
    UI_TEST_OVERHEAD_PER_TEST_SECONDS,
    UI_TEST_OVERHEAD_SECONDS,
    test_id,
)


MAX_SUMMARY_BYTES = 16 * 1024
SWIFT_FUNCTION = re.compile(
    r"^(\s*)(?:@[\w.]+(?:\([^)]*\))?\s+)*"
    r"(?:(?:private|fileprivate|internal|public|package|static|class|final|override|nonisolated|mutating)\s+)*"
    r"func\s+(\w+)")
HUNK = re.compile(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@")
SWIFT_NON_CODE = re.compile(r'"(?:[^"\\]|\\.)*"|//.*$')
# XCTest calls these itself, so no test body names them.
XCTEST_LIFECYCLE = frozenset({"setUp", "setUpWithError", "tearDown", "tearDownWithError"})


# What a change here breaks shows up first in the self-test, and in any journey
# on the nightly run. Tooling tests own the selector and its catalog data.
CONSERVATIVE_TESTS = tuple(dict.fromkeys((*SMOKE_TESTS, *HARNESS_SELF_TESTS)))

# Changes to these shared owners can alter what gets built, measured or accepted
# as UI evidence, without changing product presentation directly.
HARNESS_FILES = frozenset({
    "packaging/portavoz-uitests.entitlements",
    ".github/workflows/ci.yml",
    "Makefile",
    "project.yml",
    "project-ui-runner.yml",
    "scripts/build-ui-host-products.sh",
    "scripts/make-ui-host.sh",
    "scripts/ui_host.py",
    "scripts/ui_test_fit.py",
    "scripts/candidate_automation.py",
    "scripts/check-ui-test-host.py",
    "scripts/check-ui-interruption-safety.py",
    "scripts/check-url-scheme-handlers.sh",
    "scripts/run-ui-tests.sh",
    "scripts/ui_test_ci_gate.py",
    "scripts/ui_test_execution.py",
    "scripts/ui_test_runtime.py",
    "Sources/portavoz-app/UITestWindowPlacement.swift",
    "Sources/portavoz-app/SettingsSkillReceiptNavigation.swift",
    "Tests/PortavozUITests/UITestSupport.swift",
    "Tests/PortavozUITests/UITestSnapshotSupport.swift",
    "Tests/PortavozUITests/PortavozUITestCase.swift",
    "Tests/PortavozUITests/UITestWaitSupport.swift",
    "Tests/PortavozUITests/UITestKeyboardSupport.swift",
    "Tests/PortavozUITests/UITestStorageSupport.swift",
    "Tests/Support/UITestScratch.swift",
    "Tests/Support/UITestActionGeometry.swift",
})

# The native interruption controls compile and qualify only these owners. A
# change here, or anywhere in the fixture target, requires the controls.
INTERRUPTION_CONTROL_FILES = frozenset({
    "packaging/portavoz-uitests.entitlements",
    "scripts/check-ui-interruption-safety.py",
    "scripts/ui_test_execution.py",
    "Tests/PortavozUITests/PortavozUITestCase.swift",
    "Tests/PortavozUITests/UITestKeyboardSupport.swift",
    "Tests/PortavozUITests/UITestStorageSupport.swift",
    "Tests/PortavozUITests/UITestWaitSupport.swift",
    "Tests/Support/UITestScratch.swift",
    "Tests/Support/UITestActionGeometry.swift",
})
INTERRUPTION_FIXTURE_PREFIX = "Tests/UIInterruptionFixtures/"


def requires_interruption_controls(path: str) -> bool:
    return path in INTERRUPTION_CONTROL_FILES or path.startswith(INTERRUPTION_FIXTURE_PREFIX)


# The compact column decides which detail content exists for every journey that
# opens a meeting, including recording input, recovery and Skills.
MEETING_DETAIL_LAYOUT_FEATURES = MEETING_FEATURES | {"live-assist", "recording-recovery", "settings-skills"}


# These owners can change which real Apuntador workloads qualify, but they do
# not build, select, measure, or accept XCUITest itself. Exercise the exact
# user-visible owners reached by the leak matrix instead of paying for every
# unrelated UI journey. Candidate automation stays a harness owner above
# because it validates the UI receipt itself.
APUNTADOR_LEAK_EVIDENCE_FILES = frozenset({
    "Sources/portavoz-app/BenchMode.swift",
    "Sources/portavoz-app/BenchMode+ResourceAsk.swift",
    "Sources/portavoz-app/BenchMode+ResourceIndexing.swift",
    "Sources/portavoz-app/BenchResourceScenarioProbe.swift",
    "scripts/apuntador_leak_baseline.py",
    "scripts/run-apuntador-leak-baseline.sh",
    "docs/evidence/apuntador-leak-baseline.json",
})
NO_UI_PREFIXES = (
    ".design-sync/",
    ".github/ISSUE_TEMPLATE/",
    "Tests/Tooling/",
    "Tests/PortavozKitTests/",
    "Tests/PortavozAppTests/",
    "Tests/DictationPeer/",
    "Tests/PortavozTestSupport/",
    "Sources/portavoz-cli/",
    "Sources/portavoz-cli-main/",
    # Research-only targets: only PortavozKitTests links them, never the app.
    "Sources/CSQLiteVecResearch/",
    "Sources/SQLiteVecResearchKit/",
    "docs/",
    "site/",
    "packaging/",
)
NO_UI_FILES = {
    "Fixtures/DictationValidation/README.md",
    "Fixtures/DictationValidation/public-synthetic-v1.json",
    # Only the headless --bench-live mode and the CLI call it; unit tests own it.
    "Sources/TranscriptionKit/LiveTranscriptionBench.swift",
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
}


# Automatic selection never schedules Spanish; `make test-ui-es` stays a
# manual, non-gating pass and localization parity is a unit-test concern.
SELECTION_LOCALES = ("en",)


@dataclass(frozen=True)
class UITestChange:
    """What a diff touches in one UI test source."""
    functions: frozenset[str]
    outside_functions: bool = False


@dataclass(frozen=True)
class Selection:
    tests: tuple[str, ...]
    locales: tuple[str, ...]
    reasons: tuple[str, ...]
    interruption_controls: bool = False
    scope_unknown: bool = False
    # Lower sorts first when the budget chooses; absent for explicit runs.
    priority: Mapping[str, tuple[int, int]] = field(default_factory=dict, hash=False)
    cut: tuple[str, ...] = ()
    ranked: tuple[str, ...] = ()

    @property
    def required(self) -> bool:
        return bool(self.tests)

    @property
    def deferred_to_nightly(self) -> int:
        """Catalog cases this selection leaves to nightly; zero when it needs no UI."""
        return len(ALL_TESTS) - len(self.tests) if self.tests else 0

    @property
    def interruption_controls_required(self) -> bool:
        return self.interruption_controls


def feature_tests(features: Iterable[str]) -> set[str]:
    return {test for feature in features for test in FEATURE_TESTS[feature]}


def ui_test_class(path: str) -> str | None:
    match = re.fullmatch(r"Tests/PortavozUITests/(\w+UITests)\.swift", path)
    return match.group(1) if match else None


def tests_for_ui_test_file(path: str) -> set[str]:
    """Every test of a changed class within a pull request's reach."""
    name = ui_test_class(path)
    if name is None:
        return set()
    return {test for test in PR_TESTS if test.startswith(f"{TARGET}/{name}/")}


def function_spans(source: str) -> list[tuple[str, int, int]]:
    """Each Swift function's name and 1-based first and last lines, closed by its own indent."""
    lines = source.splitlines()
    spans = []
    for index, line in enumerate(lines):
        match = SWIFT_FUNCTION.match(line)
        if match is None:
            continue
        closing = f"{match.group(1)}}}"
        last = index
        code = SWIFT_NON_CODE.sub("", line)
        if code.count("{") == 0 or code.count("{") != code.count("}"):
            last = next((later for later in range(index + 1, len(lines)) if lines[later].startswith(closing)), index)
        spans.append((match.group(2), index + 1, last + 1))
    return spans


def enclosing_function(spans: Sequence[tuple[str, int, int]], line: int) -> str | None:
    # A nested function belongs to the test around it, which starts first.
    return next((name for name, first, last in spans if first <= line <= last), None)


def ui_test_changes(base: str, head: str | None, root: Path) -> dict[str, UITestChange]:
    """Functions a diff touches per UI test source, and whether it also touches anything else."""
    command = ["git", "diff", "--unified=0", "--no-color", "--no-renames", base]
    if head is not None:
        command.append(head)
    output = subprocess.run([*command, "--", "Tests/PortavozUITests"], check=True, capture_output=True,
                            encoding="utf-8", errors="replace", cwd=root).stdout
    touched: dict[str, list[int]] = {}
    path = None
    for line in output.splitlines():
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
            if path:
                touched[path] = []
        elif path and (hunk := HUNK.match(line)):
            first, count = int(hunk.group(1)), int(hunk.group(2) or 1)
            touched[path].extend(range(first, first + max(count, 1)))
    changes: dict[str, UITestChange] = {}
    for path, numbers in touched.items():
        if head is None:
            source = (root / path).read_text(encoding="utf-8")
        else:
            source = subprocess.run(["git", "show", f"{head}:{path}"], check=True, capture_output=True,
                                    encoding="utf-8", errors="replace", cwd=root).stdout
        spans = function_spans(source)
        names = [enclosing_function(spans, number) for number in numbers]
        changes[path] = UITestChange(frozenset(name for name in names if name), None in names)
    return changes


def tests_using(helpers: set[str], root: Path) -> set[str]:
    """Reachable tests that run one of these helpers: named in a body, directly or through another
    helper, or anywhere XCTest reaches on its own, a lifecycle method or a property, which is the class.
    """
    if not helpers:
        return set()
    bodies: dict[str, str] = {}
    owners: dict[str, str] = {}
    outside: dict[str, str] = {}
    for source in sorted((root / "Tests/PortavozUITests").glob("*.swift")):
        lines = source.read_text(encoding="utf-8").splitlines()
        spans = function_spans("\n".join(lines))
        covered = {number for _, first, last in spans for number in range(first, last + 1)}
        outside[source.stem] = "\n".join(
            line for number, line in enumerate(lines, start=1) if number not in covered)
        for name, first, last in spans:
            key = f"{source.stem}/{name}"
            bodies[key] = "\n".join(lines[first - 1:last])
            owners[key] = name
    reached = set(helpers)
    pending = set(helpers)
    while pending:
        pattern = re.compile(r"\b(?:" + "|".join(map(re.escape, sorted(pending))) + r")\b")
        # A body names itself in its own declaration, which is not a use.
        pending = {owners[key] for key, body in bodies.items()
                   if owners[key] not in reached and pattern.search(body)}
        reached |= pending
    pattern = re.compile(r"\b(?:" + "|".join(map(re.escape, sorted(reached))) + r")\b")
    classes = {stem for stem, text in outside.items() if pattern.search(text)}
    classes |= {key.split("/")[0] for key, name in owners.items() if name in reached & XCTEST_LIFECYCLE}
    return {selector for selector in PR_TESTS
            if owners.get(selector.split("/", 1)[1]) in reached or selector.split("/")[1] in classes}


def app_features(filename: str) -> set[str]:
    lowered = filename.lower()
    if "commandlinetool" in lowered:
        return {"settings-integrations"}
    if "liveassistvalidation" in lowered:
        return {"live-assist"}
    if "backgroundwork" in lowered:
        return {"background-work"}
    if lowered == "uitestfeaturehandshake.swift":
        return {"ask", "settings-skills"}
    if "automationentit" in lowered:
        return {"automation-entry", "commitment-radar"}
    if lowered in {"applaunchmodel.swift", "applaunchrecoveryview.swift"}:
        features = {"launch-recovery", "main-shell"}
        if lowered == "applaunchmodel.swift":
            features.add("background-work")
        return features
    if lowered in {
        "benchmode.swift",
        "benchmode+resourcerefinepreparation.swift",
        "benchresourcelaunchprobe.swift",
        "benchresourceprocesswatchdog.swift",
        "benchresourcescenarioprobe.swift",
    }:
        # These hidden isolated-benchmark owners have no presentation, and unit
        # and disposable Release-app evidence cover their behavior: canaries only.
        return set()
    if lowered.startswith("productionsyncqualification"):
        # The hidden exact-app owner has no presentation and runs only with a
        # disposable shell. Its safe real-app canary is the existing explicit
        # sync opt-in/existing-library Settings journey.
        return {"production-sync"}
    if lowered == "contentview.swift":
        # Root composition changes can affect every destination, but one
        # deterministic canary per route is sufficient; do not rerun all
        # feature permutations merely because a route was added or wired.
        return {"background-work", "main-shell"}
    if lowered == "homeview.swift":
        # Today composes the Library snapshot; its own journeys plus the
        # sidebar canary cover navigation from and back to it.
        return {"home", "library"}
    if lowered in {
        "audioimportqueuemodel.swift", "audioimportqueueview.swift", "audioimportqueuepresentation.swift",
        "libraryimportstatusview.swift", "appservices+audioimportuitestfixture.swift",
    }:
        return {"audio-imports", "library"}
    if lowered == "librarynavigationcontrols.swift":
        return {"home", "library"}
    if lowered in {
        "postcaptureprocessingcoordinator.swift",
        "recordingrecoverycoordinator.swift",
        "semanticcorpusindexingsupervisor.swift",
        "spotlightindexer.swift",
    }:
        return {"background-work"}
    if lowered == "appservices+ask.swift":
        return {"ask", "background-work", "library"}
    if lowered == "portavozappdelegate.swift":
        # The delegate owns external entry routes. Exercise the automation
        # handoff and the exact reminder-to-Radar path without expanding an
        # isolated routing change to every destination behind ContentView.
        return {"automation-entry", "commitment-radar"}
    if lowered == "appservices+meetingsync.swift":
        return {"settings-data"}
    if lowered == "microphoneinputselection.swift":
        return {"dictation", "recording-recovery", "settings-audio"}
    if lowered == "appservices+settingstransfer.swift":
        return {"settings-transfer", "dictation"}
    if lowered in {
        "appportablesettingsstore.swift",
        "portablesettings.swift", "portablesettingstransfer.swift", "portablesettingsfile.swift",
        "settingstransfermodel.swift", "settingstransfersection.swift",
    }:
        return {"settings-transfer"}
    if lowered in {"appservices.swift", "portavozapp.swift"}:
        # Process composition/startup changes need one deterministic canary per
        # route, not every feature permutation behind those destinations.
        return {"background-work", "launch-recovery", "main-shell", "menu-bar-brief", "dictation"}
    if "commitmentreminder" in lowered:
        return {"commitment-radar", "meeting-commitments"}
    if any(token in lowered for token in (
        "commitmentradar",
        "commitmentfieldquality",
        "reminderdraft",
    )):
        return {"commitment-radar"}
    if any(token in lowered for token in ("l10n", "applanguage")):
        # LocalizationTests own the strings; the canaries include the live language switch.
        return set()
    if any(token in lowered for token in ("applespeech", "livespeechselection")):
        return {"dictation", "settings-intelligence", "recording-recovery"}
    if "livetranscriptionattacher" in lowered:
        return {"recording-recovery"}
    if "showcase" in lowered:
        # Screenshot fixtures: their generators run on demand, the canaries cover the launch.
        return set()
    # Dictation owns controller/panel and native delivery journeys, not just
    # the Settings controls. Keep this ahead of generic presentation buckets.
    if any(
        token in lowered
        for token in (
            "dictation", "mousebutton", "mouseptt", "hotkey", "textinserter", "pasteboardsnapshot",
            "selectionrewrite", "selectioncapture",
        )
    ):
        return {"dictation"}
    if "semanticsearchpreparation" in lowered:
        return {"settings-intelligence"}
    if any(token in lowered for token in ("ask", "commandpalette")):
        return {"ask", "library"}
    if any(token in lowered for token in (
        "transcriptcorrection", "transcriptstructuralcorrection"
    )):
        return {"meeting-correction"}
    if any(token in lowered for token in ("insight",)):
        return {"insights"}
    if any(token in lowered for token in ("onboarding", "firstrun", "firstlisten")):
        return {"onboarding", "settings-voice", "settings-intelligence"}
    if "recordingtoolbar" in lowered:
        # This component owns the external-recording geometry contract as
        # well as the live catch-up, next-question, mute, and Stop controls.
        # It does not affect Library grouping or unrelated detail surfaces.
        return {"automation-entry", "recording-interview", "recording-recovery"}
    if "companionsettingssection" in lowered:
        return {"live-assist"}
    if "interviewassist" in lowered:
        return {"recording-interview"}
    if "proactiveassist" in lowered:
        return {"recording-recovery"}
    if any(token in lowered for token in (
        "recording", "startrecording", "stoprecording", "postcapture",
        "livetranslation", "livesummary"
    )):
        return {"library", "recording-interview", "recording-recovery"}
    if any(token in lowered for token in ("library", "trash", "voicemix")):
        return {"library"}
    if "menubar" in lowered:
        return {"menu-bar-brief", "dictation"}
    if any(token in lowered for token in (
        "standingskill", "standingpremeetingbriefsupervisor"
    )):
        return {"settings-standing-skills"}
    if any(token in lowered for token in ("meetingbrief", "meetingreminder")):
        return {"meeting-brief", "library"}
    if any(token in lowered for token in (
        "meetingdetailperformancetrace", "scalebenchmark"
    )):
        return {"meeting-performance"}
    if any(token in lowered for token in ("transcripttranslation", "meetingtranslation")):
        return {"meeting-translation"}
    if "transcriptsegments" in lowered:
        return {
            "meeting-audio", "meeting-correction", "meeting-evidence", "meeting-performance"
        }
    if "meetingtranscriptsection" in lowered:
        return {
            "meeting-audio", "meeting-correction", "meeting-evidence", "meeting-health",
            "meeting-performance",
        }
    if "meetingdetailheadersection" in lowered:
        return {"meeting-export", "meeting-naming", "meeting-processing"}
    if "meetinggenerateddocumentsection" in lowered:
        return {"meeting-correction", "meeting-evidence", "meeting-summary"}
    if "meetingdetailsummaryplaceholder" in lowered:
        return {"meeting-processing", "meeting-summary"}
    if "meetingcommitmentinbox" in lowered:
        return {"meeting-commitments"}
    if any(token in lowered for token in (
        "skillofferbanner", "skillconfirmsheet", "meetingdetailcoordinator+skills"
    )):
        return {"meeting-skills"}
    if "skill" in lowered:
        return {
            "commitment-radar",
            "meeting-skills",
            "menu-bar-brief",
            "settings-skills",
        }
    if "reminderdraft" in lowered:
        return {"commitment-radar"}
    if "meetingdetailtrustsection" in lowered:
        return {"meeting-health", "meeting-processing", "meeting-skills"}
    if "meetingdetailactionsection" in lowered:
        return {"meeting-export", "meeting-processing", "meeting-recap"}
    if "meetingdetailcoordinator+identity" in lowered:
        return {"meeting-naming"}
    if "meetingdetailcoordinator+documents" in lowered:
        return {
            "meeting-correction",
            "meeting-evidence",
            "meeting-export",
            "meeting-processing",
            "meeting-recap",
            "meeting-summary",
        }
    if "meetingdetailcoordinator+commitments" in lowered:
        return {"meeting-commitments"}
    if lowered == "meetingdetailcoordinator.swift":
        return {
            "meeting-audio",
            "meeting-correction",
            "meeting-evidence",
            "meeting-processing",
        }
    if "meetingdetailflowhost" in lowered:
        return {
            "meeting-correction",
            "meeting-export",
            "meeting-health",
            "meeting-naming",
            "meeting-processing",
            "meeting-recap",
            "meeting-summary",
        }
    if "meetingdetailnotessection" in lowered:
        return {"meeting-summary"}
    if "meetingdetailrefinereviewsheet" in lowered:
        return {"meeting-processing"}
    if "meetingdetailplaybacknavigation" in lowered:
        return {"meeting-audio", "meeting-evidence", "meeting-performance"}
    if "meetingdetailrailsection" in lowered:
        return {
            "meeting-correction", "meeting-evidence", "meeting-health", "meeting-processing"
        }
    if "meetingdetailplayersection" in lowered:
        return {"meeting-audio"}
    if "meetingdetailflowstate" in lowered:
        return {
            "meeting-correction",
            "meeting-export",
            "meeting-naming",
            "meeting-processing",
            "meeting-recap",
            "meeting-summary",
        }
    if "focusedtranscript" in lowered:
        return {"meeting-audio", "recording-recovery"}
    if any(token in lowered for token in ("meetingplayer", "audioworkflow", "meetingaudio")):
        return {"meeting-audio"}
    if "exportdocument" in lowered:
        return {"meeting-export"}
    if "appintents" in lowered:
        # Shortcuts itself is another app, but the intent's complete product
        # handoff is the production portavoz://record route. Exercise that
        # one boundary instead of seven unrelated recovery scenarios.
        return {"automation-entry"}
    if "recap" in lowered:
        return {"meeting-recap"}
    if any(token in lowered for token in ("summary", "companion")):
        return {
            "meeting-correction",
            "meeting-summary",
            "meeting-evidence",
            "meeting-processing",
            "settings-intelligence",
        }
    if any(token in lowered for token in ("speaker", "meetingname", "voicememory")):
        return {"meeting-naming", "meeting-health", "settings-voice"}
    if any(token in lowered for token in ("meetingdetail", "meetinghealth", "mirrorcard", "refine")):
        return {"meeting-processing"}
    if lowered == "audiosection.swift":
        return {"settings-audio"}
    if lowered == "settingsvoicesection.swift":
        return {"settings-voice"}
    if any(token in lowered for token in ("settings", "section", "localdata", "whispermodel", "mlxmodel")):
        return {"settings-navigation"}
    return set()


def lower_layer_features(path: str) -> set[str]:
    if path in {
        "Sources/ApplicationKit/PortableSettings.swift",
        "Sources/ApplicationKit/PortableSettingsTransfer.swift",
    }:
        return {"settings-transfer"}
    lowered = path.lower()
    if lowered in {
        "sources/applicationkit/processaudioimports+ownedadapters.swift",
        "sources/applicationkit/audioimportformats.swift",
        "sources/applicationkit/processaudioimports.swift",
        "sources/platformkit/audioimportfiletransfer.swift",
        "sources/platformkit/localaudioimportfiles+acquisition.swift",
        "sources/platformkit/localaudioimportfiles.swift",
        "sources/portavozcore/audioimport.swift",
        "sources/portavozcore/audioimportfiles.swift",
        "sources/portavozcore/audioimportqueue.swift",
        "sources/storagekit/meetingstore+audioimportpublication.swift",
        "sources/storagekit/meetingstore+audioimportqueue.swift",
        "sources/storagekit/meetingstore+audioimports.swift",
        "sources/storagekit/records+audioimport.swift",
        "sources/storagekit/schema+audioimport.swift",
    }:
        # These boundaries own durable import and Library lifecycle behavior,
        # not playback or microphone preferences despite their "audio" names.
        return {"audio-imports", "library"}
    exact_owners = {
        # Shared-store roots affect startup/model preparation, not every
        # feature that happens to consume the stores after composition.
        "sources/modelstorekit/modelstore.swift": {"settings-intelligence"},
        "sources/storagekit/meetingstore.swift": {"launch-recovery", "library"},
        "sources/diarizationkit/voiceprintstore.swift": {
            "meeting-health", "meeting-naming", "onboarding", "settings-voice"
        },
        # These model adapters have one presentation owner each. Their unit
        # tests retain provider/availability coverage; XCUITest owns the real
        # app surface instead of expanding the generic "intelligence" bucket.
        "sources/intelligencekit/briefsynthesizer.swift": {"meeting-brief"},
        "sources/intelligencekit/chaptertitler.swift": {"meeting-naming"},
        "sources/intelligencekit/meetingtypedetector.swift": {"meeting-naming"},
        "sources/intelligencekit/objectivecheck.swift": {"live-assist"},
        "sources/intelligencekit/titlesuggester.swift": {"meeting-naming"},
        # IOS-READY contracts are intentionally dormant. Keep their future
        # continuity and worker-center presentation owners explicit now so a
        # later edit cannot silently fall through to the unknown-scope set.
        "sources/portavozcore/commitmentreplicamerge.swift": {
            "meeting-commitments", "production-sync"
        },
        "sources/portavozcore/deferredmacwork.swift": {"background-work"},
        "sources/integrationskit/cloudkitmeetingsyncplatform.swift": {
            "production-sync"
        },
    }
    if owners := exact_owners.get(lowered):
        return set(owners)
    if any(token in lowered for token in (
        "standingskill", "standingpremeetingbrief"
    )):
        return {"settings-standing-skills"}
    if "livequestionclassifier" in lowered:
        return {"live-assist"}
    if lowered in {
        "sources/intelligencekit/companion.swift",
        "sources/intelligencekit/companiongenerationprovenance.swift",
        "sources/intelligencekit/livequestiondetector.swift",
        "sources/intelligencekit/providerneutralcompanion.swift",
        "sources/intelligencekit/turnendpointpolicy.swift",
    }:
        return {"live-assist"}
    if any(token in lowered for token in (
        "processsemanticcorpusmaintenance",
        "processmeetingmemorygraphmaintenance",
        "recoverinterruptedmeetings",
        "derivedmaintenance",
    )):
        return {"background-work"}
    if "proactivemeetingassist" in lowered:
        # The deterministic policy is rendered only by the consolidated live-
        # assist journey; it has no model, Settings, detail, or Library route.
        return {"recording-recovery"}
    if any(token in lowered for token in (
        "asknotes",
        "localasknote",
        "contextitemsearch",
        "meetingstore+notesearch",
    )):
        # Typed raw-note Ask has one consolidated real-app journey. Keep its
        # storage/index and orchestration files from paying for unrelated UI.
        return {"ask"}
    if any(token in lowered for token in (
        "numberedcitationanswer",
        "ragtextanswering",
        "raganswerer",
    )):
        # The shared cited-prose/provider authority is consumed by manual Ask
        # and live Interview Assist, but not every intelligence-backed screen.
        return {"ask", "recording-interview"}
    if "interview" in lowered:
        return {"recording-interview"}
    if "loadcommitmentblockers" in lowered:
        return {"ask"}
    if "decisionrelationship" in lowered:
        return {"ask"}
    if "topicfirstdiscussion" in lowered:
        return {"ask"}
    if "confirmedtopiccatalog" in lowered:
        return {"ask"}
    if "semanticsearchassetpreparation" in lowered:
        return {"settings-intelligence"}
    if "automationentit" in lowered:
        return {"automation-entry", "commitment-radar"}
    if "launchrecovery" in lowered:
        return {"launch-recovery"}
    if "skill" in lowered:
        return {
            "commitment-radar",
            "meeting-skills",
            "menu-bar-brief",
            "settings-skills",
        }
    if "reminderdraft" in lowered:
        return {"commitment-radar"}
    if "commitmentradar" in lowered or "commitmentfieldquality" in lowered:
        return {"commitment-radar"}
    if any(token in lowered for token in (
        "managemeetingcommitmentinbox",
        "meetingcommitmentinbox",
    )):
        return {"meeting-commitments"}
    if lowered in {
        "sources/applicationkit/correctmeetingtranscript.swift",
        "sources/applicationkit/meetingtranscriptgenerationmaterial.swift",
        "sources/applicationkit/restructuremeetingtranscript.swift",
        "sources/portavozcore/transcriptcorrection.swift",
        "sources/portavozcore/transcriptcorrectionrevision.swift",
        "sources/storagekit/meetingstore+transcriptcorrections.swift",
        "sources/storagekit/meetingstore+transcriptprojection.swift",
        "sources/storagekit/schema+transcriptcorrection.swift",
        "sources/storagekit/transcriptcorrectionrecords.swift",
    }:
        return {"meeting-correction"}
    if lowered in {
        "sources/applicationkit/meetingdetailreadmodels.swift",
        "sources/storagekit/meetingstore+meetingdetailobservation.swift",
    }:
        return set(MEETING_FEATURES)
    if lowered == "sources/applicationkit/composetranscript.swift":
        return {"meeting-correction"}
    if "meetingtranscriptcontent" in lowered:
        return {
            "meeting-audio", "meeting-evidence", "meeting-health", "meeting-performance"
        }
    if "meetinggenerateddocumentpresentation" in lowered:
        return {"meeting-evidence", "meeting-summary"}
    if "queryexpander" in lowered:
        # Deterministic query variants feed only Library search, full Ask,
        # and the meeting-brief evidence lookup. Keep a lexicon-only change
        # from expanding to every unrelated app surface.
        return {"ask", "library", "meeting-brief"}
    if "micbleed" in lowered:
        # Bleed admission affects live captions and the reviewed Refine
        # replacement, not every unrelated screen in the application.
        return {"recording-recovery", "meeting-processing"}
    if "stoprecording" in lowered or "startrecording" in lowered:
        return {"library", "recording-recovery"}
    if any(token in lowered for token in ("dictation", "mouseptt")):
        return {"dictation"}
    if "subtitle" in lowered:
        return {"meeting-export"}
    if "recap" in lowered:
        return {"meeting-recap"}
    if "insight" in lowered:
        return {"insights"}
    if any(token in lowered for token in ("ask", "brief")):
        return {"ask", "meeting-brief", "menu-bar-brief"}
    if any(token in lowered for token in ("recording", "capture", "postcapture")):
        return {"library", "recording-recovery", "settings-audio"}
    if any(token in lowered for token in ("playback", "waveform", "audio")):
        return {"meeting-audio", "settings-audio"}
    if "companion" in lowered:
        return {"ask", "meeting-correction", "meeting-processing"}
    if any(token in lowered for token in ("summary", "summaries", "intelligence")):
        return {"ask", "meeting-processing"}
    if any(token in lowered for token in ("voice", "speaker", "person")):
        return {"meeting-naming", "meeting-health", "settings-voice", "onboarding"}
    if "sync" in lowered:
        return {"settings-data"}
    # No proven owner: unit tests own the behavior and the smoke canaries
    # cover the shell; the nightly run owns the complete catalog.
    return set()


CATALOG = "Resources/Localization/Portavoz/Localizable.xcstrings"
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l)?[@dfsuxXeEgGc]|%#@\w+@|%%")
SHIPPED_STATES = {None, "translated", "needs_review"}


def catalog_english(text: str) -> dict[str, str | None]:
    """English copy as Xcode compiles it into the UI test app.

    An empty value stays empty and a missing one shows the key. None marks
    plural, substitution or unshipped entries, which report an unknown scope.
    """
    catalog = json.loads(text)
    if not isinstance(catalog, dict) or not isinstance(catalog.get("strings"), dict):
        raise ValueError("Invalid string catalog")
    values: dict[str, str | None] = {}
    for key, entry in catalog["strings"].items():
        english = entry
        for field in ("localizations", "en"):
            if not isinstance(english, dict):
                raise ValueError("Invalid English localization")
            english = english.get(field, {})
        if not isinstance(english, dict):
            raise ValueError("Invalid English localization")
        if "variations" in english or "substitutions" in english:
            values[key] = None
            continue
        unit = english.get("stringUnit", {})
        if not isinstance(unit, dict):
            raise ValueError("Invalid English string unit")
        value = unit.get("value")
        if value is not None and not isinstance(value, str):
            raise ValueError("Invalid English string value")
        values[key] = None if unit.get("state") not in SHIPPED_STATES else key if value is None else value
    return values


def swift_literal(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def copy_tests(changed_keys: Iterable[str], root: Path) -> set[str]:
    """Reachable tests that quote a changed English string or a long literal part of it."""
    needles = set()
    for key in changed_keys:
        parts = [swift_literal(part.strip()) for part in PLACEHOLDER.split(key) if len(part.strip()) >= 12]
        needles.update(parts or [f'"{swift_literal(key)}"'])
    selected: set[str] = set()
    helpers: set[str] = set()
    for source in sorted((root / "Tests/PortavozUITests").glob("*UITests.swift")):
        text = source.read_text(encoding="utf-8")
        spans = function_spans(text)
        for number, line in enumerate(text.splitlines(), start=1):
            if not any(needle in line for needle in needles):
                continue
            name = enclosing_function(spans, number)
            selector = test_id(source.stem, name) if name else None
            if name is None:
                selected |= tests_for_ui_test_file(source.relative_to(root).as_posix())
            elif selector in PR_TESTS:
                selected.add(selector)
            elif not name.startswith("test"):
                helpers.add(name)
    return selected | tests_using(helpers, root)


def select_paths(
    paths: Iterable[str],
    catalog_changes: set[str] | None = None,
    root: Path | None = None,
    dependency_changes: set[str] | None = None,
    ui_changes: Mapping[str, UITestChange] | None = None,
) -> Selection:
    selected: collections.Counter[str] = collections.Counter()
    first: set[str] = set()
    consumers: set[str] = set()
    reasons: list[str] = []
    interruption_controls = False
    scope_unknown = False

    def unknown(reason: str) -> None:
        nonlocal scope_unknown
        scope_unknown = True
        selected.update(CONSERVATIVE_TESTS)
        first.update(HARNESS_SELF_TESTS)
        reasons.append(f"scope-unknown: {reason}")

    def helpers_changed(path: str) -> bool:
        """Whether every edited helper was traced to a test or there was nothing to trace."""
        change = (ui_changes or {}).get(path)
        names = {name for name in change.functions if not name.startswith("test")} if change else set()
        found = tests_using(names, root or Path(__file__).resolve().parent.parent) if names else set()
        consumers.update(found)
        return bool(found) or not names

    for raw_path in paths:
        path = raw_path.strip().removeprefix("./")
        if not path:
            continue
        # Independent of whichever product selection branch handles the path.
        interruption_controls = interruption_controls or requires_interruption_controls(path)

        if path == "Package.resolved":
            selected.update(SMOKE_TESTS)
            if dependency_changes is None:
                unknown(f"{path}: changed pins unknown")
                continue
            unmapped = sorted(dependency_changes - DEPENDENCY_FEATURES.keys())
            if unmapped:
                unknown(f"{path}: no owner for {', '.join(unmapped)}")
            owned = sorted(dependency_changes & DEPENDENCY_FEATURES.keys())
            selected.update(feature_tests(
                feature for dependency in owned for feature in DEPENDENCY_FEATURES[dependency]))
            reasons.append(f"{path}: canaries and owners of {', '.join(owned) or 'no changed pin'}")
            continue

        if path == "Package.swift":
            unknown(f"{path}: a manifest change has no known owner")
            continue

        if path == CATALOG:
            if catalog_changes is None:
                unknown(f"{path}: changed keys unknown")
                continue
            # Journeys assert English copy literally; Spanish values belong to LocalizationTests.
            if catalog_changes:
                selected.update(copy_tests(catalog_changes, root or Path(__file__).resolve().parent.parent))
                selected.update(SMOKE_TESTS)
                reasons.append(f"{path}: journeys quoting {len(catalog_changes)} changed English strings")
            continue

        if path in HARNESS_FILES or path.startswith(INTERRUPTION_FIXTURE_PREFIX):
            selected.update(CONSERVATIVE_TESTS)
            first.update(HARNESS_SELF_TESTS)
            helpers_changed(path)
            # A production file in the harness still owes its own journeys.
            if path.startswith("Sources/portavoz-app/"):
                selected.update(feature_tests(app_features(Path(path).name)))
            reasons.append(f"{path}: canaries and harness self-test")
            continue

        if path == "Sources/portavoz-app/MeetingDetailPrimaryColumn.swift":
            selected.update(feature_tests(MEETING_DETAIL_LAYOUT_FEATURES))
            selected.update(test for test in MEETING_DETAIL_EXTRA_JOURNEYS if test in PR_TESTS)
            reasons.append(f"{path}: journeys that open a meeting")
            continue

        if path in APUNTADOR_LEAK_EVIDENCE_FILES:
            selected.update(SMOKE_TESTS)
            reasons.append(f"{path}: benchmark owner, canaries only")
            continue

        if path in {
            "Fixtures/ApuntadorWeb/public-local-v1.json",
            "Tests/PortavozUITests/ApuntadorWebFixtureSupport.swift",
        }:
            selected.update([test_id("LibraryUITests", "testAskConversationAnswersAndSeeksToExactCitation")])
            reasons.append(
                f"{path}: deterministic Web Ask journey"
            )
            continue

        if path in {
            "Fixtures/LiveAssistValidation/public-bilingual-v1.json",
            "docs/evidence/live-assist-validation-budget.json",
        }:
            selected.update(feature_tests({"live-assist"}))
            reasons.append(
                f"{path}: live-assistance evidence journey"
            )
            continue

        if path == "Tests/Support/MeetingBundleFixture.swift":
            selected.update(feature_tests({"audio-imports"}))
            reasons.append(f"{path}: audio-imports")
            continue

        if path.startswith("Tests/PortavozDictationReceiver/"):
            selected.update(feature_tests({"dictation"}))
            reasons.append(f"{path}: native dictation receiver contract")
            continue

        if path == "Tests/PortavozUITests/FeatureUITestHandshakeSupport.swift":
            selected.update(feature_tests({"ask", "settings-skills"}))
            reasons.append(f"{path}: Ask and Skills handshake contracts")
            continue

        name = ui_test_class(path)
        change = (ui_changes or {}).get(path)
        if name is not None and change is not None:
            methods = {test_id(name, method) for method in change.functions if method.startswith("test")}
            # An edited nightly-only method runs: its author is the one who needs the answer.
            first.update(methods & set(ALL_TESTS))
            selected.update(methods & set(ALL_TESTS))
            selected.update(SMOKE_TESTS)
            traced = helpers_changed(path)
            reasons.append(f"{path}: {len(methods)} edited methods, helper consumers and canaries")
            if methods - set(ALL_TESTS):
                reasons.append(f"{path}: edited methods outside the catalog's runs need their own run")
            if traced and not change.outside_functions and not change.functions & XCTEST_LIFECYCLE:
                continue
        changed_ui_tests = tests_for_ui_test_file(path)
        if changed_ui_tests:
            first.update(changed_ui_tests)
            selected.update(changed_ui_tests)
            selected.update(SMOKE_TESTS)
            reasons.append(f"{path}: changed UI-test contract and canaries")
            continue

        if path.startswith("Sources/portavoz-app/") and path.endswith(".swift"):
            file_name = Path(path).name
            if file_name in {
                "AppServices+UITestFixtures.swift",
                "AppServices+LiveAssistUITestFixture.swift",
                "AppServices+StorageComposition.swift",
                "AppServices+AskTopicMemoryUITestFixture.swift",
                "UITestDefaults.swift",
            }:
                unknown(f"{path}: a seed fixture has no known owner")
                continue
            features = app_features(file_name)
            if not features:
                selected.update(SMOKE_TESTS)
                reasons.append(f"{path}: unmapped app file smoke canaries")
                continue
            selected.update(feature_tests(features))
            reasons.append(f"{path}: {', '.join(sorted(features))}")
            continue

        # CLI and reviewed test-only corpus paths cannot alter the app UI.
        # Check them before generic Sources/*.swift, which would otherwise
        # spend smoke canaries on CLI.swift.
        if path.startswith(NO_UI_PREFIXES) or path in NO_UI_FILES or path.startswith(".github/") or path.startswith("scripts/"):
            continue

        if path.startswith("Sources/") and path.endswith(".swift"):
            features = lower_layer_features(path)
            if not features:
                selected.update(SMOKE_TESTS)
                reasons.append(f"{path}: lower-layer smoke canaries")
                continue
            selected.update(feature_tests(features))
            reasons.append(f"{path}: {', '.join(sorted(features))}")
            continue

        if path.startswith("Sources/") and not path.startswith("Sources/portavoz-app/"):
            # A lower-layer resource selects its owner's journeys; an unknown one falls through.
            features = lower_layer_features(path)
            if features:
                selected.update(feature_tests(features))
                reasons.append(f"{path}: {', '.join(sorted(features))}")
                continue

        # Unknown build/configuration changes may alter the executable even if
        # they do not look like a view, so they are never a claim of no UI impact.
        unknown(f"{path}: unknown executable impact")

    selected.update(consumers)
    ordered_tests = tuple(test for test in ALL_TESTS if test in selected)

    def rank(test: str) -> int:
        return 0 if test in first else 1 if test in consumers else 2

    return Selection(
        ordered_tests,
        SELECTION_LOCALES if ordered_tests else (),
        tuple(dict.fromkeys(reasons)),
        interruption_controls=interruption_controls,
        scope_unknown=scope_unknown,
        priority={test: (rank(test), -selected[test]) for test in ordered_tests},
    )


def hosted_seconds(root: Path) -> dict[str, float]:
    """Observed hosted p90 per case; a case no night has timed yet counts at its ceiling."""
    ceilings = json.loads((root / "docs/evidence/ui-test-runtime-budget.json").read_text(encoding="utf-8"))
    hosted = json.loads((root / "docs/evidence/ui-test-hosted-seconds.json").read_text(encoding="utf-8"))
    return {**ceilings["testBudgetsSeconds"], **hosted["hostedSeconds"]}


def feature_tier(test: str) -> int:
    return min((FEATURE_TIERS.get(feature, 2) for feature, tests in FEATURE_TESTS.items() if test in tests), default=2)


def case_seconds(test: str, seconds: Mapping[str, float]) -> float:
    return seconds[runtime_budget_key(test)] + UI_TEST_OVERHEAD_PER_TEST_SECONDS


def require_canaries_fit(seconds: Mapping[str, float], budget: float) -> None:
    """Emptying the canaries would prove nothing, so a budget they exceed is an error."""
    used = UI_TEST_OVERHEAD_SECONDS + sum(case_seconds(test, seconds) for test in SMOKE_TESTS)
    if used > budget:
        raise ValueError(f"the canaries need {used:.0f} s against a budget of {budget:.0f} s")


def ranked_candidates(selection: Selection, seconds: Mapping[str, float]) -> tuple[str, ...]:
    return tuple(sorted(
        (test for test in selection.tests if test not in SMOKE_TESTS),
        key=lambda test: (*selection.priority.get(test, (2, 0)), feature_tier(test), case_seconds(test, seconds), test)))


def fit_ranked(tests: Sequence[str], ranked: Sequence[str], seconds: Mapping[str, float],
               budget: float) -> tuple[tuple[str, ...], tuple[str, ...]]:
    """What runs and what waits for nightly. Anything unranked runs however late the build ended."""
    chosen = [test for test in tests if test not in ranked]
    used = UI_TEST_OVERHEAD_SECONDS + sum(case_seconds(test, seconds) for test in chosen)
    cut = []
    for test in ranked:
        if used + case_seconds(test, seconds) <= budget:
            chosen.append(test)
            used += case_seconds(test, seconds)
        else:
            cut.append(test)
    return tuple(test for test in ALL_TESTS if test in chosen), tuple(cut)


def rank_for_job(selection: Selection, seconds: Mapping[str, float]) -> Selection:
    """Name the canaries and every candidate; the job fits them once its build has ended."""
    if not selection.tests:
        return selection
    require_canaries_fit(seconds, UI_TEST_BUDGET_SECONDS)
    chosen = {*SMOKE_TESTS, *selection.tests}
    return replace(selection, tests=tuple(test for test in ALL_TESTS if test in chosen),
                   ranked=ranked_candidates(selection, seconds))


def apply_budget(selection: Selection, seconds: Mapping[str, float], budget: float = UI_TEST_BUDGET_SECONDS) -> Selection:
    """Keep the canaries and the best candidates that fit; the rest wait for nightly, never vanish."""
    if not selection.tests:
        return selection
    require_canaries_fit(seconds, budget)
    ranked = ranked_candidates(selection, seconds)
    tests, cut = fit_ranked((*SMOKE_TESTS, *ranked), ranked, seconds, budget)
    return replace(selection, tests=tests, cut=cut)


# The branch a stack finally enters.
DEFAULT_BRANCH_REF = "refs/remotes/origin/main"


def merge_root(first: str, second: str) -> str:
    """Their one merge base. Criss-cross history uses the roots' common ancestor, which only widens selection."""
    def lines(*arguments: str) -> list[str]:
        return subprocess.run(["git", "merge-base", *arguments], check=True, capture_output=True, text=True,
                              timeout=10).stdout.splitlines()
    roots = lines("--all", first, second)
    if len(roots) > 1:
        roots = lines("--octopus", *roots)
    if len(roots) != 1:
        raise ValueError(f"no single merge base between {first} and {second}")
    return roots[0]


def stacked_selection(own: Selection, cumulative: Selection) -> Selection:
    """Everything entering main is a candidate, and what this pull request changed ranks first."""
    chosen = {*own.tests, *cumulative.tests}
    later = {test: (rank + 3, weight) for test, (rank, weight) in cumulative.priority.items()}
    return replace(
        cumulative,
        tests=tuple(test for test in ALL_TESTS if test in chosen),
        locales=SELECTION_LOCALES if chosen else (),
        reasons=tuple(dict.fromkeys((*own.reasons, *cumulative.reasons))),
        interruption_controls=own.interruption_controls or cumulative.interruption_controls,
        scope_unknown=own.scope_unknown or cumulative.scope_unknown,
        priority={**later, **own.priority},
    )


def changed_paths(base: str, head: str) -> list[str]:
    command = ["git", "diff", "--name-only", "--diff-filter=ACDMRTUXB", base, head, "--"]
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return result.stdout.splitlines()


def catalog_changes(base: str, head: str | None, root: Path) -> set[str] | None:
    """Changed keys and old/new effective English copy; None means unreadable."""
    try:
        before = subprocess.run(["git", "show", f"{base}:{CATALOG}"], check=True, capture_output=True,
                                text=True, cwd=root).stdout
        if head is None:
            after = (root / CATALOG).read_text(encoding="utf-8")
        else:
            after = subprocess.run(["git", "show", f"{head}:{CATALOG}"], check=True, capture_output=True,
                                   text=True, cwd=root).stdout
        old_values, new_values = catalog_english(before), catalog_english(after)
        changed: set[str] = set()
        for key in old_values.keys() | new_values.keys():
            sides = [values[key] for values in (old_values, new_values) if key in values]
            if len(sides) == 2 and sides[0] == sides[1]:
                continue
            if None in sides:
                return None
            changed.add(key)
            changed.update(value for value in sides if value)
        return changed
    except (OSError, ValueError, subprocess.CalledProcessError):
        return None


def resolved_pins(text: str) -> dict[str, str]:
    pins = json.loads(text)["pins"]
    return {pin["identity"]: pin["state"]["revision"] for pin in pins}


def dependency_changes(base: str, head: str | None, root: Path) -> set[str] | None:
    """Pins added, removed or moved between two locks; None means unreadable."""
    try:
        before = subprocess.run(["git", "show", f"{base}:Package.resolved"], check=True, capture_output=True,
                                text=True, cwd=root).stdout
        if head is None:
            after = (root / "Package.resolved").read_text(encoding="utf-8")
        else:
            after = subprocess.run(["git", "show", f"{head}:Package.resolved"], check=True, capture_output=True,
                                   text=True, cwd=root).stdout
        old_pins, new_pins = resolved_pins(before), resolved_pins(after)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
        return None
    return {name for name in old_pins.keys() | new_pins.keys() if old_pins.get(name) != new_pins.get(name)}


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


def validate_catalog(root: Path, *, runtime_budget_required: bool = True) -> None:
    expected = set(ALL_TESTS) | set(ON_DEMAND_TESTS)
    discovered = discovered_test_catalog(root)
    missing = sorted(discovered - expected)
    stale = sorted(expected - discovered)
    duplicates = sorted(
        feature
        for feature, tests in FEATURE_TESTS.items()
        if len(tests) != len(set(tests))
    )
    empty_scopes = sorted(
        feature for feature, tests in FEATURE_TESTS.items() if not tests
    )
    retired = sorted(discovered & RETIRED_DUPLICATE_TESTS)
    on_demand_overlap = sorted(set(ALL_TESTS) & set(ON_DEMAND_TESTS))
    smoke_errors = sorted((set(SMOKE_TESTS) | set(HARNESS_SELF_TESTS)) - set(ALL_TESTS))
    smoke_errors += sorted(set(SMOKE_TESTS) & set(NIGHTLY_ONLY_TESTS))
    tier_errors = sorted(FEATURE_TIERS.keys() - ALL_FEATURES)
    if len(SMOKE_TESTS) != len(set(SMOKE_TESTS)):
        smoke_errors.append("duplicate smoke canary")
    lock = root / "Package.resolved"
    pins = set(resolved_pins(lock.read_text(encoding="utf-8"))) if lock.is_file() else set(DEPENDENCY_FEATURES)
    dependency_errors = sorted(DEPENDENCY_FEATURES.keys() - pins)
    dependency_errors += sorted(
        feature for features in DEPENDENCY_FEATURES.values() for feature in features - ALL_FEATURES)
    sentinel_mismatch = sorted(ALL_FEATURES ^ FEATURE_SOURCE_SENTINELS.keys())
    orphan_scopes: list[str] = []
    for feature, path in FEATURE_SOURCE_SENTINELS.items():
        source = root / path
        if not source.is_file():
            orphan_scopes.append(f"{feature} (missing {path})")
            continue
        mapped = app_features(source.name)
        if feature not in mapped:
            orphan_scopes.append(f"{feature} ({path})")

    # A no-UI fixture must stay unreachable from the app and its UI tests.
    no_ui_fixture_dirs = sorted({
        path.rsplit("/", 1)[0] for path in NO_UI_FILES if path.startswith("Fixtures/")
    })
    reachable_fixtures: list[str] = []
    for tree in ("Sources", "Tests/PortavozUITests"):
        for source in sorted((root / tree).rglob("*.swift")):
            if source.relative_to(root).as_posix().startswith(NO_UI_PREFIXES):
                continue
            text = source.read_text(encoding="utf-8")
            for directory in no_ui_fixture_dirs:
                if directory.split("/", 1)[1] in text:
                    reachable_fixtures.append(f"{directory} ({source.relative_to(root)})")

    runtime_budget_errors: list[str] = []
    if runtime_budget_required:
        budget_path = root / "docs/evidence/ui-test-runtime-budget.json"
        if not budget_path.is_file():
            runtime_budget_errors.append(f"missing {budget_path.relative_to(root)}")
        else:
            budget = json.loads(budget_path.read_text(encoding="utf-8"))
            runtime_ids = set(budget.get("testBudgetsSeconds", {}))
            expected_runtime_ids = {runtime_budget_key(selector) for selector in ALL_TESTS}
            missing_budgets = sorted(expected_runtime_ids - runtime_ids)
            stale_budgets = sorted(runtime_ids - expected_runtime_ids)
            budget_count = budget.get("catalog", {}).get("expectedCaseCount")
            if missing_budgets:
                runtime_budget_errors.append(
                    "tests without runtime budget: " + ", ".join(missing_budgets)
                )
            if stale_budgets:
                runtime_budget_errors.append(
                    "stale runtime budgets: " + ", ".join(stale_budgets)
                )
            if budget_count != len(ALL_TESTS):
                runtime_budget_errors.append(
                    f"runtime budget count {budget_count!r} != {len(ALL_TESTS)}"
                )
            if (total_error := full_suite_total_error(budget, len(ALL_TESTS))) is not None:
                runtime_budget_errors.append(total_error)

        on_demand_path = root / "docs/evidence/ui-test-on-demand-runtime-budget.json"
        on_demand_ids = (
            set(json.loads(on_demand_path.read_text(encoding="utf-8")).get("testBudgetsSeconds", {}))
            if on_demand_path.is_file() else set())
        if on_demand_ids != {runtime_budget_key(selector) for selector in ON_DEMAND_TESTS}:
            runtime_budget_errors.append("on-demand runtime budgets do not match their catalog")

    if (
        missing
        or stale
        or duplicates
        or empty_scopes
        or retired
        or on_demand_overlap
        or sentinel_mismatch
        or orphan_scopes
        or reachable_fixtures
        or runtime_budget_errors
        or smoke_errors
        or tier_errors
        or dependency_errors
    ):
        details = []
        if missing:
            details.append("unscoped tests: " + ", ".join(missing))
        if stale:
            details.append("stale selectors: " + ", ".join(stale))
        if duplicates:
            details.append("duplicate selectors inside scopes: " + ", ".join(duplicates))
        if empty_scopes:
            details.append("empty feature scopes: " + ", ".join(empty_scopes))
        if retired:
            details.append("known duplicate tests returned: " + ", ".join(retired))
        if on_demand_overlap:
            details.append("on-demand tests in hosted catalog: " + ", ".join(on_demand_overlap))
        if sentinel_mismatch:
            details.append("feature/source sentinel mismatch: " + ", ".join(sentinel_mismatch))
        if orphan_scopes:
            details.append("orphan feature scopes: " + ", ".join(orphan_scopes))
        if reachable_fixtures:
            details.append("no-UI fixtures reachable from UI sources: " + ", ".join(reachable_fixtures))
        details.extend(runtime_budget_errors)
        if tier_errors:
            details.append("tiers for features that do not exist: " + ", ".join(tier_errors))
        if smoke_errors:
            details.append("smoke canaries outside the catalog: " + ", ".join(smoke_errors))
        if dependency_errors:
            details.append("dependency owners that do not exist: " + ", ".join(dependency_errors))
        raise RuntimeError("UI-test scope catalog is stale; " + "; ".join(details))


def runtime_budget_key(selector: str) -> str:
    return "/".join(selector.split("/")[1:]) + "()"


def full_suite_total_error(budget: dict, case_count: int) -> str | None:
    """A fixed aggregate goes stale as journeys are added; it must cover the qualified per-case rate."""
    qualified = budget.get("qualifiedCandidate", {})
    rate = qualified.get("englishTestDurationSeconds", 0) / max(qualified.get("caseCount", 0), 1)
    total = budget.get("fullSuite", {}).get("maximumTestDurationSecondsPerLocale", 0)
    required = case_count * rate
    if total < required:
        return f"full-suite total {total}s is below {case_count} cases at the qualified {rate:.2f}s per case ({required:.0f}s)"
    return None


def shard_tests(root: Path, index: int, count: int) -> tuple[str, ...]:
    """Split the catalog into balanced shards by runtime budget, longest first."""
    if not 1 <= index <= count:
        raise ValueError("a shard must be K/N with 1 <= K <= N")
    budgets = json.loads((root / "docs/evidence/ui-test-runtime-budget.json").read_text(encoding="utf-8"))
    seconds = budgets["testBudgetsSeconds"]
    missing = [test for test in ALL_TESTS if runtime_budget_key(test) not in seconds]
    if missing:
        raise ValueError("tests without runtime budget: " + ", ".join(missing))
    loads = [0.0] * count
    owners: dict[str, int] = {}
    for test in sorted(ALL_TESTS, key=lambda selector: (-seconds[runtime_budget_key(selector)], selector)):
        shard = min(range(count), key=lambda candidate: (loads[candidate], candidate))
        owners[test] = shard
        loads[shard] += seconds[runtime_budget_key(test)]
    return tuple(test for test in ALL_TESTS if owners[test] == index - 1)


def bounded_summary(reasons: Sequence[str]) -> str:
    if not reasons:
        return "no UI-impacting paths"
    full_summary = "; ".join(reasons)
    if len(full_summary.encode("utf-8")) <= MAX_SUMMARY_BYTES:
        return full_summary

    digest = hashlib.sha256(full_summary.encode("utf-8")).hexdigest()
    kept: list[str] = []
    for reason in reasons:
        candidate = kept + [reason]
        omitted = len(reasons) - len(candidate)
        suffix = (
            f"; ... {omitted} additional reason"
            f"{'s' if omitted != 1 else ''} omitted"
            f"; full-summary-sha256={digest}"
        )
        rendered = "; ".join(candidate) + suffix
        if len(rendered.encode("utf-8")) > MAX_SUMMARY_BYTES:
            break
        kept = candidate

    if not kept:
        return (
            f"{len(reasons)} reasons omitted; "
            f"full-summary-sha256={digest}"
        )
    omitted = len(reasons) - len(kept)
    return (
        "; ".join(kept)
        + f"; ... {omitted} additional reason"
        + ("s" if omitted != 1 else "")
        + f" omitted; full-summary-sha256={digest}"
    )


def render(selection: Selection, output_format: str) -> str:
    tests = " ".join(selection.tests)
    locales = " ".join(selection.locales)
    summary = bounded_summary(selection.reasons)
    if output_format == "github":
        return "\n".join(
            (
                f"required={'true' if selection.required else 'false'}",
                f"interruption_controls={'true' if selection.interruption_controls_required else 'false'}",
                f"tests={tests}",
                f"scope_unknown={'true' if selection.scope_unknown else 'false'}",
                f"deferred={selection.deferred_to_nightly}",
                f"cut={' '.join(selection.cut)}",
                f"ranked={' '.join(selection.ranked)}",
                f"summary={summary}",
            )
        )
    if output_format == "shell":
        return "\n".join(
            (
                f"export UI_TEST_REQUIRED={'true' if selection.required else 'false'}",
                f"export UI_TEST_INTERRUPTION_REQUIRED={'true' if selection.interruption_controls_required else 'false'}",
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
        f"Selectors:\n  " + "\n  ".join(selection.tests) + f"\nReasons: {summary}\n"
        f"Deferred to nightly: {selection.deferred_to_nightly}"
        + (f"\nCut by the budget: {len(selection.cut)}\n  " + "\n  ".join(selection.cut) if selection.cut else "")
    )


def diff_selection(base: str, head: str | None, root: Path, paths: list[str] | None = None) -> Selection:
    """Select from one diff. No head means the working tree."""
    if paths is None:
        paths = changed_paths(base, head)
    changes = catalog_changes(base, head, root) if CATALOG in paths else None
    pin_changes = dependency_changes(base, head, root) if "Package.resolved" in paths else None
    return select_paths(paths, changes, root, pin_changes, ui_test_changes(base, head, Path.cwd()))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("paths", nargs="*", help="Changed paths; otherwise --base and --head are diffed")
    result.add_argument("--base", help="Base Git revision")
    result.add_argument("--head", default="HEAD", help="Head Git revision (default: HEAD)")
    result.add_argument("--pull-request-base", help="Diff from the merge base with this revision and with the default branch")
    result.add_argument(
        "--working-tree",
        action="store_true",
        help="Compare --base with the current index, working tree, and untracked files",
    )
    result.add_argument("--all", action="store_true", help="Select every UI test in English")
    result.add_argument("--shard", help="With --all, select balanced shard K of N (for example 2/3)")
    result.add_argument("--format", choices=("human", "github", "shell"), default="human")
    result.add_argument("--validate-catalog", action="store_true", help="Fail if a UI test lacks a selector")
    result.add_argument("--budget", action="store_true", help="Cut what does not fit a pull request's nominal test budget")
    result.add_argument("--ranked", action="store_true", help="Rank the candidates for the UI job to fit after its build")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    root = Path(__file__).resolve().parent.parent
    if arguments.validate_catalog:
        validate_catalog(root)
        if not arguments.paths and not arguments.base and not arguments.all:
            print(f"UI-test scope catalog is complete ({len(ALL_TESTS)} tests).")
            return 0

    if arguments.shard is not None and not arguments.all:
        print("--shard requires --all.", file=sys.stderr)
        return 2
    if arguments.all and arguments.shard is not None:
        try:
            index, count = (int(part) for part in arguments.shard.split("/"))
        except ValueError:
            print(f"Invalid --shard {arguments.shard!r}: expected K/N", file=sys.stderr)
            return 2
        try:
            tests = shard_tests(root, index, count)
        except ValueError as error:
            print(f"Cannot select shard {arguments.shard}: {error}", file=sys.stderr)
            return 2
        selection = Selection(tests, SELECTION_LOCALES, (f"full-suite shard {index}/{count}",))
    elif arguments.all:
        selection = Selection(
            ALL_TESTS, SELECTION_LOCALES, ("explicit full-suite request",), interruption_controls=True)
    else:
        if arguments.pull_request_base:
            head = arguments.head
            try:
                own_root = merge_root(arguments.pull_request_base, head)
                default_root = merge_root(DEFAULT_BRANCH_REF, head)
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                # A parent-branch diff alone would silently omit the parent's changes.
                print(f"::error title=UI scope::cannot resolve the pull request's bases: {error}", file=sys.stderr)
                return 2
            selection = diff_selection(default_root, head, root)
            if own_root != default_root:
                selection = stacked_selection(diff_selection(own_root, head, root), selection)
        elif arguments.working_tree:
            if not arguments.base:
                print("--working-tree requires --base.", file=sys.stderr)
                return 2
            selection = diff_selection(arguments.base, None, root, working_tree_paths(arguments.base))
        elif arguments.base:
            selection = diff_selection(arguments.base, arguments.head, root)
        elif arguments.paths:
            selection = select_paths(arguments.paths, None, root, None, None)
        else:
            print("Provide changed paths, --base, or --all.", file=sys.stderr)
            return 2
        if arguments.budget or arguments.ranked:
            try:
                budgeted = apply_budget if arguments.budget else rank_for_job
                selection = budgeted(selection, hosted_seconds(root))
            except ValueError as error:
                print(f"UI budget exceeded: {error}", file=sys.stderr)
                return 2
    print(render(selection, arguments.format))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
