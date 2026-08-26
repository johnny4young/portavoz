#!/usr/bin/env python3
"""Qualify reviewed source integration from GitHub-owned evidence."""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Protocol, Sequence

import release_reliability


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONTRACT = (
    ROOT / "docs" / "evidence" / "source-integration-qualification.json"
)
CONTRACT_SCHEMA_VERSION = 1
AUTHORITY_SCHEMA_VERSION = 1
MAXIMUM_API_RESPONSE_BYTES = 8 * 1024 * 1024
PER_PAGE = 100
REVIEW_STATES = {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}
REPOSITORY_PATTERN = re.compile(
    r"^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})/[A-Za-z0-9_.-]{1,100}$"
)
WORKFLOW_PATH_PATTERN = re.compile(
    r"^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$"
)


class SourceIntegrationError(ValueError):
    """A fail-closed source-integration qualification error."""


class GitHubAuthority(Protocol):
    """The read-only GitHub calls used by source qualification."""

    def get(self, path: str, query: dict[str, str] | None = None) -> Any:
        """Return one decoded GitHub REST response."""

    def get_all(
        self,
        path: str,
        *,
        collection: str | None = None,
        query: dict[str, str] | None = None,
    ) -> list[Any]:
        """Return every item from one paginated GitHub REST response."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def exact_object(
    value: Any,
    label: str,
    required: Sequence[str],
    optional: Sequence[str] = (),
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SourceIntegrationError(f"{label} must be an object")
    expected = set(required)
    allowed = expected | set(optional)
    missing = expected - value.keys()
    extra = value.keys() - allowed
    if missing:
        raise SourceIntegrationError(
            f"{label} is missing keys: {', '.join(sorted(missing))}"
        )
    if extra:
        raise SourceIntegrationError(
            f"{label} has unknown keys: {', '.join(sorted(extra))}"
        )
    return value


def exact_integer(value: Any, label: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise SourceIntegrationError(f"{label} must be an integer >= {minimum}")
    return value


def exact_boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise SourceIntegrationError(f"{label} must be a boolean")
    return value


def safe_code(value: Any, label: str) -> str:
    try:
        return release_reliability.safe_string(
            value,
            label,
            release_reliability.BUILD_PATTERN,
        )
    except release_reliability.ReliabilityError as error:
        raise SourceIntegrationError(str(error)) from error


def nonempty_string(value: Any, label: str, *, maximum: int = 200) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise SourceIntegrationError(
            f"{label} must be a non-empty string of at most {maximum} characters"
        )
    if any(ord(character) < 0x20 for character in value):
        raise SourceIntegrationError(f"{label} contains control characters")
    return value


def workflow_path(value: Any, label: str) -> str:
    path = nonempty_string(value, label, maximum=240)
    if WORKFLOW_PATH_PATTERN.fullmatch(path) is None:
        raise SourceIntegrationError(
            f"{label} must identify one tracked GitHub workflow file"
        )
    return path


def load_contract(path: Path = DEFAULT_CONTRACT) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SourceIntegrationError(f"cannot load source integration contract: {error}") from error

    root = exact_object(
        document,
        "contract",
        ("schemaVersion", "kind", "github", "review", "producer", "hostedCI"),
    )
    if exact_integer(root["schemaVersion"], "contract.schemaVersion") != CONTRACT_SCHEMA_VERSION:
        raise SourceIntegrationError(
            f"contract.schemaVersion must be {CONTRACT_SCHEMA_VERSION}"
        )
    if root["kind"] != "source-integration-qualification-contract":
        raise SourceIntegrationError("contract.kind is unsupported")

    github = exact_object(
        root["github"],
        "contract.github",
        (
            "repository",
            "defaultBranch",
            "requireDefaultBranchHead",
            "apiURL",
            "apiVersion",
        ),
    )
    repository = nonempty_string(
        github["repository"], "contract.github.repository", maximum=160
    )
    if REPOSITORY_PATTERN.fullmatch(repository) is None:
        raise SourceIntegrationError("contract.github.repository must be owner/name")
    default_branch = safe_code(
        github["defaultBranch"], "contract.github.defaultBranch"
    )
    api_version = nonempty_string(
        github["apiVersion"], "contract.github.apiVersion", maximum=20
    )
    api_url = nonempty_string(
        github["apiURL"], "contract.github.apiURL", maximum=120
    )
    if api_url != "https://api.github.com":
        raise SourceIntegrationError(
            "contract.github.apiURL must be https://api.github.com"
        )

    review = exact_object(
        root["review"],
        "contract.review",
        ("minimumApprovals", "allowedAuthorAssociations"),
    )
    minimum_approvals = exact_integer(
        review["minimumApprovals"],
        "contract.review.minimumApprovals",
        minimum=1,
    )
    associations = review["allowedAuthorAssociations"]
    if not isinstance(associations, list) or not associations:
        raise SourceIntegrationError(
            "contract.review.allowedAuthorAssociations must be a non-empty array"
        )
    allowed_associations = tuple(
        nonempty_string(value, "contract.review.allowedAuthorAssociations[]", maximum=40)
        for value in associations
    )
    if len(set(allowed_associations)) != len(allowed_associations):
        raise SourceIntegrationError(
            "contract.review.allowedAuthorAssociations contains duplicates"
        )

    producer = exact_object(
        root["producer"],
        "contract.producer",
        ("workflowName", "workflowPath", "event"),
    )

    hosted = exact_object(
        root["hostedCI"],
        "contract.hostedCI",
        (
            "workflowName",
            "workflowPath",
            "event",
            "requiredJobs",
            "rejectMultipleRuns",
            "rejectReruns",
        ),
    )
    required_jobs = hosted["requiredJobs"]
    if not isinstance(required_jobs, list) or not required_jobs:
        raise SourceIntegrationError(
            "contract.hostedCI.requiredJobs must be a non-empty array"
        )
    jobs = tuple(
        nonempty_string(value, "contract.hostedCI.requiredJobs[]", maximum=120)
        for value in required_jobs
    )
    if len(set(jobs)) != len(jobs):
        raise SourceIntegrationError("contract.hostedCI.requiredJobs contains duplicates")

    return {
        "repository": repository,
        "defaultBranch": default_branch,
        "requireDefaultBranchHead": exact_boolean(
            github["requireDefaultBranchHead"],
            "contract.github.requireDefaultBranchHead",
        ),
        "apiVersion": api_version,
        "apiURL": api_url,
        "minimumApprovals": minimum_approvals,
        "allowedAuthorAssociations": frozenset(allowed_associations),
        "producerWorkflowName": nonempty_string(
            producer["workflowName"],
            "contract.producer.workflowName",
            maximum=120,
        ),
        "producerWorkflowPath": workflow_path(
            producer["workflowPath"],
            "contract.producer.workflowPath",
        ),
        "producerWorkflowEvent": safe_code(
            producer["event"], "contract.producer.event"
        ),
        "workflowName": nonempty_string(
            hosted["workflowName"], "contract.hostedCI.workflowName", maximum=120
        ),
        "workflowPath": workflow_path(
            hosted["workflowPath"], "contract.hostedCI.workflowPath"
        ),
        "workflowEvent": safe_code(
            hosted["event"], "contract.hostedCI.event"
        ),
        "requiredJobs": jobs,
        "rejectMultipleRuns": exact_boolean(
            hosted["rejectMultipleRuns"],
            "contract.hostedCI.rejectMultipleRuns",
        ),
        "rejectReruns": exact_boolean(
            hosted["rejectReruns"], "contract.hostedCI.rejectReruns"
        ),
    }


class GitHubRESTClient:
    """Small bounded JSON client for GitHub's read-only REST authority."""

    def __init__(self, *, api_url: str, token: str, api_version: str) -> None:
        self.api_url = api_url.rstrip("/")
        self.token = token
        self.api_version = api_version

    def get(self, path: str, query: dict[str, str] | None = None) -> Any:
        url = f"{self.api_url}{path}"
        if query:
            url = f"{url}?{urllib.parse.urlencode(query)}"
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "User-Agent": "portavoz-source-integration-qualification",
                "X-GitHub-Api-Version": self.api_version,
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                length = response.headers.get("Content-Length")
                if length is not None and int(length) > MAXIMUM_API_RESPONSE_BYTES:
                    raise SourceIntegrationError(
                        f"GitHub API response is too large for {path}"
                    )
                body = response.read(MAXIMUM_API_RESPONSE_BYTES + 1)
        except (
            urllib.error.URLError,
            http.client.HTTPException,
            OSError,
            ValueError,
        ) as error:
            raise SourceIntegrationError(
                f"GitHub API request failed for {path}: {type(error).__name__}"
            ) from error
        if len(body) > MAXIMUM_API_RESPONSE_BYTES:
            raise SourceIntegrationError(f"GitHub API response is too large for {path}")
        try:
            return json.loads(body)
        except (json.JSONDecodeError, UnicodeError) as error:
            raise SourceIntegrationError(
                f"GitHub API returned invalid JSON for {path}"
            ) from error

    def get_all(
        self,
        path: str,
        *,
        collection: str | None = None,
        query: dict[str, str] | None = None,
    ) -> list[Any]:
        items: list[Any] = []
        for page in range(1, 101):
            page_query = dict(query or {})
            page_query.update({"per_page": str(PER_PAGE), "page": str(page)})
            document = self.get(path, page_query)
            if collection is None:
                if not isinstance(document, list):
                    raise SourceIntegrationError(
                        f"GitHub API response for {path} must be an array"
                    )
                batch = document
                total = None
            else:
                root = exact_object(
                    document,
                    f"GitHub API response for {path}",
                    ("total_count", collection),
                    tuple(key for key in document if key not in {"total_count", collection})
                    if isinstance(document, dict)
                    else (),
                )
                total = exact_integer(root["total_count"], f"{path}.total_count")
                batch = root[collection]
                if not isinstance(batch, list):
                    raise SourceIntegrationError(f"{path}.{collection} must be an array")
            items.extend(batch)
            if len(batch) < PER_PAGE or (total is not None and len(items) >= total):
                return items
        raise SourceIntegrationError(f"GitHub API pagination exceeded 100 pages for {path}")


