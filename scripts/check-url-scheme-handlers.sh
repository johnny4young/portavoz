#!/usr/bin/env bash
# Reports stale LaunchServices claimants of the portavoz: scheme.
#
# `AutomationUITests.testRecordURLRoutesIntoAVisibleRecording` asserts that the
# disposable test host — not some other build — receives an external
# `portavoz://record`. Every build product that ever registered stays in the
# LaunchServices database, including temp copies whose paths are long gone, and
# resolution can land on one of them. The launch then fails silently and the
# test reports whichever app happened to be frontmost, which reads as a code
# regression and is not one.
#
# Diagnostic only: rebuilding the database is a system-wide action with its own
# side effects, so this names the problem and leaves the decision to the user.
set -euo pipefail

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -x "$lsregister" ]] || exit 0

"$lsregister" -dump 2>/dev/null | python3 -c '
import os, sys

blocks = sys.stdin.read().split("-" * 56)
stale = [
    path
    for block in blocks
    if "portavoz:" in block
    for line in block.splitlines()
    if line.strip().startswith("path:")
    for path in [line.split("path:", 1)[1].strip().split(" (0x")[0]]
    if not os.path.exists(path)
]
if not stale:
    sys.exit(0)
print(f"⚠️  {len(stale)} stale LaunchServices claimant(s) of portavoz: point at")
print("   paths that no longer exist. An external-route test can resolve to one")
print("   of them and fail for a reason that is not in this repository.")
for path in stale[:3]:
    print(f"     {path}")
if len(stale) > 3:
    print(f"     … and {len(stale) - 3} more")
print("   To clear them (system-wide, takes a while, resets Open With):")
print("     /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user")
' || true
