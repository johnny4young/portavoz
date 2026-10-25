import ApplicationKit
import Carbon.HIToolbox
import Foundation
import Observation
import PortavozCore

/// Rewrites the text selected in another app with Polish or a recipe. Nothing is
/// replaced without a preview and Return, and only while the same selection remains.
@MainActor
@Observable
final class SelectionRewriteController {
    enum Phase: Equatable {
        case idle
        case capturing
        case choosing
        /// The user is saying how to rewrite it, through an ordinary dictation session.
        case listening
        case rewriting
        case preview(String)
        case replacing
        case replaced
        case failed(String)
    }

    @MainActor
    struct Dependencies {
        var capture: () async -> Result<CapturedSelection, SelectionRewriteFailure>
        var polish: (_ text: String, _ protectedTerms: [String], _ recipe: String?) async -> DictationPolishOutcome
        var recipes: () -> [DictationRecipe]
        var protectedTerms: () -> [String]
        var copyText: (String) -> Bool
        /// Return and Escape while the panel is open; nil leaves them to the panel's buttons.
        var registerKey: (_ keyCode: UInt32, _ onPress: @escaping () -> Void) -> (any GlobalHotkeyRegistration)?
            = { _, _ in nil }
        var wait: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        /// "Say how": start and finish the dictation session that captures the instruction.
        var startDictation: () -> Void = {}
        var finishDictation: () -> Void = {}
        var isDictating: () -> Bool = { false }
    }

    /// A selection can be long and the user is waiting on a preview, so it gets more time than a dictation.
    static let timeout: Duration = .seconds(10)

    private(set) var phase: Phase = .idle
    private(set) var original = ""
    private(set) var applicationName: String?
    private(set) var recipes: [DictationRecipe] = []
    private(set) var chosenRecipeID: String?
    /// Why the last rewrite was not offered; the choices stay open.
    private(set) var notice: String?
    private(set) var result: String?
    private(set) var copied = false
    /// What the user said for this rewrite; it acts as a one-time recipe.
    private(set) var spokenInstruction: String?
    @ObservationIgnored private var selection: CapturedSelection?
    @ObservationIgnored private var dependencies: Dependencies?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var keys: [any GlobalHotkeyRegistration] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let panel: SelectionRewritePanelController?

    init(presentsPanel: Bool = true) {
        panel = presentsPanel ? SelectionRewritePanelController() : nil
    }

    var isActive: Bool { phase != .idle }

    func start(using dependencies: Dependencies) {
        cancel()
        self.dependencies = dependencies
        let id = generation
        phase = .capturing
        show()
        task = Task { [weak self] in
            let captured = await dependencies.capture()
            guard let self, self.generation == id else { return }
            switch captured {
            case .success(let selection):
                self.selection = selection
                self.original = selection.text
                self.applicationName = selection.applicationName
                self.recipes = dependencies.recipes()
                self.phase = .choosing
                self.armKeys(replaces: false)
                self.show()
            case .failure(let failure):
                self.fail(Self.message(for: failure), closingAfter: .seconds(4))
            }
        }
    }

    /// Nil is Polish's conservative copy edit.
    func choose(_ recipe: DictationRecipe?) {
        guard phase == .choosing else { return }
        spokenInstruction = nil
        rewrite(recipeID: recipe?.id, instruction: recipe?.instruction)
    }

    /// While choosing, any dictation trigger captures the instruction instead of pasting.
    var capturesInstruction: Bool { phase == .choosing || phase == .listening }

    func sayHow() {
        guard phase == .choosing else { return }
        dependencies?.startDictation()
    }

    func finishSayingHow() {
        guard phase == .listening else { return }
        dependencies?.finishDictation()
    }

    /// Redirects one dictation session to this rewrite: Clean mode, no history,
    /// statistics, Paste last or delivery notice, and the text becomes the recipe.
    func instructionDependencies(_ base: DictationSessionDependencies) -> DictationSessionDependencies {
        var result = base
        result.captureDestination = { [weak self] in
            CapturedDictationDestination(name: L10n.text("Rewrite instruction"), canRetry: false) { [weak self] text in
                self?.receiveInstruction(text)
                return .verified
            }
        }
        result.locatePanelAnchor = { nil }
        result.beginHistory = { nil }
        result.recordStats = { _ in }
        result.textModeOverride = .clean
        result.deliversInternally = true
        beginListening()
        return result
    }