def api_path(repository: str, suffix: str) -> str:
    return f"/repos/{repository}/{suffix}"


def require_exact_default_branch_head(
    api: GitHubAuthority,
    contract: dict[str, Any],
    commit: str,
) -> None:
    default_branch = urllib.parse.quote(contract["defaultBranch"], safe="")
    comparison = api.get(
        api_path(contract["repository"], f"compare/{commit}...{default_branch}"),
        {"per_page": "1"},
    )
    root = exact_object(
        comparison,
        "compare response",
        ("status", "base_commit"),
        tuple(key for key in comparison if key not in {"status", "base_commit"})
        if isinstance(comparison, dict)
        else (),
    )
    base = exact_object(
        root["base_commit"],
        "compare response.base_commit",
        ("sha",),
        tuple(key for key in root["base_commit"] if key != "sha")
        if isinstance(root["base_commit"], dict)
        else (),
    )
    if base["sha"] != commit:
        raise SourceIntegrationError("GitHub compare authority returned another base commit")
    allowed_statuses = (
        {"identical"}
        if contract["requireDefaultBranchHead"]
        else {"ahead", "identical"}
    )
    if root["status"] not in allowed_statuses:
        raise SourceIntegrationError(
            "release commit is not the exact default-branch head"
        )


def select_integrating_pull_request(
    pull_requests: list[Any],
    contract: dict[str, Any],
    commit: str,
) -> dict[str, Any]:
    matches: list[dict[str, Any]] = []
    for index, raw in enumerate(pull_requests):
        if not isinstance(raw, dict):
            raise SourceIntegrationError(f"associated pull request {index} must be an object")
        base = raw.get("base")
        if (
            raw.get("state") == "closed"
            and raw.get("merged_at") is not None
            and raw.get("draft") is False
            and raw.get("merge_commit_sha") == commit
            and isinstance(base, dict)
            and base.get("ref") == contract["defaultBranch"]
        ):
            matches.append(raw)
    if len(matches) != 1:
        raise SourceIntegrationError(
            "exactly one reviewed pull request must introduce the release commit"
        )
    pull_request = matches[0]
    exact_integer(pull_request.get("number"), "pull request.number", minimum=1)
    head = pull_request.get("head")
    if not isinstance(head, dict):
        raise SourceIntegrationError("pull request.head must be an object")
    try:
        release_reliability.safe_string(
            head.get("sha"),
            "pull request.head.sha",
            release_reliability.COMMIT_PATTERN,
        )
    except release_reliability.ReliabilityError as error:
        raise SourceIntegrationError(str(error)) from error
    user = pull_request.get("user")
    if not isinstance(user, dict):
        raise SourceIntegrationError("pull request.user must be an object")
    nonempty_string(user.get("login"), "pull request.user.login", maximum=100)
    return pull_request


