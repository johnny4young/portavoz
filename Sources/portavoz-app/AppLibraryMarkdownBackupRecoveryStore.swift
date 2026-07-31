import ApplicationKit
import Darwin
import Foundation

/// Incremental owner-private publication evidence for whole-library Markdown
/// backup. Steady-state mutations write O(1) bytes per document; reconstructing
/// the completed manifest is deferred to recovery.
actor AppLibraryMarkdownBackupRecoveryStore:
    LibraryMarkdownBackupRecoveryStore {
    private static let metadataFormatVersion = 2
    private static let legacyMetadataFormatVersion = 1
    private static let recordFormatVersion = 1
    private static let maximumRecordBytes = 1 * 1_024 * 1_024

    private let root: URL
    private let fileManager: FileManager
    private var nextSequenceByOperation: [UUID: Int] = [:]
    private var nextFailureSequenceByOperation: [UUID: Int] = [:]

    init(
        root: URL,
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.fileManager = fileManager
    }

    func operationIDs() throws -> Set<UUID> {
        guard try itemExists(root) else { return [] }
        try validateDirectory(root)
        let children = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil)
        return Set(children.compactMap { child in
            let name = child.lastPathComponent
            guard let operationID = UUID(uuidString: name),
                  operationID.uuidString.lowercased() == name
            else { return nil }
            // Shape and contents are intentionally not trusted here. A
            // canonical symlink or malformed directory still protects the
            // matching immutable stage until strict load reports the error.
            return operationID
        })
    }

    func apply(
        _ mutation: LibraryMarkdownBackupRecoveryMutation,
        operationID: UUID
    ) throws {
        switch mutation {
        case .begin(let destinationBookmark):
            try begin(
                operationID: operationID,
                destinationBookmark: destinationBookmark)
        case .updateDestinationBookmark(let destinationBookmark):
            try updateDestinationBookmark(
                destinationBookmark,
                operationID: operationID)
        case .reserve(let publication):
            try reserve(
                publication,
                operationID: operationID)
        case .complete(let publication):
            try complete(
                publication,
                operationID: operationID)
        case .clearReservation:
            _ = try activeMetadata(operationID: operationID)
            try removeRegularFileIfPresent(
                pendingURL(operationID: operationID))
        case .recordFailure(let failure):
            try recordFailure(
                failure,
                operationID: operationID)
        case .checkpointSource(let cursor):
            try checkpointSource(
                cursor,
                operationID: operationID)
        case .markCompleted:
            try markCompleted(operationID: operationID)
        }
    }

    func load(
        operationID: UUID
    ) throws -> LibraryMarkdownBackupRecoveryState? {
        let operation = operationURL(operationID: operationID)
        guard try itemExists(operation) else { return nil }
        try validateDirectory(operation)
        let metadata = try loadMetadata(operationID: operationID)
        let completed = try completedPublications(operationID: operationID)
        let failures = try failureRecords(
            operationID: operationID,
            metadataVersion: metadata.version)
        let pendingURL = pendingURL(operationID: operationID)
        let pending = try itemExists(pendingURL)
            ? try loadPublication(at: pendingURL, operationID: operationID)
            : nil
        guard pending?.sequence == nil || pending?.sequence == completed.count,
              metadata.phase != .completed || pending == nil
        else {
            throw RecoveryStoreError.invalidDocument
        }
        nextSequenceByOperation[operationID] = completed.count
        nextFailureSequenceByOperation[operationID] = failures.count
        return LibraryMarkdownBackupRecoveryState(
            operationID: operationID,
            destinationBookmark: metadata.destinationBookmark,
            sourceCursor: metadata.sourceCursor,
            completedPublications: completed,
            failures: failures,
            pendingPublication: pending,
            phase: metadata.phase)
    }

    func remove(operationID: UUID) throws {
        let target = operationURL(operationID: operationID)
        guard try itemExists(target) else { return }
        try validateDirectory(target)
        try fileManager.removeItem(at: target)
        nextSequenceByOperation[operationID] = nil
        nextFailureSequenceByOperation[operationID] = nil
    }
}

