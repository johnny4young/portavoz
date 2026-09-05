import copy
import importlib.util
import json
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "commitment_link_policy_review.py"
SPEC = importlib.util.spec_from_file_location(
    "commitment_link_policy_review",
    SCRIPT,
)
review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(review)
quality = review.quality
FIXTURE = ROOT / "Fixtures" / "CommitmentLinkQuality" / "public-synthetic-v1.json"


class FakeGitRunner:
    def __init__(self, commit, dirty_after_status=None):
        self.commit = commit
        self.dirty_after_status = dirty_after_status
        self.status_calls = 0

    def __call__(self, command, root):
        if command[:2] == ["git", "status"]:
            self.status_calls += 1
            dirty = (
                self.dirty_after_status is not None
                and self.status_calls >= self.dirty_after_status
            )
            return subprocess.CompletedProcess(
                command,
                0,
                " M changed\n" if dirty else "",
                "",
            )
        if command == ["git", "rev-parse", "HEAD"]:
            return subprocess.CompletedProcess(command, 0, f"{self.commit}\n", "")
        if command[:2] == ["git", "check-ignore"]:
            return subprocess.CompletedProcess(command, 0, "", "")
        raise AssertionError(f"unexpected command: {command}")


class CommitmentLinkPolicyReviewTests(unittest.TestCase):
    commit = "b" * 40
    acknowledgement = (
        "selected-candidate-metrics-reviewed-no-serving-approval-v1"
    )

    def public_fixture(self):
        return quality.validate_fixture(quality.load_json(FIXTURE, "fixture"))

    def similarity_observations(self):
        fixture = self.public_fixture()
        control = quality.control_observations(fixture)
        return {
            "schemaVersion": 1,
            "kind": quality.SIMILARITY_OBSERVATION_KIND,
            "fixtureGeneration": fixture["generation"],
            "fixtureSHA256": quality.fixture_digest(fixture),
            "adapter": "product-accelerate-exact-scored-v1",
            "embeddingProfileFingerprint": "a" * 64,
            "build": "0.9.0+1",
            "commit": self.commit,
            "evaluationStatus": "not-evaluated",
            "servingStatus": "not-approved",
            "observations": [
                {
                    "caseID": row["caseID"],
                    "semanticHits": [
                        {
                            "evidenceSegmentID": evidence_id,
                            "similarity": round(0.9 - rank * 0.1, 6),
                        }
                        for rank, evidence_id in enumerate(
                            row["semanticHitSegmentIDs"]
                        )
                    ],
                    "suggestions": row["suggestions"],
                }
                for row in control["observations"]
            ],
        }

    def private_fixture(self):
        fixture = self.public_fixture()
        return {
            "schemaVersion": 1,
            "kind": quality.PRIVATE_FIXTURE_KIND,
            "generation": "private-anonymized-v1",
            "contentSource": quality.PRIVATE_SOURCE,
            "anonymization": {
                "policy": quality.PRIVATE_ANONYMIZATION_POLICY,
                "reviewStatus": quality.PRIVATE_REVIEW_STATUS,
                "containsAudio": False,
                "containsFilePaths": False,
                "containsAccountIdentifiers": False,
                "containsDirectIdentifiers": False,
            },
            "cases": fixture["cases"],
        }

    def private_observations(self):
        fixture = self.private_fixture()
        public = self.similarity_observations()
        return {
            "schemaVersion": 1,
            "kind": quality.PRIVATE_SIMILARITY_OBSERVATION_KIND,
            "fixtureGeneration": fixture["generation"],
            "fixtureSHA256": quality.fixture_digest(fixture),
            "contentSource": quality.PRIVATE_SOURCE,
            "anonymization": fixture["anonymization"],
            "adapter": "product-accelerate-exact-private-scored-v1",
            "embeddingProfileFingerprint": public[
                "embeddingProfileFingerprint"
            ],
            "build": public["build"],
            "commit": public["commit"],
            "evaluationStatus": "not-evaluated",
            "servingStatus": "not-approved",
            "observations": public["observations"],
        }

    def documents(self):
        public_fixture = self.public_fixture()
        public_observations = self.similarity_observations()
        public_replay = quality.replay_similarity_policies(
            public_fixture,
            public_observations,
        )
        private_fixture = self.private_fixture()
        private_observations = self.private_observations()
        private_replay = quality.replay_private_similarity_policies(
            private_fixture,
            private_observations,
        )
        matrix = quality.compare_public_private_profile(
            public_fixture,
            public_observations,
            public_replay,
            private_fixture,
            private_observations,
            private_replay,
        )
        return {
            "publicObservations": public_observations,
            "publicReplay": public_replay,
            "privateObservations": private_observations,
            "privateReplay": private_replay,
            "matrix": matrix,
            "privateFixture": private_fixture,
        }

    def write_sources(self, root):
        documents = self.documents()
        private_fixture = root / "private-fixture.json"
        private_fixture.write_text(
            json.dumps(documents["privateFixture"], indent=2) + "\n",
            encoding="utf-8",
        )
        private_fixture.chmod(0o600)
        bundle = root / "profile-matrix"
        bundle.mkdir(mode=0o700)
        paths = {}
        for key, filename in review.BUNDLE_FILES.items():
            path = bundle / filename
            path.write_text(
                json.dumps(documents[key], indent=2) + "\n",
                encoding="utf-8",
            )
            path.chmod(0o600)
            paths[key] = path
        matrix_bytes = paths["matrix"].read_bytes()
        return (
            bundle,
            private_fixture,
            paths,
            quality.document_digest(documents["matrix"]),
            review.sha256_bytes(matrix_bytes),
        )

    def test_review_accepts_exact_candidate_metrics_without_serving_authority(self):
        documents = self.documents()
        matrix = documents["matrix"]
        contract = review.load_contract()
        receipt = review.build_review_receipt(
            matrix,
            contract,
            matrix_file_sha256="c" * 64,
            accepted_matrix_sha256="c" * 64,
            accepted_source_commit=self.commit,
            selected_candidate_id="matrix-candidate-001",
            accepted_review_acknowledgement=self.acknowledgement,
        )

        self.assertEqual(receipt["kind"], review.REVIEW_KIND)
        self.assertEqual(
            receipt["selectionStatus"],
            "owner-selected-for-evaluation",
        )
        self.assertEqual(
            receipt["qualityFloorStatus"],
            "accepted-for-confirmation-evaluation",
        )
        self.assertEqual(receipt["productDecision"], "not-evaluated")
        self.assertEqual(receipt["servingStatus"], "not-approved")
        candidate = matrix["candidates"][0]
        self.assertEqual(
            receipt["acceptedQualityFloor"],
            {"public": candidate["public"], "private": candidate["private"]},
        )
        self.assertIs(
            review.validate_review_receipt(
                receipt,
                matrix,
                contract,
                matrix_file_sha256="c" * 64,
            ),
            receipt,
        )
        private_text = documents["privateFixture"]["cases"][0]["candidate"][
            "text"
        ]
        self.assertNotIn(private_text, json.dumps(receipt, ensure_ascii=False))

    def test_review_rejects_unacknowledged_drift_and_empty_candidate(self):
        matrix = self.documents()["matrix"]
        contract = review.load_contract()
        base = {
            "matrix_file_sha256": "c" * 64,
            "accepted_matrix_sha256": "c" * 64,
            "accepted_source_commit": self.commit,
            "selected_candidate_id": "matrix-candidate-001",
            "accepted_review_acknowledgement": self.acknowledgement,
        }
        for key, value, message in (
            ("accepted_matrix_sha256", "d" * 64, "digest"),
            ("accepted_source_commit", "e" * 40, "source commit"),
            ("accepted_review_acknowledgement", "reviewed", "acknowledgement"),
            ("selected_candidate_id", "missing", "absent"),
        ):
            arguments = dict(base)
            arguments[key] = value
            with self.assertRaisesRegex(review.ReviewError, message):
                review.build_review_receipt(matrix, contract, **arguments)

        empty_candidate = matrix["candidates"][-1]["candidateID"]
        with self.assertRaisesRegex(review.ReviewNotAdmissible, "admits no"):
            review.build_review_receipt(
                matrix,
                contract,
                **{**base, "selected_candidate_id": empty_candidate},
            )

    def test_admission_is_owner_only_non_overwriting_and_revalidatable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle, private_fixture, _, _, matrix_sha = self.write_sources(root)
            output = root / "private-evidence" / "policy-review.json"
            runner = FakeGitRunner(self.commit)

            receipt, retained = review.admit_review(
                bundle,
                private_fixture,
                output,
                accepted_matrix_sha256=matrix_sha,
                accepted_source_commit=self.commit,
                selected_candidate_id="matrix-candidate-001",
                accepted_review_acknowledgement=self.acknowledgement,
                root=root,
                runner=runner,
            )

            self.assertEqual(retained, output.resolve())
            self.assertEqual(stat.S_IMODE(retained.stat().st_mode), 0o600)
            self.assertEqual(
                review.validate_retained_review(
                    bundle,
                    private_fixture,
                    retained,
                ),
                receipt,
            )
            with self.assertRaisesRegex(review.BaselineError, "already exists"):
                review.admit_review(
                    bundle,
                    private_fixture,
                    output,
                    accepted_matrix_sha256=matrix_sha,
                    accepted_source_commit=self.commit,
                    selected_candidate_id="matrix-candidate-001",
                    accepted_review_acknowledgement=self.acknowledgement,
                    root=root,
                    runner=runner,
                )

    def test_admission_withdraws_receipt_if_checkout_changes_after_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle, private_fixture, _, _, matrix_sha = self.write_sources(root)
            output = root / "private-evidence" / "policy-review.json"
            runner = FakeGitRunner(self.commit, dirty_after_status=3)

            with self.assertRaisesRegex(
                review.BaselineError,
                "must be clean",
            ):
                review.admit_review(
                    bundle,
                    private_fixture,
                    output,
                    accepted_matrix_sha256=matrix_sha,
                    accepted_source_commit=self.commit,
                    selected_candidate_id="matrix-candidate-001",
                    accepted_review_acknowledgement=self.acknowledgement,
                    root=root,
                    runner=runner,
                )
            self.assertFalse(output.exists())

    def test_contract_and_inputs_fail_closed(self):
        contract = review.load_contract()
        broken = copy.deepcopy(contract)
        broken["servingStatus"] = "approved"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "contract.json"
            path.write_text(json.dumps(broken), encoding="utf-8")
            with self.assertRaisesRegex(review.ReviewError, "servingStatus"):
                review.load_contract(path)

            bundle, private_fixture, paths, _, _ = self.write_sources(
                Path(directory)
            )
            paths["matrix"].chmod(0o644)
            with self.assertRaisesRegex(review.ReviewError, "mode-0600"):
                review.load_review_sources(bundle, private_fixture, contract)

            paths["matrix"].chmod(0o600)
            linked_bundle = Path(directory) / "matrix-link"
            linked_bundle.symlink_to(bundle, target_is_directory=True)
            with self.assertRaisesRegex(review.ReviewError, "symbolic link"):
                review.load_review_sources(
                    linked_bundle,
                    private_fixture,
                    contract,
                )


if __name__ == "__main__":
    unittest.main()
