#!/usr/bin/env python3
"""Run positive and deliberately failing UI controls against the real test base.

This is a harness qualification, not a product UI pass or permission test. All
apps, effects and data are synthetic; no system prompt is requested or answered.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import tempfile
import time

from ui_test_execution import classify


ROOT = Path(__file__).resolve().parents[1]
SHARED = Path("/private/tmp/portavoz-ui-tests")
SOURCE_PATHS = (
    "Tests/PortavozUITests/PortavozUITestCase.swift",
    "Tests/PortavozUITests/UITestStorageSupport.swift",
    "Tests/PortavozUITests/UITestWaitSupport.swift",
    "Tests/PortavozUITests/UITestScrollSupport.swift",
    "Tests/Support/UITestScratch.swift",
)
CASES = {
    "testUninterruptedActionAndTeardown": {"target"},
    "testSyntheticChoiceIsObservable": {"choice"},
    "testSynchronousInterruption": set(),
    "testAsynchronousInterruption": set(),
}


def source_hashes() -> dict[str, str]:
    paths = [ROOT / path for path in SOURCE_PATHS]
    paths += sorted((ROOT / "Tests/UIInterruptionFixtures").rglob("*.swift"))
    paths.append(ROOT / "Tests/UIInterruptionFixtures/project.yml")
    paths += [Path(__file__), ROOT / "scripts/ui_test_execution.py", ROOT / "packaging/portavoz-uitests.entitlements"]
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


def command(args: list[str], log: Path, *, environment: dict[str, str], timeout: int) -> int:
    with log.open("xb") as stream:
        return subprocess.run(args, cwd=ROOT, env=environment, stdout=stream,
                              stderr=subprocess.STDOUT, timeout=timeout, check=False).returncode


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def validate_case(name: str, code: int, log: bytes, summary: dict, effects: set[str]) -> None:
    negative = not CASES[name]
    # A helper can vanish by trapping before its parent-exit callback runs.
    # Require that callback's own acknowledgement, not just process absence.
    expected = CASES[name] | ({"overlay-owner-exit"} if name != "testUninterruptedActionAndTeardown" else set())
    require(effects == expected, f"{name}: unexpected or missing synthetic action/lifecycle effect")
    require(summary.get("totalTestCount") == 1 and summary.get("skippedTests") == 0,
            f"{name}: expected exactly one executed case, not a restarted empty suite")
    if negative:
        require(code != 0 and summary.get("failedTests") == 1 and summary.get("passedTests") == 0,
                f"{name}: the interruption must remain a failed invocation")
        require(b"FIXTURE_INTERRUPTION_READY" in log, f"{name}: the controlled window was not ready")
        require(b"PORTAVOZ_UI_INTERRUPTION_BLOCKED cleanup=complete" in log,
                f"{name}: the real guard did not finish owned cleanup")
        require(classify(exit_status=code, result_bundle_present=True, runtime_receipt_present=True,
                         runtime_cases=1, log=log)[0] == "evidence-failure",
                f"{name}: an interruption cannot qualify as product evidence")
    else:
        require(code == 0 and summary.get("passedTests") == 1 and summary.get("failedTests") == 0,
                f"{name}: positive control did not pass")
        require(b"PORTAVOZ_UI_INTERRUPTION_BLOCKED" not in log, f"{name}: positive control was interrupted")
    for forbidden in (b"FIXTURE_FALLBACK_REACHED", b"FIXTURE_TARGET_CONTINUED", b"cleanup=failed"):
        require(forbidden not in log, f"{name}: fallback, continuation or failed cleanup observed")
    scratch = re.findall(rb"^FIXTURE_SCRATCH=(.+)$", log, re.MULTILINE)
    require(len(scratch) == 1, f"{name}: missing or duplicate owned scratch receipt")
    path = Path(os.fsdecode(scratch[0]))
    require(path.parent.parent == SHARED and path.parent.name.startswith("portavoz-ui-"),
            f"{name}: unexpected scratch boundary")
    require(not path.parent.exists(), f"{name}: owned scratch survived cleanup")


def wait_for_owned_apps_to_exit(products: Path) -> None:
    deadline = time.monotonic() + 10
    while True:
        rows = subprocess.check_output(["ps", "-axo", "comm="], text=True).splitlines()
        owned = [row for row in rows if "Interruption" in row and Path(row.strip()).resolve().is_relative_to(products)]
        if not owned:
            return
        require(time.monotonic() < deadline, "owned fixture process survived teardown; no process was killed")
        time.sleep(0.1)


def run(output: Path) -> None:
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    before = source_hashes()
    environment = dict(os.environ)
    environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    require(command(["xcodegen", "generate", "--spec", str(ROOT / "Tests/UIInterruptionFixtures/project.yml"),
                     "--project", str(output)], output / "generate.log", environment=environment, timeout=60) == 0,
            "fixture project generation failed")
    common = ["-project", str(output / "InterruptionProof.xcodeproj"), "-scheme", "InterruptionProof",
              "-destination", f"platform=macOS,arch={platform.machine()}", "-derivedDataPath", str(output / "build")]
    build_started = time.monotonic()
    require(command(["xcodebuild", "build-for-testing", *common, "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES",
                     f"PORTAVOZ_UI_FIXTURE_ENTITLEMENTS={ROOT / 'packaging/portavoz-uitests.entitlements'}"],
                    output / "build.log", environment=environment, timeout=600) == 0, "strict fixture build failed")
    build_seconds = time.monotonic() - build_started
    SHARED.mkdir(mode=0o700, exist_ok=True)
    info = SHARED.lstat()
    require(stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700 and info.st_uid == os.getuid(),
            "unsafe synthetic fixture shared base")
    products = (output / "build/Build/Products/Debug").resolve()
    environment["TEST_RUNNER_PROOF_OVERLAY_EXECUTABLE"] = str(products / "InterruptionOverlay.app/Contents/MacOS/InterruptionOverlay")
    receipts = []
    with tempfile.TemporaryDirectory(prefix="interruption-effects-", dir=SHARED) as owned:
        for name in CASES:
            require(command(["python3", "scripts/check-ui-test-host.py"], output / f"{name}-preflight.log",
                            environment=environment, timeout=90) == 0, "host preflight failed; no UI control started")
            effects = Path(owned) / name
            effects.mkdir(mode=0o700)
            environment["TEST_RUNNER_PROOF_EFFECTS_ROOT"] = str(effects)
            result = output / f"{name}.xcresult"
            log = output / f"{name}.log"
            started = time.monotonic()
            code = command(["xcodebuild", "test-without-building", *common, "-parallel-testing-enabled", "NO",
                            "-only-testing:InterruptionProofTests/InterruptionSafetyTests/" + name,
                            "-resultBundlePath", str(result)], log, environment=environment, timeout=180)
            (output / f"{name}.exit").write_text(f"{code}\n", encoding="utf-8")
            summary = json.loads(subprocess.check_output(
                ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result), "--format", "json"],
                env=environment, timeout=30))
            wait_for_owned_apps_to_exit(products)
            observed = {path.name for path in effects.iterdir()}
            (output / f"{name}-effects.json").write_text(json.dumps(sorted(observed)) + "\n", encoding="utf-8")
            validate_case(name, code, log.read_bytes(), summary, observed)
            receipts.append({"case": name, "invocationExitCode": code, "expectedFailure": not CASES[name],
                             "effects": sorted(observed), "ownedCleanup": "complete",
                             "invocationWallSeconds": time.monotonic() - started})
            print(f"{name}: {'expected failure retained' if not CASES[name] else 'positive control passed'}", flush=True)
    require(source_hashes() == before, "sources changed during fixture qualification")
    (output / "qualification.json").write_text(json.dumps(
        {"schemaVersion": 1, "scope": "synthetic-interruption-harness-only", "sourceSHA256": before,
         "buildWallSeconds": build_seconds, "cases": receipts}, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New private output directory; never overwrites evidence")
    run(parser.parse_args().output.resolve())
