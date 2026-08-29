#!/usr/bin/env python3
"""Resolve the newest first-attempt XCUITest-verified ancestor of a PR head.

The resolver never trusts the immediately previous push by itself. A commit is
eligible only when a successful first-attempt Scoped UI run published the
workflow-owned, content-free verification artifact for that exact SHA. Any API,
shape, history, or artifact uncertainty falls back to the PR base so selection
expands rather than silently dropping evidence.
"""

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
from dataclasses import dataclass
from typing import Any, Protocol, Sequence


SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
REPOSITORY_PATTERN = re.compile(
    r"^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})/[A-Za-z0-9_.-]{1,100}$"
)
WORKFLOW_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+\.ya?ml$")
BRANCH_PATTERN = re.compile(r"^[A-Za-z0-9._/-]{1,240}$")
API_VERSION_PATTERN = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
ARTIFACT_PREFIX = "ui-verification-"
MAXIMUM_RESPONSE_BYTES = 8 * 1024 * 1024
MAXIMUM_CANDIDATE_RUNS = 30


class VerifiedBaseError(ValueError):
    """The hosted verification history is unavailable or malformed."""


class GitHubAuthority(Protocol):
    """The bounded GitHub calls used by verified-base resolution."""

    def get(self, path: str, query: dict[str, str] | None = None) -> Any:
        """Return one decoded response."""


class CommitHistory(Protocol):
    """The ancestry checks used to reject stale or force-pushed anchors."""

    def is_ancestor(self, ancestor: str, descendant: str) -> bool:
        """Return whether ancestor is reachable from descendant."""


@dataclass(frozen=True)
class Resolution:
    """One fail-safe UI selection base."""

    base: str
    anchor_found: bool
    inspected_runs: int


class GitHubRESTClient:
    """Small read-only GitHub client with bounded responses."""

    def __init__(self, *, api_url: str, token: str, api_version: str) -> None:
        if api_url != "https://api.github.com":
            raise VerifiedBaseError("GitHub API URL must be https://api.github.com")
        if not token:
            raise VerifiedBaseError("GitHub token is missing")
        if API_VERSION_PATTERN.fullmatch(api_version) is None:
            raise VerifiedBaseError("GitHub API version is invalid")
        self.api_url = api_url
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
                "User-Agent": "portavoz-ui-verified-base",
                "X-GitHub-Api-Version": self.api_version,
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                length = response.headers.get("Content-Length")
                if length is not None and int(length) > MAXIMUM_RESPONSE_BYTES:
                    raise VerifiedBaseError("GitHub response exceeds the size limit")
                payload = response.read(MAXIMUM_RESPONSE_BYTES + 1)
        except (
            urllib.error.URLError,
            http.client.HTTPException,
            OSError,
            ValueError,
        ) as error:
            raise VerifiedBaseError(
                f"GitHub request failed: {type(error).__name__}"
            ) from error
        if len(payload) > MAXIMUM_RESPONSE_BYTES:
            raise VerifiedBaseError("GitHub response exceeds the size limit")
        try:
            return json.loads(payload)
        except (json.JSONDecodeError, UnicodeError) as error:
            raise VerifiedBaseError("GitHub response is not valid JSON") from error


