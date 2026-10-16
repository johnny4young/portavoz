"""CI toolchain ownership and fail-closed ordering with inert command adapters."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
IDENTIFIER = "org.swift.633202606251a"
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ["CALLS"], "a") as f:
    f.write(json.dumps([name, *sys.argv[1:]]) + "\n")
if os.environ.get("FAIL_COMMAND") == name:
    sys.exit(2)
if name == "sw_vers":
    print(os.environ.get("FAKE_OS", "15.7"))
elif name == "xcodebuild":
    print("Xcode " + os.environ.get("FAKE_XCODE", "26.3") + "\nBuild version fixture")
elif name == "xcrun":
    if sys.argv[1:] == ["--find", "swift"]:
        if os.environ.get("FAKE_SWIFT_LOCATION") == "default":
            print(os.environ["DEVELOPER_DIR"] + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
        else:
            print(os.environ["TOOLCHAIN"] + "/usr/bin/swift")
    else:
        print("26.2")
elif name == "curl":
    pathlib.Path(sys.argv[sys.argv.index("--output") + 1]).write_bytes(b"inert package")
elif name == "shasum":
    sys.stdin.read()
elif name == "pkgutil":
    print("Status: signed by a developer certificate issued by Apple for distribution")
    print(os.environ.get("FAKE_SIGNER", "Developer ID Installer: Swift Open Source (V9AUD2URP3)"))
elif name == "installer":
    root = pathlib.Path(os.environ["TOOLCHAIN"])
    (root / "usr/bin").mkdir(parents=True, exist_ok=True)
    (root / "Info.plist").write_text("inert identity")
    shutil.copyfile(os.environ["FAKE_COMMAND"], root / "usr/bin/swift")
    (root / "usr/bin/swift").chmod(0o755)
elif name == "plutil":
    print(os.environ.get("FAKE_IDENTIFIER", "org.swift.633202606251a"))
elif name == "swift":
    print("Apple Swift version " + os.environ.get("FAKE_VERSION", "6.3.3") + " (fixture)")
else:
    sys.exit("Unexpected command: " + name)
'''


class CISwiftToolchainTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="ci swift ü ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake = self.bin / "fake-command"
        fake.write_text(FAKE)
        fake.chmod(0o755)
        for name in ("sw_vers", "xcodebuild", "xcrun", "curl", "shasum", "pkgutil", "installer", "plutil", "swift"):
            shutil.copyfile(fake, self.bin / name)
            (self.bin / name).chmod(0o755)
        self.home = self.root / "home"
        self.home.mkdir()
        self.toolchain = self.home / "Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain"
        self.developer = self.root / "Xcode.app/Contents/Developer"
        self.developer.mkdir(parents=True)
        self.calls = self.root / "calls.jsonl"
        self.github_env = self.root / "github-env"
        self.github_path = self.root / "github-path"
        self.env = dict(os.environ, HOME=str(self.home), RUNNER_TEMP=str(self.root),
                        GITHUB_ACTIONS="true", GITHUB_ENV=str(self.github_env),
                        GITHUB_PATH=str(self.github_path), CALLS=str(self.calls),
                        FAKE_COMMAND=str(fake), TOOLCHAIN=str(self.toolchain),
                        DEVELOPER_DIR=str(self.developer), TOOLCHAINS=IDENTIFIER,
                        PATH=f"{self.toolchain}/usr/bin{os.pathsep}{self.bin}{os.pathsep}{os.environ['PATH']}")
        for name in ("FAIL_COMMAND", "FAKE_OS", "FAKE_XCODE", "FAKE_SIGNER", "FAKE_IDENTIFIER", "FAKE_VERSION", "FAKE_SWIFT_LOCATION"):
            self.env.pop(name, None)

    def run_script(self, name, *args, **environment):
        return subprocess.run(["bash", str(ROOT / "scripts" / name), *args],
                              env=dict(self.env, **environment), capture_output=True,
                              text=True, timeout=10)

    def installer(self, *args, **environment):
        return self.run_script("install-ci-swift-toolchain.sh", *args, **environment)

    def command_names(self):
        if not self.calls.exists():
            return []
        return [json.loads(line)[0] for line in self.calls.read_text().splitlines()]

    def assert_not_exported(self):
        self.assertFalse(self.github_env.exists())
        self.assertFalse(self.github_path.exists())

    def seed_toolchain(self):
        (self.toolchain / "usr/bin").mkdir(parents=True)
        (self.toolchain / "Info.plist").write_text("inert identity")
        shutil.copyfile(self.bin / "swift", self.toolchain / "usr/bin/swift")
        (self.toolchain / "usr/bin/swift").chmod(0o755)

    def test_installer_refuses_non_ci_other_os_and_arguments_before_download(self):
        for args, environment in (((), {"GITHUB_ACTIONS": "false"}),
                                  ((), {"GITHUB_ENV": ""}), ((), {"FAKE_OS": "26.6"}),
                                  (("unexpected",), {})):
            with self.subTest(environment=environment, args=args):
                result = self.installer(*args, **environment)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertNotIn("curl", self.command_names())
                self.assert_not_exported()

    def test_checksum_and_signature_fail_before_install_or_exports(self):
        for failure in ("curl", "shasum", "pkgutil"):
            with self.subTest(failure=failure):
                result = self.installer(FAIL_COMMAND=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("installer", self.command_names())
                self.assert_not_exported()
        result = self.installer(FAKE_SIGNER="Developer ID Installer: Someone Else (WRONG)")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("installer", self.command_names())
        self.assert_not_exported()

    def test_failed_install_identity_or_version_never_exports_selection(self):
        for environment in ({"FAIL_COMMAND": "installer"},
                            {"FAKE_IDENTIFIER": "wrong.identifier"}, {"FAKE_VERSION": "6.4"}):
            with self.subTest(environment=environment):
                result = self.installer(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assert_not_exported()

    def test_verified_user_home_install_exports_exact_identity_and_compiler_path(self):
        result = self.installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.github_env.read_text(), f"TOOLCHAINS={IDENTIFIER}\n")
        self.assertEqual(self.github_path.read_text(), f"{self.toolchain}/usr/bin\n")
        calls = self.command_names()
        self.assertLess(calls.index("shasum"), calls.index("pkgutil"))
        self.assertLess(calls.index("pkgutil"), calls.index("installer"))
        installer_call = next(json.loads(line) for line in self.calls.read_text().splitlines()
                              if json.loads(line)[0] == "installer")
        self.assertEqual(installer_call[1:3], ["-target", "CurrentUserHomeDirectory"])

    def test_verifier_accepts_only_exact_sequoia_compiler_sdk_and_selector(self):
        self.seed_toolchain()
        result = self.run_script("verify-ci-toolchain.sh", "15", "26.3", "6.3.3")
        self.assertEqual(result.returncode, 0, result.stderr)
        for environment in ({"TOOLCHAINS": "swift"}, {"FAKE_IDENTIFIER": "wrong"},
                            {"FAKE_VERSION": "6.3.2"}, {"FAKE_OS": "26.6"},
                            {"FAKE_XCODE": "26.6"}, {"FAKE_SWIFT_LOCATION": "default"},
                            {"PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}"}):
            with self.subTest(environment=environment):
                result = self.run_script("verify-ci-toolchain.sh", "15", "26.3", "6.3.3", **environment)
                self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(self.run_script("verify-ci-toolchain.sh", "26", "26.6", "6.3.3").returncode, 0)

    def test_default_xcode_lane_keeps_existing_outside_toolchain_rejection(self):
        default = self.developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
        default.mkdir(parents=True)
        result = self.run_script("verify-ci-toolchain.sh", "26", "26.6",
                                 FAKE_OS="26.6", FAKE_XCODE="26.6", FAKE_SWIFT_LOCATION="default")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_script("verify-ci-toolchain.sh", "26", "26.6", FAKE_OS="26.6", FAKE_XCODE="26.6")
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
