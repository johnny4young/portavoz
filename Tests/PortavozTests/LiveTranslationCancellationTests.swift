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
