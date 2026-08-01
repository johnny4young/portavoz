import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore

/// Process-owned semantic embedding adapter shared by Ask and Library.
///
/// The actor coalesces Apple's contextual-model preparation and serializes the
/// model's mutable API. Every caller receives an exact residency use lease for
/// its complete indexing-and-query operation.
actor AppSemanticEmbeddingRuntime: SemanticEmbeddingRuntimeClient {
    struct Load {
        let generation: UUID
        let ticket: ResourceModelLoadTicket
        let task: Task<any SemanticEmbeddingModel, Error>
    }

    enum RuntimeError: Error {
        case inconsistentResidency
    }

    private let modelResidencyLedger: AppModelResidencyLedger
    private let telemetry: ResourceWorkloadTelemetry
    private let makeModel: @Sendable () throws -> any SemanticEmbeddingModel

    private var candidateModel: (any SemanticEmbeddingModel)?
    private var residentModel: (any SemanticEmbeddingModel)?
    private var runtimeLoad: Load?

    init(
        residency: AppModelResidencyLedger,
        telemetry: ResourceWorkloadTelemetry,
        makeModel: @escaping @Sendable () throws -> any SemanticEmbeddingModel = {
            try SentenceEmbedder()
        }
    ) {
        modelResidencyLedger = residency
        self.telemetry = telemetry
        self.makeModel = makeModel
    }

    var hasAvailableAssets: Bool {
        get async {
            do {
                let model = try availableModel()
                return await model.hasAvailableAssets
            } catch {
                return false
            }
        }
    }

    func semanticEmbeddingProfile() async -> SemanticEmbeddingProfile? {
        do {
            let model = try availableModel()
            return await model.semanticEmbeddingProfile()
        } catch {
            return nil
        }
    }

    func prepare(allowAssetDownload: Bool) async throws {
        _ = try await preparedModel(
            allowAssetDownload: allowAssetDownload)
    }

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload: Bool,
        operation: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        let acquired = try await acquire(
            allowAssetDownload: allowAssetDownload)
        do {
            try Task.checkCancellation()
            let result = try await operation(acquired.model)
            _ = modelResidencyLedger.finishUse(acquired.lease)
            return result
        } catch {
            _ = modelResidencyLedger.finishUse(acquired.lease)
            throw error
        }
    }

    /// Drops only loaded OS-model state. Assets remain managed by macOS.
    /// GOV-2's later governor adapter will call this explicit fence; no
    /// evidence-free TTL is introduced here.
    @discardableResult
    func release() -> Bool {
        guard runtimeLoad == nil else { return false }
        guard let retained = residentModel else {
            return modelResidencyLedger.record(
                for: .semanticEmbedding
            ).status == .unloaded
        }
        guard let ticket = modelResidencyLedger.beginRelease(.semanticEmbedding) else {
            return false
        }
        let span = telemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: .maintenance,
            kind: .searchIndex,
            operation: .release))
        residentModel = nil
        telemetry.finish(span, outcome: .completed)
        guard modelResidencyLedger.finishRelease(ticket) else {
            residentModel = retained
            _ = modelResidencyLedger.cancelRelease(ticket)
            return false
        }
        return true
    }

    private func acquire(
        allowAssetDownload: Bool
    ) async throws -> (
        model: any SemanticEmbeddingModel,
        lease: ResourceModelUseLease
    ) {
        if let residentModel {
            guard let lease = modelResidencyLedger.beginUse(.semanticEmbedding) else {
                throw RuntimeError.inconsistentResidency
            }
            return (residentModel, lease)
        }
        let load = try startOrJoinLoad(
            allowAssetDownload: allowAssetDownload)
        let model: any SemanticEmbeddingModel
        do {
            model = try await load.task.value
        } catch {
            if runtimeLoad?.generation == load.generation {
                runtimeLoad = nil
                _ = modelResidencyLedger.failLoad(load.ticket)
            }
            throw error
        }
        guard runtimeLoad?.generation == load.generation else {
            guard let residentModel,
                  let lease = modelResidencyLedger.beginUse(.semanticEmbedding)
            else {
                throw RuntimeError.inconsistentResidency
            }
            return (residentModel, lease)
        }
        guard let lease = modelResidencyLedger.finishLoadAndBeginUse(
            load.ticket,
            measuredFootprintBytes: nil)
        else {
            runtimeLoad = nil
            _ = modelResidencyLedger.failLoad(load.ticket)
            throw RuntimeError.inconsistentResidency
        }
        runtimeLoad = nil
        residentModel = model
        return (model, lease)
    }

    private func preparedModel(
        allowAssetDownload: Bool
    ) async throws -> any SemanticEmbeddingModel {
        if let residentModel { return residentModel }
        let load = try startOrJoinLoad(
            allowAssetDownload: allowAssetDownload)
        do {
            let model = try await load.task.value
            guard runtimeLoad?.generation == load.generation else {
                guard let residentModel else {
                    throw RuntimeError.inconsistentResidency
                }
                return residentModel
            }
            guard modelResidencyLedger.finishLoad(
                load.ticket,
                measuredFootprintBytes: nil)
            else {
                runtimeLoad = nil
                _ = modelResidencyLedger.failLoad(load.ticket)
                throw RuntimeError.inconsistentResidency
            }
            runtimeLoad = nil
            residentModel = model
            return model
        } catch {
            if runtimeLoad?.generation == load.generation {
                runtimeLoad = nil
                _ = modelResidencyLedger.failLoad(load.ticket)
            }
            throw error
        }
    }

    private func startOrJoinLoad(
        allowAssetDownload: Bool
    ) throws -> Load {
        if let runtimeLoad { return runtimeLoad }
        guard let ticket = modelResidencyLedger.beginLoad(.semanticEmbedding) else {
            throw RuntimeError.inconsistentResidency
        }
        let model: any SemanticEmbeddingModel
        do {
            model = try availableModel()
        } catch {
            _ = modelResidencyLedger.failLoad(ticket)
            throw error
        }
        candidateModel = nil
        let telemetry = telemetry
        let task = Task {
            try await telemetry.measure(ResourceWorkloadDescriptor(
                workloadClass: .userInitiated,
                kind: .searchIndex,
                operation: .load)
            ) {
                try await model.prepare(
                    allowAssetDownload: allowAssetDownload)
                return model
            }
        }
        let load = Load(
            generation: UUID(),
            ticket: ticket,
            task: task)
        runtimeLoad = load
        return load
    }

    private func availableModel() throws -> any SemanticEmbeddingModel {
        if let residentModel { return residentModel }
        if let candidateModel { return candidateModel }
        let model = try makeModel()
        candidateModel = model
        return model
    }
}
