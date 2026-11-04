import ModelStoreKit
import SwiftUI

/// What the shared store holds, and which other apps keep each model on disk.
struct ModelsOnThisMacSection: View {
    let services: AppServices
    @State private var models: [ModelStore.InstalledModel] = []

    var body: some View {
        Section("Models on this Mac") {
            if models.isEmpty {
                Text("No models on this Mac yet")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-installed-models-empty")
            }
            ForEach(models) { model in
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                    Text(Self.detail(of: model))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-installed-model-\(model.id)-detail")
                }
            }
        }
        .task {
            models = await services.installedModels()
            for await _ in services.sharedModelChanges() {
                models = await services.installedModels()
            }
        }
    }

    static func detail(
        of model: ModelStore.InstalledModel, locale: Locale = AppLanguage.current.locale
    ) -> String {
        let size = model.bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let apps = model.otherApps.formatted(.list(type: .and).locale(locale))
        let users: String? = model.otherApps.isEmpty ? nil
            : L10n.format(model.isUsedHere ? "Also used by %@" : "Used by %@", apps)
        return [size, users].compactMap { $0 }.joined(separator: " · ")
    }
}
