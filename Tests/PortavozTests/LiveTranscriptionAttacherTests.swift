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
        controller.translationTarget = "es"
        controller.translations[segmentID] = "Presupuesto aprobado"

        controller.translationTarget = "en"

        XCTAssertTrue(controller.translations.isEmpty)
        XCTAssertEqual(controller.translationState, .waitingForTranscript)
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
        controller.translationTarget = "en"

        XCTAssertFalse(controller.storeLiveTranslations(
            [segmentID: "Respuesta antigua"],
            forTarget: "es"))
        controller.updateLiveTranslationState(.active, forTarget: "es")

        XCTAssertTrue(controller.translations.isEmpty)
        XCTAssertEqual(controller.translationState, .waitingForTranscript)
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
