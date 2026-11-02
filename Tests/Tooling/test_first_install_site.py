"""Keep the first installation choice explicit and release-scoped."""
import os
import re
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
        self.assertEqual(html.count("macOS Tahoe (26)+ · Apple Silicon"), 2)
        self.assertNotIn("macOS Sequoia (15)+", html)
        self.assertNotIn("macOS 14.4+ · Apple Silicon", html)
        self.assertIn("Open the DMG and drag Portavoz to Applications.", html)
        self.assertIn("Abre el DMG y arrastra Portavoz a Aplicaciones.", html)

    def test_each_language_links_older_macos_to_the_last_release_that_runs_there(self):
        html = (ROOT / "site/index.html").read_text()
        platform = re.search(r'<p class="platform">(.*?)</p>', html, re.S).group(1)
        dmg = "https://github.com/johnny4young/portavoz/releases/download/v1.2.0/Portavoz-1.2.0.dmg"
        for language in ("es", "en"):
            span = re.search(rf'<span class="{language}">(.*?)</span>', platform, re.S).group(1)
            self.assertIn(f'<a href="{dmg}">', span, language)
            self.assertIn("macOS 14.4–15", span, language)

    def test_release_kicker_names_the_latest_changelog_release(self):
        html = (ROOT / "site/index.html").read_text()
        kicker = re.search(r'class="release-kicker".*?</a>', html, re.S).group(0)
        latest = re.search(r"^## (\d+\.\d+\.\d+) ", (ROOT / "CHANGELOG.md").read_text(), re.M).group(1)
        self.assertEqual(re.findall(r"Portavoz (\d+\.\d+\.\d+)", kicker), [latest, latest])

    def test_readme_states_the_macos_26_floor(self):
        readme = (ROOT / "README.md").read_text()
        self.assertIn("Releases after 1.2.0 require macOS 26 Tahoe", readme)
        self.assertIn("Swift 6.3 on macOS 26+", readme)
        self.assertNotIn("macOS 14.4+**", readme)


if __name__ == "__main__":
    unittest.main()
