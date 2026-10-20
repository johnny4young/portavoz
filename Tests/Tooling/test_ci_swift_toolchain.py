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

    def test_verifier_accepts_only_the_current_sdk_lane(self):
        for args in (("15", "26.3"), ("26", "26.6", "6.3.3"), ("26",)):
            with self.subTest(args=args):
                result = self.run_script("verify-ci-toolchain.sh", *args, FAKE_OS="26.6", FAKE_XCODE="26.6")
                self.assertEqual(result.returncode, 64, result.stderr)

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
