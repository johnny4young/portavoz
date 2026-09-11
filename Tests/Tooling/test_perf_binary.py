import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts" / "perf-binary.sh"


class PerformanceBinaryHelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.repository = Path(self.temporary.name) / "source"
        self.repository.mkdir()
        self.git("init", "--quiet")
        self.git("config", "user.email", "tooling@example.invalid")
        self.git("config", "user.name", "Tooling Test")
        (self.repository / "README.md").write_text("fixture\n", encoding="utf-8")
        self.git("add", "README.md")
        self.git("commit", "--quiet", "-m", "fixture")
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()
        self.binary = self.repository / "portavoz-cli"
        self.binary.write_bytes(b"exact release fixture")
        self.binary.chmod(0o700)
        self.sha256 = hashlib.sha256(self.binary.read_bytes()).hexdigest()

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        return subprocess.run(
            ["git", *arguments],
            cwd=self.repository,
            check=True,
            capture_output=True,
            text=True,
        )

    def invoke(
        self,
        *,
        binary: Path | None = None,
        sha256: str | None = None,
        commit: str | None = None,
        build_wall_milliseconds: str | None = "1250.5",
    ):
        environment = os.environ.copy()
        values = {
            "PORTAVOZ_PERF_BINARY": str(binary or self.binary),
            "PORTAVOZ_PERF_BINARY_SHA256": sha256,
            "PORTAVOZ_PERF_SOURCE_COMMIT": commit,
            "PORTAVOZ_PERF_BUILD_WALL_MS": build_wall_milliseconds,
        }
        for key, value in values.items():
            if value is None:
                environment.pop(key, None)
            else:
                environment[key] = value
        return subprocess.run(
            [
                "bash",
                "-c",
                (
                    'set -euo pipefail; source "$1"; '
                    'portavoz_prepare_perf_binary "$2"; '
                    'printf "%s\\n%s\\n%s\\n%s\\n" '
                    '"$PORTAVOZ_PERF_BINARY" '
                    '"$PORTAVOZ_PERF_BINARY_SHA256" '
                    '"$PORTAVOZ_PERF_BUILD_WALL_MS" '
                    '"$PORTAVOZ_PERF_SOURCE_COMMIT"'
                ),
                "perf-binary-test",
                str(HELPER),
                str(self.repository),
            ],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

    def test_accepts_only_the_exact_regular_prebuilt_binary_identity(self):
        result = self.invoke(sha256=self.sha256, commit=self.commit)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [str(self.binary), self.sha256, "1250.5", self.commit],
        )

    def test_prebuilt_binary_requires_complete_caller_supplied_identity(self):
        for missing in ("sha256", "commit", "build_wall_milliseconds"):
            arguments = {"sha256": self.sha256, "commit": self.commit}
            arguments[missing] = None
            with self.subTest(missing=missing):
                result = self.invoke(**arguments)
                self.assertEqual(result.returncode, 64)
                self.assertIn(
                    "requires build duration, SHA-256, and source commit",
                    result.stderr,
                )

    def test_rejects_digest_or_source_drift(self):
        cases = (
            ({"sha256": "f" * 64, "commit": self.commit}, "binary changed"),
            ({"sha256": self.sha256, "commit": "e" * 40}, "HEAD changed"),
        )
        for arguments, message in cases:
            with self.subTest(message=message):
                result = self.invoke(**arguments)
                self.assertEqual(result.returncode, 65)
                self.assertIn(message, result.stderr)

    def test_rejects_a_symlink_even_when_its_target_identity_matches(self):
        link = self.repository / "linked-portavoz-cli"
        link.symlink_to(self.binary)

        result = self.invoke(
            binary=link,
            sha256=self.sha256,
            commit=self.commit,
        )

        self.assertEqual(result.returncode, 66)
        self.assertIn("executable regular file", result.stderr)


if __name__ == "__main__":
    unittest.main()
