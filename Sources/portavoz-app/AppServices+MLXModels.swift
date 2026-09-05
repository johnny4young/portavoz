import Foundation
import IntelligenceKit
import PortavozCore

@MainActor
extension AppServices {
    struct MLXRuntimeLoad {
        let generation: UUID
        let directoryKey: String
        let ticket: ResourceModelLoadTicket
        let task: Task<Void, Error>
    }

    struct MLXRuntimeLease {
        let directoryKey: String
        fileprivate let residency: ResourceModelUseLease
    }

    enum MLXRuntimeError: Error {
        case inconsistentResidency
        case modelInUse
        case servicesUnavailable
    }

    /// Creates a cheap provider over the single process-owned MLX runtime.
    /// The client crosses back through this composition root for every
    /// generation, so ad hoc provider structs cannot create hidden caches.
    func makeMLXSummaryProvider(
        modelDirectory: URL,
        priority: IntelligenceScheduler.Priority = .interactive,
        workloadClass: ResourceWorkloadClass = .userInitiated
    ) -> MLXSummaryProvider {
        let client = AppMLXSummaryRuntimeClient { [weak self] system, user, directory in
            guard let self else { throw MLXRuntimeError.servicesUnavailable }
            return try await self.respondWithMLXRuntime(
                system: system,
                user: user,
                directory: directory,
                workloadClass: workloadClass)
        }
        return MLXSummaryProvider(
            modelDirectory: modelDirectory,
            priority: priority,
            runtime: client)
    }

    /// Reuses the exact process-owned MLX runtime and residency policy for
    /// grounded Ask. A second provider value is cheap; a second runtime is
    /// deliberately impossible from application composition.
    func makeMLXRAGAnswerer(
        modelDirectory: URL,
        priority: IntelligenceScheduler.Priority = .interactive,
        workloadClass: ResourceWorkloadClass = .userInitiated
    ) -> MLXRAGAnswerer {
        let client = AppMLXSummaryRuntimeClient { [weak self] system, user, directory in
            guard let self else { throw MLXRuntimeError.servicesUnavailable }
            return try await self.respondWithMLXRuntime(
                system: system,
                user: user,
                directory: directory,
                workloadClass: workloadClass)
        }
        return MLXRAGAnswerer(
            modelDirectory: modelDirectory,
            priority: priority,
            runtime: client)
    }

    /// Acquires the exact runtime, generates while its active-use token is
    /// held, and arms the existing idle policy on every terminal outcome.
    private func respondWithMLXRuntime(
        system: String,
        user: String,
        directory: URL,
        workloadClass: ResourceWorkloadClass
    ) async throws -> String {
        let lease = try await acquireMLXRuntime(
            directory: directory,
            workloadClass: workloadClass)
        do {
            try Task.checkCancellation()
            let response = try await mlxSummaryRuntime.respondPrepared(
                system: system,
                user: user,
                directory: directory)
            finishMLXRuntime(lease)
            scheduleMLXRelease()
            return response
        } catch {
            finishMLXRuntime(lease)
            scheduleMLXRelease()
            throw error
        }
    }

    func acquireMLXRuntime(
        directory: URL,
        workloadClass: ResourceWorkloadClass
    ) async throws -> MLXRuntimeLease {
        mlxIdleGeneration += 1
        let directoryKey = Self.mlxDirectoryKey(directory)
        if let runtime = try residentMLXRuntime(directoryKey: directoryKey) {
            return runtime
        }
        try await admitModelRuntimeLoad(.languageIntelligence)

        if let active = mlxRuntimeLoad {
            guard active.directoryKey == directoryKey else {
                throw MLXRuntimeError.modelInUse
            }
            return try await finishMLXRuntimeLoad(active)
        }
        if mlxRuntimeDirectoryKey != nil,
           !(await releaseMLXRuntime()) {
            throw MLXRuntimeError.modelInUse
        }

        guard let ticket = try await beginAdmittedModelRuntimeLoad(
            .languageIntelligence
        ) else {
            throw MLXRuntimeError.inconsistentResidency
        }
        let telemetry = workloadTelemetry
        let runtime = mlxSummaryRuntime
        let task = Task {
            try await telemetry.measure(ResourceWorkloadDescriptor(
                workloadClass: workloadClass,
                kind: .languageInference,
                operation: .load)
            ) {
                try await runtime.prepare(directory)
            }
        }
        let load = MLXRuntimeLoad(
            generation: UUID(),
            directoryKey: directoryKey,
            ticket: ticket,
            task: task)
        mlxRuntimeLoad = load
        return try await finishMLXRuntimeLoad(load)
    }

