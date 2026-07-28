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


class VerifyCloudKitCapabilitiesTests(unittest.TestCase):
    def test_accepts_direct_distribution_profile_icloud_wildcard(self):
        result = self.run_verifier(profile_services="*")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("production CloudKit + APNs", result.stdout)

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
        profile_services,
        signed_services=("CloudKit",),
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Portavoz.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            (contents / "embedded.provisionprofile").write_bytes(b"fixture")

            signed = self.entitlements(signed_services)
            profile = {
                "Entitlements": self.entitlements(profile_services),
                "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=30),
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


if __name__ == "__main__":
    unittest.main()
