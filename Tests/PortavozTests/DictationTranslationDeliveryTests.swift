import ApplicationKit
import Foundation
import PortavozCore
import Testing

@testable import portavoz_app

/// Recognition is scripted; every case enters the real session, translation and final delivery.
// Preferences go to the harness suite: other suites reset the process-wide argument domain.
@Suite(.serialized, .exclusiveArgumentDomain, .timeLimit(.minutes(1)))
@MainActor
struct DictationTranslationDeliveryTests {
    private final class Recorder {
        var translations: [(text: String, source: String?, target: String)] = []
        var polishCalls: [String] = []
        var records: [DictationRecord] = []
    }

    private func dependencies(
        _ harness: DictationControllerHarness, recorder: Recorder,
        translate: @escaping (String) async -> DictationTranslationOutcome
    ) -> DictationSessionDependencies {
        var dependencies = harness.dependencies
        dependencies.beginHistory = { { record in recorder.records.append(record); return true } }
        dependencies.polishDictation = { text, _, _ in
            recorder.polishCalls.append(text)
            return .polished("No borres estas notas!")
        }
        dependencies.translateDictation = { text, source, target in
            recorder.translations.append((text, source, target))
            return await translate(text)
        }
        return dependencies
    }

    private func harness(
        target: DictationTranslationTarget, mode: DictationTextMode = .clean
    ) -> DictationControllerHarness {
        let harness = DictationControllerHarness(text: "um no borres estas notas")
        harness.defaults.set(mode.rawValue, forKey: DictationTextPreferences.modeKey)
        harness.defaults.set(target.rawValue, forKey: DictationTextPreferences.translationKey)
        harness.defaults.set("es", forKey: DictationController.languageKey)
        return harness
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
    func aTranslatedDictationPastesTheTranslationAndKeepsTheOriginal() async throws {
        let harness = harness(target: .english)
        defer { harness.controller.cancel() }
        let recorder = Recorder()
        let dependencies = dependencies(harness, recorder: recorder) { _ in .translated("Don't delete these notes") }
        try await dictate(harness, dependencies)
        try await eventually { harness.insertions.count == 1 && recorder.records.count == 1 }
        #expect(recorder.translations.map(\.text) == ["no borres estas notas"])
        #expect(recorder.translations.first?.source == "es")
        #expect(recorder.translations.first?.target == "en")
        #expect(harness.insertions == ["Don't delete these notes"])
        #expect(harness.controller.polishNotice == nil)
        #expect(harness.controller.lastText.currentAlternate == "no borres estas notas")
        #expect(harness.controller.lastText.alternateIsOriginal)
        #expect(recorder.records.first?.text == "Don't delete these notes")
        #expect(recorder.records.first?.mode == .clean)
        try await eventually { !harness.controller.isActive }
        harness.controller.pasteLastDictation(using: dependencies, alternate: true)
        try await eventually { harness.insertions.count == 2 }
        #expect(harness.insertions.last == "no borres estas notas")
    }

    @Test
    func polishRunsBeforeTranslation() async throws {
        let harness = harness(target: .english, mode: .polish)
        defer { harness.controller.cancel() }
        let recorder = Recorder()
        try await dictate(harness, dependencies(harness, recorder: recorder) { _ in
            .translated("Don't delete these notes!")
        })
        try await eventually { harness.insertions.count == 1 && recorder.records.count == 1 }
        #expect(recorder.polishCalls == ["no borres estas notas"])
        #expect(recorder.translations.map(\.text) == ["No borres estas notas!"])
        #expect(harness.insertions == ["Don't delete these notes!"])
        #expect(harness.controller.lastText.currentAlternate == "No borres estas notas!")
        #expect(recorder.records.first?.mode == .polish)
    }

    @Test
    func missingLanguagesPasteTheOriginalAndSaySo() async throws {
        let harness = harness(target: .english)
        defer { harness.controller.cancel() }
        let recorder = Recorder()
        try await dictate(harness, dependencies(harness, recorder: recorder) { _ in .kept(.notInstalled) })
        try await eventually { harness.insertions.count == 1 }
        #expect(harness.insertions == ["no borres estas notas"])
        #expect(harness.controller.polishNotice?.hasPrefix("Pasted without translation") == true)
        #expect(harness.controller.polishNotice?.contains("Settings") == true)
        #expect(!harness.controller.hasAlternateText)
    }

    @Test
    func skippingWhileTranslatingPastesTheOriginalAtOnce() async throws {
        let harness = harness(target: .english)
        defer { harness.controller.cancel() }
        let recorder = Recorder()
        try await dictate(harness, dependencies(harness, recorder: recorder) { text in
            try? await Task.sleep(for: .seconds(30))
            return .translated(text.uppercased())
        })
        try await eventually { harness.controller.isTranslating }
        #expect(!harness.controller.isPolishing)
        harness.controller.skipPolish()
        try await eventually { harness.insertions.count == 1 }
        #expect(harness.insertions == ["no borres estas notas"])
        #expect(!harness.controller.isTranslating)
        #expect(harness.controller.polishNotice == "Pasted without translation.")
    }

    @Test
    func offNeverReachesTheTranslator() async throws {
        let harness = harness(target: .off)
        defer { harness.controller.cancel() }
        let recorder = Recorder()
        try await dictate(harness, dependencies(harness, recorder: recorder) { _ in .translated("Never.") })
        try await eventually { harness.insertions.count == 1 }
        #expect(recorder.translations.isEmpty)
        #expect(harness.insertions == ["no borres estas notas"])
    }

    @Test
    func theStripChoiceAppliesToThisDictationOnly() async throws {
        let harness = harness(target: .off)
        defer { harness.controller.cancel() }
        let recorder = Recorder()
        let dependencies = dependencies(harness, recorder: recorder) { _ in .translated("Don't delete these notes") }
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.controller.selectTranslationTarget(.english)
        #expect(harness.controller.translationTarget == .english)
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.insertions.count == 1 }
        #expect(harness.insertions == ["Don't delete these notes"])
        #expect(DictationTextPreferences.globalTranslationTarget(in: harness.defaults) == .off)
    }

    @Test
    func anApplicationProfileOverridesTheDefaultTarget() throws {
        let defaults = try #require(UserDefaults(suiteName: "translation-\(UUID().uuidString)"))
        defaults.set("en", forKey: DictationTextPreferences.translationKey)
        let profiles = [
            DictationApplicationTextProfile(
                bundleIdentifier: "com.example.mail", mode: .clean, translationTarget: .spanish),
            DictationApplicationTextProfile(bundleIdentifier: "com.example.notes", mode: .clean),
        ]
        defaults.set(try DictationTextPreferences.encodeProfiles(profiles), forKey: DictationTextPreferences.profilesKey)
        func target(_ app: String?) -> DictationTranslationTarget {
            DictationTextPreferences.snapshot(in: defaults, bundleIdentifier: app).translationTarget
        }
        #expect(target("com.example.mail") == .spanish)
        #expect(target("com.example.notes") == .english)
        #expect(target(nil) == .english)
        defaults.removeObject(forKey: DictationTextPreferences.translationKey)
        #expect(target("com.example.notes") == .off)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        _ = await TestPolling.until(condition)
        try #require(condition(), "The real controller must reach the asserted lifecycle boundary")
    }
}
