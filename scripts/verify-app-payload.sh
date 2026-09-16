#!/bin/bash
# Verifies that an installed app can actually read and resolve its own payload.
#
# A staged resource bundle that keeps build-time owner-only modes, or that the
# generated SwiftPM accessor can only find through the build machine's absolute
# path, passes signing, notarization and Gatekeeper and then ends the app at a
# user's first recording. Both states fail here instead.
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "Usage: scripts/verify-app-payload.sh <Portavoz.app>" >&2
  exit 64
fi

UNREADABLE="$(find "$APP" ! -perm -o+r -o -type d ! -perm -o+x | head -5)"
if [[ -n "$UNREADABLE" ]]; then
  echo "Payload entries the installing user cannot read:" >&2
  # Paths inside the app are public product structure, not user data.
  printf '%s\n' "$UNREADABLE" >&2
  exit 65
fi

CLASSIFIER="$APP/Contents/Resources/Portavoz_IntelligenceKit.bundle"
if [[ ! -d "$CLASSIFIER/PortavozLiveQuestionClassifier.mlmodelc" ]]; then
  echo "The app is missing its staged Apuntador question classifier." >&2
  exit 65
fi

# The app itself reports which bundle it resolved. Anything outside this copy
# means the install depends on the build machine's directories.
if ! STATUS="$("$APP/Contents/MacOS/portavoz-app" --bundled-assets-status)"; then
  echo "The app could not resolve its bundled assets:" >&2
  printf '%s\n' "$STATUS" >&2
  exit 65
fi
RESOLVED="$(printf '%s\n' "$STATUS" | sed -n 's/^classifierBundle=//p')"
REAL_APP="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$APP")"
REAL_RESOLVED="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${RESOLVED:-/nonexistent}")"
if [[ "$REAL_RESOLVED" != "$REAL_APP/"* ]]; then
  echo "The app resolved its classifier outside its own payload: $RESOLVED" >&2
  exit 65
fi
if ! printf '%s\n' "$STATUS" | grep -q '^classifierLoadable=true$'; then
  echo "The app resolved its classifier bundle but could not load the model." >&2
  exit 65
fi

echo "OK → $APP reads its own payload and resolves its bundled classifier."
