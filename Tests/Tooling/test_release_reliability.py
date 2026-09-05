import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "release_reliability.py"
SPEC = importlib.util.spec_from_file_location("release_reliability", SCRIPT)
reliability = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(reliability)


class ReleaseReliabilityTests(unittest.TestCase):
    version = "1.0.0"
    build = "202607280001"
    commit = "a" * 40

    def test_complete_evidence_passes_and_preserves_proof_classes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deterministic = self.write_deterministic(root)
            distribution = self.write_distribution(root)
            qualification = self.write_complete_qualification(root)
            field = self.write_complete_field_evidence(root)
            output = root / "scorecard"

            result = reliability.main_from_args(
                self.evaluate_args(
                    deterministic,
                    distribution,
                    field,
                    output,
                    qualification,
                )
            )

            self.assertEqual(result, 0)
            scorecard = json.loads((output / "readiness.json").read_text())
            self.assertEqual(scorecard["outcome"], "pass")
            self.assertEqual(
                {proof["class"] for proof in scorecard["proofs"]},
                {
                    "deterministic-automated",
                    "candidate-automated",
                    "source-integration",
                    "signed-build",
                    "production-sync",
                    "real-hardware",
                    "assistive-technology",
                    "user-field",
                },
            )
            self.assertEqual(scorecard["artifact"]["sha256"], "c" * 64)
            rendered = (output / "readiness.md").read_text()
            self.assertNotIn("meeting-0123456789ab", rendered)
            self.assertEqual(os.stat(output / "readiness.json").st_mode & 0o777, 0o600)

    def test_missing_evidence_blocks_without_becoming_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "scorecard"

            result = reliability.main_from_args(
                [
                    "evaluate",
                    "--version",
                    self.version,
                    "--build",
                    self.build,
                    "--commit",
                    self.commit,
                    "--output",
                    str(output),
                ]
            )

            self.assertEqual(result, 1)
            scorecard = json.loads((output / "readiness.json").read_text())
            self.assertEqual(scorecard["outcome"], "blocked")
            self.assertTrue(
                all(proof["state"] == "missing" for proof in scorecard["proofs"])
            )

    def test_missing_default_receipt_paths_still_produce_a_scorecard(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "scorecard"

            result = reliability.main_from_args(
                self.evaluate_args(
                    root / "missing-deterministic.json",
                    root / "missing-distribution.json",
                    [],
                    output,
                )
            )

            self.assertEqual(result, 1)
            scorecard = json.loads((output / "readiness.json").read_text())
            self.assertEqual(scorecard["outcome"], "blocked")
            self.assertEqual(
                next(
                    proof["state"]
                    for proof in scorecard["proofs"]
                    if proof["id"] == "signed.distribution"
                ),
                "missing",
            )

    def test_failed_field_fixture_remains_release_blocking(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deterministic = self.write_deterministic(root)
            distribution = self.write_distribution(root)
            field = self.write_complete_field_evidence(root)
            manifest = json.loads((field[0] / "manifest.json").read_text())
            manifest["outcome"] = "fail"
            manifest["evidence"][0]["state"] = "fail"
            (field[0] / "manifest.json").write_text(json.dumps(manifest))

            output = root / "scorecard"
            result = reliability.main_from_args(
                self.evaluate_args(deterministic, distribution, field, output)
            )

            self.assertEqual(result, 1)
            scorecard = json.loads((output / "readiness.json").read_text())
            proof = next(
                item
                for item in scorecard["proofs"]
                if item["id"] == "hardware.built-in.sequoia"
            )
            self.assertEqual(proof["state"], "fail")

    def test_mismatched_deterministic_commit_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            deterministic = self.write_deterministic(root, commit="b" * 40)
            output = root / "scorecard"

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "does not match requested release",
            ):
                reliability.evaluate_namespace(
                    self.evaluate_args(
                        deterministic,
                        None,
                        [],
                        output,
                    )
                )

    def test_mismatched_qualification_commit_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            qualification = self.write_qualification(
                root,
                "candidate-automation",
                commit="b" * 40,
            )

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "does not match requested release",
            ):
                reliability.evaluate_namespace(
                    self.evaluate_args(
                        None,
                        None,
                        [],
                        root / "scorecard",
                        [qualification],
                    )
                )

    def test_repeated_qualification_scope_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self.write_qualification(
                root,
                "candidate-automation",
                name="candidate-a",
            )
            second = self.write_qualification(
                root,
                "candidate-automation",
                name="candidate-b",
            )

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "repeat scope: candidate-automation",
            ):
                reliability.evaluate_namespace(
                    self.evaluate_args(
                        None,
                        None,
                        [],
                        root / "scorecard",
                        [first, second],
                    )
                )

    def test_authority_owned_qualification_requires_its_sibling(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_qualification(root, "production-sync")
            receipt.with_name("authority.json").unlink()

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "qualification receipt 1 authority not found",
            ):
                reliability.evaluate_namespace(
                    self.evaluate_args(
                        None,
                        None,
                        [],
                        root / "scorecard",
                        [receipt],
                    )
                )

    def test_assistive_qualification_requires_its_exact_authority_sibling(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_qualification(root, "assistive-technology")
            receipt.with_name("authority.json").unlink()

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "qualification receipt 1 authority not found",
            ):
                reliability.evaluate_namespace(
                    self.evaluate_args(
                        None,
                        None,
                        [],
                        root / "scorecard",
                        [receipt],
                    )
                )

    def test_authority_owned_qualification_rejects_sibling_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_qualification(root, "source-integration")
            authority_path = receipt.with_name("authority.json")
            authority = json.loads(authority_path.read_text())
            authority["unexpected"] = "drift"
            authority_path.write_text(json.dumps(authority))

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "authority digest differs",
            ):
                reliability.evaluate_namespace(
                    self.evaluate_args(
                        None,
                        None,
                        [],
                        root / "scorecard",
                        [receipt],
                    )
                )

    def test_authority_owned_qualification_rejects_renamed_or_symlinked_pair(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_qualification(root, "production-sync")
            renamed = receipt.with_name("production-sync.json")
            receipt.rename(renamed)

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "must retain its owner directory and qualification.json name",
            ):
                reliability.evaluate_namespace(
                    self.evaluate_args(
                        None,
                        None,
                        [],
                        root / "renamed-scorecard",
                        [renamed],
                    )
                )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_qualification(root, "source-integration")
            authority = receipt.with_name("authority.json")
            target = root / "moved-authority.json"
            authority.rename(target)
            authority.symlink_to(target)

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "authority must not be a symbolic link",
            ):
                reliability.evaluate_namespace(
                    self.evaluate_args(
                        None,
                        None,
                        [],
                        root / "symlink-scorecard",
                        [receipt],
                    )
                )

    def test_qualification_receipt_rejects_content_bearing_additions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_qualification(root, "candidate-automation")
            document = json.loads(receipt.read_text())
            document["transcript"] = "private"
            receipt.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "forbidden keys: transcript",
            ):
                reliability.evaluate_namespace(
                    self.evaluate_args(
                        None,
                        None,
                        [],
                        root / "scorecard",
                        [receipt],
                    )
                )

    def test_failed_qualification_proof_remains_release_blocking(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_qualification(root, "candidate-automation")
            document = json.loads(receipt.read_text())
            next(
                proof
                for proof in document["proofs"]
                if proof["id"] == "model-gated"
            )["state"] = "fail"
            receipt.write_text(json.dumps(document))
            output = root / "scorecard"

            result = reliability.main_from_args(
                self.evaluate_args(None, None, [], output, [receipt])
            )

            self.assertEqual(result, 1)
            scorecard = json.loads((output / "readiness.json").read_text())
            proof = next(
                item
                for item in scorecard["proofs"]
                if item["id"] == "candidate.model-gated"
            )
            self.assertEqual(proof["state"], "fail")

    def test_incomplete_qualification_receipt_is_malformed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt = self.write_qualification(root, "candidate-automation")
            document = json.loads(receipt.read_text())
            document["proofs"].pop()
            receipt.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "is missing proofs: complete-bilingual-ui",
            ):
                reliability.evaluate_namespace(
                    self.evaluate_args(
                        None,
                        None,
                        [],
                        root / "scorecard",
                        [receipt],
                    )
                )

    def test_distribution_receipt_requires_exact_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            distribution = self.write_distribution(root)
            document = json.loads(distribution.read_text())
            del document["release"]["commit"]
            distribution.write_text(json.dumps(document))

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "release.commit is required",
            ):
                reliability.evaluate_namespace(
                    self.evaluate_args(
                        None,
                        distribution,
                        [],
                        root / "scorecard",
                    )
                )

    def test_record_distribution_binds_commit_and_owner_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "distribution.json"

            result = reliability.main_from_args(
                [
                    "record-distribution",
                    "--version",
                    self.version,
                    "--build",
                    self.build,
                    "--commit",
                    self.commit,
                    "--sha256",
                    "c" * 64,
                    "--output",
                    str(output),
                ]
            )

            self.assertEqual(result, 0)
            document = json.loads(output.read_text())
            self.assertEqual(document["release"]["commit"], self.commit)
            self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)

    def test_repeated_fixture_and_platform_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self.write_field(root, "airpods-a", "airpods", 15)
            second = self.write_field(root, "airpods-b", "airpods", 15)

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "repeats fixture/platform",
            ):
                reliability.evaluate_namespace(
                    self.evaluate_args(None, None, [first, second], root / "scorecard")
                )

    def test_field_manifest_rejects_content_bearing_additions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = self.write_field(root, "mixed", "mixed-language", 26)
            manifest = json.loads((evidence / "manifest.json").read_text())
            manifest["meetingTitle"] = "private"
            (evidence / "manifest.json").write_text(json.dumps(manifest))

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "forbidden keys: meetingTitle",
            ):
                reliability.evaluate_namespace(
                    self.evaluate_args(None, None, [evidence], root / "scorecard")
                )

    def test_incomplete_field_fixture_is_release_blocking_not_malformed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            field = self.write_field(root, "long-call", "long-call", 26)
            manifest = json.loads((field / "manifest.json").read_text())
            manifest["outcome"] = "incomplete"
            manifest["evidence"][0]["state"] = "not-observed"
            (field / "manifest.json").write_text(json.dumps(manifest))

            output = root / "scorecard"
            result = reliability.main_from_args(
                self.evaluate_args(None, None, [field], output)
            )

            self.assertEqual(result, 1)
            scorecard = json.loads((output / "readiness.json").read_text())
            proof = next(
                item
                for item in scorecard["proofs"]
                if item["id"] == "hardware.long-call"
            )
            self.assertEqual(proof["state"], "not-observed")

    def test_field_manifest_rejects_nonfinite_elapsed_time(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = self.write_field(root, "long-call", "long-call", 26)
            manifest = json.loads((evidence / "manifest.json").read_text())
            manifest["elapsedSeconds"] = float("nan")
            (evidence / "manifest.json").write_text(json.dumps(manifest))

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "elapsedSeconds must be finite",
            ):
                reliability.evaluate_namespace(
                    self.evaluate_args(None, None, [evidence], root / "scorecard")
                )

    def test_contract_rejects_unknown_receipt_proof(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contract = json.loads(reliability.DEFAULT_CONTRACT.read_text())
            contract["proofs"][0]["source"]["proof"] = "typo"
            contract_path = root / "contract.json"
            contract_path.write_text(json.dumps(contract))
            args = self.evaluate_args(None, None, [], root / "scorecard")
            args += ["--contract", str(contract_path)]

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "references unknown deterministic-receipt proof",
            ):
                reliability.evaluate_namespace(args)

    def test_contract_rejects_qualification_class_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contract = json.loads(reliability.DEFAULT_CONTRACT.read_text())
            proof = next(
                item
                for item in contract["proofs"]
                if item["id"] == "candidate.model-gated"
            )
            proof["class"] = "source-integration"
            contract_path = root / "contract.json"
            contract_path.write_text(json.dumps(contract))
            args = self.evaluate_args(None, None, [], root / "scorecard")
            args += ["--contract", str(contract_path)]

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "candidate-automation requires 'candidate-automated'",
            ):
                reliability.evaluate_namespace(args)

    def test_contract_rejects_a_missing_release_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contract = json.loads(reliability.DEFAULT_CONTRACT.read_text())
            contract["proofs"] = [
                proof
                for proof in contract["proofs"]
                if proof["id"] != "candidate.upgrade-recovery"
            ]
            contract_path = root / "contract.json"
            contract_path.write_text(json.dumps(contract))
            args = self.evaluate_args(None, None, [], root / "scorecard")
            args += ["--contract", str(contract_path)]

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "missing candidate.upgrade-recovery",
            ):
                reliability.evaluate_namespace(args)

    def test_contract_rejects_reused_evidence_authority(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contract = json.loads(reliability.DEFAULT_CONTRACT.read_text())
            proof = next(
                item
                for item in contract["proofs"]
                if item["id"] == "candidate.upgrade-recovery"
            )
            proof["source"]["proof"] = "long-capture"
            contract_path = root / "contract.json"
            contract_path.write_text(json.dumps(contract))
            args = self.evaluate_args(None, None, [], root / "scorecard")
            args += ["--contract", str(contract_path)]

            with self.assertRaisesRegex(
                reliability.ReliabilityError,
                "reuses one evidence authority",
            ):
                reliability.evaluate_namespace(args)

    def evaluate_args(
        self,
        deterministic,
        distribution,
        field,
        output,
        qualification=(),
    ):
        args = [
            "evaluate",
            "--version",
            self.version,
            "--build",
            self.build,
            "--commit",
            self.commit,
            "--output",
            str(output),
        ]
        if deterministic is not None:
            args += ["--deterministic-receipt", str(deterministic)]
        if distribution is not None:
            args += ["--distribution-receipt", str(distribution)]
        for receipt in qualification:
            args += ["--qualification-receipt", str(receipt)]
        for evidence in field:
            args += ["--field-evidence", str(evidence)]
        return args

    def write_deterministic(self, root, commit=None):
        path = root / "deterministic.json"
        payload = {
            "schemaVersion": 1,
            "kind": "deterministic",
            "collectedAt": "2026-07-28T12:00:00Z",
            "release": {
                "version": self.version,
                "build": self.build,
                "commit": commit or self.commit,
            },
            "proofs": [
                {"id": identifier, "state": "pass"}
                for identifier in reliability.DETERMINISTIC_PROOFS
            ],
        }
        path.write_text(json.dumps(payload))
        return path

    def write_distribution(self, root):
        path = root / "distribution.json"
        payload = {
            "schemaVersion": 1,
            "kind": "distribution",
            "collectedAt": "2026-07-28T12:05:00Z",
            "release": {
                "version": self.version,
                "build": self.build,
                "commit": self.commit,
            },
            "artifact": {"sha256": "c" * 64},
            "proofs": [{"id": "distribution", "state": "pass"}],
        }
        path.write_text(json.dumps(payload))
        return path

    def write_complete_qualification(self, root):
        return [
            self.write_qualification(root, scope)
            for scope in reliability.QUALIFICATION_RECEIPTS
        ]

    def write_qualification(self, root, scope, commit=None, name=None):
        release = {
            "version": self.version,
            "build": self.build,
            "commit": commit or self.commit,
        }
        payload = {
            "schemaVersion": 1,
            "kind": "qualification",
            "scope": scope,
            "collectedAt": "2026-07-28T12:07:00Z",
            "release": release,
            "proofs": [
                {"id": identifier, "state": "pass"}
                for identifier in reliability.QUALIFICATION_RECEIPTS[scope]["proofs"]
            ],
        }
        descriptor = reliability.QUALIFICATION_RECEIPTS[scope]
        if "authorityKind" in descriptor:
            evidence = root / (name or scope)
            evidence.mkdir()
            authority = {
                "schemaVersion": 1,
                "kind": descriptor["authorityKind"],
                "collectedAt": payload["collectedAt"],
                "release": release,
            }
            (evidence / "authority.json").write_text(json.dumps(authority))
            payload["authoritySHA256"] = reliability.canonical_document_sha256(
                authority
            )
            path = evidence / "qualification.json"
        else:
            path = root / f"{name or scope}.json"
        path.write_text(json.dumps(payload))
        return path

    def write_complete_field_evidence(self, root):
        return [
            self.write_field(root, "built-in-15", "built-in-speaker-mic", 15),
            self.write_field(root, "built-in-26", "built-in-speaker-mic", 26),
            self.write_field(root, "airpods-15", "airpods", 15),
            self.write_field(root, "airpods-26", "airpods", 26),
            self.write_field(
                root,
                "callback",
                "source-callback-interruption",
                26,
            ),
            self.write_field(root, "long-call", "long-call", 26),
            self.write_field(root, "model-cold", "model-cold-start", 26),
            self.write_field(root, "mixed", "mixed-language", 26),
        ]

    def write_field(self, root, name, fixture, os_major):
        directory = root / name
        directory.mkdir()
        payload = {
            "protocolVersion": 2,
            "collectedAt": "2026-07-28T12:10:00Z",
            "fixture": fixture,
            "meetingReference": "meeting-0123456789ab",
            "outcome": "pass",
            "evidence": [
                {
                    "id": identifier,
                    "subsystem": reliability.EVIDENCE_SUBSYSTEMS[identifier],
                    "state": "pass",
                }
                for identifier in reliability.FIXTURE_EVIDENCE[fixture]
            ],
            "elapsedSeconds": None,
            "app": {"version": self.version, "build": self.build},
            "macOS": {
                "productVersion": f"{os_major}.5",
                "buildVersion": "25F70",
            },
            "supportReports": {
                "beforeRefine": {
                    "formatVersion": 2,
                    "generatedAt": "2026-07-28T12:00:00Z",
                    "meetingCount": 1,
                    "selectedMeeting": {
                        "lifecycleState": "captured",
                        "transcriptRevision": 1,
                        "audioAssetCount": 2,
                        "segmentCount": 1,
                        "processingJobCount": 1,
                    },
                },
                "afterRefine": (
                    {
                        "formatVersion": 2,
                        "generatedAt": "2026-07-28T12:05:00Z",
                        "meetingCount": 1,
                        "selectedMeeting": {
                            "lifecycleState": "captured",
                            "transcriptRevision": 2,
                            "audioAssetCount": 2,
                            "segmentCount": 1,
                            "processingJobCount": 1,
                        },
                    }
                    if fixture == "mixed-language"
                    else None
                ),
            },
        }
        (directory / "manifest.json").write_text(json.dumps(payload))
        return directory
