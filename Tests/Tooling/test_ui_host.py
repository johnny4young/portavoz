"""The host a pull request's UI lane wraps from SwiftPM, compared with its project owner."""

import copy
import plistlib
import re
import shutil
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


def specs():
    target = {"sources": [{"path": "Tests"}], "type": "bundle", "platform": "macOS",
              "deploymentTarget": "26.0", "settings": {"base": {"A": "1"}}}
    receiver = {**target, "type": "application"}
    runner = {"settings": {"base": {"SWIFT_VERSION": "6.0"}},
              "targets": {"PortavozUITests": copy.deepcopy(target), "PortavozDictationReceiver": copy.deepcopy(receiver)}}
    project = {**copy.deepcopy(runner), "packages": {"Portavoz": {"path": "."}}}
    project["targets"]["Portavoz"] = {
        "deploymentTarget": "26.0", "settings": {"base": {ui_host.HOST_IDENTIFIER_KEY: IDENTIFIER}},
        "info": {"properties": {"CFBundleDevelopmentRegion": "en"}}}
    project["settings"]["base"].update(MARKETING_VERSION="0.1.0", CURRENT_PROJECT_VERSION="1")
    runner["settings"]["base"].update(MARKETING_VERSION="0.1.0", CURRENT_PROJECT_VERSION="1")
    return project, runner


class RunnerContractTests(unittest.TestCase):
    def test_a_matching_runner_has_no_problem(self):
        self.assertEqual(ui_host.contract_problems(*specs()), [])

    def test_runner_drift_from_the_full_project_is_named(self):
        for key, value in (("sources", [{"path": "Other"}]), ("deploymentTarget", "27.0"),
                           ("settings", {"base": {"A": "2"}}), ("type", "tool"), ("platform", "iOS")):
            with self.subTest(key=key):
                project, runner = specs()
                project["targets"]["PortavozUITests"][key] = value

                self.assertEqual(ui_host.contract_problems(project, runner), [f"PortavozUITests differs in {key}"])

    def test_shared_settings_drift_is_named(self):
        project, runner = specs()
        project["settings"]["base"]["SWIFT_VERSION"] = "6.2"

        self.assertEqual(ui_host.contract_problems(project, runner), ["the shared settings differ"])

    def test_a_runner_with_the_app_or_a_package_is_refused(self):
        project, runner = specs()
        runner["targets"]["Portavoz"] = {}
        runner["packages"] = {"Portavoz": {"path": "."}}

        problems = ui_host.contract_problems(project, runner)

        self.assertIn("the runner must have no app target", problems[0])
        self.assertIn("the runner must link no package", problems)

    def test_a_host_key_that_acts_like_the_shipping_app_is_refused(self):
        for key in ui_host.FORBIDDEN_HOST_KEYS:
            with self.subTest(key=key):
                project, runner = specs()
                project["targets"]["Portavoz"]["info"]["properties"][key] = "x"

                self.assertEqual(ui_host.contract_problems(project, runner), [f"the host must not declare {key}"])


class WiringTests(unittest.TestCase):
    def test_the_contract_runs_before_anything_compiles(self):
        builder = (ROOT / "scripts/build-ui-host-products.sh").read_text(encoding="utf-8")

        self.assertLess(builder.index("scripts/ui_host.py verify"), builder.index("swift build"))

    def test_hygiene_owns_this_module_and_both_scripts(self):
        hygiene = (ROOT / "scripts/check-repository-hygiene.sh").read_text(encoding="utf-8")

        for line in ("python3 -m unittest Tests.Tooling.test_ui_host", "bash -n scripts/make-ui-host.sh",
                     "bash -n scripts/build-ui-host-products.sh"):
            self.assertIn(line, hygiene)

    def test_the_full_project_app_links_what_the_swiftpm_app_links(self):
        package = (ROOT / "Package.swift").read_text(encoding="utf-8")
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        app = re.search(r'name: "portavoz-app",\s*dependencies: \[(.*?)\n\s*\]', package, re.DOTALL).group(1)
        linked = set(re.findall(r'^\s*"(\w+)"|[\s,]"(\w+)"(?=,|\s*$)', app, re.MULTILINE))
        swiftpm = {name for pair in linked for name in pair if name} - {"Sparkle"}
        section = project.split("    dependencies:\n      - package: Portavoz\n        products:\n", 1)[1]
        section = section.split("      - package: Sparkle", 1)[0]

        self.assertEqual(set(re.findall(r"- (\w+)", section)), swiftpm)
        self.assertIn('.product(name: "Sparkle", package: "Sparkle")', app)


@unittest.skipUnless(shutil.which("xcodegen"), "XcodeGen is required to parse the UI projects")
class HostAndRunnerSpecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = ui_host.project_spec()
        cls.runner = ui_host.runner_spec()
        cls.plist = ui_host.info_plist(cls.project)
        script = (ROOT / "scripts/make-app.sh").read_text(encoding="utf-8")
        cls.shipping = plistlib.loads(
            script.split('cat > "$APP/Contents/Info.plist" << \'PLIST\'\n', 1)[1].split("\nPLIST", 1)[0].encode())

    def test_the_tracked_specs_satisfy_the_contract(self):
        self.assertEqual(ui_host.contract_problems(self.project, self.runner), [])

    def test_the_host_plist_is_project_yml_and_a_complete_bundle(self):
        properties = self.project["targets"]["Portavoz"]["info"]["properties"]

        self.assertEqual({key: self.plist[key] for key in properties}, properties)
        self.assertEqual(self.plist["CFBundleIdentifier"], IDENTIFIER)
        self.assertEqual(self.plist["CFBundleExecutable"], "Portavoz")
        self.assertEqual(self.plist["LSMinimumSystemVersion"], "26.0")

    def test_the_host_shares_the_shipping_file_type_but_not_its_identity(self):
        self.assertNotEqual(self.plist["CFBundleIdentifier"], self.shipping["CFBundleIdentifier"])
        self.assertEqual(self.plist["UTExportedTypeDeclarations"], self.shipping["UTExportedTypeDeclarations"])
        script = (ROOT / "scripts/make-ui-host.sh").read_text(encoding="utf-8")
        for inherited in ("portavoz-cli", "--options runtime", "make-app.sh", "swift build --product"):
            self.assertNotIn(inherited, script)
        self.assertIn("packaging/portavoz-local.entitlements", script)


if __name__ == "__main__":
    unittest.main()