    @discardableResult
    func finishMLXRuntime(_ runtime: MLXRuntimeLease) -> Bool {
        modelResidencyLedger.finishUse(runtime.residency)
    }

    /// Drops resident weights only after the ledger proves there is no active
    /// summary. The runtime owns the concrete container; AppServices owns the
    /// accepted lifecycle transition.
    @discardableResult
    func releaseMLXRuntime() async -> Bool {
        guard mlxRuntimeLoad == nil else { return false }
        guard mlxRuntimeDirectoryKey != nil else {
            return modelResidencyLedger.record(
                for: .languageIntelligence).status == .unloaded
        }
        guard let ticket = modelResidencyLedger.beginRelease(
            .languageIntelligence)
        else { return false }

        let span = workloadTelemetry.begin(ResourceWorkloadDescriptor(
            workloadClass: .maintenance,
            kind: .languageInference,
            operation: .release))
        await mlxSummaryRuntime.release()
        mlxRuntimeDirectoryKey = nil
        workloadTelemetry.finish(span, outcome: .completed)

        let finished = modelResidencyLedger.finishRelease(ticket)
        assert(finished, "accepted MLX release ticket must remain current")
        return finished
    }

    func scheduleMLXRelease() {
        mlxIdleGeneration += 1
        let generation = mlxIdleGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard let self, generation == self.mlxIdleGeneration else { return }
            await self.releaseMLXRuntime()
        }
    }

    private func finishMLXRuntimeLoad(
        _ load: MLXRuntimeLoad
    ) async throws -> MLXRuntimeLease {
        do {
            try await load.task.value
            guard mlxRuntimeLoad?.generation == load.generation else {
                guard let runtime = try residentMLXRuntime(
                    directoryKey: load.directoryKey)
                else { throw CancellationError() }
                return runtime
            }
            try await admitModelRuntimeLoad(.languageIntelligence)
            guard mlxRuntimeLoad?.generation == load.generation else {
                guard let runtime = try residentMLXRuntime(
                    directoryKey: load.directoryKey)
                else { throw CancellationError() }
                return runtime
            }
            guard modelResidencyLedger.finishLoad(
                load.ticket,
                measuredFootprintBytes: nil)
            else {
                mlxRuntimeLoad = nil
                _ = modelResidencyLedger.failLoad(load.ticket)
                await mlxSummaryRuntime.release()
                throw MLXRuntimeError.inconsistentResidency
            }
            mlxRuntimeLoad = nil
            mlxRuntimeDirectoryKey = load.directoryKey
            guard let runtime = try residentMLXRuntime(
                directoryKey: load.directoryKey)
            else {
                _ = await releaseMLXRuntime()
                throw MLXRuntimeError.inconsistentResidency
            }
            return runtime
        } catch {
            if mlxRuntimeLoad?.generation == load.generation {
                mlxRuntimeLoad = nil
                _ = modelResidencyLedger.failLoad(load.ticket)
                await mlxSummaryRuntime.release()
            }
            throw error
        }
    }

    private func residentMLXRuntime(
        directoryKey: String
    ) throws -> MLXRuntimeLease? {
        guard mlxRuntimeDirectoryKey == directoryKey else { return nil }
        guard let residency = modelResidencyLedger.beginUse(
            .languageIntelligence)
        else { throw MLXRuntimeError.inconsistentResidency }
        return MLXRuntimeLease(
            directoryKey: directoryKey,
            residency: residency)
    }

    private static func mlxDirectoryKey(_ directory: URL) -> String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private struct AppMLXSummaryRuntimeClient: MLXSummaryRuntimeClient {
    let operation: @Sendable (
        _ system: String,
        _ user: String,
        _ directory: URL
    ) async throws -> String

    init(
        operation: @escaping @Sendable (
            _ system: String,
            _ user: String,
            _ directory: URL
        ) async throws -> String
    ) {
        self.operation = operation
    }

    func respond(
        system: String,
        user: String,
        directory: URL
    ) async throws -> String {
        try await operation(system, user, directory)
    }
}
