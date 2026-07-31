import Darwin
import Foundation
import GRDB
import PortavozCore

public struct MeetingMarkdownBackupSnapshot: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let summary: SummaryDraft?
    public let summaryVersion: Int?

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        summary: SummaryDraft?,
        summaryVersion: Int?
    ) {
        self.meeting = meeting
        self.speakers = speakers
        self.segments = segments
        self.summary = summary
        self.summaryVersion = summaryVersion
    }
}

public struct MeetingMarkdownBackupReadFailure: Equatable, Sendable {
    public let meetingID: MeetingID?
    public let title: String

    public init(meetingID: MeetingID?, title: String) {
        self.meetingID = meetingID
        self.title = title
    }
}

public enum MeetingMarkdownBackupStageEntry: Sendable {
    case meeting(MeetingMarkdownBackupSnapshot)
    case failure(MeetingMarkdownBackupReadFailure)
}

public enum MeetingMarkdownBackupStagePreparation: Sendable {
    case ready(MeetingMarkdownBackupStage)
    case suspended
}

/// Content-free keyset position inside one immutable backup stage.
///
/// The ordering pair is persisted by the application recovery boundary in a
/// later slice; StorageKit validates it against the exact staged row before
/// allowing adoption.
public struct MeetingMarkdownBackupStageCursor:
    Codable,
    Equatable,
    Sendable {
    public let startedAt: Date
    public let recordID: String

    public init(
        startedAt: Date,
        recordID: String
    ) {
        self.startedAt = startedAt
        self.recordID = recordID
    }
}

public enum MeetingMarkdownBackupStageAdoption: Sendable {
    case ready(MeetingMarkdownBackupStage)
    case unavailable
}

/// A coherent, disk-backed source consumed one aggregate at a time.
///
/// The stage never reads the live database after preparation. Closing it
/// removes every transient SQLite file from its private workspace.
public actor MeetingMarkdownBackupStage {
    nonisolated public let id: UUID
    nonisolated public let totalMeetings: Int

    let workspaceURL: URL
    private let database: DatabaseQueue
    private var workspaceLease: MeetingMarkdownBackupWorkspaceLease?
    private var cursor: MeetingMarkdownBackupStageCursor?
    private var isClosed = false

    fileprivate init(
        id: UUID,
        database: DatabaseQueue,
        workspaceURL: URL,
        workspaceLease: MeetingMarkdownBackupWorkspaceLease,
        totalMeetings: Int,
        cursor: MeetingMarkdownBackupStageCursor? = nil
    ) {
        self.id = id
        self.database = database
        self.workspaceURL = workspaceURL
        self.workspaceLease = workspaceLease
        self.totalMeetings = totalMeetings
        self.cursor = cursor
    }

    deinit {
        try? database.close()
        try? FileManager.default.removeItem(at: workspaceURL)
    }

    public func next() async throws -> MeetingMarkdownBackupStageEntry? {
        guard !isClosed else {
            throw MeetingMarkdownBackupStageError.closed
        }
        let currentCursor = cursor
        let result:
            (MeetingMarkdownBackupStageCursor, MeetingMarkdownBackupStageEntry)? =
            try await database.read { database in
                var request = MeetingRecord
                    .filter(Column("deletedAt") == nil)
                    .order(Column("startedAt").desc, Column("id").asc)
                if let currentCursor {
                    request = request.filter(
                        Column("startedAt") < currentCursor.startedAt
                            || (
                                Column("startedAt") == currentCursor.startedAt
                                    && Column("id") > currentCursor.recordID
                            ))
                }
                guard let record = try request.fetchOne(database)
                else { return nil }
                let nextCursor = MeetingMarkdownBackupStageCursor(
                    startedAt: record.startedAt,
                    recordID: record.id)
                do {
                    return (
                        nextCursor,
                        .meeting(try MeetingStore.markdownBackupSnapshot(
                            record: record,
                            in: database))
                    )
                } catch {
                    return (
                        nextCursor,
                        .failure(MeetingMarkdownBackupReadFailure(
                            meetingID: UUID(uuidString: record.id).map {
                                MeetingID(rawValue: $0)
                            },
                            title: record.title))
                    )
                }
            }
        guard let result else { return nil }
        cursor = result.0
        return result.1
    }

    public func checkpoint() throws -> MeetingMarkdownBackupStageCursor? {
        guard !isClosed else {
            throw MeetingMarkdownBackupStageError.closed
        }
        return cursor
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        try? database.close()
        try? FileManager.default.removeItem(at: workspaceURL)
        workspaceLease = nil
    }
}

