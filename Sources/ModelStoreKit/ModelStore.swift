import Foundation
import LocalModelStore

/// Downloads and verifies model artifacts against the pinned registry.
/// Nothing is ever loaded from a directory this store hasn't verified:
/// a model file is code we execute, so integrity is not optional.
public actor ModelStore {
    public enum ModelStoreError: Error, LocalizedError {
        case checksumMismatch(path: String, expected: String, actual: String)
        case sizeMismatch(path: String, expected: Int, actual: Int)
        case downloadFailed(path: String, underlying: String)
        /// The disk or quota was full while downloading, staging or publishing.
        case outOfSpace(path: String)
        case notInstalled(missing: [String], corrupted: [String])
        /// The shared store cannot be used, or another process is deleting this model.
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .checksumMismatch(let path, let expected, let actual):
                return "sha256 mismatch for \(path): expected \(expected), got \(actual)"
            case .sizeMismatch(let path, let expected, let actual):
                return "size mismatch for \(path): expected \(expected) bytes, got \(actual)"
            case .downloadFailed(let path, let underlying):
                return "download failed for \(path): \(underlying)"
            case .outOfSpace(let path):
                return "not enough disk space to save \(path)"
            case .notInstalled(let missing, let corrupted):
                return "model not installed (missing: \(missing.count), corrupted: \(corrupted.count))"
            case .unavailable(let reason):
                return reason
            }
        }

        init(_ error: LocalModelStore.LocalModelStoreError) {
            switch error {
            case .checksumMismatch(let path, let expected, let actual):
                self = .checksumMismatch(path: path, expected: expected, actual: actual)
            case .sizeMismatch(let path, let expected, let actual):
                self = .sizeMismatch(path: path, expected: expected, actual: actual)
            case .downloadFailed(let path, let underlying):
                self = .downloadFailed(path: path, underlying: underlying)
            case .outOfSpace(let path):
                self = .outOfSpace(path: path)
            case .notInstalled(let missing, let corrupted):
                self = .notInstalled(missing: missing, corrupted: corrupted)
            case .invalidManifest, .sandboxed, .invalidConsumer, .busy:
                self = .unavailable(error.localizedDescription)
            }
        }
    }

    /// Result of checking an installed model against its descriptor.
    public struct VerificationReport: Sendable {
        public let missing: [String]
        public let corrupted: [String]
        public var isComplete: Bool { missing.isEmpty && corrupted.isEmpty }
    }

    /// A directory that passed the complete pinned descriptor, not merely a
    /// path that happens to contain one expected filename.
    public struct VerifiedInstallation: Equatable, Sendable {
        public let descriptorID: String
        public let descriptorRevision: String
        public let directory: URL
        public let artifactBytes: Int64

        init(
            descriptorID: String,
            descriptorRevision: String,
            directory: URL,
            artifactBytes: Int64
        ) {
            self.descriptorID = descriptorID
            self.descriptorRevision = descriptorRevision
            self.directory = directory
            self.artifactBytes = artifactBytes
        }
    }

    /// Keeps verified shared-store files on disk until the last runtime or job
    /// using them unloads. Installation evidence alone does not hold this lock.
    public final class ModelLease: Sendable {
        public let directory: URL
        /// Claims remain the fallback on volumes that do not support file locks.
        public var isProtected: Bool { backing.isProtected }
        private let backing: LocalModelStore.ModelLease

        fileprivate init(_ backing: LocalModelStore.ModelLease) {
            self.backing = backing
            directory = backing.directory
        }
    }

    public struct DownloadProgress: Sendable {
        public let completedBytes: Int
        public let totalBytes: Int
        public let currentPath: String
        public var fraction: Double {
            totalBytes > 0 ? Double(completedBytes) / Double(totalBytes) : 0
        }
    }

    /// Who is using the store. Every process names itself: a claim keeps a model on
    /// disk for that consumer, and Settings shows the name to people.
    public struct Consumer: Sendable, Equatable {
        public let identifier: String
        public let displayName: String

        public init(identifier: String, displayName: String) {
            self.identifier = identifier
            self.displayName = displayName
        }
    }

    /// What a removal did. A model another app still needs stays for that app.
    public enum RemovalOutcome: Equatable, Sendable {
        case removed
        case keptForOthers([String])
        case deferred
    }

    /// One model on this Mac, whichever app asked for it.
    public struct InstalledModel: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let bytes: Int?
        public let isUsedHere: Bool
        public let otherApps: [String]

        public init(id: String, name: String, bytes: Int?, isUsedHere: Bool, otherApps: [String]) {
            self.id = id
            self.name = name
            self.bytes = bytes
            self.isUsedHere = isUsedHere
            self.otherApps = otherApps
        }
    }

    private let backing: Result<LocalModelStore, Error>
    /// The same store with no network, so adopting a legacy install can only place files.
    private let adopter: LocalModelStore?
    private let legacyRoot: URL?
    private let consumerName: String

    /// Where Portavoz kept models before the shared store. Read as a seed, so an
    /// existing install moves without a download.
    public static var legacyRootDirectory: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Portavoz/Models", isDirectory: true)
    }

    /// The store shared with other apps on this Mac.
    public static func userLibrary(consumer: Consumer, session: URLSession = .shared) -> ModelStore {
        ModelStore(location: .userLibrary, consumer: consumer, legacyRoot: legacyRootDirectory, session: session)
    }

    /// A store in an explicit folder, for tests and tools. `legacyRoot` is read as a seed.
    public init(rootDirectory: URL, consumer: Consumer, legacyRoot: URL? = nil, session: URLSession = .shared) {
        self.init(location: .directory(rootDirectory), consumer: consumer, legacyRoot: legacyRoot, session: session)
    }

    private init(location: StoreLocation, consumer: Consumer, legacyRoot: URL?, session: URLSession) {
        let storeConsumer = StoreConsumer(bundleID: consumer.identifier, displayName: consumer.displayName)
        backing = Result { try LocalModelStore(location: location, consumer: storeConsumer, session: session) }
        adopter = legacyRoot == nil ? nil : try? LocalModelStore(
            location: location, consumer: storeConsumer, session: Self.offlineSession)
        self.legacyRoot = legacyRoot
        consumerName = consumer.displayName
    }

    public func directory(for descriptor: ModelDescriptor) async throws -> URL {
        try await translatingErrors { try await store().directory(for: descriptor.manifest) }
    }

    /// Re-hashes the installation against the descriptor. A model this app never asked
    /// for reads as missing even when another app installed it, because presence is
    /// not consent. A complete legacy install is adopted first, without a download.
    public func verify(_ descriptor: ModelDescriptor) async -> VerificationReport {
        let manifest = descriptor.manifest
        guard let store = try? store() else {
            return VerificationReport(missing: manifest.artifacts.map(\.path), corrupted: [])
        }
        await adoptLegacyInstall(descriptor)
        guard await isClaimed(manifest, in: store) else {
            return VerificationReport(missing: manifest.artifacts.map(\.path), corrupted: [])
        }
        let report = await store.verify(manifest)
        return VerificationReport(missing: report.missing, corrupted: report.corrupted)
    }

    /// Returns loadable installation evidence only after every pinned artifact has
    /// been hashed in this process and is unchanged since. `forceHash` reads them
    /// again. Callers must not infer readiness from directory, filename, or byte-count
    /// checks of their own.
    public func verifiedInstallation(
        _ descriptor: ModelDescriptor,
        forceHash: Bool = false
    ) async -> VerifiedInstallation? {
        let manifest = descriptor.manifest
        guard let store = try? store() else { return nil }
        await adoptLegacyInstall(descriptor)
        guard await isClaimed(manifest, in: store),
              let installed = await store.verifiedInstallation(manifest, forceHash: forceHash) else { return nil }
        return VerifiedInstallation(
            descriptorID: descriptor.id,
            descriptorRevision: descriptor.revision,
            directory: installed.directory,
            artifactBytes: installed.artifactBytes)
    }

    /// Protects this consumer's installation before rechecking its bytes. This
    /// never downloads or claims a model merely because another app installed it.
    public func lease(_ descriptor: ModelDescriptor) async throws -> ModelLease {
        try Task.checkCancellation()
        let manifest = descriptor.manifest
        await adoptLegacyInstall(descriptor)
        return try await translatingErrors {
            let store = try store()
            guard await isClaimed(manifest, in: store) else {
                throw ModelStoreError.notInstalled(missing: manifest.artifacts.map(\.path), corrupted: [])
            }
            let lease = try await store.lease(manifest)
            try Task.checkCancellation()
            return ModelLease(lease)
        }
    }

    /// Ensures the model is installed and verified, placing what this Mac already has
    /// and downloading the rest. Returns the directory to load. Every file is hashed
    /// before it is published.
    @discardableResult
    public func ensureAvailable(
        _ descriptor: ModelDescriptor,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        let seeds = legacyDirectory(for: descriptor).map { [$0] } ?? []
        return try await translatingErrors {
            try await store().ensureAvailable(descriptor.manifest, seeds: seeds) { event in
                guard case .downloading(let state) = event else { return }
                progress?(DownloadProgress(
                    completedBytes: state.completedBytes, totalBytes: state.totalBytes,
                    currentPath: state.currentPath))
            }
        }
    }

    /// Whether getting this model would fetch bytes. False when another app installed it.
    public func needsDownload(_ descriptor: ModelDescriptor) async -> Bool {
        guard await !verify(descriptor).isComplete, let store = try? store() else { return false }
        return await store.verifiedInstallation(descriptor.manifest) == nil
    }

    /// Removes this app's copy, including its legacy one so it is not adopted again.
    /// The bytes stay while another app claims or uses them.
    @discardableResult
    public func remove(_ descriptor: ModelDescriptor) async throws -> RemovalOutcome {
        if let legacy = legacyDirectory(for: descriptor), FileManager.default.fileExists(atPath: legacy.path) {
            try FileManager.default.removeItem(at: legacy)
        }
        let outcome = try await translatingErrors { try await store().remove(descriptor.manifest) }
        switch outcome {
        case .removed: return .removed
        case .keptForOthers(let names): return .keptForOthers(names)
        case .deferred: return .deferred
        }
    }

    /// Every model in the store, including those only other apps use.
    public func installedModels() async -> [InstalledModel] {
        guard let store = try? store() else { return [] }
        return await store.inventory().map { entry in
            InstalledModel(
                id: entry.key,
                name: entry.displayName ?? entry.id ?? entry.key,
                bytes: entry.logicalBytes,
                isUsedHere: entry.isClaimedByThisConsumer,
                otherApps: entry.claimants.filter { $0 != consumerName })
        }
    }

    /// Fires when models or claims change in any process, with no polling.
    nonisolated public func changes() -> AsyncStream<Void> {
        guard case .success(let store) = backing else { return AsyncStream { $0.finish() } }
        return store.changes()
    }

    /// Retires claims an update re-pinned and collects what no app claims any more.
    public func collectUnused(keeping descriptors: [ModelDescriptor]) async throws {
        try await translatingErrors {
            let store = try store()
            try await store.reconcileClaims(keeping: descriptors.map(\.manifest))
            _ = try await store.collectGarbage()
        }
    }

    // MARK: - Internals

    private func store() throws -> LocalModelStore {
        try backing.get()
    }

    private func legacyDirectory(for descriptor: ModelDescriptor) -> URL? {
        legacyRoot?.appendingPathComponent(descriptor.folderName, isDirectory: true)
    }

    private func isClaimed(_ manifest: ModelManifest, in store: LocalModelStore) async -> Bool {
        guard let key = try? await store.directory(for: manifest).deletingLastPathComponent().lastPathComponent else {
            return false
        }
        return await store.inventory().contains { $0.key == key && $0.isClaimedByThisConsumer }
    }

    /// Sizes rule out a partial install without reading it. A file that still fails its
    /// hash ends the attempt, because this store cannot download.
    private func adoptLegacyInstall(_ descriptor: ModelDescriptor) async {
        let manifest = descriptor.manifest
        guard let adopter, let legacy = legacyDirectory(for: descriptor),
              Self.holdsExpectedSizes(descriptor, in: legacy),
              await !isClaimed(manifest, in: adopter) else { return }
        _ = try? await adopter.ensureAvailable(manifest, seeds: [legacy])
    }

    private static func holdsExpectedSizes(_ descriptor: ModelDescriptor, in directory: URL) -> Bool {
        descriptor.artifacts.allSatisfy { artifact in
            let file = directory.appendingPathComponent(artifact.path)
            let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int
            return size == artifact.sizeBytes
        }
    }

    private static let offlineSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    private func translatingErrors<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as LocalModelStore.LocalModelStoreError {
            throw ModelStoreError(error)
        }
    }

    /// Whether a disk-full or quota cause appears anywhere in the error's cause chain.
    public static func isOutOfSpace(_ error: NSError) -> Bool {
        if case .outOfSpace = error as? ModelStoreError { return true }
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(ENOSPC) || error.code == Int(EDQUOT) {
            return true
        }
        var causes = (error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError]) ?? []
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { causes.append(underlying) }
        return causes.contains { isOutOfSpace($0) }
    }
}

/// Refuses every request before it reaches the network.
private final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
