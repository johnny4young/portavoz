#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${PORTAVOZ_RELEASE_VERSION:-}"
BUILD="${PORTAVOZ_RELEASE_BUILD:-}"
OUTPUT="${PORTAVOZ_RELIABILITY_RECEIPT:-$ROOT/dist/release-readiness/deterministic.json}"
LANGUAGE_FILTER='CaptionCoalescerTests|CaptionCoalescerNoiseTests|CaptionCoalescerOverlapTests|MicBleedFilterTests|LiveCaptionParagraphProjectorTests|LiveTranslationRoutingTests|LiveTranslationStateTests|LiveTranslationWakeHubTests|LiveTranslationWakeIntegrationTests|TurnEndpointPolicyTests|LiveCompanionWorkCoordinatorTests|LiveSummaryWorkCoordinatorTests|LiveSummaryWindowPolicyTests|ProactiveMeetingAssistPolicyTests|RecordingProactiveAssistModelTests|SpokenLanguageDetectorTests|ModelCatalogTests|RefineMeetingUseCaseTests|SemanticCorpusIndexingTests|SemanticCorpusIndexingCoordinatorTests|SemanticCorpusIndexingSupervisorTests'
UI_TESTS='PortavozUITests/LibraryUITests/testRecordingWarnsWhenRemoteAudioCallbacksStop PortavozUITests/LibraryUITests/testRecordingWarnsWhenIncomingAudioClips PortavozUITests/LibraryUITests/testColdRecordingStartsLiveCaptionsWhenModelBecomesReady PortavozUITests/LibraryUITests/testLiveTranscriptYieldsFollowWhileReadingHistory PortavozUITests/LibraryUITests/testLiveTranslationUsesADistinctLabeledRail PortavozUITests/MeetingDetailUITests/testRunningRefineCanBeCanceledWithoutChangingTheTranscript PortavozUITests/SettingsUITests/testCategoryNavigationRevealsEachPane'
SWIFT_TEST_DIAGNOSTIC_DIR=""

cleanup_swift_test_diagnostics() {
  if [[ -n "$SWIFT_TEST_DIAGNOSTIC_DIR" \
    && -d "$SWIFT_TEST_DIAGNOSTIC_DIR" ]]; then
    rm -rf -- "$SWIFT_TEST_DIAGNOSTIC_DIR"
  fi
  SWIFT_TEST_DIAGNOSTIC_DIR=""
}

trap cleanup_swift_test_diagnostics EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
SWIFT_TEST_DIAGNOSTIC_DIR="$(
  mktemp -d "${TMPDIR:-/tmp}/portavoz-swift-test.XXXXXX"
)"
chmod 700 "$SWIFT_TEST_DIAGNOSTIC_DIR"
SWIFT_TEST_LOG="$SWIFT_TEST_DIAGNOSTIC_DIR/swift-test.log"
set +e
swift test 2>&1 | tee "$SWIFT_TEST_LOG"
pipeline_status=("${PIPESTATUS[@]}")
set -e
swift_test_status="${pipeline_status[0]}"
tee_status="${pipeline_status[1]}"
if [[ "$swift_test_status" -ne 0 ]]; then
  python3 scripts/swift_test_failure_summary.py "$SWIFT_TEST_LOG" || true
  exit "$swift_test_status"
fi
if [[ "$tee_status" -ne 0 ]]; then
  echo "error: private Swift test diagnostic capture failed" >&2
  exit "$tee_status"
fi
cleanup_swift_test_diagnostics
swiftlint lint --strict --no-cache
PORTAVOZ_STRESS_MINIMUM_TESTS=108 make test-recording-stress
swift test --filter "$LANGUAGE_FILTER"
make test-ui-scoped UI_TESTS="$UI_TESTS" UI_TEST_LOCALES="en es"

python3 scripts/release_reliability.py record-deterministic \
  --version "$VERSION" \
  --build "$BUILD" \
  --commit "$(git rev-parse HEAD)" \
  --output "$OUTPUT"
