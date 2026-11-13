import SwiftUI

/// Settings › Your data, while a 1.x library still holds dictation rows.
struct LegacyDictationDataSection: View {
    let model: LegacyDictationModel
    @State private var confirming = false

    var body: some View {
        if model.hasRows {
            Section("Dictation history") {
                Button("Delete dictation history and statistics", role: .destructive) { confirming = true }
                    .accessibilityIdentifier("settings-legacy-dictation-delete")
                if model.deleteFailed {
                    Text("Could not delete them. Try again.")
                        .font(.caption)
                        .accessibilityIdentifier("settings-legacy-dictation-delete-failed")
                }
            }
            .modifier(LegacyDictationDeleteConfirmation(
                isPresented: $confirming, model: model, identifier: "settings-legacy-dictation-delete-confirm"))
        }
    }
}

/// Shown once to a user who dictated in 1.x.
struct DictationMovedNoticeSheet: View {
    let model: LegacyDictationModel
    let dismiss: () -> Void
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dictation moved to Secreteo")
                .font(.title2.bold())
                .accessibilityIdentifier("dictation-moved-title")
            Text("Portavoz no longer dictates; global dictation is now its own app, Secreteo.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.hasRows {
                    Button("Delete dictation history and statistics", role: .destructive) { confirming = true }
                        .accessibilityIdentifier("dictation-moved-delete")
                }
                Spacer()
                Button("OK", action: dismiss)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("dictation-moved-dismiss")
            }
        }
        .padding(24)
        .frame(width: 460)
        .modifier(LegacyDictationDeleteConfirmation(
            isPresented: $confirming, model: model, identifier: "dictation-moved-delete-confirm"))
    }
}

private struct LegacyDictationDeleteConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let model: LegacyDictationModel
    let identifier: String

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete dictation history and statistics?", isPresented: $isPresented, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteAll() }
            }
            .accessibilityIdentifier(identifier)
        } message: {
            Text("This can't be undone.")
        }
    }
}
