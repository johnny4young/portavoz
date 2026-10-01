"""Execute the real install recipe with inert external-command boundaries."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
DEV_APP = "/Applications/Portavoz Dev.app"


class DevInstallTests(unittest.TestCase):
    def run_install(self, *, failure="", profile=""):
        with tempfile.TemporaryDirectory(prefix="portavoz dev ñ-") as temporary:
            root = Path(temporary)
            shutil.copyfile(ROOT / "Makefile", root / "Makefile")
            commands = root / "commands"
            commands.mkdir()
            log = root / "commands.jsonl"
            stub = commands / "stub"
            stub.write_text(
                f"#!{sys.executable}\n"
                "import json, os, pathlib, sys\n"
                "name = pathlib.Path(sys.argv[0]).name\n"
                "with open(os.environ['INSTALL_TEST_LOG'], 'a') as out:\n"
                "    out.write(json.dumps([name, *sys.argv[1:]]) + '\\n')\n"
                "if name == 'open': raise SystemExit(91)\n"
                "if name == 'codesign' and '--verify' in sys.argv:\n"
                "    target = sys.argv[-1]\n"
                "    if target == os.environ.get('INSTALL_TEST_FAILURE'): raise SystemExit(92)\n"
            )
            stub.chmod(0o700)
            for command in ["osascript", "sleep", "plutil", "codesign", "rm", "cp", "open", "lsregister"]:
                (commands / command).symlink_to(stub)
            # Real sed edits the fixture; GNU sed on Linux runners needs `-i` without BSD's ''.
            shim = commands / "sed"
            shim.write_text(
                f"#!{sys.executable}\n"
                "import os, sys\n"
                "if os.environ.get('INSTALL_TEST_FAILURE') == 'sed': raise SystemExit(93)\n"
                "args = sys.argv[1:]\n"
                f"if {sys.platform != 'darwin'} and args[:2] == ['-i', '']: args = ['-i', *args[2:]]\n"
                f"os.execv({shutil.which('sed')!r}, ['sed', *args])\n"
            )
            shim.chmod(0o700)
            scripts = root / "scripts"
            scripts.mkdir()
            builder = scripts / "make-app.sh"
            builder.write_text(
                f"#!{sys.executable}\n"
                "from pathlib import Path\n"
                "import json, os, sys\n"
                "with open(os.environ['INSTALL_TEST_LOG'], 'a') as out:\n"
                "    out.write(json.dumps(['make-app.sh', *sys.argv[1:]]) + '\\n')\n"
                "resources = Path('dist/Portavoz.app/Contents/Resources/en.lproj')\n"
                "resources.mkdir(parents=True)\n"
                "(resources / 'InfoPlist.strings').write_text('\\\"CFBundleName\\\" = \\\"Portavoz\\\";\\n')\n"
                "Path('dist/.portavoz-sign-entitlements').write_text('entitlements.plist')\n"
            )
            builder.chmod(0o700)
            environment = {
                **os.environ,
                "PATH": str(commands) + os.pathsep + os.environ["PATH"],
                "INSTALL_TEST_LOG": str(log),
                "INSTALL_TEST_FAILURE": failure,
                "PORTAVOZ_PROVISIONING_PROFILE": profile,
            }
            # Prevent inherited make flags from injecting recipes or silently
            # switching this executed call-site test into a dry run.
            for key in ["MAKEFLAGS", "MFLAGS", "GNUMAKEFLAGS", "MAKEFILES"]:
                environment.pop(key, None)
            result = subprocess.run(
                ["/usr/bin/make", "install", f"PORTAVOZ_LSREGISTER={commands / 'lsregister'}"],
                cwd=root, env=environment, capture_output=True, text=True, timeout=30,
            )
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            strings = root / "dist/Portavoz.app/Contents/Resources/en.lproj/InfoPlist.strings"
            self.localized_names = strings.read_text() if strings.exists() else None
            return result, calls

    def test_install_registers_verified_dev_bundle_without_launching_any_app(self):
        result, calls = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("open", [call[0] for call in calls])
        self.assertIn("automatic launch intentionally disabled", result.stdout)
        self.assertIn("--args -use-temp-store", result.stdout)
        stages = [call for call in calls if call[0] in {"codesign", "rm", "cp", "lsregister"}]
        self.assertEqual([call[0] for call in stages], ["codesign", "codesign", "rm", "cp", "codesign", "lsregister"])
        self.assertIn("--force", stages[0])
        self.assertEqual(stages[1][-1], "dist/Portavoz.app")
        self.assertEqual(stages[2], ["rm", "-rf", DEV_APP])
        self.assertEqual(stages[3], ["cp", "-R", "dist/Portavoz.app", DEV_APP])
        self.assertEqual(stages[4][-1], DEV_APP)
        self.assertEqual(stages[5], ["lsregister", "-f", DEV_APP])
        self.assertEqual(self.localized_names, '"CFBundleName" = "Portavoz Dev";\n')
        self.assertFalse(any("/Applications/Portavoz.app" in argument for call in calls for argument in call))

    def test_localized_name_failure_stops_before_signing_or_replacing_dev(self):
        result, calls = self.run_install(failure="sed")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call for call in calls if call[0] in {"codesign", "rm", "cp", "lsregister", "open"}], [])

    def test_verification_failures_cannot_copy_or_register_an_unverified_bundle(self):
        for failure in ["dist/Portavoz.app", DEV_APP]:
            with self.subTest(failure=failure):
                result, calls = self.run_install(failure=failure)
                self.assertNotEqual(result.returncode, 0)
                names = [call[0] for call in calls]
                self.assertNotIn("open", names)
                self.assertNotIn("lsregister", names)
                self.assertEqual("rm" in names, failure == DEV_APP)
                self.assertEqual("cp" in names, failure == DEV_APP)

    def test_production_profile_refusal_precedes_any_app_or_filesystem_effect(self):
        result, calls = self.run_install(profile="fixture-production.mobileprovision")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot mutate a production-profile app", result.stderr)
        self.assertEqual(calls, [])

    def test_environment_cannot_replace_the_registration_tool(self):
        environment = {key: value for key, value in os.environ.items()
                       if key not in {"MAKEFLAGS", "MFLAGS", "GNUMAKEFLAGS", "MAKEFILES"}}
        environment["PORTAVOZ_LSREGISTER"] = "/fixture/inherited-lsregister"
        result = subprocess.run(
            ["/usr/bin/make", "-n", "install"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("/fixture/inherited-lsregister", result.stdout)
        self.assertIn("LaunchServices.framework/Support/lsregister", result.stdout)


if __name__ == "__main__":
    unittest.main()