extension MeetingStore {
    /// Copies one coherent SQLite moment into a private transient stage.
    /// Copying yields between bounded page groups; a closed checkpoint aborts
    /// and removes the partial stage before returning.
    public func prepareLibraryMarkdownBackupStage(
        mayContinue: @escaping @Sendable () -> Bool
    ) async throws -> MeetingMarkdownBackupStagePreparation {
        try await prepareLibraryMarkdownBackupStage(
            in: Self.defaultLibraryMarkdownBackupStagingRoot,
            pagesPerStep: 256,
            mayContinue: mayContinue)
    }

    /// Removes only stages whose kernel-owned lease proves that no live
    /// Portavoz process still owns them. Legacy or malformed workspaces are
    /// preserved rather than guessed stale.
    public func cleanupAbandonedLibraryMarkdownBackupStages() async -> Set<UUID> {
        let stagingRoot = Self.defaultLibraryMarkdownBackupStagingRoot
        return await Task.detached(priority: .utility) {
            (try? Self.cleanupAbandonedLibraryMarkdownBackupStages(
                in: stagingRoot)) ?? []
        }.value
    }

    /// Reopens one exact immutable stage after its previous process released
    /// the kernel lease. Active, missing, malformed, or cursor-mismatched work
    /// is never guessed safe.
    public func adoptLibraryMarkdownBackupStage(
        id: UUID,
        cursor: MeetingMarkdownBackupStageCursor?
    ) async throws -> MeetingMarkdownBackupStageAdoption {
        try await Self.adoptLibraryMarkdownBackupStage(
            id: id,
            cursor: cursor,
            in: Self.defaultLibraryMarkdownBackupStagingRoot)
    }

    static func cleanupAbandonedLibraryMarkdownBackupStages(
        in stagingRoot: URL
    ) throws -> Set<UUID> {
        let manager = FileManager.default
        guard manager.fileExists(atPath: stagingRoot.path) else { return [] }
        return try withLibraryMarkdownBackupRootLock(in: stagingRoot) {
            cleanupAbandonedLibraryMarkdownBackupStagesWithRootLock(
                in: stagingRoot)
        }
    }

    static func adoptLibraryMarkdownBackupStage(
        id: UUID,
        cursor: MeetingMarkdownBackupStageCursor?,
        in stagingRoot: URL
    ) async throws -> MeetingMarkdownBackupStageAdoption {
        guard try itemExistsWithoutFollowingSymbolicLinks(stagingRoot)
        else { return .unavailable }

        let workspace = try withLibraryMarkdownBackupRootLock(in: stagingRoot) {
            try adoptableLibraryMarkdownBackupWorkspace(
                id: id,
                in: stagingRoot)
        }
        guard let workspace else { return .unavailable }

        var configuration = Configuration()
        configuration.readonly = true
        let database: DatabaseQueue
        do {
            database = try DatabaseQueue(
                path: workspace.databaseURL.path,
                configuration: configuration)
        } catch {
            throw MeetingMarkdownBackupStageError.invalidWorkspace
        }

        do {
            let total = try await database.read { database in
                if let cursor {
                    guard cursor.startedAt.timeIntervalSince1970.isFinite,
                          !cursor.recordID.isEmpty,
                          try MeetingRecord
                            .filter(Column("deletedAt") == nil)
                            .filter(Column("startedAt") == cursor.startedAt)
                            .filter(Column("id") == cursor.recordID)
                            .fetchCount(database) == 1
                    else {
                        throw MeetingMarkdownBackupStageError.invalidCursor
                    }
                }
                return try MeetingRecord
                    .filter(Column("deletedAt") == nil)
                    .fetchCount(database)
            }
            return .ready(MeetingMarkdownBackupStage(
                id: id,
                database: database,
                workspaceURL: workspace.url,
                workspaceLease: workspace.lease,
                totalMeetings: total,
                cursor: cursor))
        } catch {
            try? database.close()
            throw error
        }
    }
}

