import ApplicationKit
import Foundation
import PortavozCore
import TranscriptionKit
import XCTest

@testable import portavoz_app

final class LiveTranscriptionAttacherTests: XCTestCase {
    func testColdModelHotAttachesToNewestContextAndKeepsRecoveryRequired() async throws {
        let probe = LiveTranscriptionProbe()
        let attacher = makeAttacher(probe: probe, initialAvailable: false, capacity: 2)
        for index in 0..<5 {
            attacher.feeds.yield(chunk(at: index))
        }

        await attacher.recordingDidStart(
            initialTranscriber: nil,
            loader: { EchoLiveTranscriptionEngine() })

        try await waitUntil {
            probe.events == [.preparing, .available] && probe.captionTimes.count == 2
        }
        let requiresRecovery = await attacher.finish()

        XCTAssertTrue(requiresRecovery, "audio before hot attachment still needs durable recovery")
        XCTAssertEqual(probe.events, [.preparing, .available])
        XCTAssertEqual(probe.captionTimes, [3, 4])
    }

    func testResidentModelStartsAvailableWithoutRecovery() async throws {
        let probe = LiveTranscriptionProbe()
        let attacher = makeAttacher(probe: probe, initialAvailable: true, capacity: 2)

        await attacher.recordingDidStart(
            initialTranscriber: EchoLiveTranscriptionEngine(),
            loader: { throw LiveTranscriptionTestFailure.unexpectedLoad })
        attacher.feeds.yield(chunk(at: 1))

        try await waitUntil { probe.captionTimes == [1] }
        let requiresRecovery = await attacher.finish()

        XCTAssertFalse(requiresRecovery)
        XCTAssertEqual(probe.events, [.available])
    }

    func testDeferredLoadFailureIsVisibleAndFallsBackToDurableTranscript() async throws {
        let probe = LiveTranscriptionProbe()
        let attacher = makeAttacher(probe: probe, initialAvailable: false, capacity: 2)

        await attacher.recordingDidStart(
            initialTranscriber: nil,
            loader: { throw LiveTranscriptionTestFailure.loadFailed })

        try await waitUntil { probe.events == [.preparing, .failed] }
        let requiresRecovery = await attacher.finish()
        XCTAssertTrue(requiresRecovery)
    }

    private func makeAttacher(
        probe: LiveTranscriptionProbe,
        initialAvailable: Bool,
        capacity: Int
    ) -> LiveTranscriptionAttacher {
        LiveTranscriptionAttacher(
            channels: [.microphone],
            hints: TranscriptionHints(meetingID: MeetingID()),
            callbacks: StartRecordingLiveCallbacks(
                caption: { probe.record(caption: $0) },
                liveTranscription: { probe.record(event: $0) }),
            initialTranscriberAvailable: initialAvailable,
            capacityPerChannel: capacity)
    }

