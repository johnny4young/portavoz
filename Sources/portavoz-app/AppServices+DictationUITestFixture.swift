import AppKit
import ApplicationKit
import AudioCaptureKit
import Foundation
import IntelligenceKit
import PortavozCore
import TranscriptionKit

extension AppServices {
    /// Paste last passes false: a replay is never a rewrite instruction.
    func makeDictationSessionDependencies(capturesInstruction: Bool = true) -> DictationSessionDependencies {
        let beginCapture: () -> () -> Void = { [weak self] in
            self?.beginDictationCapture() ?? {}
        }
        // Temporary composition must never open real audio or prompt for
        // Accessibility just because a test clicked the production menu item.
        var dependencies: DictationSessionDependencies
        if usesTemporaryMeetingStore {
            dependencies = DictationUITestFixture.dependencies(
                fixture: dictationUITestFixture, beginCapture: beginCapture)
            dependencies.waitForFeedbackDismissal = DictationUITestFixture.waitHoldingUnverifiedNotices
            dependencies.polishDictation = DictationUITestFixture.polishing(dictationUITestFixture)
        } else {
            dependencies = .live(services: self, beginCapture: beginCapture)
        }
        dependencies.beginHistory = { [weak self] in self?.dictationHistory.admit() }
        dependencies.recordStats = { [weak self] sample in self?.dictationStats.record(sample) }
        let routed = dictationPractice.route(dependencies, appIsActive: NSApplication.shared.isActive)
        // A rewrite waiting for "Say how" takes the next session's words as its instruction.
        return capturesInstruction && selectionRewrite.capturesInstruction
            ? selectionRewrite.instructionDependencies(routed) : routed
    }
}

@MainActor
final class DictationUITestFixture {
    let text: String
    let recoversDestination: Bool
    let deliveryOutcome: DictationDeliveryOutcome?
    /// Real clipboard borrowing on a named board, with inert native effects.
    let exerciseClipboard: Bool
    var presentsRecoveryControls: Bool { recoversDestination || deliveryOutcome == .dispatched }
    let streamsDeltas: Bool
    let deniesMicrophoneOnce: Bool
    let missesAudioOnce: Bool
    let holdsPermission: Bool
    /// Listening starts but the model never arrives, so the strip stays in its loading state.
    let holdsModel: Bool
    let captureFailure: Bool
    /// A deterministic voice detector that never hears speech; no model is loaded.
    let simulatesNoSpeech: Bool
    /// The polish rewrite: a punctuation-only change, one that never answers, or one that drops the negation.
    enum PolishBehavior { case polishes, holds, changesMeaning }
    let polish: PolishBehavior
    private var finishesNextCapture: Bool
    private var permissionRequests = 0
    private var sourceCreations = 0
    private var microphone: DictationFixtureMicrophone?

    init?(arguments: [String], usesTemporaryStore: Bool) {
        guard usesTemporaryStore, arguments.contains("-seed-dictation") else { return nil }
        recoversDestination = arguments.contains("-seed-dictation-recovery")
        deliveryOutcome = arguments.contains("-seed-dictation-delivery")
            ? (arguments.contains("-seed-dictation-verified") ? .verified : .dispatched) : nil
        finishesNextCapture = arguments.contains("-seed-dictation-source-eof")
        streamsDeltas = arguments.contains("-seed-dictation-streaming")
        deniesMicrophoneOnce = arguments.contains("-seed-dictation-microphone-denied")
        missesAudioOnce = arguments.contains("-seed-dictation-microphone-no-audio")
        holdsPermission = arguments.contains("-seed-dictation-preparation-held")
        holdsModel = arguments.contains("-seed-dictation-model-loading")
        captureFailure = arguments.contains("-seed-dictation-capture-failure")
        exerciseClipboard = arguments.contains("-seed-dictation-clipboard")
        simulatesNoSpeech = arguments.contains("-seed-dictation-no-speech")
        polish = arguments.contains("-seed-dictation-polish-held") ? .holds
            : arguments.contains("-seed-dictation-polish-unfaithful") ? .changesMeaning : .polishes
        text = arguments.contains("-seed-dictation-english")
            ? "Don't delete these notes."
            : "No borres estas notas."
    }

    /// UI journeys inspect unverified notices; unit tests own their expiry.
    static func waitHoldingUnverifiedNotices(_ delay: Duration) async throws {
        try await Task.sleep(for: delay == DictationController.unverifiedFeedbackDuration ? .seconds(3_600) : delay)
    }

    /// False once a held load is cancelled.
    func modelArrives() async -> Bool {
        guard holdsModel else { return true }
        do { try await Task.sleep(for: .seconds(3_600)) } catch { return false }
        return true
    }

