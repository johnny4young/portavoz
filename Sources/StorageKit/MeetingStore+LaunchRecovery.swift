import Foundation
import GRDB

/// Content-free failure evidence that can be shown or exported when the
/// writable application database cannot open. Raw SQLite messages and SQL are
/// deliberately excluded because they can contain local paths or user data.
public struct MeetingStoreOpenFailureEvidence: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case busy
        case damagedOrIncompatible = "damaged-or-incompatible"
        case inputOutput = "input-output"
        case permission
        case storageUnavailable = "storage-unavailable"
        case unknown
    }

    public let kind: Kind
    public let authority: String
    public let numericCode: Int

    public init(kind: Kind, authority: String, numericCode: Int) {
        self.kind = kind
        self.authority = authority
        self.numericCode = numericCode
    }
}

public enum MeetingStoreRecoveryCopyError: Error, Equatable, Sendable {
    case destinationUnavailable
    case integrityCheckFailed
    case sourceChanged
    case sourceUnavailable
}

extension MeetingStore {
    /// Reduces an arbitrary launch error to bounded, content-free evidence.
    public static func openFailureEvidence(
        for error: any Error
    ) -> MeetingStoreOpenFailureEvidence {
        guard let databaseError = error as? DatabaseError else {
            let systemError = error as NSError
            return MeetingStoreOpenFailureEvidence(
                kind: .unknown,
                authority: "system",
                numericCode: systemError.code)
        }

        let resultCode = databaseError.resultCode
        return MeetingStoreOpenFailureEvidence(
            kind: openFailureKind(for: resultCode),
            authority: "sqlite",
            numericCode: Int(databaseError.extendedResultCode.rawValue))
    }

    /// Creates one standalone SQLite snapshot. The failed authority and its
    /// committed WAL are copied with filesystem reads into a private stage;
    /// only that snapshot is opened by SQLite, read-only, for online backup.
    /// The authority is never migrated, renamed, deleted, or written.
    /// Publication is a same-directory rename from the hidden stage, and an
    /// existing destination is never replaced.
    public static func makeReadOnlyRecoveryCopy(
        of sourceURL: URL,
        in destinationRoot: URL,
        at timestamp: Date = Date()
    ) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try makeReadOnlyRecoveryCopySynchronously(
                of: sourceURL,
                in: destinationRoot,
                at: timestamp)
        }.value
    }
}

private extension MeetingStore {
    static func openFailureKind(
        for resultCode: ResultCode
    ) -> MeetingStoreOpenFailureEvidence.Kind {
        switch resultCode {
        case .SQLITE_BUSY, .SQLITE_LOCKED:
            .busy
        case .SQLITE_CORRUPT, .SQLITE_FORMAT, .SQLITE_NOTADB, .SQLITE_SCHEMA:
            .damagedOrIncompatible
        case .SQLITE_IOERR, .SQLITE_CANTOPEN:
            .inputOutput
        case .SQLITE_PERM, .SQLITE_AUTH, .SQLITE_READONLY:
            .permission
        case .SQLITE_FULL, .SQLITE_NOMEM:
            .storageUnavailable
        default:
            .unknown
        }
    }

    static func makeReadOnlyRecoveryCopySynchronously(
        of sourceURL: URL,
        in destinationRoot: URL,
        at timestamp: Date
    ) throws -> URL {
        let manager = FileManager.default
        let canonicalSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let sourceValues = try? canonicalSource.resourceValues(
            forKeys: [.isRegularFileKey])
        guard sourceValues?.isRegularFile == true else {
            throw MeetingStoreRecoveryCopyError.sourceUnavailable
        }

        let canonicalDestination = destinationRoot.standardizedFileURL
            .resolvingSymlinksInPath()
        let destinationValues = try? canonicalDestination.resourceValues(
            forKeys: [.isDirectoryKey])
        guard destinationValues?.isDirectory == true else {
            throw MeetingStoreRecoveryCopyError.destinationUnavailable
        }

        let stageURL = canonicalDestination.appendingPathComponent(
            ".portavoz-recovery-\(UUID().uuidString)",
            isDirectory: true)
        let finalURL = availableRecoveryDirectory(
            in: canonicalDestination,
            at: timestamp,
            manager: manager)
        try manager.createDirectory(
            at: stageURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var published = false
        defer {
            if !published {
                try? manager.removeItem(at: stageURL)
            }
        }

        // SQLite read-only connections may still need shared-memory state for
        // a WAL database. Snapshot the authority and its committed WAL with
        // filesystem reads first, so SQLite can create or update only private
        // stage sidecars and can never touch the failed source directory.
        let stagedSourceURL = stageURL.appendingPathComponent("source.sqlite")
        try copySourceSnapshot(
            from: canonicalSource,
            to: stagedSourceURL,
            manager: manager)

        let stagedDatabaseURL = stageURL.appendingPathComponent("portavoz.sqlite")
        try createVerifiedRecoveryDatabase(
            from: stagedSourceURL,
            at: stagedDatabaseURL)
        try manager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stagedDatabaseURL.path)
        try removePrivateSourceSnapshot(
            at: stagedSourceURL,
            manager: manager)
        try manager.moveItem(at: stageURL, to: finalURL)
        published = true
        return finalURL
    }

