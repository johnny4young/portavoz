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

/// A coherent, disk-backed source consumed one aggregate at a time.
///
/// The stage never reads the live database after preparation. Closing it
/// removes every transient SQLite file from its private workspace.
public actor MeetingMarkdownBackupStage {
    nonisolated public let totalMeetings: Int

    let workspaceURL: URL
    private let database: DatabaseQueue
    private var workspaceLease: MeetingMarkdownBackupWorkspaceLease?
    private var cursor: Cursor?
    private var isClosed = false

    fileprivate init(
        database: DatabaseQueue,
        workspaceURL: URL,
        workspaceLease: MeetingMarkdownBackupWorkspaceLease,
        totalMeetings: Int
    ) {
        self.database = database
        self.workspaceURL = workspaceURL
        self.workspaceLease = workspaceLease
        self.totalMeetings = totalMeetings
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
        let result: (Cursor, MeetingMarkdownBackupStageEntry)? =
            try await database.read { database in
                var request = MeetingRecord
                    .filter(Column("deletedAt") == nil)
                    .order(Column("startedAt").desc, Column("id").asc)
                if let currentCursor {
                    request = request.filter(
                        Column("startedAt") < currentCursor.startedAt
                            || (
                                Column("startedAt") == currentCursor.startedAt
                                    && Column("id") > currentCursor.id
                            ))
                }
                guard let record = try request.fetchOne(database)
                else { return nil }
                let nextCursor = Cursor(
                    startedAt: record.startedAt,
                    id: record.id)
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

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        try? database.close()
        try? FileManager.default.removeItem(at: workspaceURL)
        workspaceLease = nil
    }

    private struct Cursor: Sendable {
        let startedAt: Date
        let id: String
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
    public func cleanupAbandonedLibraryMarkdownBackupStages() async {
        let stagingRoot = Self.defaultLibraryMarkdownBackupStagingRoot
        _ = await Task.detached(priority: .utility) {
            try? Self.cleanupAbandonedLibraryMarkdownBackupStages(
                in: stagingRoot)
        }.value
    }

    static func cleanupAbandonedLibraryMarkdownBackupStages(
        in stagingRoot: URL
    ) throws -> Int {
        let manager = FileManager.default
        guard manager.fileExists(atPath: stagingRoot.path) else { return 0 }
        return try withLibraryMarkdownBackupRootLock(in: stagingRoot) {
            cleanupAbandonedLibraryMarkdownBackupStagesWithRootLock(
                in: stagingRoot)
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
        let workspace = stagingRoot.appendingPathComponent(
            UUID().uuidString.lowercased(),
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
                url: workspace,
                lease: lease)
        } catch {
            try? manager.removeItem(at: workspace)
            throw error
        }
    }

    static func cleanupAbandonedLibraryMarkdownBackupStagesWithRootLock(
        in stagingRoot: URL
    ) -> Int {
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
        else { return 0 }

        var removedCount = 0
        for workspace in children {
            guard workspace.lastPathComponent !=
                libraryMarkdownBackupCoordinatorFileName,
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
                removedCount += 1
            }
            withExtendedLifetime(lease) {}
        }
        return removedCount
    }

    static func withLibraryMarkdownBackupRootLock<T>(
        in stagingRoot: URL,
        _ operation: () throws -> T
    ) throws -> T {
        let manager = FileManager.default
        try manager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true)
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
    case suspended
    case workspaceUnavailable
}

private struct MeetingMarkdownBackupWorkspace {
    let url: URL
    let lease: MeetingMarkdownBackupWorkspaceLease
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
