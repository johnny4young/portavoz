import Foundation
import PortavozCore
import Testing
import TranscriptionKit

@testable import portavoz_app
@testable import PortavozTestSupport

/// The history names the lane that transcribed, not the one selected in Settings.
@Suite(.serialized, .exclusiveArgumentDomain, .timeLimit(.minutes(1)))
@MainActor
struct DictationHistoryEngineTests {
    @Test
    func parakeetCheckpointsMapToTheirLanes() {
        #expect(LiveSpeechSelection(checkpoint: .v3) == .parakeet)
        #expect(LiveSpeechSelection(checkpoint: .ultra) == .parakeetUltra)
    }

    @Test(arguments: [LiveSpeechSelection.parakeet, .parakeetUltra, .appleSpeech])
    func theRecordNamesTheLaneThatRan(lane: LiveSpeechSelection) async throws {
        let harness = DictationControllerHarness(text: "no borres estas notas")
        defer { harness.controller.cancel() }
        harness.defaults.set(
            lane == .parakeetUltra ? LiveSpeechSelection.appleSpeech.rawValue : LiveSpeechSelection.parakeetUltra.rawValue,
            forKey: LiveSpeechSelection.dictationKey)
        harness.lane = lane
        #expect(try await dictate(harness).map(\.engine) == [lane.rawValue])
    }

    @Test
    func aRuntimeWithoutALaneKeepsTheSelectedLane() async throws {
        let harness = DictationControllerHarness(text: "no borres estas notas")
        defer { harness.controller.cancel() }
        harness.defaults.set(LiveSpeechSelection.appleSpeech.rawValue, forKey: LiveSpeechSelection.dictationKey)
        #expect(try await dictate(harness).map(\.engine) == [LiveSpeechSelection.appleSpeech.rawValue])
    }

    private final class Recorder {
        var records: [DictationRecord] = []
    }

    private func dictate(_ harness: DictationControllerHarness) async throws -> [DictationRecord] {
        let recorder = Recorder()
        var dependencies = harness.dependencies
        dependencies.beginHistory = { { record in recorder.records.append(record); return true } }
        harness.controller.toggle(using: dependencies)
        try #require(await TestPolling.until { harness.controller.partialText == harness.text })
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        try #require(await TestPolling.until { recorder.records.count == 1 })
        return recorder.records
    }
}
