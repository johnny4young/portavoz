import Foundation

/// Read-only capability state for Apple's OS-managed semantic-search assets.
///
/// This is deliberately separate from `SemanticCorpusReadiness`: preparing the
/// model makes query vectors possible, while durable background maintenance may
/// still need time to publish vectors for the whole library.
public enum SemanticSearchAssetReadiness: Equatable, Sendable {
    case ready
    case needsPreparation
    case unsupported
}

/// Inspects semantic asset readiness without loading a model, downloading an
/// asset, or writing the semantic corpus.
public struct InspectSemanticSearchAssets: Sendable {
    private let runtime: any SemanticEmbeddingRuntimeClient

    public init(runtime: any SemanticEmbeddingRuntimeClient) {
        self.runtime = runtime
    }

    public func current() async -> SemanticSearchAssetReadiness {
        guard let profile = await runtime.semanticEmbeddingProfile(),
              profile.isValid
        else { return .unsupported }
        return await runtime.hasAvailableAssets ? .ready : .needsPreparation
    }
}

/// The only product workflow allowed to request Apple's semantic assets.
/// Search fields and automatic corpus maintenance keep passing
/// `allowAssetDownload: false` through their existing read-only paths.
public struct PrepareSemanticSearchAssets: Sendable {
    private let runtime: any SemanticEmbeddingRuntimeClient
    private let inspection: InspectSemanticSearchAssets

    public init(runtime: any SemanticEmbeddingRuntimeClient) {
        self.runtime = runtime
        inspection = InspectSemanticSearchAssets(runtime: runtime)
    }

    public func execute() async throws -> SemanticSearchAssetReadiness {
        try Task.checkCancellation()
        switch await inspection.current() {
        case .unsupported:
            return .unsupported
        case .ready:
            try await runtime.prepare(allowAssetDownload: false)
        case .needsPreparation:
            try await runtime.prepare(allowAssetDownload: true)
        }
        try Task.checkCancellation()
        return await inspection.current()
    }
}
