import PortavozCore
import SwiftUI

/// Consent for the dictation history. Every switch here starts off.
struct DictationHistorySettingsSection: View {
    @Environment(AppServices.self) private var services

    private var model: DictationHistoryModel { services.dictationHistory }

    var body: some View {
        Section("Dictation history") {
            Toggle("Save dictation history", isOn: binding(\.isEnabled) { await model.update(isEnabled: $0) })
                .accessibilityIdentifier("settings-dictation-history")
            if model.policy.isEnabled {
                Picker("Keep dictations for", selection: retention) {
                    ForEach(DictationHistoryPolicy.retentionChoices, id: \.self) { days in
                        Text(L10n.format("%d days", days)).tag(days)
                    }
                }
                .accessibilityIdentifier("settings-dictation-history-retention")
                Toggle(
                    "Also keep the words before Clean mode",
                    isOn: binding(\.keepsOriginal) { await model.update(keepsOriginal: $0) })
                    .accessibilityIdentifier("settings-dictation-history-original")
            }
            Text("History stays on this Mac. Passwords, practice and silence are never saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings-dictation-history-note")
        }
        .task { if !model.isLoaded { await model.load() } }
    }

    private var retention: Binding<Int> {
        Binding(
            get: { model.policy.retentionDays },
            set: { days in Task { await model.update(retentionDays: days) } })
    }

    private func binding(
        _ keyPath: KeyPath<DictationHistoryPolicy, Bool>, update: @escaping (Bool) async -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { model.policy[keyPath: keyPath] },
            set: { value in Task { await update(value) } })
    }
}
