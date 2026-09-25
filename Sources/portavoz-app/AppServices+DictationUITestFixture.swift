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
    let streamsDeltas: Bool
    let deniesMicrophoneOnce: Bool
    let missesAudioOnce: Bool
    let holdsPermission: Bool
    let captureFailure: Bool
    private var permissionRequests = 0
    private var sourceCreations = 0
    private var microphone: DictationFixtureMicrophone?

    init?(arguments: [String], usesTemporaryStore: Bool) {
        guard usesTemporaryStore, arguments.contains("-seed-dictation") else { return nil }
        streamsDeltas = arguments.contains("-seed-dictation-streaming")
        deniesMicrophoneOnce = arguments.contains("-seed-dictation-microphone-denied")
        missesAudioOnce = arguments.contains("-seed-dictation-microphone-no-audio")
        holdsPermission = arguments.contains("-seed-dictation-preparation-held")
        captureFailure = arguments.contains("-seed-dictation-capture-failure")
        text = arguments.contains("-seed-dictation-english")
            ? "Don't delete these notes."
            : "No borres estas notas."
    }

    @MainActor
    static func dependencies(fixture: DictationUITestFixture?) -> DictationSessionDependencies {
        return DictationSessionDependencies(
            authorizeMicrophone: {
                guard let fixture else { return false }
                fixture.permissionRequests += 1
                if fixture.holdsPermission {
                    do { try await Task.sleep(for: .seconds(3_600)) } catch { return false }
                }
                return !(fixture.deniesMicrophoneOnce && fixture.permissionRequests == 1)
            },
            makeMicrophone: {
                if let fixture { fixture.sourceCreations += 1 }
                let microphone = DictationFixtureMicrophone(
                    emitsAudio: !(fixture?.missesAudioOnce == true && fixture?.sourceCreations == 1))
                fixture?.microphone = microphone
                return .init(
                    source: microphone,
                    warmUp: {},
                    usesSystemFallback: fixture?.missesAudioOnce == true)
            },
            acquireRuntime: {
                guard let fixture else { throw CancellationError() }
                return LiveTranscriptionRuntime(
                    engine: DictationFixtureEngine(
                        text: fixture.text,
                        streamsDeltas: fixture.streamsDeltas,
                        onFirstCaption: { await fixture.triggerCaptureFailure() }),
                    completion: {})
            },
            canInsert: { fixture != nil },
            targetName: { "Dictation test receiver" },
            // This fixture qualifies the controller and panel, not native
            // paste. The separate receiver journey calls TextInserter itself.
            insert: { _ in .focusUnavailable },
            defaults: .standard)
    }

    private func triggerCaptureFailure() async {
        guard captureFailure else { return }
        await microphone?.fail()
    }
}

private actor DictationFixtureMicrophone: AudioCaptureSource {
    nonisolated let channel = AudioChannel.microphone
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    private let emitsAudio: Bool

    init(emitsAudio: Bool) { self.emitsAudio = emitsAudio }

    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        if emitsAudio {
            continuation.yield(AudioChunk(
                channel: .microphone, samples: [0.1, -0.1], sampleRate: 16_000, timestamp: 0))
        }
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
    let streamsDeltas: Bool
    let onFirstCaption: @Sendable () async -> Void
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
                    await onFirstCaption()
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
