import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "scripts" / "generate-live-question-training.py"
CORPUS = ROOT / "Fixtures" / "LiveQuestionDetector" / (
    "training-public-synthetic-v1.json"
)
HOLDOUT = ROOT / "Fixtures" / "LiveAssistValidation" / (
    "public-bilingual-v1.json"
)
COMPILED_MODEL = ROOT / "Sources" / "IntelligenceKit" / "Resources" / (
    "PortavozLiveQuestionClassifier.mlmodelc"
)


class LiveQuestionTrainingTests(unittest.TestCase):
    def test_generator_reproduces_the_frozen_corpus_byte_for_byte(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "training.json"
            subprocess.run(
                [str(GENERATOR), str(output)],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(output.read_bytes(), CORPUS.read_bytes())

    def test_corpus_is_bilingual_balanced_and_disjoint_from_holdout(self):
        corpus = json.loads(CORPUS.read_text(encoding="utf-8"))
        self.assertEqual(corpus["schemaVersion"], 1)
        self.assertEqual(corpus["contentSource"], "public-synthetic-only")
        self.assertEqual(corpus["license"], "CC0-1.0")
        self.assertEqual(
            {key: len(value) for key, value in corpus["labels"].items()},
            {"abstain": 44, "nonQuestion": 260, "question": 256},
        )
        examples = [item for values in corpus["labels"].values() for item in values]
        self.assertEqual(len(examples), len(set(examples)))
        self.assertTrue(any("¿" in item for item in examples))
        self.assertTrue(any(" the " in f" {item.lower()} " for item in examples))

        validation = json.loads(HOLDOUT.read_text(encoding="utf-8"))
        held_out = {
            event["text"]
            for session in validation["questionSessions"]
            for event in session["events"]
        }
        self.assertTrue(held_out.isdisjoint(examples))

    def test_checked_in_compiled_model_tree_is_pinned(self):
        digest = hashlib.sha256()
        files = sorted(path for path in COMPILED_MODEL.rglob("*") if path.is_file())
        self.assertEqual(
            [path.relative_to(COMPILED_MODEL).as_posix() for path in files],
            [
                "analytics/coremldata.bin",
                "coremldata.bin",
                "metadata.json",
            ],
        )
        for path in files:
            relative = path.relative_to(COMPILED_MODEL).as_posix().encode("utf-8")
            content = path.read_bytes()
            digest.update(len(relative).to_bytes(4, "big"))
            digest.update(relative)
            digest.update(len(content).to_bytes(8, "big"))
            digest.update(content)
        self.assertEqual(
            digest.hexdigest(),
            "24d803830a4993bafabc0545880552572a1bafff108e695ffc968418dbd7d34d",
        )


if __name__ == "__main__":
    unittest.main()
