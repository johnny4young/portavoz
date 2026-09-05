import json
import os
import plistlib
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
PACKAGER = REPOSITORY / "scripts" / "make-production-sync-qualification-app.sh"


class ProductionSyncQualificationPackagingTests(unittest.TestCase):
    def test_builds_exact_identity_bundle_without_installing_or_opening_it(self):
        with tempfile.TemporaryDirectory() as directory:
            repository, commit, environment = self.make_fixture(Path(directory))

            result = subprocess.run(
                [str(repository / "scripts" / PACKAGER.name)],
                cwd=repository,
                capture_output=True,
                check=False,
                env=environment,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            output = repository / "dist" / "Portavoz Sync Qualification.app"
            self.assertTrue(output.is_dir())
            with (output / "Contents" / "Info.plist").open("rb") as handle:
                info = plistlib.load(handle)
            self.assertEqual(info["CFBundleIdentifier"], "app.portavoz.mac")
            self.assertEqual(
                info["CFBundleDisplayName"], "Portavoz Sync Qualification"
            )
            self.assertEqual(info["CFBundleShortVersionString"], "1.0.0")
            self.assertEqual(info["CFBundleVersion"], "202608250001")
            self.assertEqual(info["PortavozSourceCommit"], commit)
            self.assertEqual(
                (
                    output
                    / "Contents"
                    / "Resources"
                    / "production-sync-qualification.json"
                ).read_bytes(),
                (
                    repository
                    / "docs"
                    / "evidence"
                    / "production-sync-qualification.json"
                ).read_bytes(),
            )
            self.assertIn(
                "--entitlements dist/.portavoz-production.entitlements",
                (repository / "codesign.log").read_text(encoding="utf-8"),
            )
            verification = (repository / "verify.log").read_text(
                encoding="utf-8"
            ).splitlines()
            self.assertEqual(len(verification), 1)
            self.assertIn(".Portavoz-Sync-Qualification.", verification[0])

            tool_log_root = Path(environment["FIXTURE_TOOL_LOG_ROOT"])
            plutil_calls = [
                json.loads(line)
                for line in (tool_log_root / "plutil.log").read_text(
                    encoding="utf-8"
                ).splitlines()
            ]
            self.assertEqual(
                [call[:4] for call in plutil_calls[:2]],
                [
                    [
                        "-replace",
                        "CFBundleDisplayName",
                        "-string",
                        "Portavoz Sync Qualification",
                    ],
                    [
                        "-replace",
                        "CFBundleName",
                        "-string",
                        "Portavoz Sync Qualification",
                    ],
                ],
            )
            self.assertEqual(
                [call[0] for call in plutil_calls[2:]],
                ["-lint", "-lint"],
            )
            sed_calls = [
                json.loads(line)
                for line in (tool_log_root / "sed.log").read_text(
                    encoding="utf-8"
                ).splitlines()
            ]
            self.assertEqual(len(sed_calls), 2)
            self.assertEqual([call[:3] for call in sed_calls], [["-i", "", "-e"]] * 2)
            for locale, call in zip(("en", "es"), sed_calls, strict=True):
                self.assertTrue(
                    call[-1].endswith(
                        f"/{locale}.lproj/InfoPlist.strings"
                    )
                )
                localized = (
                    output
                    / "Contents"
                    / "Resources"
                    / f"{locale}.lproj"
                    / "InfoPlist.strings"
                ).read_text(encoding="utf-8")
                self.assertIn(
                    '"CFBundleDisplayName" = "Portavoz Sync Qualification";',
                    localized,
                )
                self.assertIn(
                    '"CFBundleName" = "Portavoz Sync Qualification";',
                    localized,
                )

            source = PACKAGER.read_text(encoding="utf-8")
            self.assertNotIn("/Applications/", source)
            self.assertNotIn("lsregister", source)
            self.assertNotIn("open \"$OUTPUT\"", source)

    def test_rejects_adjacent_source_commit_before_building(self):
        with tempfile.TemporaryDirectory() as directory:
            repository, _, environment = self.make_fixture(Path(directory))
            environment["PORTAVOZ_RELEASE_COMMIT"] = "0" * 40

            result = subprocess.run(
                [str(repository / "scripts" / PACKAGER.name)],
                cwd=repository,
                capture_output=True,
                check=False,
                env=environment,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match HEAD at preflight", result.stderr)
            self.assertFalse((repository / "make-app.log").exists())

    def test_failed_final_signature_leaves_no_qualification_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            repository, _, environment = self.make_fixture(Path(directory))
            environment["FIXTURE_CODESIGN_STATUS"] = "1"

            result = subprocess.run(
                [str(repository / "scripts" / PACKAGER.name)],
                cwd=repository,
                capture_output=True,
                check=False,
                env=environment,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(
                (repository / "dist" / "Portavoz Sync Qualification.app").exists()
            )
            self.assertEqual(
                list((repository / "dist").glob(".Portavoz-Sync-Qualification.*")),
                [],
            )
            self.assertFalse((repository / "verify.log").exists())

    def test_dev_install_rejects_production_profile_before_building(self):
        result = subprocess.run(
            [
                "make",
                "install",
                "PORTAVOZ_PROVISIONING_PROFILE=/private/tmp/fixture.provisionprofile",
            ],
            cwd=REPOSITORY,
            capture_output=True,
            check=False,
            text=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot mutate a production-profile app", result.stderr)
        self.assertNotIn("Building portavoz-app", result.stdout + result.stderr)

    @staticmethod
    def make_fixture(root):
        repository = root / "repository"
        scripts = repository / "scripts"
        packaging = repository / "packaging"
        evidence = repository / "docs" / "evidence"
        tools = root / "bin"
        scripts.mkdir(parents=True)
        packaging.mkdir()
        evidence.mkdir(parents=True)
        tools.mkdir()

        copied_packager = scripts / PACKAGER.name
        copied_packager.write_bytes(PACKAGER.read_bytes())
        copied_packager.chmod(copied_packager.stat().st_mode | stat.S_IXUSR)
        (
            evidence / "production-sync-qualification.json"
        ).write_bytes(
            (
                REPOSITORY
                / "docs"
                / "evidence"
                / "production-sync-qualification.json"
            ).read_bytes()
        )
        (packaging / "portavoz.entitlements").write_text(
            "fixture\n", encoding="utf-8"
        )
        profile = repository / "fixture.provisionprofile"
        profile.write_bytes(b"fixture")
        (repository / ".gitignore").write_text(
            "dist/\nmake-app.log\ncodesign.log\nverify.log\n",
            encoding="utf-8",
        )

        make_app = scripts / "make-app.sh"
        make_app.write_text(
            textwrap.dedent(
                """\
                #!/bin/bash
                set -euo pipefail
                mkdir -p dist/Portavoz.app/Contents/Resources/en.lproj
                mkdir -p dist/Portavoz.app/Contents/Resources/es.lproj
                python3 - "$PORTAVOZ_RELEASE_COMMIT" "$3" "$5" <<'PY'
                import plistlib
                import sys
                commit, version, build = sys.argv[1:]
                info = {
                    "CFBundleIdentifier": "app.portavoz.mac",
                    "CFBundleDisplayName": "Portavoz",
                    "CFBundleName": "Portavoz",
                    "CFBundleShortVersionString": version,
                    "CFBundleVersion": build,
                    "PortavozSourceCommit": commit,
                }
                with open("dist/Portavoz.app/Contents/Info.plist", "wb") as handle:
                    plistlib.dump(info, handle)
                PY
                for locale in en es; do
                  cat > "dist/Portavoz.app/Contents/Resources/$locale.lproj/InfoPlist.strings" <<'STRINGS'
                "CFBundleDisplayName" = "Portavoz";
                "CFBundleName" = "Portavoz";
                STRINGS
                done
                cat > dist/.portavoz-production.entitlements <<'ENTITLEMENTS'
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                <key>com.apple.application-identifier</key>
                <string>TEAMID1234.app.portavoz.mac</string>
                <key>com.apple.developer.team-identifier</key>
                <string>TEAMID1234</string>
                </dict></plist>
                ENTITLEMENTS
                printf '%s\\n' dist/.portavoz-production.entitlements > dist/.portavoz-sign-entitlements
                printf '%s\\n' make-app > make-app.log
                """
            ),
            encoding="utf-8",
        )
        make_app.chmod(make_app.stat().st_mode | stat.S_IXUSR)

        verifier = scripts / "verify-cloudkit-capabilities.sh"
        verifier.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$1\" >> verify.log\n",
            encoding="utf-8",
        )
        verifier.chmod(verifier.stat().st_mode | stat.S_IXUSR)

        codesign = tools / "codesign"
        codesign.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" >> \"$FIXTURE_REPOSITORY/codesign.log\"\n"
            "exit \"${FIXTURE_CODESIGN_STATUS:-0}\"\n",
            encoding="utf-8",
        )
        codesign.chmod(codesign.stat().st_mode | stat.S_IXUSR)

        plutil = tools / "plutil"
        plutil.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                import plistlib
                import sys
                from pathlib import Path

                arguments = sys.argv[1:]
                log = Path(os.environ["FIXTURE_TOOL_LOG_ROOT"]) / "plutil.log"
                with log.open("a", encoding="utf-8") as handle:
                    handle.write(json.dumps(arguments) + "\\n")

                if arguments[:1] == ["-replace"]:
                    if len(arguments) != 5 or arguments[2] != "-string":
                        raise SystemExit("unexpected plutil replacement arguments")
                    path = Path(arguments[4])
                    with path.open("rb") as handle:
                        document = plistlib.load(handle)
                    document[arguments[1]] = arguments[3]
                    with path.open("wb") as handle:
                        plistlib.dump(document, handle)
                elif arguments[:1] == ["-lint"]:
                    if len(arguments) != 2:
                        raise SystemExit("unexpected plutil lint arguments")
                    content = Path(arguments[1]).read_text(encoding="utf-8")
                    expected = (
                        '\"CFBundleDisplayName\" = \"Portavoz Sync Qualification\";',
                        '\"CFBundleName\" = \"Portavoz Sync Qualification\";',
                    )
                    if any(line not in content for line in expected):
                        raise SystemExit("localized display metadata was not rewritten")
                else:
                    raise SystemExit("unexpected plutil operation")
                """
            ),
            encoding="utf-8",
        )
        plutil.chmod(plutil.stat().st_mode | stat.S_IXUSR)

        sed = tools / "sed"
        sed.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                import sys
                from pathlib import Path

                arguments = sys.argv[1:]
                log = Path(os.environ["FIXTURE_TOOL_LOG_ROOT"]) / "sed.log"
                with log.open("a", encoding="utf-8") as handle:
                    handle.write(json.dumps(arguments) + "\\n")

                expected = [
                    "-i",
                    "",
                    "-e",
                    's/^\"CFBundleDisplayName\" = \".*\";$/\"CFBundleDisplayName\" = \"Portavoz Sync Qualification\";/',
                    "-e",
                    's/^\"CFBundleName\" = \".*\";$/\"CFBundleName\" = \"Portavoz Sync Qualification\";/',
                ]
                if len(arguments) != 7 or arguments[:6] != expected:
                    raise SystemExit("unexpected sed arguments")
                path = Path(arguments[6])
                content = path.read_text(encoding="utf-8")
                replacements = (
                    (
                        '\"CFBundleDisplayName\" = \"Portavoz\";',
                        '\"CFBundleDisplayName\" = \"Portavoz Sync Qualification\";',
                    ),
                    (
                        '\"CFBundleName\" = \"Portavoz\";',
                        '\"CFBundleName\" = \"Portavoz Sync Qualification\";',
                    ),
                )
                for original, replacement in replacements:
                    if original not in content:
                        raise SystemExit("expected localized metadata was absent")
                    content = content.replace(original, replacement)
                path.write_text(content, encoding="utf-8")
                """
            ),
            encoding="utf-8",
        )
        sed.chmod(sed.stat().st_mode | stat.S_IXUSR)

        subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
        subprocess.run(
            ["git", "config", "user.name", "Portavoz Fixture"],
            cwd=repository,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.email", "fixture@example.invalid"],
            cwd=repository,
            check=True,
        )
        subprocess.run(["git", "add", "."], cwd=repository, check=True)
        subprocess.run(
            ["git", "commit", "-qm", "fixture"], cwd=repository, check=True
        )
        commit = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repository,
            capture_output=True,
            check=True,
            text=True,
        ).stdout.strip()

        environment = os.environ.copy()
        environment.update(
            {
                "FIXTURE_REPOSITORY": str(repository),
                "FIXTURE_TOOL_LOG_ROOT": str(root),
                "PATH": f"{tools}:{environment['PATH']}",
                "PORTAVOZ_RELEASE_VERSION": "1.0.0",
                "PORTAVOZ_RELEASE_BUILD": "202608250001",
                "PORTAVOZ_RELEASE_COMMIT": commit,
                "PORTAVOZ_SIGN_IDENTITY": "Developer ID fixture",
                "PORTAVOZ_PROVISIONING_PROFILE": str(profile),
            }
        )
        return repository, commit, environment


if __name__ == "__main__":
    unittest.main()