def current_decisive_reviews(reviews: list[Any]) -> dict[str, dict[str, Any]]:
    current: dict[str, dict[str, Any]] = {}
    for index, raw in enumerate(reviews):
        if not isinstance(raw, dict):
            raise SourceIntegrationError(f"pull request review {index} must be an object")
        state = raw.get("state")
        if state not in REVIEW_STATES:
            continue
        user = raw.get("user")
        if not isinstance(user, dict):
            raise SourceIntegrationError(f"pull request review {index}.user must be an object")
        login = nonempty_string(
            user.get("login"), f"pull request review {index}.user.login", maximum=100
        ).casefold()
        exact_integer(
            raw.get("id"), f"pull request review {index}.id", minimum=1
        )
        # GitHub documents this endpoint as chronological. Overwriting in
        # response order preserves the current decisive state without assuming
        # globally monotonic review identifiers.
        current[login] = raw
    return current


def approved_reviews(
    reviews: list[Any],
    pull_request: dict[str, Any],
    contract: dict[str, Any],
) -> list[dict[str, Any]]:
    current = current_decisive_reviews(reviews)
    if any(review.get("state") == "CHANGES_REQUESTED" for review in current.values()):
        raise SourceIntegrationError("pull request has an outstanding change request")
    author = pull_request["user"]["login"].casefold()
    head_commit = pull_request["head"]["sha"]
    approved: list[dict[str, Any]] = []
    for login, review in current.items():
        user = review["user"]
        if (
            review.get("state") != "APPROVED"
            or login == author
            or user.get("type") == "Bot"
            or login.endswith("[bot]")
            or review.get("author_association")
            not in contract["allowedAuthorAssociations"]
            or review.get("commit_id") != head_commit
        ):
            continue
        approved.append(review)
    if len(approved) < contract["minimumApprovals"]:
        raise SourceIntegrationError(
            "pull request lacks a current human approval for its exact head commit"
        )
    return sorted(approved, key=lambda review: review["id"])