    private func chunk(at index: Int) -> AudioChunk {
        AudioChunk(
            channel: .microphone,
            samples: [Float(index)],
            sampleRate: 16_000,
            timestamp: TimeInterval(index))
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                return XCTFail("timed out waiting for live transcription state")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
final class LiveTranslationStateTests: XCTestCase {
    func testChangingTargetCannotReuseTranslationsFromThePreviousLanguage() {
        let controller = RecordingController()
        let segmentID = UUID()
        let unsupportedID = UUID()
        controller.translationTarget = "es"
        let pair = LiveTranslationPair(source: "en", target: "es")
        controller.beginLiveTranslationPair(pair)
        controller.translationDownloadApproved = true
        controller.translations[segmentID] = "Presupuesto aprobado"
        controller.markUnsupportedLiveTranslationRows(Set([unsupportedID]), for: pair)

        controller.translationTarget = "en"

        XCTAssertTrue(controller.translations.isEmpty)
        XCTAssertTrue(controller.liveTranslationHandledIDs.isEmpty)
        XCTAssertNil(controller.translationSource)
        XCTAssertFalse(controller.translationDownloadApproved)
        XCTAssertEqual(controller.translationState, .waitingForTranscript)
    }

    func testChangingSourceLaneRequiresFreshDownloadConsent() {
        let controller = RecordingController()
        controller.translationTarget = "en"
        controller.beginLiveTranslationPair(LiveTranslationPair(source: "es", target: "en"))
        controller.translationDownloadApproved = true

        controller.beginLiveTranslationPair(LiveTranslationPair(source: "fr", target: "en"))

        XCTAssertEqual(controller.translationSource, "fr")
        XCTAssertFalse(controller.translationDownloadApproved)
    }

    func testDisablingTranslationClearsStateAndRenderedRows() {
        let controller = RecordingController()
        controller.translationTarget = "es"
        controller.translations[UUID()] = "Texto"
        controller.updateLiveTranslationState(.failed)

        controller.translationTarget = nil

        XCTAssertTrue(controller.translations.isEmpty)
        XCTAssertEqual(controller.translationState, .off)
    }

    func testCanceledPreviousTargetCannotPublishLateTranslationsOrState() {
        let controller = RecordingController()
        let segmentID = UUID()
        controller.translationTarget = "es"
        let stalePair = LiveTranslationPair(source: "en", target: "es")
        controller.beginLiveTranslationPair(stalePair)
        controller.translationTarget = "en"

        XCTAssertFalse(controller.storeLiveTranslations(
            [segmentID: "Respuesta antigua"],
            for: stalePair))
        controller.updateLiveTranslationState(.active, for: stalePair)

        XCTAssertTrue(controller.translations.isEmpty)
        XCTAssertEqual(controller.translationState, .waitingForTranscript)
    }

    func testCanceledPreviousSourceCannotPublishIntoNewPairWithSameTarget() {
        let controller = RecordingController()
        let segmentID = UUID()
        controller.translationTarget = "en"
        let stalePair = LiveTranslationPair(source: "es", target: "en")
        controller.beginLiveTranslationPair(stalePair)
        controller.beginLiveTranslationPair(LiveTranslationPair(source: "fr", target: "en"))

        XCTAssertFalse(controller.storeLiveTranslations(
            [segmentID: "Stale Spanish result"],
            for: stalePair))
        controller.updateLiveTranslationState(.active, for: stalePair)

        XCTAssertTrue(controller.translations.isEmpty)
        XCTAssertEqual(controller.translationSource, "fr")
        XCTAssertEqual(controller.translationState, .waitingForTranscript)
    }

    func testVisibleTranslationStatesDescribeAutomaticFailureRetry() {
        XCTAssertEqual(
            LiveTranslationState.waitingForTranscript.statusMessageKey,
            "Live translation will start as soon as captions are available.")
        XCTAssertEqual(
            LiveTranslationState.unsupported.statusMessageKey,
            "Apple Translation does not support this language pair on this Mac.")
        XCTAssertEqual(
            LiveTranslationState.partiallyUnsupported.statusMessageKey,
            "Some captions stay in their original language because Apple Translation does not support their language pair on this Mac.")
        XCTAssertEqual(
            LiveTranslationState.failed.statusMessageKey,
            "Live translation paused after an error. Retrying automatically…")
        XCTAssertNil(LiveTranslationState.active.statusMessageKey)
    }

    func testWaitingTranslationStatusYieldsToTerminalCaptionFailure() {
        XCTAssertTrue(LiveTranslationState.waitingForTranscript.shouldPresentStatus(
            liveTranscriptState: .preparing))
        XCTAssertFalse(LiveTranslationState.waitingForTranscript.shouldPresentStatus(
            liveTranscriptState: .failed))
        XCTAssertTrue(LiveTranslationState.unsupported.shouldPresentStatus(
            liveTranscriptState: .failed))
        XCTAssertTrue(LiveTranslationState.partiallyUnsupported.shouldPresentStatus(
            liveTranscriptState: .available))
        XCTAssertTrue(LiveTranslationState.failed.shouldPresentStatus(
            liveTranscriptState: .failed))
        XCTAssertFalse(LiveTranslationState.active.shouldPresentStatus(
            liveTranscriptState: .available))
    }

    func testUnsupportedLaneRemainsVisibleAfterAnotherLaneSucceeds() {
        let controller = RecordingController()
        controller.translationTarget = "en"
        let unsupportedPair = LiveTranslationPair(source: "zu", target: "en")
        controller.beginLiveTranslationPair(unsupportedPair)
        let unsupportedID = UUID()

        controller.markUnsupportedLiveTranslationRows(
            Set([unsupportedID]),
            for: unsupportedPair)

        XCTAssertTrue(controller.liveTranslationHandledIDs.contains(unsupportedID))
        XCTAssertEqual(controller.translationState, .partiallyUnsupported)

        let supportedPair = LiveTranslationPair(source: "es", target: "en")
        controller.beginLiveTranslationPair(supportedPair)
        controller.updateLiveTranslationState(.active, for: supportedPair)

        XCTAssertEqual(controller.translationState, .partiallyUnsupported)
    }
}

final class LiveTranslationRoutingTests: XCTestCase {
    /// Why the translation loop must survive an idle lull: after everything
    /// in a lane is translated, the next caption in the SAME language
    /// reproduces the SAME pair — and an identical pair builds an identical
    /// `TranslationSession.Configuration`, which SwiftUI does not treat as a
    /// change. Nothing would restart a loop that returned when it went idle.
    func testCaptionAfterAnIdleLullReproducesTheSameLaneInsteadOfANewOne() throws {
        let first = segment(
            text: "La primera intervención ya fue traducida.",
            language: "es",
            start: 0)
        let open = segment(text: "Fila abierta.", language: "es", start: 2)

        let idlePair = LiveTranslationRouting.nextPair(
            segments: [first, open],
            translatedSourceTexts: [first.id: first.text],
            unsupportedIDs: [],
            target: "en")
        XCTAssertNil(idlePair, "a fully translated lane has nothing pending")

        let afterLull = segment(
            text: "Una intervención nueva llega después de la pausa.",
            language: "es",
            start: 4)
        let resumed = try XCTUnwrap(LiveTranslationRouting.nextPair(
            segments: [first, afterLull, open],
            translatedSourceTexts: [first.id: first.text],
            unsupportedIDs: [],
            target: "en"))

        XCTAssertEqual(resumed, LiveTranslationPair(source: "es", target: "en"))
        XCTAssertEqual(
            LiveTranslationRouting.pendingRows(
                segments: [first, afterLull, open],
                translatedSourceTexts: [first.id: first.text],
                unsupportedIDs: [],
                pair: resumed
            ).map(\.id),
            [afterLull.id],
            "the resumed lane must carry the post-lull row")
    }

    func testMixedMeetingRoutesOnlyClosedTurnsThatDifferFromTarget() throws {
        let spanish = segment(
            text: "Esta intervención permanece en español.",
            language: "es",
            start: 0)
        let english = segment(
            text: "This contribution remains in English.",
            language: "en",
            start: 2)
        let open = segment(
            text: "La fila más reciente todavía está creciendo.",
            language: "es",
            start: 4)
        let segments = [spanish, english, open]

        let pair = try XCTUnwrap(LiveTranslationRouting.nextPair(
            segments: segments,
            translatedSourceTexts: [:],
            unsupportedIDs: [],
            target: "en"))
        let pending = LiveTranslationRouting.pendingRows(
            segments: segments,
            translatedSourceTexts: [:],
            unsupportedIDs: [],
            pair: pair)

        XCTAssertEqual(pair, LiveTranslationPair(source: "es", target: "en"))
        XCTAssertEqual(pending.map(\.id), [spanish.id, open.id])
    }

    func testTargetLanguageRowsRemainOriginalWithoutBlockingTheNextSourceLane() throws {
        let english = segment(
            text: "This contribution remains in English.",
            language: "en-US",
            start: 0)
        let french = segment(
            text: "Cette intervention reste en français.",
            language: "fr",
            start: 2)
        let open = segment(
            text: "This newest row is still open.",
            language: "en",
            start: 4)

        let pair = try XCTUnwrap(LiveTranslationRouting.nextPair(
            segments: [english, french, open],
            translatedSourceTexts: [:],
            unsupportedIDs: [],
            target: "en"))

        XCTAssertEqual(pair, LiveTranslationPair(source: "fr", target: "en"))
    }

    func testUnknownLongRowUsesDeterministicLocalDetection() {
        let unknown = segment(
            text: "This row has enough evidence for local language detection.",
            language: nil,
            start: 0)
        let open = segment(text: "Newest open row.", language: nil, start: 2)

        let pair = LiveTranslationRouting.nextPair(
            segments: [unknown, open],
            translatedSourceTexts: [:],
            unsupportedIDs: [],
            target: "es",
            detector: { _ in "en" })

        XCTAssertEqual(pair, LiveTranslationPair(source: "en", target: "es"))
    }

    func testShortUnknownRowNeverGuessesOrRequestsFrameworkAutoDetection() {
        let short = segment(text: "Thanks.", language: nil, start: 0)
        let open = segment(text: "Open.", language: nil, start: 2)
        var detectorCalls = 0

        let pair = LiveTranslationRouting.nextPair(
            segments: [short, open],
            translatedSourceTexts: [:],
            unsupportedIDs: [],
            target: "en",
            detector: { _ in
                detectorCalls += 1
                return "es"
            })

        XCTAssertNil(pair)
        XCTAssertEqual(detectorCalls, 0)
    }

    func testHandledUnsupportedLaneDoesNotBlockLaterSupportedLanguage() throws {
        let unsupported = segment(
            text: "Lokhu kungumbhalo ongasekelwa ukuhumusha.",
            language: "zu",
            start: 0)
        let spanish = segment(
            text: "Esta intervención posterior sí puede traducirse.",
            language: "es",
            start: 2)
        let open = segment(
            text: "This newest row is still open.",
            language: "en",
            start: 4)
        let segments = [unsupported, spanish, open]

        let first = try XCTUnwrap(LiveTranslationRouting.nextPair(
            segments: segments,
            translatedSourceTexts: [:],
            unsupportedIDs: [],
            target: "en"))
        let next = try XCTUnwrap(LiveTranslationRouting.nextPair(
            segments: segments,
            translatedSourceTexts: [:],
            unsupportedIDs: [unsupported.id],
            target: "en"))

        XCTAssertEqual(first, LiveTranslationPair(source: "zu", target: "en"))
        XCTAssertEqual(next, LiveTranslationPair(source: "es", target: "en"))
    }

    func testGrowingOpenTurnTranslatesBeforeAnotherSpeakerClosesIt() throws {
        let open = segment(
            text: "Esta intervención larga debe traducirse mientras sigo hablando.",
            language: "es",
            start: 0)

        let pair = try XCTUnwrap(LiveTranslationRouting.nextPair(
            segments: [open],
            translatedSourceTexts: [:],
            unsupportedIDs: [],
            target: "en"))
        let pending = LiveTranslationRouting.pendingRows(
            segments: [open],
            translatedSourceTexts: [:],
            unsupportedIDs: [],
            pair: pair)

        XCTAssertEqual(pair, LiveTranslationPair(source: "es", target: "en"))
        XCTAssertEqual(pending.map(\.id), [open.id])
    }

    func testGrowingOpenTurnRefreshesOnlyAfterMeaningfulGrowth() throws {
        let open = segment(
            text: "Esta intervención larga ya tiene una traducción parcial",
            language: "es",
            start: 0)
        let pair = LiveTranslationPair(source: "es", target: "en")

        XCTAssertTrue(LiveTranslationRouting.pendingRows(
            segments: [open],
            translatedSourceTexts: [open.id: "Esta intervención larga"],
            unsupportedIDs: [],
            pair: pair).count == 1)
        XCTAssertTrue(LiveTranslationRouting.pendingRows(
            segments: [open],
            translatedSourceTexts: [
                open.id: "Esta intervención larga ya tiene una traducción"
            ],
            unsupportedIDs: [],
            pair: pair).isEmpty)
    }

    private func segment(
        text: String,
        language: String?,
        start: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: MeetingID(),
            channel: .system,
            text: text,
            language: language,
            startTime: start,
            endTime: start + 1,
            isFinal: true)
    }
}

final class TranscriptFocusVisualPolicyTests: XCTestCase {
    func testLiveFollowKeepsNearbyHistorySharpLonger() {
        let style = TranscriptFocusVisualPolicy.style(
            distance: 100,
            reach: 400,
            mode: .live,
            isFollowing: true)

        XCTAssertEqual(style.opacity, 1, accuracy: 0.001)
        XCTAssertEqual(style.scale, 1, accuracy: 0.001)
        XCTAssertEqual(style.blurRadius, 0, accuracy: 0.001)
    }