extension MeetingStore {
    static var defaultLibraryMarkdownBackupStagingRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Portavoz", isDirectory: true)
            .appendingPathComponent("LibraryMarkdownBackup", isDirectory: true)
    }

    func prepareLibraryMarkdownBackupStage(
        in stagingRoot: URL,
        pagesPerStep: CInt,
        mayContinue: @escaping @Sendable () -> Bool
    ) async throws -> MeetingMarkdownBackupStagePreparation {
        guard mayContinue() else { return .suspended }
        let workspace = try Self.makeLibraryMarkdownBackupWorkspace(
            in: stagingRoot)
        let databaseURL = workspace.url.appendingPathComponent("source.sqlite")
        let stagedDatabase: DatabaseQueue
        do {
            stagedDatabase = try DatabaseQueue(path: databaseURL.path)
        } catch {
            try? FileManager.default.removeItem(at: workspace.url)
            throw error
        }

        do {
            let completed = try await Task.detached(priority: .utility) {
                do {
                    try self.database.backup(
                        to: stagedDatabase,
                        pagesPerStep: pagesPerStep
                    ) { progress in
                        guard progress.isCompleted || mayContinue() else {
                            throw MeetingMarkdownBackupStageError.suspended
                        }
                    }
                    return mayContinue()
                } catch MeetingMarkdownBackupStageError.suspended {
                    return false
                }
            }.value

            guard completed else {
                try? stagedDatabase.close()
                try? FileManager.default.removeItem(at: workspace.url)
                return .suspended
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path)
            let total = try await stagedDatabase.read { database in
                try MeetingRecord
                    .filter(Column("deletedAt") == nil)
                    .fetchCount(database)
            }
            return .ready(MeetingMarkdownBackupStage(
                id: workspace.id,
                database: stagedDatabase,
                workspaceURL: workspace.url,
                workspaceLease: workspace.lease,
                totalMeetings: total))
        } catch {
            try? stagedDatabase.close()
            try? FileManager.default.removeItem(at: workspace.url)
            throw error
        }
    }

    static func markdownBackupSnapshot(
        record: MeetingRecord,
        in database: Database
    ) throws -> MeetingMarkdownBackupSnapshot {
        let meeting = try record.meeting
        guard let core = try fetchMeetingReviewCore(meeting.id, in: database) else {
            throw MeetingMarkdownBackupSnapshotError.missingAggregate
        }
        let summary = try? generalSummarySnapshot(
            meetingID: meeting.id,
            in: database)
        return MeetingMarkdownBackupSnapshot(
            meeting: core.meeting,
            speakers: core.speakers,
            segments: core.segments,
            summary: summary?.draft,
            summaryVersion: summary?.version)
    }
}

private extension MeetingStore {
    static let libraryMarkdownBackupCoordinatorFileName =
        ".workspace-coordinator.lock"
    static let libraryMarkdownBackupOwnerFileName = ".owner.lock"

    static func makeLibraryMarkdownBackupWorkspace(
        in stagingRoot: URL
    ) throws -> MeetingMarkdownBackupWorkspace {
        try withLibraryMarkdownBackupRootLock(in: stagingRoot) {
            _ = cleanupAbandonedLibraryMarkdownBackupStagesWithRootLock(
                in: stagingRoot)
            return try createLibraryMarkdownBackupWorkspace(in: stagingRoot)
        }
    }

