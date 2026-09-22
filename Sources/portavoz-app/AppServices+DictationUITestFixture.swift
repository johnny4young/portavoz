import AppKit
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
    let exerciseClipboard: Bool

    init?(arguments: [String], usesTemporaryStore: Bool) {
        guard usesTemporaryStore, arguments.contains("-seed-dictation") else { return nil }
        exerciseClipboard = arguments.contains("-seed-dictation-clipboard")
        text = arguments.contains("-seed-dictation-english")
            ? "Don't delete these notes."
            : "No borres estas notas."
    }

    @MainActor
    static func dependencies(
        fixture: Self?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DictationSessionDependencies {
        DictationSessionDependencies(
            makeMicrophone: {
                .init(source: DictationFixtureMicrophone(), warmUp: {})
            },
            acquireRuntime: {
                guard let fixture else { throw CancellationError() }
                return LiveTranscriptionRuntime(
                    engine: DictationFixtureEngine(text: fixture.text), completion: {})
            },
            canInsert: { fixture != nil },
            targetName: { "Dictation test receiver" },
            // This fixture qualifies the controller and panel, not native
            // paste. The separate receiver journey calls TextInserter itself.
            insert: { text in
                guard fixture?.exerciseClipboard == true else { return .focusUnavailable }
                return await clipboardInsertion(text, environment: environment)
            },
            defaults: .standard)
    }

    /// Real clipboard admission, inert native effects. Names must stay inside
    /// the same explicit UUID namespace as the separate native receiver test.
    @MainActor
    private static func clipboardInsertion(
        _ text: String, environment: [String: String]
    ) async -> TextInserter.InsertionResult {
        let prefix = DictationNativeUITestFixture.pasteboardPrefix
        guard let name = environment[DictationNativeUITestFixture.environmentKey], name.hasPrefix(prefix),
              UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { return .clipboardUnavailable }
        return await TextInserter.insert(
            text, pasteboard: NSPasteboard(name: .init(name)),
            eventTarget: .process(ProcessInfo.processInfo.processIdentifier),
            effects: .init(isTargetAvailable: { _ in true }, waitForModifiers: { true },
                           focusedSecurity: { _ in .regular }, post: { _ in false }))
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
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
