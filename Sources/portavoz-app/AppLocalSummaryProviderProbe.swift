import ApplicationKit
import Foundation
import IntelligenceKit

/// Platform probes stay outside application policy and SwiftUI. Injectable
/// observations exercise the actual profile construction without host services.
struct AppLocalSummaryProviderProbe: LocalSummaryProviderProbing {
    let appleOnDeviceAvailable: Bool
    let usesTemporaryStore: Bool
    let capacity: AppModelMemoryCapacity
    let freeDiskGB: @Sendable () -> Int
    let localOllama: @Sendable () async -> LocalOllamaAvailability

    init(
        appleOnDeviceAvailable: Bool,
        usesTemporaryStore: Bool,
        capacity: AppModelMemoryCapacity = .init(),
        freeDiskGB: @escaping @Sendable () -> Int = Self.probeFreeDiskGB,
        localOllama: @escaping @Sendable () async -> LocalOllamaAvailability = Self.probeOllama
    ) {
        self.appleOnDeviceAvailable = appleOnDeviceAvailable
        self.usesTemporaryStore = usesTemporaryStore
        self.capacity = capacity
        self.freeDiskGB = freeDiskGB
        self.localOllama = localOllama
    }

    func probeLocalSummaryProviders() async -> LocalSummaryProviderProfile {
        // Automation must not inherit the host's models, RAM or disk pressure.
        if usesTemporaryStore {
            return LocalSummaryProviderProfile(
                memoryGB: 16, freeDiskGB: 100,
                appleOnDeviceAvailable: appleOnDeviceAvailable, ollama: .unavailable)
        }
        return LocalSummaryProviderProfile(
            memoryGB: capacity.wholeGiB, freeDiskGB: freeDiskGB(),
            appleOnDeviceAvailable: appleOnDeviceAvailable, ollama: await localOllama())
    }

    private static func probeFreeDiskGB() -> Int {
        let free = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        return Int((free ?? 0) / 1_000_000_000)
    }

    private static func probeOllama() async -> LocalOllamaAvailability {
        guard await OllamaService.isRunning() else { return .unavailable }
        return .running(models: await OllamaService.models().map {
            LocalSummaryModel(name: $0.name, parameterSize: $0.parameterSize, bytes: $0.bytes)
        })
    }
}
