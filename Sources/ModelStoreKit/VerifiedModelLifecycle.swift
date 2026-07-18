import Foundation

/// Process-scoped lifecycle for model installations admitted by `ModelStore`.
///
/// Only successful full-descriptor SHA-256 verification is cached. Missing or
/// corrupt results are deliberately rechecked, and explicit install, removal,
/// or invalidation prevents an older in-flight check from restoring stale
/// evidence.
public actor VerifiedModelLifecycle {
    private struct Verification: Sendable {
        let generation: UUID
        let task: Task<ModelStore.VerifiedInstallation?, Never>
    }

    private let store: ModelStore
    private var verified: [String: ModelStore.VerifiedInstallation] = [:]
    private var verifications: [String: Verification] = [:]

    public init(store: ModelStore) {
        self.store = store
    }

    public func installation(
        for descriptor: ModelDescriptor,
        forceVerification: Bool = false
    ) async -> ModelStore.VerifiedInstallation? {
        let key = Self.key(for: descriptor)
        if !forceVerification, let cached = verified[key] { return cached }
        if let verification = verifications[key] {
            return await verification.task.value
        }

        let generation = UUID()
        let store = store
        let task = Task {
            await store.verifiedInstallation(descriptor)
        }
        verifications[key] = Verification(generation: generation, task: task)
        let installation = await task.value
        if verifications[key]?.generation == generation {
            verifications[key] = nil
            verified[key] = installation
        }
        return installation
    }

    public func install(
        _ descriptor: ModelDescriptor,
        progress: (@Sendable (ModelStore.DownloadProgress) -> Void)? = nil
    ) async throws -> ModelStore.VerifiedInstallation {
        let key = Self.key(for: descriptor)
        invalidate(key: key)
        let directory = try await store.ensureAvailable(descriptor, progress: progress)
        let installation = ModelStore.VerifiedInstallation(
            descriptorID: descriptor.id,
            descriptorRevision: descriptor.revision,
            directory: directory,
            artifactBytes: Int64(descriptor.totalSizeBytes))
        verified[key] = installation
        return installation
    }

    public func remove(_ descriptor: ModelDescriptor) async throws {
        let key = Self.key(for: descriptor)
        invalidate(key: key)
        try await store.remove(descriptor)
    }

    public func invalidate(_ descriptor: ModelDescriptor) {
        invalidate(key: Self.key(for: descriptor))
    }

    private func invalidate(key: String) {
        verified[key] = nil
        verifications[key] = nil
    }

    private static func key(for descriptor: ModelDescriptor) -> String {
        "\(descriptor.id)@\(descriptor.revision)"
    }
}
