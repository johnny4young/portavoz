import Foundation
import PortavozCore
import Testing
import TranscriptionKit

@testable import portavoz_app

/// The history names the lane that transcribed, not the one selected in Settings.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct DictationHistoryEngineTests {
    @Test
    func engineIDsMapToTheirLanes() {
        #expect(LiveSpeechSelection(engineID: ParakeetCheckpoint.v3.engineID) == .parakeet)
        #expect(LiveSpeechSelection(engineID: ParakeetCheckpoint.ultra.engineID) == .parakeetUltra)
        #expect(LiveSpeechSelection(engineID: SpeechAnalyzerLiveEngine.engineIDPrefix + "es-ES") == .appleSpeech)
        #expect(LiveSpeechSelection(engineID: "controlled") == nil)
    }

    @Test(arguments: [
        (ParakeetCheckpoint.v3.engineID, LiveSpeechSelection.parakeet),
        (ParakeetCheckpoint.ultra.engineID, .parakeetUltra),
        (SpeechAnalyzerLiveEngine.engineIDPrefix + "en-US", .appleSpeech),
    ])
    func theRecordNamesTheEngineThatRan(engineID: String, expected: LiveSpeechSelection) async throws {
        let harness = DictationControllerHarness(text: "no borres estas notas")
        defer { harness.controller.cancel() }
        harness.defaults.set(LiveSpeechSelection.parakeetUltra.rawValue, forKey: LiveSpeechSelection.dictationKey)
        harness.engineID = engineID
        let records = try await dictate(harness)
        #expect(records.map(\.engine) == [expected.rawValue])
    }

    @Test
    func anUnknownEngineKeepsTheSelectedLane() async throws {
        let harness = DictationControllerHarness(text: "no borres estas notas")
        defer { harness.controller.cancel() }
        harness.defaults.set(LiveSpeechSelection.appleSpeech.rawValue, forKey: LiveSpeechSelection.dictationKey)
        let records = try await dictate(harness)
        #expect(records.map(\.engine) == [LiveSpeechSelection.appleSpeech.rawValue])
    }

    private final class Recorder {
        var records: [DictationRecord] = []
    }

    private func dictate(_ harness: DictationControllerHarness) async throws -> [DictationRecord] {
        let recorder = Recorder()
        var dependencies = harness.dependencies
        dependencies.beginHistory = { { record in recorder.records.append(record); return true } }
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        try await eventually { recorder.records.count == 1 }
        return recorder.records
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "The real controller must reach the asserted lifecycle boundary")
    }
}
