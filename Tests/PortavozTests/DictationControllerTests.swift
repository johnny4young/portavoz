import AppKit
import AudioCaptureKit
import Foundation
import PortavozCore
import TranscriptionKit
import XCTest

@testable import portavoz_app

@MainActor
final class DictationControllerTests: XCTestCase {
    func testInvalidNativeEventTargetDoesNotBorrowClipboardOrFallBackToSession() async {
        let board = NSPasteboard(name: .init("app.portavoz.dictation-test." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("Do not replace — no reemplazar", forType: .string)
        let originalCount = board.changeCount
        for processID: pid_t in [0, -1, .min] {
            let result = await TextInserter.insert(
                "Must never be delivered", pasteboard: board, eventTarget: .process(processID))
            XCTAssertEqual(result, .eventUnavailable)
            XCTAssertEqual(board.changeCount, originalCount)
            XCTAssertEqual(board.string(forType: .string), "Do not replace — no reemplazar")
        }
    }

    func testExitedProcessTargetFailsBeforeClipboardMutation() async throws {
        let board = NSPasteboard(name: .init("app.portavoz.dictation-test." + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let originalCount = board.changeCount
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        let target = TextInserter.EventTarget.process(exited.processIdentifier)
        XCTAssertFalse(target.isAvailable)
        let result = await TextInserter.insert("Must never be delivered", pasteboard: board, eventTarget: target)
        XCTAssertEqual(result, .eventUnavailable)
        XCTAssertEqual(board.changeCount, originalCount)
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testNativeFixtureRequiresTemporaryCompositionExplicitActionAndUUIDClipboard() async {
        let key = DictationNativeUITestFixture.environmentKey
        let name = DictationNativeUITestFixture.pasteboardPrefix + UUID().uuidString
        for temporary in [false, true] {
            for arguments in [[], ["-seed-dictation"], ["-seed-dictation-native"]] {
                for candidate in [nil, "", "NSGeneralPboard", "app.portavoz.dictation-test.invalid", name] {
                    let environment = candidate.map { [key: $0] } ?? [:]
                    let fixture = DictationNativeUITestFixture(
                        arguments: arguments, environment: environment, usesTemporaryStore: temporary)
                    let admitted = temporary && arguments == ["-seed-dictation-native"] && candidate == name
                    XCTAssertEqual(fixture != nil, admitted)
                    if let fixture {
                        XCTAssertEqual(fixture.status, "idle", "Construction must not arm native input")
                    }
                }
            }
        }
    }

    func testPermissionDenialDoesNotPrepareAudioOrModels() async {
        let harness = Harness(text: "No borres estas notas.")
        var dependencies = harness.dependencies
        dependencies.canInsert = { false }
        harness.controller.toggle(using: dependencies)
        guard case .failed = harness.controller.phase else {
            return XCTFail("permission denial must remain an actionable failure")
        }
        XCTAssertEqual(harness.loads, 0)
        let starts = await harness.microphone.starts
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(harness.insertions.isEmpty)
        harness.controller.cancel()
    }

    func testCancelAfterPartialNeverDeliversAndReleasesRuntime() async {
        for text in ["No borres estas notas.", "Don’t delete these notes."] {
            let harness = Harness(text: text)
            harness.controller.toggle(using: harness.dependencies)
            let reached1 = await awaitEventually { harness.controller.partialText == text }
            XCTAssertTrue(reached1)
            harness.controller.cancel()
            XCTAssertEqual(harness.controller.phase, .idle)
            let reached2 = await awaitEventually { harness.finishes == 1 }
            XCTAssertTrue(reached2)
            XCTAssertTrue(harness.insertions.isEmpty)
        }
    }

    func testFinalTextRunsThroughRealRulesAndSuppliesHintsToEngine() async {
        let harness = Harness(text: "eh Café C++")
        harness.set("es", forKey: DictationController.languageKey)
        harness.set("Kubernetes, Café", forKey: "customVocabulary")
        harness.set(
            #"[{"trigger":"C++","replacement":"Swift $5\\path"}]"#,
            forKey: DictationController.replacementsKey)
        harness.controller.toggle(using: harness.dependencies)
        let reached3 = await awaitEventually { !harness.controller.partialText.isEmpty }
        XCTAssertTrue(reached3)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: harness.dependencies)
        let reached4 = await awaitEventually { !harness.insertions.isEmpty }
        XCTAssertTrue(reached4)
        XCTAssertEqual(harness.insertions, ["Café Swift $5\\path"])
        XCTAssertEqual(harness.hints?.language, "es")
        XCTAssertEqual(harness.hints?.vocabulary, ["Kubernetes", "Café"])
        harness.controller.cancel()
        let reached5 = await awaitEventually { harness.finishes == 1 }
        XCTAssertTrue(reached5)
    }

    func testPunctuationOnlyFinalDoesNotInvokeInsertion() async {
        let harness = Harness(text: "… — !!!")
        harness.controller.toggle(using: harness.dependencies)
        let reached6 = await awaitEventually { harness.hints != nil }
        XCTAssertTrue(reached6)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: harness.dependencies)
        let reached7 = await awaitEventually { harness.finishes == 1 }
        XCTAssertTrue(reached7)
        XCTAssertEqual(harness.controller.phase, .idle)
        XCTAssertTrue(harness.insertions.isEmpty)
    }

    func testCancelDuringModelPreparationCannotStartMicrophoneLater() async {
        let harness = Harness(text: "Late text must not appear")
        let gate = PreparationGate()
        var dependencies = harness.dependencies
        let load = dependencies.acquireRuntime
        dependencies.acquireRuntime = {
            await gate.wait()
            return try await load()
        }
        harness.controller.toggle(using: dependencies)
        let reached8 = await awaitEventually { gate.started }
        XCTAssertTrue(reached8)
        harness.controller.cancel()
        gate.release()
        let reached9 = await awaitEventually { harness.finishes == 1 }
        XCTAssertTrue(reached9)
        let starts = await harness.microphone.starts
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(harness.insertions.isEmpty)
        XCTAssertEqual(harness.controller.phase, .idle)
    }

    func testFixtureFlagsAreInertOutsideTemporaryComposition() async {
        XCTAssertNil(DictationUITestFixture(
            arguments: ["-seed-dictation"], usesTemporaryStore: false))
        XCTAssertNil(DictationUITestFixture(arguments: [], usesTemporaryStore: true))
        XCTAssertNotNil(DictationUITestFixture(
            arguments: ["-seed-dictation"], usesTemporaryStore: true))
        XCTAssertFalse(DictationUITestFixture.dependencies(fixture: nil).canInsert())
    }

    private func awaitEventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

@MainActor
private final class Harness {
    let controller = DictationController(presentsPanel: false)
    let microphone = ControlledDictationMicrophone()
    let defaults = UserDefaults(suiteName: "dictation-tests-\(UUID().uuidString)")!
    let text: String
    var now = Date(timeIntervalSince1970: 1_000)
    var loads = 0
    var finishes = 0
    var hints: TranscriptionHints?
    var insertions: [String] = []

    init(text: String) {
        self.text = text
        defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
    }

    func set(_ value: Any, forKey key: String) {
        var values = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        values[key] = value
        defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
    }

    var dependencies: DictationSessionDependencies {
        DictationSessionDependencies(
            makeMicrophone: { [microphone] in .init(source: microphone, warmUp: {}) },
            acquireRuntime: { [weak self] in
                guard let self else { throw CancellationError() }
                self.loads += 1
                return LiveTranscriptionRuntime(engine: ControlledDictationEngine(
                    text: self.text, receivedHints: { [weak self] in self?.hints = $0 })) { [weak self] in
                    self?.finishes += 1
                }
            },
            canInsert: { true }, targetName: { "Disposable receiver" },
            insert: { [weak self] text in
                self?.insertions.append(text)
                return .inserted
            },
            defaults: defaults, now: { [weak self] in self?.now ?? .distantPast })
    }
}

private actor ControlledDictationMicrophone: AudioCaptureSource {
    nonisolated let channel = AudioChannel.microphone
    private(set) var starts = 0
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?

    func start() async throws -> AsyncThrowingStream<AudioChunk, Error> {
        starts += 1
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        continuation.yield(AudioChunk(
            channel: .microphone, samples: [0.1], sampleRate: 16_000, timestamp: 0))
        return stream
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }
}

private struct ControlledDictationEngine: TranscriptionEngine {
    let text: String
    let receivedHints: @MainActor @Sendable (TranscriptionHints) -> Void
    let descriptor = EngineDescriptor(
        id: "controlled", displayName: "Controlled", realTimeFactor: 0,
        runsOnDevice: true, approximateMemoryMB: 0)

    func transcribe(
        _ audio: AsyncStream<AudioChunk>, hints: TranscriptionHints
    ) -> AsyncThrowingStream<TranscriptSegment, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptSegment.self)
        let task = Task {
            await receivedHints(hints)
            for await _ in audio {
                continuation.yield(TranscriptSegment(
                    meetingID: hints.meetingID!, channel: .microphone,
                    text: text, startTime: 0, endTime: 1))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

@MainActor
private final class PreparationGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
