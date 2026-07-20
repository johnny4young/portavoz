import Foundation

/// A concrete local model reported by a provider adapter. Provider-specific
/// transport and DTOs never cross into presentation.
public struct LocalSummaryModel: Identifiable, Equatable, Sendable {
    public let name: String
    public let parameterSize: String
    public let bytes: Int64

    public var id: String { name }

    public init(name: String, parameterSize: String, bytes: Int64) {
        self.name = name
        self.parameterSize = parameterSize
        self.bytes = bytes
    }
}

public enum LocalOllamaAvailability: Equatable, Sendable {
    case unavailable
    case running(models: [LocalSummaryModel])

    public var models: [LocalSummaryModel] {
        switch self {
        case .unavailable:
            []
        case .running(let models):
            models
        }
    }
}

/// Machine and provider facts gathered by the concrete macOS adapter.
/// Unknown disk capacity remains zero, matching Foundation's API contract.
public struct LocalSummaryProviderProfile: Equatable, Sendable {
    public let memoryGB: Int
    public let freeDiskGB: Int
    public let appleOnDeviceAvailable: Bool
    public let ollama: LocalOllamaAvailability

    public init(
        memoryGB: Int,
        freeDiskGB: Int,
        appleOnDeviceAvailable: Bool,
        ollama: LocalOllamaAvailability
    ) {
        self.memoryGB = memoryGB
        self.freeDiskGB = freeDiskGB
        self.appleOnDeviceAvailable = appleOnDeviceAvailable
        self.ollama = ollama
    }
}

public protocol LocalSummaryProviderProbing: Sendable {
    func probeLocalSummaryProviders() async -> LocalSummaryProviderProfile
}

public struct LocalSummaryProviderSelection: Equatable, Sendable {
    public let engine: SummaryEngine
    public let ollamaModel: String?

    public init(engine: SummaryEngine, ollamaModel: String? = nil) {
        self.engine = engine
        let normalizedModel = ollamaModel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.ollamaModel = engine == .ollama && normalizedModel?.isEmpty == false
            ? normalizedModel
            : nil
    }
}

public enum LocalSummaryRecommendationHeadline: Equatable, Sendable {
    case appleOnDevice
    case ollama
    case builtIn
    case unavailable
}

/// Typed reasons keep product policy in ApplicationKit while localization
/// remains a presentation responsibility.
public enum LocalSummaryRecommendationReason: Equatable, Sendable {
    case appleOnDeviceAvailable
    case ollamaAvailable
    case ollamaHasNoEligibleModel
    case builtInEligible
    case noCompatibleLocalProvider
    case lowMemoryForOllama(memoryGB: Int)
    case lowDisk(freeDiskGB: Int)
}

public struct LocalSummaryProviderRecommendation: Equatable, Sendable {
    public let selection: LocalSummaryProviderSelection?
    public let headline: LocalSummaryRecommendationHeadline
    public let reasons: [LocalSummaryRecommendationReason]
    public let preferCompactWhisper: Bool

    public init(
        selection: LocalSummaryProviderSelection?,
        headline: LocalSummaryRecommendationHeadline,
        reasons: [LocalSummaryRecommendationReason],
        preferCompactWhisper: Bool
    ) {
        self.selection = selection
        self.headline = headline
        self.reasons = reasons
        self.preferCompactWhisper = preferCompactWhisper
    }
}

public struct LocalSummaryProviderDiscovery: Equatable, Sendable {
    public let profile: LocalSummaryProviderProfile
    public let recommendation: LocalSummaryProviderRecommendation

    public init(
        profile: LocalSummaryProviderProfile,
        recommendation: LocalSummaryProviderRecommendation
    ) {
        self.profile = profile
        self.recommendation = recommendation
    }
}