class GitCommitHistory:
    """Read ancestry from the complete checkout without mutating it."""

    def is_ancestor(self, ancestor: str, descendant: str) -> bool:
        try:
            result = subprocess.run(
                ["git", "merge-base", "--is-ancestor", ancestor, descendant],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise VerifiedBaseError(
                "git could not validate candidate ancestry"
            ) from error
        if result.returncode not in (0, 1):
            raise VerifiedBaseError("git could not validate candidate ancestry")
        return result.returncode == 0


def exact_sha(value: Any, label: str) -> str:
    if not isinstance(value, str) or SHA_PATTERN.fullmatch(value) is None:
        raise VerifiedBaseError(f"{label} must be a full lowercase commit SHA")
    return value


def exact_positive_integer(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise VerifiedBaseError(f"{label} must be a positive integer")
    return value


def workflow_runs(
    authority: GitHubAuthority,
    *,
    repository: str,
    workflow: str,
    branch: str,
) -> list[Any]:
    encoded_workflow = urllib.parse.quote(workflow, safe="")
    document = authority.get(
        f"/repos/{repository}/actions/workflows/{encoded_workflow}/runs",
        {
            "branch": branch,
            "event": "pull_request",
            "status": "completed",
            "per_page": str(MAXIMUM_CANDIDATE_RUNS),
            "page": "1",
        },
    )
    if not isinstance(document, dict) or not isinstance(
        document.get("workflow_runs"), list
    ):
        raise VerifiedBaseError("workflow run response shape differs")
    return document["workflow_runs"]


def has_exact_anchor(
    authority: GitHubAuthority,
    *,
    repository: str,
    run_id: int,
    commit: str,
) -> bool:
    document = authority.get(
        f"/repos/{repository}/actions/runs/{run_id}/artifacts",
        {"per_page": "100", "page": "1"},
    )
    if not isinstance(document, dict) or not isinstance(document.get("artifacts"), list):
        raise VerifiedBaseError("workflow artifact response shape differs")
    expected_name = f"{ARTIFACT_PREFIX}{commit}"
    matches = []
    for artifact in document["artifacts"]:
        if not isinstance(artifact, dict):
            raise VerifiedBaseError("workflow artifact entry is invalid")
        if artifact.get("name") == expected_name and artifact.get("expired") is False:
            matches.append(artifact)
    return len(matches) == 1


def resolve_verified_base(
    authority: GitHubAuthority,
    history: CommitHistory,
    *,
    repository: str,
    workflow: str,
    branch: str,
    head: str,
    fallback: str,
) -> Resolution:
    """Choose the newest exact artifact-backed ancestor, else the PR base."""

    exact_sha(head, "head")
    exact_sha(fallback, "fallback")
    runs = workflow_runs(
        authority,
        repository=repository,
        workflow=workflow,
        branch=branch,
    )
    inspected = 0
    for raw_run in runs[:MAXIMUM_CANDIDATE_RUNS]:
        inspected += 1
        if not isinstance(raw_run, dict):
            raise VerifiedBaseError("workflow run entry is invalid")
        candidate = raw_run.get("head_sha")
        if not isinstance(candidate, str) or SHA_PATTERN.fullmatch(candidate) is None:
            continue
        if (
            candidate == head
            or raw_run.get("conclusion") != "success"
            or raw_run.get("event") != "pull_request"
            or raw_run.get("run_attempt") != 1
        ):
            continue
        run_id = exact_positive_integer(raw_run.get("id"), "workflow run id")
        if not history.is_ancestor(fallback, candidate):
            continue
        if not history.is_ancestor(candidate, head):
            continue
        if has_exact_anchor(
            authority,
            repository=repository,
            run_id=run_id,
            commit=candidate,
        ):
            return Resolution(candidate, True, inspected)
    return Resolution(fallback, False, inspected)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--repository", required=True)
    value.add_argument("--workflow", required=True)
    value.add_argument("--branch", required=True)
    value.add_argument("--head", required=True)
    value.add_argument("--fallback", required=True)
    value.add_argument("--token-env", default="GITHUB_TOKEN")
    value.add_argument("--api-url", default="https://api.github.com")
    value.add_argument("--api-version", default="2026-03-10")
    value.add_argument("--format", choices=("plain", "github"), default="plain")
    return value


def render(resolution: Resolution, output_format: str) -> str:
    summary = (
        f"verified UI ancestor {resolution.base}"
        if resolution.anchor_found
        else f"no verified UI ancestor; fail-safe PR base {resolution.base}"
    )
    if output_format == "github":
        return "\n".join(
            (
                f"base={resolution.base}",
                f"anchor_found={'true' if resolution.anchor_found else 'false'}",
                f"inspected_runs={resolution.inspected_runs}",
                f"summary={summary}",
            )
        )
    return resolution.base


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    if REPOSITORY_PATTERN.fullmatch(arguments.repository) is None:
        print("repository must be owner/name", file=sys.stderr)
        return 2
    if WORKFLOW_PATTERN.fullmatch(arguments.workflow) is None:
        print("workflow must be a workflow filename", file=sys.stderr)
        return 2
    if BRANCH_PATTERN.fullmatch(arguments.branch) is None or ".." in arguments.branch:
        print("branch is invalid", file=sys.stderr)
        return 2
    try:
        head = exact_sha(arguments.head, "head")
        fallback = exact_sha(arguments.fallback, "fallback")
    except VerifiedBaseError as error:
        print(str(error), file=sys.stderr)
        return 2

    token = os.environ.get(arguments.token_env, "")
    try:
        authority = GitHubRESTClient(
            api_url=arguments.api_url,
            token=token,
            api_version=arguments.api_version,
        )
        resolution = resolve_verified_base(
            authority,
            GitCommitHistory(),
            repository=arguments.repository,
            workflow=arguments.workflow,
            branch=arguments.branch,
            head=head,
            fallback=fallback,
        )
    except VerifiedBaseError as error:
        print(
            "::warning title=UI verified-base fallback::"
            f"{str(error).replace('%', '%25').replace(chr(10), '%0A')}"
        )
        resolution = Resolution(fallback, False, 0)
    print(render(resolution, arguments.format))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