def select_hosted_ci_run(
    runs: list[Any],
    contract: dict[str, Any],
    commit: str,
) -> dict[str, Any]:
    relevant: list[dict[str, Any]] = []
    for index, raw in enumerate(runs):
        if not isinstance(raw, dict):
            raise SourceIntegrationError(f"workflow run {index} must be an object")
        if raw.get("name") == contract["workflowName"]:
            relevant.append(raw)
    if not relevant:
        raise SourceIntegrationError("required hosted CI workflow has no exact-commit run")
    if contract["rejectMultipleRuns"] and len(relevant) != 1:
        raise SourceIntegrationError(
            "required hosted CI workflow has multiple unchanged-commit runs"
        )
    if any(run.get("conclusion") != "success" for run in relevant):
        raise SourceIntegrationError(
            "required hosted CI has a non-success unchanged-commit run"
        )
    run = relevant[-1]
    required = {
        "status": "completed",
        "conclusion": "success",
        "event": contract["workflowEvent"],
        "head_branch": contract["defaultBranch"],
        "head_sha": commit,
        "path": contract["workflowPath"],
    }
    for key, expected in required.items():
        if run.get(key) != expected:
            raise SourceIntegrationError(
                f"hosted CI run {key} does not match the qualification contract"
            )
    run_id = exact_integer(run.get("id"), "hosted CI run.id", minimum=1)
    run_attempt = exact_integer(
        run.get("run_attempt"), "hosted CI run.run_attempt", minimum=1
    )
    if contract["rejectReruns"] and run_attempt != 1:
        raise SourceIntegrationError("hosted CI reruns cannot qualify unchanged source")
    run["id"] = run_id
    run["run_attempt"] = run_attempt
    return run