    private func beginListening() {
        guard phase == .choosing, let dependencies else { return }
        // The dictation session claims Escape for itself while it listens.
        releaseKeys()
        notice = nil
        phase = .listening
        show()
        let id = generation
        Task { [weak self] in
            // The session may not have started yet; then wait for it to end.
            for _ in 0..<20 where !dependencies.isDictating() {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            while dependencies.isDictating() {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard let self, self.generation == id, self.phase == .listening else { return }
            self.phase = .choosing
            self.armKeys(replaces: false)
            self.show()
        }
    }

    private func receiveInstruction(_ text: String) {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .listening, !instruction.isEmpty else { return }
        spokenInstruction = instruction
        rewrite(recipeID: nil, instruction: String(instruction.prefix(DictationRecipe.maximumInstructionLength)))
    }

    private func rewrite(recipeID: String?, instruction: String?) {
        guard let dependencies else { return }
        chosenRecipeID = recipeID
        notice = nil
        phase = .rewriting
        armKeys(replaces: false)
        show()
        let id = generation
        let text = original
        task = Task { [weak self] in
            let outcome = await dependencies.polish(text, dependencies.protectedTerms(), instruction)
            guard let self, self.generation == id else { return }
            switch outcome {
            case .polished(let rewritten):
                self.result = rewritten
                self.phase = .preview(rewritten)
                self.armKeys(replaces: true)
            case .kept(let skip):
                self.notice = Self.message(for: skip)
                self.phase = .choosing
            }
            self.show()
        }
    }

    func chooseAgain() {
        guard case .preview = phase else { return }
        phase = .choosing
        armKeys(replaces: false)
        show()
    }

    /// Replaces only the exact selection the rewrite started from.
    func replace() {
        guard case .preview(let text) = phase, let selection else { return }
        if let failure = selection.revalidate() {
            fail(Self.message(for: failure))
            return
        }
        releaseKeys()
        phase = .replacing
        show()
        let id = generation
        task = Task { [weak self] in
            let outcome = await selection.destination.insert(text)
            guard let self, self.generation == id else { return }
            switch outcome {
            case .verified, .dispatched:
                self.phase = .replaced
                self.show()
                self.scheduleClose(after: .milliseconds(1600))
            case .refused:
                self.fail(L10n.text("Nothing was replaced. Copy the rewrite instead."))
            }
        }
    }

    func copyResult() {
        guard let result, let dependencies else { return }
        copied = dependencies.copyText(result)
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        releaseKeys()
        selection = nil
        dependencies = nil
        original = ""
        applicationName = nil
        recipes = []
        chosenRecipeID = nil
        notice = nil
        result = nil
        copied = false
        spokenInstruction = nil
        phase = .idle
        panel?.close()
    }

    private func fail(_ message: String, closingAfter delay: Duration? = nil) {
        phase = .failed(message)
        armKeys(replaces: false)
        show()
        if let delay { scheduleClose(after: delay) }
    }

    private func scheduleClose(after delay: Duration) {
        guard let wait = dependencies?.wait else { return }
        let id = generation
        Task { [weak self] in
            do { try await wait(delay) } catch { return }
            guard let self, self.generation == id else { return }
            self.cancel()
        }
    }

    private func show() {
        panel?.show(controller: self)
    }

    private func armKeys(replaces: Bool) {
        releaseKeys()
        guard let dependencies else { return }
        let id = generation
        let escape = dependencies.registerKey(UInt32(kVK_Escape)) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                self.cancel()
            }
        }
        keys = [escape].compactMap { $0 }
        guard replaces, let enter = dependencies.registerKey(UInt32(kVK_Return), { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                self.replace()
            }
        }) else { return }
        keys.append(enter)
    }

    private func releaseKeys() {
        keys.forEach { $0.unregister() }
        keys = []
    }

    static func message(for failure: SelectionRewriteFailure) -> String {
        switch failure {
        case .accessibilityRequired:
            L10n.text("Rewriting needs the Accessibility permission. Grant it in System Settings and try again.")
        case .secureField:
            L10n.text("Password fields cannot be rewritten.")
        case .nothingSelected:
            L10n.text("Select some text first, then try again.")
        case .tooLong:
            L10n.text("Select at most 2,000 characters to rewrite.")
        case .unavailable:
            L10n.text("This app does not let Portavoz read its selection.")
        case .selectionChanged:
            L10n.text("The selection changed, so nothing was replaced. Copy the rewrite instead.")
        }
    }

    static func message(for skip: DictationPolishSkip) -> String {
        switch skip {
        case .tooShort:
            L10n.text("Select at least three words to rewrite.")
        case .tooLong:
            L10n.text("Select at most 2,000 characters to rewrite.")
        case .unavailable(let reason):
            reason
        case .timedOut:
            L10n.text("The summary engine took too long. Try again.")
        case .failed:
            L10n.text("The summary engine could not rewrite it. Try again.")
        case .changedMeaning:
            L10n.text("The rewrite changed a fact, name or number, so it is not offered. Try another recipe.")
        }
    }
}
