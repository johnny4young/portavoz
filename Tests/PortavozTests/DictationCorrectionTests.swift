import Foundation
import PortavozCore
import Testing
import TranscriptionKit

@testable import portavoz_app

struct DictationCorrectionCommandTests {
    @Test(arguments: [
        ("Change Friday to Monday.", DictationCorrectionCommand.replace("Friday", with: "Monday")),
        ("replace the draft with the final version", .replace("the draft", with: "the final version")),
        ("Cambia viernes por lunes.", .replace("viernes", with: "lunes")),
        ("reemplaza borrador por versión final", .replace("borrador", with: "versión final")),
        ("Delete Friday", .delete("Friday")),
        ("borra viernes", .delete("viernes")),
        ("Scratch that.", .deleteLast),
        ("borra eso", .deleteLast),
        ("Bórralo", .deleteLast)
    ])
    func spokenCommandsParseInEnglishAndSpanish(_ example: (String, DictationCorrectionCommand)) {
        #expect(DictationCorrectionCommand.parse(example.0) == example.1)
    }

    @Test(arguments: ["Let's meet on Friday", "No borres estas notas", "", "change"])
    func ordinaryDictationIsNotACommand(_ text: String) {
        #expect(DictationCorrectionCommand.parse(text) == nil)
    }

