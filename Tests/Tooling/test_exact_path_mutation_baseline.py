import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from Tests.Tooling import test_exact_path_mutation_cross_host as cross_test


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "exact_path_mutation_baseline.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location(
    "exact_path_mutation_baseline",
    SCRIPT,
)
baseline = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(baseline)


class RepositoryRunner:
    def __init__(
        self,
        *,
        commit="c" * 40,
        dirty=False,
        ignored=True,
        dirty_status_call=None,
    ):
        self.commit = commit
        self.dirty = dirty
        self.ignored = ignored
        self.dirty_status_call = dirty_status_call
        self.status_calls = 0

    def __call__(self, command, root):
        if command[:2] == ["git", "status"]:
            self.status_calls += 1
            changed = self.dirty or self.status_calls == self.dirty_status_call
            output = " M Sources/Changed.swift\n" if changed else ""
            return self.result(0, output)
        if command[:3] == ["git", "rev-parse", "HEAD"]:
            return self.result(0, f"{self.commit}\n")
        if command[:3] == ["git", "check-ignore", "--quiet"]:
            return self.result(0 if self.ignored else 1)
        return self.result(64, error=f"unexpected command: {command}")

    @staticmethod
    def result(code, output="", error=""):
        return subprocess.CompletedProcess([], code, output, error)


