#!/usr/bin/env python3
"""Attest complete nightly evidence and resolve its exact-SHA freshness anchor."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys

from ui_test_verification_anchor import write_new
from ui_test_verified_base import (
    GitHubRESTClient, REPOSITORY_PATTERN, VerifiedBaseError, exact_positive_integer,
    exact_sha,
)

PREFIX = "nightly-ui-verification-"
SHARDS = (1, 2, 3)


def verified_run(authority, *, repository: str, commit: str) -> int | None:
    """A workflow-owned artifact attests all shards and required controls.

    Success, including advisory and skipped runs, cannot attest verification.
    Search bounded history so a skip can reuse the original unexpired artifact
    without copying it or renewing its retention. Uncertainty retries the suite.
    """
    exact_sha(commit, "commit")
    if REPOSITORY_PATTERN.fullmatch(repository) is None:
        raise VerifiedBaseError("repository is invalid")
    document = authority.get(
        f"/repos/{repository}/actions/workflows/ui-nightly.yml/runs",
        {"branch": "main", "status": "success", "head_sha": commit, "per_page": "30"},
    )
    if not isinstance(document, dict) or not isinstance(document.get("workflow_runs"), list):
        raise VerifiedBaseError("nightly runs are unavailable")
    for run in document["workflow_runs"][:30]:
        if not isinstance(run, dict):
            raise VerifiedBaseError("nightly run is invalid")
        if (run.get("head_sha") != commit or run.get("head_branch") != "main"
                or run.get("conclusion") != "success" or run.get("run_attempt") != 1
                or run.get("event") not in ("schedule", "workflow_dispatch")):
            continue
        run_id = exact_positive_integer(run.get("id"), "nightly run ID")
        artifacts = authority.get(
            f"/repos/{repository}/actions/runs/{run_id}/artifacts",
            {"per_page": "100", "page": "1"},
        )
        if not isinstance(artifacts, dict) or not isinstance(artifacts.get("artifacts"), list):
            raise VerifiedBaseError("nightly artifacts are unavailable")
        matches = [item for item in artifacts["artifacts"] if isinstance(item, dict)
                   and item.get("name") == PREFIX + commit and item.get("expired") is False]
        if len(matches) == 1:
            return run_id
    return None


def qualify(*, commit: str, results: Path, build: str, controls: str,
            shards: str, attempt: int) -> bool:
    """Keep known infrastructure advisory, but never certify absent evidence."""
    exact_sha(commit, "commit")
    if attempt != 1 or (build, controls, shards) != ("success",) * 3:
        raise ValueError("nightly prerequisites or first attempt did not complete")
    verified = True
    for shard in SHARDS:
        try:
            document = json.loads((results / f"{shard}.json").read_text())
        except (OSError, ValueError) as error:
            raise ValueError(f"shard {shard} evidence is unavailable") from error
        if (not isinstance(document, dict) or document.get("commit") != commit
                or type(document.get("shard")) is not int or document["shard"] != shard
                or type(document.get("verified")) is not bool):
            raise ValueError(f"shard {shard} evidence identity is invalid")
        classification = (document.get("state"), document["verified"])
        if classification == ("infrastructure-advisory", False):
            verified = False
        elif classification != ("passed", True):
            raise ValueError(f"shard {shard} classification is missing or contradictory")
    return verified


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    freshness = commands.add_parser("freshness")
    freshness.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    freshness.add_argument("--commit", required=True)
    freshness.add_argument("--require-verified", action="store_true")
    shard = commands.add_parser("shard")
    shard.add_argument("--commit", required=True)
    shard.add_argument("--shard", required=True, type=int, choices=SHARDS)
    shard.add_argument("--verified", required=True, choices=("true", "false"))
    shard.add_argument("--state", required=True)
    shard.add_argument("--output", required=True, type=Path)
    verify = commands.add_parser("verify")
    verify.add_argument("--commit", required=True)
    verify.add_argument("--results", required=True, type=Path)
    for prerequisite in ("build", "controls", "shards"):
        verify.add_argument(f"--{prerequisite}", required=True)
    verify.add_argument("--attempt", required=True, type=int)
    verify.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        exact_sha(args.commit, "commit")
        if args.command == "freshness":
            run_id = None
            try:
                authority = GitHubRESTClient(api_url="https://api.github.com",
                    token=os.environ.get("GH_TOKEN", ""), api_version="2022-11-28")
                run_id = verified_run(authority, repository=args.repository, commit=args.commit)
            except VerifiedBaseError as error:
                print(f"Nightly evidence unavailable; retry required: {error}", file=sys.stderr)
            print(f"run={'false' if run_id else 'true'}")
            print(f"verified_run={run_id or ''}")
            return int(args.require_verified and run_id is None)
        if args.command == "shard":
            document = dict(commit=args.commit, shard=args.shard,
                            verified=args.verified == "true", state=args.state)
        else:
            verified = qualify(commit=args.commit, results=args.results, build=args.build,
                               controls=args.controls, shards=args.shards, attempt=args.attempt)
            if os.environ.get("GITHUB_OUTPUT"):
                with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                    output.write(f"verified={str(verified).lower()}\n")
            if not verified:
                print("::warning::Nightly infrastructure advisory: no verification anchor; retry required.")
                return 0
            document = dict(schemaVersion=1, kind="nightly-ui-verification", commit=args.commit,
                            shards=list(SHARDS), verified=True, interruptionControls="success")
        write_new(args.output, (json.dumps(document, sort_keys=True) + "\n").encode())
    except (OSError, ValueError) as error:
        print(f"Nightly verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
