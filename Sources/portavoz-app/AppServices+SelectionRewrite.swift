import AppKit
import ApplicationKit
import Carbon.HIToolbox
import Foundation
import PortavozCore
import TranscriptionKit

/// Optional fixed shortcut for rewriting the selection; off by default.
enum RewriteSelectionShortcut {
    static let defaultsKey = "dictationRewriteSelectionHotkey"
    static let keyCode = UInt32(kVK_ANSI_R)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
}

extension AppServices {
    func rewriteSelection() {
        selectionRewrite.start(using: makeSelectionRewriteDependencies())
    }

    func syncRewriteSelectionShortcut() {
        rewriteSelectionHotkey?.unregister()
        rewriteSelectionHotkey = nil
        let wanted = defaults.bool(forKey: DictationController.defaultsKey)
            && defaults.bool(forKey: RewriteSelectionShortcut.defaultsKey)
        // Disposable launches never register Carbon hotkeys.
        guard wanted, !usesTemporaryMeetingStore else {
            rewriteSelectionShortcutUnavailable = false
            return
        }
        rewriteSelectionHotkey = GlobalHotkey(
            keyCode: RewriteSelectionShortcut.keyCode, modifiers: RewriteSelectionShortcut.modifiers
        ) { [weak self] in self?.rewriteSelection() }
        rewriteSelectionShortcutUnavailable = rewriteSelectionHotkey == nil
    }

    func makeSelectionRewriteDependencies() -> SelectionRewriteController.Dependencies {
        let defaults = defaults
        let recipes = { DictationTextPreferences.recipes(in: defaults) }
        let terms = {
            DictationTextRules.decode(
                replacements: defaults.string(forKey: DictationController.replacementsKey) ?? ""
            ).map(\.replacement)
        }
        if usesTemporaryMeetingStore {
            return SelectionRewriteUITestFixture(arguments: ProcessInfo.processInfo.arguments)
                .dependencies(recipes: recipes)
        }
        return SelectionRewriteController.Dependencies(
            capture: { await TextInserter.captureSelection() },
            polish: { [polisher = dictationPolisher] text, protectedTerms, recipe in
                await PolishDictation(polisher: polisher, timeout: SelectionRewriteController.timeout)(
                    text, protectedTerms: protectedTerms, recipe: recipe)
            },
            recipes: recipes,
            protectedTerms: terms,
            copyText: { TextInserter.copy($0) },
            registerKey: { keyCode, onPress in GlobalHotkey(keyCode: keyCode, modifiers: 0, onPress: onPress) })
    }
}

/// Disposable launches rewrite a fixed selection with no Accessibility, clipboard or engine.
@MainActor
struct SelectionRewriteUITestFixture {
    static let text = "Don't delete these notes."
    let selectsNothing: Bool
    let selectionChanges: Bool

    init(arguments: [String]) {
        selectsNothing = arguments.contains("-seed-rewrite-nothing-selected")
        selectionChanges = arguments.contains("-seed-rewrite-selection-changes")
    }

    func dependencies(recipes: @escaping () -> [DictationRecipe]) -> SelectionRewriteController.Dependencies {
        let selectsNothing = selectsNothing
        let selectionChanges = selectionChanges
        return SelectionRewriteController.Dependencies(
            capture: {
                guard !selectsNothing else { return .failure(.nothingSelected) }
                return .success(CapturedSelection(
                    text: Self.text, source: .accessibility, applicationName: "Rewrite test receiver",
                    revalidate: { selectionChanges ? .selectionChanged : nil },
                    destination: CapturedDictationDestination(
                        name: "Rewrite test receiver", canRetry: false) { _ in .verified }))
            },
            polish: DictationUITestFixture.polishing(nil),
            recipes: recipes,
            protectedTerms: { [] },
            copyText: { _ in true },
            wait: DictationUITestFixture.waitHoldingUnverifiedNotices)
    }
}
