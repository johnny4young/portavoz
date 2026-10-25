import ApplicationKit
import Foundation
import PortavozCore
import Testing

@testable import portavoz_app

/// Recognition is scripted; every case enters the real session, polish and final delivery.
// The controller harness overrides process-wide NSArgumentDomain, so the suite is serialized.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct DictationPolishDeliveryTests {
    private final class Recorder {
        var polishCalls: [String] = []
        var recipes: [String?] = []
        var capturesEnded = 0
        var capturesEndedBeforePolish: Int?
        var records: [DictationRecord] = []
    }

    private func dependencies(
        _ harness: DictationControllerHarness, recorder: Recorder,
        polish: @escaping (String) async -> DictationPolishOutcome
    ) -> DictationSessionDependencies {
        var dependencies = harness.dependencies
        dependencies.beginCapture = { { recorder.capturesEnded += 1 } }
        dependencies.beginHistory = { { record in recorder.records.append(record); return true } }
        dependencies.polishDictation = { text, _, recipe in
            recorder.polishCalls.append(text)
            recorder.recipes.append(recipe)
            recorder.capturesEndedBeforePolish = recorder.capturesEnded
            return await polish(text)
        }
        return dependencies
    }

    private func dictate(
        _ harness: DictationControllerHarness, _ dependencies: DictationSessionDependencies
    ) async throws {
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
    }

    @Test
    func aPolishedDictationPastesTheRewriteAndKeepsTheCleanText() async throws {
        let harness = DictationControllerHarness(text: "um so we ship it tomorrow")
        defer { harness.controller.cancel() }
        harness.set(DictationTextMode.polish.rawValue, forKey: DictationTextPreferences.modeKey)
        let recorder = Recorder()
        try await dictate(harness, dependencies(harness, recorder: recorder) { _ in
            .polished("So we ship it tomorrow.")
        })
        try await eventually { harness.insertions.count == 1 && recorder.records.count == 1 }
        #expect(recorder.polishCalls == ["so we ship it tomorrow"])
        #expect(recorder.capturesEndedBeforePolish == 1)
        #expect(harness.insertions == ["So we ship it tomorrow."])
        #expect(harness.controller.polishNotice == nil)
        #expect(harness.controller.lastText.current == "So we ship it tomorrow.")
        #expect(harness.controller.lastText.currentUnpolished == "so we ship it tomorrow")
        #expect(harness.controller.hasUnpolishedText)
        #expect(recorder.records.first?.text == "So we ship it tomorrow.")
        #expect(recorder.records.first?.mode == .polish)
        #expect(recorder.records.first?.originalText == "um so we ship it tomorrow")
    }

    @Test
    func aKeptDictationPastesCleanAndSaysWhy() async throws {
        let harness = DictationControllerHarness(text: "um don't ship it tomorrow")
        defer { harness.controller.cancel() }
        harness.set(DictationTextMode.polish.rawValue, forKey: DictationTextPreferences.modeKey)
        let recorder = Recorder()
        try await dictate(harness, dependencies(harness, recorder: recorder) { _ in
            .kept(.changedMeaning(.negation))
        })
        try await eventually { harness.insertions.count == 1 && recorder.records.count == 1 }
        #expect(harness.insertions == ["don't ship it tomorrow"])
        #expect(harness.controller.polishNotice != nil)
        #expect(!harness.controller.hasUnpolishedText)
        #expect(recorder.records.first?.mode == .clean)
        #expect(recorder.records.first?.text == "don't ship it tomorrow")
    }

    @Test
    func skippingWhilePolishingPastesTheCleanTextAtOnce() async throws {
        let harness = DictationControllerHarness(text: "so we ship it tomorrow")
        defer { harness.controller.cancel() }
        harness.set(DictationTextMode.polish.rawValue, forKey: DictationTextPreferences.modeKey)
        let recorder = Recorder()
        try await dictate(harness, dependencies(harness, recorder: recorder) { text in
            try? await Task.sleep(for: .seconds(30))
            return .polished(text.uppercased())
        })
        try await eventually { harness.controller.isPolishing }
        #expect(harness.controller.phase == .delivering)
        harness.controller.skipPolish()
        try await eventually { harness.insertions.count == 1 }
        #expect(harness.insertions == ["so we ship it tomorrow"])
        #expect(!harness.controller.isPolishing)
        #expect(harness.controller.polishNotice == "Pasted without polish.")
    }

    @Test
    func theChosenRecipeReachesTheEngine() async throws {
        let harness = DictationControllerHarness(text: "so we ship it tomorrow")
        defer { harness.controller.cancel() }
        harness.set(DictationTextMode.polish.rawValue, forKey: DictationTextPreferences.modeKey)
        harness.set("builtin.bullets", forKey: DictationTextPreferences.polishRecipeKey)
        let recorder = Recorder()
        try await dictate(harness, dependencies(harness, recorder: recorder) { _ in .polished("- So we ship it.") })
        try await eventually { harness.insertions.count == 1 }
        let bullets = try #require(DictationRecipe.builtIns.first { $0.id == "builtin.bullets" })
        #expect(recorder.recipes == [bullets.instruction])
        #expect(harness.insertions == ["- So we ship it."])
    }

    @Test(arguments: [DictationTextMode.literal, .clean])
    func otherModesNeverReachTheEngine(_ mode: DictationTextMode) async throws {
        let harness = DictationControllerHarness(text: "um so we ship it tomorrow")
        defer { harness.controller.cancel() }
        harness.set(mode.rawValue, forKey: DictationTextPreferences.modeKey)
        let recorder = Recorder()
        try await dictate(harness, dependencies(harness, recorder: recorder) { _ in .polished("Never.") })
        try await eventually { harness.insertions.count == 1 }
        #expect(recorder.polishCalls.isEmpty)
        #expect(!harness.controller.hasUnpolishedText)
    }

    @Test
    func pasteWithoutPolishReplaysTheCleanText() async throws {
        let harness = DictationControllerHarness(text: "so we ship it tomorrow")
        defer { harness.controller.cancel() }
        harness.set(DictationTextMode.polish.rawValue, forKey: DictationTextPreferences.modeKey)
        let recorder = Recorder()
        let dependencies = dependencies(harness, recorder: recorder) { _ in .polished("So we ship it tomorrow.") }
        try await dictate(harness, dependencies)
        try await eventually { harness.insertions.count == 1 && !harness.controller.isActive }
        harness.controller.pasteLastDictation(using: dependencies, unpolished: true)
        try await eventually { harness.insertions.count == 2 }
        #expect(harness.insertions.last == "so we ship it tomorrow")
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "The real controller must reach the asserted lifecycle boundary")
    }
}
