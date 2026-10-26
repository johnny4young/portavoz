import PortavozCore
import SwiftUI

/// Original or translated reading, plus the request, progress and failure of a translation.
struct MeetingTranscriptTranslationControls: View {
    let state: MeetingTranscriptTranslationState
    @Binding var language: String?
    let translate: @MainActor (String) -> Void
    let cancel: @MainActor () -> Void
    let openSettings: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if !state.languages.isEmpty {
                Picker("Transcript language", selection: $language) {
                    Text("Original").tag(String?.none)
                    ForEach(state.languages, id: \.self) { code in
                        Text(Self.name(code)).tag(String?.some(code))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("detail-transcript-language")
            }
            if let language, !state.isCurrent(language) {
                Image(systemName: PVSymbol.warning)
                    .foregroundStyle(.orange)
                    .help("The transcript changed after this translation. Translate again to update it.")
                    .accessibilityLabel("Translation out of date")
                    .accessibilityIdentifier("detail-transcript-translation-stale")
            }
            activity
        }
    }

    @ViewBuilder
    private var activity: some View {
        switch state.activity {
        case .translating:
            ProgressView().controlSize(.small)
            Button("Cancel") { cancel() }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("detail-transcript-translation-cancel")
        case .failed(missingLanguages: true):
            Button("Download languages") { openSettings() }
                .buttonStyle(.borderless)
                .help("Translation needs Apple's English and Spanish languages on this Mac.")
                .accessibilityIdentifier("detail-transcript-translation-settings")
            menu
        case .failed(missingLanguages: false):
            Image(systemName: PVSymbol.error)
                .foregroundStyle(.red)
                .help("The last translation failed. Try again.")
                .accessibilityLabel("Translation failed")
                .accessibilityIdentifier("detail-transcript-translation-failure")
            menu
        case .idle:
            menu
        }
    }

    private var menu: some View {
        Menu {
            ForEach(TranscriptTranslation.languages.sorted(), id: \.self) { code in
                Button(Self.name(code)) { translate(code) }
                    .accessibilityIdentifier("detail-transcript-translate-\(code)")
            }
        } label: {
            Label("Translate", systemImage: PVSymbol.translate)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("detail-transcript-translate")
    }

    static func name(_ code: String) -> String {
        code == "es" ? L10n.text("Spanish") : L10n.text("English")
    }
}
