import CryptoKit
import Foundation

/// Downloads and verifies model artifacts against the pinned registry.
/// Nothing is ever loaded from a directory this store hasn't verified:
/// a model file is code we execute, so integrity is not optional.
public actor ModelStore {
    public enum ModelStoreError: Error, LocalizedError {
        case checksumMismatch(path: String, expected: String, actual: String)
        case sizeMismatch(path: String, expected: Int, actual: Int)
        case downloadFailed(path: String, underlying: String)
        case notInstalled(missing: [String], corrupted: [String])

        public var errorDescription: String? {
            switch self {
            case .checksumMismatch(let path, let expected, let actual):
                return "sha256 mismatch for \(path): expected \(expected), got \(actual)"
            case .sizeMismatch(let path, let expected, let actual):
                return "size mismatch for \(path): expected \(expected) bytes, got \(actual)"
            case .downloadFailed(let path, let underlying):
                return "download failed for \(path): \(underlying)"
            case .notInstalled(let missing, let corrupted):
                return "model not installed (missing: \(missing.count), corrupted: \(corrupted.count))"
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

    private let rootDirectory: URL
    private let session: URLSession

    /// `~/Library/Application Support/Portavoz/Models`
    public static var defaultRootDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support")
        return base.appendingPathComponent("Portavoz/Models", isDirectory: true)
    }

    public init(rootDirectory: URL = ModelStore.defaultRootDirectory, session: URLSession = .shared) {
        self.rootDirectory = rootDirectory
        self.session = session
    }

    public func directory(for descriptor: ModelDescriptor) -> URL {
        rootDirectory.appendingPathComponent(descriptor.folderName, isDirectory: true)
    }

    /// Re-hashes every artifact on disk against the descriptor.
    public func verify(_ descriptor: ModelDescriptor) -> VerificationReport {
        let base = directory(for: descriptor)
        var missing: [String] = []
        var corrupted: [String] = []

        for artifact in descriptor.artifacts {
            let url = base.appendingPathComponent(artifact.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                missing.append(artifact.path)
                continue
            }
            do {
                let digest = try Self.sha256(of: url)
                if digest != artifact.sha256 {
                    corrupted.append(artifact.path)
                }
            } catch {
                corrupted.append(artifact.path)
            }
        }
        return VerificationReport(missing: missing, corrupted: corrupted)
    }

    /// Returns loadable installation evidence only after every pinned artifact
    /// has been re-hashed. Callers must not infer readiness from directory,
    /// filename, or byte-count checks of their own.
    public func verifiedInstallation(
        _ descriptor: ModelDescriptor
    ) -> VerifiedInstallation? {
        guard verify(descriptor).isComplete else { return nil }
        return VerifiedInstallation(
            descriptorID: descriptor.id,
            descriptorRevision: descriptor.revision,
            directory: directory(for: descriptor),
            artifactBytes: Int64(descriptor.totalSizeBytes))
    }

    /// Ensures the model is installed and verified, downloading whatever is
    /// missing or corrupted. Returns the model directory, ready to load.
    /// Every downloaded file is hashed before it replaces anything on disk.
    @discardableResult
    public func ensureAvailable(
        _ descriptor: ModelDescriptor,
        progress: (@Sendable (DownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        let base = directory(for: descriptor)
        let report = verify(descriptor)
        if report.isComplete { return base }

        let pending = Set(report.missing + report.corrupted)
        let toFetch = descriptor.artifacts.filter { pending.contains($0.path) }
        let totalBytes = toFetch.reduce(0) { $0 + $1.sizeBytes }
        var completedBytes = 0

        for artifact in toFetch {
            progress?(
                DownloadProgress(
                    completedBytes: completedBytes, totalBytes: totalBytes,
                    currentPath: artifact.path))
            try await fetch(artifact, of: descriptor, into: base)
            completedBytes += artifact.sizeBytes
        }
        progress?(DownloadProgress(completedBytes: totalBytes, totalBytes: totalBytes, currentPath: ""))

        // Paranoia pass: everything the descriptor lists must now hash clean.
        let final = verify(descriptor)
        guard final.isComplete else {
            throw ModelStoreError.notInstalled(missing: final.missing, corrupted: final.corrupted)
        }
        return base
    }

    public func remove(_ descriptor: ModelDescriptor) throws {
        let base = directory(for: descriptor)
        if FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.removeItem(at: base)
        }
    }

    // MARK: - Internals

    private func fetch(_ artifact: ModelArtifact, of descriptor: ModelDescriptor, into base: URL) async throws {
        let source = descriptor.downloadURL(for: artifact)
        let destination = base.appendingPathComponent(artifact.path)

        let temporary: URL
        do {
            (temporary, _) = try await session.download(from: source)
        } catch {
            throw ModelStoreError.downloadFailed(
                path: artifact.path, underlying: String(describing: error))
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int) ?? -1
        guard size == artifact.sizeBytes else {
            throw ModelStoreError.sizeMismatch(
                path: artifact.path, expected: artifact.sizeBytes, actual: size)
        }

        let digest = try Self.sha256(of: temporary)
        guard digest == artifact.sha256 else {
            throw ModelStoreError.checksumMismatch(
                path: artifact.path, expected: artifact.sha256, actual: digest)
        }

        // Verified — move into place atomically (replacing a corrupt copy if any).
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
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
