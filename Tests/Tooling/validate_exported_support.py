"""Exercise real consumers with the unmodified AppServices export from Swift."""

import importlib.util
import json
import plistlib
import sys
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]


def main():
    report_path = Path(sys.argv[1])
    report = json.loads(report_path.read_text())
    spec = importlib.util.spec_from_file_location(
        "collect_field_evidence", REPOSITORY / "scripts/collect-field-evidence.py")
    collector = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(collector)
    reliability_spec = importlib.util.spec_from_file_location(
        "release_reliability", REPOSITORY / "scripts/release_reliability.py")
    reliability = importlib.util.module_from_spec(reliability_spec)
    reliability_spec.loader.exec_module(reliability)

    # A metadata-only synthetic Dev bundle, never an installed application.
    app = report_path.parent / "Portavoz Dev.app"
    info = app / "Contents/Info.plist"
    info.parent.mkdir(parents=True)
    with info.open("wb") as handle:
        plistlib.dump({
            "CFBundleIdentifier": "app.portavoz.mac.dev",
            "CFBundleShortVersionString": report["environment"]["appVersion"],
            "CFBundleVersion": report["environment"]["buildVersion"],
        }, handle)
    output = report_path.parent / "evidence"
    result = collector.main([
        "--fixture", "model-cold-start", "--report", str(report_path),
        "--meeting-reference", report["meetings"][0]["reference"],
        "--app", str(app), "--output", str(output),
    ])
    if result:
        return result
    manifest = json.loads((output / "manifest.json").read_text())
    actual = json.loads((output / "support-before-refine.json").read_text())
    assert actual == report, "Collection must not discard the host snapshot"
    validated = reliability.validate_field_manifest(manifest, "synthetic export")
    assert validated["outcome"] == "not-observed", "Synthetic export is not field qualification"
    print("support-roundtrip=validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
