import AudioCaptureKit
import Foundation
import PortavozCore
import TranscriptionKit

extension AppServices {
    func makeDictationSessionDependencies() -> DictationSessionDependencies {
        guard usesTemporaryMeetingStore else { return .live(services: self) }
        // Temporary composition must never open real audio or prompt for
        // Accessibility just because a test clicked the production menu item.
        return DictationUITestFixture.dependencies(fixture: dictationUITestFixture)
    }
}

@MainActor
final class DictationUITestFixture {
    let text: String
    let captureFailure: Bool
    private var finishesNextCapture: Bool
    private var activeMicrophone: DictationFixtureMicrophone?

    init?(arguments: [String], usesTemporaryStore: Bool) {
        guard usesTemporaryStore, arguments.contains("-seed-dictation") else { return nil }
        captureFailure = arguments.contains("-seed-dictation-capture-failure")
        text = arguments.contains("-seed-dictation-english")
            ? "Don't delete these notes."
            : "No borres estas notas."
        finishesNextCapture = arguments.contains("-seed-dictation-unexpected-completion")
    }

    static func dependencies(fixture: DictationUITestFixture?) -> DictationSessionDependencies {
        DictationSessionDependencies(
            makeMicrophone: {
                // AppServices recreates dependencies for menu actions. Consume
                // the first failure only when this app owner creates capture.
                let finishesImmediately = fixture?.finishesNextCapture ?? false
                fixture?.finishesNextCapture = false
                let microphone = DictationFixtureMicrophone(finishesImmediately: finishesImmediately)
                fixture?.activeMicrophone = microphone
                return .init(source: microphone, warmUp: {})
            },
            acquireRuntime: {
                guard let fixture else { throw CancellationError() }
                let microphone = fixture.activeMicrophone
                return LiveTranscriptionRuntime(
                    engine: DictationFixtureEngine(text: fixture.text, onFirstCaption: {
                        if fixture.captureFailure { await microphone?.fail() }
                    }), completion: {})
            },
            canInsert: { fixture != nil },
            targetName: { "Dictation test receiver" },
            // This fixture qualifies the controller and panel, not native
            // paste. The separate receiver journey calls TextInserter itself.
            insert: { _ in .focusUnavailable },
            defaults: .standard)
    }
}

private actor DictationFixtureMicrophone: AudioCaptureSource {
    nonisolated let channel = AudioChannel.microphone
    private let finishesImmediately: Bool
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?

    init(finishesImmediately: Bool) {
        self.finishesImmediately = finishesImmediately
    }

    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        continuation.yield(AudioChunk(
            channel: .microphone, samples: [0.1, -0.1], sampleRate: 16_000, timestamp: 0))
        if finishesImmediately { continuation.finish() }
        return stream
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }

    func fail() {
        continuation?.finish(throwing: FixtureFailure.interrupted)
        continuation = nil
    }

    private enum FixtureFailure: Error { case interrupted }
}

private struct DictationFixtureEngine: TranscriptionEngine {
    let text: String
    let onFirstCaption: @Sendable () async -> Void
    let descriptor = EngineDescriptor(
        id: "dictation-ui-fixture", displayName: "Dictation fixture",
        realTimeFactor: 0, runsOnDevice: true, approximateMemoryMB: 0)

    func transcribe(
        _ audio: AsyncStream<AudioChunk>, hints: TranscriptionHints
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptSegment.self)
        let task = Task {
            var emitted = false
            for await _ in audio {
                guard !Task.isCancelled else { break }
                if !emitted {
                    emitted = true
                    continuation.yield(TranscriptSegment(
                        meetingID: hints.meetingID ?? MeetingID(),
                        channel: .microphone, text: text, startTime: 0, endTime: 1))
                    await onFirstCaption()
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
