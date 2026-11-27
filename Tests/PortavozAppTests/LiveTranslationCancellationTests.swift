import PortavozCore
import XCTest

@testable import portavoz_app

@MainActor
final class LiveTranslationCancellationTests: XCTestCase {
    func testCancelledLaneCannotReplaceNewSourceOrRevokeItsConsent() async {
        let controller = RecordingController()
        controller.translationTarget = "en"
        let currentPair = LiveTranslationPair(source: "fr", target: "en")
        controller.beginLiveTranslationPair(currentPair)
        controller.translationDownloadApproved = true
        controller.updateLiveTranslationState(.active, for: currentPair)

        await deliverCancelledCallback {
            controller.beginLiveTranslationPair(.init(source: "es", target: "en"))
        }

        XCTAssertEqual(controller.translationSource, "fr")
        XCTAssertTrue(controller.translationDownloadApproved)
        XCTAssertEqual(controller.translationState, .active)
    }

    func testCancelledCallbackCannotPublishAfterTargetReturnsToSamePair() async {
        let controller = RecordingController()
        let pair = LiveTranslationPair(source: "es", target: "en")
        controller.translationTarget = "en"
        controller.beginLiveTranslationPair(pair)
        controller.translationTarget = "fr"
        controller.translationTarget = "en"
        controller.beginLiveTranslationPair(pair)
        controller.updateLiveTranslationState(.active, for: pair)

        await deliverCancelledCallback {
            controller.updateLiveTranslationState(.failed, for: pair)
        }

        XCTAssertEqual(controller.translationState, .active)
    }

    func testCancelledCallbackCannotMarkCurrentLaneUnsupported() async {
        let controller = RecordingController()
        let pair = LiveTranslationPair(source: "es", target: "en")
        controller.translationTarget = "en"
        controller.beginLiveTranslationPair(pair)
        controller.updateLiveTranslationState(.active, for: pair)

        await deliverCancelledCallback {
            controller.markUnsupportedLiveTranslationRows([UUID()], for: pair)
        }

        XCTAssertEqual(controller.translationState, .active)
        XCTAssertTrue(controller.unsupportedTranslationRowIDs.isEmpty)
        XCTAssertFalse(controller.hasUnsupportedTranslationRows)
    }

    func testCancelledPreparationFailureCannotRevokeCurrentConsent() async {
        let controller = RecordingController()
        let pair = LiveTranslationPair(source: "es", target: "en")
        controller.translationTarget = "en"
        controller.beginLiveTranslationPair(pair)
        controller.translationDownloadApproved = true
        controller.updateLiveTranslationState(.active, for: pair)
        XCTAssertTrue(controller.isCurrentLiveTranslationTask(for: pair))

        await deliverCancelledCallback {
            XCTAssertFalse(controller.isCurrentLiveTranslationTask(for: pair))
            controller.failLiveTranslationPreparation(for: pair)
        }

        XCTAssertTrue(controller.translationDownloadApproved)
        XCTAssertEqual(controller.translationState, .active)
    }

    func testCurrentPreparationFailureRequiresFreshConsent() async {
        let controller = RecordingController()
        let pair = LiveTranslationPair(source: "es", target: "en")
        controller.translationTarget = "en"
        controller.beginLiveTranslationPair(pair)
        controller.translationDownloadApproved = true

        controller.failLiveTranslationPreparation(for: pair)

        XCTAssertFalse(controller.translationDownloadApproved)
        XCTAssertEqual(controller.translationState, .needsDownload)
    }

    func testCancelledUnscopedCallbackCannotReplaceVisibleState() async {
        let controller = RecordingController()
        let pair = LiveTranslationPair(source: "es", target: "en")
        controller.translationTarget = "en"
        controller.beginLiveTranslationPair(pair)
        controller.updateLiveTranslationState(.active, for: pair)

        await deliverCancelledCallback {
            controller.updateLiveTranslationState(.failed)
        }

        XCTAssertEqual(controller.translationState, .active)
    }