    static func createVerifiedRecoveryDatabase(
        from stagedSourceURL: URL,
        at stagedDatabaseURL: URL
    ) throws {
        var sourceConfiguration = Configuration()
        sourceConfiguration.readonly = true
        sourceConfiguration.busyMode = .timeout(5)
        let source = try DatabaseQueue(
            path: stagedSourceURL.path,
            configuration: sourceConfiguration)
        let destination = try DatabaseQueue(path: stagedDatabaseURL.path)

        do {
            try source.backup(to: destination, pagesPerStep: 256)
            let integrity = try destination.read { database in
                try String.fetchAll(database, sql: "PRAGMA quick_check")
            }
            guard integrity == ["ok"] else {
                throw MeetingStoreRecoveryCopyError.integrityCheckFailed
            }
            try source.close()
            try destination.close()
        } catch {
            try? source.close()
            try? destination.close()
            throw error
        }
    }

    static func availableRecoveryDirectory(
        in root: URL,
        at timestamp: Date,
        manager: FileManager
    ) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        let safeTimestamp = formatter.string(from: timestamp)
            .replacingOccurrences(of: ":", with: "-")
        let baseName = "Portavoz Database Recovery \(safeTimestamp)"
        for suffix in 1...100 {
            let name = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            let candidate = root.appendingPathComponent(name, isDirectory: true)
            if !manager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return root.appendingPathComponent(
            "\(baseName) \(UUID().uuidString)",
            isDirectory: true)
    }

    static func copySourceSnapshot(
        from sourceURL: URL,
        to stagedSourceURL: URL,
        manager: FileManager
    ) throws {
        let evidenceBefore = sourceSnapshotEvidence(
            at: sourceURL,
            manager: manager)
        try manager.copyItem(at: sourceURL, to: stagedSourceURL)
        try manager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stagedSourceURL.path)

        let sourceWAL = URL(fileURLWithPath: sourceURL.path + "-wal")
        if manager.fileExists(atPath: sourceWAL.path) {
            let values = try? sourceWAL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true else {
                throw MeetingStoreRecoveryCopyError.sourceUnavailable
            }
            let stagedWAL = URL(fileURLWithPath: stagedSourceURL.path + "-wal")
            try manager.copyItem(at: sourceWAL, to: stagedWAL)
            try manager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stagedWAL.path)
        }
        guard sourceSnapshotEvidence(at: sourceURL, manager: manager)
            == evidenceBefore else {
            throw MeetingStoreRecoveryCopyError.sourceChanged
        }
    }

    static func removePrivateSourceSnapshot(
        at stagedSourceURL: URL,
        manager: FileManager
    ) throws {
        let parent = stagedSourceURL.deletingLastPathComponent()
        let prefix = stagedSourceURL.lastPathComponent
        let artifacts = try manager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil)
        for artifact in artifacts where artifact.lastPathComponent.hasPrefix(prefix) {
            try manager.removeItem(at: artifact)
        }
    }

    static func sourceSnapshotEvidence(
        at sourceURL: URL,
        manager: FileManager
    ) -> [String: SourceArtifactEvidence] {
        ["database", "wal"].reduce(into: [:]) { result, kind in
            let url = kind == "database"
                ? sourceURL
                : URL(fileURLWithPath: sourceURL.path + "-wal")
            guard let attributes = try? manager.attributesOfItem(
                atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modifiedAt = attributes[.modificationDate] as? Date else {
                return
            }
            result[kind] = SourceArtifactEvidence(
                size: size,
                modifiedAt: modifiedAt)
        }
    }
}

private struct SourceArtifactEvidence: Equatable {
    let size: UInt64
    let modifiedAt: Date
}
