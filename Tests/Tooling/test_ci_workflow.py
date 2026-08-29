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

    def test_repository_contracts_have_one_linux_owner_before_macos(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        ui = (ROOT / ".github/workflows/ui-tests.yml").read_text(encoding="utf-8")

        self.assertEqual(ci.count("run: scripts/check-repository-hygiene.sh"), 1)
        self.assertEqual(ci.count("needs: repository-hygiene"), 3)
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


if __name__ == "__main__":
    unittest.main()
