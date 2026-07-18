import ApplicationKit
import Foundation
import IntelligenceKit

extension AppServices {
    /// Presentation requests one application-owned discovery result; concrete
    /// Foundation Models, Ollama, process, and filesystem probes stay here.
    func discoverLocalSummaryProviders() async -> LocalSummaryProviderDiscovery {
        await DiscoverLocalSummaryProviders(
            probe: AppLocalSummaryProviderProbe(
                appleOnDeviceAvailable: foundationModelsCapability.isAvailable,
                usesTemporaryStore: ProcessInfo.processInfo.arguments
                    .contains("-use-temp-store"))
        ).execute(())
    }

    /// Clean-install configuration runs after recovery and durable worker
    /// resume. Existing user selection always wins.
    func configureInitialSummaryProviderIfNeeded() async {
        _ = await ConfigureInitialSummaryProvider(
            probe: AppLocalSummaryProviderProbe(
                appleOnDeviceAvailable: foundationModelsCapability.isAvailable,
                usesTemporaryStore: ProcessInfo.processInfo.arguments
                    .contains("-use-temp-store")),
            selections: AppSummaryProviderSelectionStore()
        ).execute(())
    }
}

private struct AppLocalSummaryProviderProbe: LocalSummaryProviderProbing {
    let appleOnDeviceAvailable: Bool
    let usesTemporaryStore: Bool

    func probeLocalSummaryProviders() async -> LocalSummaryProviderProfile {
        // Disposable automation must not inherit the host's Ollama models,
        // memory pressure, or disk state. The Apple capability may itself be
        // an explicit deterministic fixture such as Sequoia simulation.
        if usesTemporaryStore {
            return LocalSummaryProviderProfile(
                memoryGB: 16,
                freeDiskGB: 100,
                appleOnDeviceAvailable: appleOnDeviceAvailable,
                ollama: .unavailable)
        }
        let memoryGB = Int(
            (ProcessInfo.processInfo.physicalMemory + 500_000_000) / 1_000_000_000)
        let free = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        let ollama: LocalOllamaAvailability
        if await OllamaService.isRunning() {
            ollama = .running(models: await OllamaService.models().map {
                LocalSummaryModel(
                    name: $0.name,
                    parameterSize: $0.parameterSize,
                    bytes: $0.bytes)
            })
        } else {
            ollama = .unavailable
        }
        return LocalSummaryProviderProfile(
            memoryGB: memoryGB,
            freeDiskGB: Int((free ?? 0) / 1_000_000_000),
            appleOnDeviceAvailable: appleOnDeviceAvailable,
            ollama: ollama)
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
