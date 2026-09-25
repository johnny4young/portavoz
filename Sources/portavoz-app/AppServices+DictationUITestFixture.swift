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
    let recoversDestination: Bool
    let deliveryOutcome: DictationDeliveryOutcome?

    init?(arguments: [String], usesTemporaryStore: Bool) {
        guard usesTemporaryStore, arguments.contains("-seed-dictation") else { return nil }
        recoversDestination = arguments.contains("-seed-dictation-recovery")
        deliveryOutcome = arguments.contains("-seed-dictation-delivery")
            ? (arguments.contains("-seed-dictation-verified") ? .verified : .dispatched) : nil
        text = arguments.contains("-seed-dictation-english")
            ? "Don't delete these notes."
            : "No borres estas notas."
    }

    @MainActor
    static func dependencies(
        fixture: Self?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DictationSessionDependencies {
        let boardName = DictationNativeUITestFixture.validPasteboardName(
            environment[DictationNativeUITestFixture.environmentKey])
        var deliveryAttempts = 0
        var copyAttempts = 0
        var clockTick = 0.0
        return DictationSessionDependencies(
            makeMicrophone: {
                .init(source: DictationFixtureMicrophone(), warmUp: {})
            },
            acquireRuntime: {
                guard let fixture else { throw CancellationError() }
                return LiveTranscriptionRuntime(
                    engine: DictationFixtureEngine(text: fixture.text), completion: {})
            },
            canInsert: { fixture != nil },
            captureDestination: {
                // No native events. The separate receiver journey owns those.
                let name = fixture?.recoversDestination == true
                    ? String(repeating: "Dictation receiver — / ", count: 12)
                    : "Dictation test receiver"
                return CapturedDictationDestination(name: name, canRetry: true) { _ in
                    deliveryAttempts += 1
                    if let outcome = fixture?.deliveryOutcome { return outcome }
                    guard fixture?.recoversDestination == true else { return .refused(.focusUnavailable) }
                    return deliveryAttempts == 1 ? .refused(.targetChanged) : .dispatched
                }
            },
            copyText: { text in
                copyAttempts += 1
                // Deliberate first failure; later attempts use only a named board.
                guard fixture?.recoversDestination == true, copyAttempts > 1, let boardName else { return false }
                return TextInserter.copy(text, to: NSPasteboard(name: .init(boardName)))
            },
            defaults: .standard,
            now: {
                guard fixture?.recoversDestination == true || fixture?.deliveryOutcome != nil else { return Date() }
                defer { clockTick += 1 }
                return Date(timeIntervalSince1970: clockTick)
            })
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
