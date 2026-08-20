#!/usr/bin/env python3
"""Run one source-bound segment versus one declared Ask retrieval candidate."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SAFE_BUILD = re.compile(r"^[A-Za-z0-9.+_-]{1,80}$")
OUTCOMES = {"candidate-parity", "blocked"}
CANDIDATES = {"speaker-turn", "conversation-window"}
SEGMENT_ADAPTER = "local-hybrid-preindexed-segment-no-expansion-evidence-v3"
CANDIDATE_ADAPTERS = {
    "speaker-turn": (
        "local-hybrid-preindexed-speaker-turn-v1-no-expansion-evidence-v1"
    ),
    "conversation-window": (
        "local-hybrid-preindexed-conversation-window-v1-no-expansion-evidence-v1"
    ),
}


class AskQualityPairError(ValueError):
    """A fail-closed paired-run contract violation."""


def run_command(command: list[str], root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=root,
        check=False,
        capture_output=True,
        text=True,
    )


def require_command(
    command: list[str],
    root: Path,
    label: str,
    accepted: tuple[int, ...] = (0,),
    runner=run_command,
) -> subprocess.CompletedProcess[str]:
    result = runner(command, root)
    if result.returncode not in accepted:
        detail = result.stderr.strip() or result.stdout.strip() or "no diagnostic"
        raise AskQualityPairError(f"{label} failed: {detail}")
    return result


def ensure_private_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise AskQualityPairError(f"{label} did not publish its output")
    path.chmod(0o600)


def is_within(path: Path, directory: Path) -> bool:
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def collect_pair(
    root: Path,
    fixture: Path,
    output: Path,
    build: str,
    candidate: str = "speaker-turn",
    runner=run_command,
) -> tuple[int, Path]:
    root = root.resolve()
    fixture = fixture.expanduser().resolve()
    output = output.expanduser().resolve()
    if not SAFE_BUILD.fullmatch(build):
        raise AskQualityPairError("build must be a bounded receipt-safe identifier")
    if candidate not in CANDIDATES:
        raise AskQualityPairError(f"unsupported candidate: {candidate}")
    if not fixture.is_file():
        raise AskQualityPairError(f"fixture not found: {fixture}")
    if output.exists():
        raise AskQualityPairError(f"output already exists: {output}")

    status = require_command(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        root,
        "worktree inspection",
        runner=runner,
    )
    if status.stdout.strip():
        raise AskQualityPairError(
            "the worktree must be clean so both candidates match one commit"
        )
    commit = require_command(
        ["git", "rev-parse", "HEAD"],
        root,
        "commit inspection",
        runner=runner,
    ).stdout.strip()
    if not COMMIT.fullmatch(commit):
        raise AskQualityPairError("git did not return one full lowercase commit SHA")

    if is_within(output, root):
        ignored = runner(
            ["git", "check-ignore", "--quiet", str(output)],
            root,
        )
        if ignored.returncode != 0:
            raise AskQualityPairError(
                "repository-local output must be covered by .gitignore"
            )

    quality = root / "scripts" / "ask_quality.py"
    require_command(
        [sys.executable, str(quality), "verify-public", "--fixture", str(fixture)],
        root,
        "canonical fixture verification",
        runner=runner,
    )
    require_command(
        ["swift", "build", "-c", "release", "--product", "portavoz-cli"],
        root,
        "Release CLI build",
        runner=runner,
    )
    cli = root / ".build" / "release" / "portavoz-cli"
    if not cli.is_file():
        raise AskQualityPairError("Release CLI build did not publish portavoz-cli")

    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = output.parent / f".{output.name}.lock"
    lock_descriptor = None
    staging = None
    try:
        try:
            lock_descriptor = os.open(
                lock,
                os.O_CREAT | os.O_EXCL | os.O_WRONLY,
                0o600,
            )
        except FileExistsError as error:
            raise AskQualityPairError(
                f"output is reserved by another run: {output}"
            ) from error
        staging = Path(
            tempfile.mkdtemp(
                prefix=f".{output.name}.partial.",
                dir=output.parent,
            )
        )
        staging.chmod(0o700)

        artifacts = {
            "segment_observations": staging / "segment-observations.json",
            "segment_scorecard": staging / "segment-scorecard.json",
            "candidate_observations": staging / f"{candidate}-observations.json",
            "candidate_scorecard": staging / f"{candidate}-scorecard.json",
            "comparison": staging / "comparison.json",
        }
        for unit, key in (
            ("segment", "segment_observations"),
            (candidate, "candidate_observations"),
        ):
            require_command(
                [
                    str(cli),
                    "bench-ask-quality",
                    "--fixture",
                    str(fixture),
                    "--output",
                    str(artifacts[key]),
                    "--build",
                    build,
                    "--commit",
                    commit,
                    "--retrieval-unit",
                    unit,
                    "--asset-download",
                    "never",
                ],
                root,
                f"{unit} observation",
                runner=runner,
            )
            ensure_private_file(artifacts[key], f"{unit} observation")

        for observation_key, scorecard_key, label in (
            ("segment_observations", "segment_scorecard", "segment"),
            ("candidate_observations", "candidate_scorecard", candidate),
        ):
            require_command(
                [
                    sys.executable,
                    str(quality),
                    "evaluate",
                    "--fixture",
                    str(fixture),
                    "--observations",
                    str(artifacts[observation_key]),
                    "--output",
                    str(artifacts[scorecard_key]),
                ],
                root,
                f"{label} evaluation",
                accepted=(0, 1),
                runner=runner,
            )
            ensure_private_file(artifacts[scorecard_key], f"{label} evaluation")

        comparison_result = require_command(
            [
                sys.executable,
                str(quality),
                "compare",
                "--fixture",
                str(fixture),
                "--control",
                str(artifacts["segment_scorecard"]),
                "--candidate",
                str(artifacts["candidate_scorecard"]),
                "--output",
                str(artifacts["comparison"]),
            ],
            root,
            "paired comparison",
            accepted=(0, 1),
            runner=runner,
        )
        ensure_private_file(artifacts["comparison"], "paired comparison")
        try:
            comparison = json.loads(artifacts["comparison"].read_text(encoding="utf-8"))
            outcome = comparison["outcome"]
            subject = comparison["subject"]
        except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as error:
            raise AskQualityPairError("paired comparison receipt is malformed") from error
        if outcome not in OUTCOMES:
            raise AskQualityPairError("paired comparison receipt has an invalid outcome")
        if not isinstance(subject, dict):
            raise AskQualityPairError("paired comparison receipt is malformed")
        if subject.get("build") != build or subject.get("commit") != commit:
            raise AskQualityPairError("paired comparison receipt lost source identity")
        if (
            subject.get("controlAdapter") != SEGMENT_ADAPTER
            or subject.get("candidateAdapter") != CANDIDATE_ADAPTERS[candidate]
        ):
            raise AskQualityPairError(
                "paired comparison receipt lost selected adapter identity"
            )
        expected_code = 0 if outcome == "candidate-parity" else 1
        if comparison_result.returncode != expected_code:
            raise AskQualityPairError("paired comparison exit status contradicts its receipt")

        if output.exists():
            raise AskQualityPairError(f"output already exists: {output}")
        os.rename(staging, output)
        staging = None
        return expected_code, output / "comparison.json"
    finally:
        if lock_descriptor is not None:
            os.close(lock_descriptor)
        try:
            lock.unlink(missing_ok=True)
        except OSError:
            pass
        if staging is not None:
            shutil.rmtree(staging, ignore_errors=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--candidate", default="speaker-turn")
    return parser


def main(arguments: list[str] | None = None) -> int:
    args = build_parser().parse_args(arguments)
    try:
        status, receipt = collect_pair(
            ROOT,
            Path(args.fixture),
            Path(args.output),
            args.build,
            candidate=args.candidate,
        )
    except AskQualityPairError as error:
        print(f"ask-quality-pair error: {error}", file=sys.stderr)
        return 64
    print(f"Ask quality comparison: {receipt}")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