    static func createLibraryMarkdownBackupWorkspace(
        in stagingRoot: URL
    ) throws -> MeetingMarkdownBackupWorkspace {
        let manager = FileManager.default
        let id = UUID()
        let workspace = stagingRoot.appendingPathComponent(
            id.uuidString.lowercased(),
            isDirectory: true)
        try manager.createDirectory(
            at: workspace,
            withIntermediateDirectories: false)
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: workspace.path)
        do {
            let ownerURL = workspace.appendingPathComponent(
                libraryMarkdownBackupOwnerFileName)
            guard let lease = try MeetingMarkdownBackupWorkspaceLease.acquire(
                at: ownerURL,
                create: true,
                nonBlocking: false)
            else {
                throw MeetingMarkdownBackupStageError.workspaceUnavailable
            }
            return MeetingMarkdownBackupWorkspace(
                id: id,
                url: workspace,
                lease: lease)
        } catch {
            try? manager.removeItem(at: workspace)
            throw error
        }
    }

    static func adoptableLibraryMarkdownBackupWorkspace(
        id: UUID,
        in stagingRoot: URL
    ) throws -> MeetingMarkdownBackupWorkspace? {
        let workspace = stagingRoot.appendingPathComponent(
            id.uuidString.lowercased(),
            isDirectory: true)
        guard try itemExistsWithoutFollowingSymbolicLinks(workspace)
        else { return nil }
        try validateLibraryMarkdownBackupDirectory(workspace)

        let ownerURL = workspace.appendingPathComponent(
            libraryMarkdownBackupOwnerFileName)
        try validateLibraryMarkdownBackupRegularFile(ownerURL)
        guard let lease = try MeetingMarkdownBackupWorkspaceLease.acquire(
            at: ownerURL,
            create: false,
            nonBlocking: true)
        else { return nil }

        do {
            try validateLibraryMarkdownBackupRegularFile(
                workspace.appendingPathComponent("source.sqlite"))
            return MeetingMarkdownBackupWorkspace(
                id: id,
                url: workspace,
                lease: lease)
        } catch {
            withExtendedLifetime(lease) {}
            throw error
        }
    }

    static func cleanupAbandonedLibraryMarkdownBackupStagesWithRootLock(
        in stagingRoot: URL
    ) -> Set<UUID> {
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
        else { return [] }

        var removedIDs: Set<UUID> = []
        for workspace in children {
            guard workspace.lastPathComponent !=
                libraryMarkdownBackupCoordinatorFileName,
                let stageID = UUID(uuidString: workspace.lastPathComponent),
                stageID.uuidString.lowercased() == workspace.lastPathComponent,
                let values = try? workspace.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey
                ]),
                values.isDirectory == true,
                values.isSymbolicLink != true
            else { continue }

            let ownerURL = workspace.appendingPathComponent(
                libraryMarkdownBackupOwnerFileName)
            guard let ownerValues = try? ownerURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]),
                ownerValues.isRegularFile == true,
                ownerValues.isSymbolicLink != true,
                let lease = try? MeetingMarkdownBackupWorkspaceLease.acquire(
                    at: ownerURL,
                    create: false,
                    nonBlocking: true)
            else {
                // An active owner or an unknown legacy shape is not ours to
                // delete. Cleanup intentionally fails closed.
                continue
            }

            if (try? manager.removeItem(at: workspace)) != nil {
                removedIDs.insert(stageID)
            }
            withExtendedLifetime(lease) {}
        }
        return removedIDs
    }

    static func withLibraryMarkdownBackupRootLock<T>(
        in stagingRoot: URL,
        _ operation: () throws -> T
    ) throws -> T {
        let manager = FileManager.default
        if try itemExistsWithoutFollowingSymbolicLinks(stagingRoot) {
            try validateLibraryMarkdownBackupDirectory(stagingRoot)
        } else {
            try manager.createDirectory(
                at: stagingRoot,
                withIntermediateDirectories: true)
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stagingRoot.path)
        var root = stagingRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)

        let coordinatorURL = stagingRoot.appendingPathComponent(
            libraryMarkdownBackupCoordinatorFileName)
        guard let lease = try MeetingMarkdownBackupWorkspaceLease.acquire(
            at: coordinatorURL,
            create: true,
            nonBlocking: false)
        else {
            throw MeetingMarkdownBackupStageError.workspaceUnavailable
        }
        defer { withExtendedLifetime(lease) {} }
        return try operation()
    }

    static func itemExistsWithoutFollowingSymbolicLinks(
        _ url: URL
    ) throws -> Bool {
        var information = stat()
        if Darwin.lstat(url.path, &information) == 0 {
            return true
        }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return false
    }

    static func validateLibraryMarkdownBackupDirectory(
        _ url: URL
    ) throws {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true
        else {
            throw MeetingMarkdownBackupStageError.invalidWorkspace
        }
    }

    static func validateLibraryMarkdownBackupRegularFile(
        _ url: URL
    ) throws {
        guard try itemExistsWithoutFollowingSymbolicLinks(url) else {
            throw MeetingMarkdownBackupStageError.invalidWorkspace
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            throw MeetingMarkdownBackupStageError.invalidWorkspace
        }
    }

    /// Preserves the released backup's General-recipe selection instead of
    /// silently switching existing exports to a custom or Standup structure.
    static func generalSummarySnapshot(
        meetingID: MeetingID,
        in database: Database
    ) throws -> (draft: SummaryDraft, version: Int)? {
        guard let record = try SummaryRecord
            .filter(Column("meetingID") == meetingID.rawValue.uuidString)
            .filter(Column("recipeID") == Recipe.general.id)
            .filter(Column("deletedAt") == nil)
            .order(Column("version").desc)
            .fetchOne(database)
        else { return nil }
        return try summarySnapshot(record, meetingID: meetingID, in: database)
    }
}

