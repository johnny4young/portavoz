import copy
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import source_integration_qualification as source_integration  # noqa: E402


class FakeGitHubAuthority:
    def __init__(self, *, comparison, pulls, reviews, producer_runs, runs, jobs):
        self.comparison = comparison
        self.pulls = pulls
        self.reviews = reviews
        self.producer_runs = producer_runs
        self.runs = runs
        self.jobs = jobs
        self.queries = []

    def get(self, path, query=None):
        if "/compare/" in path:
            return copy.deepcopy(self.comparison)
        raise AssertionError(f"unexpected GitHub GET: {path} {query}")

    def get_all(self, path, *, collection=None, query=None):
        self.queries.append((path, collection, copy.deepcopy(query)))
        if "/commits/" in path and path.endswith("/pulls"):
            return copy.deepcopy(self.pulls)
        if path.endswith("/reviews"):
            return copy.deepcopy(self.reviews)
        if "/actions/workflows/" in path and path.endswith("/runs"):
            return copy.deepcopy(self.producer_runs)
        if path.endswith("/actions/runs"):
            return copy.deepcopy(self.runs)
        if path.endswith("/jobs"):
            return copy.deepcopy(self.jobs)
        raise AssertionError(f"unexpected paginated GitHub GET: {path} {query}")


class SourceIntegrationQualificationTests(unittest.TestCase):
    def test_exact_checkout_includes_untracked_source(self):
        source = (ROOT / "scripts" / "source_integration_qualification.py").read_text()
        self.assertIn("--untracked-files=all", source)
        self.assertNotIn("--untracked-files=no", source)

    version = "1.0.0"
    build = "202608260001"
    commit = "a" * 40
    head_commit = "b" * 40

    def setUp(self):
        self.contract_document = json.loads(
            source_integration.DEFAULT_CONTRACT.read_text()
        )
        self.contract = source_integration.load_contract()
        self.release = source_integration.release_identity(
            self.version, self.build, self.commit
        )

    def test_tracked_contract_freezes_review_and_hosted_ci_authority(self):
        self.assertEqual(self.contract_document["schemaVersion"], 1)
        self.assertEqual(
            self.contract_document["kind"],
            "source-integration-qualification-contract",
        )
        self.assertEqual(self.contract["repository"], "johnny4young/portavoz")
        self.assertEqual(self.contract["defaultBranch"], "main")
        self.assertTrue(self.contract["requireDefaultBranchHead"])
        self.assertEqual(self.contract["apiURL"], "https://api.github.com")
        self.assertEqual(self.contract["minimumApprovals"], 1)
        self.assertEqual(self.contract["workflowName"], "CI")
        self.assertEqual(
            self.contract["producerWorkflowName"],
            "Source integration evidence",
        )
        self.assertEqual(
            self.contract["requiredJobs"],
            (
                "build-and-test",
                "ios-portability",
                "sequoia-compatibility",
                "lint",
                "repository-hygiene",
            ),
        )
        self.assertTrue(self.contract["rejectMultipleRuns"])
        self.assertTrue(self.contract["rejectReruns"])

    def test_exact_reviewed_merge_and_first_pass_hosted_ci_qualify(self):
        api = self.good_api()
        authority = source_integration.collect_authority(
            api,
            self.contract,
            self.commit,
            self.release,
            collected_at="2026-08-26T00:00:00Z",
            producer_run_id=900,
            producer_run_attempt=1,
        )
        receipt = source_integration.qualification_receipt(
            self.release,
            collected_at="2026-08-26T00:00:00Z",
            authority_sha256=(
                source_integration.release_reliability.canonical_document_sha256(
                    authority
                )
            ),
        )

        self.assertEqual(authority["pullRequest"]["number"], 42)
        self.assertEqual(authority["pullRequest"]["approvalCount"], 1)
        self.assertEqual(authority["hostedCI"]["runAttempt"], 1)
        self.assertEqual(authority["producer"]["runID"], 900)
        hosted_run_queries = [
            query
            for path, collection, query in api.queries
            if path.endswith("/actions/runs") and collection == "workflow_runs"
        ]
        self.assertEqual(hosted_run_queries, [{"head_sha": self.commit}])
        self.assertEqual(
            receipt["proofs"],
            [
                {"id": "reviewed", "state": "pass"},
                {"id": "hosted-ci", "state": "pass"},
            ],
        )
        self.assertEqual(
            receipt["authoritySHA256"],
            source_integration.release_reliability.canonical_document_sha256(
                authority
            ),
        )
        serialized = json.dumps(authority)
        for private_or_content_key in (
            "reviewer",
            "author-login",
            "pull request body",
            "pull request title",
            "transcript",
            "prompt",
        ):
            self.assertNotIn(private_or_content_key, serialized)

    def test_outputs_are_new_owner_only_and_atomically_written(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "source-integration"
            authority = source_integration.collect_authority(
                self.good_api(),
                self.contract,
                self.commit,
                self.release,
                collected_at="2026-08-26T00:00:00Z",
            )
            receipt = source_integration.qualification_receipt(
                self.release,
                collected_at="2026-08-26T00:00:00Z",
                authority_sha256=(
                    source_integration.release_reliability
                    .canonical_document_sha256(authority)
                ),
            )
            prepared = source_integration.publish_output(
                output,
                authority,
                receipt,
            )

            self.assertEqual(os.stat(prepared).st_mode & 0o777, 0o700)
            self.assertEqual(
                os.stat(prepared / "qualification.json").st_mode & 0o777,
                0o600,
            )
            self.assertEqual(
                os.stat(prepared / "authority.json").st_mode & 0o777,
                0o600,
            )
            with self.assertRaisesRegex(
                source_integration.SourceIntegrationError,
                "output already exists",
            ):
                source_integration.publish_output(output, authority, receipt)

    def test_atomic_publication_leaves_no_partial_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "source-integration"
            original_write = source_integration.write_json

            def fail_second(path, document):
                if path.name == "qualification.json":
                    raise OSError("simulated publication failure")
                original_write(path, document)

            with mock.patch.object(
                source_integration,
                "write_json",
                side_effect=fail_second,
            ), self.assertRaisesRegex(OSError, "simulated publication failure"):
                source_integration.publish_output(
                    output,
                    {"schemaVersion": 1},
                    {"schemaVersion": 1},
                )

            self.assertFalse(output.exists())
            self.assertEqual(list(root.glob(".source-integration.*")), [])

    def test_atomic_publication_rejects_an_active_publisher(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "source-integration"
            lock = root / ".source-integration.publish.lock"
            lock.write_text("content-free reservation")

            with self.assertRaisesRegex(
                source_integration.SourceIntegrationError,
                "publication is already in progress",
            ):
                source_integration.publish_output(
                    output,
                    {"schemaVersion": 1},
                    {"schemaVersion": 1},
                )

            self.assertFalse(output.exists())
            self.assertTrue(lock.exists())

    def test_api_transport_truncation_fails_closed_without_a_raw_exception(self):
        client = source_integration.GitHubRESTClient(
            api_url=self.contract["apiURL"],
            token="test-token",
            api_version=self.contract["apiVersion"],
        )
        incomplete = source_integration.http.client.IncompleteRead(b"{", 1)
        with mock.patch.object(
            source_integration.urllib.request,
            "urlopen",
            side_effect=incomplete,
        ):
            with self.assertRaisesRegex(
                source_integration.SourceIntegrationError,
                "GitHub API request failed",
            ):
                client.get("/repos/johnny4young/portavoz")

    def test_diverged_release_commit_is_rejected(self):
        api = self.good_api()
        api.comparison["status"] = "diverged"

        with self.assertRaisesRegex(
            source_integration.SourceIntegrationError,
            "not the exact default-branch head",
        ):
            self.collect(api)

    def test_stale_default_branch_ancestor_is_rejected(self):
        api = self.good_api()
        api.comparison["status"] = "ahead"

        with self.assertRaisesRegex(
            source_integration.SourceIntegrationError,
            "not the exact default-branch head",
        ):
            self.collect(api)

    def test_exactly_one_merged_default_branch_pull_request_is_required(self):
        for mutate in (
            lambda pull: pull.update({"merged_at": None}),
            lambda pull: pull.update({"merge_commit_sha": "c" * 40}),
            lambda pull: pull["base"].update({"ref": "release"}),
            lambda pull: pull.update({"draft": True}),
        ):
            with self.subTest(mutate=mutate):
                api = self.good_api()
                mutate(api.pulls[0])
                with self.assertRaisesRegex(
                    source_integration.SourceIntegrationError,
                    "exactly one reviewed pull request",
                ):
                    self.collect(api)

    def test_approval_must_be_current_human_and_for_exact_pull_head(self):
        cases = {
            "stale commit": lambda review: review.update({"commit_id": "c" * 40}),
            "bot": lambda review: review["user"].update(
                {"login": "robot[bot]", "type": "Bot"}
            ),
            "self": lambda review: review["user"].update({"login": "author"}),
            "outsider": lambda review: review.update(
                {"author_association": "NONE"}
            ),
            "dismissed": lambda review: review.update({"state": "DISMISSED"}),
        }
        for name, mutate in cases.items():
            with self.subTest(name=name):
                api = self.good_api()
                mutate(api.reviews[0])
                with self.assertRaisesRegex(
                    source_integration.SourceIntegrationError,
                    "lacks a current human approval",
                ):
                    self.collect(api)

    def test_outstanding_change_request_blocks_even_with_an_approval(self):
        api = self.good_api()
        api.reviews.append(
            self.review(
                review_id=502,
                login="second-reviewer",
                state="CHANGES_REQUESTED",
            )
        )

        with self.assertRaisesRegex(
            source_integration.SourceIntegrationError,
            "outstanding change request",
        ):
            self.collect(api)

    def test_comment_after_approval_does_not_erase_decisive_state(self):
        api = self.good_api()
        comment = self.review(review_id=503, state="COMMENTED")
        api.reviews.append(comment)

        authority = self.collect(api)

        self.assertEqual(authority["pullRequest"]["approvalCount"], 1)

    def test_multiple_or_failed_unchanged_ci_runs_are_rejected(self):
        duplicate = self.good_api()
        duplicate.runs.append(copy.deepcopy(duplicate.runs[0]))
        duplicate.runs[-1]["id"] = 102
        with self.assertRaisesRegex(
            source_integration.SourceIntegrationError,
            "multiple unchanged-commit runs",
        ):
            self.collect(duplicate)

        failed = self.good_api()
        failed.runs[0]["conclusion"] = "failure"
        with self.assertRaisesRegex(
            source_integration.SourceIntegrationError,
            "non-success unchanged-commit run",
        ):
            self.collect(failed)

        in_progress_duplicate = self.good_api()
        in_progress_duplicate.runs.append(copy.deepcopy(in_progress_duplicate.runs[0]))
        in_progress_duplicate.runs[-1].update(
            {"id": 103, "status": "in_progress", "conclusion": None}
        )
        with self.assertRaisesRegex(
            source_integration.SourceIntegrationError,
            "multiple unchanged-commit runs",
        ):
            self.collect(in_progress_duplicate)

    def test_duplicate_or_rerun_producer_cannot_emit_another_receipt(self):
        duplicate = self.good_api()
        duplicate.producer_runs.append(copy.deepcopy(duplicate.producer_runs[0]))
        duplicate.producer_runs[-1]["id"] = 901
        with self.assertRaisesRegex(
            source_integration.SourceIntegrationError,
            "one unique dispatch",
        ):
            self.collect(duplicate)

        rerun = self.good_api()
        rerun.producer_runs[0]["run_attempt"] = 2
        with self.assertRaisesRegex(
            source_integration.SourceIntegrationError,
            "does not match this dispatch",
        ):
            self.collect(rerun)

    def test_producer_run_must_be_the_exact_main_commit(self):
        for key, value in (
            ("head_branch", "feature"),
            ("head_sha", "c" * 40),
        ):
            with self.subTest(key=key):
                api = self.good_api()
                api.producer_runs[0][key] = value
                with self.assertRaisesRegex(
                    source_integration.SourceIntegrationError,
                    f"producer {key} does not match",
                ):
                    self.collect(api)

    def test_ci_rerun_cannot_replace_first_pass_evidence(self):
        api = self.good_api()
        api.runs[0]["run_attempt"] = 2

        with self.assertRaisesRegex(
            source_integration.SourceIntegrationError,
            "reruns cannot qualify",
        ):
            self.collect(api)

    def test_every_required_ci_job_must_run_once_and_pass(self):
        missing = self.good_api()
        missing.jobs = [
            job for job in missing.jobs if job["name"] != "sequoia-compatibility"
        ]
        with self.assertRaisesRegex(
            source_integration.SourceIntegrationError,
            "sequoia-compatibility must run exactly once and pass",
        ):
            self.collect(missing)

        duplicate = self.good_api()
        duplicate.jobs.append(
            {"name": "repository-hygiene", "conclusion": "success"}
        )
        with self.assertRaisesRegex(
            source_integration.SourceIntegrationError,
            "repository-hygiene must run exactly once and pass",
        ):
            self.collect(duplicate)

    def test_runner_has_no_caller_supplied_contract_or_proof_state(self):
        parser = source_integration.parser()
        destinations = {action.dest for action in parser._actions}
        self.assertEqual(
            destinations,
            {"help", "version", "build", "commit", "output"},
        )
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(
                source_integration.SourceIntegrationError,
                "receipt owner is GitHub Actions",
            ):
                source_integration.require_github_environment(self.contract)

    def test_dispatch_environment_requires_exact_main_first_attempt(self):
        environment = {
            "GITHUB_ACTIONS": "true",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_REPOSITORY": self.contract["repository"],
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_WORKFLOW": self.contract["producerWorkflowName"],
            "GITHUB_TOKEN": "test-token",
            "GITHUB_API_URL": self.contract["apiURL"],
            "GITHUB_RUN_ID": "900",
            "GITHUB_RUN_ATTEMPT": "1",
        }
        with mock.patch.dict(os.environ, environment, clear=True):
            api_url, token, run_id, run_attempt = (
                source_integration.require_github_environment(self.contract)
            )
        self.assertEqual(api_url, "https://api.github.com")
        self.assertEqual(token, "test-token")
        self.assertEqual((run_id, run_attempt), (900, 1))

        for key, value, message in (
            ("GITHUB_REF", "refs/heads/feature", "default branch"),
            ("GITHUB_RUN_ATTEMPT", "2", "reruns cannot qualify"),
        ):
            with self.subTest(key=key):
                invalid = dict(environment)
                invalid[key] = value
                with mock.patch.dict(os.environ, invalid, clear=True):
                    with self.assertRaisesRegex(
                        source_integration.SourceIntegrationError,
                        message,
                    ):
                        source_integration.require_github_environment(self.contract)

    def test_dispatch_sha_and_checked_out_head_must_match_release(self):
        with mock.patch.dict(
            os.environ,
            {"GITHUB_SHA": "c" * 40},
            clear=True,
        ), mock.patch.object(source_integration, "exact_checkout") as checkout:
            with self.assertRaisesRegex(
                source_integration.SourceIntegrationError,
                "dispatch source does not match",
            ):
                source_integration.require_exact_dispatch_source(self.commit)
            checkout.assert_not_called()

        with mock.patch.dict(
            os.environ,
            {"GITHUB_SHA": self.commit},
            clear=True,
        ), mock.patch.object(source_integration, "exact_checkout") as checkout:
            source_integration.require_exact_dispatch_source(self.commit)
            checkout.assert_called_once_with(self.commit)

    def collect(self, api):
        return source_integration.collect_authority(
            api,
            self.contract,
            self.commit,
            self.release,
            collected_at="2026-08-26T00:00:00Z",
            producer_run_id=900,
            producer_run_attempt=1,
        )

    def good_api(self):
        return FakeGitHubAuthority(
            comparison={
                "status": "identical",
                "base_commit": {"sha": self.commit},
            },
            pulls=[
                {
                    "number": 42,
                    "state": "closed",
                    "merged_at": "2026-08-25T23:50:00Z",
                    "draft": False,
                    "merge_commit_sha": self.commit,
                    "base": {"ref": "main"},
                    "head": {"sha": self.head_commit},
                    "user": {"login": "author"},
                }
            ],
            reviews=[self.review()],
            producer_runs=[
                {
                    "id": 900,
                    "name": "Source integration evidence",
                    "display_title": f"Source integration {self.commit}",
                    "path": ".github/workflows/source-integration-evidence.yml",
                    "event": "workflow_dispatch",
                    "head_branch": "main",
                    "head_sha": self.commit,
                    "run_attempt": 1,
                    "status": "in_progress",
                    "conclusion": None,
                }
            ],
            runs=[
                {
                    "id": 101,
                    "name": "CI",
                    "status": "completed",
                    "conclusion": "success",
                    "event": "push",
                    "head_branch": "main",
                    "head_sha": self.commit,
                    "path": ".github/workflows/ci.yml",
                    "run_attempt": 1,
                }
            ],
            jobs=[
                {"name": name, "conclusion": "success"}
                for name in self.contract["requiredJobs"]
            ],
        )

    def review(
        self,
        *,
        review_id=501,
        login="reviewer",
        state="APPROVED",
    ):
        return {
            "id": review_id,
            "state": state,
            "user": {"login": login, "type": "User"},
            "author_association": "COLLABORATOR",
            "commit_id": self.head_commit,
        }


if __name__ == "__main__":
    unittest.main()
