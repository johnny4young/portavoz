import PortavozCore
import SwiftUI
import Translation

/// The default translation target and Apple's English and Spanish language packs. Dictation
/// never downloads them; this is the one deliberate place that does.
struct DictationTranslationSettings: View {
    let model: DictationTextSettingsModel
    @State private var installed: Bool?
    @State private var download: TranslationSession.Configuration?
    @State private var downloadFailed = false

    var body: some View {
        DictationTranslationPicker(
            identifier: "settings-dictation-translate", label: Text("Translate dictation into"),
            selection: Binding(get: { model.globalTranslationTarget }, set: { model.setGlobalTranslationTarget($0) }))
        Text(status)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings-dictation-translate-status")
            .task { await refresh() }
        if installed == false {
            Button("Download English and Spanish") {
                downloadFailed = false
                download = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "es"), target: Locale.Language(identifier: "en"))
            }
            .accessibilityIdentifier("settings-dictation-translate-download")
            .translationTask(download, action: Self.prepare { prepared in
                downloadFailed = !prepared
                await refresh()
                download = nil
            })
        }
    }

    private var status: String {
        if downloadFailed { return L10n.text("The languages were not downloaded. Try again when you are online.") }
        switch installed {
        case true?:
            return L10n.text(
                "Translation runs on this Mac with Apple's English and Spanish languages.")
        case false?:
            return L10n.text("English and Spanish are not downloaded yet, so dictation is pasted untranslated.")
        case nil:
            return L10n.text("Checking Apple's translation languages…")
        }
    }

    /// Built outside the main actor so the session never crosses isolation.
    nonisolated private static func prepare(
        then finish: @escaping @MainActor @Sendable (Bool) async -> Void
    ) -> (TranslationSession) async -> Void {
        { session in
            let prepared = (try? await session.prepareTranslation()) != nil
            await finish(prepared)
        }
    }

    private func refresh() async {
        let availability = LanguageAvailability()
        let english = Locale.Language(identifier: "en")
        let spanish = Locale.Language(identifier: "es")
        let forward = await availability.status(from: spanish, to: english)
        let backward = await availability.status(from: english, to: spanish)
        let ready = forward == .installed && backward == .installed
        await MainActor.run { installed = ready }
    }
}
