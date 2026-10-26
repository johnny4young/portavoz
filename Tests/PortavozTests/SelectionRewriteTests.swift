import AppKit
import ApplicationKit
import Carbon.HIToolbox
import Foundation
import PortavozCore
import Testing

@testable import portavoz_app

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct SelectionRewriteControllerTests {
    private final class Recorder {
        var insertions: [String] = []
        var recipes: [String?] = []
        var copies: [String] = []
        var keys: [UInt32: () -> Void] = [:]
        var changed = false
    }

    private final class Registration: GlobalHotkeyRegistration {
        let onUnregister: () -> Void
        init(onUnregister: @escaping () -> Void) { self.onUnregister = onUnregister }
        func unregister() { onUnregister() }
    }

    private func dependencies(
        _ recorder: Recorder,
        capture: Result<String, SelectionRewriteFailure> = .success("so we ship it tomorrow"),
        polish: @escaping (String, String?) async -> DictationPolishOutcome
    ) -> SelectionRewriteController.Dependencies {
        SelectionRewriteController.Dependencies(
            capture: {
                capture.map { text in
                    CapturedSelection(
                        text: text, source: .accessibility, applicationName: "Receiver",
                        revalidate: { recorder.changed ? .selectionChanged : nil },
                        destination: CapturedDictationDestination(name: "Receiver", canRetry: false) { text in
                            recorder.insertions.append(text)
                            return .verified
                        })
                }
            },
            polish: { text, _, recipe in
                recorder.recipes.append(recipe)
                return await polish(text, recipe)
            },
            recipes: { DictationRecipe.builtIns },
            protectedTerms: { [] },
            copyText: { recorder.copies.append($0); return true },
            registerKey: { keyCode, onPress in
                recorder.keys[keyCode] = onPress
                return Registration { recorder.keys[keyCode] = nil }
            },
            wait: { _ in try await Task.sleep(for: .seconds(3_600)) })
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    @Test
    func nothingIsReplacedBeforeThePreviewIsAccepted() async throws {
        let recorder = Recorder()
        let controller = SelectionRewriteController(presentsPanel: false)
        defer { controller.cancel() }
        controller.start(using: dependencies(recorder) { _, _ in .polished("So we ship it tomorrow.") })
        try await eventually { controller.phase == .choosing }
        #expect(controller.original == "so we ship it tomorrow")
        #expect(recorder.keys[UInt32(kVK_Return)] == nil)
        controller.choose(nil)
        try await eventually { controller.phase == .preview("So we ship it tomorrow.") }
        #expect(recorder.insertions.isEmpty)
        #expect(recorder.recipes == [nil])
        let enter = try #require(recorder.keys[UInt32(kVK_Return)])
        enter()
        try await eventually { controller.phase == .replaced }
        #expect(recorder.insertions == ["So we ship it tomorrow."])
        #expect(recorder.keys.isEmpty)
    }

    @Test
    func aRecipeReachesTheEngineAndAKeptRewriteKeepsTheChoicesOpen() async throws {
        let recorder = Recorder()
        let controller = SelectionRewriteController(presentsPanel: false)
        defer { controller.cancel() }
        controller.start(using: dependencies(recorder) { _, _ in .kept(.changedMeaning(.negation)) })
        try await eventually { controller.phase == .choosing }
        let formal = try #require(DictationRecipe.builtIns.first)
        controller.choose(formal)
        try await eventually { controller.phase == .choosing && controller.notice != nil }
        #expect(recorder.recipes == [formal.instruction])
        #expect(controller.chosenRecipeID == formal.id)
        #expect(recorder.insertions.isEmpty)
    }

    @Test
    func aChangedSelectionIsNeverReplacedButTheRewriteCanBeCopied() async throws {
        let recorder = Recorder()
        let controller = SelectionRewriteController(presentsPanel: false)
        defer { controller.cancel() }
        controller.start(using: dependencies(recorder) { _, _ in .polished("So we ship it tomorrow.") })
        try await eventually { controller.phase == .choosing }
        controller.choose(nil)
        try await eventually { controller.result != nil }
        recorder.changed = true
        controller.replace()
        #expect(controller.phase == .failed(SelectionRewriteController.message(for: .selectionChanged)))
        #expect(recorder.insertions.isEmpty)
        controller.copyResult()
        #expect(recorder.copies == ["So we ship it tomorrow."])
        #expect(controller.copied)
    }

    @Test
    func aFailedCaptureExplainsWhy() async throws {
        let recorder = Recorder()
        let controller = SelectionRewriteController(presentsPanel: false)
        defer { controller.cancel() }
        controller.start(using: dependencies(recorder, capture: .failure(.secureField)) { _, _ in .polished("") })
        try await eventually { controller.phase == .failed(SelectionRewriteController.message(for: .secureField)) }
        #expect(recorder.recipes.isEmpty)
    }

    @Test
    func escapeAbandonsALateRewrite() async throws {
        let recorder = Recorder()
        let controller = SelectionRewriteController(presentsPanel: false)
        defer { controller.cancel() }
        controller.start(using: dependencies(recorder) { _, _ in
            try? await Task.sleep(for: .milliseconds(200))
            return .polished("Late.")
        })
        try await eventually { controller.phase == .choosing }
        controller.choose(nil)
        let escape = try #require(recorder.keys[UInt32(kVK_Escape)])
        escape()
        try await eventually { controller.phase == .idle }
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.phase == .idle)
        #expect(controller.result == nil)
        #expect(recorder.insertions.isEmpty)
    }
}

