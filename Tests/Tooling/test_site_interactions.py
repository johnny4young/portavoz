"""Execute the shipped site's script against explicit browser capability doubles."""
import subprocess
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SiteInteractionTests(unittest.TestCase):
    def test_browser_capability_failures_and_copy_lifecycle(self):
        result = subprocess.run(
            ["node", "Tests/Tooling/site_interactions_test.cjs"],
            cwd=ROOT, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
