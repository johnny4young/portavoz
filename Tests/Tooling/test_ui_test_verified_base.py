import os
import tempfile
import unittest
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from ui_test_verified_base import (  # noqa: E402
    GitCommitHistory,
    VerifiedBaseError,
    resolve_verified_base,
)


BASE = "1" * 40
OLDER = "2" * 40
NEWER = "3" * 40
HEAD = "4" * 40


class FakeAuthority:
    def __init__(self, runs, artifacts):
        self.runs = runs
        self.artifacts = artifacts

    def get(self, path, query=None):
        del query
        if path.endswith("/runs"):
            return {"workflow_runs": self.runs}
        run_id = int(path.split("/")[-2])
        artifacts = self.artifacts.get(run_id, [])
        return {"total_count": len(artifacts), "artifacts": artifacts}


class FakeHistory:
    def __init__(self, relationships):
        self.relationships = set(relationships)

    def is_ancestor(self, ancestor, descendant):
        return ancestor == descendant or (ancestor, descendant) in self.relationships


def run(run_id, sha, *, conclusion="success", attempt=1, event="pull_request"):
    return {
        "id": run_id,
        "head_sha": sha,
        "conclusion": conclusion,
        "event": event,
        "run_attempt": attempt,
    }


def anchor(sha, *, expired=False):
    return {"name": f"ui-verification-{sha}", "expired": expired}


class UITestVerifiedBaseTests(unittest.TestCase):
    def resolve(self, runs, artifacts, relationships=None):
        if relationships is None:
            relationships = {
                (BASE, OLDER),
                (BASE, NEWER),
                (OLDER, NEWER),
                (OLDER, HEAD),
                (NEWER, HEAD),
                (BASE, HEAD),
            }
        return resolve_verified_base(
            FakeAuthority(runs, artifacts),
            FakeHistory(relationships),
            repository="owner/repo",
            workflow="ui-tests.yml",
            branch="codex/feature",
            head=HEAD,
            fallback=BASE,
        )

    def test_newest_first_attempt_success_with_exact_anchor_wins(self):
        resolution = self.resolve(
            [run(20, NEWER), run(10, OLDER)],
            {20: [anchor(NEWER)], 10: [anchor(OLDER)]},
        )

        self.assertTrue(resolution.anchor_found)
        self.assertEqual(resolution.base, NEWER)
        self.assertEqual(resolution.inspected_runs, 1)

    def test_rerun_green_cannot_become_incremental_proof(self):
        resolution = self.resolve(
            [run(20, NEWER, attempt=2), run(10, OLDER)],
            {20: [anchor(NEWER)], 10: [anchor(OLDER)]},
        )

        self.assertTrue(resolution.anchor_found)
        self.assertEqual(resolution.base, OLDER)

    def test_failed_expired_or_duplicate_anchor_is_not_trusted(self):
        resolution = self.resolve(
            [run(30, NEWER, conclusion="failure"), run(20, NEWER), run(10, OLDER)],
            {
                30: [anchor(NEWER)],
                20: [anchor(NEWER), anchor(NEWER)],
                10: [anchor(OLDER, expired=True)],
            },
        )

        self.assertFalse(resolution.anchor_found)
        self.assertEqual(resolution.base, BASE)

    def test_force_pushed_nonancestor_falls_back_to_pr_base(self):
        resolution = self.resolve(
            [run(20, NEWER)],
            {20: [anchor(NEWER)]},
            relationships={(BASE, HEAD)},
        )

        self.assertFalse(resolution.anchor_found)
        self.assertEqual(resolution.base, BASE)

    def test_current_head_anchor_is_ignored_so_rerun_cannot_self_qualify(self):
        resolution = self.resolve(
            [run(40, HEAD), run(20, NEWER)],
            {40: [anchor(HEAD)], 20: [anchor(NEWER)]},
        )

        self.assertTrue(resolution.anchor_found)
        self.assertEqual(resolution.base, NEWER)

    def test_search_is_bounded_to_thirty_completed_runs(self):
        candidates = [run(index, OLDER, conclusion="failure") for index in range(1, 31)]
        candidates.append(run(31, NEWER))

        resolution = self.resolve(candidates, {31: [anchor(NEWER)]})

        self.assertFalse(resolution.anchor_found)
        self.assertEqual(resolution.base, BASE)
        self.assertEqual(resolution.inspected_runs, 30)

    @patch(
        "ui_test_verified_base.subprocess.run",
        side_effect=subprocess.TimeoutExpired(cmd="git", timeout=10),
    )
    def test_git_ancestry_timeout_becomes_fail_safe_error(self, _run):
        with self.assertRaisesRegex(VerifiedBaseError, "could not validate"):
            GitCommitHistory().is_ancestor(BASE, HEAD)

    @patch("ui_test_verified_base.subprocess.run")
    def test_multiple_merge_bases_widen_to_their_common_ancestor(self, run):
        run.side_effect = [
            subprocess.CompletedProcess(args=[], returncode=0, stdout=f"{BASE}\n{NEWER}\n"),
            subprocess.CompletedProcess(args=[], returncode=0, stdout=f"{OLDER}\n"),
        ]

        root = GitCommitHistory().merge_base("refs/remotes/origin/main", HEAD)

        self.assertEqual(root, OLDER)
        self.assertEqual(run.call_args.args[0], ["git", "merge-base", "--octopus", BASE, NEWER])

    @patch("ui_test_verified_base.subprocess.run")
    def test_unresolvable_merge_bases_cannot_narrow_stacked_scope(self, run):
        run.side_effect = [
            subprocess.CompletedProcess(args=[], returncode=0, stdout=f"{BASE}\n{NEWER}\n"),
            subprocess.CompletedProcess(args=[], returncode=0, stdout=""),
        ]
        with self.assertRaisesRegex(VerifiedBaseError, "ambiguous"):
            GitCommitHistory().merge_base("refs/remotes/origin/main", HEAD)

    @patch(
        "ui_test_verified_base.subprocess.run",
        return_value=subprocess.CompletedProcess(
            args=[], returncode=0, stdout="--output=/tmp/x\nnot-a-sha\n"),
    )
    def test_malformed_merge_bases_never_reach_git_as_arguments(self, run):
        with self.assertRaisesRegex(VerifiedBaseError, "full lowercase commit SHA"):
            GitCommitHistory().merge_base("refs/remotes/origin/main", HEAD)
        self.assertEqual(run.call_count, 1)


class StackedPRSelectionIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        self.write_commit("README.md", "base\n")
        self.root = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("update-ref", "refs/remotes/origin/main", self.root)
        self.write_commit("Sources/portavoz-app/DictationSection.swift", "parent view\n")
        self.parent = self.git("rev-parse", "HEAD").stdout.strip()
        self.write_commit("docs/GAPS.md", "child documentation\n")
        self.head = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *arguments):
        return subprocess.run(
            ["git", *arguments],
            cwd=self.repository,
            check=True,
            capture_output=True,
            text=True,
        )

    def write_commit(self, path, content):
        target = self.repository / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        self.git("add", path)
        self.git("commit", "-qm", f"Add {path}")

    def resolve(
        self, *, base_branch="codex/parent", fallback=None, branch="codex/child", default_branch="main"
    ):
        return subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/ui_test_verified_base.py"),
                "--repository", "owner/repo",
                "--workflow", "ui-tests.yml",
                f"--branch={branch}",
                "--head", self.head,
                "--fallback", fallback or self.parent,
                f"--base-branch={base_branch}",
                f"--default-branch={default_branch}",
                "--format", "github",
            ],
            cwd=self.repository,
            capture_output=True,
            text=True,
            env={**os.environ, "GITHUB_TOKEN": ""},
        )

    def select(self, base):
        return subprocess.run(
            [
                sys.executable,
                str(ROOT / "scripts/ui_test_scope.py"),
                "--base", base,
                "--head", self.head,
                "--format", "github",
            ],
            cwd=self.repository,
            check=True,
            capture_output=True,
            text=True,
        )

    def test_child_docs_change_still_selects_parent_view_journey(self):
        child_only = self.select(self.parent)
        self.assertIn("required=false", child_only.stdout)

        base = self.resolve()
        self.assertEqual(base.returncode, 0, base.stderr)
        outputs = dict(line.split("=", 1) for line in base.stdout.splitlines())
        self.assertEqual(outputs["base"], self.root)
        self.assertEqual(outputs["anchor_found"], "false")
        self.assertIn("stacked PR cumulative", outputs["summary"])

        cumulative = self.select(outputs["base"])
        self.assertIn("required=true", cumulative.stdout)
        self.assertIn("testDictationOffersTriggersLanguageAndDictionary", cumulative.stdout)

    def test_parent_shared_harness_change_requires_both_child_locales(self):
        self.git("reset", "--hard", self.parent)
        self.write_commit("project.yml", "parent shared UI harness\n")
        self.parent = self.git("rev-parse", "HEAD").stdout.strip()
        self.write_commit("docs/GAPS.md", "new child documentation\n")
        self.head = self.git("rev-parse", "HEAD").stdout.strip()

        base = self.resolve()
        self.assertEqual(base.returncode, 0, base.stderr)
        resolved = dict(line.split("=", 1) for line in base.stdout.splitlines())
        self.assertEqual(resolved["base"], self.root)
        cumulative = self.select(resolved["base"])
        self.assertIn("locales=en es", cumulative.stdout)
        self.assertIn("testDictationOffersTriggersLanguageAndDictionary", cumulative.stdout)

    def test_missing_default_branch_ref_fails_instead_of_using_parent(self):
        self.git("update-ref", "-d", "refs/remotes/origin/main")

        result = self.resolve()

        self.assertEqual(result.returncode, 2)
        self.assertIn("::error title=Stacked UI scope::stacked UI scope failed closed", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_criss_cross_history_widens_to_the_shared_root(self):
        self.git("checkout", "-q", "-B", "main-line", self.root)
        self.write_commit("docs/ROADMAP-public.md", "main side\n")
        main_side = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "-q", "-B", "child-line", self.root)
        self.write_commit("Sources/portavoz-app/DictationSection.swift", "child view\n")
        child_side = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("merge", "-q", "--no-edit", main_side)
        self.head = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "-q", "main-line")
        self.git("merge", "-q", "--no-edit", child_side)
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        roots = self.git("merge-base", "--all", "refs/remotes/origin/main", self.head).stdout.split()
        self.assertEqual(set(roots), {main_side, child_side})

        base = self.resolve()

        self.assertEqual(base.returncode, 0, base.stderr)
        resolved = dict(line.split("=", 1) for line in base.stdout.splitlines())
        self.assertEqual(resolved["base"], self.root)
        self.assertIn("testDictationOffersTriggersLanguageAndDictionary", self.select(resolved["base"]).stdout)

    def test_malformed_branch_names_never_reach_git(self):
        for field in ("branch", "base_branch", "default_branch"):
            for name in ("-main", "../main", "/main", "main/", "a//b", "main branch"):
                with self.subTest(field=field, name=name):
                    result = self.resolve(**{field: name})
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("is invalid", result.stderr)
                    self.assertEqual(result.stdout, "")

    def test_direct_main_pr_retains_existing_verified_anchor_fallback(self):
        result = self.resolve(base_branch="main", fallback=self.root)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"base={self.root}", result.stdout)
        self.assertIn("fail-safe PR base", result.stdout)
        self.assertIn("::warning title=UI verified-base fallback::", result.stderr)
        for line in result.stdout.splitlines():
            self.assertRegex(line, r"^[a-z_]+=", "stdout is the step's GITHUB_OUTPUT")


if __name__ == "__main__":
    unittest.main()
