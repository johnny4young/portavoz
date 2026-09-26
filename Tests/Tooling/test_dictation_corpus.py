"""Public fixture and real-file admission tests; no TTS, ASR or user audio."""

import copy
import hashlib
import json
import os
import random
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unicodedata
import unittest
import wave

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import dictation_corpus as corpus  # noqa: E402


class DictationCorpusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document, cls.cells = corpus.read_public_corpus()
        cls.directory = tempfile.TemporaryDirectory(prefix="portavoz-dictation-pcm-")
        cls.audio_root = Path(cls.directory.name)
        cls.voices = {split: {language: hashlib.sha256(f'{split}-{language}'.encode()).hexdigest()
                             for language in ("en", "es")} for split in ("tuning", "holdout")}
        entries = []
        for index, (case_id, (family, _)) in enumerate(cls.cells.items()):
            path = cls.audio_root / (case_id + ".wav")
            frames = index + 1
            # These synthetic WAVs test parser/digest contracts, not speech.
            with wave.open(str(path), "wb") as audio:
                audio.setparams((1, 2, 16_000, frames, "NONE", "not compressed"))
                audio.writeframes(struct.pack("<h", 17) * frames)
            entries.append(dict(caseID=case_id, audioSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),
                                frames=frames, sampleRate=16_000, channels=1, sampleWidth=2,
                                voiceSHA256=sorted({cls.voices[family["split"]][segment["language"]]
                                                    for segment in family["segments"]})))
        cls.manifest = dict(schemaVersion=1, kind="dictation-audio-manifest", corpusSHA256=corpus.CORPUS_SHA256,
                            recipeSHA256="a" * 64, voices=cls.voices, entries=entries)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_public_cli_reports_cells_separately_from_families_without_quality_claims(self):
        result = self.run_cli("verify-public")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["cellCounts"], {"en": 160, "es": 160, "mixed": 80, "adversarial": 80})
        self.assertEqual(sum(report["familyCounts"].values()), 60)
        self.assertEqual(report["phraseGroupCount"], 37)
        for name in ("audioChecked", "qualityMeasured", "verifiedDeliveryMeasured"):
            self.assertIs(report[name], False)
        self.assertNotIn("authorize the payment", result.stdout)

    def test_corpus_has_bilingual_boundary_shapes_not_only_clean_average_cases(self):
        shapes = {family["shape"] for family in self.document["families"]}
        self.assertTrue({"negation", "numbers", "unicode", "code", "code-switching", "non-speech", "minimal", "hostile"}
                        <= shapes)
        text = json.dumps(self.document, ensure_ascii=False)
        for required in ("Don’t", "O’Connor", "papá", "0,05", "0,5", "Task.checkCancellation", "example.com"):
            self.assertIn(required, text)

    def test_every_declared_pcm_is_read_and_bound_to_the_manifest(self):
        manifest_path = self.audio_root / "manifest.json"
        manifest_path.write_text(json.dumps(self.manifest))
        result = self.run_cli("validate-audio", "--manifest", str(manifest_path), "--audio-root", str(self.audio_root))
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["audioCellCount"], 480)
        self.assertEqual(report["distinctAudioCount"], 480)
        self.assertEqual(report["syntheticVoiceCount"], 4)
        self.assertTrue(report["audioChecked"])
        self.assertFalse(report["qualityMeasured"], "parser fixtures cannot be presented as model results")
        self.assertFalse(report["verifiedDeliveryMeasured"])

    def test_malformed_field_types_fail_closed_through_the_cli_without_tracebacks(self):
        mutations = [
            ("cohort", []), ("split", {}), ("audioKind", []),
            ("segments", [{"language": [], "text": "PRIVATE-SENTINEL"}]),
            ("segments", [{"language": "en", "text": "\ud800PRIVATE-SENTINEL"}]),
        ]
        for key, value in mutations:
            with self.subTest(key=key, value=type(value).__name__):
                document = copy.deepcopy(self.document)
                document["families"][0][key] = value
                result = self.run_document(document)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn("Traceback", result.stderr)
                self.assertNotIn("PRIVATE-SENTINEL", result.stderr + result.stdout)

    def test_canonical_digest_rejects_relabelled_private_or_edited_corpus(self):
        document = copy.deepcopy(self.document)
        family = document["families"][0]
        family["segments"][0]["text"] = "PRIVATE-SENTINEL"
        family["acceptedTexts"] = ["PRIVATE-SENTINEL"]
        result = self.run_document(document)
        self.assertEqual(result.returncode, 2)
        self.assertIn("not the reviewed public generation", result.stderr)
        self.assertNotIn("PRIVATE-SENTINEL", result.stderr + result.stdout)

    def test_duplicate_keys_nonfinite_numbers_and_oversize_json_are_rejected(self):
        for data in (b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":Infinity}', b'{"x":-Infinity}',
                     b'"' + b'x' * corpus.MAX_JSON_BYTES + b'"', b'\xff'):
            with tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "bad.json"
                path.write_bytes(data)
                with self.assertRaises(corpus.CorpusError):
                    corpus.read_json(path)

    def test_larger_observation_budget_is_explicit_and_does_not_weaken_default_source_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "observation.json"
            path.write_bytes(b'"' + b'x' * corpus.MAX_JSON_BYTES + b'"')
            with self.assertRaises(corpus.CorpusError):
                corpus.read_json(path)
            value, _ = corpus.read_json(path, maximum_bytes=3_000_000)
            self.assertEqual(len(value), corpus.MAX_JSON_BYTES)
            for bound in (0, -1, True, 8_000_001, "8000000"):
                with self.assertRaises(corpus.CorpusError):
                    corpus.read_json(path, maximum_bytes=bound)

    def test_family_and_profile_inventory_rejects_duplicates_and_missing_cohorts(self):
        for field in ("families", "profiles"):
            document = copy.deepcopy(self.document)
            document[field][-1] = copy.deepcopy(document[field][0])
            with self.assertRaises(corpus.CorpusError):
                corpus.validate_corpus(document)
        document = copy.deepcopy(self.document)
        document["profiles"][1] = {**document["profiles"][0], "id": "duplicate-audio-shape"}
        with self.assertRaises(corpus.CorpusError):
            corpus.validate_corpus(document)

    def test_phrase_groups_and_unicode_equivalent_references_cannot_cross_holdout(self):
        document = copy.deepcopy(self.document)
        document["families"][1]["split"] = "holdout"
        with self.assertRaisesRegex(corpus.CorpusError, "related phrase"):
            corpus.validate_corpus(document)
        document = copy.deepcopy(self.document)
        first, second = document["families"][0], document["families"][30]
        first["segments"][0]["text"] = "Café de reunión"
        first["acceptedTexts"] = ["Café de reunión"]
        second["segments"][0]["text"] = unicodedata.normalize("NFD", "CAFÉ DE REUNIÓN")
        second["acceptedTexts"] = [second["segments"][0]["text"]]
        with self.assertRaisesRegex(corpus.CorpusError, "reference leaks"):
            corpus.validate_corpus(document)

    def test_noise_cannot_invent_ground_truth_and_mixed_needs_both_languages(self):
        for predicate, mutation in [
            (lambda family: family["audioKind"] == "silence", lambda family: family.update(acceptedTexts=["hello"])),
            (lambda family: family["cohort"] == "mixed", lambda family: family["segments"][1].update(language="en")),
        ]:
            document = copy.deepcopy(self.document)
            mutation(next(family for family in document["families"] if predicate(family)))
            with self.assertRaises(corpus.CorpusError):
                corpus.validate_corpus(document)

    def test_synthetic_voice_and_case_attribution_cannot_leak_across_splits(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["voices"]["holdout"]["es"] = manifest["voices"]["tuning"]["en"]
        self.reject_manifest(manifest)
        manifest = copy.deepcopy(self.manifest)
        manifest["entries"][0]["voiceSHA256"] = []
        self.reject_manifest(manifest)

    def test_manifest_is_exact_not_an_accepted_subset_or_a_payload_container(self):
        for mutation in (
            lambda m: m["entries"].pop(),
            lambda m: m["entries"].__setitem__(-1, copy.deepcopy(m["entries"][0])),
            lambda m: m["entries"][0].update(caseID="../../private"),
            lambda m: m["entries"][0].update(recognizedText="PRIVATE-SENTINEL"),
            lambda m: m.update(schemaVersion=True),
            lambda m: m.update(corpusSHA256="0" * 64),
        ):
            manifest = copy.deepcopy(self.manifest)
            mutation(manifest)
            self.reject_manifest(manifest)

    def test_pcm_numeric_types_and_bounds_are_not_coerced(self):
        for key, value in (("frames", True), ("frames", 0), ("frames", 1_920_001), ("frames", 1.5),
                           ("sampleRate", 16_000.0), ("channels", True), ("sampleWidth", "2")):
            manifest = copy.deepcopy(self.manifest)
            manifest["entries"][0][key] = value
            self.reject_manifest(manifest)

    def test_unrelated_phrase_families_cannot_reuse_audio_with_new_names(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["entries"][8]["audioSHA256"] = manifest["entries"][0]["audioSHA256"]
        self.reject_manifest(manifest)

    def test_truncated_audio_is_rejected_even_with_a_matching_hash(self):
        expected = copy.deepcopy(self.manifest["entries"][0])
        data = (self.audio_root / (expected["caseID"] + ".wav")).read_bytes()[:-2]
        expected["audioSHA256"] = hashlib.sha256(data).hexdigest()
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "truncated.wav"
            path.write_bytes(data)
            with self.assertRaisesRegex(corpus.CorpusError, "truncated PCM payload"):
                corpus.inspect_audio(path, expected)

    def test_wrong_audio_hash_symlinks_and_fifos_fail_without_following_or_waiting(self):
        expected = self.manifest["entries"][0]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target.wav"
            target.write_bytes(b"synthetic sentinel" * 8)
            link = root / "link.wav"
            link.symlink_to(target)
            fifo = root / "pipe.wav"
            os.mkfifo(fifo)
            for path in (target, link, fifo):
                with self.assertRaises(corpus.CorpusError):
                    corpus.inspect_audio(path, expected)

    def test_corrupt_riff_chunk_fails_at_the_cli_instead_of_escaping_as_runtime_error(self):
        manifest = copy.deepcopy(self.manifest)
        expected = manifest["entries"][0]
        path = self.audio_root / (expected["caseID"] + ".wav")
        original = path.read_bytes()
        malformed = b"RIFF" + struct.pack("<I", 36) + b"WAVEJUNK" + struct.pack("<I", 100) + b"x" * 80
        expected["audioSHA256"] = hashlib.sha256(malformed).hexdigest()
        manifest_path = self.audio_root / "corrupt-manifest.json"
        manifest_path.write_text(json.dumps(manifest))
        try:
            path.write_bytes(malformed)
            result = self.run_cli("validate-audio", "--manifest", str(manifest_path),
                                  "--audio-root", str(self.audio_root))
            self.assertEqual(result.returncode, 2)
            self.assertNotIn("Traceback", result.stderr)
        finally:
            path.write_bytes(original)

    def test_malformed_riff_lengths_are_bounded_format_failures(self):
        randomizer = random.Random(7)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "bad.wav"
            for _ in range(160):
                data = b"RIFF" + struct.pack("<I", randomizer.choice([0, 4, 12, 36, 100, 0xffffffff])) + b"WAVE"
                data += randomizer.choice([b"fmt ", b"data", b"JUNK"])
                data += struct.pack("<I", randomizer.choice([0, 2, 8, 16, 24, 100, 0xffffffff]))
                data += randomizer.randbytes(80)
                path.write_bytes(data)
                with self.assertRaises(corpus.CorpusError):
                    corpus.inspect_audio(path, dict(audioSHA256=hashlib.sha256(data).hexdigest(), frames=1))

    def test_cli_missing_audio_root_fails_without_printing_the_path(self):
        path = self.audio_root / "manifest.json"
        path.write_text(json.dumps(self.manifest))
        result = self.run_cli("validate-audio", "--manifest", str(path), "--audio-root", "/PRIVATE-SENTINEL/not-present")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("PRIVATE-SENTINEL", result.stderr + result.stdout)

    def reject_manifest(self, manifest):
        with self.assertRaises(corpus.CorpusError):
            corpus.validate_audio_manifest(manifest, self.cells, self.audio_root)

    def run_document(self, document):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "corpus.json"
            path.write_text(json.dumps(document))
            return self.run_cli("verify-public", "--corpus", str(path))

    def run_cli(self, *arguments):
        return subprocess.run([sys.executable, str(ROOT / "scripts/dictation_corpus.py"), *arguments],
                              capture_output=True, text=True, timeout=8, check=False)


if __name__ == "__main__":
    unittest.main()
