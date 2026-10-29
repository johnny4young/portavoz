import contextlib
import hashlib
import io
import json
import re
import runpy
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import ui_test_scope as ui_scope  # noqa: E402
from ui_test_scope import (  # noqa: E402
    ALL_TESTS,
    FEATURE_TESTS,
    HARNESS_TESTS,
    MEETING_FEATURES,
    PERMISSION_GATED_TESTS,
    SMOKE_TESTS,
    select_paths,
    validate_catalog,
    working_tree_paths,
)


class UITestScopeTests(unittest.TestCase):
    def test_compact_detail_column_selects_every_journey_that_opens_a_meeting(self):
        path = "Sources/portavoz-app/MeetingDetailPrimaryColumn.swift"
        selection = select_paths([path])
        self.assertEqual(set(selection.tests), set(HARNESS_TESTS))
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
        self.assertEqual(len(expected), 2)
        for path in paths:
            selection = select_paths([path])
            self.assertEqual(set(selection.tests), expected, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_package_changes_cannot_bypass_ui_evidence(self):
        manifest = select_paths(["Package.swift"])
        self.assertTrue(manifest.required)
        self.assertEqual(manifest.tests, ALL_TESTS)
        self.assertEqual(manifest.locales, ("en",))

        lock = select_paths(["Package.resolved"])
        self.assertTrue(lock.required)
        self.assertEqual(lock.tests, ALL_TESTS)
        self.assertEqual(lock.locales, ("en",))
        self.assertEqual(lock.reasons, ("Package.resolved: complete English dependency fallback",))

    def test_package_changes_keep_complete_harness_expansion(self):
        selection = select_paths(["Package.swift", "project.yml"])
        self.assertEqual(selection.tests, ALL_TESTS)
        self.assertEqual(selection.locales, ("en",))

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
        self.assertEqual(unknown_fixture.tests, ALL_TESTS)
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
        self.assertEqual(outputs["locales"], "en")
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
        expected = set(FEATURE_TESTS["launch-recovery"])
        expected.update(FEATURE_TESTS["main-shell"])
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
                all("MeetingDetailUITests" in test for test in selection.tests),
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
        self.assertEqual(unknown.tests, ALL_TESTS, "changed keys must be known to narrow the run")
        quoted = select_paths([catalog], {"Live captions are available now."}, ROOT)
        library = {test for test in ALL_TESTS if "/LibraryUITests/" in test}
        self.assertTrue(library <= set(quoted.tests))
        self.assertTrue(set(SMOKE_TESTS) <= set(quoted.tests))
        self.assertLess(len(quoted.tests), len(ALL_TESTS))
        formatted = select_paths([catalog], {"Apple summaries are unavailable: %@. Choose Ollama or Built-in (MLX)."}, ROOT)
        self.assertTrue(set(SMOKE_TESTS) <= set(formatted.tests))
        spanish_only = select_paths([catalog], set(), ROOT)
        self.assertFalse(spanish_only.required, "Spanish values belong to LocalizationTests")

    def test_catalog_changes_compare_english_keys_between_revisions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*arguments):
                return subprocess.run(["git", *arguments], cwd=root, check=True, capture_output=True, text=True).stdout
            git("init", "-q", "-b", "main")
            git("config", "user.email", "fixture@example.invalid")
            git("config", "user.name", "Fixture")
            path = root / ui_scope.CATALOG
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps({"strings": {"Keep": {}, "Old copy": {}}}))
            git("add", "-A")
            git("commit", "-q", "-m", "base")
            base = git("rev-parse", "HEAD").strip()
            path.write_text(json.dumps({"strings": {"Keep": {"localizations": {"es": {}}}, "New copy": {}}}))
            git("commit", "-qam", "copy")
            self.assertEqual(ui_scope.catalog_changes(base, "HEAD", root), {"Old copy", "New copy"})
            self.assertEqual(ui_scope.catalog_changes(base, None, root), {"Old copy", "New copy"})
            self.assertIsNone(ui_scope.catalog_changes("0" * 40, "HEAD", root))

    @contextlib.contextmanager
    def catalog_revisions(self, before, after):
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
            git("commit", "-qam", "copy")
            yield root, base

    def test_catalog_changes_track_stable_key_english_overrides(self):
        key = "Live captions are available now."
        def entry(value):
            return {"localizations": {"en": {"stringUnit": {"value": value}}}}
        cases = (
            ({}, entry("Captions are ready to read.")),
            (entry("Captions were ready to read."), entry("Captions are ready to read.")),
            (entry("Captions were ready to read."), {}),
            (entry("Captions were ready to read."), entry("")),
            (entry("Captions were ready to read."), entry(None)),
        )
        exported_value = runpy.run_path(str(ROOT / "scripts/export-localizations.py"))["localized_value"]
        for before, after in cases:
            with self.subTest(before=before, after=after), self.catalog_revisions(
                {"strings": {key: before}}, {"strings": {key: after}}
            ) as (root, base):
                expected = {key, exported_value(before, "en", key), exported_value(after, "en", key)}
                for head in ("HEAD", None):
                    changed = ui_scope.catalog_changes(base, head, root)
                    self.assertEqual(changed, expected)
                    selected = select_paths([ui_scope.CATALOG], changed, ROOT)
                    self.assertTrue(set(SMOKE_TESTS) <= set(selected.tests))
                    library = {test for test in ALL_TESTS if "/LibraryUITests/" in test}
                    self.assertTrue(library <= set(selected.tests))
                    self.assertLess(len(selected.tests), len(ALL_TESTS))

    def test_catalog_override_changes_select_old_and_new_quoted_values(self):
        key = "stable-caption-key"
        old, new = "Old caption override text.", "New caption override text."
        def catalog(value):
            return {"strings": {key: {"localizations": {"en": {"stringUnit": {"value": value}}}}}}
        with self.catalog_revisions(catalog(old), catalog(new)) as (root, base):
            tests = root / "Tests/PortavozUITests"
            tests.mkdir(parents=True)
            for name, value in (("LibraryUITests", old), ("InsightsUITests", new)):
                (tests / f"{name}.swift").write_text(f'// Assertion quoting "{value}"\n', encoding="utf-8")
            for head in ("HEAD", None):
                changed = ui_scope.catalog_changes(base, head, root)
                self.assertEqual(changed, {key, old, new})
                selected = select_paths([ui_scope.CATALOG], changed, root)
                for name in ("LibraryUITests", "InsightsUITests"):
                    expected = {test for test in ALL_TESTS if f"/{name}/" in test}
                    self.assertTrue(expected)
                    self.assertTrue(expected <= set(selected.tests))

    def test_catalog_changes_include_overrides_for_added_and_removed_keys(self):
        def catalog(key, value):
            return {"strings": {key: {"localizations": {"en": {"stringUnit": {"value": value}}}}}}
        with self.catalog_revisions(
            catalog("old-key", "Old English override."), catalog("new-key", "New English override.")
        ) as (root, base):
            for head in ("HEAD", None):
                self.assertEqual(
                    ui_scope.catalog_changes(base, head, root),
                    {"old-key", "new-key", "Old English override.", "New English override."},
                )

    def test_catalog_changes_use_exporter_fallback_and_ignore_spanish_only(self):
        key = "Live captions are available now."
        before = {"strings": {key: {}}}
        entries = (
            {"localizations": {"es": {"stringUnit": {"value": "Los subtítulos están disponibles."}}}},
            {"localizations": {"en": {}}},
            {"localizations": {"en": {"stringUnit": {}}}},
            {"localizations": {"en": {"stringUnit": {"value": ""}}}},
            {"localizations": {"en": {"stringUnit": {"value": None}}}},
            {"localizations": {"en": {"stringUnit": {"value": key, "state": "translated"}}}},
        )
        exported_value = runpy.run_path(str(ROOT / "scripts/export-localizations.py"))["localized_value"]
        for entry in entries:
            with self.subTest(entry=entry), self.catalog_revisions(before, {"strings": {key: entry}}) as (root, base):
                self.assertEqual(exported_value(entry, "en", key), key)
                for head in ("HEAD", None):
                    changed = ui_scope.catalog_changes(base, head, root)
                    self.assertEqual(changed, set())
                    self.assertFalse(select_paths([ui_scope.CATALOG], changed, ROOT).required)

    def test_catalog_changes_fail_closed_for_malformed_english_data(self):
        valid = {"strings": {"Keep": {}}}
        malformed = (
            [], {}, {"strings": []}, {"strings": {"Keep": None}},
            {"strings": {"Keep": {"localizations": []}}},
            {"strings": {"Keep": {"localizations": {"en": None}}}},
            {"strings": {"Keep": {"localizations": {"en": {"stringUnit": []}}}}},
            {"strings": {"Keep": {"localizations": {"en": {"stringUnit": {"value": 42}}}}}},
        )
        for invalid in malformed:
            for before, after in ((valid, invalid), (invalid, valid)):
                with self.subTest(before=before, after=after), self.catalog_revisions(before, after) as (root, base):
                    for head in ("HEAD", None):
                        changed = ui_scope.catalog_changes(base, head, root)
                        self.assertIsNone(changed)
                        self.assertEqual(select_paths([ui_scope.CATALOG], changed, ROOT).tests, ALL_TESTS)

    def test_no_path_combination_selects_spanish(self):
        selection = select_paths([
            "Resources/Localization/Portavoz/Localizable.xcstrings",
            "Tests/PortavozUITests/UITestSupport.swift",
            "Sources/portavoz-app/UITestDefaults.swift",
            "Sources/portavoz-app/PortavozAppIntents.swift",
            "Fixtures/ApuntadorWeb/public-local-v1.json",
            *sorted(ui_scope.APUNTADOR_LEAK_EVIDENCE_FILES),
        ])
        self.assertEqual(selection.tests, ALL_TESTS)
        self.assertEqual(selection.locales, ("en",))
        self.assertEqual(ui_scope.SELECTION_LOCALES, ("en",))

    def test_all_selects_every_test_in_english_only(self):
        for output_format, expected in (
            ("github", {"locales=en", 'matrix=["en"]', "interruption_controls=true"}),
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

    def test_pr_scope_advances_only_from_verified_ancestor_artifacts(self):
        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text(
            encoding="utf-8"
        )

        self.assertNotIn("PREVIOUS_HEAD_SHA", workflow)
        self.assertNotIn("github.event.before", workflow)
        self.assertIn("actions: read", workflow)
        self.assertIn("scripts/ui_test_verified_base.py", workflow)
        self.assertIn('--base "$VERIFIED_BASE_SHA"', workflow)
        self.assertIn("github.run_attempt == 1", workflow)
        self.assertIn("ui-verification-${{", workflow)
        self.assertIn("retention-days: 90", workflow)
        self.assertIn(
            "python3 scripts/ui_test_scope.py --all --format github",
            workflow,
        )

    def test_hosted_ui_builds_once_runs_locale_lanes_and_gates_after_artifacts(self):
        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text(
            encoding="utf-8"
        )

        # One build job publishes the exact products; one matrix lane per
        # selected locale restores them and runs without rebuilding.
        self.assertEqual(workflow.count("run: make test-ui-build"), 1)
        self.assertEqual(workflow.count("run: make test-ui-run"), 1)
        self.assertEqual(workflow.count("continue-on-error: true"), 1)
        self.assertEqual(
            workflow.count('UI_TEST_ENFORCE_RUNTIME_BUDGET: "false"'),
            1,
        )
        self.assertIn("matrix:\n        locale: ${{ fromJSON(needs.scope.outputs.matrix) }}", workflow)
        self.assertIn("UI_TEST_LOCALES: ${{ matrix.locale }}", workflow)
        self.assertIn("UI_TEST_PRODUCTS_PATH:", workflow)
        self.assertIn('--english-outcome "$(outcome en)"', workflow)
        self.assertNotIn("--spanish-outcome", workflow)
        self.assertIn("runs-on: macos-26", workflow)
        self.assertIn("Xcode_26.6.app/Contents/Developer", workflow)
        for job in ("interruption-controls", "build-ui-products"):
            body = re.search(rf"(?ms)^  {job}:\n(.*?)(?=^  [a-z][a-z-]+:\n|\Z)", workflow).group(1)
            self.assertEqual(body.count("scripts/install-ci-xcodegen.sh"), 1, job)
        self.assertNotIn("brew install xcodegen", workflow)
        artifact = workflow.index("Preserve ${{ matrix.locale }} UI evidence")
        gate = workflow.index("Classify functional evidence and hosted runtime drift")
        self.assertLess(artifact, gate)
        self.assertNotIn("run: make test-ui-scoped", workflow)

    def test_github_selection_emits_a_json_locale_matrix(self):
        selection = ui_scope.Selection(
            tests=("PortavozUITests/HomeUITests/testTodayAsksAndRecordsWithoutTyping",),
            locales=("en",),
            reasons=("localization catalog changed",),
        )
        rendered = ui_scope.render(selection, "github")
        self.assertIn('matrix=["en"]', rendered)
        empty = ui_scope.Selection(tests=(), locales=(), reasons=())
        self.assertIn("matrix=[]", ui_scope.render(empty, "github"))

    def test_ui_scope_does_not_duplicate_repository_tooling_suites(self):
        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text(
            encoding="utf-8"
        )

        self.assertEqual(
            workflow.count("scripts/ui_test_scope.py --validate-catalog"),
            1,
        )
        self.assertNotIn("python3 -m unittest Tests.Tooling", workflow)

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
        self.assertIn(
            "PortavozUITests/MeetingDetailUITests/testMostRecentRecipeRemainsVisibleAfterReload",
            selection.tests,
        )
        self.assertIn(
            "PortavozUITests/LibraryUITests/testSeededMeetingsGroupByRecency",
            selection.tests,
        )
        self.assertLess(len(selection.tests), len(ALL_TESTS))

    def test_companion_refresh_selects_correction_publication_evidence(self):
        expected = {
            "PortavozUITests/MeetingDetailUITests/"
            "testExplicitApuntadorRefreshUsesCorrectedTranscript",
            "PortavozUITests/MeetingDetailUITests/"
            "testNoAppleIntelligenceApuntadorRefreshPreservesStaleAnswers",
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

    def test_meeting_detail_scene_and_presentation_select_all_detail_journeys(self):
        self.assertNotIn("meeting-brief", MEETING_FEATURES)
        for path in [
            "Sources/portavoz-app/MeetingDetailScene.swift",
            "Sources/portavoz-app/MeetingDetailPresentation.swift",
        ]:
            selection = select_paths([path])
            expected = tuple(
                test for test in ALL_TESTS
                if test in {
                    item
                    for feature in MEETING_FEATURES
                    for item in FEATURE_TESTS[feature]
                }
            )
            self.assertEqual(selection.tests, expected, path)
            self.assertEqual(selection.locales, ("en",), path)
            self.assertNotIn(
                FEATURE_TESTS["meeting-brief"][0],
                selection.tests,
                path,
            )

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

    def test_window_placement_expands_to_the_complete_english_catalog(self):
        for path in (
            "Sources/portavoz-app/UITestWindowPlacement.swift",
            "Sources/portavoz-app/SettingsSkillReceiptNavigation.swift",
        ):
            with self.subTest(path=path):
                selection = select_paths([path])
                self.assertEqual(selection.tests, HARNESS_TESTS)
                self.assertEqual(selection.locales, ("en",))

    def test_seed_fixtures_expand_to_the_complete_english_catalog(self):
        for path in (
            "Sources/portavoz-app/AppServices+UITestFixtures.swift",
            "Sources/portavoz-app/AppServices+LiveAssistUITestFixture.swift",
            "Sources/portavoz-app/AppServices+StorageComposition.swift",
            "Sources/portavoz-app/AppServices+AskTopicMemoryUITestFixture.swift",
            "Sources/portavoz-app/UITestDefaults.swift",
        ):
            with self.subTest(path=path):
                selection = select_paths([path])
                self.assertEqual(selection.tests, HARNESS_TESTS)
                self.assertEqual(selection.locales, ("en",))
                self.assertIn("seed-fixture fallback", selection.reasons[0])

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

    def test_native_delivery_journeys_are_discoverable_explicit_gates_not_hosted_passes(self):
        native = ui_scope.test_id(
            "DictationUITests", "testNativeInserterUsesDisposableReceiverAndClipboard"
        )
        controller = ui_scope.test_id(
            "DictationUITests", "testNativeControllerModeChoicePreservesReceiverAndClipboard"
        )
        self.assertEqual(PERMISSION_GATED_TESTS, frozenset({native, controller}))
        for selector in (native, controller):
            self.assertNotIn(selector, ALL_TESTS)
            self.assertNotIn(selector, FEATURE_TESTS["dictation"])
            self.assertIn(selector, ui_scope.discovered_test_catalog(ROOT))
        budget = json.loads((
            ROOT / "docs/evidence/ui-test-native-dictation-runtime-budget.json"
        ).read_text(encoding="utf-8"))
        self.assertEqual(budget["catalog"]["expectedCaseCount"], 2)
        self.assertEqual(
            budget["testBudgetsSeconds"],
            {"DictationUITests/testNativeInserterUsesDisposableReceiverAndClipboard()": 20.0,
             "DictationUITests/testNativeControllerModeChoicePreservesReceiverAndClipboard()": 20.0},
        )
        self.assertEqual(budget["fullSuite"], {
            "maximumP95Seconds": 20.0,
            "maximumTestDurationSecondsPerLocale": 40.0,
        })
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        native_target = makefile.split("test-ui-native-dictation:", 1)[1].split("\n\n", 1)[0]
        self.assertIn(native, native_target)
        self.assertIn(controller, native_target)
        self.assertIn("ui-test-native-dictation-runtime-budget.json", native_target)
        validate_catalog(ROOT)

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
            self.assertEqual(len(selection.tests), 2, path)

    def test_atomic_snapshot_helper_requires_the_complete_catalog_without_neighboring_changes(self):
        path = "Tests/PortavozUITests/UITestSnapshotSupport.swift"
        selection = select_paths([path])
        self.assertEqual(selection.tests, HARNESS_TESTS)
        self.assertEqual(selection.locales, ("en",))

    def test_shared_fixture_build_sources_and_permission_require_full_catalog(self):
        for path in (
            "Package.swift",
            "packaging/portavoz-uitests.entitlements",
            "Tests/Support/UITestScratch.swift",
            "Tests/PortavozUITests/UITestStorageSupport.swift",
        ):
            with self.subTest(path=path):
                selection = select_paths([path])
                self.assertEqual(selection.tests, HARNESS_TESTS)
                self.assertEqual(selection.locales, ("en",))

    def test_harness_change_expands_to_the_complete_english_catalog(self):
        self.assertIn(
            "scripts/candidate_automation.py",
            ui_scope.FULL_HARNESS_FILES,
        )
        for path in sorted(ui_scope.FULL_HARNESS_FILES):
            selection = select_paths([path])
            self.assertEqual(selection.tests, HARNESS_TESTS, path)
            self.assertEqual(selection.locales, ("en",), path)

    def test_leak_evidence_owners_select_only_their_product_paths(self):
        expected_set = set(
            FEATURE_TESTS["ask"]
            + FEATURE_TESTS["background-work"]
            + FEATURE_TESTS["live-assist"]
        )
        expected = tuple(test for test in ALL_TESTS if test in expected_set)
        # Includes five distinct assist journeys: layout, identity/reentry,
        # manual requests, coalesced arrivals and unsubmitted drafts, plus four
        # durable-input journeys: recovery, retry, removal and held-write Stop.
        # Topic jobs share one owner without dropping their four result/citation paths;
        # Ask also owns the dictation-source journey.
        self.assertEqual(len(expected), 18)
        self.assertTrue(ui_scope.APUNTADOR_LEAK_EVIDENCE_FILES.isdisjoint(
            ui_scope.FULL_HARNESS_FILES
        ))
        for path in sorted(ui_scope.APUNTADOR_LEAK_EVIDENCE_FILES):
            selection = select_paths([path])
            self.assertEqual(selection.tests, expected, path)
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

    def test_changed_ui_test_file_selects_only_its_class(self):
        selection = select_paths(["Tests/PortavozUITests/InsightsUITests.swift"])
        self.assertEqual(selection.tests, FEATURE_TESTS["insights"])
        self.assertTrue(all("InsightsUITests" in test for test in selection.tests))

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
                self.assertEqual(select_paths([unknown]).tests, ALL_TESTS)
        for research in ("Sources/portavoz-cli-main/main.swift", "Sources/CSQLiteVecResearch/sqlite-vec.c",
                         "Sources/SQLiteVecResearchKit/Ranker.swift"):
            with self.subTest(path=research):
                self.assertFalse(select_paths([research]).required)
        for path in ("Sources/portavoz-app/L10n.swift", "Sources/portavoz-app/AppLanguage.swift"):
            with self.subTest(path=path):
                self.assertEqual(select_paths([path]).tests, ALL_TESTS)

    def smoke_selection(self):
        return tuple(test for test in ALL_TESTS if test in set(SMOKE_TESTS))

    def test_unknown_non_swift_paths_keep_the_full_english_fallback(self):
        for path in ("Fixtures/NewCapability/future-app-resource.json", "project.yml"):
            with self.subTest(path=path):
                selection = select_paths([path])
                self.assertEqual(selection.tests, ALL_TESTS)
                self.assertEqual(selection.locales, ("en",))

    def test_smoke_canaries_are_a_unique_unattended_subset_of_the_catalog(self):
        self.assertTrue(SMOKE_TESTS)
        self.assertEqual(len(SMOKE_TESTS), len(set(SMOKE_TESTS)))
        self.assertLessEqual(set(SMOKE_TESTS), set(ALL_TESTS))
        self.assertTrue(set(SMOKE_TESTS).isdisjoint(PERMISSION_GATED_TESTS))
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
            FEATURE_SOURCE_SENTINELS={
                "insights": "Sources/portavoz-app/InsightsView.swift"
            },
            RETIRED_DUPLICATE_TESTS=frozenset(),
        ):
            with self.assertRaisesRegex(
                RuntimeError, rf"smoke canaries outside the catalog: {re.escape(outside)}$"
            ):
                ui_scope.validate_catalog(root, runtime_budget_required=False)

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

    def test_catalog_policy_rejects_permission_gate_in_unattended_scope(self):
        native = ui_scope.test_id("InsightsUITests", "testNativeGate")
        temporary, root = self.minimal_catalog_root("testNativeGate")
        with temporary, mock.patch.multiple(
            ui_scope,
            FEATURE_TESTS={"insights": (native,)},
            ALL_TESTS=(native,),
            ALL_FEATURES=frozenset({"insights"}),
            PERMISSION_GATED_TESTS=frozenset({native}),
            FEATURE_SOURCE_SENTINELS={
                "insights": "Sources/portavoz-app/InsightsView.swift"
            },
            RETIRED_DUPLICATE_TESTS=frozenset(),
        ):
            with self.assertRaisesRegex(RuntimeError, "permission-gated tests in hosted catalog"):
                ui_scope.validate_catalog(root, runtime_budget_required=False)

    def test_catalog_policy_rejects_missing_permission_gate(self):
        scoped = ui_scope.test_id("InsightsUITests", "testScoped")
        native = ui_scope.test_id("InsightsUITests", "testNativeGate")
        temporary, root = self.minimal_catalog_root("testScoped")
        with temporary, mock.patch.multiple(
            ui_scope,
            FEATURE_TESTS={"insights": (scoped,)},
            ALL_TESTS=(scoped,),
            ALL_FEATURES=frozenset({"insights"}),
            PERMISSION_GATED_TESTS=frozenset({native}),
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


if __name__ == "__main__":
    unittest.main()
