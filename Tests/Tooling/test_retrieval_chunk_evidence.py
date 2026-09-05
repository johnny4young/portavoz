import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from hashlib import sha256
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "retrieval_chunk_evidence", ROOT / "scripts" / "retrieval_chunk_evidence.py"
)
evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evidence)


class FakeRunner:
    def __init__(
        self,
        *,
        dirty=False,
        drift_role=None,
        host_drift_role=None,
        semantic_vector_count=240,
        dirty_status_call=None,
        fixture_digest=None,
    ):
        self.dirty = dirty
        self.drift_role = drift_role
        self.host_drift_role = host_drift_role
        self.semantic_vector_count = semantic_vector_count
        self.dirty_status_call = dirty_status_call
        self.fixture_digest = fixture_digest
        self.calls = []
        self.role_calls = {}
        self.commit = "a" * 40
        self.status_calls = 0

    def __call__(self, command, root):
        self.calls.append(command)
        if command[:2] == ["git", "status"]:
            self.status_calls += 1
            dirty = self.dirty or self.status_calls == self.dirty_status_call
            return self.result(0, " M dirty.swift\n" if dirty else "")
        if command[:3] == ["git", "rev-parse", "HEAD"]:
            return self.result(0, self.commit + "\n")
        if command[:3] == ["git", "check-ignore", "--quiet"]:
            return self.result(0)
        if (
            len(command) > 2
            and command[1].endswith("retrieval_chunk_resource_fixture.py")
        ):
            digest = self.fixture_digest or sha256(
                (root.parent / "fixture.json").read_bytes()
            ).hexdigest()
            return self.result(0, digest + "\n")
        if command[:3] == ["xcrun", "swiftc", "--version"]:
            return self.result(0, "Apple Swift version 6.2.3\n")
        if command[:3] == ["swift", "build", "-c"]:
            cli = root / ".build" / "release" / "portavoz-cli"
            cli.parent.mkdir(parents=True, exist_ok=True)
            cli.write_text("fixture", encoding="utf-8")
            return self.result(0)
        if command and command[0].endswith("portavoz-cli"):
            role = command[command.index("--retrieval-unit") + 1]
            output = Path(command[command.index("--output") + 1])
            call = self.role_calls.get(role, 0) + 1
            self.role_calls[role] = call
            document = self.observation(command, role, call)
            output.write_text(json.dumps(document) + "\n", encoding="utf-8")
            return self.result(0)
        return self.result(64, error=f"unexpected command: {command}")

    def observation(self, command, role, call):
        semantic = role == "semantic-boundary"
        units = {
            "segment": 480,
            "speaker-turn": 240,
            "conversation-window": 120,
            "semantic-boundary": 240,
        }[role]
        if role == self.drift_role and call > 1:
            units += 1
        diagnostics = (
            self.diagnostics(240, 180, self.semantic_vector_count)
            if semantic
            else None
        )
        resources = self.resources(call)
        target_units = {
            "segment": 8,
            "speaker-turn": 4,
            "conversation-window": 2,
            "semantic-boundary": 4,
        }[role]
        corrections = []
        for index, scenario in enumerate(evidence.SCENARIOS):
            input_segments = 9 if scenario == "structural-split" else (
                7 if scenario == "structural-merge" else 8
            )
            correction_turns = input_segments if role == "segment" else 4
            correction = {
                "scenario": scenario,
                "inputSegmentCount": input_segments,
                "resultingUnitCount": target_units,
                "sourceReferenceCount": input_segments,
                "turnCount": correction_turns,
                "retainedUnitCount": (
                    target_units if index < 2 else max(0, target_units - 1)
                ),
                "candidateEmbeddingUpsertCount": 0 if index < 2 else 1,
                "removedUnitCount": 0,
                "resources": resources,
            }
            if semantic:
                correction["diagnostics"] = self.diagnostics(4, 3, 4)
            corrections.append(correction)
        adapter = evidence.FIXED_ADAPTERS.get(role, "semantic-v1." + ("d" * 64))
        construction = {
            "resultingUnitCount": units,
            "sourceReferenceCount": 480,
            "turnCount": 480 if role == "segment" else 240,
            "resources": resources,
        }
        if semantic:
            construction["diagnostics"] = diagnostics
        return {
            "schemaVersion": 2,
            "kind": "retrieval-chunk-resource-correction-observation",
            "authority": "research-resource-correction-only",
            "contentPolicy": "content-free",
            "lifecycle": "warm-candidate-construction-and-one-meeting-rebuild-only",
            "assetDownloadPolicy": "never",
            "productComposition": "unchanged",
            "candidateSelection": "not-evaluated",
            "performanceDecision": "not-evaluated",
            "subject": {
                "build": command[command.index("--build") + 1],
                "sourceCommit": command[command.index("--commit") + 1],
                "fixtureGeneration": "public-bilingual-homogeneous-v1",
                "fixtureSHA256": command[command.index("--fixture-sha256") + 1],
                "toolchainSHA256": command[command.index("--toolchain-sha256") + 1],
                "hostProfile": command[command.index("--host-profile") + 1],
                "retrievalUnit": role,
                "adapter": adapter,
            },
            "host": {
                "operatingSystem": "macOS 26.5.2",
                "architecture": "arm64",
                "processorCount": 17 if role == self.host_drift_role else 16,
                "physicalMemoryBytes": 36_000_000_000,
                "evidenceScope": "single-development-host",
            },
            "preparation": {
                "scope": "outside-resource-samples",
                "semanticProposalAdmissionCount": 1 if semantic else 0,
                "englishVectorWarmupCount": 1 if semantic else 0,
                "spanishVectorWarmupCount": 1 if semantic else 0,
            },
            "corpus": {
                "contentSource": "public-synthetic-only",
                "userLibraryAccess": "none",
                "meetingCount": 60,
                "sourceSegmentCount": 480,
                "homogeneousEnglishTurnCount": 120,
                "homogeneousSpanishTurnCount": 120,
            },
            "construction": construction,
            "corrections": corrections,
        }

    @staticmethod
    def diagnostics(turn_count, boundary_count, vectorized_turn_count):
        return {
            "turnCount": turn_count,
            "vectorizedTurnCount": vectorized_turn_count,
            "joinedBoundaryCount": 0,
            "languageTransitionBoundaryCount": 0,
            "unavailableLanguageBoundaryCount": 0,
            "resourceBoundaryCount": 0,
            "similarityBoundaryCount": boundary_count,
        }

    @staticmethod
    def resources(call):
        return {
            "wallMilliseconds": 1.0 + call,
            "processCPUMilliseconds": 0.5 + call,
            "baselinePhysicalFootprintBytes": 100,
            "peakPhysicalFootprintBytes": 120 + call,
            "incrementalPeakPhysicalFootprintBytes": 20 + call,
            "endingPhysicalFootprintBytes": 110,
        }

    @staticmethod
    def result(code, output="", error=""):
        return subprocess.CompletedProcess([], code, output, error)


class RetrievalChunkEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        base = Path(self.temporary.name)
        self.root = base / "repository"
        self.root.mkdir()
        scripts = self.root / "scripts"
        scripts.mkdir()
        (scripts / "retrieval_chunk_resource_fixture.py").write_text(
            "fixture", encoding="utf-8"
        )
        self.fixture = base / "fixture.json"
        self.fixture.write_text("{}\n", encoding="utf-8")
        self.output = base / "private-evidence"

    def tearDown(self):
        self.temporary.cleanup()

    def test_collects_rotated_owner_only_matrix_with_full_bilingual_coverage(self):
        runner = FakeRunner()

        receipt_path = evidence.collect_evidence(
            self.root,
            self.fixture,
            self.output,
            "search4b+d354",
            "reference",
            runner=runner,
        )

        self.output = self.output.resolve()
        self.assertEqual(receipt_path, self.output / "receipt.json")
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)
        self.assertEqual(len(list(self.output.iterdir())), 13)
        self.assertTrue(all(
            path.stat().st_mode & 0o777 == 0o600
            for path in self.output.iterdir()
        ))
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        self.assertEqual(receipt["schemaVersion"], 2)
        self.assertEqual(receipt["outcome"], "review-required")
        self.assertEqual(receipt["blockingReasons"], [])
        self.assertEqual(
            receipt["fixtureGeneration"], "public-bilingual-homogeneous-v1"
        )
        self.assertEqual(
            receipt["corpusCoverage"]["homogeneousEnglishTurnCount"], 120
        )
        self.assertEqual(
            receipt["corpusCoverage"]["homogeneousSpanishTurnCount"], 120
        )
        self.assertEqual(receipt["candidateSelection"], "not-evaluated")
        cli_calls = [
            call for call in runner.calls if call[0].endswith("portavoz-cli")
        ]
        self.assertEqual(len(cli_calls), 12)
        self.assertEqual(
            [call[call.index("--retrieval-unit") + 1] for call in cli_calls],
            [
                "segment", "speaker-turn", "conversation-window", "semantic-boundary",
                "speaker-turn", "conversation-window", "semantic-boundary", "segment",
                "conversation-window", "semantic-boundary", "segment", "speaker-turn",
            ],
        )

    def test_rejects_dirty_source_before_build(self):
        runner = FakeRunner(dirty=True)

        with self.assertRaisesRegex(
            evidence.RetrievalChunkEvidenceError, "worktree must be clean"
        ):
            evidence.collect_evidence(
                self.root,
                self.fixture,
                self.output,
                "search4b+d354",
                "reference",
                runner=runner,
            )

        self.assertFalse(self.output.exists())
        self.assertFalse(any(call[:1] == ["swift"] for call in runner.calls))

    def test_binds_observations_to_digest_returned_by_fixture_verifier(self):
        verified_digest = "f" * 64
        runner = FakeRunner(fixture_digest=verified_digest)

        receipt_path = evidence.collect_evidence(
            self.root,
            self.fixture,
            self.output,
            "search4b+d354",
            "reference",
            runner=runner,
        )

        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        self.assertEqual(receipt["fixtureSHA256"], verified_digest)
        self.assertTrue(all(
            call[call.index("--fixture-sha256") + 1] == verified_digest
            for call in runner.calls
            if call and call[0].endswith("portavoz-cli")
        ))

    def test_rejects_source_drift_after_build_and_before_publication(self):
        for dirty_status_call in (2, 3):
            with self.subTest(dirty_status_call=dirty_status_call):
                output = self.output.with_name(
                    f"{self.output.name}-{dirty_status_call}"
                )
                runner = FakeRunner(dirty_status_call=dirty_status_call)
                with self.assertRaisesRegex(
                    evidence.RetrievalChunkEvidenceError,
                    "worktree must be clean",
                ):
                    evidence.collect_evidence(
                        self.root,
                        self.fixture,
                        output,
                        "search4b+d354",
                        "reference",
                        runner=runner,
                    )
                self.assertFalse(output.exists())

    def test_complete_matrix_blocks_incomplete_semantic_vector_coverage(self):
        runner = FakeRunner(semantic_vector_count=239)

        receipt_path = evidence.collect_evidence(
            self.root,
            self.fixture,
            self.output,
            "search4b+d354",
            "reference",
            runner=runner,
        )

        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        self.assertEqual(receipt["outcome"], "blocked")
        self.assertEqual(
            receipt["blockingReasons"],
            ["public-fixture-semantic-vector-coverage-incomplete"],
        )

    def test_removes_staging_when_structural_observations_drift(self):
        runner = FakeRunner(drift_role="conversation-window")

        with self.assertRaisesRegex(
            evidence.RetrievalChunkEvidenceError, "structural observations drifted"
        ):
            evidence.collect_evidence(
                self.root,
                self.fixture,
                self.output,
                "search4b+d354",
                "reference",
                runner=runner,
            )

        self.assertFalse(self.output.exists())
        self.assertFalse(any(
            path.name.startswith(f".{self.output.name}.partial.")
            for path in self.output.parent.iterdir()
        ))

    def test_rejects_host_identity_drift_across_roles(self):
        runner = FakeRunner(host_drift_role="speaker-turn")

        with self.assertRaisesRegex(
            evidence.RetrievalChunkEvidenceError,
            "host identity drifted across retrieval roles",
        ):
            evidence.collect_evidence(
                self.root,
                self.fixture,
                self.output,
                "search4b+d354",
                "reference",
                runner=runner,
            )

        self.assertFalse(self.output.exists())

    def test_rejects_payload_keys(self):
        runner = FakeRunner()
        document = runner.observation(
            [
                "portavoz-cli", "--build", "test", "--commit", "a" * 40,
                "--fixture-sha256", "b" * 64,
                "--toolchain-sha256", "c" * 64,
                "--host-profile", "reference",
            ],
            "segment",
            1,
        )
        document["text"] = "private"

        with self.assertRaisesRegex(
            evidence.RetrievalChunkEvidenceError, "invalid shape"
        ):
            evidence.validate_observation(
                document,
                role="segment",
                build="test",
                commit="a" * 40,
                fixture_sha256="b" * 64,
                toolchain_sha256="c" * 64,
                host_profile="reference",
            )

    def test_nonsemantic_shape_matches_swift_optional_encoding(self):
        runner = FakeRunner()
        command = [
            "portavoz-cli", "--build", "test", "--commit", "a" * 40,
            "--fixture-sha256", "b" * 64,
            "--toolchain-sha256", "c" * 64,
            "--host-profile", "reference",
        ]
        document = runner.observation(command, "segment", 1)

        self.assertNotIn("diagnostics", document["construction"])
        self.assertTrue(all(
            "diagnostics" not in correction
            for correction in document["corrections"]
        ))
        validated = evidence.validate_observation(
            document,
            role="segment",
            build="test",
            commit="a" * 40,
            fixture_sha256="b" * 64,
            toolchain_sha256="c" * 64,
            host_profile="reference",
        )
        self.assertEqual(validated["subject"]["retrievalUnit"], "segment")

        document["construction"]["diagnostics"] = None
        with self.assertRaisesRegex(
            evidence.RetrievalChunkEvidenceError, "invalid shape"
        ):
            evidence.validate_observation(
                document,
                role="segment",
                build="test",
                commit="a" * 40,
                fixture_sha256="b" * 64,
                toolchain_sha256="c" * 64,
                host_profile="reference",
            )

    def test_rejects_forged_fixture_generation_and_semantic_preparation(self):
        runner = FakeRunner()
        command = [
            "portavoz-cli", "--build", "test", "--commit", "a" * 40,
            "--fixture-sha256", "b" * 64,
            "--toolchain-sha256", "c" * 64,
            "--host-profile", "reference",
        ]
        document = runner.observation(command, "semantic-boundary", 1)
        document["subject"]["fixtureGeneration"] = "public-synthetic-v2"
        with self.assertRaisesRegex(
            evidence.RetrievalChunkEvidenceError,
            "fixtureGeneration mismatch",
        ):
            evidence.validate_observation(
                document,
                role="semantic-boundary",
                build="test",
                commit="a" * 40,
                fixture_sha256="b" * 64,
                toolchain_sha256="c" * 64,
                host_profile="reference",
            )

        document = runner.observation(command, "semantic-boundary", 1)
        document["preparation"]["spanishVectorWarmupCount"] = 0
        with self.assertRaisesRegex(
            evidence.RetrievalChunkEvidenceError,
            "preparation does not match",
        ):
            evidence.validate_observation(
                document,
                role="semantic-boundary",
                build="test",
                commit="a" * 40,
                fixture_sha256="b" * 64,
                toolchain_sha256="c" * 64,
                host_profile="reference",
            )

    def test_observation_loader_rejects_duplicate_keys(self):
        path = Path(self.temporary.name) / "duplicate-observation.json"
        path.write_text(
            '{"schemaVersion":2,"schemaVersion":2}\n',
            encoding="utf-8",
        )

        with self.assertRaisesRegex(
            evidence.RetrievalChunkEvidenceError,
            "duplicate key: schemaVersion",
        ):
            evidence.load_json_file(path, "test observation")

    def test_rejects_host_profile_and_equivalent_correction_forgery(self):
        runner = FakeRunner()
        command = [
            "portavoz-cli", "--build", "test", "--commit", "a" * 40,
            "--fixture-sha256", "b" * 64,
            "--toolchain-sha256", "c" * 64,
            "--host-profile", "reference",
        ]
        document = runner.observation(command, "segment", 1)
        document["host"]["physicalMemoryBytes"] = 8 * evidence.GIBIBYTE

        with self.assertRaisesRegex(
            evidence.RetrievalChunkEvidenceError,
            "physical memory does not match host profile",
        ):
            evidence.validate_observation(
                document,
                role="segment",
                build="test",
                commit="a" * 40,
                fixture_sha256="b" * 64,
                toolchain_sha256="c" * 64,
                host_profile="reference",
            )

        document = runner.observation(command, "segment", 1)
        equivalent = document["corrections"][1]
        equivalent["retainedUnitCount"] -= 1
        equivalent["candidateEmbeddingUpsertCount"] = 1
        with self.assertRaisesRegex(
            evidence.RetrievalChunkEvidenceError,
            "rebuilt equivalent units",
        ):
            evidence.validate_observation(
                document,
                role="segment",
                build="test",
                commit="a" * 40,
                fixture_sha256="b" * 64,
                toolchain_sha256="c" * 64,
                host_profile="reference",
            )


if __name__ == "__main__":
    unittest.main()
