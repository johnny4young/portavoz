import SwiftUI

/// Consent for dictation statistics, separate from the history and off by default.
struct DictationStatsSettingsSection: View {
    @Environment(AppServices.self) private var services
    @State private var confirmingDelete = false

    private var model: DictationStatsModel { services.dictationStats }

    // Modifiers on a Form section reach every row, so each row carries its own.
    var body: some View {
        Section("Dictation statistics") {
            Toggle("Keep dictation statistics", isOn: Binding(
                get: { model.isEnabled },
                set: { value in Task { await model.update(isEnabled: value) } }))
                .accessibilityIdentifier("settings-dictation-stats")
            Text(L10n.text(Self.noteKey))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-dictation-stats-note")
            Button("Delete statistics", role: .destructive) { confirmingDelete = true }
                .accessibilityIdentifier("settings-dictation-stats-delete")
                .confirmationDialog(
                    "Delete your dictation statistics?", isPresented: $confirmingDelete, titleVisibility: .visible
                ) {
                    Button("Delete statistics", role: .destructive) { Task { await model.deleteAll() } }
                        .accessibilityIdentifier("settings-dictation-stats-delete-confirm")
                }
        }
    }

    private static let noteKey = "Counts dictations, words and speaking time per day and app, never what you said. "
        + "Kept for one year on this Mac, separate from the history."
}
