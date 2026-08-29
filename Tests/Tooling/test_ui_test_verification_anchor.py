import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "ui_test_verification_anchor.py"
SHA = "a" * 40
TEST = "PortavozUITests/LibraryUITests/testLibraryRendersRecordButtonAndActionChips"


class UITestVerificationAnchorTests(unittest.TestCase):
    def run_anchor(self, *, required="true", tests=TEST, locales="en"):
        temporary = tempfile.TemporaryDirectory()
        output = Path(temporary.name) / "receipt.json"
        completed = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--commit",
                SHA,
                "--required",
                required,
                "--tests",
                tests,
                "--locales",
                locales,
                "--output",
                str(output),
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        document = json.loads(output.read_text(encoding="utf-8")) if output.exists() else None
        return temporary, completed, document

    def test_scoped_success_creates_content_free_digest(self):
        temporary, completed, document = self.run_anchor()
        self.addCleanup(temporary.cleanup)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(document["commit"], SHA)
        self.assertEqual(document["selectorCount"], 1)
        self.assertNotIn(TEST, json.dumps(document))
        self.assertEqual(set(document), {
            "commit", "kind", "locales", "schemaVersion", "selectorCount", "selectorSHA256"
        })

    def test_no_ui_change_creates_zero_selector_anchor(self):
        temporary, completed, document = self.run_anchor(
            required="false",
            tests="",
            locales="",
        )
        self.addCleanup(temporary.cleanup)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(document["selectorCount"], 0)
        self.assertEqual(document["locales"], [])

    def test_required_state_cannot_disagree_with_selection(self):
        temporary, completed, document = self.run_anchor(
            required="true",
            tests="",
            locales="",
        )
        self.addCleanup(temporary.cleanup)

        self.assertEqual(completed.returncode, 2)
        self.assertIsNone(document)


if __name__ == "__main__":
    unittest.main()
