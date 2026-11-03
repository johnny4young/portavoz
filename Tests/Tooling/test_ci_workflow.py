import itertools
import json
import re
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
            "lint",
            "repository-hygiene",
        ]
        self.assertEqual(contract["hostedCI"]["requiredJobs"], expected)
        for job in expected:
            self.assertEqual(workflow.count(f"  {job}:\n"), 1, job)

    def test_main_ci_can_be_dispatched_when_a_push_run_is_missing(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        triggers = workflow.split("\npermissions:", 1)[0]

        self.assertIn("  push:\n    branches: [main]\n", triggers)
        self.assertIn("  pull_request:\n", triggers)
        self.assertIn("  workflow_dispatch:\n", triggers)
        # A dispatched run follows the push seed policy.
        self.assertIn("if: github.event_name != 'pull_request' && github.ref == 'refs/heads/main'", workflow)

    def test_only_a_pull_request_replaces_its_older_run(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")

        self.assertIn(
            "concurrency:\n"
            "  group: ci-${{ github.event.pull_request.number || github.sha }}\n"
            "  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n",
            workflow,
        )

    def test_nightly_products_travel_compressed_once(self):
        workflow = (ROOT / ".github/workflows/ui-nightly.yml").read_text(encoding="utf-8")

        self.assertIn('zstd -T0 -3 --rm "$RUNNER_TEMP/ui-products.tar"', workflow)
        self.assertIn(
            "path: ${{ runner.temp }}/ui-products.tar.zst\n"
            "          compression-level: 0\n",
            workflow,
        )
        self.assertIn('zstd -d --rm "$RUNNER_TEMP/ui-archive/ui-products.tar.zst"', workflow)
        self.assertNotIn("ui-products.tar.gz", workflow)

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

    def test_no_sequoia_lane_remains(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertNotIn("sequoia-compatibility", workflow)
        self.assertNotIn("runs-on: macos-15", workflow)
        self.assertNotIn("install-ci-swift-toolchain.sh", workflow)
        self.assertFalse((ROOT / "scripts/install-ci-swift-toolchain.sh").exists())

    def test_ios_portability_is_isolated_without_fake_runtime_evidence(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        runner = (ROOT / "scripts/check-ios-portability.sh").read_text(
            encoding="utf-8"
        )

        self.assertEqual(workflow.count("  ios-portability:\n"), 1)
        self.assertIn("run: scripts/check-ios-portability.sh", workflow)
        self.assertIn("arm64-apple-ios26.0-simulator", runner)
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
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(
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

    def test_complete_ui_job_has_bounded_orchestration_headroom(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(
            encoding="utf-8"
        )
        scoped_job = workflow.split("  ui-tests:\n", 1)[1].split(
            "\n  gate:\n", 1
        )[0]

        self.assertEqual(scoped_job.count("    timeout-minutes: ${{ inputs.full_ui && 90 || 22 }}\n"), 1)

    def test_one_job_builds_the_host_and_runs_it_without_a_second_compiler(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(
            encoding="utf-8"
        )
        runner = (ROOT / "scripts/run-ui-tests.sh").read_text(encoding="utf-8")
        builder = (ROOT / "scripts/build-ui-host-products.sh").read_text(encoding="utf-8")
        scoped_job = workflow.split("  ui-tests:\n", 1)[1].split(
            "\n  gate:\n", 1
        )[0]
        gate_job = workflow.split("  gate:\n", 1)[1].split(
            "\n  ui-test-gate:\n", 1
        )[0]

        self.assertNotIn("build-ui-products", workflow)
        self.assertNotIn("run: make test-ui-build", workflow)
        self.assertNotIn("upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2\n        with:\n          name: ui-products", workflow)
        self.assertLess(scoped_job.index("Restore compatible Swift build state"),
                        scoped_job.index("run: make test-ui-host-products"))
        self.assertLess(scoped_job.index("run: make test-ui-host-products"), scoped_job.index("id: fit"))
        self.assertLess(scoped_job.index("id: fit"), scoped_job.index("run: make test-ui-run"))
        self.assertNotIn("actions/cache/save", scoped_job)
        self.assertIn("--spec project-ui-runner.yml", builder)
        self.assertIn("-testProductsPath", runner)
        self.assertIn('UI_TEST_PRODUCTS_PATH=$RUNNER_TEMP', scoped_job)
        # GitHub rejects the whole workflow for this context at job level.
        for job in (scoped_job, gate_job):
            self.assertNotIn("runner.temp", job.split("    steps:\n", 1)[0])
        self.assertNotIn("matrix", workflow)
        self.assertEqual(scoped_job.count("run: make test-ui-run"), 1)
        # One Linux classifier reads the lane's receipts and outcome.
        self.assertEqual(workflow.count("scripts/ui_test_ci_gate.py"), 1)
        self.assertIn("scripts/ui_test_ci_gate.py", gate_job)
        # Hosted evidence is English only; Spanish is never wired as a lane.
        self.assertIn('--english-outcome "$outcome"', gate_job)
        self.assertNotIn("spanish", workflow.lower())
        self.assertNotIn("outcome es", workflow)

    def test_repository_contracts_have_one_linux_owner_before_macos(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        ui = ci.split("\n  scope:\n", 1)[1]

        self.assertEqual(ci.count("run: scripts/check-repository-hygiene.sh"), 1)
        self.assertEqual(ci.count("needs: repository-hygiene\n"), 1)
        self.assertEqual(ci.count("    needs: scope\n"), 2)
        # scope is skipped on a main push, and the release contract requires this job there.
        self.assertIn("if: ${{ !cancelled() && needs.scope.result != 'failure' }}\n", ci)
        self.assertNotIn("python3 -m unittest Tests.Tooling", ui)
        self.assertEqual(
            ui.count("scripts/ui_test_scope.py --validate-catalog"),
            1,
        )

    def test_ios_portability_leaves_pull_requests_and_stays_on_main(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        lane = ci.split("  ios-portability:\n", 1)[1].split("\n  interruption:\n", 1)[0]

        self.assertIn("if: github.event_name != 'pull_request'\n", lane)
        self.assertNotIn("ios-scope", ci)
        self.assertFalse((ROOT / "scripts/ios_portability_scope.py").exists())

    def test_large_ui_evidence_is_kept_only_when_a_lane_did_not_pass(self):
        ui = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        nightly = (ROOT / ".github/workflows/ui-nightly.yml").read_text(encoding="utf-8")

        self.assertIn("if: always() && steps.lane.outputs.complete != 'true'\n",
                      ui.split("- name: Preserve UI evidence\n", 1)[1][:80])
        self.assertIn("id: lane\n", ui.split("- name: Record the lane receipt\n", 1)[1][:60])
        self.assertIn('--github-output "$GITHUB_OUTPUT"', ui)
        self.assertIn("steps.ui.outcome != 'success' || steps.classify.outputs.verified != 'true'", nightly)

    def test_small_receipts_and_pr_screenshots_are_kept_on_every_run(self):
        ui = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        for step in ("- name: Record the lane receipt\n", "- name: Record PR screenshots\n",
                     "- name: Publish PR screenshots\n", "- name: Publish compact classifier receipts\n"):
            self.assertIn("        if: always()\n", ui.split(step, 1)[1][:60], step)
        self.assertIn("dist/ui-test-results/en-lane.json", ui)
        self.assertIn("name: pr-screenshots-${{ github.run_id }}", ui)
        self.assertIn("path: dist/pr-screenshots\n          if-no-files-found: ignore", ui)

    def test_a_person_can_ask_for_the_complete_catalog_or_the_selection(self):
        ui = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        triggers = ui.split("\npermissions:", 1)[0]
        select = ui.split("- name: Select UI evidence\n", 1)[1].split("- name: Explain the selection", 1)[0]

        self.assertIn("    inputs:\n      full_ui:\n", triggers)
        self.assertIn("        type: boolean\n        default: false\n", triggers)
        self.assertIn('FULL_UI: ${{ inputs.full_ui }}', select)
        self.assertIn('"$EVENT_NAME" == "workflow_dispatch" && "$FULL_UI" == "true"', select)
        self.assertIn("scripts/ui_test_scope.py --all --format github", select)
        self.assertIn("--pull-request-base origin/main --head HEAD", select)

    def test_a_pull_request_shows_an_unknown_scope_and_what_it_defers(self):
        ui = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        explain = ui.split("- name: Explain the selection\n", 1)[1].split("\n  build-and-test:", 1)[0]

        self.assertIn('if [[ "$SCOPE_UNKNOWN" == "true" ]]; then', explain)
        self.assertIn("::warning title=UI scope unknown::Canaries and what fits of the harness self-test are selected.", explain)
        self.assertIn("-f full_ui=true", explain)
        fit = ui.split("- name: Fit the selection to what remains of the job\n", 1)[1].split("- name: Run ", 1)[0]
        self.assertIn('echo "Deferred to nightly: $deferred" | tee -a "$GITHUB_STEP_SUMMARY"', fit)

    def test_reruns_are_allowed_and_no_earlier_run_narrows_a_selection(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        contract = json.loads((ROOT / "docs/evidence/source-integration-qualification.json").read_text(encoding="utf-8"))

        self.assertNotIn("github.run_attempt == 1", workflow)
        self.assertNotIn("RUN_ATTEMPT", workflow)
        self.assertNotIn("verification-anchor", workflow)
        self.assertNotIn("github.event.before", workflow)
        self.assertNotIn("PREVIOUS_HEAD_SHA", workflow)
        # A release still takes only a first attempt of the main push.
        self.assertIs(contract["hostedCI"]["rejectReruns"], True)

    def test_one_workflow_owns_pull_requests_and_always_triggers(self):
        workflows = ROOT / ".github/workflows"
        workflow = (workflows / "ci.yml").read_text(encoding="utf-8")
        triggers = workflow.split("\npermissions:", 1)[0]

        self.assertFalse((workflows / "ui-tests.yml").exists())
        self.assertNotIn("paths", triggers)
        self.assertIn("  pull_request:\n", triggers)
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", workflow)

    def test_pull_request_jobs_stay_off_the_push_the_release_contract_reads(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")

        for job in ("scope", "gate"):
            body = workflow.split(f"\n  {job}:\n", 1)[1]
            self.assertIn("github.event_name != 'push'", body.split("    steps:\n", 1)[0], job)

    def test_only_a_pull_request_reports_the_required_check_names(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        gate = workflow.split("\n  gate:\n", 1)[1].split("    steps:\n", 1)[0]
        follower = workflow.split("\n  ui-test-gate:\n", 1)[1].split("    steps:\n", 1)[0]

        self.assertIn("name: ${{ github.event_name == 'pull_request' && 'gate' || 'gate-manual' }}", gate)
        self.assertIn("if: always() && github.event_name == 'pull_request'", follower)

    def test_a_rerun_of_failed_jobs_runs_a_failed_ui_lane_again(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        lane = workflow.split("\n  ui-tests:\n", 1)[1].split("\n  gate:\n", 1)[0]
        steps = re.findall(r"^      - name: (.*)$", lane, re.MULTILINE)
        last = lane.split("- name: Fail the lane when its tests did not pass\n", 1)[1]

        self.assertEqual(steps[-1], "Fail the lane when its tests did not pass")
        self.assertIn("if: always()\n", last)
        self.assertIn("OUTCOME: ${{ steps.ui.outcome }}", last)
        self.assertIn('run: test "$OUTCOME" = "success"', last)

    def test_no_required_job_can_be_green_by_continuing_on_error(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")

        self.assertNotRegex(workflow, r"(?m)^    continue-on-error:")
        self.assertEqual(workflow.count("continue-on-error: true"), 1)
        self.assertIn("id: ui\n        continue-on-error: true\n", workflow)

    def test_the_gate_needs_every_lane(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        jobs = re.findall(r"^  ([a-z][a-z-]+):\n", workflow.split("\njobs:\n", 1)[1], re.MULTILINE)
        gate = workflow.split("\n  gate:\n", 1)[1].split("\n  ui-test-gate:\n", 1)[0]
        needed = re.search(r"needs: \[(.*)\]", gate).group(1).split(", ")

        self.assertEqual(set(needed), set(jobs) - {"gate", "ui-test-gate"})
        self.assertIn("if: always() && github.event_name != 'push'", gate)


class UIPrerequisiteTests(unittest.TestCase):
    """Exercise the workflow's real final shell, not a duplicate Python policy."""

    @classmethod
    def setUpClass(cls):
        import re
        import textwrap

        cls.workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        cls.jobs = dict(re.findall(
            r"^  ([a-z][a-z-]+):\n(.*?)(?=^  [a-z][a-z-]+:\n|\Z)",
            cls.workflow, re.MULTILINE | re.DOTALL))
        final_step = cls.jobs["gate"].split(
            "      - name: Require every lane the selection asked for\n", 1)[1]
        cls.shell = textwrap.dedent(final_step.split("        run: |\n", 1)[1])

    def run_gate(self, **overrides):
        import os
        import subprocess

        environment = dict(os.environ, EVENT_NAME="pull_request", HYGIENE_RESULT="success", LINT_RESULT="success",
                           BUILD_RESULT="success", IOS_RESULT="skipped", SCOPE_SUMMARY="reason",
                           SCOPE_RESULT="success", UI_REQUIRED="true",
                           CONTROLS_REQUIRED="true",
                           CONTROLS_RESULT="success", UI_RESULT="success",
                           UI_VERIFIED="true", UI_STATE="passed")
        environment.update(overrides)
        return subprocess.run(["bash", "-euo", "pipefail", "-c", self.shell],
                              env=environment, text=True, capture_output=True, timeout=5)

    def test_native_and_product_builds_are_independent_single_owners(self):
        native = self.jobs["interruption"]
        build = self.jobs["ui-tests"]
        self.assertIn("    needs: scope\n", native)
        self.assertIn("runs-on: macos-26", native)
        self.assertIn("runs-on: macos-26", build)
        self.assertIn("if: needs.scope.outputs.interruption_controls == 'true'", native)
        self.assertEqual(native.count("run: make test-ui-interruption-safety "), 1)
        self.assertNotIn("test-ui-build", native)
        self.assertNotIn("test-ui-interruption-safety", build)
        self.assertEqual(build.count("run: make test-ui-host-products"), 1)
        self.assertIn("if: always()", native)
        self.assertIn("name: ui-interruption-safety-${{ github.run_id }}-${{ github.run_attempt }}", native)

    def test_interruption_evidence_is_archived_by_its_owning_job(self):
        native = self.jobs["interruption"]
        self.assertNotIn("archive-ui-interruption-evidence", self.jobs["ui-tests"])
        self.assertEqual(native.count("scripts/archive-ui-interruption-evidence.sh"), 1)
        self.assertIn("steps.interruption_controls.outcome != 'skipped'", native)
        upload = native.split("      - name: Upload interruption-control evidence\n", 1)[1]
        self.assertIn("path: ${{ runner.temp }}/ui-interruption-safety.tar.gz", upload)
        self.assertNotIn("path: ${{ runner.temp }}/ui-interruption-safety\n", upload)
        self.assertIn("if-no-files-found: error", upload)
        self.assertIn("steps.interruption_archive.outcome == 'success'", upload)
        self.assertNotIn("continue-on-error: true", upload)

    def test_locales_join_both_prerequisites_even_when_native_is_skipped(self):
        lane = self.jobs["ui-tests"]
        self.assertIn("needs: [scope, interruption]", lane)
        self.assertIn("always() && !cancelled()", lane)
        self.assertIn("needs.interruption.result == 'success'", lane)
        self.assertIn("needs.interruption.result == 'skipped'", lane)
        gate = self.jobs["gate"]
        self.assertIn("CONTROLS_REQUIRED: ${{ needs.scope.outputs.interruption_controls }}", gate)
        self.assertIn("CONTROLS_RESULT: ${{ needs.interruption.result }}", gate)
        self.assertIn("test \"$GATE_RESULT\" = \"success\"", self.jobs["ui-test-gate"])
        self.assertIn("    needs: gate\n", self.jobs["ui-test-gate"])

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
                            CONTROLS_RESULT="skipped",
                            UI_RESULT="skipped", UI_VERIFIED="", UI_STATE="")
        self.assertEqual(run.returncode, 0, run.stderr)

    def test_no_ui_selection_rejects_unexpected_native_work(self):
        run = self.run_gate(UI_REQUIRED="false")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("cannot require native controls", run.stderr)

    def test_other_failures_cannot_hide_behind_successful_native_controls(self):
        for key in ("HYGIENE_RESULT", "LINT_RESULT", "SCOPE_RESULT", "BUILD_RESULT", "UI_RESULT"):
            for result in ("failure", "cancelled", "skipped", ""):
                with self.subTest(key=key, result=result):
                    run = self.run_gate(**{key: result})
                    self.assertNotEqual(run.returncode, 0, run.stdout)
        run = self.run_gate(UI_STATE="passed", UI_VERIFIED="false")
        self.assertNotEqual(run.returncode, 0, run.stdout)

    def test_every_combination_of_a_required_lane_and_a_result_is_decided(self):
        states = ("success", "failure", "cancelled", "skipped", "")
        for hygiene, lint, scope, build in itertools.product(states, repeat=4):
            with self.subTest(hygiene=hygiene, lint=lint, scope=scope, build=build):
                run = self.run_gate(HYGIENE_RESULT=hygiene, LINT_RESULT=lint, SCOPE_RESULT=scope, BUILD_RESULT=build)
                self.assertEqual(run.returncode == 0, {hygiene, lint, scope, build} == {"success"}, run.stderr)

    def test_a_hosted_failure_stays_red_and_a_rerun_clears_it(self):
        run = self.run_gate(UI_RESULT="failure", UI_STATE="infrastructure-advisory", UI_VERIFIED="false")

        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertIn("infrastructure-advisory", run.stderr)
        self.assertIn("Rerun the failed jobs", run.stderr)

    def test_a_selection_that_said_nothing_is_not_a_skip(self):
        for required in ("", "TRUE", "maybe"):
            with self.subTest(required=required):
                run = self.run_gate(UI_REQUIRED=required, CONTROLS_REQUIRED="false", CONTROLS_RESULT="skipped",
                                    UI_RESULT="skipped")
                self.assertNotEqual(run.returncode, 0, run.stdout)
                self.assertIn("did not say whether UI is required", run.stderr)

    def test_a_skipped_ui_lane_needs_the_reason_scope_gave(self):
        for overrides in ({"SCOPE_SUMMARY": ""}, {"UI_RESULT": "success"}, {"UI_RESULT": "cancelled"}):
            with self.subTest(**overrides):
                values = dict(UI_REQUIRED="false", CONTROLS_REQUIRED="false", CONTROLS_RESULT="skipped",
                              UI_RESULT="skipped", UI_VERIFIED="", UI_STATE="")
                run = self.run_gate(**{**values, **overrides})
                self.assertNotEqual(run.returncode, 0, run.stdout)
                self.assertIn("needs its reason and a skipped lane", run.stderr)

    def test_ios_portability_follows_the_event(self):
        for event, result, accepted in (("pull_request", "skipped", True), ("pull_request", "success", False),
                                        ("workflow_dispatch", "success", True), ("workflow_dispatch", "skipped", False),
                                        ("workflow_dispatch", "failure", False), ("pull_request", "cancelled", False)):
            with self.subTest(event=event, result=result):
                run = self.run_gate(EVENT_NAME=event, IOS_RESULT=result)
                self.assertEqual(run.returncode == 0, accepted, run.stderr)

    def test_a_failed_receipt_download_still_reaches_the_classifier_and_the_final_step(self):
        gate = self.jobs["gate"]
        self.assertIn("if: always() && needs.scope.outputs.required == 'true'",
                      gate.split("- name: Classify functional evidence", 1)[1][:200])
        self.assertIn("if: always()\n", gate.split("- name: Require every lane", 1)[1][:60])
        self.assertIn("name: ui-receipts-${{ github.run_id }}-${{ needs.ui-tests.outputs.attempt }}", gate)


class UIArtifactTransportTests(unittest.TestCase):
    def receipt_paths(self, locale):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        marker = "      - name: Publish compact classifier receipts\n"
        self.assertIn(marker, workflow, "the classifier must not download result bundles")
        step = workflow.split(marker, 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("if: always()", step)
        self.assertIn("name: ui-receipts-${{ github.run_id }}-${{ github.run_attempt }}", step)
        self.assertIn("if-no-files-found: error", step)
        paths = step.split("          path: |\n", 1)[1].split(
            "          if-no-files-found:", 1)[0]
        paths = [line.strip().replace("/en-", f"/{locale}-")
                 for line in paths.splitlines() if line.strip()]
        self.assertEqual(set(paths), {
            f"dist/ui-test-results/{locale}-runtime.json",
            f"dist/ui-test-results/{locale}-execution.json",
            f"dist/ui-test-results/{locale}-outcome.txt",
            f"dist/ui-test-results/{locale}-lane.json",
        })
        self.assertEqual(len(paths), 4)
        return paths

    def test_classifier_fetches_only_receipts_without_removing_raw_evidence(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        gate = workflow.split("\n  gate:\n", 1)[1].split(
            "\n  ui-test-gate:\n", 1)[0]
        self.assertIn("name: ui-receipts-${{ github.run_id }}-${{ needs.ui-tests.outputs.attempt }}", gate)
        self.assertNotIn("ui-evidence-", gate)
        raw = workflow.split("      - name: Preserve UI evidence\n", 1)[1]
        self.assertIn("name: ui-evidence-${{ github.run_id }}-${{ github.run_attempt }}", raw)
        self.assertIn("path: dist/ui-test-results", raw)
        self.assertIn("retention-days: 7", raw)
        self.receipt_paths("en")

    def classify_transported_files(
        self, *, remove=None, replace=None, lanes=("en",),
    ):
        import os
        import shutil
        import subprocess
        import tempfile
        import textwrap
        from Tests.Tooling.test_ui_test_ci_gate import execution, receipt

        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        step = workflow.split(
            "      - name: Classify functional evidence and hosted runtime drift\n", 1)[1]
        shell = textwrap.dedent(step.split("        run: |\n", 1)[1].split(
            "\n      - name:", 1)[0])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            producer = root / "producer"
            results = producer / "dist/ui-test-results"
            results.mkdir(parents=True)
            for locale in lanes:
                (results / f"{locale}-runtime.json").write_text(json.dumps(receipt(locale)))
                (results / f"{locale}-execution.json").write_text(json.dumps(execution(locale)))
                (results / f"{locale}-outcome.txt").write_text("success\n")
                (results / f"{locale}-lane.json").write_text(json.dumps(
                    {"sha": "a" * 40, "attempt": 1, "executed": [{"identifier": "x"}], "notExecuted": []}))
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
            for locale in lanes:
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
            environment = dict(os.environ, HEAD_SHA="a" * 40, ATTEMPT="1", GITHUB_OUTPUT=str(output))
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", shell],
                                    cwd=consumer, env=environment, capture_output=True,
                                    text=True, timeout=5)
            return result, output.read_text() if output.exists() else ""

    def test_actual_classifier_accepts_the_english_lane_without_result_bundles(self):
        run, outputs = self.classify_transported_files()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("verified=true", outputs)

    def test_a_lane_receipt_of_another_head_or_with_gaps_never_qualifies(self):
        good = {"sha": "a" * 40, "attempt": 1, "executed": [{"identifier": "x"}], "notExecuted": []}
        for change, message in (({"sha": "b" * 40}, "another head"), ({"attempt": 2}, "another attempt"),
                                ({"executed": []}, "zero tests"), ({"notExecuted": ["y"]}, "did not run")):
            with self.subTest(change=change):
                run, outputs = self.classify_transported_files(replace=("en-lane.json", json.dumps({**good, **change})))
                self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
                self.assertIn(message, run.stderr)
                self.assertIn("verified=false", outputs)

        run, outputs = self.classify_transported_files(remove="en-lane.json")
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn("lane receipt is unreadable", run.stderr)

    def test_transported_spanish_lane_never_qualifies(self):
        run, outputs = self.classify_transported_files(lanes=("en", "es"))
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertIn("es: unsupported locale lane", run.stderr)
        self.assertIn("verified=false", outputs)
        self.assertIn("--locales en \\\n", (ROOT / ".github/workflows/ci.yml").read_text())

    def test_transport_cannot_hide_missing_or_corrupt_required_evidence(self):
        for locale in ("en",):
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



class NightlyUIWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = (ROOT / ".github/workflows/ui-nightly.yml").read_text(encoding="utf-8")

    def test_nightly_runs_on_main_schedule_and_on_demand_only(self):
        triggers = self.workflow.split("\npermissions:", 1)[0]
        self.assertIn('    - cron: "23 3 * * *"\n', triggers)
        self.assertIn("  workflow_dispatch:\n", triggers)
        self.assertNotIn("pull_request", triggers)
        self.assertNotIn("  push:", triggers)
        self.assertIn("group: ui-nightly-${{ github.ref }}\n  cancel-in-progress: false", self.workflow)

    def test_every_scheduled_run_executes_the_catalog(self):
        self.assertNotIn("freshness", self.workflow)
        self.assertNotIn("actions: read", self.workflow)

    def test_three_shards_share_one_build_and_cover_the_validated_catalog(self):
        self.assertEqual(self.workflow.count("run: make test-ui-build"), 1)
        self.assertEqual(self.workflow.count("run: make test-ui-run"), 1)
        self.assertIn("python3 scripts/ui_test_scope.py --validate-catalog --all --format github", self.workflow)
        self.assertIn("shard: [1, 2, 3]", self.workflow)
        self.assertIn('--all --shard "${{ matrix.shard }}/3" --format github', self.workflow)
        self.assertIn("fail-fast: false", self.workflow)
        self.assertIn("UI_TEST_LOCALES: en", self.workflow)
        self.assertIn('UI_TEST_ENFORCE_RUNTIME_BUDGET: "false"', self.workflow)
        self.assertIn("run: make test-ui-interruption-safety", self.workflow)

    def test_each_shard_uses_the_pull_request_classifier(self):
        self.assertEqual(self.workflow.count("continue-on-error: true"), 1)
        self.assertIn("python3 scripts/ui_test_ci_gate.py --results dist/ui-test-results --locales en", self.workflow)
        self.assertIn('--english-outcome "$OUTCOME"', self.workflow)
        self.assertIn("OUTCOME: ${{ steps.ui.outcome }}", self.workflow)
        # Success must mean verified evidence; an advisory shard fails the run.
        self.assertIn('if [[ "$STATE" != "passed" || "$VERIFIED" != "true" ]]; then', self.workflow)
        self.assertIn("VERIFIED: ${{ steps.classify.outputs.verified }}", self.workflow)

    def test_a_night_never_holds_more_than_three_macos_slots(self):
        shard = self.workflow.split("  shard:\n", 1)[1].split("\n  alert:\n", 1)[0]

        self.assertIn("needs: [build-ui-products, interruption-controls, clean-build-and-test]\n", shard)
        self.assertIn("!cancelled() && needs.build-ui-products.result == 'success'", shard)
        self.assertEqual(self.workflow.split("\n  shard:\n", 1)[1].count("shard: [1, 2, 3]"), 1)

    def test_any_unverified_or_cancelled_job_reaches_the_alert(self):
        alert = self.workflow.split("\n  alert:\n", 1)[1]

        self.assertIn("needs: [build-ui-products, interruption-controls, clean-build-and-test, shard]\n", alert)
        self.assertIn("if: always()\n", alert)
        self.assertIn("issues: write\n", alert)
        self.assertIn("NEEDS: ${{ toJSON(needs) }}\n", alert)
        self.assertIn("runs-on: ubuntu-latest\n", alert)
        # Only the alert may write; the jobs running tests keep read-only tokens.
        self.assertEqual(self.workflow.count("issues: write"), 1)
        self.assertIn("permissions:\n  contents: read\n", self.workflow)

    def test_the_watch_runs_where_a_missing_schedule_cannot_silence_it(self):
        watch = (ROOT / ".github/workflows/ui-nightly-watch.yml").read_text(encoding="utf-8")
        triggers = watch.split("\npermissions:", 1)[0]

        self.assertIn("  push:\n    branches: [main]\n", triggers)
        self.assertIn("  schedule:\n", triggers)
        self.assertIn("  workflow_dispatch:\n", triggers)
        self.assertNotIn("pull_request", triggers)
        self.assertIn("  actions: read\n", watch)
        self.assertIn("  issues: write\n", watch)
        self.assertIn("scripts/ui_nightly_health.py freshness", watch)

    def test_pull_requests_select_within_the_budget_and_report_what_was_cut(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")

        self.assertEqual(workflow.count("python3 scripts/ui_test_scope.py --ranked"), 2)
        self.assertNotIn("ui_test_scope.py --budget", workflow)
        self.assertIn("python3 scripts/ui_test_scope.py --all --format github", workflow)
        self.assertIn("ranked: ${{ steps.select.outputs.ranked }}", workflow)
        self.assertIn("cut: ${{ steps.fit.outputs.cut }}", workflow)
        self.assertIn("UI_TESTS: ${{ steps.fit.outputs.tests }}", workflow)
        self.assertIn("UI_CUT: ${{ needs.ui-tests.outputs.cut }}", workflow)
        self.assertIn("DEFERRED: ${{ steps.fit.outputs.deferred }}", workflow)
        self.assertIn('Deferred to nightly: $deferred', workflow)
        self.assertNotIn("needs.scope.outputs.deferred", workflow)
        self.assertIn("::notice title=ui-budget-cut::", workflow)
        self.assertIn('--cut "$CUT"', workflow)
        self.assertIn("Not run, for nightly to own: $UI_CUT", workflow)

    def test_nightly_owns_a_clean_build_and_seeds_only_from_main(self):
        clean = self.workflow.split("  clean-build-and-test:\n", 1)[1].split("\n  # After the jobs above", 1)[0]

        self.assertNotIn("actions/cache/restore@", clean)
        self.assertIn("run: scripts/run-swift-tests.sh -Xswiftc -warnings-as-errors\n", clean)
        self.assertIn("PORTAVOZ_XCTEST_BATCH_SEED: ${{ github.run_id }}\n", clean)
        self.assertIn('PORTAVOZ_SWIFT_INCLUDE_NIGHTLY_ONLY: "1"\n', clean)
        self.assertLess(clean.index("run-swift-tests.sh"), clean.index("ci_swift_source_stamps.py snapshot"))
        self.assertEqual(clean.count("if: github.ref == 'refs/heads/main'"), 2)
        self.assertIn("if: steps.swift_cache_size.outputs.save == 'true'", clean)
        self.assertIn("key: ${{ steps.swift_cache_key.outputs.clean_key }}", clean)

    def test_every_macos_job_uses_the_fixed_toolchain(self):
        self.assertEqual(self.workflow.count("runs-on: macos-26"), 4)
        self.assertEqual(self.workflow.count("DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer"), 4)
        self.assertEqual(self.workflow.count("run: scripts/verify-ci-toolchain.sh 26 26.6"), 4)


if __name__ == "__main__":
    unittest.main()
