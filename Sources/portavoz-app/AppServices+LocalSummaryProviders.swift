import ApplicationKit
import Foundation
import IntelligenceKit

extension AppServices {
    /// Presentation requests one application-owned discovery result; concrete
    /// Foundation Models, Ollama, process, and filesystem probes stay here.
    func discoverLocalSummaryProviders() async -> LocalSummaryProviderDiscovery {
        await DiscoverLocalSummaryProviders(probe: localSummaryProviderProbe()).execute(())
    }

    /// Clean-install configuration runs after recovery and durable worker
    /// resume. Existing user selection always wins.
    func configureInitialSummaryProviderIfNeeded() async {
        _ = await ConfigureInitialSummaryProvider(
            probe: localSummaryProviderProbe(),
            selections: AppSummaryProviderSelectionStore()
        ).execute(())
    }

    /// Provider guidance and the memory profile read one RAM observation.
    func localSummaryProviderProbe() -> AppLocalSummaryProviderProbe {
        AppLocalSummaryProviderProbe(
            appleOnDeviceAvailable: foundationModelsCapability.isAvailable,
            usesTemporaryStore: ProcessInfo.processInfo.arguments.contains("-use-temp-store"),
            capacity: modelMemoryPreferences.capacity)
    }
}

/// UserDefaults and SwiftUI's `@AppStorage` share the main-actor serialization
/// point, so the guarded clean-install write cannot race an explicit Settings
/// choice between its final check and persistence.
@MainActor
private struct AppSummaryProviderSelectionStore: SummaryProviderSelectionStoring {
    func summaryProviderSelection() async -> LocalSummaryProviderSelection? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "summaryEngine") != nil,
              let raw = defaults.string(forKey: "summaryEngine"),
              let engine = SummaryEngine(rawValue: raw)
        else { return nil }
        let model = defaults.string(forKey: "ollamaModel")
            .flatMap { $0.isEmpty ? nil : $0 }
        return LocalSummaryProviderSelection(engine: engine, ollamaModel: model)
    }

    func saveInitialSummaryProviderSelection(
        _ selection: LocalSummaryProviderSelection
    ) async -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "summaryEngine") == nil else { return false }
        if let model = selection.ollamaModel {
            defaults.set(model, forKey: "ollamaModel")
        }
        defaults.set(selection.engine.rawValue, forKey: "summaryEngine")
        return true
    }
}
