#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${PORTAVOZ_RELEASE_VERSION:-}"
BUILD="${PORTAVOZ_RELEASE_BUILD:-}"
OUTPUT="${PORTAVOZ_RELIABILITY_RECEIPT:-$ROOT/dist/release-readiness/deterministic.json}"
LANGUAGE_FILTER='CaptionCoalescerTests|CaptionCoalescerNoiseTests|CaptionCoalescerOverlapTests|MicBleedFilterTests|LiveCaptionParagraphProjectorTests|LiveTranslationRoutingTests|LiveTranslationStateTests|LiveTranslationWakeHubTests|LiveTranslationWakeIntegrationTests|TurnEndpointPolicyTests|LiveCompanionWorkCoordinatorTests|LiveSummaryWorkCoordinatorTests|LiveSummaryWindowPolicyTests|SpokenLanguageDetectorTests|ModelCatalogTests|RefineMeetingUseCaseTests|SemanticCorpusIndexingTests|SemanticCorpusIndexingCoordinatorTests'
UI_TESTS='PortavozUITests/LibraryUITests/testRecordingWarnsWhenRemoteAudioCallbacksStop PortavozUITests/LibraryUITests/testRecordingWarnsWhenIncomingAudioClips PortavozUITests/LibraryUITests/testColdRecordingStartsLiveCaptionsWhenModelBecomesReady PortavozUITests/LibraryUITests/testLiveTranscriptYieldsFollowWhileReadingHistory PortavozUITests/LibraryUITests/testLiveTranslationUsesADistinctLabeledRail PortavozUITests/MeetingDetailUITests/testRunningRefineCanBeCanceledWithoutChangingTheTranscript PortavozUITests/SettingsUITests/testCategoryNavigationRevealsEachPane'

usage() {
  cat <<'EOF'
Usage: PORTAVOZ_RELEASE_VERSION=<version> PORTAVOZ_RELEASE_BUILD=<build> \
  scripts/run-release-reliability-gates.sh

Runs the deterministic release reliability gates and writes a content-free
receipt only after every command succeeds. Optional:
  PORTAVOZ_RELIABILITY_RECEIPT=/path/to/deterministic.json
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 0 ]]; then
  usage >&2
  exit 64
fi
if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "error: PORTAVOZ_RELEASE_VERSION and PORTAVOZ_RELEASE_BUILD are required" >&2
  exit 64
fi

cd "$ROOT"
if [[ -z "${DEVELOPER_DIR:-}" \
  && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
scripts/check-repository-hygiene.sh
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint lint --strict --no-cache
PORTAVOZ_STRESS_MINIMUM_TESTS=108 make test-recording-stress
swift test --filter "$LANGUAGE_FILTER"
make test-ui-scoped UI_TESTS="$UI_TESTS" UI_TEST_LOCALES="en es"

python3 scripts/release_reliability.py record-deterministic \
  --version "$VERSION" \
  --build "$BUILD" \
  --commit "$(git rev-parse HEAD)" \
  --output "$OUTPUT"