private extension AppLibraryMarkdownBackupRecoveryStore {
    struct MetadataDocument: Codable {
        var version: Int
        let operationID: UUID
        var destinationBookmark: LibraryMarkdownBackupDestinationBookmark
        var sourceCursor: LibraryMarkdownBackupSourceCursor?
        var phase: LibraryMarkdownBackupRecoveryPhase
    }

    struct PublicationDocument: Codable {
        let version: Int
        let operationID: UUID
        let publication: LibraryMarkdownBackupRecoveryPublication
    }

    struct FailureDocument: Codable {
        let version: Int
        let operationID: UUID
        let failure: LibraryMarkdownBackupRecoveryFailure
    }

    enum RecoveryStoreError: Error {
        case documentTooLarge
        case invalidDocument
        case unsafePath
    }

    func updateDestinationBookmark(
        _ destinationBookmark: LibraryMarkdownBackupDestinationBookmark,
        operationID: UUID
    ) throws {
        guard !destinationBookmark.data.isEmpty else {
            throw RecoveryStoreError.invalidDocument
        }
        var metadata = try activeMetadata(operationID: operationID)
        metadata.destinationBookmark = destinationBookmark
        try write(metadata, to: metadataURL(operationID: operationID))
    }

    func reserve(
        _ publication: LibraryMarkdownBackupRecoveryPublication,
        operationID: UUID
    ) throws {
        _ = try activeMetadata(operationID: operationID)
        try validateNext(publication, operationID: operationID)
        try write(
            PublicationDocument(
                version: Self.recordFormatVersion,
                operationID: operationID,
                publication: publication),
            to: pendingURL(operationID: operationID))
    }

    func complete(
        _ publication: LibraryMarkdownBackupRecoveryPublication,
        operationID: UUID
    ) throws {
        _ = try activeMetadata(operationID: operationID)
        try validateNext(publication, operationID: operationID)
        let pending = try loadPublication(
            at: pendingURL(operationID: operationID),
            operationID: operationID)
        guard pending == publication else {
            throw RecoveryStoreError.invalidDocument
        }
        let destination = completedURL(
            operationID: operationID,
            sequence: publication.sequence)
        guard try !itemExists(destination) else {
            throw RecoveryStoreError.invalidDocument
        }
        try fileManager.moveItem(
            at: pendingURL(operationID: operationID),
            to: destination)
        nextSequenceByOperation[operationID] = publication.sequence + 1
    }

    func markCompleted(operationID: UUID) throws {
        var metadata = try loadMetadata(operationID: operationID)
        guard try !itemExists(
            pendingURL(operationID: operationID))
        else {
            throw RecoveryStoreError.invalidDocument
        }
        guard metadata.phase == .active else { return }
        metadata.phase = .completed
        try write(metadata, to: metadataURL(operationID: operationID))
    }

    func begin(
        operationID: UUID,
        destinationBookmark: LibraryMarkdownBackupDestinationBookmark
    ) throws {
        guard !destinationBookmark.data.isEmpty else {
            throw RecoveryStoreError.invalidDocument
        }
        try prepareRoot()
        let operation = operationURL(operationID: operationID)
        guard try !itemExists(operation) else {
            throw RecoveryStoreError.invalidDocument
        }
        try createPrivateDirectory(operation)
        do {
            try createPrivateDirectory(
                completedDirectoryURL(operationID: operationID))
            try createPrivateDirectory(
                failuresDirectoryURL(operationID: operationID))
            try write(
                MetadataDocument(
                    version: Self.metadataFormatVersion,
                    operationID: operationID,
                    destinationBookmark: destinationBookmark,
                    sourceCursor: nil,
                    phase: .active),
                to: metadataURL(operationID: operationID))
            nextSequenceByOperation[operationID] = 0
            nextFailureSequenceByOperation[operationID] = 0
        } catch {
            try? fileManager.removeItem(at: operation)
            throw error
        }
    }