    func testMicrophoneEchoReplacementReopeningRemoteRowInvalidatesTranslationAndSummaryAndPurgesEcho() async {
        let controller = RecordingController()
        let meetingID = MeetingID()
        let pair = LiveTranslationPair(source: "es", target: "en")
        controller.translationTarget = "en"
        controller.beginLiveTranslationPair(pair)

        let remoteInitial = TranscriptSegment(
            meetingID: meetingID,
            channel: .system,
            text: "Vamos a lanzar el cambio",
            language: "es",
            startTime: 1.0,
            endTime: 2.5,
            isFinal: true)
        controller.receiveLiveCaption(remoteInitial)
        XCTAssertEqual(controller.captions.count, 1)
        let remoteID = controller.captions[0].id

        // Overlapping microphone echo opens a trailing mic row, closing the remote row.
        let micEcho = TranscriptSegment(
            meetingID: meetingID,
            channel: .microphone,
            text: "el cambio mañana temprano",
            language: "es",
            startTime: 2.6,
            endTime: 4.0,
            isFinal: true)
        controller.receiveLiveCaption(micEcho)
        XCTAssertEqual(controller.captions.count, 2)
        let echoID = controller.captions[1].id

        // Translate both rows and mark remote as previously unsupported/summarized.
        XCTAssertTrue(controller.storeLiveTranslations(
            [remoteID: "We are launching the change", echoID: "the change tomorrow morning"],
            sourceTexts: [remoteID: remoteInitial.text, echoID: micEcho.text],
            for: pair))
        controller.markUnsupportedLiveTranslationRows([remoteID, echoID], for: pair)

        // Direct system continuation removes the mic echo tail and reopens/extends R1.
        let remoteContinuation = TranscriptSegment(
            meetingID: meetingID,
            channel: .system,
            text: "el cambio mañana temprano con el equipo.",
            language: "es",
            startTime: 2.6,
            endTime: 4.5,
            isFinal: true)
        controller.receiveLiveCaption(remoteContinuation)

        XCTAssertEqual(controller.captions.count, 1)
        XCTAssertEqual(controller.captions[0].id, remoteID)
        XCTAssertNil(controller.translations[echoID])
        XCTAssertNil(controller.translatedSourceTexts[echoID])
        XCTAssertFalse(controller.unsupportedTranslationRowIDs.contains(echoID))
        XCTAssertFalse(controller.unsupportedTranslationRowIDs.contains(remoteID))

        // Stale translation for the pre-extension text must be rejected.
        XCTAssertFalse(controller.storeLiveTranslations(
            [remoteID: "Stale short translation"],
            sourceTexts: [remoteID: remoteInitial.text],
            for: pair))

        // A later turn closes R1 again; live translation must re-queue R1 with its full text.
        let nextRemote = TranscriptSegment(
            meetingID: meetingID,
            channel: .system,
            text: "Perfecto, empezamos a las nueve.",
            language: "es",
            startTime: 10.0,
            endTime: 12.0,
            isFinal: true)
        controller.receiveLiveCaption(nextRemote)

        let pending = LiveTranslationRouting.pendingRows(
            segments: controller.captions,
            translatedSourceTexts: controller.translatedSourceTexts,
            unsupportedIDs: controller.unsupportedTranslationRowIDs,
            pair: pair)
        XCTAssertTrue(pending.contains(where: { $0.id == remoteID && $0.text == controller.captions[0].text }))
    }

    func testMicrophoneCaptureHealthTracksStallRecoveryAndFailure() async {
        let controller = RecordingController()
        controller.receiveCaptureHealth(.stalled(channel: .microphone, secondsWithoutFrames: 8))
        XCTAssertEqual(controller.microphoneCaptureHealth, .stalled(secondsWithoutFrames: 8))
        XCTAssertFalse(controller.microphoneCaptureFailed)
        XCTAssertEqual(controller.systemCaptureHealth, .healthy)

        controller.receiveCaptureHealth(
            .recoveryRequested(channel: .microphone, attempt: 1, secondsWithoutFrames: 8))
        XCTAssertEqual(
            controller.microphoneCaptureHealth,
            .recovering(attempt: 1, secondsWithoutFrames: 8))

        controller.receiveCaptureHealth(.recovered(channel: .microphone, outageSeconds: 10))
        XCTAssertEqual(controller.microphoneCaptureHealth, .recovered)

        controller.receiveCaptureHealth(.streamFailed(channel: .microphone))
        XCTAssertEqual(controller.microphoneCaptureHealth, .failed)
        XCTAssertTrue(controller.microphoneCaptureFailed)
        XCTAssertEqual(controller.systemCaptureHealth, .healthy)
    }

    /// The inherited main-actor task cannot enter before this actor cancels
    /// it and suspends. Still deliver its callback through the same actor hop
    /// as the framework adapter: cancellation must be checked at publication.
    private func deliverCancelledCallback(
        _ operation: @escaping @MainActor @Sendable () -> Void
    ) async {
        let task = Task { @MainActor in
            await MainActor.run {
                XCTAssertTrue(Task.isCancelled)
                operation()
            }
        }
        task.cancel()
        await task.value
    }
}
