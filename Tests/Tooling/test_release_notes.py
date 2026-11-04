"""Rendering one release's changelog section for the appcast."""

import importlib.util
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_notes", ROOT / "scripts/release_notes.py")
notes = importlib.util.module_from_spec(SPEC)
sys.modules["release_notes"] = notes
SPEC.loader.exec_module(notes)

CHANGELOG = """# What's new

## 1.4.0 — November 9, 2026

**One dictation app at a time.**

- **🤝 Ownership** — only one app dictates, with `Use Portavoz` to come back
- Fixes <angle> & ampersands

## 1.3.0 — October 31, 2026

- Older entry

## November 4, 2026

- Ledger entry
"""


class ReleaseNotesTests(unittest.TestCase):
    def test_only_the_requested_release_is_rendered(self):
        rendered = notes.render(CHANGELOG, "1.3.0")

        self.assertEqual(rendered, "<ul>\n<li>Older entry</li>\n</ul>\n")

    def test_the_section_ends_at_a_dated_ledger_heading(self):
        changelog = "## 1.0.0 — May 2, 2026\n\n- Mine\n\n## May 1, 2026\n\n- Ledger\n"

        self.assertNotIn("Ledger", notes.render(changelog, "1.0.0"))

    def test_markup_becomes_html_and_text_is_escaped(self):
        rendered = notes.render(CHANGELOG, "1.4.0")

        self.assertIn("<p><strong>One dictation app at a time.</strong></p>", rendered)
        self.assertIn("<li><strong>🤝 Ownership</strong> — only one app dictates, with <code>Use Portavoz</code>", rendered)
        self.assertIn("Fixes &lt;angle&gt; &amp; ampersands", rendered)

    def test_the_fragment_stays_embeddable(self):
        rendered = notes.render(CHANGELOG, "1.4.0")

        self.assertNotIn("<!DOCTYPE", rendered)
        self.assertNotIn("<body", rendered)

    def test_a_missing_or_empty_release_is_refused(self):
        with self.assertRaisesRegex(notes.ReleaseNotesError, "no section for 9.9.9"):
            notes.render(CHANGELOG, "9.9.9")
        with self.assertRaisesRegex(notes.ReleaseNotesError, "empty section for 1.0.0"):
            notes.render("## 1.0.0 — May 2, 2026\n\n## 0.9.0 — May 1, 2026\n\n- x\n", "1.0.0")

    def test_a_version_never_matches_a_longer_one_or_a_dot_wildcard(self):
        with self.assertRaises(notes.ReleaseNotesError):
            notes.render("## 1x4x0 — May 2, 2026\n\n- x\n", "1.4.0")


if __name__ == "__main__":
    unittest.main()