    func testBrowsingHistoryDisablesCylinderFadingAndBlur() {
        let style = TranscriptFocusVisualPolicy.style(
            distance: 390,
            reach: 400,
            mode: .live,
            isFollowing: false)

        XCTAssertEqual(style.opacity, 1, accuracy: 0.001)
        XCTAssertEqual(style.scale, 1, accuracy: 0.001)
        XCTAssertEqual(style.blurRadius, 0, accuracy: 0.001)
    }

    func testLiveEdgeTreatmentRemainsReadable() {
        let style = TranscriptFocusVisualPolicy.style(
            distance: 400,
            reach: 400,
            mode: .live,
            isFollowing: true)

        XCTAssertGreaterThanOrEqual(style.opacity, 0.52)
        XCTAssertGreaterThanOrEqual(style.scale, 0.95)
        XCTAssertLessThanOrEqual(style.blurRadius, 0.65)
    }

    func testRollingSummaryIdentityCursorAdmitsNewDiarizationSplitPiece() {
        let meetingID = MeetingID()
        let originalID = UUID()
        let retainedPiece = TranscriptSegment(
            id: originalID,
            meetingID: meetingID,
            channel: .system,
            text: "first voice",
            startTime: 0,
            endTime: 1,
            isFinal: true)
        let newPiece = TranscriptSegment(
            meetingID: meetingID,
            channel: .system,
            text: "second voice",
            startTime: 1,
            endTime: 2,
            isFinal: true)
        let open = TranscriptSegment(
            meetingID: meetingID,
            channel: .system,
            text: "still growing",
            startTime: 2,
            endTime: 3)

        let window = LiveSummaryWindowPolicy.unsummarizedClosedRows(
            [retainedPiece, newPiece, open],
            summarizedIDs: [originalID])

        XCTAssertEqual(window.map(\.id), [newPiece.id])
    }
}

final class RecordingMeterPublicationPolicyTests: XCTestCase {
    func testMeterPublishesAtMostTwentyFramesPerSecond() {
        XCTAssertFalse(RecordingMeterPublicationPolicy.shouldPublish(
            now: 10.04,
            last: 10))
        XCTAssertTrue(RecordingMeterPublicationPolicy.shouldPublish(
            now: 10.05,
            last: 10))
    }
}

@MainActor
final class RecordingSystemCaptureHealthPresentationTests: XCTestCase {
    func testOnlyProlongedRecoverableOutageSuggestsCallMayHaveEnded() {
        XCTAssertTrue(
            RecordingSystemCaptureHealth.stalled(secondsWithoutFrames: 120)
                .shouldSuggestStop)
        XCTAssertFalse(RecordingSystemCaptureHealth.failed.shouldSuggestStop)
    }

