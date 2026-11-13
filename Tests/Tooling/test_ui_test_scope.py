import contextlib
import hashlib
import io
import json
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from ui_test_catalog import UI_JOB_BUDGET_SECONDS, UI_JOB_TEARDOWN_SECONDS  # noqa: E402
import ui_test_scope as ui_scope  # noqa: E402
from ui_test_scope import (  # noqa: E402
    ALL_TESTS,
    CONSERVATIVE_TESTS,
    FEATURE_TESTS,
    HARNESS_FILES,
    HARNESS_SELF_TESTS,
    MEETING_FEATURES,
    PR_TESTS,
    SMOKE_TESTS,
    select_paths,
    validate_catalog,
    working_tree_paths,
)


QUOTES_LIVE_CAPTIONS = "PortavozUITests/LibraryUITests/testColdRecordingStartsLiveCaptionsWhenModelBecomesReady"


class UITestScopeTests(unittest.TestCase):
    def test_compact_detail_column_selects_every_journey_that_opens_a_meeting(self):
        path = "Sources/portavoz-app/MeetingDetailPrimaryColumn.swift"
        selection = select_paths([path])
        self.assertLess(len(selection.tests), len(ALL_TESTS))
        self.assertEqual(selection.locales, ("en",))
        for journey in (
            "RecordingInputUITests/testAcceptedNotesAndObjectivesSurviveTerminationAndRecovery",
            "SkillsSettingsUITests/testSkillsPaneControlsOffersAndShowsTheConfirmedReceipt",
        ):
            self.assertIn(f"PortavozUITests/{journey}", selection.tests)

    def test_portable_settings_files_reach_both_actual_transfer_journeys(self):
        paths = (
            "Sources/ApplicationKit/PortableSettings.swift",
            "Sources/ApplicationKit/PortableSettingsTransfer.swift",
            "Sources/portavoz-app/AppPortableSettingsStore.swift",
            "Sources/portavoz-app/PortableSettingsFile.swift",
            "Sources/portavoz-app/SettingsTransferModel.swift",
            "Sources/portavoz-app/SettingsTransferSection.swift",
        )
        expected = set(FEATURE_TESTS["settings-transfer"])
        self.assertTrue(expected)
        for path in paths:
            selection = select_paths([path])
            self.assertEqual(set(selection.tests), expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_package_changes_cannot_bypass_ui_evidence(self):
        manifest = select_paths(["Package.swift"])
        self.assertEqual(set(manifest.tests), set(CONSERVATIVE_TESTS))
        self.assertEqual(manifest.locales, ("en",))
        self.assertTrue(manifest.scope_unknown)

        lock = select_paths(["Package.resolved"])
        self.assertEqual(set(lock.tests), set(CONSERVATIVE_TESTS))
        self.assertEqual(lock.locales, ("en",))
        self.assertTrue(lock.scope_unknown)
        self.assertEqual(lock.reasons, ("scope-unknown: Package.resolved: changed pins unknown",))

    def test_a_known_pin_selects_canaries_and_its_owners_without_full_catalog(self):
        selection = select_paths(["Package.resolved"], dependency_changes={"sparkle"})

        expected = set(SMOKE_TESTS) | set(FEATURE_TESTS["main-shell"]) | set(FEATURE_TESTS["settings-navigation"])
        self.assertEqual(set(selection.tests), expected)
        self.assertFalse(selection.scope_unknown)
        self.assertEqual(selection.deferred_to_nightly, len(ALL_TESTS) - len(expected))

    def test_an_unmapped_pin_is_reported_and_keeps_the_owners_it_can_name(self):
        selection = select_paths(["Package.resolved"], dependency_changes={"sparkle", "swift-collections"})

        self.assertTrue(selection.scope_unknown)
        self.assertTrue(set(CONSERVATIVE_TESTS) <= set(selection.tests))
        self.assertTrue(set(FEATURE_TESTS["settings-navigation"]) <= set(selection.tests))
        self.assertIn("swift-collections", selection.reasons[0])

    def test_a_lock_with_no_moved_pin_still_runs_the_canaries(self):
        selection = select_paths(["Package.resolved"], dependency_changes=set())

        self.assertEqual(set(selection.tests), set(SMOKE_TESTS))
        self.assertFalse(selection.scope_unknown)

    def test_dependency_changes_read_pins_from_both_revisions(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)

            def run(*arguments):
                subprocess.run(["git", *arguments], cwd=root, check=True, capture_output=True)

            def lock(pins):
                (root / "Package.resolved").write_text(json.dumps({"pins": [
                    {"identity": name, "state": {"revision": revision}} for name, revision in pins.items()]}))

            run("init", "-q")
            run("config", "user.email", "ci@example.test")
            run("config", "user.name", "CI")
            lock({"kept": "1", "moved": "1", "removed": "1"})
            run("add", ".")
            run("commit", "-qm", "base")
            lock({"kept": "1", "moved": "2", "added": "1"})
            run("add", ".")
            run("commit", "-qm", "head")

            self.assertEqual(ui_scope.dependency_changes("HEAD~1", "HEAD", root), {"moved", "removed", "added"})
            self.assertEqual(ui_scope.dependency_changes("HEAD~1", None, root), {"moved", "removed", "added"})
            (root / "Package.resolved").write_text("not json")
            self.assertIsNone(ui_scope.dependency_changes("HEAD~1", None, root))
            self.assertIsNone(ui_scope.dependency_changes("no-such-revision", "HEAD", root))

    def test_package_and_harness_changes_keep_the_conservative_set(self):
        selection = select_paths(["Package.swift", "project.yml"])
        self.assertEqual(set(selection.tests), set(CONSERVATIVE_TESTS))
        self.assertEqual(selection.locales, ("en",))

    def test_a_layout_change_selects_every_journey_that_opens_meeting_detail(self):
        selected = set(select_paths(["Sources/portavoz-app/MeetingDetailPrimaryColumn.swift"]).tests)
        opens_detail = re.compile(r'openMeetingDetail|"detail-|detail-compact|detail-transcript|detail-artifacts')
        missed = []
        for source in sorted((ROOT / "Tests/PortavozUITests").glob("*UITests.swift")):
            text = source.read_text(encoding="utf-8")
            owner = re.search(r"class\s+(\w+UITests)\s*:", text)
            for body in re.split(r"(?=\n\s*func\s+test\w+\s*\()", text)[1:]:
                method = re.search(r"func\s+(test\w+)\s*\(", body).group(1)
                selector = ui_scope.test_id(owner.group(1), method)
                if selector in PR_TESTS and opens_detail.search(body) and selector not in selected:
                    missed.append(selector)
        self.assertEqual(missed, [])

    def test_no_single_path_selects_the_complete_catalog(self):
        every_kind = [
            "Package.swift", "Package.resolved", ui_scope.CATALOG, "Makefile", "project.yml",
            "scripts/ui_test_scope.py", "scripts/ui_test_catalog.py", "docs/evidence/ui-test-runtime-budget.json",
            "Sources/portavoz-app/MeetingDetailPrimaryColumn.swift", "Sources/portavoz-app/UITestDefaults.swift",
            "Sources/portavoz-app/L10n.swift", "Resources/Unknown.bin",
            "Tests/PortavozUITests/UITestSupport.swift",
        ]
        for path in every_kind:
            with self.subTest(path=path):
                self.assertLess(len(select_paths([path]).tests), len(ALL_TESTS))

    def test_a_catalog_edit_runs_no_ui_and_a_new_case_runs_its_class_with_the_canaries(self):
        for path in ("scripts/ui_test_catalog.py", "scripts/ui_test_scope.py",
                     "docs/evidence/ui-test-runtime-budget.json"):
            with self.subTest(path=path):
                self.assertFalse(select_paths([path]).required)

        selection = select_paths([
            "scripts/ui_test_catalog.py", "docs/evidence/ui-test-runtime-budget.json",
            "Tests/PortavozUITests/InsightsUITests.swift",
        ])
        insights = {test for test in ALL_TESTS if "/InsightsUITests/" in test}
        self.assertEqual(set(selection.tests), insights | set(SMOKE_TESTS))
        self.assertGreater(selection.deferred_to_nightly, 0)

    def test_unreadable_or_unknown_input_is_never_zero_tests(self):
        for selection in (select_paths([ui_scope.CATALOG]), select_paths(["Package.resolved"]),
                          select_paths(["Resources/Unknown.bin"]), select_paths(["Fixtures/Deleted/gone.json"])):
            with self.subTest(reasons=selection.reasons):
                self.assertTrue(selection.required)
                self.assertTrue(selection.scope_unknown)
                self.assertTrue(selection.reasons[0].startswith("scope-unknown: "))

    def test_github_output_declares_scope_and_what_it_defers(self):
        outputs = dict(line.split("=", 1) for line in ui_scope.render(select_paths(["Package.swift"]), "github").splitlines())
        self.assertEqual(outputs["scope_unknown"], "true")
        self.assertEqual(outputs["deferred"], str(len(ALL_TESTS) - len(CONSERVATIVE_TESTS)))
        quiet = dict(line.split("=", 1) for line in ui_scope.render(select_paths(["docs/GAPS.md"]), "github").splitlines())
        self.assertEqual(quiet["scope_unknown"], "false")
        self.assertEqual(quiet["deferred"], "0")

    def test_harness_self_test_covers_every_handoff_and_stays_in_the_catalog(self):
        self.assertTrue(set(HARNESS_SELF_TESTS) <= set(ALL_TESTS))
        self.assertTrue(set(HARNESS_SELF_TESTS) - set(SMOKE_TESTS))
        for journey in ("UITestStorageUITests/testSharedScratch", "AudioImportUITests/",
                        "testAskConversationAnswersAndSeeksToExactCitation", "testTwentyThousandSegment"):
            with self.subTest(journey=journey):
                self.assertTrue(any(journey in test for test in HARNESS_SELF_TESTS))

    def test_validation_rejects_a_dependency_owner_that_does_not_exist(self):
        for owners in ({"not-a-pin": frozenset({"library"})}, {"sparkle": frozenset({"not-a-feature"})}):
            with self.subTest(owners=owners), mock.patch.object(ui_scope, "DEPENDENCY_FEATURES", owners):
                with self.assertRaisesRegex(RuntimeError, "dependency owners that do not exist"):
                    validate_catalog(ROOT, runtime_budget_required=False)

    def minimal_catalog_root(self, *methods: str, with_owner: bool = True):
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        tests = root / "Tests" / "PortavozUITests"
        tests.mkdir(parents=True)
        declarations = "\n".join(f"    func {method}() {{}}" for method in methods)
        (tests / "InsightsUITests.swift").write_text(
            "final class InsightsUITests: PortavozUITestCase {\n"
            f"{declarations}\n"
            "}\n",
            encoding="utf-8",
        )
        if with_owner:
            owner = root / "Sources" / "portavoz-app" / "InsightsView.swift"
            owner.parent.mkdir(parents=True)
            owner.write_text("// production owner\n", encoding="utf-8")
        return temporary, root

    def test_empty_change_set_requires_no_ui_runner(self):
        self.assertFalse(select_paths([]).required)

    def test_cli_and_public_dictation_corpus_do_not_run_unrelated_ui(self):
        for path in (
            "Sources/portavoz-cli/CLI.swift",
            "Sources/portavoz-cli/CLIBenchLive.swift",
            "Fixtures/DictationValidation/public-synthetic-v1.json",
            "Fixtures/DictationValidation/README.md",
        ):
            self.assertFalse(select_paths([path]).required, path)
        selection = select_paths([
            "Sources/portavoz-cli/CLI.swift",
            "Fixtures/DictationValidation/public-synthetic-v1.json",
            "Sources/portavoz-app/DictationController.swift",
        ])
        self.assertEqual(set(selection.tests), set(FEATURE_TESTS["dictation"]))
        self.assertEqual(selection.locales, ("en",))

        unknown_fixture = select_paths([
            "Fixtures/DictationValidation/future-app-resource.json",
        ])
        self.assertEqual(set(unknown_fixture.tests), set(CONSERVATIVE_TESTS))
        self.assertTrue(unknown_fixture.scope_unknown)
        self.assertEqual(unknown_fixture.locales, ("en",))

    def test_headless_live_benchmark_runs_no_ui_while_unknown_neighbors_keep_smoke(self):
        benchmark = "Sources/TranscriptionKit/LiveTranscriptionBench.swift"
        self.assertFalse(select_paths([benchmark]).required)
        # The exemption holds only while headless bench mode and the CLI are its callers.
        headless = {
            "Sources/TranscriptionKit/LiveTranscriptionBench.swift",
            "Sources/portavoz-app/BenchMode.swift",
        }
        for tree in ("Sources", "Tests/PortavozUITests"):
            for source in (ROOT / tree).rglob("*.swift"):
                path = source.relative_to(ROOT).as_posix()
                if path in headless or path.startswith("Sources/portavoz-cli/"):
                    continue
                self.assertNotIn(
                    "LiveTranscriptionBench.", source.read_text(encoding="utf-8"), path
                )
        unknown = select_paths(["Sources/TranscriptionKit/UnknownLiveOwner.swift"])
        self.assertTrue(unknown.required)
        self.assertEqual(unknown.tests, self.smoke_selection())
        self.assertEqual(unknown.locales, ("en",))

    def test_github_summary_is_bounded_without_weakening_selected_evidence(self):
        reasons = tuple(
            f"Sources/Feature{index}.swift: " + ("mapped-impact " * 80).strip()
            for index in range(200)
        )
        selection = ui_scope.Selection(
            tests=ui_scope.ALL_TESTS,
            locales=("en",),
            reasons=reasons,
        )

        rendered = ui_scope.render(selection, "github")
        outputs = dict(line.split("=", 1) for line in rendered.splitlines())

        self.assertEqual(outputs["required"], "true")
        self.assertEqual(outputs["tests"].split(), list(ui_scope.ALL_TESTS))
        self.assertLessEqual(
            len(outputs["summary"].encode("utf-8")),
            ui_scope.MAX_SUMMARY_BYTES,
        )
        self.assertIn("additional reasons omitted", outputs["summary"])
        full_summary = "; ".join(reasons)
        digest = hashlib.sha256(full_summary.encode("utf-8")).hexdigest()
        self.assertTrue(outputs["summary"].endswith(f"full-summary-sha256={digest}"))
        kept_summary = outputs["summary"].split("; ... ", 1)[0]
        self.assertTrue(
            all(reason in reasons for reason in kept_summary.split("; "))
        )

    def test_database_launch_recovery_selects_failure_and_normal_shell_evidence(self):
        recovery = FEATURE_TESTS["launch-recovery"]
        for path in (
            "Sources/portavoz-app/AppLaunchModel.swift",
            "Sources/portavoz-app/AppLaunchRecoveryView.swift",
            "Sources/portavoz-app/AppServices.swift",
            "Sources/portavoz-app/PortavozApp.swift",
        ):
            selection = select_paths([path])
            self.assertTrue(set(recovery).issubset(selection.tests), path)
            self.assertTrue(
                set(FEATURE_TESTS["main-shell"]).issubset(selection.tests),
                path,
            )
        storage = select_paths(
            ["Sources/StorageKit/MeetingStore+LaunchRecovery.swift"]
        )
        self.assertEqual(storage.tests, recovery)

    def test_resource_benchmark_owners_select_startup_canaries(self):
        expected = set(SMOKE_TESTS)
        for path in (
            "Sources/portavoz-app/BenchMode+ResourceRefinePreparation.swift",
            "Sources/portavoz-app/BenchResourceLaunchProbe.swift",
            "Sources/portavoz-app/BenchResourceProcessWatchdog.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.locales, ("en",), path)
            self.assertEqual(set(selection.tests), expected, path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_production_sync_stage_owners_select_only_the_sync_settings_journey(self):
        expected = FEATURE_TESTS["production-sync"]
        for path in (
            "Sources/portavoz-app/ProductionSyncQualificationCorpus.swift",
            "Sources/portavoz-app/ProductionSyncQualificationEvidence.swift",
            "Sources/portavoz-app/ProductionSyncQualificationProcess.swift",
            "Sources/portavoz-app/ProductionSyncQualificationRunner.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.locales, ("en",), path)
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(len(selection.tests), 1, path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_ios_readiness_sources_select_only_their_owned_canaries(self):
        expected_features = {
            "Sources/ModelStoreKit/ModelStore.swift": ("settings-intelligence",),
            "Sources/StorageKit/MeetingStore.swift": ("launch-recovery", "library"),
            "Sources/DiarizationKit/VoiceprintStore.swift": (
                "meeting-health", "meeting-naming", "onboarding", "settings-voice"
            ),
            "Sources/IntelligenceKit/BriefSynthesizer.swift": ("meeting-brief",),
            "Sources/IntelligenceKit/ChapterTitler.swift": ("meeting-naming",),
            "Sources/IntelligenceKit/MeetingTypeDetector.swift": ("meeting-naming",),
            "Sources/IntelligenceKit/ObjectiveCheck.swift": ("live-assist",),
            "Sources/IntelligenceKit/TitleSuggester.swift": ("meeting-naming",),
            "Sources/PortavozCore/CommitmentReplicaMerge.swift": (
                "meeting-commitments", "production-sync"
            ),
            "Sources/PortavozCore/DeferredMacWork.swift": ("background-work",),
            "Sources/IntegrationsKit/CloudKitMeetingSyncPlatform.swift": (
                "production-sync",
            ),
        }

        for path, features in expected_features.items():
            expected_set = {
                test
                for feature in features
                for test in FEATURE_TESTS[feature]
            }
            expected = tuple(test for test in ALL_TESTS if test in expected_set)
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_docs_governance_and_local_tooling_do_not_spend_a_ui_runner(self):
        selection = select_paths(
            [
                "README.md",
                "docs/ARCHITECTURE.md",
                ".github/dependabot.yml",
                ".design-sync/config.json",
                "Tests/Tooling/test_ui_test_scope.py",
            ]
        )
        self.assertFalse(selection.required)

    def test_audio_view_selects_only_audio_detail_evidence(self):
        for path in (
            "Sources/portavoz-app/MeetingPlayerBar.swift",
            "Sources/portavoz-app/MeetingDetailPlayerSection.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.locales, ("en",), path)
            self.assertEqual(selection.tests, FEATURE_TESTS["meeting-audio"], path)
            self.assertTrue(
                all(test.split("/")[1] in {"MeetingDetailUITests", "MeetingAudioTrimUITests"}
                    for test in selection.tests),
                path,
            )
            self.assertIn(
                "PortavozUITests/MeetingAudioTrimUITests/"
                "testSilentTailRequiresConfirmationAndCutsOnlyAfterConfirmation",
                selection.tests,
                path,
            )

    def test_audio_import_sources_reach_the_queue_instead_of_playback_settings(self):
        expected = set(FEATURE_TESTS["audio-imports"]) | set(FEATURE_TESTS["library"])
        paths = sorted(ROOT.glob("Sources/**/*AudioImport*.swift"))
        self.assertTrue(paths)
        for source in paths:
            path = source.relative_to(ROOT).as_posix()
            with self.subTest(path=path):
                selection = select_paths([path])
                self.assertEqual(set(selection.tests), expected)
                self.assertEqual(selection.locales, ("en",))
                self.assertFalse(selection.interruption_controls)

    def test_interruption_controls_follow_only_their_behavior_files(self):
        for path in ("Tests/PortavozUITests/PortavozUITestCase.swift", "Tests/Support/UITestScratch.swift",
                     "packaging/portavoz-uitests.entitlements", "scripts/check-ui-interruption-safety.py",
                     "scripts/ui_test_execution.py", "Tests/UIInterruptionFixtures/Fixture.swift"):
            with self.subTest(path=path):
                self.assertTrue(select_paths([path]).interruption_controls)
        for path in ("scripts/ui_test_scope.py", "docs/evidence/ui-test-runtime-budget.json", "Makefile",
                     ".github/workflows/ci.yml"):
            with self.subTest(path=path):
                self.assertFalse(select_paths([path]).interruption_controls)

    def test_detail_secondary_sections_select_only_owned_journeys(self):
        expected = {
            "Sources/portavoz-app/MeetingDetailActionSection.swift": (
                "meeting-export",
                "meeting-processing",
                "meeting-recap",
            ),
            "Sources/portavoz-app/MeetingDetailRailSection.swift": (
                "meeting-correction",
                "meeting-evidence",
                "meeting-health",
                "meeting-processing",
            ),
            "Sources/portavoz-app/MeetingDetailFlowState.swift": (
                "meeting-correction",
                "meeting-export",
                "meeting-naming",
                "meeting-processing",
                "meeting-recap",
                "meeting-summary",
            ),
        }
        for path, features in expected.items():
            selection = select_paths([path])
            owned_tests = {
                test
                for feature in features
                for test in FEATURE_TESTS[feature]
            }
            self.assertEqual(selection.locales, ("en",), path)
            self.assertEqual(set(selection.tests), owned_tests, path)

    def test_detail_composition_files_select_only_their_owned_journeys(self):
        expected = {
            "Sources/portavoz-app/MeetingDetailCoordinator+Identity.swift": (
                "meeting-naming",
            ),
            "Sources/portavoz-app/MeetingDetailCoordinator+Documents.swift": (
                "meeting-correction",
                "meeting-evidence",
                "meeting-export",
                "meeting-processing",
                "meeting-recap",
                "meeting-summary",
            ),
            "Sources/portavoz-app/MeetingDetailCoordinator+Commitments.swift": (
                "meeting-commitments",
            ),
            "Sources/portavoz-app/MeetingDetailCoordinator.swift": (
                "meeting-audio",
                "meeting-correction",
                "meeting-evidence",
                "meeting-processing",
            ),
            "Sources/portavoz-app/MeetingDetailFlowHost.swift": (
                "meeting-correction",
                "meeting-export",
                "meeting-health",
                "meeting-naming",
                "meeting-processing",
                "meeting-recap",
                "meeting-summary",
            ),
            "Sources/portavoz-app/MeetingDetailNotesSection.swift": (
                "meeting-summary",
            ),
            "Sources/portavoz-app/MeetingDetailRefineReviewSheet.swift": (
                "meeting-processing",
            ),
            "Sources/portavoz-app/MeetingCommitmentInboxSection.swift": (
                "meeting-commitments",
            ),
            "Sources/portavoz-app/MeetingDetailPlaybackNavigation.swift": (
                "meeting-audio",
                "meeting-evidence",
                "meeting-performance",
            ),
        }
        for path, features in expected.items():
            selection = select_paths([path])
            owned_tests = {
                test
                for feature in features
                for test in FEATURE_TESTS[feature]
            }
            self.assertEqual(selection.locales, ("en",), path)
            self.assertEqual(set(selection.tests), owned_tests, path)

    def test_localization_selects_journeys_quoting_changed_english_copy(self):
        catalog = ui_scope.CATALOG
        unknown = select_paths([catalog])
        self.assertEqual(set(unknown.tests), set(CONSERVATIVE_TESTS), "unknown keys cannot name a journey")
        self.assertTrue(unknown.scope_unknown)
        quoted = select_paths([catalog], {"Live captions are available now."}, ROOT)
        self.assertEqual(set(quoted.tests), set(SMOKE_TESTS) | {QUOTES_LIVE_CAPTIONS}, "only the test quoting it")
        formatted = select_paths([catalog], {"Apple summaries are unavailable: %@. Choose Ollama or Built-in (MLX)."}, ROOT)
        self.assertTrue(set(SMOKE_TESTS) <= set(formatted.tests))
        spanish_only = select_paths([catalog], set(), ROOT)
        self.assertFalse(spanish_only.required, "Spanish values belong to LocalizationTests")

    def test_catalog_changes_compare_english_keys_between_revisions(self):
        with self.catalog_revisions(
            {"strings": {"Keep": {}, "Old copy": {}}},
            {"strings": {"Keep": {"localizations": {"es": {}}}, "New copy": {}}},
        ) as (root, base):
            self.assertEqual(ui_scope.catalog_changes(base, "HEAD", root), {"Old copy", "New copy"})
            self.assertEqual(ui_scope.catalog_changes(base, None, root), {"Old copy", "New copy"})
            self.assertIsNone(ui_scope.catalog_changes("0" * 40, "HEAD", root))

    @contextlib.contextmanager
    def catalog_revisions(self, before, after, commit_after=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*arguments):
                return subprocess.run(["git", *arguments], cwd=root, check=True, capture_output=True, text=True).stdout
            git("init", "-q", "-b", "main")
            git("config", "user.email", "fixture@example.invalid")
            git("config", "user.name", "Fixture")
            path = root / ui_scope.CATALOG
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(before), encoding="utf-8")
            git("add", "-A")
            git("commit", "-q", "-m", "base")
            base = git("rev-parse", "HEAD").strip()
            path.write_text(json.dumps(after), encoding="utf-8")
            if commit_after:
                git("commit", "-qam", "copy")
            yield root, base

    @staticmethod
    def english(value, state=None):
        unit = {"value": value, **({"state": state} if state else {})}
        return {"localizations": {"en": {"stringUnit": unit}}}

    def test_catalog_changes_track_stable_key_english_overrides(self):
        key = "Live captions are available now."
        old, new = "Captions were ready to read.", "Captions are ready to read."
        cases = (
            ({}, self.english(new), {key, new}),
            (self.english(old), self.english(new), {key, old, new}),
            (self.english(old), {}, {key, old}),
            (self.english(old), self.english(""), {key, old}),
            ({}, self.english(""), {key}),
        )
        for before, after, expected in cases:
            with self.subTest(before=before, after=after), self.catalog_revisions(
                {"strings": {key: before}}, {"strings": {key: after}}
            ) as (root, base):
                for head in ("HEAD", None):
                    changed = ui_scope.catalog_changes(base, head, root)
                    self.assertEqual(changed, expected)
                    selected = select_paths([ui_scope.CATALOG], changed, ROOT)
                    self.assertTrue(set(SMOKE_TESTS) <= set(selected.tests))
                    self.assertIn(QUOTES_LIVE_CAPTIONS, selected.tests)
                    self.assertEqual(set(selected.tests), set(SMOKE_TESTS) | {QUOTES_LIVE_CAPTIONS})

    def test_uncommitted_catalog_edit_counts_in_working_tree_mode(self):
        key = "Live captions are available now."
        with self.catalog_revisions(
            {"strings": {key: {}}}, {"strings": {key: self.english("Captions are ready.")}}, commit_after=False
        ) as (root, base):
            self.assertEqual(ui_scope.catalog_changes(base, None, root), {key, "Captions are ready."})
            self.assertEqual(ui_scope.catalog_changes(base, "HEAD", root), set())

    def test_catalog_override_changes_select_old_and_new_quoted_values(self):
        key = "stable-caption-key"
        old, new = 'Old "caption" override text.', "New caption override text."
        with self.catalog_revisions(
            {"strings": {key: self.english(old)}}, {"strings": {key: self.english(new)}}
        ) as (root, base):
            tests = root / "Tests/PortavozUITests"
            tests.mkdir(parents=True)
            for name, value in (("LibraryUITests", old), ("InsightsUITests", new)):
                literal = value.replace('"', '\\"')
                (tests / f"{name}.swift").write_text(f'let label = "{literal}"\n', encoding="utf-8")
            for head in ("HEAD", None):
                changed = ui_scope.catalog_changes(base, head, root)
                self.assertEqual(changed, {key, old, new})
                selected = select_paths([ui_scope.CATALOG], changed, root)
                for name in ("LibraryUITests", "InsightsUITests"):
                    expected = {test for test in PR_TESTS if f"/{name}/" in test}
                    self.assertTrue(expected)
                    self.assertTrue(expected <= set(selected.tests), "outside any function: the whole class")

    def test_catalog_changes_include_overrides_for_added_and_removed_keys(self):
        with self.catalog_revisions(
            {"strings": {"old-key": self.english("Old English override.")}},
            {"strings": {"new-key": self.english("New English override.")}},
        ) as (root, base):
            for head in ("HEAD", None):
                self.assertEqual(
                    ui_scope.catalog_changes(base, head, root),
                    {"old-key", "new-key", "Old English override.", "New English override."},
                )

    def test_catalog_changes_ignore_spanish_only_and_compiled_no_ops(self):
        key = "Live captions are available now."
        entries = (
            {"localizations": {"es": {"stringUnit": {"value": "Los subtítulos están disponibles."}}}},
            {"localizations": {"en": {}}},
            {"localizations": {"en": {"stringUnit": {}}}},
            {"localizations": {"en": {"stringUnit": {"value": None}}}},
            self.english(key, "translated"),
            self.english(key, "needs_review"),
        )
        for entry in entries:
            with self.subTest(entry=entry), self.catalog_revisions(
                {"strings": {key: {}}}, {"strings": {key: entry}}
            ) as (root, base):
                for head in ("HEAD", None):
                    changed = ui_scope.catalog_changes(base, head, root)
                    self.assertEqual(changed, set())
                    self.assertFalse(select_paths([ui_scope.CATALOG], changed, ROOT).required)

    def test_plural_substitution_and_unshipped_english_changes_select_everything(self):
        key = "%lld meetings"
        plural = {"plural": {"one": {"stringUnit": {"value": "%lld meeting"}}}}
        substitution = {"n": {"formatSpecifier": "lld", "variations": plural}}
        for after in (
            {"localizations": {"en": {"variations": plural}}},
            {"localizations": {"en": {"stringUnit": {"value": "%#@n@ left"}, "substitutions": substitution}}},
            self.english(key, "new"),
        ):
            with self.subTest(after=after), self.catalog_revisions(
                {"strings": {key: {}}}, {"strings": {key: after}}
            ) as (root, base):
                changed = ui_scope.catalog_changes(base, "HEAD", root)
                self.assertIsNone(changed)
                self.assertTrue(select_paths([ui_scope.CATALOG], changed, ROOT).scope_unknown)
        with self.catalog_revisions(
            {"strings": {key: {"localizations": {"en": {"variations": plural}}}}},
            {"strings": {key: {"localizations": {"en": {"variations": plural}, "es": {}}}}},
        ) as (root, base):
            self.assertEqual(ui_scope.catalog_changes(base, "HEAD", root), set())

    def test_catalog_english_rejects_malformed_data(self):
        for invalid in (
            [], {}, {"strings": []}, {"strings": {"Keep": None}},
            {"strings": {"Keep": {"localizations": []}}},
            {"strings": {"Keep": {"localizations": {"en": None}}}},
            {"strings": {"Keep": {"localizations": {"en": {"stringUnit": []}}}}},
            {"strings": {"Keep": {"localizations": {"en": {"stringUnit": {"value": 42}}}}}},
        ):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                ui_scope.catalog_english(json.dumps(invalid))
        with self.catalog_revisions({"strings": {"Keep": {}}}, {"strings": []}) as (root, base):
            for head in ("HEAD", None):
                changed = ui_scope.catalog_changes(base, head, root)
                self.assertIsNone(changed)
                self.assertTrue(select_paths([ui_scope.CATALOG], changed, ROOT).scope_unknown)

    def test_no_path_combination_selects_spanish(self):
        selection = select_paths([
            "Resources/Localization/Portavoz/Localizable.xcstrings",
            "Tests/PortavozUITests/UITestSupport.swift",
            "Sources/portavoz-app/UITestDefaults.swift",
            "Sources/portavoz-app/PortavozAppIntents.swift",
            "Fixtures/ApuntadorWeb/public-local-v1.json",
            *sorted(ui_scope.APUNTADOR_LEAK_EVIDENCE_FILES),
        ])
        self.assertTrue(selection.required)
        self.assertEqual(selection.locales, ("en",))
        self.assertEqual(ui_scope.SELECTION_LOCALES, ("en",))

    def test_all_selects_every_test_in_english_only(self):
        for output_format, expected in (
            ("github", {"interruption_controls=true"}),
            ("shell", {"export UI_TEST_LOCALES=en"}),
            ("human", {"Locales: en", f"UI tests: {len(ALL_TESTS)}/{len(ALL_TESTS)}"}),
        ):
            with self.subTest(output_format=output_format):
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    status = ui_scope.main(["--all", "--format", output_format])
                self.assertEqual(status, 0)
                self.assertLessEqual(expected, set(stdout.getvalue().splitlines()))
        self.assertIn("Select every UI test in English", ui_scope.parser().format_help())

    def test_feature_handshake_support_selects_only_ask_and_skills(self):
        expected = set(FEATURE_TESTS["ask"])
        expected.update(FEATURE_TESTS["settings-skills"])
        for path in (
            "Sources/portavoz-app/UITestFeatureHandshake.swift",
            "Tests/PortavozUITests/FeatureUITestHandshakeSupport.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(set(selection.tests), expected, path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_every_attempt_selects_from_history_and_no_earlier_run_narrows_it(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("PREVIOUS_HEAD_SHA", workflow)
        self.assertNotIn("github.event.before", workflow)
        self.assertNotIn("ui-verification-", workflow)
        self.assertNotIn("github.run_attempt == 1", workflow)
        self.assertIn('--pull-request-base "$BASE_SHA" --head "$HEAD_SHA"', workflow)
        self.assertIn(
            "python3 scripts/ui_test_scope.py --all --format github",
            workflow,
        )
        self.assertFalse((ROOT / "scripts/ui_test_verified_base.py").exists())
        self.assertFalse((ROOT / "scripts/ui_test_verification_anchor.py").exists())

    def test_hosted_ui_builds_once_runs_locale_lanes_and_gates_after_artifacts(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(
            encoding="utf-8"
        )

        # The lane builds its host from SwiftPM and runs it on the same Mac.
        self.assertEqual(workflow.count("run: make test-ui-host-products"), 1)
        self.assertEqual(workflow.count("run: make test-ui-run"), 1)
        # The classifier reads the UI step's outcome; nothing else may hide a failure.
        self.assertEqual(workflow.count("continue-on-error: true"), 1)
        self.assertEqual(
            workflow.count('UI_TEST_ENFORCE_RUNTIME_BUDGET: "false"'),
            1,
        )
        self.assertNotIn("matrix", workflow)
        self.assertIn("UI_TEST_LOCALES: en", workflow)
        self.assertIn("UI_TEST_PRODUCTS_PATH=", workflow)
        self.assertIn('--english-outcome "$outcome"', workflow)
        self.assertNotIn("--spanish-outcome", workflow)
        self.assertIn("runs-on: macos-26", workflow)
        self.assertIn("Xcode_26.6.app/Contents/Developer", workflow)
        for job in ("interruption", "ui-tests"):
            body = re.search(rf"(?ms)^  {job}:\n(.*?)(?=^  [a-z][a-z-]+:\n|\Z)", workflow).group(1)
            self.assertEqual(body.count("scripts/install-ci-xcodegen.sh"), 1, job)
        self.assertNotIn("brew install xcodegen", workflow)
        artifact = workflow.index("Preserve UI evidence")
        gate = workflow.index("Classify functional evidence and hosted runtime drift")
        self.assertLess(artifact, gate)
        self.assertNotIn("run: make test-ui-scoped", workflow)

    def test_ui_scope_does_not_duplicate_repository_tooling_suites(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(
            encoding="utf-8"
        )

        self.assertEqual(
            workflow.count("scripts/ui_test_scope.py --validate-catalog"),
            1,
        )
        lanes = workflow.split("\n  scope:\n", 1)[1]
        self.assertNotIn("python3 -m unittest Tests.Tooling", lanes)

    def test_semantic_asset_preparation_selects_its_settings_journey(self):
        expected = FEATURE_TESTS["settings-intelligence"]
        for path in (
            "Sources/ApplicationKit/SemanticSearchAssetPreparation.swift",
            "Sources/portavoz-app/SemanticSearchPreparationModel.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_decision_relationship_sources_select_exact_ask_journeys(self):
        selection = select_paths([
            "Sources/ApplicationKit/LoadDecisionRelationships.swift",
            "Sources/StorageKit/MeetingStore+DecisionRelationshipQuery.swift",
        ])
        self.assertEqual(selection.tests, FEATURE_TESTS["ask"])
        self.assertEqual(selection.locales, ("en",))

    def test_recording_sources_select_callback_recovery_evidence(self):
        selection = select_paths(["Sources/AudioCaptureKit/RecordingSession.swift"])
        self.assertIn(
            "PortavozUITests/LibraryUITests/testRecordingWarnsWhenRemoteAudioCallbacksStop",
            selection.tests,
        )

    def test_recording_use_cases_skip_unrelated_settings_surfaces(self):
        for path in (
            "Sources/ApplicationKit/StartRecording.swift",
            "Sources/ApplicationKit/StopRecording.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(
                selection.tests,
                tuple(dict.fromkeys(
                    FEATURE_TESTS["library"]
                    + FEATURE_TESTS["recording-recovery"]
                )),
                path,
            )

    def test_mic_bleed_selects_live_and_refine_evidence_without_full_fallback(self):
        selection = select_paths(["Sources/TranscriptionKit/MicBleedFilter.swift"])
        selected = set(
            FEATURE_TESTS["recording-recovery"]
            + FEATURE_TESTS["meeting-processing"]
        )
        self.assertEqual(
            selection.tests,
            tuple(test for test in ALL_TESTS if test in selected),
        )
        self.assertLess(len(selection.tests), len(ALL_TESTS))

    def test_query_expander_selects_only_search_consumers(self):
        selection = select_paths(
            ["Sources/ApplicationKit/BilingualSearchQueryExpander.swift"]
        )
        expected = tuple(dict.fromkeys(
            FEATURE_TESTS["library"]
            + FEATURE_TESTS["meeting-brief"]
            + FEATURE_TESTS["ask"]
        ))
        self.assertEqual(selection.tests, expected)
        self.assertEqual(selection.locales, ("en",))
        self.assertLess(len(selection.tests), len(ALL_TESTS))

    def test_typed_note_ask_layers_select_only_the_consolidated_ask_scope(self):
        for path in (
            "Sources/ApplicationKit/AskNotes.swift",
            "Sources/ApplicationKit/LocalAskNoteRetrieval.swift",
            "Sources/StorageKit/Schema+ContextItemSearch.swift",
            "Sources/StorageKit/MeetingStore+NoteSearch.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, FEATURE_TESTS["ask"], path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_shared_cited_answering_selects_ask_and_interview_only(self):
        selected = set(
            FEATURE_TESTS["ask"] + FEATURE_TESTS["recording-interview"]
        )
        expected = tuple(test for test in ALL_TESTS if test in selected)
        for path in (
            "Sources/ApplicationKit/NumberedCitationAnswer.swift",
            "Sources/IntelligenceKit/RAGTextAnswering.swift",
            "Sources/IntelligenceKit/RAGAnswerer.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_proactive_assist_layers_select_only_consolidated_recording_evidence(self):
        expected = FEATURE_TESTS["recording-recovery"]
        for path in (
            "Sources/IntelligenceKit/ProactiveMeetingAssist.swift",
            "Sources/portavoz-app/RecordingProactiveAssistModel.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_confirmed_topic_catalog_selects_only_exact_ask_journeys(self):
        expected = FEATURE_TESTS["ask"]
        for path in (
            "Sources/ApplicationKit/LoadConfirmedTopicCatalog.swift",
            "Sources/StorageKit/MeetingStore+ConfirmedTopicCatalog.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_topic_first_discussion_selects_only_exact_ask_journeys(self):
        expected = FEATURE_TESTS["ask"]
        for path in (
            "Sources/ApplicationKit/LoadTopicFirstDiscussion.swift",
            "Sources/StorageKit/MeetingStore+TopicFirstDiscussionQuery.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_commitment_blocker_query_selects_only_exact_ask_journeys(self):
        selection = select_paths([
            "Sources/ApplicationKit/LoadCommitmentBlockers.swift",
        ])
        self.assertEqual(selection.tests, FEATURE_TESTS["ask"])
        self.assertEqual(selection.locales, ("en",))
        self.assertLess(len(selection.tests), len(ALL_TESTS))

    def test_summary_storage_selects_its_consumers_without_full_fallback(self):
        selection = select_paths(["Sources/StorageKit/MeetingStore+Summaries.swift"])
        self.assertTrue(set(FEATURE_TESTS["meeting-processing"]) <= set(selection.tests))
        self.assertTrue(set(FEATURE_TESTS["ask"]) <= set(selection.tests))
        self.assertLess(len(selection.tests), len(ALL_TESTS))

    def test_companion_refresh_selects_correction_publication_evidence(self):
        expected = {
            "PortavozUITests/MeetingDetailUITests/"
            "testExplicitApuntadorRefreshUsesCorrectedTranscript",
        }
        for path in (
            "Sources/ApplicationKit/RegenerateCompanionCards.swift",
            "Sources/StorageKit/MeetingStore+Companion.swift",
            "Sources/portavoz-app/AppServices+CompanionRegeneration.swift",
            "Sources/portavoz-app/CompanionRefresh.swift",
            "Sources/portavoz-app/MeetingDetailCoordinator.swift",
            "Sources/portavoz-app/MeetingDetailFlowState.swift",
        ):
            selection = select_paths([path])
            self.assertTrue(expected.issubset(selection.tests), path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

    def test_live_assist_validation_uses_one_bounded_real_app_journey(self):
        expected = FEATURE_TESTS["live-assist"]
        for path in (
            "Sources/IntelligenceKit/Companion.swift",
            "Sources/IntelligenceKit/CompanionGenerationProvenance.swift",
            "Sources/IntelligenceKit/LiveQuestionDetector.swift",
            "Sources/IntelligenceKit/ProviderNeutralCompanion.swift",
            "Sources/IntelligenceKit/TurnEndpointPolicy.swift",
            "Sources/portavoz-app/CompanionSettingsSection.swift",
            "Sources/portavoz-app/LiveAssistValidationContract.swift",
            "Sources/portavoz-app/LiveAssistValidationFaultRunner.swift",
            "Sources/portavoz-app/LiveAssistValidationRunner.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

        for path in (
            "Fixtures/LiveAssistValidation/public-bilingual-v1.json",
            "docs/evidence/live-assist-validation-budget.json",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_detail_performance_harness_selects_only_scale_journeys(self):
        for path in (
            "Sources/portavoz-app/MeetingDetailPerformanceTrace.swift",
            "Sources/portavoz-app/AppServices+ScaleBenchmark.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, FEATURE_TESTS["meeting-performance"])
            self.assertEqual(selection.locales, ("en",))

    def test_transcript_view_selects_navigation_audio_and_scale_evidence(self):
        selection = select_paths(
            ["Sources/portavoz-app/TranscriptSegmentsView.swift"]
        )
        selected = set(
            FEATURE_TESTS["meeting-audio"]
            + FEATURE_TESTS["meeting-correction"]
            + FEATURE_TESTS["meeting-evidence"]
            + FEATURE_TESTS["meeting-performance"]
        )
        expected = tuple(test for test in ALL_TESTS if test in selected)
        self.assertEqual(selection.tests, expected)
        self.assertEqual(selection.locales, ("en",))

    def test_meeting_detail_scene_and_presentation_select_the_processing_journeys(self):
        for path in [
            "Sources/portavoz-app/MeetingDetailScene.swift",
            "Sources/portavoz-app/MeetingDetailPresentation.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(set(selection.tests), set(FEATURE_TESTS["meeting-processing"]), path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_meeting_detail_sections_select_only_owned_journeys(self):
        expected_features = {
            "Sources/portavoz-app/MeetingDetailHeaderSection.swift": {
                "meeting-export", "meeting-naming", "meeting-processing"
            },
            "Sources/portavoz-app/MeetingGeneratedDocumentSection.swift": {
                "meeting-correction", "meeting-evidence", "meeting-summary"
            },
            "Sources/portavoz-app/MeetingDetailTrustSection.swift": {
                "meeting-health", "meeting-processing", "meeting-skills"
            },
            "Sources/portavoz-app/MeetingTranscriptSection.swift": {
                "meeting-audio", "meeting-correction", "meeting-evidence",
                "meeting-health", "meeting-performance"
            },
            "Sources/ApplicationKit/MeetingGeneratedDocumentPresentation.swift": {
                "meeting-evidence", "meeting-summary"
            },
            "Sources/ApplicationKit/MeetingTranscriptContent.swift": {
                "meeting-audio", "meeting-evidence", "meeting-health", "meeting-performance"
            },
        }
        for path, features in expected_features.items():
            selection = select_paths([path])
            selected = {
                test
                for feature in features
                for test in FEATURE_TESTS[feature]
            }
            expected = tuple(test for test in ALL_TESTS if test in selected)
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_composed_transcript_policy_selects_only_correction_journey(self):
        selection = select_paths(["Sources/ApplicationKit/ComposeTranscript.swift"])
        self.assertEqual(selection.tests, FEATURE_TESTS["meeting-correction"])
        self.assertEqual(selection.locales, ("en",))

        future_consumer = select_paths(["Sources/StorageKit/ComposeTranscriptStore.swift"])
        self.assertTrue(future_consumer.required)
        self.assertEqual(future_consumer.tests, self.smoke_selection())

    def test_durable_correction_storage_selects_only_correction_journey(self):
        expected = FEATURE_TESTS["meeting-correction"]
        for path in [
            "Sources/PortavozCore/TranscriptCorrection.swift",
            "Sources/PortavozCore/TranscriptCorrectionRevision.swift",
            "Sources/ApplicationKit/MeetingTranscriptGenerationMaterial.swift",
            "Sources/StorageKit/MeetingStore+TranscriptCorrections.swift",
            "Sources/StorageKit/MeetingStore+TranscriptProjection.swift",
            "Sources/StorageKit/Schema+TranscriptCorrection.swift",
            "Sources/StorageKit/TranscriptCorrectionRecords.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_commitment_admission_selects_only_the_confirmation_journey(self):
        expected = FEATURE_TESTS["meeting-commitments"]
        for path in [
            "Sources/ApplicationKit/ManageMeetingCommitmentInbox.swift",
            "Sources/ApplicationKit/MeetingCommitmentInbox.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_commitment_radar_selects_only_its_global_continuity_journey(self):
        expected = FEATURE_TESTS["commitment-radar"]
        for path in [
            "Sources/PortavozCore/CommitmentRadar.swift",
            "Sources/ApplicationKit/LoadCommitmentRadar.swift",
            "Sources/ApplicationKit/ManageCommitmentRadar.swift",
            "Sources/StorageKit/MeetingStore+CommitmentRadar.swift",
            "Sources/portavoz-app/AppServices+CommitmentRadar.swift",
            "Sources/portavoz-app/CommitmentRadarModel.swift",
            "Sources/portavoz-app/CommitmentRadarView.swift",
            "Sources/portavoz-app/CommitmentRadarView+ReminderDraft.swift",
            "Sources/portavoz-app/ReminderDraftModel.swift",
            "Sources/portavoz-app/ReminderDraftSheet.swift",
            "Sources/portavoz-app/AppReminderDraftEventKitAdapter.swift",
            "Sources/portavoz-app/AppServices+ReminderDraft.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_content_composition_selects_one_canary_per_root_route(self):
        selection = select_paths(["Sources/portavoz-app/ContentView.swift"])
        expected = set(FEATURE_TESTS["main-shell"])
        expected.update(FEATURE_TESTS["background-work"])
        self.assertEqual(set(selection.tests), expected)
        self.assertEqual(selection.locales, ("en",))
        self.assertLess(len(selection.tests), len(ALL_TESTS))

    def test_background_work_owners_select_only_the_consolidated_journeys(self):
        expected = FEATURE_TESTS["background-work"]
        for path in (
            "Sources/portavoz-app/BackgroundWorkCenterModel.swift",
            "Sources/portavoz-app/BackgroundWorkCenterView.swift",
            "Sources/portavoz-app/PostCaptureProcessingCoordinator.swift",
            "Sources/portavoz-app/RecordingRecoveryCoordinator.swift",
            "Sources/portavoz-app/SemanticCorpusIndexingSupervisor.swift",
            "Sources/portavoz-app/SpotlightIndexer.swift",
            "Sources/ApplicationKit/ProcessSemanticCorpusMaintenance.swift",
            "Sources/ApplicationKit/ProcessMeetingMemoryGraphMaintenance.swift",
            "Sources/ApplicationKit/RecoverInterruptedMeetings.swift",
        ):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_window_placement_runs_the_harness_self_test(self):
        for path in (
            "Sources/portavoz-app/UITestWindowPlacement.swift",
        ):
            with self.subTest(path=path):
                selection = select_paths([path])
                self.assertEqual(set(selection.tests), set(CONSERVATIVE_TESTS))
                self.assertEqual(selection.locales, ("en",))

    def test_seed_fixtures_report_an_unknown_scope(self):
        for path in (
            "Sources/portavoz-app/AppServices+UITestFixtures.swift",
            "Sources/portavoz-app/AppServices+LiveAssistUITestFixture.swift",
            "Sources/portavoz-app/AppServices+StorageComposition.swift",
            "Sources/portavoz-app/AppServices+AskTopicMemoryUITestFixture.swift",
            "Sources/portavoz-app/UITestDefaults.swift",
        ):
            with self.subTest(path=path):
                selection = select_paths([path])
                self.assertEqual(set(selection.tests), set(CONSERVATIVE_TESTS))
                self.assertEqual(selection.locales, ("en",))
                self.assertTrue(selection.scope_unknown)
                self.assertIn("seed fixture", selection.reasons[0])

    def test_subtitle_export_selects_only_its_meeting_export_smoke(self):
        selection = select_paths(["Sources/IntegrationsKit/SubtitleExport.swift"])
        self.assertEqual(
            selection.tests,
            (
                "PortavozUITests/MeetingDetailUITests/"
                "testExportMenuOffersSubtitleFormats",
            ),
        )
        self.assertEqual(selection.locales, ("en",))

    def test_dictation_surfaces_select_unattended_controller_coverage(self):
        for path in [
            "Sources/portavoz-app/DictationSection.swift",
            "Sources/portavoz-app/DictationShortcut.swift",
            "Sources/portavoz-app/DictationShortcutSettings.swift",
            "Sources/portavoz-app/HotkeySetting+Labels.swift",
            "Sources/portavoz-app/MouseButtonPTT.swift",
            "Sources/portavoz-app/MousePTTGesture.swift",
            "Sources/portavoz-app/DictationController.swift",
            "Sources/portavoz-app/DictationSessionDependencies.swift",
            "Sources/portavoz-app/AppServices+DictationUITestFixture.swift",
            "Sources/portavoz-app/TextInserter.swift",
            "Sources/portavoz-app/DictationClipboard.swift",
            "Sources/portavoz-app/PasteboardSnapshot.swift",
            "Sources/TranscriptionKit/DictationTextRules.swift",
        ]:
            selection = select_paths([path])
            expected = tuple(test for test in ALL_TESTS if test in FEATURE_TESTS["dictation"])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_shared_microphone_preference_reaches_dictation_recording_and_settings(self):
        selection = select_paths(["Sources/portavoz-app/MicrophoneInputSelection.swift"])
        expected = set().union(*(FEATURE_TESTS[feature] for feature in (
            "dictation", "recording-recovery", "settings-audio")))
        self.assertEqual(set(selection.tests), expected)

    def test_settings_application_keeps_preparing_dictation_in_scope(self):
        selection = select_paths(["Sources/portavoz-app/AppServices+SettingsTransfer.swift"])
        self.assertEqual(set(selection.tests), set(FEATURE_TESTS["settings-transfer"] + FEATURE_TESTS["dictation"]))

    def test_dictation_receiver_changes_keep_the_panel_journey_in_scope(self):
        selection = select_paths(["Tests/PortavozDictationReceiver/DictationReceiver.swift"])
        self.assertEqual(set(selection.tests), set(FEATURE_TESTS["dictation"]))
        self.assertEqual(selection.locales, ("en",))

    def test_the_coexistence_peer_is_a_headless_test_process(self):
        selection = select_paths(["Tests/DictationPeer/DictationPeer.swift"])
        self.assertEqual(selection.tests, ())
        self.assertFalse(selection.scope_unknown)

    def test_menu_bar_changes_cover_the_dictation_entrypoint(self):
        selection = select_paths(["Sources/portavoz-app/MenuBarView.swift"])
        expected = set(FEATURE_TESTS["menu-bar-brief"] + FEATURE_TESTS["dictation"])
        self.assertEqual(set(selection.tests), expected)

    def test_skill_sources_select_the_control_and_proposal_journeys(self):
        expected_set = set(
            FEATURE_TESTS["commitment-radar"]
            + FEATURE_TESTS["meeting-skills"]
            + FEATURE_TESTS["menu-bar-brief"]
            + FEATURE_TESTS["settings-skills"])
        expected = tuple(test for test in ALL_TESTS if test in expected_set)
        for path in [
            "Sources/PortavozCore/SkillExecutionPolicy.swift",
            "Sources/ApplicationKit/SkillsControlCenter.swift",
            "Sources/StorageKit/MeetingStore+SkillControl.swift",
            "Sources/portavoz-app/AppServices+MeetingSkills.swift",
            "Sources/portavoz-app/SkillActivitySection.swift",
            "Sources/portavoz-app/SkillsSettingsSection.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_standing_skill_sources_select_only_the_composed_lifecycle(self):
        expected = FEATURE_TESTS["settings-standing-skills"]
        for path in [
            "Sources/PortavozCore/StandingSkillRule.swift",
            "Sources/ApplicationKit/StandingSkillAutomationCenter.swift",
            "Sources/ApplicationKit/StandingPreMeetingBriefs.swift",
            "Sources/StorageKit/MeetingStore+StandingSkillHistory.swift",
            "Sources/portavoz-app/AppServices+StandingSkills.swift",
            "Sources/portavoz-app/StandingPreMeetingBriefSupervisor.swift",
            "Sources/portavoz-app/StandingSkillRulesSection.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_atomic_snapshot_helper_runs_the_harness_self_test(self):
        path = "Tests/PortavozUITests/UITestSnapshotSupport.swift"
        selection = select_paths([path])
        self.assertEqual(set(selection.tests), set(CONSERVATIVE_TESTS))
        self.assertEqual(selection.locales, ("en",))

    def test_shared_fixture_build_sources_and_permission_run_the_harness_self_test(self):
        for path in (
            "Package.swift",
            "packaging/portavoz-uitests.entitlements",
            "Tests/Support/UITestScratch.swift",
            "Tests/PortavozUITests/UITestStorageSupport.swift",
        ):
            with self.subTest(path=path):
                selection = select_paths([path])
                self.assertEqual(set(selection.tests), set(CONSERVATIVE_TESTS))
                self.assertEqual(selection.locales, ("en",))

    def test_a_production_harness_file_keeps_its_own_journeys(self):
        selection = select_paths(["Sources/portavoz-app/SettingsSkillReceiptNavigation.swift"])

        self.assertTrue(set(CONSERVATIVE_TESTS) <= set(selection.tests))
        self.assertTrue(set(FEATURE_TESTS["settings-skills"]) <= set(selection.tests))

    def test_harness_change_runs_the_canaries_and_the_self_test(self):
        self.assertIn("scripts/candidate_automation.py", HARNESS_FILES)
        for path in sorted(HARNESS_FILES - {"Sources/portavoz-app/SettingsSkillReceiptNavigation.swift"}):
            selection = select_paths([path])
            self.assertEqual(set(selection.tests), set(CONSERVATIVE_TESTS), path)
            self.assertFalse(selection.scope_unknown, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_leak_evidence_owners_run_only_the_canaries(self):
        self.assertTrue(ui_scope.APUNTADOR_LEAK_EVIDENCE_FILES.isdisjoint(HARNESS_FILES))
        for path in sorted(ui_scope.APUNTADOR_LEAK_EVIDENCE_FILES):
            selection = select_paths([path])
            self.assertEqual(set(selection.tests), set(SMOKE_TESTS), path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_app_intents_selects_only_the_recording_handoff(self):
        selection = select_paths(
            ["Sources/portavoz-app/PortavozAppIntents.swift"]
        )
        self.assertEqual(
            selection.tests,
            FEATURE_TESTS["automation-entry"],
        )
        self.assertEqual(selection.locales, ("en",))

    def test_app_entity_catalog_files_select_only_entry_and_radar(self):
        expected_set = set(
            FEATURE_TESTS["automation-entry"]
            + FEATURE_TESTS["commitment-radar"]
        )
        expected = tuple(test for test in ALL_TESTS if test in expected_set)
        for path in [
            "Sources/ApplicationKit/LoadAutomationEntities.swift",
            "Sources/StorageKit/MeetingStore+AutomationEntities.swift",
            "Sources/portavoz-app/AppServices+AutomationEntities.swift",
            "Sources/portavoz-app/AppServices+AutomationEntityUITestFixture.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertLess(len(selection.tests), len(ALL_TESTS), path)

        focus = select_paths([
            "Sources/portavoz-app/CommitmentRadarAppEntityFocusBanner.swift"
        ])
        self.assertEqual(focus.tests, FEATURE_TESTS["commitment-radar"])

    def test_recording_toolbar_selects_geometry_and_live_control_contracts(self):
        selection = select_paths(
            ["Sources/portavoz-app/RecordingToolbar.swift"]
        )
        self.assertEqual(
            selection.tests,
            tuple(test for test in ALL_TESTS if test in set(
                FEATURE_TESTS["automation-entry"]
                + FEATURE_TESTS["recording-interview"]
                + FEATURE_TESTS["recording-recovery"])),
        )
        self.assertEqual(selection.locales, ("en",))

    def test_interview_sources_select_the_single_grounded_real_app_journey(self):
        expected = FEATURE_TESTS["recording-interview"]
        for path in [
            "Sources/ApplicationKit/AssistInterviewQuestion.swift",
            "Sources/portavoz-app/RecordingInterviewAssistModel.swift",
            "Sources/portavoz-app/RecordingInterviewAssistView.swift",
        ]:
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_an_edited_method_selects_itself_and_the_canaries_not_its_class(self):
        method = "testRelaunchResumesPublishedAudioWithoutTheSelectedOriginals"
        path = "Tests/PortavozUITests/AudioImportUITests.swift"

        selection = select_paths([path], ui_changes={path: ui_scope.UITestChange(frozenset({method}))})

        self.assertEqual(set(selection.tests), {ui_scope.test_id("AudioImportUITests", method)} | set(SMOKE_TESTS))
        self.assertEqual(selection.priority[ui_scope.test_id("AudioImportUITests", method)][0], 0)

    def test_an_edited_nightly_only_method_runs_on_its_pull_request(self):
        method = "testMultipleAudioFilesReachPagedQueueAndOpenTheirMeeting"
        path = "Tests/PortavozUITests/AudioImportUITests.swift"
        selector = ui_scope.test_id("AudioImportUITests", method)
        self.assertIn(selector, ui_scope.NIGHTLY_ONLY_TESTS)

        selection = select_paths([path], ui_changes={path: ui_scope.UITestChange(frozenset({method}))})

        self.assertIn(selector, selection.tests)

    def test_an_edited_helper_selects_the_tests_that_use_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tests = root / "Tests/PortavozUITests"
            tests.mkdir(parents=True)
            kept = "testRelaunchResumesPublishedAudioWithoutTheSelectedOriginals"
            other = "testSingleMeetingBundleReachesDetailWithoutChangingTheOriginal"
            (tests / "AudioImportUITests.swift").write_text(
                f"final class AudioImportUITests {{\n"
                f"    func {kept}() {{\n        shared()\n    }}\n\n"
                f"    func {other}() {{\n        unrelated()\n    }}\n\n"
                f"    private func shared() {{\n        click()\n    }}\n}}\n", encoding="utf-8")
            path = "Tests/PortavozUITests/AudioImportUITests.swift"

            selection = select_paths([path], root=root, ui_changes={path: ui_scope.UITestChange(frozenset({"shared"}))})

            self.assertIn(ui_scope.test_id("AudioImportUITests", kept), selection.tests)
            self.assertNotIn(ui_scope.test_id("AudioImportUITests", other), selection.tests)
            self.assertEqual(selection.priority[ui_scope.test_id("AudioImportUITests", kept)][0], 1)

    def test_a_diff_maps_to_functions_and_outside_any_function_to_the_class(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "t@example.com"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "t"], cwd=root, check=True)
            tests = root / "Tests/PortavozUITests"
            tests.mkdir(parents=True)
            source = tests / "AUITests.swift"
            other = tests / "BUITests.swift"
            source.write_text("final class AUITests {\n    func testOne() {\n        a()\n    }\n\n"
                              "    @MainActor\n    func testTwo() {\n        b()\n    }\n}\n", encoding="utf-8")
            other.write_text("let a = 1\nfinal class BUITests {\n    func testThree() {\n        c()\n    }\n}\n",
                             encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "base"], cwd=root, check=True)
            source.write_text(source.read_text().replace("b()", "b2()"), encoding="utf-8")
            other.write_text(other.read_text().replace("let a = 1", "let a = 2"), encoding="utf-8")
            subprocess.run(["git", "commit", "-qam", "edit"], cwd=root, check=True)

            changes = ui_scope.ui_test_changes("HEAD~1", "HEAD", root)

            self.assertEqual(changes["Tests/PortavozUITests/AUITests.swift"], ui_scope.UITestChange(frozenset({"testTwo"})))
            self.assertEqual(changes["Tests/PortavozUITests/BUITests.swift"],
                             ui_scope.UITestChange(frozenset(), outside_functions=True))

    def test_an_edit_beside_a_function_keeps_the_edited_nightly_method_and_adds_the_class(self):
        method = "testMultipleAudioFilesReachPagedQueueAndOpenTheirMeeting"
        path = "Tests/PortavozUITests/AudioImportUITests.swift"
        changes = ui_scope.UITestChange(frozenset({method}), outside_functions=True)

        selection = select_paths([path], ui_changes={path: changes})

        self.assertIn(ui_scope.test_id("AudioImportUITests", method), selection.tests)
        self.assertTrue({test for test in PR_TESTS if "/AudioImportUITests/" in test} <= set(selection.tests))

    def test_a_lifecycle_edit_selects_the_class_because_no_body_names_it(self):
        path = "Tests/PortavozUITests/AudioImportUITests.swift"

        selection = select_paths([path], ui_changes={path: ui_scope.UITestChange(frozenset({"tearDown"}))})

        self.assertTrue({test for test in PR_TESTS if "/AudioImportUITests/" in test} <= set(selection.tests))

    def test_a_helper_called_on_a_test_first_line_or_through_another_helper_finds_the_test(self):
        direct = "testRelaunchResumesPublishedAudioWithoutTheSelectedOriginals"
        indirect = "testSingleMeetingBundleReachesDetailWithoutChangingTheOriginal"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tests = root / "Tests/PortavozUITests"
            tests.mkdir(parents=True)
            (tests / "AudioImportUITests.swift").write_text(
                f"final class AudioImportUITests {{\n    func {direct}() {{ shared() }}\n"
                f"    func {indirect}() {{\n        wrapper()\n    }}\n}}\n", encoding="utf-8")
            (tests / "ImportSupport.swift").write_text(
                "func wrapper() {\n    shared()\n}\n\nfunc shared() {\n    click()\n}\n", encoding="utf-8")

            found = ui_scope.tests_using({"shared"}, root)

        self.assertEqual(found, {ui_scope.test_id("AudioImportUITests", direct),
                                 ui_scope.test_id("AudioImportUITests", indirect)})

    def test_a_brace_in_a_string_or_comment_does_not_stretch_a_one_line_function(self):
        source = ('class T {\n    func testA() { print("{") }\n    func testB() { work() } // {\n'
                  '    func testC() {\n        c()\n    }\n}\n')

        self.assertEqual(ui_scope.function_spans(source), [("testA", 2, 2), ("testB", 3, 3), ("testC", 4, 6)])

    def test_a_helper_run_by_a_lifecycle_method_or_a_property_selects_the_class(self):
        one, other = ("testRelaunchResumesPublishedAudioWithoutTheSelectedOriginals",
                      "testSingleMeetingBundleReachesDetailWithoutChangingTheOriginal")
        for body in ("    override func tearDown() {\n        shared()\n    }\n",
                     "    private let fixture = shared()\n"):
            with self.subTest(body=body), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                tests = root / "Tests/PortavozUITests"
                tests.mkdir(parents=True)
                (tests / "AudioImportUITests.swift").write_text(
                    f"final class AudioImportUITests {{\n{body}"
                    f"    func {one}() {{\n        a()\n    }}\n"
                    f"    func {other}() {{\n        b()\n    }}\n}}\n"
                    f"func shared() {{\n    c()\n}}\n", encoding="utf-8")

                found = ui_scope.tests_using({"shared"}, root)

                self.assertTrue({ui_scope.test_id("AudioImportUITests", one),
                                 ui_scope.test_id("AudioImportUITests", other)} <= found)

    def test_a_helper_no_test_is_seen_to_use_selects_its_class(self):
        path = "Tests/PortavozUITests/AudioImportUITests.swift"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "Tests/PortavozUITests").mkdir(parents=True)
            (root / path).write_text("final class AudioImportUITests {\n    func orphan() {\n    }\n}\n",
                                     encoding="utf-8")

            selection = select_paths([path], root=root, ui_changes={path: ui_scope.UITestChange(frozenset({"orphan"}))})

        self.assertTrue({test for test in PR_TESTS if "/AudioImportUITests/" in test} <= set(selection.tests))

    def test_harness_and_unknown_changes_choose_the_self_tests_before_other_candidates(self):
        for path in ("Package.swift", "Tests/PortavozUITests/UITestSupport.swift"):
            with self.subTest(path=path):
                selection = select_paths([path])
                self.assertTrue(all(selection.priority[test][0] == 0 for test in HARNESS_SELF_TESTS))

    def test_an_edited_method_outside_the_catalog_runs_nothing_and_says_so(self):
        path = "Tests/PortavozUITests/PublicShowcaseUITests.swift"

        selection = select_paths([path], ui_changes={path: ui_scope.UITestChange(frozenset({"testTodayShowcase"}))})

        self.assertEqual(set(selection.tests), set(SMOKE_TESTS))
        self.assertTrue(any("need their own run" in reason for reason in selection.reasons))

    def test_selections_and_changes_stay_hashable(self):
        self.assertIsInstance(hash(ui_scope.UITestChange(frozenset({"a"}))), int)
        self.assertIsInstance(hash(ui_scope.Selection(("a",), ("en",), (), priority={"a": (0, 0)})), int)

    def test_one_line_and_multi_line_functions_end_where_they_close(self):
        source = ("class T {\n    func one() { a() }\n\n    private func two(\n        x: Int\n    ) {\n"
                  "        b()\n    }\n}\n")

        self.assertEqual(ui_scope.function_spans(source), [("one", 2, 2), ("two", 4, 8)])

    def seconds(self, overrides=None):
        seconds = {ui_scope.runtime_budget_key(test): 10.0 for test in ALL_TESTS}
        seconds.update(overrides or {})
        return seconds

    def test_the_budget_keeps_the_canaries_and_partitions_candidates_exactly(self):
        candidates = [test for test in PR_TESTS if test not in SMOKE_TESTS][:40]
        selection = ui_scope.Selection((*SMOKE_TESTS, *candidates), ("en",), ())

        budgeted = ui_scope.apply_budget(selection, self.seconds())

        self.assertTrue(set(SMOKE_TESTS) <= set(budgeted.tests))
        self.assertTrue(budgeted.cut)
        self.assertEqual(set(budgeted.tests) | set(budgeted.cut), set(selection.tests))
        self.assertFalse(set(budgeted.tests) & set(budgeted.cut))
        spent = ui_scope.UI_TEST_OVERHEAD_SECONDS + len(budgeted.tests) * (10 + ui_scope.UI_TEST_OVERHEAD_PER_TEST_SECONDS)
        self.assertLessEqual(spent, ui_scope.UI_TEST_BUDGET_SECONDS)

    def test_the_budget_is_deterministic_and_prefers_edited_then_consumers_then_paths(self):
        edited, consumer, many, one = [test for test in PR_TESTS if test not in SMOKE_TESTS][:4]
        selection = ui_scope.Selection(
            (*SMOKE_TESTS, edited, consumer, many, one), ("en",), (),
            priority={edited: (0, -1), consumer: (1, -1), many: (2, -3), one: (2, -1)})
        each = 10 + ui_scope.UI_TEST_OVERHEAD_PER_TEST_SECONDS
        for extra, expected_cut in ((3, [one]), (2, [many, one]), (1, [consumer, many, one])):
            with self.subTest(extra=extra):
                fit = ui_scope.UI_TEST_OVERHEAD_SECONDS + (len(SMOKE_TESTS) + extra) * each + 0.01
                budgeted = ui_scope.apply_budget(selection, self.seconds(), fit)
                self.assertEqual(budgeted, ui_scope.apply_budget(selection, self.seconds(), fit))
                self.assertEqual(list(budgeted.cut), expected_cut)

    def test_a_cheaper_case_wins_a_tie_and_no_case_disappears_over_budget(self):
        slow, fast = [test for test in PR_TESTS if test not in SMOKE_TESTS][:2]
        fast_key = ui_scope.runtime_budget_key(fast)
        selection = ui_scope.Selection((*SMOKE_TESTS, slow, fast), ("en",), ())
        canaries = ui_scope.UI_TEST_OVERHEAD_SECONDS + len(SMOKE_TESTS) * (10 + ui_scope.UI_TEST_OVERHEAD_PER_TEST_SECONDS)

        with mock.patch.object(ui_scope, "feature_tier", return_value=2):
            budgeted = ui_scope.apply_budget(selection, self.seconds({fast_key: 1.0}), canaries + 2)

        self.assertIn(fast, budgeted.tests)
        self.assertEqual(budgeted.cut, (slow,))

    def test_ranking_keeps_every_candidate_for_the_job_to_fit(self):
        edited, other = [test for test in PR_TESTS if test not in SMOKE_TESTS][:2]
        selection = ui_scope.Selection((other, edited), ("en",), (),
                                       priority={edited: (0, -1), other: (2, -1)})

        ranked = ui_scope.rank_for_job(selection, self.seconds())

        self.assertEqual(ranked.ranked, (edited, other))
        self.assertEqual(set(ranked.tests), {*SMOKE_TESTS, edited, other})
        self.assertEqual(ranked.cut, ())

    def test_ranking_rejects_canaries_over_the_nominal_budget_and_leaves_no_ui_empty(self):
        selection = ui_scope.Selection(tuple(SMOKE_TESTS), ("en",), ())
        over = {ui_scope.runtime_budget_key(test): 100.0 for test in SMOKE_TESTS}

        with self.assertRaisesRegex(ValueError, "canaries need"):
            ui_scope.rank_for_job(selection, self.seconds(over))
        self.assertEqual(ui_scope.rank_for_job(ui_scope.Selection((), (), ()), self.seconds()).tests, ())

    def test_a_late_build_cuts_every_candidate_but_never_a_canary(self):
        candidate = next(test for test in PR_TESTS if test not in SMOKE_TESTS)

        tests, cut = ui_scope.fit_ranked((*SMOKE_TESTS, candidate), (candidate,), self.seconds(), -100)

        self.assertEqual(set(tests), set(SMOKE_TESTS))
        self.assertEqual(cut, (candidate,))

    def test_more_time_left_after_the_build_fits_more_candidates_in_rank_order(self):
        first, second = [test for test in PR_TESTS if test not in SMOKE_TESTS][:2]
        each = 10 + ui_scope.UI_TEST_OVERHEAD_PER_TEST_SECONDS
        canaries = ui_scope.UI_TEST_OVERHEAD_SECONDS + len(SMOKE_TESTS) * each
        tests = (*SMOKE_TESTS, first, second)

        for extra, expected_cut in ((0, (first, second)), (1, (second,)), (2, ())):
            with self.subTest(extra=extra):
                _, cut = ui_scope.fit_ranked(tests, (first, second), self.seconds(), canaries + extra * each + 0.01)
                self.assertEqual(cut, expected_cut)

    def test_a_complete_run_has_nothing_ranked_and_nothing_to_cut(self):
        tests, cut = ui_scope.fit_ranked(ALL_TESTS, (), self.seconds(), -100)

        self.assertEqual(tests, tuple(ALL_TESTS))
        self.assertEqual(cut, ())

    def test_the_fit_command_budgets_what_remains_of_the_job(self):
        candidate = next(test for test in PR_TESTS if test not in SMOKE_TESTS)
        arguments = [sys.executable, str(ROOT / "scripts/ui_test_fit.py"),
                     "--tests", " ".join((*SMOKE_TESTS, candidate)), "--ranked", candidate]
        room = int(UI_JOB_BUDGET_SECONDS - UI_JOB_TEARDOWN_SECONDS)

        early = subprocess.run([*arguments, "--elapsed", "0"], check=True, capture_output=True, text=True).stdout
        late = subprocess.run([*arguments, "--elapsed", str(room + 60)], check=True, capture_output=True, text=True).stdout

        self.assertIn(f"left={room}", early)
        self.assertIn("cut=\n", early)
        self.assertIn("left=0", late)
        self.assertIn(f"cut={candidate}", late)
        self.assertIn(f"deferred={len(ALL_TESTS) - len(SMOKE_TESTS) - 1}", early)
        self.assertIn(f"deferred={len(ALL_TESTS) - len(SMOKE_TESTS)}", late)

    def test_the_ui_fixture_selects_its_import_journey(self):
        selection = select_paths(["Tests/Support/MeetingBundleFixture.swift"])

        self.assertFalse(selection.scope_unknown)
        self.assertTrue(set(FEATURE_TESTS["audio-imports"]) <= set(selection.tests))

    def test_canaries_over_budget_fail_instead_of_emptying_the_selection(self):
        selection = ui_scope.Selection(tuple(SMOKE_TESTS), ("en",), ())

        with self.assertRaisesRegex(ValueError, "canaries need"):
            ui_scope.apply_budget(selection, self.seconds(), budget=30)

    def test_the_budget_adds_the_canaries_and_needs_no_ui_stays_empty(self):
        feature = FEATURE_TESTS["settings-transfer"]

        self.assertTrue(set(SMOKE_TESTS) <= set(ui_scope.apply_budget(select_paths(
            ["Sources/portavoz-app/SettingsTransferSection.swift"]), self.seconds()).tests))
        self.assertTrue(set(feature) <= set(ui_scope.apply_budget(select_paths(
            ["Sources/portavoz-app/SettingsTransferSection.swift"]), self.seconds()).tests))
        self.assertEqual(ui_scope.apply_budget(select_paths(["docs/GAPS.md"]), self.seconds()).tests, ())

    def test_the_real_canaries_fit_on_recorded_times(self):
        seconds = ui_scope.hosted_seconds(ROOT)
        canaries = ui_scope.apply_budget(ui_scope.Selection(tuple(SMOKE_TESTS), ("en",), ()), seconds)

        self.assertEqual(set(canaries.tests), set(SMOKE_TESTS))
        for test in ALL_TESTS:
            self.assertIn(ui_scope.runtime_budget_key(test), seconds)

    def test_nightly_only_and_on_demand_cases_stay_out_of_path_selection(self):
        everything = select_paths(["Sources/portavoz-app/" + name for name in (
            "AudioImportQueueView.swift", "MeetingDetailPrimaryColumn.swift", "SkillsSettingsSection.swift")])

        self.assertFalse(set(everything.tests) & set(ui_scope.NIGHTLY_ONLY_TESTS))
        self.assertFalse(set(everything.tests) & set(ui_scope.ON_DEMAND_TESTS))

    def test_the_budget_cut_reaches_github_output_and_every_cut_is_named(self):
        selection = ui_scope.Selection(tuple(SMOKE_TESTS), ("en",), (), cut=("a", "b"))

        rendered = ui_scope.render(selection, "github")

        self.assertIn("cut=a b\n", rendered)

    def test_hosted_seconds_take_the_nearest_rank_p90_of_each_case(self):
        import ui_test_hosted_seconds as hosted
        night = "Test Case '-[PortavozUITests.AUITests testOne]' passed ({} seconds).\n"
        logs = [night.format(value) for value in (1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 20.0)]

        self.assertEqual(hosted.hosted_seconds(logs), {"AUITests/testOne()": 9.0})

    def test_changed_ui_test_file_selects_its_class_and_the_canaries(self):
        selection = select_paths(["Tests/PortavozUITests/AudioImportUITests.swift"])
        audio = {test for test in PR_TESTS if "/AudioImportUITests/" in test}
        self.assertEqual(set(selection.tests), audio | set(SMOKE_TESTS))

    def test_web_fixture_selects_only_its_real_app_journey(self):
        for path in (
            "Fixtures/ApuntadorWeb/public-local-v1.json",
            "Tests/PortavozUITests/ApuntadorWebFixtureSupport.swift",
        ):
            selection = select_paths([path])

            self.assertEqual(
                selection.tests,
                (
                    "PortavozUITests/LibraryUITests/"
                    "testAskConversationAnswersAndSeeksToExactCitation",
                ),
                path,
            )
            self.assertEqual(selection.locales, ("en",), path)

    def test_unknown_production_source_selects_the_smoke_canaries(self):
        for path, reason in (
            ("Sources/NewCapabilityKit/Unknown.swift", "lower-layer smoke canaries"),
            ("Sources/portavoz-app/BrandNewUnmappedSurface.swift", "unmapped app file smoke canaries"),
        ):
            with self.subTest(path=path):
                selection = select_paths([path])
                self.assertTrue(selection.required)
                self.assertEqual(selection.tests, self.smoke_selection())
                self.assertEqual(selection.locales, ("en",))
                self.assertEqual(selection.reasons, (f"{path}: {reason}",))

    def test_lower_layers_keep_proven_owners_and_send_the_rest_to_smoke(self):
        for path, feature in (
            ("Sources/ApplicationKit/PortableSettingsTransfer.swift", "settings-transfer"),
            ("Sources/IntelligenceKit/ChapterTitler.swift", "meeting-naming"),
            ("Sources/ApplicationKit/ProcessAudioImports.swift", "audio-imports"),
        ):
            with self.subTest(path=path):
                self.assertTrue(set(FEATURE_TESTS[feature]) <= set(select_paths([path]).tests))
                self.assertLess(len(select_paths([path]).tests), len(ALL_TESTS))
        selection = select_paths(["Sources/ApplicationKit/ProcessingWakeSchedule.swift"])
        self.assertEqual(selection.tests, self.smoke_selection())
        classifier = "Sources/IntelligenceKit/Resources/PortavozLiveQuestionClassifier.mlmodelc/coremldata.bin"
        self.assertEqual(set(select_paths([classifier]).tests), set(FEATURE_TESTS["live-assist"]))
        for unknown in ("Sources/PlatformKit/Resources/Unowned.json", "Sources/portavoz-app/Info.plist"):
            with self.subTest(path=unknown):
                self.assertEqual(set(select_paths([unknown]).tests), set(CONSERVATIVE_TESTS))
                self.assertTrue(select_paths([unknown]).scope_unknown)
        for research in ("Sources/portavoz-cli-main/main.swift", "Sources/CSQLiteVecResearch/sqlite-vec.c",
                         "Sources/SQLiteVecResearchKit/Ranker.swift"):
            with self.subTest(path=research):
                self.assertFalse(select_paths([research]).required)
        for path in ("Sources/portavoz-app/L10n.swift", "Sources/portavoz-app/AppLanguage.swift"):
            with self.subTest(path=path):
                self.assertEqual(select_paths([path]).tests, self.smoke_selection())

    def smoke_selection(self):
        return tuple(test for test in ALL_TESTS if test in set(SMOKE_TESTS))

    def test_unknown_non_swift_paths_keep_the_conservative_set(self):
        for path in ("Fixtures/NewCapability/future-app-resource.json", "project.yml"):
            with self.subTest(path=path):
                selection = select_paths([path])
                self.assertEqual(set(selection.tests), set(CONSERVATIVE_TESTS))
                self.assertEqual(selection.locales, ("en",))

    def test_smoke_canaries_are_a_unique_unattended_subset_of_the_catalog(self):
        self.assertTrue(SMOKE_TESTS)
        self.assertEqual(len(SMOKE_TESTS), len(set(SMOKE_TESTS)))
        self.assertLessEqual(set(SMOKE_TESTS), set(ALL_TESTS))
        self.assertLess(len(SMOKE_TESTS), len(ALL_TESTS))

    def test_shards_partition_the_catalog_with_balanced_budgets(self):
        budget = json.loads(
            (ROOT / "docs/evidence/ui-test-runtime-budget.json").read_text(encoding="utf-8")
        )["testBudgetsSeconds"]
        shards = [ui_scope.shard_tests(ROOT, index, 3) for index in (1, 2, 3)]
        flattened = [test for shard in shards for test in shard]
        self.assertEqual(len(flattened), len(set(flattened)))
        self.assertEqual(set(flattened), set(ALL_TESTS))
        totals = []
        for shard in shards:
            self.assertTrue(shard)
            self.assertEqual(shard, tuple(test for test in ALL_TESTS if test in set(shard)))
            totals.append(sum(budget["/".join(test.split("/")[1:]) + "()"] for test in shard))
        self.assertLessEqual(max(totals) - min(totals), 0.05 * max(totals))
        for index in (0, 4):
            with self.subTest(index=index), self.assertRaises(ValueError):
                ui_scope.shard_tests(ROOT, index, 3)

    def test_full_suite_total_keeps_pace_with_the_catalog(self):
        budget = json.loads(
            (ROOT / "docs/evidence/ui-test-runtime-budget.json").read_text(encoding="utf-8")
        )
        self.assertIsNone(ui_scope.full_suite_total_error(budget, len(ALL_TESTS)))
        rate = budget["qualifiedCandidate"]["englishTestDurationSeconds"] / budget["qualifiedCandidate"]["caseCount"]
        grown = int(budget["fullSuite"]["maximumTestDurationSecondsPerLocale"] / rate) + 1
        self.assertIn("full-suite total", ui_scope.full_suite_total_error(budget, grown))

    def test_cli_shard_requires_all_and_emits_only_its_tests(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ui_scope.main(["--shard", "2/3", "Sources/portavoz-app/ContentView.swift"]), 2)
        self.assertIn("--shard requires --all", stderr.getvalue())

        for invalid in ("0/3", "4/3", "two/3"):
            with self.subTest(shard=invalid):
                with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(ui_scope.main(["--all", "--shard", invalid]), 2)

        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            status = ui_scope.main(["--all", "--shard", "2/3", "--format", "shell"])
        self.assertEqual(status, 0)
        exports = dict(
            line.removeprefix("export ").split("=", 1) for line in stdout.getvalue().splitlines()
        )
        self.assertEqual(exports["UI_TEST_REQUIRED"], "true")
        self.assertEqual(exports["UI_TEST_LOCALES"], "en")
        self.assertEqual(
            tuple(shlex.split(exports["UI_TESTS"])[0].split()),
            ui_scope.shard_tests(ROOT, 2, 3),
        )

    def test_catalog_policy_rejects_a_smoke_canary_outside_the_catalog(self):
        scoped = ui_scope.test_id("InsightsUITests", "testScoped")
        outside = ui_scope.test_id("InsightsUITests", "testOutside")
        temporary, root = self.minimal_catalog_root("testScoped")
        with temporary, mock.patch.multiple(
            ui_scope,
            FEATURE_TESTS={"insights": (scoped,)},
            ALL_TESTS=(scoped,),
            ALL_FEATURES=frozenset({"insights"}),
            SMOKE_TESTS=(scoped, outside),
            HARNESS_SELF_TESTS=(),
            DEPENDENCY_FEATURES={},
            FEATURE_SOURCE_SENTINELS={
                "insights": "Sources/portavoz-app/InsightsView.swift"
            },
            RETIRED_DUPLICATE_TESTS=frozenset(),
        ):
            with self.assertRaisesRegex(
                RuntimeError, rf"smoke canaries outside the catalog: {re.escape(outside)}$"
            ):
                ui_scope.validate_catalog(root, runtime_budget_required=False)

    def test_catalog_policy_rejects_a_self_test_outside_the_catalog(self):
        outside = ui_scope.test_id("InsightsUITests", "testOutside")
        with mock.patch.object(ui_scope, "HARNESS_SELF_TESTS", (outside,)):
            with self.assertRaisesRegex(RuntimeError, re.escape(outside)):
                validate_catalog(ROOT, runtime_budget_required=False)

    def test_working_tree_paths_keeps_staged_change_hidden_from_worktree_diff(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            path = repository / "Sources/portavoz-app/RecordingView.swift"
            path.parent.mkdir(parents=True)
            subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
            subprocess.run(
                ["git", "config", "user.email", "ui-scope@example.invalid"],
                cwd=repository,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "UI Scope Test"],
                cwd=repository,
                check=True,
            )
            path.write_text("base\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=repository, check=True)
            subprocess.run(["git", "commit", "-qm", "base"], cwd=repository, check=True)

            path.write_text("staged\n", encoding="utf-8")
            subprocess.run(["git", "add", str(path)], cwd=repository, check=True)
            subprocess.run(
                ["git", "restore", "--worktree", "--source=HEAD", "--", str(path)],
                cwd=repository,
                check=True,
            )

            self.assertEqual(
                working_tree_paths("HEAD", cwd=repository),
                ["Sources/portavoz-app/RecordingView.swift"],
            )

    def test_catalog_covers_every_declared_ui_test(self):
        validate_catalog(ROOT)

    def test_ui_harness_forbids_blind_sleeps_and_native_existence_polling(self):
        sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted((ROOT / "Tests" / "PortavozUITests").glob("*.swift"))
        )
        support = (ROOT / "Tests" / "PortavozUITests" / "UITestSupport.swift")
        support_source = support.read_text(encoding="utf-8")
        wait_source = (support.parent / "UITestWaitSupport.swift").read_text(encoding="utf-8")

        self.assertNotIn("Thread.sleep", sources)
        self.assertNotIn(".waitForExistence(", sources)
        self.assertNotIn(".waitForNonExistence(", sources)
        self.assertIn("func waitForUITestCondition(", wait_source)
        self.assertIn("func waitForExistenceFast(", support_source)
        self.assertIn("func waitForDisappearance(", support_source)
        self.assertIn("RunLoop.current.run", wait_source)
        settings_source = (
            ROOT / "Tests" / "PortavozUITests" / "SettingsUITests.swift"
        ).read_text(encoding="utf-8")
        self.assertNotIn(
            "settingsForm.scroll(byDeltaX: 0, deltaY: -18)",
            settings_source,
        )
        self.assertIn(
            "downloadFrame.maxY - visibleFormFrame.maxY",
            settings_source,
        )

    def test_catalog_policy_rejects_an_unscoped_test(self):
        scoped = ui_scope.test_id("InsightsUITests", "testScoped")
        temporary, root = self.minimal_catalog_root("testScoped", "testUnscoped")
        with temporary, mock.patch.multiple(
            ui_scope,
            FEATURE_TESTS={"insights": (scoped,)},
            ALL_TESTS=(scoped,),
            ALL_FEATURES=frozenset({"insights"}),
            FEATURE_SOURCE_SENTINELS={
                "insights": "Sources/portavoz-app/InsightsView.swift"
            },
            RETIRED_DUPLICATE_TESTS=frozenset(),
        ):
            with self.assertRaisesRegex(RuntimeError, "unscoped tests"):
                ui_scope.validate_catalog(root, runtime_budget_required=False)

    def test_catalog_policy_rejects_an_on_demand_case_in_unattended_scope(self):
        native = ui_scope.test_id("InsightsUITests", "testNativeGate")
        temporary, root = self.minimal_catalog_root("testNativeGate")
        with temporary, mock.patch.multiple(
            ui_scope,
            FEATURE_TESTS={"insights": (native,)},
            ALL_TESTS=(native,),
            ALL_FEATURES=frozenset({"insights"}),
            ON_DEMAND_TESTS=(native,),
            FEATURE_SOURCE_SENTINELS={
                "insights": "Sources/portavoz-app/InsightsView.swift"
            },
            RETIRED_DUPLICATE_TESTS=frozenset(),
        ):
            with self.assertRaisesRegex(RuntimeError, "on-demand tests in hosted catalog"):
                ui_scope.validate_catalog(root, runtime_budget_required=False)

    def test_catalog_policy_rejects_a_missing_on_demand_case(self):
        scoped = ui_scope.test_id("InsightsUITests", "testScoped")
        native = ui_scope.test_id("InsightsUITests", "testNativeGate")
        temporary, root = self.minimal_catalog_root("testScoped")
        with temporary, mock.patch.multiple(
            ui_scope,
            FEATURE_TESTS={"insights": (scoped,)},
            ALL_TESTS=(scoped,),
            ALL_FEATURES=frozenset({"insights"}),
            ON_DEMAND_TESTS=(native,),
            FEATURE_SOURCE_SENTINELS={
                "insights": "Sources/portavoz-app/InsightsView.swift"
            },
            RETIRED_DUPLICATE_TESTS=frozenset(),
        ):
            with self.assertRaisesRegex(RuntimeError, "stale selectors"):
                ui_scope.validate_catalog(root, runtime_budget_required=False)

    def test_catalog_policy_rejects_an_orphan_scope(self):
        scoped = ui_scope.test_id("InsightsUITests", "testScoped")
        temporary, root = self.minimal_catalog_root("testScoped", with_owner=False)
        with temporary, mock.patch.multiple(
            ui_scope,
            FEATURE_TESTS={"insights": (scoped,)},
            ALL_TESTS=(scoped,),
            ALL_FEATURES=frozenset({"insights"}),
            FEATURE_SOURCE_SENTINELS={
                "insights": "Sources/portavoz-app/InsightsView.swift"
            },
            RETIRED_DUPLICATE_TESTS=frozenset(),
        ):
            with self.assertRaisesRegex(RuntimeError, "orphan feature scopes"):
                ui_scope.validate_catalog(root, runtime_budget_required=False)

    def test_catalog_policy_rejects_a_no_ui_fixture_loaded_by_the_app(self):
        scoped = ui_scope.test_id("InsightsUITests", "testScoped")
        temporary, root = self.minimal_catalog_root("testScoped")
        loader = root / "Sources" / "portavoz-app" / "DictationFixtureLoader.swift"
        loader.write_text(
            'let corpus = "Fixtures/DictationValidation/public-synthetic-v1.json"\n',
            encoding="utf-8",
        )
        cli = root / "Sources" / "portavoz-cli" / "CLIDictationCorpus.swift"
        cli.parent.mkdir(parents=True)
        cli.write_text(loader.read_text(encoding="utf-8"), encoding="utf-8")
        with temporary, mock.patch.multiple(
            ui_scope,
            FEATURE_TESTS={"insights": (scoped,)},
            ALL_TESTS=(scoped,),
            ALL_FEATURES=frozenset({"insights"}),
            FEATURE_SOURCE_SENTINELS={
                "insights": "Sources/portavoz-app/InsightsView.swift"
            },
            RETIRED_DUPLICATE_TESTS=frozenset(),
        ):
            with self.assertRaisesRegex(
                RuntimeError,
                r"no-UI fixtures reachable from UI sources: Fixtures/DictationValidation "
                r"\(Sources/portavoz-app/DictationFixtureLoader.swift\)(;|$)",
            ):
                ui_scope.validate_catalog(root, runtime_budget_required=False)

    def test_catalog_policy_rejects_a_known_duplicate_journey(self):
        retired = ui_scope.test_id("InsightsUITests", "testRetiredDuplicate")
        temporary, root = self.minimal_catalog_root("testRetiredDuplicate")
        with temporary, mock.patch.multiple(
            ui_scope,
            FEATURE_TESTS={"insights": (retired,)},
            ALL_TESTS=(retired,),
            ALL_FEATURES=frozenset({"insights"}),
            FEATURE_SOURCE_SENTINELS={
                "insights": "Sources/portavoz-app/InsightsView.swift"
            },
            RETIRED_DUPLICATE_TESTS=frozenset({retired}),
        ):
            with self.assertRaisesRegex(RuntimeError, "known duplicate tests returned"):
                ui_scope.validate_catalog(root, runtime_budget_required=False)

    def test_consolidated_journey_duplicates_cannot_return_even_with_valid_scopes(self):
        for test_class, method in (
            ("SkillsSettingsUITests", "testSkillActivityExpandsOlderRunsOnlyAfterExplicitRequest"),
            ("SkillsSettingsUITests", "testSkillActivityRefreshPreservesTheExpandedCurrentScope"),
            ("LibraryUITests", "testAskConfirmedMemoryLoadsExactTopicDecisionsAndEvidence"),
            ("LibraryUITests", "testAskConfirmedMemoryLoadsExactTopicFirstDiscussionAndEvidence"),
            ("LibraryUITests", "testAskConfirmedMemoryLoadsExactTopicDecisionConflictsAndEvidence"),
            ("LibraryUITests", "testAskConfirmedMemoryLoadsExactTopicChangesSinceMeetingAndEvidence"),
            ("LibraryUITests", "testAskConfirmedMemoryLoadsExactPersonCommitmentsAndEvidence"),
            ("LibraryUITests", "testAskConfirmedMemoryLoadsExactCommitmentBlockersAndEvidence"),
        ):
            with self.subTest(method=method):
                selector = ui_scope.test_id(test_class, method)
                temporary, root = self.minimal_catalog_root(method)
                with temporary:
                    source = root / "Tests/PortavozUITests/InsightsUITests.swift"
                    source.write_text(source.read_text().replace(
                        "class InsightsUITests", f"class {test_class}"))
                    source.rename(source.with_name(f"{test_class}.swift"))
                    with mock.patch.multiple(
                        ui_scope,
                        FEATURE_TESTS={"insights": (selector,)},
                        ALL_TESTS=(selector,),
                        ALL_FEATURES=frozenset({"insights"}),
                        FEATURE_SOURCE_SENTINELS={
                            "insights": "Sources/portavoz-app/InsightsView.swift"
                        },
                    ):
                        with self.assertRaisesRegex(RuntimeError, "known duplicate tests returned"):
                            ui_scope.validate_catalog(root, runtime_budget_required=False)

    def test_catalog_policy_rejects_duplicate_selectors_inside_scope(self):
        scoped = ui_scope.test_id("InsightsUITests", "testScoped")
        temporary, root = self.minimal_catalog_root("testScoped")
        with temporary, mock.patch.multiple(
            ui_scope,
            FEATURE_TESTS={"insights": (scoped, scoped)},
            ALL_TESTS=(scoped,),
            ALL_FEATURES=frozenset({"insights"}),
            FEATURE_SOURCE_SENTINELS={
                "insights": "Sources/portavoz-app/InsightsView.swift"
            },
            RETIRED_DUPLICATE_TESTS=frozenset(),
        ):
            with self.assertRaisesRegex(RuntimeError, "duplicate selectors"):
                ui_scope.validate_catalog(root, runtime_budget_required=False)


class PullRequestBaseSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        self.write_commit("README.md", "base\n")
        self.root = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("update-ref", "refs/remotes/origin/main", self.root)
        self.write_commit("Sources/portavoz-app/DictationSection.swift", "parent view\n")
        self.parent = self.git("rev-parse", "HEAD").stdout.strip()
        self.write_commit("docs/GAPS.md", "child documentation\n")
        self.head = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *arguments):
        return subprocess.run(["git", *arguments], cwd=self.repository, check=True, capture_output=True, text=True)

    def write_commit(self, path, content):
        target = self.repository / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        self.git("add", path)
        self.git("commit", "-qm", f"Add {path}")

    def select(self, pull_request_base, *extra):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts/ui_test_scope.py"), "--pull-request-base", pull_request_base,
             "--head", self.head, "--format", "github", *extra],
            cwd=self.repository, capture_output=True, text=True)
        return result, dict(line.split("=", 1) for line in result.stdout.splitlines())

    def test_child_docs_change_still_selects_the_parents_view_journey(self):
        run, outputs = self.select(self.parent)

        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(outputs["required"], "true")
        self.assertIn("testTheDataPaneDeletesLegacyDictationHistory", outputs["tests"])

    def test_a_direct_pull_request_diffs_from_its_merge_base_when_main_moved_on(self):
        self.git("checkout", "-q", "-b", "newer-main", self.root)
        self.write_commit("Sources/portavoz-app/HomeView.swift", "main moved on\n")
        newer_main = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("update-ref", "refs/remotes/origin/main", newer_main)

        run, outputs = self.select(newer_main)

        self.assertEqual(run.returncode, 0, run.stderr)
        own = ui_scope.select_paths(["Sources/portavoz-app/DictationSection.swift", "docs/GAPS.md"])
        self.assertEqual(outputs["tests"].split(), list(own.tests))

    def test_what_a_child_changed_ranks_before_what_its_parents_changed(self):
        self.git("reset", "-q", "--hard", self.parent)
        self.write_commit("Sources/portavoz-app/HomeView.swift", "child view\n")
        self.head = self.git("rev-parse", "HEAD").stdout.strip()

        child = ui_scope.select_paths(["Sources/portavoz-app/HomeView.swift"])
        parent = ui_scope.select_paths(["Sources/portavoz-app/DictationSection.swift"])
        only_child = set(child.tests) - set(ui_scope.SMOKE_TESTS)

        run, outputs = self.select(self.parent, "--ranked")

        self.assertEqual(run.returncode, 0, run.stderr)
        ranked = outputs["ranked"].split()
        self.assertEqual(set(ranked[:len(only_child)]), only_child)
        self.assertLessEqual(set(parent.tests) - only_child - set(ui_scope.SMOKE_TESTS), set(ranked[len(only_child):]))

    def test_a_parents_shared_harness_change_keeps_the_self_test_on_the_child(self):
        self.git("reset", "-q", "--hard", self.parent)
        self.write_commit("project.yml", "parent shared UI harness\n")
        self.parent = self.git("rev-parse", "HEAD").stdout.strip()
        self.write_commit("docs/GAPS.md", "new child documentation\n")
        self.head = self.git("rev-parse", "HEAD").stdout.strip()

        run, outputs = self.select(self.parent)

        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("testSharedScratchProtectsOwnershipAndRoundTripsAppFixtures", outputs["tests"])

    def test_a_missing_default_branch_fails_instead_of_using_the_parent(self):
        self.git("update-ref", "-d", "refs/remotes/origin/main")

        run, _ = self.select(self.parent)

        self.assertEqual(run.returncode, 2)
        self.assertIn("::error title=UI scope::", run.stderr)
        self.assertEqual(run.stdout, "")

    def test_criss_cross_history_widens_to_the_shared_root(self):
        self.git("checkout", "-q", "-B", "main-line", self.root)
        self.write_commit("docs/ROADMAP-public.md", "main side\n")
        main_side = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "-q", "-B", "child-line", self.root)
        self.write_commit("Sources/portavoz-app/DictationSection.swift", "child view\n")
        child_side = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("merge", "-q", "--no-edit", main_side)
        self.head = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "-q", "main-line")
        self.git("merge", "-q", "--no-edit", child_side)
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        roots = self.git("merge-base", "--all", "refs/remotes/origin/main", self.head).stdout.split()
        self.assertEqual(set(roots), {main_side, child_side})

        run, outputs = self.select(self.root)

        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("testTheDataPaneDeletesLegacyDictationHistory", outputs["tests"])


if __name__ == "__main__":
    unittest.main()
