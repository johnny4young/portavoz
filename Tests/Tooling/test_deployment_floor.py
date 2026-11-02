import re
import subprocess
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    return (REPOSITORY / relative).read_text(encoding="utf-8")


class DeploymentFloorTests(unittest.TestCase):
    """Every place that declares the floor must agree on macOS 26 and iOS 26."""

    def test_package_and_project_target_macos_26(self):
        self.assertIn(".macOS(.v26)", read("Package.swift"))
        self.assertIn(".iOS(.v26)", read("Package.swift"))
        project = read("project.yml")
        self.assertNotRegex(project, r'deploymentTarget: "(?!26\.0")')
        self.assertEqual(len(re.findall(r'deploymentTarget: "26\.0"', project)), 3)
        self.assertIn('macOS: "26.0"', project)

    def test_bundle_tools_and_distribution_share_the_floor(self):
        packager = read("scripts/make-app.sh")
        self.assertIn(
            "<key>LSMinimumSystemVersion</key>\n    <string>26.0</string>", packager
        )
        self.assertIn("--minimum-deployment-target 26.0", packager)
        self.assertIn(
            'DEPLOYMENT_TARGET="26.0"', read("scripts/build-appintents-metadata.sh")
        )
        self.assertIn(
            'MINIMUM_SYSTEM_VERSION = "26.0"', read("scripts/verify_release_appcast.py")
        )
        self.assertIn("depends_on macos: :tahoe", read("packaging/Casks/portavoz.rb"))

    def test_rendered_cask_has_no_template_header_or_placeholders(self):
        rendered = subprocess.run(
            [REPOSITORY / "scripts" / "render-cask.sh", "1.2.3", "0" * 64],
            check=True, capture_output=True, text=True,
        ).stdout
        self.assertTrue(rendered.startswith('cask "portavoz" do\n  version "1.2.3"'))
        self.assertNotIn("__", rendered)
        self.assertIn("depends_on macos: :tahoe", rendered)

    def test_cask_omits_the_deprecated_url_verified_option(self):
        # Homebrew deprecates `verified:`, and developer mode refuses to load it.
        self.assertNotIn("verified:", read("packaging/Casks/portavoz.rb"))


if __name__ == "__main__":
    unittest.main()
