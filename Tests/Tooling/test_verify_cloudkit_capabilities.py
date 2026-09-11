import os
import plistlib
import stat
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
VERIFIER = REPOSITORY / "scripts" / "verify-cloudkit-capabilities.sh"
MATERIALIZER = (
    REPOSITORY / "scripts" / "materialize-cloudkit-entitlements.py"
)


class VerifyCloudKitCapabilitiesTests(unittest.TestCase):
    def test_accepts_direct_distribution_profile_icloud_wildcard(self):
        result = self.run_verifier(profile_services="*")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("exact production app identity", result.stdout)

    def test_accepts_matching_application_identifier_aliases(self):
        result = self.run_verifier(
            profile_application_identifiers={
                "application-identifier": "TEAMID1234.app.portavoz.mac",
                "com.apple.application-identifier": (
                    "TEAMID1234.app.portavoz.mac"
                ),
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_development_bundle_identifier(self):
        result = self.run_verifier(bundle_identifier="app.portavoz.mac.dev")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signed app has CFBundleIdentifier", result.stderr)

    def test_rejects_missing_info_plist(self):
        result = self.run_verifier(include_info_plist=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing Contents/Info.plist", result.stderr)

    def test_rejects_profile_for_different_app_identifier(self):
        result = self.run_verifier(
            profile_application_identifiers={
                "application-identifier": "TEAMID1234.app.portavoz.other"
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "application identifier does not authorize", result.stderr
        )

    def test_rejects_missing_application_identifier(self):
        result = self.run_verifier(profile_application_identifiers={})

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no application identifier entitlement", result.stderr)

    def test_rejects_conflicting_application_identifier_aliases(self):
        result = self.run_verifier(
            profile_application_identifiers={
                "application-identifier": "TEAMID1234.app.portavoz.mac",
                "com.apple.application-identifier": (
                    "TEAMID1234.app.portavoz.other"
                ),
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("conflicting application identifier", result.stderr)

    def test_rejects_signed_app_without_application_identifier(self):
        result = self.run_verifier(signed_application_identifiers={})

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signed app application identifier", result.stderr)

    def test_rejects_signed_app_for_different_application_identifier(self):
        result = self.run_verifier(
            signed_application_identifiers={
                "com.apple.application-identifier": (
                    "TEAMID1234.app.portavoz.other"
                )
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signed app application identifier", result.stderr)

    def test_rejects_conflicting_signed_application_identifier_aliases(self):
        result = self.run_verifier(
            signed_application_identifiers={
                "com.apple.application-identifier": (
                    "TEAMID1234.app.portavoz.mac"
                ),
                "application-identifier": "TEAMID1234.app.portavoz.other",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signed app has conflicting", result.stderr)

    def test_rejects_signed_team_identifier_mismatch(self):
        result = self.run_verifier(signed_team_identifier="OTHERTEAM1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signed app developer team identifier", result.stderr)

    def test_rejects_inconsistent_profile_team_identifier(self):
        result = self.run_verifier(team_identifiers=("OTHERTEAM1",))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("profile team identifier is inconsistent", result.stderr)

    def test_rejects_missing_application_identifier_prefix(self):
        result = self.run_verifier(application_identifier_prefixes=[])

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no valid ApplicationIdentifierPrefix", result.stderr)

    def test_rejects_expired_profile(self):
        result = self.run_verifier(expiration_offset=timedelta(days=-1))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("provisioning profile expired", result.stderr)

    def test_rejects_non_dictionary_profile_entitlements_without_traceback(self):
        result = self.run_verifier(profile_entitlements=[])

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no valid Entitlements dictionary", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_rejects_non_dictionary_info_plist_without_traceback(self):
        result = self.run_verifier(info_payload=[])

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("app Info.plist property list is not a dictionary", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_rejects_profile_without_cloudkit_authorization(self):
        result = self.run_verifier(profile_services=["CloudDocuments"])

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("com.apple.developer.icloud-services", result.stderr)

    def test_rejects_wildcard_in_signed_app(self):
        result = self.run_verifier(
            profile_services="*",
            signed_services="*",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signed app has com.apple.developer.icloud-services", result.stderr)

    def run_verifier(
        self,
        *,
        profile_services="*",
        signed_services=("CloudKit",),
        bundle_identifier="app.portavoz.mac",
        include_info_plist=True,
        application_identifier_prefixes=("TEAMID1234",),
        profile_application_identifiers=None,
        signed_application_identifiers=None,
        signed_team_identifier="TEAMID1234",
        profile_team_identifier="TEAMID1234",
        team_identifiers=("TEAMID1234",),
        expiration_offset=timedelta(days=30),
        profile_entitlements=None,
        info_payload=None,
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Portavoz.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            (contents / "embedded.provisionprofile").write_bytes(b"fixture")
            if include_info_plist:
                with (contents / "Info.plist").open("wb") as handle:
                    if info_payload is None:
                        info_payload = {
                            "CFBundleIdentifier": bundle_identifier
                        }
                    plistlib.dump(info_payload, handle)

            signed = self.entitlements(signed_services)
            if signed_application_identifiers is None:
                signed_application_identifiers = {
                    "com.apple.application-identifier": (
                        "TEAMID1234.app.portavoz.mac"
                    )
                }
            signed.update(signed_application_identifiers)
            if signed_team_identifier is not None:
                signed["com.apple.developer.team-identifier"] = (
                    signed_team_identifier
                )
            if profile_entitlements is None:
                profile_entitlements = self.entitlements(profile_services)
                if profile_application_identifiers is None:
                    profile_application_identifiers = {
                        "com.apple.application-identifier": (
                            "TEAMID1234.app.portavoz.mac"
                        )
                    }
                profile_entitlements.update(profile_application_identifiers)
                if profile_team_identifier is not None:
                    profile_entitlements[
                        "com.apple.developer.team-identifier"
                    ] = profile_team_identifier
            profile = {
                "ApplicationIdentifierPrefix": list(
                    application_identifier_prefixes
                ),
                "Entitlements": profile_entitlements,
                "ExpirationDate": datetime.now(timezone.utc)
                + expiration_offset,
                "TeamIdentifier": list(team_identifiers),
            }
            signed_path = root / "signed.plist"
            profile_path = root / "profile.plist"
            with signed_path.open("wb") as handle:
                plistlib.dump(signed, handle)
            with profile_path.open("wb") as handle:
                plistlib.dump(profile, handle)

            tools = root / "bin"
            tools.mkdir()
            self.write_tool(tools / "codesign", f'cat "{signed_path}"\n')
            self.write_tool(tools / "security", f'cat "{profile_path}"\n')
            environment = os.environ.copy()
            environment["PATH"] = f"{tools}:{environment['PATH']}"
            return subprocess.run(
                [str(VERIFIER), str(app)],
                capture_output=True,
                check=False,
                env=environment,
                text=True,
            )

    @staticmethod
    def entitlements(services):
        if isinstance(services, tuple):
            services = list(services)
        return {
            "com.apple.developer.icloud-container-identifiers": [
                "iCloud.app.portavoz.mac"
            ],
            "com.apple.developer.icloud-services": services,
            "com.apple.developer.icloud-container-environment": "Production",
            "com.apple.developer.aps-environment": "production",
        }

    @staticmethod
    def write_tool(path, body):
        path.write_text(f"#!/bin/sh\n{body}", encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)


class MaterializeCloudKitEntitlementsTests(unittest.TestCase):
    def test_materializes_profile_owned_mac_identity(self):
        result, output = self.run_materializer()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            output["com.apple.application-identifier"],
            "TEAMID1234.app.portavoz.mac",
        )
        self.assertEqual(
            output["com.apple.developer.team-identifier"],
            "TEAMID1234",
        )
        self.assertEqual(
            output["com.apple.developer.icloud-services"],
            ["CloudKit"],
        )

    def test_accepts_matching_profile_application_identifier_aliases(self):
        result, output = self.run_materializer(
            application_identifiers={
                "com.apple.application-identifier": (
                    "TEAMID1234.app.portavoz.mac"
                ),
                "application-identifier": "TEAMID1234.app.portavoz.mac",
            }
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            output["com.apple.application-identifier"],
            "TEAMID1234.app.portavoz.mac",
        )

    def test_rejects_foreign_profile_app_identifier_without_output(self):
        result, output = self.run_materializer(
            application_identifiers={
                "com.apple.application-identifier": (
                    "TEAMID1234.app.portavoz.other"
                )
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(output)
        self.assertIn("does not authorize", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_rejects_hard_coded_base_identity(self):
        result, output = self.run_materializer(
            base_identity="TEAMID1234.app.portavoz.mac"
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(output)
        self.assertIn("must not hard-code", result.stderr)

    @staticmethod
    def run_materializer(
        *,
        application_identifiers=None,
        base_identity=None,
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base_path = root / "base.plist"
            profile_path = root / "profile.plist"
            output_path = root / "output.plist"

            base = {
                "com.apple.developer.icloud-services": ["CloudKit"],
            }
            if base_identity is not None:
                base["com.apple.application-identifier"] = base_identity
            if application_identifiers is None:
                application_identifiers = {
                    "com.apple.application-identifier": (
                        "TEAMID1234.app.portavoz.mac"
                    )
                }
            profile = {
                "ApplicationIdentifierPrefix": ["TEAMID1234"],
                "Entitlements": {
                    **application_identifiers,
                    "com.apple.developer.team-identifier": "TEAMID1234",
                },
                "TeamIdentifier": ["TEAMID1234"],
            }
            with base_path.open("wb") as handle:
                plistlib.dump(base, handle)
            with profile_path.open("wb") as handle:
                plistlib.dump(profile, handle)

            result = subprocess.run(
                [
                    "python3",
                    str(MATERIALIZER),
                    str(base_path),
                    str(profile_path),
                    str(output_path),
                    "app.portavoz.mac",
                ],
                capture_output=True,
                check=False,
                text=True,
            )
            output = None
            if output_path.exists():
                with output_path.open("rb") as handle:
                    output = plistlib.load(handle)
            return result, output


if __name__ == "__main__":
    unittest.main()