@MainActor
struct SelectionCopyClipboardTests {
    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: .init("app.portavoz.rewrite-test." + UUID().uuidString))
        board.clearContents()
        board.setString("The user's clipboard", forType: .string)
        return board
    }

    @Test
    func aCopiedSelectionIsReadAndTheClipboardRestored() async {
        let board = board()
        defer { board.releaseGlobally() }
        let copied = await DictationClipboard.shared.copySelection(on: board) {
            board.clearContents()
            return board.setString("the selected words", forType: .string)
        }
        #expect(copied == "the selected words")
        #expect(board.string(forType: .string) == "The user's clipboard")
    }

    @Test
    func anEditorThatCopiesNothingLeavesTheClipboardAlone() async {
        let board = board()
        defer { board.releaseGlobally() }
        let before = board.changeCount
        let copied = await DictationClipboard.shared.copySelection(on: board, timeout: .milliseconds(60)) { true }
        #expect(copied == nil)
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "The user's clipboard")
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct SelectionRewriteSayHowTests {
    private final class Recorder {
        var recipes: [String?] = []
        var insertions: [String] = []
        var dictating = false
    }

    private func dependencies(_ recorder: Recorder) -> SelectionRewriteController.Dependencies {
        var dependencies = SelectionRewriteController.Dependencies(
            capture: {
                .success(CapturedSelection(
                    text: "so we ship it tomorrow", source: .accessibility, applicationName: "Receiver",
                    revalidate: { nil },
                    destination: CapturedDictationDestination(name: "Receiver", canRetry: false) { text in
                        recorder.insertions.append(text)
                        return .verified
                    }))
            },
            polish: { text, _, recipe in
                recorder.recipes.append(recipe)
                return .polished(text.uppercased())
            },
            recipes: { [] }, protectedTerms: { [] }, copyText: { _ in true },
            wait: { _ in try await Task.sleep(for: .seconds(3_600)) })
        dependencies.isDictating = { recorder.dictating }
        return dependencies
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    @Test
    func theSpokenInstructionBecomesTheRecipeAndNothingIsDelivered() async throws {
        let recorder = Recorder()
        let rewrite = SelectionRewriteController(presentsPanel: false)
        defer { rewrite.cancel() }
        rewrite.start(using: dependencies(recorder))
        try await eventually { rewrite.phase == .choosing }
        #expect(rewrite.capturesInstruction)

        let harness = DictationControllerHarness(text: "um make it formal")
        defer { harness.controller.cancel() }
        harness.set(DictationTextMode.polish.rawValue, forKey: DictationTextPreferences.modeKey)
        var history: [DictationRecord] = []
        var base = harness.dependencies
        base.beginHistory = { { record in history.append(record); return true } }
        let session = rewrite.instructionDependencies(base)
        #expect(rewrite.phase == .listening)
        #expect(session.textModeOverride == .clean)
        #expect(session.deliversInternally)

        recorder.dictating = true
        harness.controller.toggle(using: session)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: session)
        try await eventually { rewrite.phase == .preview("SO WE SHIP IT TOMORROW") }
        recorder.dictating = false
        #expect(recorder.recipes == ["make it formal"])
        #expect(rewrite.spokenInstruction == "make it formal")
        #expect(harness.insertions.isEmpty)
        #expect(history.isEmpty)
        #expect(harness.controller.lastText.current == nil)
        try await eventually { harness.controller.phase == .idle }
        #expect(recorder.insertions.isEmpty)
    }

    @Test(arguments: [false, true])
    func aSpokenRewriteInstructionNeverCorrectsThePreviousDictation(_ refusesEdit: Bool) async throws {
        let receiver = DictationFixtureReceiver()
        // Harness construction clears the process-wide argument domain; keep other suites
        // intact across these synchronous, main-actor construction boundaries.
        let firstArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let first = DictationControllerHarness(text: "ship it on friday")
        first.defaults.setVolatileDomain(firstArguments, forName: UserDefaults.argumentDomain)
        defer { first.controller.cancel() }
        first.defaults.set(true, forKey: DictationCorrections.defaultsKey)
        var initial = first.dependencies
        var editCalls = 0
        initial.captureDestination = {
            var destination = CapturedDictationDestination(name: "Synthetic receiver", canRetry: true) {
                receiver.insert($0)
            }
            destination.lastInsertion = {
                guard let last = receiver.last else { return nil }
                return DictationInsertion(text: last.text, insertedAt: last.insertedAt, isIntact: last.isIntact) { range, replacement in
                    editCalls += 1
                    if refusesEdit { return nil }
                    return await last.edit(range, replacement)
                }
            }
            return destination
        }
        first.controller.toggle(using: initial)
        try await eventually { first.controller.partialText == first.text }
        first.now = first.now.addingTimeInterval(1)
        first.controller.toggle(using: initial)
        try await eventually { !first.controller.isActive }
        #expect(receiver.text == "ship it on friday")

        let recorder = Recorder()
        let rewrite = SelectionRewriteController(presentsPanel: false)
        defer { rewrite.cancel() }
        rewrite.start(using: dependencies(recorder))
        try await eventually { rewrite.phase == .choosing }
        let commandArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let command = DictationControllerHarness(text: "change friday to monday", controller: first.controller)
        command.defaults.setVolatileDomain(commandArguments, forName: UserDefaults.argumentDomain)
        command.defaults.set(true, forKey: DictationCorrections.defaultsKey)
        let session = rewrite.instructionDependencies(command.dependencies)
        recorder.dictating = true
        defer { recorder.dictating = false }
        command.controller.toggle(using: session)
        try await eventually { command.controller.partialText == command.text }
        command.now = command.now.addingTimeInterval(1)
        command.controller.toggle(using: session)
        try await eventually { !command.controller.isActive }
        #expect(receiver.text == "ship it on friday")
        #expect(editCalls == 0)
        #expect(rewrite.spokenInstruction == "change friday to monday")
        try await eventually { rewrite.phase == .preview("SO WE SHIP IT TOMORROW") }
        #expect(recorder.recipes == ["change friday to monday"])
        #expect(recorder.insertions.isEmpty)
    }

    @Test
    func aDictationThatEndsWithoutWordsReturnsToTheChoices() async throws {
        let recorder = Recorder()
        let rewrite = SelectionRewriteController(presentsPanel: false)
        defer { rewrite.cancel() }
        rewrite.start(using: dependencies(recorder))
        try await eventually { rewrite.phase == .choosing }
        _ = rewrite.instructionDependencies(DictationControllerHarness(text: "").dependencies)
        #expect(rewrite.phase == .listening)
        try await eventually { rewrite.phase == .choosing }
        #expect(recorder.recipes.isEmpty)
        #expect(rewrite.notice == "Nothing was heard. Say how again, or choose a recipe.")
    }
}