    @MainActor
    static func dependencies(
        fixture: DictationUITestFixture?, beginCapture: @escaping () -> () -> Void,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DictationSessionDependencies {
        let boardName = DictationNativeUITestFixture.validPasteboardName(
            environment[DictationNativeUITestFixture.environmentKey])
        var deliveryAttempts = 0
        var copyAttempts = 0
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
                let finishesImmediately = fixture?.finishesNextCapture ?? false
                fixture?.finishesNextCapture = false
                let microphone = DictationFixtureMicrophone(
                    emitsAudio: !(fixture?.missesAudioOnce == true && fixture?.sourceCreations == 1),
                    finishesImmediately: finishesImmediately)
                fixture?.microphone = microphone
                return .init(
                    source: microphone,
                    warmUp: {},
                    usesSystemFallback: fixture?.missesAudioOnce == true)
            },
            acquireRuntime: {
                guard let fixture, await fixture.modelArrives() else { throw CancellationError() }
                return LiveTranscriptionRuntime(
                    engine: DictationFixtureEngine(
                        text: fixture.text,
                        streamsDeltas: fixture.streamsDeltas,
                        onFirstCaption: { await fixture.triggerCaptureFailure() }),
                    completion: {})
            },
            canInsert: { fixture != nil },
            captureDestination: {
                if fixture?.exerciseClipboard == true {
                    return CapturedDictationDestination(name: "Dictation test receiver", canRetry: true) { text in
                        await clipboardInsertion(text, boardName: boardName)
                    }
                }
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
                guard fixture?.presentsRecoveryControls == true, copyAttempts > 1, let boardName else { return false }
                return TextInserter.copy(text, to: NSPasteboard(name: .init(boardName)))
            },
            defaults: .standard,
            now: fixtureClock(fixture),
            beginCapture: beginCapture, makeSpeechGate: { noSpeechGate(fixture) })
    }

    static func polishing(
        _ fixture: DictationUITestFixture?
    ) -> (String, [String], String?) async -> DictationPolishOutcome {
        { text, terms, recipe in
            await PolishDictation(polisher: FixturePolisher(behavior: fixture?.polish ?? .polishes))(
                text, protectedTerms: terms, recipe: recipe)
        }
    }

    /// No engine: the fixture edits punctuation, holds, or drops the first word.
    private struct FixturePolisher: DictationTextPolishing {
        let behavior: PolishBehavior

        func polish(_ text: String, recipe: String?) async throws -> String {
            switch behavior {
            case .polishes:
                // A recipe turns the sentence into a one-item list.
                return (recipe == nil ? "" : "- ") + text.trimmingCharacters(in: .punctuationCharacters) + "!"
            case .holds:
                try await Task.sleep(for: .seconds(3_600))
                return text
            case .changesMeaning:
                return text.split(separator: " ").dropFirst().joined(separator: " ")
            }
        }
    }

    private static func noSpeechGate(_ fixture: DictationUITestFixture?) -> DictationSpeechGate? {
        fixture?.simulatesNoSpeech == true ? DictationSpeechGate { { _ in false } } : nil
    }

    /// Recovery and delivery journeys use a deterministic clock; others use real time.
    private static func fixtureClock(_ fixture: DictationUITestFixture?) -> () -> Date {
        var clockTick = 0.0
        return {
            guard fixture?.recoversDestination == true || fixture?.deliveryOutcome != nil else { return Date() }
            defer { clockTick += 1 }
            return Date(timeIntervalSince1970: clockTick)
        }
    }

    /// The production inserter and clipboard loan on a UUID-named board only;
    /// the paste event is never posted, so the borrowed clipboard is restored.
    @MainActor
    private static func clipboardInsertion(_ text: String, boardName: String?) async -> DictationDeliveryOutcome {
        guard let boardName else { return .refused(.clipboardUnavailable) }
        let target = TextInserter.Target(processID: ProcessInfo.processInfo.processIdentifier, validate: { nil })
        return await TextInserter.insert(
            text, into: target, pasteboard: NSPasteboard(name: .init(boardName)),
            effects: .init(waitForModifiers: { true }, post: { _ in false }))
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

    private let finishesImmediately: Bool

    init(emitsAudio: Bool, finishesImmediately: Bool) {
        self.emitsAudio = emitsAudio
        self.finishesImmediately = finishesImmediately
    }

    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        if emitsAudio {
            continuation.yield(AudioChunk(
                channel: .microphone, samples: [0.1, -0.1], sampleRate: 16_000, timestamp: 0))
        }
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
