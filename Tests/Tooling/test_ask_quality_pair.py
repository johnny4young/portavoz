import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "ask_quality_pair", ROOT / "scripts" / "ask_quality_pair.py"
)
pair = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pair)


class FakeCommandRunner:
    def __init__(
        self,
        outcome="candidate-parity",
        dirty=False,
        fail_at=None,
        reported_candidate_adapter=None,
    ):
        self.outcome = outcome
        self.dirty = dirty
        self.fail_at = fail_at
        self.reported_candidate_adapter = reported_candidate_adapter
        self.calls = []
        self.commit = "a" * 40

    def __call__(self, command, root):
        self.calls.append(command)
        if command[:2] == ["git", "status"]:
            return self.result(0, " M Sources/Dirty.swift\n" if self.dirty else "")
        if command[:3] == ["git", "rev-parse", "HEAD"]:
            return self.result(0, f"{self.commit}\n")
        if command[:3] == ["git", "check-ignore", "--quiet"]:
            return self.result(0)
        if command[:3] == ["swift", "build", "-c"]:
            cli = root / ".build" / "release" / "portavoz-cli"
            cli.parent.mkdir(parents=True, exist_ok=True)
            cli.write_text("fixture", encoding="utf-8")
            return self.result(0)
        if len(command) > 2 and command[1].endswith("ask_quality.py"):
            action = command[2]
            if action == "verify-public":
                return self.result(0)
            output = Path(command[command.index("--output") + 1])
            if action == "evaluate":
                if self.fail_at == "evaluate":
                    return self.result(64, error="invalid observations")
                output.write_text("{}\n", encoding="utf-8")
                return self.result(1)
            if action == "compare":
                candidate_scorecard = Path(
                    command[command.index("--candidate") + 1]
                )
                candidate = candidate_scorecard.name.removesuffix(
                    "-scorecard.json"
                )
                output.write_text(
                    json.dumps(
                        {
                            "outcome": self.outcome,
                            "subject": {
                                "build": "search4d",
                                "commit": self.commit,
                                "controlAdapter": pair.SEGMENT_ADAPTER,
                                "candidateAdapter": (
                                    self.reported_candidate_adapter
                                    or pair.CANDIDATE_ADAPTERS[candidate]
                                ),
                            },
                        }
                    )
                    + "\n",
                    encoding="utf-8",
                )
                return self.result(0 if self.outcome == "candidate-parity" else 1)
        if command and command[0].endswith("portavoz-cli"):
            unit = command[command.index("--retrieval-unit") + 1]
            if self.fail_at == unit:
                return self.result(64, error="embedding assets unavailable")
            output = Path(command[command.index("--output") + 1])
            output.write_text("{}\n", encoding="utf-8")
            return self.result(0)
        return self.result(64, error=f"unexpected command: {command}")

    @staticmethod
    def result(code, output="", error=""):
        return subprocess.CompletedProcess([], code, output, error)


class AskQualityPairTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        base = Path(self.temporary.name)
        self.root = base / "repository"
        self.root.mkdir()
        scripts = self.root / "scripts"
        scripts.mkdir()
        (scripts / "ask_quality.py").write_text("fixture", encoding="utf-8")
        fixtures = self.root / "Fixtures" / "AskQuality"
        fixtures.mkdir(parents=True)
        self.fixture = fixtures / "public-synthetic-v2.json"
        self.fixture.write_text("{}\n", encoding="utf-8")
        self.output = (base / "private-evidence").resolve()

    def tearDown(self):
        self.temporary.cleanup()

    def test_publishes_complete_owner_only_pair_from_one_commit(self):
        runner = FakeCommandRunner()

        status, receipt = pair.collect_pair(
            self.root,
            self.fixture,
            self.output,
            "search4d",
            runner=runner,
        )

        self.assertEqual(status, 0)
        self.assertEqual(receipt, self.output / "comparison.json")
        self.assertEqual(
            {path.name for path in self.output.iterdir()},
            {
                "segment-observations.json",
                "segment-scorecard.json",
                "speaker-turn-observations.json",
                "speaker-turn-scorecard.json",
                "comparison.json",
            },
        )
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)
        self.assertTrue(all(
            (path.stat().st_mode & 0o777) == 0o600
            for path in self.output.iterdir()
        ))
        cli_calls = [
            call for call in runner.calls if call[0].endswith("portavoz-cli")
        ]
        self.assertEqual(len(cli_calls), 2)
        self.assertTrue(all("never" in call for call in cli_calls))
        self.assertTrue(all(runner.commit in call for call in cli_calls))
        self.assertEqual(
            [
                call[call.index("--retrieval-unit") + 1]
                for call in cli_calls
            ],
            ["segment", "speaker-turn"],
        )

    def test_publishes_declared_conversation_window_pair(self):
        runner = FakeCommandRunner()

        status, receipt = pair.collect_pair(
            self.root,
            self.fixture,
            self.output,
            "search4d",
            candidate="conversation-window",
            runner=runner,
        )

        self.assertEqual(status, 0)
        self.assertEqual(receipt, self.output / "comparison.json")
        self.assertEqual(
            {path.name for path in self.output.iterdir()},
            {
                "segment-observations.json",
                "segment-scorecard.json",
                "conversation-window-observations.json",
                "conversation-window-scorecard.json",
                "comparison.json",
            },
        )
        cli_calls = [
            call for call in runner.calls if call[0].endswith("portavoz-cli")
        ]
        self.assertEqual(
            [
                call[call.index("--retrieval-unit") + 1]
                for call in cli_calls
            ],
            ["segment", "conversation-window"],
        )

    def test_rejects_an_unknown_candidate_before_inspecting_source(self):
        runner = FakeCommandRunner()

        with self.assertRaisesRegex(
            pair.AskQualityPairError, "unsupported candidate"
        ):
            pair.collect_pair(
                self.root,
                self.fixture,
                self.output,
                "search4d",
                candidate="semantic-paragraph",
                runner=runner,
            )

        self.assertEqual(runner.calls, [])
        self.assertFalse(self.output.exists())

    def test_refuses_a_receipt_for_a_different_registered_candidate(self):
        runner = FakeCommandRunner(
            reported_candidate_adapter=pair.CANDIDATE_ADAPTERS["speaker-turn"]
        )

        with self.assertRaisesRegex(
            pair.AskQualityPairError, "lost selected adapter identity"
        ):
            pair.collect_pair(
                self.root,
                self.fixture,
                self.output,
                "search4d",
                candidate="conversation-window",
                runner=runner,
            )

        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.output.parent.glob(".private-evidence.*")), [])

    def test_publishes_blocked_receipt_with_nonzero_quality_status(self):
        runner = FakeCommandRunner(outcome="blocked")

        status, receipt = pair.collect_pair(
            self.root,
            self.fixture,
            self.output,
            "search4d",
            runner=runner,
        )

        self.assertEqual(status, 1)
        self.assertTrue(receipt.is_file())

    def test_rejects_dirty_source_before_building_or_creating_output(self):
        runner = FakeCommandRunner(dirty=True)

        with self.assertRaisesRegex(pair.AskQualityPairError, "must be clean"):
            pair.collect_pair(
                self.root,
                self.fixture,
                self.output,
                "search4d",
                runner=runner,
            )

        self.assertFalse(self.output.exists())
        self.assertFalse(any(call[0] == "swift" for call in runner.calls))

    def test_failure_removes_private_partial_output_and_lock(self):
        runner = FakeCommandRunner(fail_at="segment")

        with self.assertRaisesRegex(
            pair.AskQualityPairError, "embedding assets unavailable"
        ):
            pair.collect_pair(
                self.root,
                self.fixture,
                self.output,
                "search4d",
                runner=runner,
            )

        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.output.parent.glob(".private-evidence.*")), [])

    def test_refuses_to_overwrite_an_existing_evidence_directory(self):
        self.output.mkdir()
        runner = FakeCommandRunner()

        with self.assertRaisesRegex(pair.AskQualityPairError, "already exists"):
            pair.collect_pair(
                self.root,
                self.fixture,
                self.output,
                "search4d",
                runner=runner,
            )

        self.assertEqual(runner.calls, [])

    def test_evaluator_contract_error_is_not_treated_as_a_blocked_score(self):
        runner = FakeCommandRunner(fail_at="evaluate")

        with self.assertRaisesRegex(pair.AskQualityPairError, "evaluation failed"):
            pair.collect_pair(
                self.root,
                self.fixture,
                self.output,
                "search4d",
                runner=runner,
            )

        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