class ExactPathMutationBaselineTests(unittest.TestCase):
    retained_at = "2026-08-01T15:00:00Z"
    source_commit = "c" * 40
    acknowledgement = "timings-reviewed-no-engine-decision-v1"

    def setUp(self):
        self.cross_case = cross_test.ExactPathMutationCrossHostTests()
        self.cross_case.setUp()
        self.host_contract = self.cross_case.host_contract
        self.profiles = self.cross_case.profiles
        self.cross_contract = self.cross_case.contract
        self.admission_contract = baseline.load_contract(
            baseline.DEFAULT_CONTRACT,
            self.cross_contract,
            self.host_contract,
        )
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.repository = self.base / "repository"
        self.repository.mkdir()
        self.receipt_path = self.base / "receipts.jsonl"
        self.scorecard_path = self.base / "scorecard.json"
        self.output = self.base / "private" / "nested" / "baseline.json"

    def tearDown(self):
        self.temporary.cleanup()

    def test_explicit_review_publishes_recomputable_owner_only_baseline(self):
        receipts = list(reversed(self.cross_case.receipts()))
        self.write_evidence(receipts, self.cross_case.scorecard(receipts))

        document, output = self.admit()

        self.assertEqual(output, self.output.resolve())
        self.assertEqual(document["authority"], "research-correction-cost-only")
        self.assertEqual(document["engineDecision"], "not-evaluated")
        self.assertEqual(document["performanceDecision"], "not-evaluated")
        self.assertEqual(document["reviewAcknowledgement"], self.acknowledgement)
        self.assertEqual(document["sourceCommit"], self.source_commit)
        self.assertEqual(document["retainedAt"], self.retained_at)
        self.assertEqual(
            document["scorecardFileSHA256"],
            hashlib.sha256(self.scorecard_path.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            [receipt["hostProfile"] for receipt in document["hostReceipts"]],
            ["memory-8gb", "memory-16gb", "reference"],
        )
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(output.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(output.parent.parent.stat().st_mode & 0o777, 0o700)
        persisted = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(self.validate(persisted), document)
        encoded = json.dumps(document, sort_keys=True)
        for forbidden in (
            "meetingTitle",
            "transcript",
            "queryVector",
            "segmentID",
            "databasePath",
            "operatorNotes",
            "reviewerIdentity",
        ):
            self.assertNotIn(forbidden, encoded)

    def test_digest_source_and_acknowledgement_are_required_before_io(self):
        arguments = {
            "accepted_scorecard_sha256": "0" * 64,
            "accepted_source_commit": self.source_commit,
            "accepted_review_acknowledgement": self.acknowledgement,
        }
        invalid = (
            ("accepted_scorecard_sha256", "accept", "lowercase SHA-256"),
            ("accepted_source_commit", "HEAD", "full lowercase commit"),
            (
                "accepted_review_acknowledgement",
                "reviewed",
                "acknowledgement is inconsistent",
            ),
        )
        for key, value, message in invalid:
            options = dict(arguments)
            options[key] = value
            with self.assertRaisesRegex(baseline.BaselineError, message):
                baseline.admit_baseline(
                    self.base / "missing-receipts.jsonl",
                    self.base / "missing-scorecard.json",
                    self.output,
                    root=self.repository,
                    runner=RepositoryRunner(),
                    **options,
                )
        self.assertFalse(self.output.exists())
        self.assertFalse(self.output.parent.exists())

    def test_valid_blocked_scorecard_is_not_admitted(self):
        receipts = self.cross_case.receipts()[:-1]
        self.write_evidence(receipts, self.cross_case.scorecard(receipts))

        with self.assertRaisesRegex(
            baseline.BaselineNotAdmissible,
            "scorecard is blocked",
        ):
            self.admit()

        self.assertFalse(self.output.exists())

    def test_scorecard_must_match_the_exact_receipt_set(self):
        receipts = self.cross_case.receipts()
        scorecard = self.cross_case.scorecard(receipts)
        receipts[0] = self.cross_case.receipt("memory-8gb", 8, 15, 9)
        self.write_evidence(receipts, scorecard)

        with self.assertRaisesRegex(baseline.BaselineError, "does not exactly match"):
            self.admit()

        self.assertFalse(self.output.exists())

    def test_scorecard_file_must_be_exact_canonical_stdout(self):
        receipts = self.cross_case.receipts()
        scorecard = self.cross_case.scorecard(receipts)
        self.write_receipts(receipts)
        self.scorecard_path.write_text(json.dumps(scorecard) + "\n", encoding="utf-8")

        with self.assertRaisesRegex(
            baseline.BaselineError,
            "canonical cross-host stdout",
        ):
            self.admit()

    def test_scalar_payload_duplicate_and_nonfinite_json_fail_closed(self):
        receipts = self.cross_case.receipts()
        scorecard = self.cross_case.scorecard(receipts)
        scorecard["coverage"]["presentOperatingSystemMajors"][0] = 15.0
        self.write_evidence(receipts, scorecard)
        with self.assertRaisesRegex(baseline.BaselineError, "does not exactly match"):
            self.admit()

        scorecard = self.cross_case.scorecard(receipts)
        scorecard["meetingTitle"] = "private meeting"
        self.write_evidence(receipts, scorecard)
        with self.assertRaisesRegex(baseline.BaselineError, "forbidden meetingTitle"):
            self.admit()

        for text, message in (
            ('{"schemaVersion":1,"schemaVersion":1}\n', "duplicate JSON key"),
            ('{"schemaVersion":NaN}\n', "non-finite JSON"),
        ):
            self.scorecard_path.write_text(text, encoding="utf-8")
            with self.assertRaisesRegex(baseline.BaselineError, message):
                self.admit()
        self.assertFalse(self.output.exists())

    def test_existing_output_and_input_aliases_are_never_overwritten(self):
        receipts = self.cross_case.receipts()
        self.write_evidence(receipts, self.cross_case.scorecard(receipts))
        self.output.parent.mkdir(parents=True)
        self.output.write_text("sentinel\n", encoding="utf-8")

        with self.assertRaisesRegex(baseline.BaselineError, "already exists"):
            self.admit()
        self.assertEqual(self.output.read_text(encoding="utf-8"), "sentinel\n")

        alias = self.base / "alias-scorecard.json"
        alias.symlink_to(self.scorecard_path)
        with self.assertRaisesRegex(baseline.BaselineError, "must not replace"):
            baseline.validate_output_destination(
                alias,
                (self.receipt_path, self.scorecard_path),
                self.repository,
            )

    def test_existing_parent_permissions_are_not_changed(self):
        receipts = self.cross_case.receipts()
        self.write_evidence(receipts, self.cross_case.scorecard(receipts))
        parent = self.base / "existing"
        parent.mkdir(mode=0o755)
        os.chmod(parent, 0o755)
        output = parent / "baseline.json"

        self.admit(output=output)

        self.assertEqual(parent.stat().st_mode & 0o777, 0o755)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_repository_local_output_must_be_ignored(self):
        output = self.repository / "evidence" / "baseline.json"
        with self.assertRaisesRegex(baseline.BaselineError, "must be ignored"):
            baseline.validate_output_destination(
                output,
                (self.receipt_path, self.scorecard_path),
                self.repository,
                RepositoryRunner(ignored=False),
            )
        self.assertFalse(output.parent.exists())

        self.assertEqual(
            baseline.validate_output_destination(
                output,
                (self.receipt_path, self.scorecard_path),
                self.repository,
                RepositoryRunner(ignored=True),
            ),
            output.resolve(),
        )

    def test_admission_contract_cannot_gain_decision_authority(self):
        raw = json.loads(baseline.DEFAULT_CONTRACT.read_text(encoding="utf-8"))
        contract_path = self.base / "admission.json"
        mutations = (
            ("authority", "product-engine-selection"),
            ("engineDecision", "sqlite-vec"),
            ("performanceDecision", "candidate-faster"),
            ("reviewPolicyVersion", "automatic-v1"),
            ("requiredReviewAcknowledgement", "reviewed"),
            ("requiredScorecardOutcome", "pass"),
            ("maximumBaselineBytes", raw["maximumBaselineBytes"] + 1),
        )
        for key, value in mutations:
            weakened = copy.deepcopy(raw)
            weakened[key] = value
            contract_path.write_text(json.dumps(weakened), encoding="utf-8")
            with self.assertRaises(baseline.BaselineError):
                baseline.load_contract(
                    contract_path,
                    self.cross_contract,
                    self.host_contract,
                )

    def test_persisted_baseline_rejects_tampering(self):
        receipts = self.cross_case.receipts()
        scorecard = self.cross_case.scorecard(receipts)
        document = self.build(scorecard, receipts)
        cases = (
            (
                lambda value: value.__setitem__("scorecardFileSHA256", "0" * 64),
                "scorecardFileSHA256",
            ),
            (lambda value: value.__setitem__("authority", "product"), "authority"),
            (
                lambda value: value.__setitem__("performanceDecision", "fast"),
                "performanceDecision",
            ),
            (
                lambda value: value.__setitem__("reviewAcknowledgement", "reviewed"),
                "acknowledgement",
            ),
            (
                lambda value: value["hostReceipts"].reverse(),
                "canonical profile order",
            ),
        )
        for mutate, message in cases:
            tampered = copy.deepcopy(document)
            mutate(tampered)
            with self.assertRaisesRegex(baseline.BaselineError, message):
                self.validate(tampered)

    def test_retained_document_is_detached_from_input_evidence(self):
        receipts = self.cross_case.receipts()
        original_receipts = copy.deepcopy(receipts)
        scorecard = self.cross_case.scorecard(receipts)
        original_scorecard = copy.deepcopy(scorecard)

        document = self.build(scorecard, receipts)
        document["scorecard"]["profiles"][0]["host"]["processorCount"] += 1
        document["hostReceipts"][0]["host"]["processorCount"] += 1

        self.assertEqual(receipts, original_receipts)
        self.assertEqual(scorecard, original_scorecard)

    def test_bounded_readers_reject_oversized_inputs(self):
        self.scorecard_path.write_text("{}", encoding="utf-8")
        self.receipt_path.write_text("{}\n", encoding="utf-8")
        with self.assertRaisesRegex(baseline.BaselineError, "scorecard exceeds"):
            baseline.read_bounded_json(self.scorecard_path, "scorecard", 1)
        with self.assertRaisesRegex(baseline.BaselineError, "stream exceeds"):
            baseline.read_bounded_receipts(self.receipt_path, 1)

    def test_checkout_is_clean_stable_and_matches_reviewed_commit(self):
        receipts = self.cross_case.receipts()
        self.write_evidence(receipts, self.cross_case.scorecard(receipts))

        with self.assertRaisesRegex(baseline.BaselineError, "must be clean"):
            self.admit(runner=RepositoryRunner(dirty=True))
        with self.assertRaisesRegex(baseline.BaselineError, "does not match"):
            self.admit(runner=RepositoryRunner(commit="d" * 40))

        changed_after_publication = RepositoryRunner(dirty_status_call=3)
        with self.assertRaisesRegex(baseline.BaselineError, "must be clean"):
            self.admit(runner=changed_after_publication)
        self.assertFalse(self.output.exists())

    def test_cli_exit_codes_distinguish_retained_blocked_and_malformed(self):
        receipts = self.cross_case.receipts()
        self.write_evidence(receipts, self.cross_case.scorecard(receipts))
        retained_output = self.base / "retained.json"
        self.assertEqual(self.cli(retained_output), 0)
        self.assertTrue(retained_output.is_file())

        blocked_receipts = receipts[:-1]
        self.write_evidence(
            blocked_receipts,
            self.cross_case.scorecard(blocked_receipts),
        )
        blocked_output = self.base / "blocked.json"
        self.assertEqual(self.cli(blocked_output), 1)
        self.assertFalse(blocked_output.exists())

        self.scorecard_path.write_text('{"schemaVersion":1,"schemaVersion":1}\n')
        malformed_output = self.base / "malformed.json"
        self.assertEqual(self.cli(malformed_output), 2)
        self.assertFalse(malformed_output.exists())

    def write_receipts(self, receipts):
        self.receipt_path.write_text(
            "".join(json.dumps(receipt) + "\n" for receipt in receipts),
            encoding="utf-8",
        )

    def write_evidence(self, receipts, scorecard):
        self.write_receipts(receipts)
        self.scorecard_path.write_bytes(
            baseline.canonical_scorecard_file_bytes(scorecard)
        )

    def scorecard_digest(self):
        return hashlib.sha256(self.scorecard_path.read_bytes()).hexdigest()

    def build(self, scorecard, receipts):
        return baseline.build_baseline(
            scorecard,
            receipts,
            self.admission_contract,
            self.cross_contract,
            self.host_contract,
            self.profiles,
            scorecard_file_sha256=hashlib.sha256(
                baseline.canonical_scorecard_file_bytes(scorecard)
            ).hexdigest(),
            accepted_source_commit=self.source_commit,
            accepted_review_acknowledgement=self.acknowledgement,
            retained_at=self.retained_at,
        )

    def validate(self, document):
        return baseline.validate_baseline(
            document,
            self.admission_contract,
            self.cross_contract,
            self.host_contract,
            self.profiles,
        )

    def admit(self, *, output=None, runner=None):
        return baseline.admit_baseline(
            self.receipt_path,
            self.scorecard_path,
            output or self.output,
            accepted_scorecard_sha256=self.scorecard_digest(),
            accepted_source_commit=self.source_commit,
            accepted_review_acknowledgement=self.acknowledgement,
            root=self.repository,
            runner=runner or RepositoryRunner(),
            retained_at=self.retained_at,
        )

    def cli(self, output):
        arguments = [
            "--receipts",
            str(self.receipt_path),
            "--scorecard",
            str(self.scorecard_path),
            "--output",
            str(output),
            "--accept-scorecard-sha256",
            self.scorecard_digest(),
            "--accept-source-commit",
            self.source_commit,
            "--accept-review-acknowledgement",
            self.acknowledgement,
        ]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(
            io.StringIO()
        ):
            return baseline.main(
                arguments,
                root=self.repository,
                runner=RepositoryRunner(),
            )


if __name__ == "__main__":
    unittest.main()
