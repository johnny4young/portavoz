#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

selectors='PortavozUITests/PublicShowcaseUITests/testMeetingDetailShowcase PortavozUITests/PublicShowcaseUITests/testLiveTranslationShowcase PortavozUITests/PublicShowcaseUITests/testInsightsShowcase'

make --no-print-directory test-ui-scoped \
	UI_TESTS="$selectors" \
	UI_TEST_LOCALES="en"

result_bundle="dist/ui-test-results/en.xcresult"
[ -d "$result_bundle" ] || {
	printf '✗ missing screenshot result bundle: %s\n' "$result_bundle" >&2
	exit 1
}

export_dir="$(mktemp -d "${TMPDIR:-/tmp}/portavoz-public-screenshots.XXXXXX")"
trap 'rm -rf "$export_dir"' EXIT

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
	xcrun xcresulttool export attachments \
	--path "$result_bundle" \
	--output-path "$export_dir"

python3 - "$export_dir" <<'PY'
import json
import pathlib
import shutil
import sys

export_dir = pathlib.Path(sys.argv[1])
manifest = json.loads((export_dir / "manifest.json").read_text())
expected = {
    "public-meeting-detail": "meeting-detail.png",
    "public-live-translation": "recording-live-translation.png",
    "public-insights": "insights.png",
}
found: dict[str, pathlib.Path] = {}

for test in manifest:
    for attachment in test.get("attachments", []):
        suggested = attachment.get("suggestedHumanReadableName", "")
        for prefix in expected:
            if suggested.startswith(prefix + "_"):
                found[prefix] = export_dir / attachment["exportedFileName"]

missing = sorted(set(expected) - set(found))
if missing:
    raise SystemExit(f"missing public screenshot attachments: {', '.join(missing)}")

for prefix, destination_name in expected.items():
    source = found[prefix]
    for destination_root in (
        pathlib.Path("assets/screenshots"),
        pathlib.Path("site/assets/screenshots"),
    ):
        destination_root.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination_root / destination_name)
        print(f"✓ {destination_root / destination_name}")
PY

rm -f \
	assets/screenshots/recording-companion.png \
	site/assets/screenshots/recording-companion.png

printf '✓ public screenshots regenerated from disposable XCUITest fixtures\n'