    @Test
    func aCommandAppliesOnlyToWhatTheInsertionContains() {
        let inserted = "Ship it on Friday, then tell Ana on Friday evening."
        let edit = DictationCorrectionCommand.replace("friday", with: "monday").edit(in: inserted)
        #expect(edit?.range == (inserted as NSString).range(of: "Friday", options: .backwards))
        #expect(edit?.replacement == "Monday")
        #expect(DictationCorrectionCommand.replace("of plans", with: "monday").edit(in: inserted) == nil)
        #expect(DictationCorrectionCommand.replace("Fri", with: "Mon").edit(in: inserted) == nil)
        let deletion = DictationCorrectionCommand.delete("then").edit(in: inserted)
        #expect(deletion?.range == (inserted as NSString).range(of: "then "))
        #expect(DictationCorrectionCommand.deleteLast.edit(in: inserted)?.range
            == NSRange(location: 0, length: inserted.utf16.count))
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct DictationCorrectionDeliveryTests {
    private func dependencies(
        _ harness: DictationControllerHarness, receiver: DictationFixtureReceiver
    ) -> DictationSessionDependencies {
        // The suite's own domain: other harnesses reset the process-wide argument domain.
        harness.defaults.set(true, forKey: DictationCorrections.defaultsKey)
        var dependencies = harness.dependencies
        dependencies.captureDestination = {
            var destination = CapturedDictationDestination(name: "Receiver", canRetry: true) { receiver.insert($0) }
            destination.lastInsertion = { receiver.last }
            return destination
        }
        return dependencies
    }

    private func dictate(_ harness: DictationControllerHarness, _ dependencies: DictationSessionDependencies) async throws {
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        try await eventually { !harness.controller.isActive }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        _ = await TestPolling.until(condition)
        try #require(condition())
    }

    @Test
    func aSpokenCorrectionEditsOnlyTheLastInsertion() async throws {
        let receiver = DictationFixtureReceiver()
        _ = receiver.insert("Earlier text. ")
        let first = DictationControllerHarness(text: "ship it on friday")
        defer { first.controller.cancel() }
        try await dictate(first, dependencies(first, receiver: receiver))
        #expect(receiver.text == "Earlier text. ship it on friday")
        let command = DictationControllerHarness(text: "um change friday to monday", controller: first.controller)
        try await dictate(command, dependencies(command, receiver: receiver))
        #expect(receiver.text == "Earlier text. ship it on monday")
        #expect(first.controller.correctionSummary == "Changed “friday” to “monday”.")
        #expect(first.controller.lastText.current == "ship it on monday")
    }

    @Test
    func aCorrectionIsLearnedOnlyWhenChosenAndAppliesToTheNextDictation() async throws {
        let receiver = DictationFixtureReceiver()
        let first = DictationControllerHarness(text: "ship it on friday")
        defer { first.controller.cancel() }
        try await dictate(first, dependencies(first, receiver: receiver))
        let command = DictationControllerHarness(text: "change friday to monday", controller: first.controller)
        try await dictate(command, dependencies(command, receiver: receiver))
        let offered = try #require(first.controller.learnableCorrection)
        #expect(offered.rule == DictationReplacement(trigger: "friday", replacement: "monday"))
        #expect(command.defaults.string(forKey: DictationController.replacementsKey) == nil)
        first.controller.learnCorrection()
        #expect(first.controller.learnableCorrection == nil)
        #expect(first.controller.correctionSummary == "From now on, “friday” is written “monday”.")
        let rules = DictationTextRules.decode(
            replacements: command.defaults.string(forKey: DictationController.replacementsKey) ?? "")
        #expect(rules == [DictationReplacement(trigger: "friday", replacement: "monday")])
        let next = DictationControllerHarness(text: "see you friday", controller: first.controller)
        var learned = dependencies(next, receiver: receiver)
        learned.defaults = command.defaults
        try await dictate(next, learned)
        #expect(receiver.text.hasSuffix("see you monday"))
    }

    @Test
    func deletionsAndKnownRulesAreNotOffered() async throws {
        let receiver = DictationFixtureReceiver()
        let first = DictationControllerHarness(text: "ship it on friday please")
        defer { first.controller.cancel() }
        try await dictate(first, dependencies(first, receiver: receiver))
        let deletion = DictationControllerHarness(text: "delete please", controller: first.controller)
        try await dictate(deletion, dependencies(deletion, receiver: receiver))
        #expect(first.controller.correctionSummary == "Deleted “please”.")
        #expect(first.controller.learnableCorrection == nil)
        let known = DictationControllerHarness(text: "change friday to monday", controller: first.controller)
        known.defaults.set(
            DictationTextRules.encode([DictationReplacement(trigger: "friday", replacement: "monday")]),
            forKey: DictationController.replacementsKey)
        try await dictate(known, dependencies(known, receiver: receiver))
        #expect(first.controller.correctionSummary == "Changed “friday” to “monday”.")
        #expect(first.controller.learnableCorrection == nil)
    }

    @Test
    func withCorrectionsOffTheCommandIsPastedAsText() async throws {
        let receiver = DictationFixtureReceiver()
        let first = DictationControllerHarness(text: "ship it on friday")
        defer { first.controller.cancel() }
        try await dictate(first, dependencies(first, receiver: receiver))
        let command = DictationControllerHarness(text: "change friday to monday", controller: first.controller)
        var off = dependencies(command, receiver: receiver)
        command.defaults.set(false, forKey: DictationCorrections.defaultsKey)
        off.defaults = command.defaults
        try await dictate(command, off)
        #expect(receiver.text.hasSuffix("change friday to monday"))
    }

    @Test
    func aPhraseThatOnlyLooksLikeACommandIsPasted() async throws {
        let receiver = DictationFixtureReceiver()
        let first = DictationControllerHarness(text: "ship it on friday")
        defer { first.controller.cancel() }
        try await dictate(first, dependencies(first, receiver: receiver))
        let ordinary = DictationControllerHarness(text: "change of plans to monday", controller: first.controller)
        try await dictate(ordinary, dependencies(ordinary, receiver: receiver))
        #expect(receiver.text.hasSuffix("change of plans to monday"))
        #expect(first.controller.correctionSummary == nil)
    }

    @Test
    func aChangedFieldIsNeverCorrectedAndTheCommandIsNotPasted() async throws {
        let receiver = DictationFixtureReceiver()
        let first = DictationControllerHarness(text: "ship it on friday")
        defer { first.controller.cancel() }
        var changed = dependencies(first, receiver: receiver)
        changed.captureDestination = {
            var destination = CapturedDictationDestination(name: "Receiver", canRetry: true) { receiver.insert($0) }
            // The user typed over the insertion after Portavoz pasted it.
            destination.lastInsertion = {
                DictationInsertion(
                    text: "ship it on friday", insertedAt: Date(), isIntact: { false },
                    edit: { _, _ in
                        Issue.record("A changed field must never be edited")
                        return nil
                    })
            }
            return destination
        }
        try await dictate(first, changed)
        let command = DictationControllerHarness(text: "change friday to monday", controller: first.controller)
        let beforeCommand = receiver.text
        command.controller.toggle(using: dependencies(command, receiver: receiver))
        try await eventually { command.controller.partialText == command.text }
        command.now = command.now.addingTimeInterval(1)
        command.controller.toggle(using: dependencies(command, receiver: receiver))
        try await eventually {
            if case .failed = command.controller.phase { return true }
            return false
        }
        #expect(receiver.text == beforeCommand)
    }
}
