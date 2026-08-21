import copy
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "retrieval_chunk_resource_fixture",
    ROOT / "scripts" / "retrieval_chunk_resource_fixture.py",
)
fixture_tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture_tool)


class RetrievalChunkResourceFixtureTests(unittest.TestCase):
    def test_tracked_fixture_is_canonical_and_bilingually_homogeneous(self):
        path = (
            ROOT
            / "Fixtures"
            / "RetrievalChunkResource"
            / "public-bilingual-homogeneous-v1.json"
        )

        document = fixture_tool.load_json(path)
        coverage = fixture_tool.validate_fixture(document)
        digest = fixture_tool.verify_public_fixture(path)

        self.assertEqual(document, fixture_tool.public_fixture())
        self.assertEqual(
            coverage,
            {
                "meetingCount": 60,
                "sourceSegmentCount": 480,
                "homogeneousEnglishTurnCount": 120,
                "homogeneousSpanishTurnCount": 120,
            },
        )
        self.assertEqual(digest, hashlib.sha256(path.read_bytes()).hexdigest())

    def test_verifier_cli_prints_digest_of_the_validated_snapshot(self):
        path = (
            ROOT
            / "Fixtures"
            / "RetrievalChunkResource"
            / "public-bilingual-homogeneous-v1.json"
        )

        with mock.patch("builtins.print") as print_mock:
            result = fixture_tool.main_from_args([
                "verify-public",
                "--fixture",
                str(path),
                "--print-sha256",
            ])

        self.assertEqual(result, 0)
        print_mock.assert_called_once_with(
            hashlib.sha256(path.read_bytes()).hexdigest()
        )

    def test_rejects_mixed_language_complete_turn_and_unexpected_fields(self):
        mixed = copy.deepcopy(fixture_tool.public_fixture())
        mixed["segments"][1]["language"] = "es"

        with self.assertRaisesRegex(
            fixture_tool.RetrievalChunkResourceFixtureError,
            "mixed-language complete turn",
        ):
            fixture_tool.validate_fixture(mixed)

        unexpected = copy.deepcopy(fixture_tool.public_fixture())
        unexpected["queries"] = []
        with self.assertRaisesRegex(
            fixture_tool.RetrievalChunkResourceFixtureError,
            "invalid shape",
        ):
            fixture_tool.validate_fixture(unexpected)

    def test_loader_rejects_duplicate_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text(
                '{"schemaVersion":1,"schemaVersion":1}\n',
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                fixture_tool.RetrievalChunkResourceFixtureError,
                "duplicate key: schemaVersion",
            ):
                fixture_tool.load_json(path)

    def test_loader_reads_at_most_one_byte_past_the_size_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "oversized.json"
            path.write_bytes(b" " * (fixture_tool.MAXIMUM_BYTES + 1))

            with self.assertRaisesRegex(
                fixture_tool.RetrievalChunkResourceFixtureError,
                "exceeds 8 MiB",
            ):
                fixture_tool.load_json(path)

    def test_public_generation_is_non_overwriting(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            fixture_tool.write_public_fixture(path)
            original = path.read_bytes()

            with self.assertRaisesRegex(
                fixture_tool.RetrievalChunkResourceFixtureError,
                "already exists",
            ):
                fixture_tool.write_public_fixture(path)

            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(
                json.loads(original),
                fixture_tool.public_fixture(),
            )


if __name__ == "__main__":
    unittest.main()
