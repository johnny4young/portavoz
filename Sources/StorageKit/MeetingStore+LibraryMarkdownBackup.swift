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
    private var cursor: Cursor?
    private var isClosed = false

    init(
        database: DatabaseQueue,
        workspaceURL: URL,
        totalMeetings: Int
    ) {
        self.database = database
        self.workspaceURL = workspaceURL
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
        let databaseURL = workspace.appendingPathComponent("source.sqlite")
        let stagedDatabase: DatabaseQueue
        do {
            stagedDatabase = try DatabaseQueue(path: databaseURL.path)
        } catch {
            try? FileManager.default.removeItem(at: workspace)
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
                try? FileManager.default.removeItem(at: workspace)
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
                workspaceURL: workspace,
                totalMeetings: total))
        } catch {
            try? stagedDatabase.close()
            try? FileManager.default.removeItem(at: workspace)
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
    static func makeLibraryMarkdownBackupWorkspace(
        in stagingRoot: URL
    ) throws -> URL {
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

        let workspace = stagingRoot.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true)
        try manager.createDirectory(
            at: workspace,
            withIntermediateDirectories: false)
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: workspace.path)
        return workspace
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
}
