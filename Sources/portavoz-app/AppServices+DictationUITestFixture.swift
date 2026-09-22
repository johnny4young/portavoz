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

struct DictationUITestFixture: Sendable {
    let text: String
    let streamsDeltas: Bool

    init?(arguments: [String], usesTemporaryStore: Bool) {
        guard usesTemporaryStore, arguments.contains("-seed-dictation") else { return nil }
        streamsDeltas = arguments.contains("-seed-dictation-streaming")
        text = arguments.contains("-seed-dictation-english")
            ? "Don't delete these notes."
            : "No borres estas notas."
    }

    @MainActor
    static func dependencies(fixture: Self?) -> DictationSessionDependencies {
        DictationSessionDependencies(
            makeMicrophone: {
                .init(source: DictationFixtureMicrophone(), warmUp: {})
            },
            acquireRuntime: {
                guard let fixture else { throw CancellationError() }
                return LiveTranscriptionRuntime(
                    engine: DictationFixtureEngine(text: fixture.text, streamsDeltas: fixture.streamsDeltas),
                    completion: {})
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
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?

    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        continuation.yield(AudioChunk(
            channel: .microphone, samples: [0.1, -0.1], sampleRate: 16_000, timestamp: 0))
        return stream
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }
}

private struct DictationFixtureEngine: TranscriptionEngine {
    let text: String
    let streamsDeltas: Bool
    let descriptor = EngineDescriptor(
        id: "dictation-ui-fixture", displayName: "Dictation fixture",
        realTimeFactor: 0, runsOnDevice: true, approximateMemoryMB: 0)

    func transcribe(
        _ audio: AsyncStream<AudioChunk>, hints: TranscriptionHints
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: TranscriptSegment.self, bufferingPolicy: .bufferingOldest(16))
        let task = Task {
            var emitted = false
            for await _ in audio {
                guard !Task.isCancelled else { break }
                if !emitted {
                    emitted = true
                    continuation.yield(TranscriptSegment(
                        meetingID: hints.meetingID ?? MeetingID(),
                        channel: .microphone, text: text, startTime: 0, endTime: 1))
                    if streamsDeltas {
                        for (delta, time) in [("Café", 8.0), ("C++", 8.2), (".", 8.4), ("Final", 16.0)] {
                            continuation.yield(TranscriptSegment(
                                meetingID: hints.meetingID ?? MeetingID(), channel: .microphone,
                                text: delta, startTime: time, endTime: time + 0.1))
                        }
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
