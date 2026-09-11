import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts" / "check-ios-portability.sh"


class IOSPortabilityTests(unittest.TestCase):
    def run_runner(
        self,
        *,
        sdk_version: str = "26.6",
        create_sdk: bool = True,
        fail_target: str | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], list[list[str]], Path]:
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        binary = root / "bin"
        binary.mkdir()
        sdk = root / "iPhoneSimulator.sdk"
        if create_sdk:
            sdk.mkdir()
        log = root / "swift.jsonl"
        swift = binary / "swift"
        swift.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$@\" | \"$REAL_PYTHON\" -c '"
            "import json,sys; print(json.dumps(sys.stdin.read().splitlines()))' "
            '>> "$SWIFT_LOG"\n'
            "target=''\n"
            "previous=''\n"
            "for value in \"$@\"; do\n"
            "  if [ \"$previous\" = --target ]; then target=$value; fi\n"
            "  previous=$value\n"
            "done\n"
            "test \"$target\" != \"${FAIL_TARGET:-}\"\n",
            encoding="utf-8",
        )
        swift.chmod(0o755)
        xcrun = binary / "xcrun"
        xcrun.write_text(
            "#!/bin/sh\n"
            "case \"$*\" in\n"
            f"  '--find swift') printf '%s\\n' '{swift}' ;;\n"
            f"  '--sdk iphonesimulator --show-sdk-path') printf '%s\\n' '{sdk}' ;;\n"
            "  '--sdk iphonesimulator --show-sdk-version') "
            f"printf '%s\\n' '{sdk_version}' ;;\n"
            "  *) exit 64 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        xcrun.chmod(0o755)
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{binary}:{environment['PATH']}",
                "REAL_PYTHON": shutil.which("python3") or "python3",
                "SWIFT_LOG": str(log),
                "FAIL_TARGET": fail_target or "",
                "PORTAVOZ_IOS_PORTABILITY_SCRATCH": str(root / "scratch"),
            }
        )
        result = subprocess.run(
            [str(RUNNER)],
            cwd=ROOT,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        calls = (
            [json.loads(line) for line in log.read_text().splitlines()]
            if log.exists()
            else []
        )
        return result, calls, root

    def test_compiles_exact_targets_sequentially_in_one_scratch_graph(self):
        result, calls, root = self.run_runner()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 4)
        self.assertEqual(
            [call[call.index("--target") + 1] for call in calls],
            ["PortavozCore", "StorageKit", "ApplicationKit", "IntegrationsKit"],
        )
        for call in calls:
            self.assertEqual(call[0], "build")
            self.assertEqual(
                call[call.index("--triple") + 1],
                "arm64-apple-ios17.0-simulator",
            )
            self.assertEqual(
                call[call.index("--scratch-path") + 1],
                str(root / "scratch"),
            )
            self.assertEqual(
                call[call.index("--sdk") + 1],
                str(root / "iPhoneSimulator.sdk"),
            )

    def test_missing_or_obsolete_sdk_fails_before_swift(self):
        missing, calls, _ = self.run_runner(create_sdk=False)
        self.assertEqual(missing.returncode, 2)
        self.assertEqual(calls, [])
        self.assertIn("did not resolve an installed", missing.stderr)

        obsolete, calls, _ = self.run_runner(sdk_version="18.5")
        self.assertEqual(obsolete.returncode, 2)
        self.assertEqual(calls, [])
        self.assertIn("requires an iPhone Simulator 26+ SDK", obsolete.stderr)

    def test_first_compiler_failure_stops_later_targets(self):
        result, calls, _ = self.run_runner(fail_target="StorageKit")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            [call[call.index("--target") + 1] for call in calls],
            ["PortavozCore", "StorageKit"],
        )


if __name__ == "__main__":
    unittest.main()
