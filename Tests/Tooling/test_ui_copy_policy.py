"""User-facing copy stays in the user's vocabulary.

The localization catalog keys are the English source strings. Engineering
vocabulary ("evidence", "receipt", "provenance", "authority", "boundary") and
marketing emphasis ("100%") leaked into the UI during 1.0; this policy keeps
them out, keeps help texts short, and keeps the privacy promise to one phrase.
"""

import json
import re
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Resources/Localization/Portavoz/Localizable.xcstrings"
SOURCES = ROOT / "Sources/portavoz-app"

# Words that describe how Portavoz is built, not what the user does.
FORBIDDEN = (
    r"\bevidence\b",
    r"\breceipts?\b",
    r"\bprovenance\b",
    r"\bauthority\b",
    r"\bboundary\b",
    r"\badmitted\b",
    r"\bhonest\b",
    r"100%",
    r"\bpull-only\b",
    r"\bcited captions\b",
    r"integrity-verified",
    r"\bnothing leaves\b",
    r"\bnever leaves\b",
    r"[Ll]ocal-first",
)
FORBIDDEN_ES = (
    r"\bevidencia",
    r"\brecibos?\b",
    r"\bprocedencia\b",
    r"\bautoridad\b",
    r"100 ?%",
    r"[Ll]ocal primero",
)
# A few strings legitimately name a technical concept the user chose.
ALLOWED_KEYS = {
    "Reminder suggestions are unavailable. Your commitments are unchanged. Reopen Radar to try again.",
}
MAX_HELP_CHARACTERS = 90


def catalog():
    return json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]


class UICopyPolicyTests(unittest.TestCase):
    def test_english_keys_avoid_engineering_vocabulary(self):
        offenders = []
        for key in catalog():
            if key in ALLOWED_KEYS:
                continue
            for pattern in FORBIDDEN:
                if re.search(pattern, key):
                    offenders.append((pattern, key[:80]))
                    break
        self.assertEqual(offenders, [], "rewrite these strings in the user's vocabulary")

    def test_spanish_values_avoid_engineering_vocabulary(self):
        offenders = []
        for key, entry in catalog().items():
            if key in ALLOWED_KEYS:
                continue
            value = entry.get("localizations", {}).get("es", {}).get("stringUnit", {}).get("value", "")
            for pattern in FORBIDDEN_ES:
                if re.search(pattern, value):
                    offenders.append((pattern, value[:80]))
                    break
        self.assertEqual(offenders, [])

    def test_help_texts_stay_short(self):
        pattern = re.compile(r'\.help\(\s*"((?:[^"\\]|\\.)*)"')
        offenders = []
        for path in SOURCES.rglob("*.swift"):
            for match in pattern.finditer(path.read_text(encoding="utf-8")):
                text = match.group(1)
                if len(text) > MAX_HELP_CHARACTERS:
                    offenders.append((path.name, len(text), text[:60]))
        self.assertEqual(offenders, [], f"tooltips stay at or under {MAX_HELP_CHARACTERS} characters")

    def test_one_privacy_promise_phrase(self):
        keys = catalog()
        self.assertIn("On your Mac", keys)
        legacy = [k for k in keys if "transfers require opt-in" in k or "Nothing auto-uploads" in k]
        self.assertEqual(legacy, [], "the sidebar chip is the single privacy promise")


if __name__ == "__main__":
    unittest.main()
