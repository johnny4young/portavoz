import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class CIWorkflowTests(unittest.TestCase):
    def test_release_authority_job_names_remain_stable(self):
        contract = json.loads(
            (ROOT / "docs/evidence/source-integration-qualification.json").read_text(
                encoding="utf-8"
            )
        )
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")

        expected = [
            "build-and-test",
            "ios-portability",
            "sequoia-compatibility",
            "lint",
            "repository-hygiene",
        ]
        self.assertEqual(contract["hostedCI"]["requiredJobs"], expected)
        for job in expected:
            self.assertEqual(workflow.count(f"  {job}:\n"), 1, job)

    def test_current_sdk_uses_one_fixed_toolchain_test_build(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")

        self.assertIn("runs-on: macos-26", workflow)
        self.assertIn(
            "DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer",
            workflow,
        )
        self.assertEqual(
            workflow.count(
                "scripts/run-swift-tests.sh -Xswiftc -warnings-as-errors"
            ),
            1,
        )
        self.assertNotIn("run: swift build", workflow)
        self.assertNotIn("Select newest Xcode", workflow)
        self.assertNotIn("sort -V", workflow)

    def test_sequoia_lane_is_real_and_exact(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")

        self.assertEqual(workflow.count("runs-on: macos-15"), 1)
        self.assertIn(
            "DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer",
            workflow,
        )
        self.assertIn("scripts/verify-ci-toolchain.sh 15 26.3", workflow)
        self.assertIn("scripts/run-swift-tests.sh", workflow)

    def test_ios_portability_is_isolated_without_fake_runtime_evidence(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        runner = (ROOT / "scripts/check-ios-portability.sh").read_text(
            encoding="utf-8"
        )

        self.assertEqual(workflow.count("  ios-portability:\n"), 1)
        self.assertIn("run: scripts/check-ios-portability.sh", workflow)
        self.assertIn("arm64-apple-ios17.0-simulator", runner)
        self.assertIn(
            "targets=(PortavozCore StorageKit ApplicationKit IntegrationsKit)",
            runner,
        )
        self.assertNotIn("xcodebuild test", runner)
        self.assertNotIn("CloudKit", runner)

    def test_lint_uses_checksum_pinned_official_archive_on_linux(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        runner = (ROOT / "scripts/run-ci-swiftlint.sh").read_text(encoding="utf-8")

        self.assertIn("run: scripts/run-ci-swiftlint.sh", workflow)
        self.assertNotIn("brew install swiftlint", workflow)
        self.assertIn('version="0.65.0"', runner)
        self.assertIn(
            "79306a34e5c7cc55a220cd108cbb861dcad5f10138dcdf261e2624ae8b0a486b",
            runner,
        )
        self.assertNotIn(":latest", runner)

    def test_ui_generator_is_checksum_pinned_and_no_test_retry_exists(self):
        installer = (ROOT / "scripts/install-ci-xcodegen.sh").read_text(
            encoding="utf-8"
        )
        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn('version="2.46.0"', installer)
        self.assertIn(
            "4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806",
            installer,
        )
        self.assertNotIn("brew install xcodegen", workflow)
        self.assertNotIn("-retry-tests-on-failure", workflow)
        self.assertNotIn("test-iterations", workflow)
        self.assertIn("cannot manufacture qualifying UI evidence", workflow)

    def test_complete_bilingual_ui_job_has_bounded_orchestration_headroom(self):
        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text(
            encoding="utf-8"
        )
        scoped_job = workflow.split("  scoped-ui-tests:\n", 1)[1].split(
            "\n  ui-test-gate:\n", 1
        )[0]

        self.assertEqual(scoped_job.count("    timeout-minutes: 90\n"), 1)
        self.assertNotIn("timeout-minutes: 60", scoped_job)
        self.assertIn(
            "90-minute job-orchestration ceiling is not a per-test/runtime budget",
            scoped_job,
        )

    def test_locale_lanes_share_one_build_and_one_classifier(self):
        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text(
            encoding="utf-8"
        )
        runner = (ROOT / "scripts/run-ui-tests.sh").read_text(encoding="utf-8")
        build_job = workflow.split("  build-ui-products:\n", 1)[1].split(
            "\n  scoped-ui-tests:\n", 1
        )[0]
        scoped_job = workflow.split("  scoped-ui-tests:\n", 1)[1].split(
            "\n  ui-test-gate:\n", 1
        )[0]
        gate_job = workflow.split("  ui-test-gate:\n", 1)[1].split(
            "\n  verification-anchor:\n", 1
        )[0]

        # Exactly one build owns the products; every lane restores them.
        self.assertEqual(workflow.count("run: make test-ui-build"), 1)
        self.assertIn("-testProductsPath", runner)
        self.assertIn("UI_TEST_PRODUCTS_PATH", build_job)
        self.assertIn("fail-fast: false", scoped_job)
        self.assertIn("locale: ${{ fromJSON(needs.scope.outputs.matrix) }}", scoped_job)
        self.assertEqual(scoped_job.count("run: make test-ui-run"), 1)
        self.assertNotIn("xcodegen", scoped_job.lower())
        # One Linux classifier reads every lane's receipts and outcome.
        self.assertEqual(workflow.count("scripts/ui_test_ci_gate.py"), 1)
        self.assertIn("scripts/ui_test_ci_gate.py", gate_job)
        self.assertIn("merge-multiple: true", gate_job)
        self.assertIn("needs.ui-test-gate.outputs.verified == 'true'", workflow)

    def test_repository_contracts_have_one_linux_owner_before_macos(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        ui = (ROOT / ".github/workflows/ui-tests.yml").read_text(encoding="utf-8")

        self.assertEqual(ci.count("run: scripts/check-repository-hygiene.sh"), 1)
        self.assertEqual(ci.count("needs: repository-hygiene"), 4)
        self.assertNotIn("python3 -m unittest Tests.Tooling", ui)
        self.assertEqual(
            ui.count("scripts/ui_test_scope.py --validate-catalog"),
            1,
        )

    def test_ui_scope_requires_first_attempt_anchor_and_never_previous_push(self):
        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("id: verified_base", workflow)
        self.assertIn("scripts/ui_test_verified_base.py", workflow)
        self.assertIn("github.run_attempt == 1", workflow)
        self.assertIn("retention-days: 90", workflow)
        self.assertNotIn("github.event.before", workflow)
        self.assertNotIn("PREVIOUS_HEAD_SHA", workflow)

    def test_stacked_ui_scope_passes_both_branch_identities_to_resolver(self):
        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("BASE_BRANCH: ${{ github.event.pull_request.base.ref }}", workflow)
        self.assertIn("DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}", workflow)
        self.assertIn('--base-branch "$BASE_BRANCH"', workflow)
        self.assertIn('--default-branch "$DEFAULT_BRANCH"', workflow)
        self.assertIn('--base "$VERIFIED_BASE_SHA" --head "$HEAD_SHA"', workflow)


class UIPrerequisiteTests(unittest.TestCase):
    """Exercise the workflow's real final shell, not a duplicate Python policy."""

    @classmethod
    def setUpClass(cls):
        import re
        import textwrap

        cls.workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text()
        cls.jobs = dict(re.findall(
            r"^  ([a-z][a-z-]+):\n(.*?)(?=^  [a-z][a-z-]+:\n|\Z)",
            cls.workflow, re.MULTILINE | re.DOTALL))
        final_step = cls.jobs["ui-test-gate"].split(
            "      - name: Require selected evidence and allow an honest no-UI skip\n", 1)[1]
        cls.shell = textwrap.dedent(final_step.split("        run: |\n", 1)[1])

    def run_gate(self, **overrides):
        import os
        import subprocess

        environment = dict(os.environ, SCOPE_RESULT="success", UI_REQUIRED="true",
                           BUILD_RESULT="success", CONTROLS_REQUIRED="true",
                           CONTROLS_RESULT="success", UI_RESULT="success",
                           UI_VERIFIED="true", UI_STATE="passed")
        environment.update(overrides)
        return subprocess.run(["bash", "-euo", "pipefail", "-c", self.shell],
                              env=environment, text=True, capture_output=True, timeout=5)

    def test_native_and_product_builds_are_independent_single_owners(self):
        native = self.jobs["interruption-controls"]
        build = self.jobs["build-ui-products"]
        for job in (native, build):
            self.assertIn("    needs: scope\n", job)
            self.assertIn("runs-on: macos-26", job)
        self.assertIn("if: needs.scope.outputs.interruption_controls == 'true'", native)
        self.assertEqual(native.count("run: make test-ui-interruption-safety "), 1)
        self.assertNotIn("test-ui-build", native)
        self.assertNotIn("test-ui-interruption-safety", build)
        self.assertEqual(build.count("run: make test-ui-build"), 1)
        self.assertIn("if: always()", native)
        self.assertIn("name: ui-interruption-safety-${{ github.run_id }}", native)

    def test_interruption_evidence_is_archived_by_its_owning_job(self):
        native = self.jobs["interruption-controls"]
        self.assertNotIn("archive-ui-interruption-evidence", self.jobs["build-ui-products"])
        self.assertEqual(native.count("scripts/archive-ui-interruption-evidence.sh"), 1)
        self.assertIn("steps.interruption_controls.outcome != 'skipped'", native)
        upload = native.split("      - name: Upload interruption-control evidence\n", 1)[1]
        self.assertIn("path: ${{ runner.temp }}/ui-interruption-safety.tar.gz", upload)
        self.assertNotIn("path: ${{ runner.temp }}/ui-interruption-safety\n", upload)
        self.assertIn("if-no-files-found: error", upload)
        self.assertIn("steps.interruption_archive.outcome == 'success'", upload)
        self.assertNotIn("continue-on-error: true", upload)

    def test_locales_join_both_prerequisites_even_when_native_is_skipped(self):
        lane = self.jobs["scoped-ui-tests"]
        self.assertIn("needs: [scope, build-ui-products, interruption-controls]", lane)
        self.assertIn("always() && !cancelled()", lane)
        self.assertIn("needs.build-ui-products.result == 'success'", lane)
        self.assertIn("needs.interruption-controls.result == 'success'", lane)
        self.assertIn("needs.interruption-controls.result == 'skipped'", lane)
        gate = self.jobs["ui-test-gate"]
        self.assertIn("needs: [scope, build-ui-products, interruption-controls, scoped-ui-tests]", gate)
        self.assertIn("CONTROLS_REQUIRED: ${{ needs.scope.outputs.interruption_controls }}", gate)
        self.assertIn("CONTROLS_RESULT: ${{ needs.interruption-controls.result }}", gate)
        self.assertIn("needs.ui-test-gate.result == 'success'", self.jobs["verification-anchor"])

    def test_actual_gate_rejects_every_invalid_native_outcome_even_with_green_ui(self):
        states = ("success", "failure", "cancelled", "skipped", "", "neutral")
        for required in ("true", "false", "", "TRUE"):
            for result in states:
                with self.subTest(required=required, result=result):
                    accepted = (required, result) in (("true", "success"), ("false", "skipped"))
                    run = self.run_gate(CONTROLS_REQUIRED=required, CONTROLS_RESULT=result)
                    self.assertEqual(run.returncode == 0, accepted, run.stdout + run.stderr)
                    if not accepted:
                        self.assertIn("Native interruption controls contradict selection", run.stderr)

    def test_no_ui_change_requires_no_native_work(self):
        run = self.run_gate(UI_REQUIRED="false", CONTROLS_REQUIRED="false",
                            CONTROLS_RESULT="skipped", BUILD_RESULT="skipped",
                            UI_RESULT="skipped", UI_VERIFIED="", UI_STATE="")
        self.assertEqual(run.returncode, 0, run.stderr)

    def test_no_ui_selection_rejects_unexpected_native_work(self):
        run = self.run_gate(UI_REQUIRED="false")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("cannot require native controls", run.stderr)

    def test_other_failures_cannot_hide_behind_successful_native_controls(self):
        for key in ("SCOPE_RESULT", "BUILD_RESULT", "UI_RESULT"):
            for result in ("failure", "cancelled", "skipped", ""):
                with self.subTest(key=key, result=result):
                    run = self.run_gate(**{key: result})
                    self.assertNotEqual(run.returncode, 0, run.stdout)
        run = self.run_gate(UI_STATE="passed", UI_VERIFIED="false")
        self.assertNotEqual(run.returncode, 0, run.stdout)


class UIArtifactTransportTests(unittest.TestCase):
    def receipt_paths(self, locale):
        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text()
        marker = "      - name: Publish compact classifier receipts\n"
        self.assertIn(marker, workflow, "the classifier must not download result bundles")
        step = workflow.split(marker, 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("if: always()", step)
        self.assertIn("name: scoped-ui-receipts-${{ matrix.locale }}-${{ github.run_id }}", step)
        self.assertIn("if-no-files-found: error", step)
        paths = step.split("          path: |\n", 1)[1].split(
            "          if-no-files-found:", 1)[0]
        paths = [line.strip().replace("${{ matrix.locale }}", locale)
                 for line in paths.splitlines() if line.strip()]
        self.assertEqual(set(paths), {
            f"dist/ui-test-results/{locale}-runtime.json",
            f"dist/ui-test-results/{locale}-execution.json",
            f"dist/ui-test-results/{locale}-outcome.txt",
        })
        self.assertEqual(len(paths), 3)
        return paths

    def test_classifier_fetches_only_receipts_without_removing_raw_evidence(self):
        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text()
        gate = workflow.split("  ui-test-gate:\n", 1)[1].split(
            "\n  verification-anchor:\n", 1)[0]
        self.assertIn("pattern: scoped-ui-receipts-*-${{ github.run_id }}", gate)
        self.assertNotIn("pattern: scoped-ui-*-${{ github.run_id }}", gate)
        self.assertIn("merge-multiple: true", gate)
        raw = workflow.split("      - name: Preserve ${{ matrix.locale }} UI evidence\n", 1)[1]
        self.assertIn("name: scoped-ui-${{ matrix.locale }}-${{ github.run_id }}", raw)
        self.assertIn("path: dist/ui-test-results", raw)
        self.assertIn("retention-days: 7", raw)
        for locale in ("en", "es"):
            self.receipt_paths(locale)

    def classify_transported_files(self, *, remove=None, replace=None):
        import os
        import shutil
        import subprocess
        import tempfile
        import textwrap
        from Tests.Tooling.test_ui_test_ci_gate import execution, receipt

        workflow = (ROOT / ".github/workflows/ui-tests.yml").read_text()
        step = workflow.split(
            "      - name: Classify functional evidence and hosted runtime drift\n", 1)[1]
        shell = textwrap.dedent(step.split("        run: |\n", 1)[1].split(
            "\n      - name:", 1)[0])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            producer = root / "producer"
            results = producer / "dist/ui-test-results"
            results.mkdir(parents=True)
            for locale in ("en", "es"):
                (results / f"{locale}-runtime.json").write_text(json.dumps(receipt(locale)))
                (results / f"{locale}-execution.json").write_text(json.dumps(execution(locale)))
                (results / f"{locale}-outcome.txt").write_text("success\n")
            (results / "en.xcresult").mkdir()
            (results / "en.xcresult/large-result").write_bytes(b"unneeded by the classifier")
            (results / "en.log").write_text("retained diagnostic log")
            if remove:
                (results / remove).unlink()
            if replace:
                name, contents = replace
                (results / name).write_text(contents)

            consumer = root / "consumer"
            destination = consumer / "dist/ui-test-results"
            destination.mkdir(parents=True)
            for locale in ("en", "es"):
                for relative in self.receipt_paths(locale):
                    source = producer / relative
                    if source.exists():
                        shutil.copyfile(source, destination / source.name)
            self.assertFalse((destination / "en.xcresult").exists())
            self.assertFalse((destination / "en.log").exists())
            self.assertTrue((results / "en.xcresult/large-result").is_file())
            (consumer / "scripts").mkdir()
            shutil.copyfile(ROOT / "scripts/ui_test_ci_gate.py",
                            consumer / "scripts/ui_test_ci_gate.py")
            output = root / "github-output"
            environment = dict(os.environ, UI_TEST_LOCALES="en es", GITHUB_OUTPUT=str(output))
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", shell],
                                    cwd=consumer, env=environment, capture_output=True,
                                    text=True, timeout=5)
            return result, output.read_text() if output.exists() else ""

    def test_actual_classifier_accepts_both_transported_locales_without_result_bundles(self):
        run, outputs = self.classify_transported_files()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("verified=true", outputs)

    def test_transport_cannot_hide_missing_or_corrupt_required_evidence(self):
        for locale in ("en", "es"):
            for suffix in ("runtime.json", "execution.json", "outcome.txt"):
                name = f"{locale}-{suffix}"
                with self.subTest(missing=name):
                    run, outputs = self.classify_transported_files(remove=name)
                    self.assertNotEqual(run.returncode, 0, run.stdout)
                    self.assertNotIn("verified=true", outputs)
                with self.subTest(corrupt=name):
                    run, outputs = self.classify_transported_files(replace=(name, "corrupt"))
                    self.assertNotEqual(run.returncode, 0, run.stdout)
                    self.assertNotIn("verified=true", outputs)


if __name__ == "__main__":
    unittest.main()
