import Foundation

/// Process-scoped lifecycle for model installations admitted by `ModelStore`.
///
/// Only successful full-descriptor SHA-256 verification is cached. Missing or
/// corrupt results are deliberately rechecked, and explicit install, removal,
/// or invalidation prevents an older in-flight check from restoring stale
/// evidence.
public actor VerifiedModelLifecycle {
    typealias VerificationOperation = @Sendable (
        ModelDescriptor
    ) async -> ModelStore.VerifiedInstallation?
    typealias InstallationOperation = @Sendable (
        ModelDescriptor,
        (@Sendable (ModelStore.DownloadProgress) -> Void)?
    ) async throws -> ModelStore.VerifiedInstallation
    typealias RemovalOperation = @Sendable (ModelDescriptor) async throws -> Void

    private struct Verification: Sendable {
        let generation: UUID
        let task: Task<ModelStore.VerifiedInstallation?, Never>
    }

    private struct Mutation: Sendable {
        let generation: UUID
        let completion: Task<Void, Never>
    }

    private let verifyInstallation: VerificationOperation
    private let installModel: InstallationOperation
    private let removeModel: RemovalOperation
    private var verified: [String: ModelStore.VerifiedInstallation] = [:]
    private var verifications: [String: Verification] = [:]
    private var mutations: [String: Mutation] = [:]

    public init(store: ModelStore) {
        verifyInstallation = { descriptor in
            await store.verifiedInstallation(descriptor)
        }
        installModel = { descriptor, progress in
            let directory = try await store.ensureAvailable(
                descriptor,
                progress: progress)
            return ModelStore.VerifiedInstallation(
                descriptorID: descriptor.id,
                descriptorRevision: descriptor.revision,
                directory: directory,
                artifactBytes: Int64(descriptor.totalSizeBytes))
        }
        removeModel = { descriptor in
            try await store.remove(descriptor)
        }
    }

    init(
        verifyInstallation: @escaping VerificationOperation,
        installModel: @escaping InstallationOperation,
        removeModel: @escaping RemovalOperation
    ) {
        self.verifyInstallation = verifyInstallation
        self.installModel = installModel
        self.removeModel = removeModel
    }

    public func installation(
        for descriptor: ModelDescriptor,
        forceVerification: Bool = false
    ) async -> ModelStore.VerifiedInstallation? {
        let key = Self.key(for: descriptor)
        if forceVerification {
            invalidateEvidence(key: key)
        }
        var requiresVerification = forceVerification

        while true {
            if let mutation = mutations[key] {
                await mutation.completion.value
                continue
            }
            if !requiresVerification, let cached = verified[key] {
                return cached
            }

            let verification: Verification
            if let current = verifications[key] {
                verification = current
            } else {
                let generation = UUID()
                let verifyInstallation = verifyInstallation
                let task = Task {
                    await verifyInstallation(descriptor)
                }
                verification = Verification(generation: generation, task: task)
                verifications[key] = verification
            }

            let installation = await verification.task.value
            guard verifications[key]?.generation == verification.generation else {
                // A mutation or explicit invalidation superseded this result.
                // Loop until the caller receives evidence for current state.
                requiresVerification = false
                continue
            }
            verifications[key] = nil
            verified[key] = installation
            return installation
        }
    }

    public func install(
        _ descriptor: ModelDescriptor,
        progress: (@Sendable (ModelStore.DownloadProgress) -> Void)? = nil
    ) async throws -> ModelStore.VerifiedInstallation {
        let key = Self.key(for: descriptor)
        invalidateEvidence(key: key)
        let previous = mutations[key]?.completion
        let generation = UUID()
        let installModel = installModel
        let task = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                let installation = try await installModel(descriptor, progress)
                // Installation has crossed its filesystem commit point. A
                // cancellation arriving now must not report false failure.
                completeInstall(
                    installation,
                    key: key,
                    generation: generation)
                return installation
            } catch {
                completeMutation(key: key, generation: generation)
                throw error
            }
        }
        let completion = Task {
            _ = try? await task.value
        }
        mutations[key] = Mutation(generation: generation, completion: completion)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func remove(_ descriptor: ModelDescriptor) async throws {
        let key = Self.key(for: descriptor)
        invalidateEvidence(key: key)
        let previous = mutations[key]?.completion
        let generation = UUID()
        let removeModel = removeModel
        let task = Task {
            await previous?.value
            do {
                try Task.checkCancellation()
                try await removeModel(descriptor)
                completeMutation(key: key, generation: generation)
            } catch {
                completeMutation(key: key, generation: generation)
                throw error
            }
        }
        let completion = Task {
            _ = try? await task.value
        }
        mutations[key] = Mutation(generation: generation, completion: completion)
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func invalidate(_ descriptor: ModelDescriptor) {
        invalidateEvidence(key: Self.key(for: descriptor))
    }

    private func invalidateEvidence(key: String) {
        verified[key] = nil
        verifications[key]?.task.cancel()
        verifications[key] = nil
    }

    private func completeInstall(
        _ installation: ModelStore.VerifiedInstallation,
        key: String,
        generation: UUID
    ) {
        guard mutations[key]?.generation == generation else { return }
        verified[key] = installation
        mutations[key] = nil
    }

    private func completeMutation(key: String, generation: UUID) {
        guard mutations[key]?.generation == generation else { return }
        mutations[key] = nil
    }

    private static func key(for descriptor: ModelDescriptor) -> String {
        "\(descriptor.id)@\(descriptor.revision)"
    }
}