def validate_hosted_jobs(
    jobs: list[Any], contract: dict[str, Any]
) -> tuple[str, ...]:
    states: dict[str, list[str | None]] = {}
    for index, raw in enumerate(jobs):
        if not isinstance(raw, dict):
            raise SourceIntegrationError(f"hosted CI job {index} must be an object")
        name = nonempty_string(raw.get("name"), f"hosted CI job {index}.name", maximum=160)
        states.setdefault(name, []).append(raw.get("conclusion"))
    for required in contract["requiredJobs"]:
        conclusions = states.get(required)
        if conclusions != ["success"]:
            raise SourceIntegrationError(
                f"hosted CI job {required} must run exactly once and pass"
            )
    if any(conclusion != "success" for values in states.values() for conclusion in values):
        raise SourceIntegrationError("hosted CI contains a non-success job")
    return tuple(sorted(states))


def validate_unique_producer_run(
    api: GitHubAuthority,
    contract: dict[str, Any],
    commit: str,
    *,
    run_id: int,
    run_attempt: int,
) -> dict[str, Any]:
    workflow_id = urllib.parse.quote(
        Path(contract["producerWorkflowPath"]).name,
        safe="",
    )
    runs = api.get_all(
        api_path(
            contract["repository"],
            f"actions/workflows/{workflow_id}/runs",
        ),
        collection="workflow_runs",
        query={"event": contract["producerWorkflowEvent"]},
    )
    title = f"Source integration {commit}"
    matching: list[dict[str, Any]] = []
    for index, raw in enumerate(runs):
        if not isinstance(raw, dict):
            raise SourceIntegrationError(
                f"source integration producer run {index} must be an object"
            )
        if raw.get("display_title") == title:
            matching.append(raw)
    if len(matching) != 1:
        raise SourceIntegrationError(
            "source integration qualification must have one unique dispatch"
        )
    run = matching[0]
    expected = {
        "id": run_id,
        "name": contract["producerWorkflowName"],
        "path": contract["producerWorkflowPath"],
        "event": contract["producerWorkflowEvent"],
        "head_branch": contract["defaultBranch"],
        "head_sha": commit,
        "run_attempt": run_attempt,
        "status": "in_progress",
        "conclusion": None,
    }
    for key, value in expected.items():
        if run.get(key) != value:
            raise SourceIntegrationError(
                f"source integration producer {key} does not match this dispatch"
            )
    if run_attempt != 1:
        raise SourceIntegrationError(
            "source integration producer reruns cannot qualify unchanged source"
        )
    return run