private enum MeetingMarkdownBackupSnapshotError: Error {
    case missingAggregate
}

private enum MeetingMarkdownBackupStageError: Error {
    case closed
    case invalidCursor
    case invalidWorkspace
    case suspended
    case workspaceUnavailable
}

private struct MeetingMarkdownBackupWorkspace {
    let id: UUID
    let url: URL
    let lease: MeetingMarkdownBackupWorkspaceLease

    var databaseURL: URL {
        url.appendingPathComponent("source.sqlite")
    }
}

private final class MeetingMarkdownBackupWorkspaceLease:
    @unchecked Sendable {
    private let fileDescriptor: CInt

    private init(fileDescriptor: CInt) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = portavoBSDFileLock(fileDescriptor, LOCK_UN)
        _ = Darwin.close(fileDescriptor)
    }

    static func acquire(
        at url: URL,
        create: Bool,
        nonBlocking: Bool
    ) throws -> MeetingMarkdownBackupWorkspaceLease? {
        var flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW
        if create { flags |= O_CREAT }
        let descriptor = Darwin.open(
            url.path,
            flags,
            mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            if !create, errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        let operation = LOCK_EX | (nonBlocking ? LOCK_NB : 0)
        guard portavoBSDFileLock(descriptor, operation) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            if nonBlocking, code == EWOULDBLOCK || code == EAGAIN {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return MeetingMarkdownBackupWorkspaceLease(
            fileDescriptor: descriptor)
    }
}

/// The Darwin importer exposes `struct flock` under the same Swift name as
/// BSD `flock(2)`. Bind the C symbol explicitly so workspace ownership keeps
/// open-file-description semantics rather than process-scoped `fcntl` locks.
@_silgen_name("flock")
private func portavoBSDFileLock(
    _ fileDescriptor: CInt,
    _ operation: CInt
) -> CInt
