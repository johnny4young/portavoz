#!/usr/bin/env python3
"""The XCUITest host built from SwiftPM: its Info.plist, its place in the xctestrun and the lane's capture format."""

import argparse
import json
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNNER_TARGET = "PortavozUITests"
HOST_IDENTIFIER_KEY = "PRODUCT_BUNDLE_IDENTIFIER"
RUNNER_TARGETS = frozenset({RUNNER_TARGET})
RUNNER_TARGET_KEYS = ("sources", "type", "platform", "deploymentTarget", "settings")
FORBIDDEN_HOST_KEYS = ("CFBundleDocumentTypes", "SUFeedURL", "SUEnableAutomaticChecks", "SUPublicEDKey")
HOST_IN_TEST_ROOT = "__TESTROOT__/Debug/Portavoz.app"
# xcodebuild maps __TESTROOT__ here inside an xctestproducts bundle.
HOST_IN_PRODUCTS = "Binaries/0/Debug/Portavoz.app"


def parsed_spec(path: Path) -> dict:
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory) / "project.json"
        subprocess.run(
            ["xcodegen", "dump", "--spec", str(path),
             "--type", "json", "--no-env", "--quiet", "--file", str(output)],
            check=True, capture_output=True, text=True, timeout=30,
        )
        return json.loads(output.read_text(encoding="utf-8"))


def project_spec(root: Path = ROOT) -> dict:
    return parsed_spec(root / "project.yml")


def runner_spec(root: Path = ROOT) -> dict:
    return parsed_spec(root / "project-ui-runner.yml")


def contract_problems(project: dict, runner: dict) -> list[str]:
    """Why the runner would not build what nightly proves, or the host would act like the shipping app."""
    problems = []
    extra = sorted(set(runner["targets"]) - RUNNER_TARGETS)
    if extra:
        problems.append(f"the runner must have no app target: {', '.join(extra)}")
    if runner.get("packages"):
        problems.append("the runner must link no package")
    if runner["settings"] != project["settings"]:
        problems.append("the shared settings differ")
    problems += [f"{name} differs in {key}" for name in sorted(RUNNER_TARGETS) for key in RUNNER_TARGET_KEYS
                 if runner["targets"][name][key] != project["targets"][name][key]]
    plist = info_plist(project)
    problems += [f"the host must not declare {key}" for key in FORBIDDEN_HOST_KEYS if key in plist]
    return problems


def info_plist(project: dict) -> dict:
    """project.yml's disposable app properties, plus what Xcode would have added to them."""
    target = project["targets"]["Portavoz"]
    settings = project["settings"]["base"]
    return {
        **target["info"]["properties"],
        "CFBundleExecutable": "Portavoz",
        "CFBundleIdentifier": target["settings"]["base"][HOST_IDENTIFIER_KEY],
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Portavoz",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": settings["MARKETING_VERSION"],
        "CFBundleVersion": settings["CURRENT_PROJECT_VERSION"],
        "LSMinimumSystemVersion": target["deploymentTarget"],
    }


def inject_host(run: dict, identifier: str) -> dict:
    """Make the prebuilt host the runner's target app, as if the project had built it, and capture no video."""
    target = run[RUNNER_TARGET]
    target.pop("UseUITargetAppProvidedByTests", None)
    target["UITargetAppPath"] = HOST_IN_TEST_ROOT
    target["PreferredScreenCaptureFormat"] = "screenshots"
    target.setdefault("DependentProductPaths", []).insert(0, HOST_IN_TEST_ROOT)
    target.setdefault("BundleIdentifiersForCrashReportEmphasis", []).append(identifier)
    return run


def inject_products(products: Path, identifier: str) -> Path:
    runs = list(products.rglob("*.xctestrun"))
    if len(runs) != 1:
        raise SystemExit(f"Expected exactly one xctestrun in {products}, found {len(runs)}")
    if not (products / HOST_IN_PRODUCTS / "Contents/MacOS/Portavoz").is_file():
        raise SystemExit(f"The host is not where {HOST_IN_TEST_ROOT} resolves: {products / HOST_IN_PRODUCTS}")
    runs[0].write_bytes(plistlib.dumps(inject_host(plistlib.loads(runs[0].read_bytes()), identifier)))
    return runs[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("info-plist").add_argument("output", type=Path)
    commands.add_parser("host-path").add_argument("products", type=Path)
    commands.add_parser("inject").add_argument("products", type=Path)
    commands.add_parser("verify")
    args = parser.parse_args()
    if args.command == "host-path":
        print(args.products / HOST_IN_PRODUCTS)
        return 0
    project = project_spec()
    if args.command == "verify":
        problems = contract_problems(project, runner_spec())
        for problem in problems:
            print(f"UI host contract: {problem}", file=sys.stderr)
        return 1 if problems else 0
    if args.command == "info-plist":
        args.output.write_bytes(plistlib.dumps(info_plist(project)))
    else:
        identifier = project["targets"]["Portavoz"]["settings"]["base"][HOST_IDENTIFIER_KEY]
        print(f"Injected the host into {inject_products(args.products, identifier)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