def collect_authority(
    api: GitHubAuthority,
    contract: dict[str, Any],
    commit: str,
    release: dict[str, str],
    *,
    collected_at: str,
    producer_run_id: int | None = None,
    producer_run_attempt: int | None = None,
) -> dict[str, Any]:
    producer: dict[str, Any] | None = None
    if producer_run_id is not None or producer_run_attempt is not None:
        if producer_run_id is None or producer_run_attempt is None:
            raise SourceIntegrationError("producer run identity must be complete")
        producer = validate_unique_producer_run(
            api,
            contract,
            commit,
            run_id=producer_run_id,
            run_attempt=producer_run_attempt,
        )
    require_exact_default_branch_head(api, contract, commit)
    pulls = api.get_all(
        api_path(contract["repository"], f"commits/{commit}/pulls")
    )
    pull_request = select_integrating_pull_request(pulls, contract, commit)
    pull_number = pull_request["number"]
    reviews = api.get_all(
        api_path(contract["repository"], f"pulls/{pull_number}/reviews")
    )
    approvals = approved_reviews(reviews, pull_request, contract)

    runs = api.get_all(
        api_path(contract["repository"], "actions/runs"),
        collection="workflow_runs",
        query={"head_sha": commit},
    )
    run = select_hosted_ci_run(runs, contract, commit)
    jobs = api.get_all(
        api_path(contract["repository"], f"actions/runs/{run['id']}/jobs"),
        collection="jobs",
        query={"filter": "all"},
    )
    job_names = validate_hosted_jobs(jobs, contract)

    authority = {
        "schemaVersion": AUTHORITY_SCHEMA_VERSION,
        "kind": "source-integration-authority",
        "collectedAt": collected_at,
        "release": release,
        "repository": contract["repository"],
        "pullRequest": {
            "number": pull_number,
            "baseBranch": contract["defaultBranch"],
            "headCommit": pull_request["head"]["sha"],
            "mergeCommit": commit,
            "approvalCount": len(approvals),
            "approvedReviewIDs": [review["id"] for review in approvals],
        },
        "hostedCI": {
            "workflowName": contract["workflowName"],
            "workflowPath": contract["workflowPath"],
            "runID": run["id"],
            "runAttempt": run["run_attempt"],
            "event": contract["workflowEvent"],
            "headBranch": contract["defaultBranch"],
            "headCommit": commit,
            "jobs": list(job_names),
        },
    }
    if producer is not None:
        authority["producer"] = {
            "workflowName": contract["producerWorkflowName"],
            "workflowPath": contract["producerWorkflowPath"],
            "runID": producer_run_id,
            "runAttempt": producer_run_attempt,
        }
    return authority


def release_identity(version: str, build: str, commit: str) -> dict[str, str]:
    try:
        return {
            "version": release_reliability.safe_string(
                version, "release.version", release_reliability.VERSION_PATTERN
            ),
            "build": release_reliability.safe_string(
                build, "release.build", release_reliability.BUILD_PATTERN
            ),
            "commit": release_reliability.safe_string(
                commit, "release.commit", release_reliability.COMMIT_PATTERN
            ),
        }
    except release_reliability.ReliabilityError as error:
        raise SourceIntegrationError(str(error)) from error


def qualification_receipt(
    release: dict[str, str], *, collected_at: str
) -> dict[str, Any]:
    expected = tuple(
        release_reliability.QUALIFICATION_RECEIPTS["source-integration"]["proofs"]
    )
    receipt = {
        "schemaVersion": release_reliability.RECEIPT_SCHEMA_VERSION,
        "kind": "qualification",
        "scope": "source-integration",
        "collectedAt": collected_at,
        "release": release,
        "proofs": [{"id": identifier, "state": "pass"} for identifier in expected],
    }
    try:
        release_reliability.validate_qualification_receipt(
            receipt, "source integration qualification receipt"
        )
    except release_reliability.ReliabilityError as error:
        raise SourceIntegrationError(str(error)) from error
    return receipt


