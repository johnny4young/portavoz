"""Keep the first installation choice explicit and release-scoped."""
import os
from html.parser import HTMLParser
from pathlib import Path
import unittest

ROOT = Path(os.environ.get("PORTAVOZ_SITE_TEST_ROOT", Path(__file__).resolve().parents[2]))


class HeroParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.actions = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "a" and "download-primary" in attrs.get("class", "").split():
            self.actions.append(("download", attrs.get("href")))
        if tag == "button" and attrs.get("id") == "brew":
            self.actions.append(("terminal", None))


class FirstInstallSiteTests(unittest.TestCase):
    def test_graphical_installer_precedes_terminal_alternative(self):
        parser = HeroParser()
        parser.feed((ROOT / "site/index.html").read_text())
        self.assertEqual(parser.actions, [
            ("download", "https://github.com/johnny4young/portavoz/releases/latest"),
            ("terminal", None),
        ])

    def test_both_languages_state_distributed_release_floor(self):
        html = (ROOT / "site/index.html").read_text()
        self.assertEqual(html.count("macOS Sequoia (15)+ · Apple Silicon"), 2)
        self.assertNotIn("macOS 14.4+ · Apple Silicon", html)
        self.assertIn("Open the DMG and drag Portavoz to Applications.", html)
        self.assertIn("Abre el DMG y arrastra Portavoz a Aplicaciones.", html)

    def test_source_floor_is_not_presented_as_release_qualification(self):
        readme = (ROOT / "README.md").read_text()
        self.assertIn("source-build deployment target is macOS 14.4", readme)
        self.assertIn("does not establish validation of the published app on Sonoma", readme)


if __name__ == "__main__":
    unittest.main()
