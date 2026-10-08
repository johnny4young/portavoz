"""Compare the parsed disposable-app metadata with the shipping plist owner."""

import json
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("xcodegen"), "XcodeGen is required to parse the UI project")
class UIBundleMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "project.json"
            subprocess.run(
                ["xcodegen", "dump", "--spec", str(ROOT / "project.yml"),
                 "--type", "json", "--no-env", "--quiet", "--file", str(output)],
                check=True, capture_output=True, text=True, timeout=30,
            )
            cls.project = json.loads(output.read_text())
        script = (ROOT / "scripts/make-app.sh").read_text()
        marker = 'cat > "$APP/Contents/Info.plist" << \'PLIST\'\n'
        cls.shipping = plistlib.loads(script.split(marker, 1)[1].split("\nPLIST", 1)[0].encode())
        cls.target = cls.project["targets"]["Portavoz"]
        cls.properties = cls.target["info"]["properties"]

    def test_disposable_app_exports_the_actual_shipping_file_type(self):
        self.assertEqual(
            self.properties.get("UTExportedTypeDeclarations"),
            self.shipping["UTExportedTypeDeclarations"],
            "A native picker must not depend on a release app having registered .portavoz",
        )

    def test_disposable_app_does_not_claim_the_release_document_handler(self):
        self.assertNotIn("CFBundleDocumentTypes", self.properties)
        self.assertNotEqual(
            self.target["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"],
            self.shipping["CFBundleIdentifier"],
        )

    def test_bundle_fixture_links_its_typed_codec_explicitly(self):
        products = {
            product
            for dependency in self.project["targets"]["PortavozUITests"]["dependencies"]
            for product in dependency.get("products", [])
        }
        self.assertTrue({"PortavozCore", "IntegrationsKit"}.issubset(products))


if __name__ == "__main__":
    unittest.main()