    func prepareRoot() throws {
        if try itemExists(root) {
            try validateDirectory(root)
        } else {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path)
        var protectedRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedRoot.setResourceValues(values)
    }

    func createPrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path)
    }

    func activeMetadata(
        operationID: UUID
    ) throws -> MetadataDocument {
        let metadata = try loadMetadata(operationID: operationID)
        guard metadata.phase == .active else {
            throw RecoveryStoreError.invalidDocument
        }
        return metadata
    }

    func checkpointSource(
        _ cursor: LibraryMarkdownBackupSourceCursor,
        operationID: UUID
    ) throws {
        try Self.validate(cursor)
        guard try !itemExists(pendingURL(operationID: operationID)) else {
            throw RecoveryStoreError.invalidDocument
        }
        var metadata = try activeMetadata(operationID: operationID)
        if let current = metadata.sourceCursor {
            guard cursor == current || Self.isAfter(cursor, current) else {
                throw RecoveryStoreError.invalidDocument
            }
        }
        metadata.sourceCursor = cursor
        try write(metadata, to: metadataURL(operationID: operationID))
    }

    func loadMetadata(
        operationID: UUID
    ) throws -> MetadataDocument {
        try validateDirectory(operationURL(operationID: operationID))
        let metadata: MetadataDocument = try read(
            MetadataDocument.self,
            at: metadataURL(operationID: operationID))
        guard [
            Self.legacyMetadataFormatVersion,
            Self.metadataFormatVersion
        ].contains(metadata.version),
              metadata.operationID == operationID,
              !metadata.destinationBookmark.data.isEmpty
        else {
            throw RecoveryStoreError.invalidDocument
        }
        if let sourceCursor = metadata.sourceCursor {
            try Self.validate(sourceCursor)
        }
        return metadata
    }

    func completedPublications(
        operationID: UUID
    ) throws -> [LibraryMarkdownBackupRecoveryPublication] {
        let directory = completedDirectoryURL(operationID: operationID)
        try validateDirectory(directory)
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
        let publications = try urls.map { url in
            let publication = try loadPublication(
                at: url,
                operationID: operationID)
            guard url.lastPathComponent == completedFileName(
                sequence: publication.sequence)
            else {
                throw RecoveryStoreError.invalidDocument
            }
            return publication
        }.sorted { $0.sequence < $1.sequence }
        guard publications.indices.allSatisfy({
            publications[$0].sequence == $0
        }) else {
            throw RecoveryStoreError.invalidDocument
        }
        return publications
    }

    func failureRecords(
        operationID: UUID,
        metadataVersion: Int
    ) throws -> [LibraryMarkdownBackupRecoveryFailure] {
        let directory = failuresDirectoryURL(operationID: operationID)
        guard try itemExists(directory) else {
            guard metadataVersion == Self.legacyMetadataFormatVersion else {
                throw RecoveryStoreError.invalidDocument
            }
            return []
        }
        try validateDirectory(directory)
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
        guard metadataVersion != Self.legacyMetadataFormatVersion
                || urls.isEmpty
        else {
            throw RecoveryStoreError.invalidDocument
        }
        let failures = try urls.map { url in
            let failure = try loadFailure(
                at: url,
                operationID: operationID)
            guard url.lastPathComponent == failureFileName(
                sequence: failure.sequence)
            else {
                throw RecoveryStoreError.invalidDocument
            }
            return failure
        }.sorted { $0.sequence < $1.sequence }
        guard failures.indices.allSatisfy({
            failures[$0].sequence == $0
        }) else {
            throw RecoveryStoreError.invalidDocument
        }
        return failures
    }

    func recordFailure(
        _ failure: LibraryMarkdownBackupRecoveryFailure,
        operationID: UUID
    ) throws {
        try Self.validate(failure)
        guard try !itemExists(pendingURL(operationID: operationID)) else {
            throw RecoveryStoreError.invalidDocument
        }
        var metadata = try activeMetadata(operationID: operationID)
        let directory = failuresDirectoryURL(operationID: operationID)
        if try itemExists(directory) {
            try validateDirectory(directory)
        } else {
            guard metadata.version == Self.legacyMetadataFormatVersion else {
                throw RecoveryStoreError.invalidDocument
            }
            try createPrivateDirectory(directory)
        }
        if metadata.version == Self.legacyMetadataFormatVersion {
            metadata.version = Self.metadataFormatVersion
            try write(metadata, to: metadataURL(operationID: operationID))
        }

        let destination = failureURL(
            operationID: operationID,
            sequence: failure.sequence)
        if try itemExists(destination) {
            if nextFailureSequenceByOperation[operationID] == nil {
                nextFailureSequenceByOperation[operationID] = try failureRecords(
                    operationID: operationID,
                    metadataVersion: metadata.version).count
            }
            guard try loadFailure(
                at: destination,
                operationID: operationID) == failure
            else {
                throw RecoveryStoreError.invalidDocument
            }
            nextFailureSequenceByOperation[operationID] = max(
                nextFailureSequenceByOperation[operationID] ?? 0,
                failure.sequence + 1)
            return
        }

        let expected: Int
        if let cached = nextFailureSequenceByOperation[operationID] {
            expected = cached
        } else {
            expected = try failureRecords(
                operationID: operationID,
                metadataVersion: metadata.version).count
            nextFailureSequenceByOperation[operationID] = expected
        }
        guard failure.sequence == expected else {
            throw RecoveryStoreError.invalidDocument
        }
        try write(
            FailureDocument(
                version: Self.recordFormatVersion,
                operationID: operationID,
                failure: failure),
            to: destination)
        nextFailureSequenceByOperation[operationID] = failure.sequence + 1
    }

    func validateNext(
        _ publication: LibraryMarkdownBackupRecoveryPublication,
        operationID: UUID
    ) throws {
        try Self.validate(publication)
        let expected: Int
        if let cached = nextSequenceByOperation[operationID] {
            expected = cached
        } else {
            expected = try completedPublications(
                operationID: operationID).count
            nextSequenceByOperation[operationID] = expected
        }
        guard publication.sequence == expected else {
            throw RecoveryStoreError.invalidDocument
        }
    }

    func loadPublication(
        at url: URL,
        operationID: UUID
    ) throws -> LibraryMarkdownBackupRecoveryPublication {
        let document: PublicationDocument = try read(
            PublicationDocument.self,
            at: url)
        guard document.version == Self.recordFormatVersion,
              document.operationID == operationID
        else {
            throw RecoveryStoreError.invalidDocument
        }
        try Self.validate(document.publication)
        return document.publication
    }

    func loadFailure(
        at url: URL,
        operationID: UUID
    ) throws -> LibraryMarkdownBackupRecoveryFailure {
        let document: FailureDocument = try read(
            FailureDocument.self,
            at: url)
        guard document.version == Self.recordFormatVersion,
              document.operationID == operationID
        else {
            throw RecoveryStoreError.invalidDocument
        }
        try Self.validate(document.failure)
        return document.failure
    }

    func write<T: Encodable>(
        _ value: T,
        to destination: URL
    ) throws {
        if try itemExists(destination) {
            try validateRegularFile(destination)
        }
        let data = try JSONEncoder.portavozBackupRecovery.encode(value)
        guard data.count <= Self.maximumRecordBytes else {
            throw RecoveryStoreError.documentTooLarge
        }
        try data.write(to: destination, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path)
    }

    func read<T: Decodable>(
        _ type: T.Type,
        at source: URL
    ) throws -> T {
        try validateRegularFile(source)
        let data = try Data(
            contentsOf: source,
            options: .mappedIfSafe)
        guard data.count <= Self.maximumRecordBytes else {
            throw RecoveryStoreError.documentTooLarge
        }
        return try JSONDecoder.portavozBackupRecovery.decode(
            type,
            from: data)
    }

    func removeRegularFileIfPresent(_ url: URL) throws {
        guard try itemExists(url) else { return }
        try validateRegularFile(url)
        try fileManager.removeItem(at: url)
    }

    func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true
        else {
            throw RecoveryStoreError.unsafePath
        }
    }

    func itemExists(_ url: URL) throws -> Bool {
        var information = stat()
        if Darwin.lstat(url.path, &information) == 0 {
            return true
        }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return false
    }

    func validateRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            throw RecoveryStoreError.unsafePath
        }
    }

    func operationURL(operationID: UUID) -> URL {
        root.appendingPathComponent(
            operationID.uuidString.lowercased(),
            isDirectory: true)
    }

    func metadataURL(operationID: UUID) -> URL {
        operationURL(operationID: operationID)
            .appendingPathComponent("metadata.json")
    }

    func pendingURL(operationID: UUID) -> URL {
        operationURL(operationID: operationID)
            .appendingPathComponent("pending.json")
    }

    func completedDirectoryURL(operationID: UUID) -> URL {
        operationURL(operationID: operationID)
            .appendingPathComponent("completed", isDirectory: true)
    }

    func failuresDirectoryURL(operationID: UUID) -> URL {
        operationURL(operationID: operationID)
            .appendingPathComponent("failures", isDirectory: true)
    }

    func completedURL(
        operationID: UUID,
        sequence: Int
    ) -> URL {
        completedDirectoryURL(operationID: operationID)
            .appendingPathComponent(completedFileName(sequence: sequence))
    }

    func completedFileName(sequence: Int) -> String {
        String(format: "%012d.json", sequence)
    }

    func failureURL(
        operationID: UUID,
        sequence: Int
    ) -> URL {
        failuresDirectoryURL(operationID: operationID)
            .appendingPathComponent(failureFileName(sequence: sequence))
    }

    func failureFileName(sequence: Int) -> String {
        String(format: "%012d.json", sequence)
    }

    static func validate(
        _ publication: LibraryMarkdownBackupRecoveryPublication
    ) throws {
        guard publication.sequence >= 0,
              publication.byteCount >= 0,
              publication.sha256.count == 64,
              publication.sha256.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }),
              !publication.fileName.isEmpty,
              !publication.fileName.hasPrefix("."),
              URL(fileURLWithPath: publication.fileName).lastPathComponent
                == publication.fileName,
              URL(fileURLWithPath: publication.fileName)
                .pathExtension.lowercased() == "md"
        else {
            throw RecoveryStoreError.invalidDocument
        }
        if let sourceCursor = publication.sourceCursor {
            try validate(sourceCursor)
            guard sourceCursor.recordID
                == publication.meetingID.rawValue.uuidString
            else {
                throw RecoveryStoreError.invalidDocument
            }
        }
    }

    static func validate(
        _ cursor: LibraryMarkdownBackupSourceCursor
    ) throws {
        guard cursor.startedAt.timeIntervalSince1970.isFinite,
              !cursor.recordID.isEmpty,
              cursor.recordID.utf8.count <= 128
        else {
            throw RecoveryStoreError.invalidDocument
        }
    }

    static func validate(
        _ failure: LibraryMarkdownBackupRecoveryFailure
    ) throws {
        try validate(failure.sourceCursor)
        guard failure.sequence >= 0,
              failure.title.utf8.count
                <= LibraryMarkdownBackupRecoveryFailure.maximumTitleBytes,
              failure.stage == .source || failure.meetingID != nil
        else {
            throw RecoveryStoreError.invalidDocument
        }
        if let meetingID = failure.meetingID {
            guard failure.sourceCursor.recordID
                == meetingID.rawValue.uuidString
            else {
                throw RecoveryStoreError.invalidDocument
            }
        }
    }

    static func isAfter(
        _ candidate: LibraryMarkdownBackupSourceCursor,
        _ current: LibraryMarkdownBackupSourceCursor
    ) -> Bool {
        candidate.startedAt < current.startedAt
            || (
                candidate.startedAt == current.startedAt
                    && candidate.recordID > current.recordID
            )
    }
}

private extension JSONEncoder {
    static var portavozBackupRecovery: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var portavozBackupRecovery: JSONDecoder {
        JSONDecoder()
    }
}
