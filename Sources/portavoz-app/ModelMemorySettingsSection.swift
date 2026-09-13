import SwiftUI

struct ModelMemorySettingsSection: View {
    let services: AppServices
    @AppStorage(AppModelMemoryPreferences.key) private var profileRaw =
        AppModelMemoryPreferences.Profile.balanced.rawValue

    var body: some View {
        Section("Model memory") {
            Toggle("Lightweight model memory", isOn: Binding(
                get: { profileRaw == AppModelMemoryPreferences.Profile.lightweight.rawValue },
                set: { services.setModelMemoryProfile($0 ? .lightweight : .balanced) }))
                .accessibilityIdentifier("settings-model-memory-lightweight")
            Text("Release idle models sooner. Models in use stay available; the next start may be slower.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-model-memory-help")
            Text("Model choices and downloaded files are unchanged. This is not a RAM usage limit.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L10n.text(services.modelMemoryPreferences.recommendedProfile == .lightweight
                ? "Suggested for this Mac: lightweight memory."
                : "Balanced memory keeps models ready for back-to-back work."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-model-memory-recommendation")
        }
    }
}
