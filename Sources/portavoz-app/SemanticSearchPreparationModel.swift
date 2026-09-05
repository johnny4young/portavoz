import ApplicationKit
import Foundation
import IntelligenceKit
import Observation
import PortavozCore

@MainActor
protocol SemanticSearchPreparationModelClient: AnyObject {
    func current() async -> SemanticSearchAssetReadiness
    func prepare() async throws -> SemanticSearchAssetReadiness
}

/// Process-scoped presentation state for the explicit semantic asset action.
/// Closing Settings cannot start a competing download, and every Settings
/// window observes the same result.
@MainActor
@Observable
final class SemanticSearchPreparationModel {
    enum Phase: Equatable {
        case checking
        case needsPreparation
        case preparing
        case ready
        case unsupported
        case blockedByCapture
        case failed
    }

    private(set) var phase: Phase = .checking
    private let client: any SemanticSearchPreparationModelClient
    @ObservationIgnored private var inspectionGeneration: UInt64 = 0

    init(client: any SemanticSearchPreparationModelClient) {
        self.client = client
    }

    func refresh() async {
        guard phase != .preparing, !Task.isCancelled else { return }
        inspectionGeneration &+= 1
        let generation = inspectionGeneration
        let readiness = await client.current()
        guard !Task.isCancelled, generation == inspectionGeneration else { return }
        phase = Self.phase(for: readiness)
    }

    func prepare() async {
        guard phase != .preparing, phase != .ready, phase != .unsupported else {
            return
        }
        // A Settings inspection already in flight must not reopen the action
        // or replace its result after this explicit preparation starts.
        inspectionGeneration &+= 1
        phase = .preparing
        do {
            let readiness = try await client.prepare()
            switch readiness {
            case .ready:
                phase = .ready
            case .unsupported:
                phase = .unsupported
            case .needsPreparation:
                phase = .failed
            }
        } catch is CancellationError {
            phase = Self.phase(for: await client.current())
        } catch AppResourceGovernorAdmissionError.activeCaptureModelConflict {
            phase = .blockedByCapture
        } catch {
            phase = .failed
        }
    }

    private static func phase(
        for readiness: SemanticSearchAssetReadiness
    ) -> Phase {
        switch readiness {
        case .ready: .ready
        case .needsPreparation: .needsPreparation
        case .unsupported: .unsupported
        }
    }
}

@MainActor
final class AppSemanticSearchPreparationClient:
    SemanticSearchPreparationModelClient {
    private weak var services: AppServices?
    private let inspection: InspectSemanticSearchAssets
    private let preparation: PrepareSemanticSearchAssets

    init(services: AppServices) {
        self.services = services
        inspection = InspectSemanticSearchAssets(
            runtime: services.semanticEmbeddingRuntime)
        preparation = PrepareSemanticSearchAssets(
            runtime: services.semanticEmbeddingRuntime)
    }

    func current() async -> SemanticSearchAssetReadiness {
        await inspection.current()
    }

    func prepare() async throws -> SemanticSearchAssetReadiness {
        guard let services else { throw CancellationError() }
        try await services.admitModelRuntimeLoad(.semanticEmbedding)
        let result = try await preparation.execute()
        if result == .ready {
            services.semanticIndexingSupervisor.kick()
        }
        return result
    }
}
