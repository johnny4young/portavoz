import CryptoKit
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

    private let backing: Result<LocalModelStore, Error>
    private let legacyRoot: URL?

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
        backing = Result {
            try LocalModelStore(
                location: location,
                consumer: StoreConsumer(bundleID: consumer.identifier, displayName: consumer.displayName),
                session: session)
        }
        self.legacyRoot = legacyRoot
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
        await adoptLegacyInstall(descriptor, into: store)
        guard await isClaimed(manifest, in: store) else {
            return VerificationReport(missing: manifest.artifacts.map(\.path), corrupted: [])
        }
        let report = await store.verify(manifest)
        return VerificationReport(missing: report.missing, corrupted: report.corrupted)
    }

    /// Returns loadable installation evidence only after every pinned artifact
    /// has been hashed. Callers must not infer readiness from directory,
    /// filename, or byte-count checks of their own.
    public func verifiedInstallation(
        _ descriptor: ModelDescriptor
    ) async -> VerifiedInstallation? {
        guard await verify(descriptor).isComplete, let directory = try? await directory(for: descriptor) else {
            return nil
        }
        return VerifiedInstallation(
            descriptorID: descriptor.id,
            descriptorRevision: descriptor.revision,
            directory: directory,
            artifactBytes: Int64(descriptor.totalSizeBytes))
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

    /// Only a complete legacy install counts: checking must never start a download.
    private func adoptLegacyInstall(_ descriptor: ModelDescriptor, into store: LocalModelStore) async {
        let manifest = descriptor.manifest
        guard let legacy = legacyDirectory(for: descriptor),
              FileManager.default.fileExists(atPath: legacy.path),
              await !isClaimed(manifest, in: store) else { return }
        let isComplete = await Task.detached(priority: .utility) {
            descriptor.artifacts.allSatisfy { artifact in
                (try? Self.sha256(of: legacy.appendingPathComponent(artifact.path))) == artifact.sha256
            }
        }.value
        guard isComplete else { return }
        _ = try? await store.ensureAvailable(manifest, seeds: [legacy])
    }

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

    /// Streaming SHA-256 (1 MiB reads) so a 445 MB weight file never has to
    /// fit in memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