/// Deterministic local-provider policy. A running Ollama process is not enough:
/// it must expose a nonempty model not screened as a non-summary workload.
public enum LocalSummaryProviderPolicy {
    public static func recommendation(
        for profile: LocalSummaryProviderProfile
    ) -> LocalSummaryProviderRecommendation {
        var reasons: [LocalSummaryRecommendationReason] = []
        let selection: LocalSummaryProviderSelection?
        let headline: LocalSummaryRecommendationHeadline

        if profile.appleOnDeviceAvailable {
            selection = LocalSummaryProviderSelection(engine: .appleOnDevice)
            headline = .appleOnDevice
            reasons.append(.appleOnDeviceAvailable)
        } else if let model = profile.ollama.models.first(where: {
            isEligibleOllamaSummaryModel($0.name)
        }) {
            selection = LocalSummaryProviderSelection(engine: .ollama, ollamaModel: model.name)
            headline = .ollama
            reasons.append(.ollamaAvailable)
            if profile.memoryGB > 0 && profile.memoryGB < 16 {
                reasons.append(.lowMemoryForOllama(memoryGB: profile.memoryGB))
            }
        } else if canRunBuiltInModel(profile) {
            selection = LocalSummaryProviderSelection(engine: .mlx)
            headline = .builtIn
            if case .running = profile.ollama {
                reasons.append(.ollamaHasNoEligibleModel)
            }
            reasons.append(.builtInEligible)
        } else {
            selection = nil
            headline = .unavailable
            if case .running = profile.ollama {
                reasons.append(.ollamaHasNoEligibleModel)
            }
            reasons.append(.noCompatibleLocalProvider)
        }

        let lowDisk = profile.freeDiskGB > 0 && profile.freeDiskGB < 8
        if lowDisk {
            reasons.append(.lowDisk(freeDiskGB: profile.freeDiskGB))
        }
        return LocalSummaryProviderRecommendation(
            selection: selection,
            headline: headline,
            reasons: reasons,
            preferCompactWhisper: lowDisk)
    }

    /// Deny-list by name marker instead of asking Ollama per model: discovery
    /// runs on every Settings visit and `/api/show` would cost one round-trip
    /// per installed model, while `/api/tags` carries no capability field.
    /// Unknown names stay eligible on purpose — a future chat model works
    /// without a code change, and a miscategorized pick fails visibly at
    /// generation instead of being silently hidden here.
    public static func isEligibleOllamaSummaryModel(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        let nonChatMarkers = ["ocr", "embed", "embedding", "rerank", "whisper"]
        return !nonChatMarkers.contains { normalized.contains($0) }
    }

    private static func canRunBuiltInModel(_ profile: LocalSummaryProviderProfile) -> Bool {
        profile.memoryGB >= 8 && (profile.freeDiskGB >= 4 || profile.freeDiskGB == 0)
    }
}

public struct DiscoverLocalSummaryProviders: ApplicationUseCase {
    private let probe: any LocalSummaryProviderProbing

    public init(probe: any LocalSummaryProviderProbing) {
        self.probe = probe
    }

    public func execute(_ request: Void) async -> LocalSummaryProviderDiscovery {
        let profile = await probe.probeLocalSummaryProviders()
        return LocalSummaryProviderDiscovery(
            profile: profile,
            recommendation: LocalSummaryProviderPolicy.recommendation(for: profile))
    }
}

public protocol SummaryProviderSelectionStoring: Sendable {
    func summaryProviderSelection() async -> LocalSummaryProviderSelection?
    func saveInitialSummaryProviderSelection(
        _ selection: LocalSummaryProviderSelection
    ) async -> Bool
}

public enum InitialSummaryProviderConfiguration: Equatable, Sendable {
    case alreadyConfigured
    case configured(LocalSummaryProviderSelection)
    case unavailable
}

/// Chooses a clean-install provider exactly once. Existing user preferences
/// are authoritative and are never migrated or silently replaced.
public struct ConfigureInitialSummaryProvider: ApplicationUseCase {
    private let discovery: DiscoverLocalSummaryProviders
    private let selections: any SummaryProviderSelectionStoring

    public init(
        probe: any LocalSummaryProviderProbing,
        selections: any SummaryProviderSelectionStoring
    ) {
        discovery = DiscoverLocalSummaryProviders(probe: probe)
        self.selections = selections
    }

    public func execute(_ request: Void) async -> InitialSummaryProviderConfiguration {
        guard await selections.summaryProviderSelection() == nil else {
            return .alreadyConfigured
        }
        let result = await discovery.execute(())
        guard let selection = result.recommendation.selection else {
            return .unavailable
        }
        guard await selections.summaryProviderSelection() == nil else {
            return .alreadyConfigured
        }
        guard await selections.saveInitialSummaryProviderSelection(selection) else {
            return .alreadyConfigured
        }
        return .configured(selection)
    }
}