def exact_checkout(commit: str) -> None:
    head = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if head != commit:
        raise SourceIntegrationError("checked-out Git commit does not match release commit")
    status = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=no"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    if status:
        raise SourceIntegrationError("source integration requires a clean tracked checkout")


def prepare_output(path: Path) -> Path:
    output = path.expanduser().resolve()
    if output.exists():
        raise SourceIntegrationError(f"source integration output already exists: {output}")
    output.mkdir(parents=True, mode=0o700)
    os.chmod(output, 0o700)
    return output


def write_json(path: Path, document: dict[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def require_github_environment(
    contract: dict[str, Any]
) -> tuple[str, str, int, int]:
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise SourceIntegrationError("source integration receipt owner is GitHub Actions")
    if os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
        raise SourceIntegrationError(
            "source integration qualification requires workflow_dispatch"
        )
    if os.environ.get("GITHUB_REPOSITORY") != contract["repository"]:
        raise SourceIntegrationError("GitHub repository does not match the contract")
    expected_ref = f"refs/heads/{contract['defaultBranch']}"
    if os.environ.get("GITHUB_REF") != expected_ref:
        raise SourceIntegrationError("GitHub dispatch must run from the default branch")
    if os.environ.get("GITHUB_WORKFLOW") != contract["producerWorkflowName"]:
        raise SourceIntegrationError("GitHub workflow does not match the producer")
    token = os.environ.get("GITHUB_TOKEN", "")
    if not token:
        raise SourceIntegrationError("GITHUB_TOKEN is required")
    api_url = os.environ.get("GITHUB_API_URL", "")
    if api_url != contract["apiURL"]:
        raise SourceIntegrationError("GITHUB_API_URL does not match the contract")
    try:
        run_id = int(os.environ.get("GITHUB_RUN_ID", "0"))
        run_attempt = int(os.environ.get("GITHUB_RUN_ATTEMPT", "0"))
    except ValueError as error:
        raise SourceIntegrationError(
            "GitHub run identity must contain positive integers"
        ) from error
    exact_integer(run_id, "GITHUB_RUN_ID", minimum=1)
    exact_integer(run_attempt, "GITHUB_RUN_ATTEMPT", minimum=1)
    if run_attempt != 1:
        raise SourceIntegrationError(
            "source integration producer reruns cannot qualify unchanged source"
        )
    return api_url, token, run_id, run_attempt


def require_exact_dispatch_source(commit: str) -> None:
    if os.environ.get("GITHUB_SHA") != commit:
        raise SourceIntegrationError(
            "GitHub dispatch source does not match the release commit"
        )
    exact_checkout(commit)


def execute(args: argparse.Namespace) -> int:
    contract = load_contract()
    release = release_identity(args.version, args.build, args.commit)
    api_url, token, run_id, run_attempt = require_github_environment(contract)
    require_exact_dispatch_source(release["commit"])
    client = GitHubRESTClient(
        api_url=api_url,
        token=token,
        api_version=contract["apiVersion"],
    )
    collected_at = utc_now()
    authority = collect_authority(
        client,
        contract,
        release["commit"],
        release,
        collected_at=collected_at,
        producer_run_id=run_id,
        producer_run_attempt=run_attempt,
    )
    receipt = qualification_receipt(release, collected_at=collected_at)
    output = prepare_output(Path(args.output))
    try:
        write_json(output / "authority.json", authority)
        write_json(output / "qualification.json", receipt)
    except BaseException:
        for child in output.iterdir():
            child.unlink(missing_ok=True)
        output.rmdir()
        raise
    print(f"Source integration qualification passed -> {output}")
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--version", required=True)
    result.add_argument("--build", required=True)
    result.add_argument("--commit", required=True)
    result.add_argument("--output", required=True)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    try:
        return execute(parser().parse_args(argv))
    except (SourceIntegrationError, OSError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
