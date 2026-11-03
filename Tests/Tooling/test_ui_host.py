"""The host a pull request's UI lane wraps from SwiftPM, compared with its project owner."""

import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import ui_host  # noqa: E402

IDENTIFIER = "app.portavoz.mac.uitest-host"


def run_document(**overrides):
    return {ui_host.RUNNER_TARGET: {
        "UseUITargetAppProvidedByTests": True,
        "DependentProductPaths": ["__TESTROOT__/Debug/PortavozUITests-Runner.app"],
        "BundleIdentifiersForCrashReportEmphasis": ["app.portavoz.PortavozUITests"],
        **overrides,
    }}


class XctestrunInjectionTests(unittest.TestCase):
    def test_the_host_becomes_the_target_app_and_its_crashes_are_emphasized(self):
        target = ui_host.inject_host(run_document(), IDENTIFIER)[ui_host.RUNNER_TARGET]

        self.assertEqual(target["UITargetAppPath"], ui_host.HOST_IN_TEST_ROOT)
        self.assertNotIn("UseUITargetAppProvidedByTests", target)
        self.assertEqual(target["DependentProductPaths"][0], ui_host.HOST_IN_TEST_ROOT)
        self.assertIn(IDENTIFIER, target["BundleIdentifiersForCrashReportEmphasis"])

    def test_a_missing_host_refuses_to_inject(self):
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            (products / "Tests").mkdir()
            (products / "Tests/one.xctestrun").write_bytes(plistlib.dumps(run_document()))

            with self.assertRaisesRegex(SystemExit, "not where"):
                ui_host.inject_products(products, IDENTIFIER)

    def test_an_ambiguous_xctestrun_refuses_to_inject(self):
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            for name in ("one", "two"):
                (products / f"{name}.xctestrun").write_bytes(plistlib.dumps(run_document()))

            with self.assertRaisesRegex(SystemExit, "exactly one xctestrun.*found 2"):
                ui_host.inject_products(products, IDENTIFIER)

    def test_injection_rewrites_the_only_run_on_disk(self):
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            binary = products / ui_host.HOST_IN_PRODUCTS / "Contents/MacOS/Portavoz"
            binary.parent.mkdir(parents=True)
            binary.touch()
            run = products / "one.xctestrun"
            run.write_bytes(plistlib.dumps(run_document()))

            ui_host.inject_products(products, IDENTIFIER)

            self.assertEqual(plistlib.loads(run.read_bytes())[ui_host.RUNNER_TARGET]["UITargetAppPath"],
                             ui_host.HOST_IN_TEST_ROOT)


@unittest.skipUnless(shutil.which("xcodegen"), "XcodeGen is required to parse the UI projects")
class HostAndRunnerSpecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = ui_host.project_spec()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "runner.json"
            subprocess.run(
                ["xcodegen", "dump", "--spec", str(ROOT / "project-ui-runner.yml"),
                 "--type", "json", "--no-env", "--quiet", "--file", str(output)],
                check=True, capture_output=True, text=True, timeout=30)
            cls.runner = json.loads(output.read_text(encoding="utf-8"))
        cls.plist = ui_host.info_plist(cls.project)
        script = (ROOT / "scripts/make-app.sh").read_text(encoding="utf-8")
        cls.shipping = plistlib.loads(
            script.split('cat > "$APP/Contents/Info.plist" << \'PLIST\'\n', 1)[1].split("\nPLIST", 1)[0].encode())

    def test_the_host_plist_is_project_yml_and_a_complete_bundle(self):
        properties = self.project["targets"]["Portavoz"]["info"]["properties"]

        self.assertEqual({key: self.plist[key] for key in properties}, properties)
        self.assertEqual(self.plist["CFBundleIdentifier"], IDENTIFIER)
        self.assertEqual(self.plist["CFBundleExecutable"], "Portavoz")
        self.assertEqual(self.plist["LSMinimumSystemVersion"], "26.0")

    def test_the_host_inherits_nothing_that_would_act_like_the_shipping_app(self):
        for key in ("CFBundleDocumentTypes", "SUFeedURL", "SUEnableAutomaticChecks", "SUPublicEDKey"):
            self.assertNotIn(key, self.plist)
        self.assertNotEqual(self.plist["CFBundleIdentifier"], self.shipping["CFBundleIdentifier"])
        self.assertEqual(self.plist["UTExportedTypeDeclarations"], self.shipping["UTExportedTypeDeclarations"])
        script = (ROOT / "scripts/make-ui-host.sh").read_text(encoding="utf-8")
        for inherited in ("portavoz-cli", "--options runtime", "make-app.sh", "swift build --product"):
            self.assertNotIn(inherited, script)
        self.assertIn("packaging/portavoz-local.entitlements", script)

    def test_the_runner_has_no_app_and_no_package(self):
        self.assertEqual(set(self.runner["targets"]), {"PortavozUITests", "PortavozDictationReceiver"})
        self.assertNotIn("packages", self.runner)

    def test_the_runner_builds_what_the_full_project_builds(self):
        for name in ("PortavozUITests", "PortavozDictationReceiver"):
            for key in ("sources", "type", "platform", "deploymentTarget", "settings"):
                with self.subTest(target=name, key=key):
                    self.assertEqual(self.runner["targets"][name][key], self.project["targets"][name][key])


if __name__ == "__main__":
    unittest.main()
