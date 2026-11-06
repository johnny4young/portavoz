import base64
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "make-release.sh"


class MakeReleaseTests(unittest.TestCase):
    version = "1.0.0"
    build = "202608300001"
    commit = "a" * 40

    def test_missing_appcast_signer_fails_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))
            missing_signer = repository / "tools" / "missing-generate-appcast"

            result = self.run_release(repository, missing_signer)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("generate_appcast", result.stderr)
            self.assertFalse((repository / "build-called").exists())

    def test_successful_signer_without_appcast_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))
            signer = repository / "tools" / "generate_appcast"
            self.write_executable(signer, "#!/bin/bash\nexit 0\n")

            result = self.run_release(repository, signer)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("release appcast not found", result.stderr)
            self.assertNotIn("Release 1.0.0 ready", result.stdout)
            self.assertFalse((repository / "dist" / "release" / "portavoz.rb").exists())

    def test_symlinked_appcast_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))
            signer = self.make_signer(repository, symlink_appcast=True)

            result = self.run_release(repository, signer)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must not be a symbolic link", result.stderr)
            self.assertNotIn("Release 1.0.0 ready", result.stdout)
            self.assertFalse((repository / "dist" / "release" / "portavoz.rb").exists())

    def test_malformed_signature_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))
            signer = self.make_signer(repository, signature="not-base64")

            result = self.run_release(repository, signer)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("malformed EdDSA signature", result.stderr)
            self.assertNotIn("Release 1.0.0 ready", result.stdout)

    def test_wrong_appcast_identity_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))
            signer = self.make_signer(repository, version="0.9.9")

            result = self.run_release(repository, signer)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("version/build does not match", result.stderr)
            self.assertNotIn("Release 1.0.0 ready", result.stdout)

    def test_wrong_appcast_build_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))
            signer = self.make_signer(repository, build="202608299999")

            result = self.run_release(repository, signer)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("version/build does not match", result.stderr)
            self.assertNotIn("Release 1.0.0 ready", result.stdout)

    def test_wrong_enclosure_url_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))
            signer = self.make_signer(
                repository,
                url="https://example.invalid/Portavoz-1.0.0.dmg",
            )

            result = self.run_release(repository, signer)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("enclosure URL does not match", result.stderr)
            self.assertNotIn("Release 1.0.0 ready", result.stdout)

    def test_wrong_enclosure_length_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))
            signer = self.make_signer(repository, length=4)

            result = self.run_release(repository, signer)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("enclosure length does not match", result.stderr)
            self.assertNotIn("Release 1.0.0 ready", result.stdout)

    def test_appcast_offering_older_macos_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))
            signer = self.make_signer(repository, minimum_system="14.4")

            result = self.run_release(repository, signer)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must require macOS 26.0 or newer", result.stderr)
            self.assertNotIn("Release 1.0.0 ready", result.stdout)

    def test_a_version_missing_from_the_changelog_fails_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))
            (repository / "CHANGELOG.md").write_text("## 0.9.0 — May 1, 2026\n\n- Older\n", encoding="utf-8")

            result = self.run_release(repository, self.make_signer(repository))

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no section for 1.0.0", result.stderr)
            self.assertFalse((repository / "build-called").exists())

    def test_appcast_without_the_embedded_notes_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))
            signer = self.make_signer(repository, description="")

            result = self.run_release(repository, signer)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not embed the release notes", result.stderr)
            self.assertNotIn("Release 1.0.0 ready", result.stdout)

    def test_appcast_with_other_notes_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))
            signer = self.make_signer(repository, description="<description>Older notes</description>")

            result = self.run_release(repository, signer)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not embed the release notes", result.stderr)
            self.assertNotIn("Release 1.0.0 ready", result.stdout)

    def test_unreadable_notes_fail_with_an_error_line(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))
            signer = self.make_signer(repository, corrupts_notes=True)

            result = self.run_release(repository, signer)

            self.assertEqual(result.returncode, 64)
            self.assertIn("error: release notes cannot be read", result.stderr)
            self.assertNotIn("Traceback", result.stderr)

    def test_the_signer_is_asked_to_embed_the_notes_beside_the_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))

            result = self.run_release(repository, self.make_signer(repository))

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("--embed-release-notes", (repository / "signer-arguments").read_text(encoding="utf-8"))
            notes = repository / "dist" / "release" / "Portavoz-1.0.0.html"
            self.assertIn("<strong>Fixes</strong>", notes.read_text(encoding="utf-8"))

    def test_exact_signed_appcast_allows_release_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))
            signer = self.make_signer(repository)

            result = self.run_release(repository, signer)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Verified signed release appcast", result.stdout)
            self.assertIn("Release 1.0.0 ready", result.stdout)
            cask = repository / "dist" / "release" / "portavoz.rb"
            self.assertTrue(cask.is_file())
            self.assertTrue(cask.read_text(encoding="utf-8").startswith('cask "portavoz" do\n  version "1.0.0"'))

    def test_the_dsym_is_kept_outside_the_folder_the_signer_scans(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = self.make_repository(Path(directory))

            result = self.run_release(repository, self.make_signer(repository))

            self.assertEqual(result.returncode, 0, result.stderr)
            kept = repository / "dist" / "dsym" / f"Portavoz-{self.version}-{self.build}.app.dSYM"
            self.assertEqual((kept / "Contents" / "Info.plist").read_text(encoding="utf-8"), "symbols")
            self.assertIn(f"Crash symbols: dist/dsym/{kept.name}", result.stdout)
            self.assertEqual(list((repository / "dist" / "release").rglob("*.dSYM")), [])

    def make_repository(self, root: Path) -> Path:
        repository = root / "repository"
        scripts = repository / "scripts"
        tools = repository / "tools"
        casks = repository / "packaging" / "Casks"
        scripts.mkdir(parents=True)
        tools.mkdir()
        casks.mkdir(parents=True)

        (repository / "CHANGELOG.md").write_text(
            "## 1.0.0 — May 2, 2026\n\n- **Fixes** — they help\n\n## 0.9.0 — May 1, 2026\n\n- Older\n",
            encoding="utf-8",
        )
        shutil.copy2(SCRIPT, scripts / SCRIPT.name)
        shutil.copy2(REPOSITORY / "scripts" / "release_notes.py", scripts / "release_notes.py")
        shutil.copy2(REPOSITORY / "scripts" / "render-cask.sh", scripts / "render-cask.sh")
        shutil.copy2(
            REPOSITORY / "scripts" / "verify_release_appcast.py",
            scripts / "verify_release_appcast.py",
        )
        self.write_executable(
            tools / "git",
            f"""#!/bin/bash
set -euo pipefail
case "$*" in
  "rev-parse HEAD") printf '%s\\n' '{self.commit}' ;;
  "status --porcelain --untracked-files=no") exit 0 ;;
  *) printf 'unexpected git invocation: %s\\n' "$*" >&2; exit 70 ;;
esac
""",
        )
        self.write_executable(
            scripts / "make-app.sh",
            """#!/bin/bash
set -euo pipefail
touch build-called
mkdir -p dist/Portavoz.app.dSYM/Contents
printf 'symbols' > dist/Portavoz.app.dSYM/Contents/Info.plist
""",
        )
        self.write_executable(
            scripts / "make-dmg.sh",
            f"""#!/bin/bash
set -euo pipefail
mkdir -p dist
printf 'dmg' > 'dist/Portavoz-{self.version}.dmg'
""",
        )
        (casks / "portavoz.rb").write_text(
            '# Template header.\ncask "portavoz" do\n  version "__VERSION__"\n  sha256 "__SHA256__"\nend\n',
            encoding="utf-8",
        )
        return repository

    def make_signer(
        self,
        repository: Path,
        *,
        version: str | None = None,
        build: str | None = None,
        signature: str | None = None,
        url: str | None = None,
        length: int = 3,
        minimum_system: str = "26.0",
        symlink_appcast: bool = False,
        description: str | None = None,
        corrupts_notes: bool = False,
    ) -> Path:
        signer = repository / "tools" / "generate_appcast"
        resolved_version = self.version if version is None else version
        resolved_build = self.build if build is None else build
        resolved_signature = (
            base64.b64encode(b"s" * 64).decode()
            if signature is None
            else signature
        )
        resolved_url = url or (
            "https://github.com/johnny4young/portavoz/releases/latest/download/"
            f"Portavoz-{self.version}.dmg"
        )
        appcast_destination = (
            '"$PWD/outside-appcast.xml"'
            if symlink_appcast
            else '"$release_dir/appcast.xml"'
        )
        link_appcast = (
            'ln -s "$PWD/outside-appcast.xml" "$release_dir/appcast.xml"'
            if symlink_appcast
            else ""
        )
        resolved_description = (
            f'<description><![CDATA[$(cat "$release_dir/Portavoz-{self.version}.html")]]></description>'
            if description is None
            else description
        )
        corrupt_notes = f"""printf '\\377' > "$release_dir/Portavoz-{self.version}.html\"""" if corrupts_notes else ""
        self.write_executable(
            signer,
            f"""#!/bin/bash
set -euo pipefail
printf '%s\\n' "$*" > signer-arguments
release_dir="${{!#}}"
cat > {appcast_destination} <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:version>{resolved_build}</sparkle:version>
      <sparkle:shortVersionString>{resolved_version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minimum_system}</sparkle:minimumSystemVersion>
      {resolved_description}
      <enclosure url="{resolved_url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{resolved_signature}"/>
    </item>
  </channel>
</rss>
XML
{link_appcast}
{corrupt_notes}
""",
        )
        return signer

    def run_release(
        self,
        repository: Path,
        signer: Path,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{repository / 'tools'}:/usr/bin:/bin",
                "HOME": str(repository / "home"),
                "GENERATE_APPCAST": str(signer),
                "PORTAVOZ_BUILD": self.build,
                "PORTAVOZ_NOTARY_PROFILE": "test-notary",
                "PORTAVOZ_PROVISIONING_PROFILE": str(
                    repository / "test.provisionprofile"
                ),
                "PORTAVOZ_RELEASE_COMMIT": self.commit,
                "PORTAVOZ_SIGN_IDENTITY": "test-developer-id",
            }
        )
        return subprocess.run(
            [str(repository / "scripts" / "make-release.sh"), self.version],
            cwd=repository,
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )

    @staticmethod
    def write_executable(path: Path, contents: str) -> None:
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