    func testCompactHUDDistinguishesTerminalFailureFromRecoverableInterruption() {
        XCTAssertEqual(
            RecordingSystemCaptureHealth.stalled(secondsWithoutFrames: 8)
                .compactStatusMessageKey,
            "Remote audio interrupted")
        XCTAssertEqual(
            RecordingSystemCaptureHealth.failed.compactStatusMessageKey,
            "Remote audio capture failed. Stop and start a new recording to avoid losing the call.")
    }
}

private enum LiveTranscriptionTestFailure: Error {
    case loadFailed
    case unexpectedLoad
}

private final class LiveTranscriptionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [StartRecordingLiveTranscriptionEvent] = []
    private var storedCaptionTimes: [TimeInterval] = []

    var events: [StartRecordingLiveTranscriptionEvent] {
        lock.withLock { storedEvents }
    }

    var captionTimes: [TimeInterval] {
        lock.withLock { storedCaptionTimes.sorted() }
    }

    func record(event: StartRecordingLiveTranscriptionEvent) {
        lock.withLock { storedEvents.append(event) }
    }

    func record(caption: TranscriptSegment) {
        lock.withLock { storedCaptionTimes.append(caption.startTime) }
    }
}

private struct EchoLiveTranscriptionEngine: TranscriptionEngine {
    let descriptor = EngineDescriptor(
        id: "test-live",
        displayName: "Test live",
        realTimeFactor: 0,
        runsOnDevice: true,
        approximateMemoryMB: 0)

    func transcribe(
        _ audio: AsyncStream<AudioChunk>,
        hints: TranscriptionHints
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for await chunk in audio {
                    continuation.yield(TranscriptSegment(
                        meetingID: hints.meetingID ?? MeetingID(),
                        channel: chunk.channel,
                        text: "chunk \(Int(chunk.timestamp))",
                        startTime: chunk.timestamp,
                        endTime: chunk.timestamp + 0.1,
                        isFinal: true))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
