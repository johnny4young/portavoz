import Foundation
import PortavozCore
import StorageKit

/// One storage-independent meeting document used by the whole-library backup.
public struct LibraryMarkdownBackupContent: Sendable {
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

/// A corrupt live aggregate is reported without exposing a storage error or
/// preventing healthy meetings from being backed up.
public struct LibraryMarkdownBackupSourceFailure: Equatable, Sendable {
    public let meetingID: MeetingID?
    public let title: String

    public init(meetingID: MeetingID?, title: String) {
        self.meetingID = meetingID
        self.title = title
    }
}

public enum LibraryMarkdownBackupSourceEntry: Sendable {
    case content(LibraryMarkdownBackupContent)
    case failure(LibraryMarkdownBackupSourceFailure)
}

public protocol LibraryMarkdownBackupSourceSession: Sendable {
    var id: UUID { get }
    var totalMeetings: Int { get }
    func next() async throws -> LibraryMarkdownBackupSourceEntry?
    func checkpoint() async throws -> LibraryMarkdownBackupSourceCursor?
    func close() async
    /// Releases process ownership without deleting the immutable source.
    /// Launch recovery uses this when setup cannot safely continue so a later
    /// process can retry the exact same stage.
    func abandon() async
}

public extension LibraryMarkdownBackupSourceSession {
    func abandon() async {}
}

public enum LibraryMarkdownBackupSourcePreparation: Sendable {
    case ready(any LibraryMarkdownBackupSourceSession)
    case suspended
}

/// Creates one read-consistent, incrementally consumed projection of the live
/// library. Storage corruption remains isolated per aggregate.
public protocol LibraryMarkdownBackupStore: Sendable {
    func prepareLibraryMarkdownBackupSource(
        mayContinue: @escaping @Sendable () -> Bool
    ) async throws -> LibraryMarkdownBackupSourcePreparation
}

public enum LibraryMarkdownBackupSourceAdoption: Sendable {
    case ready(any LibraryMarkdownBackupSourceSession)
    case unavailable
}

/// Relaunch-only source ownership. Cleanup receives the complete durable
/// journal catalog and must not remove a matching immutable stage.
public protocol LibraryMarkdownBackupRecoverySourceStore: Sendable {
    func adoptLibraryMarkdownBackupSource(
        id: UUID,
        cursor: LibraryMarkdownBackupSourceCursor?
    ) async throws -> LibraryMarkdownBackupSourceAdoption

    func cleanupAbandonedLibraryMarkdownBackupSources(
        preserving operationIDs: Set<UUID>
    ) async -> Set<UUID>
}

extension MeetingStore: LibraryMarkdownBackupStore {
    public func prepareLibraryMarkdownBackupSource(
        mayContinue: @escaping @Sendable () -> Bool
    ) async throws -> LibraryMarkdownBackupSourcePreparation {
        switch try await prepareLibraryMarkdownBackupStage(
            mayContinue: mayContinue
        ) {
        case .ready(let stage):
            return .ready(MeetingStoreLibraryMarkdownBackupSource(stage: stage))
        case .suspended:
            return .suspended
        }
    }
}

extension MeetingStore: LibraryMarkdownBackupRecoverySourceStore {
    public func adoptLibraryMarkdownBackupSource(
        id: UUID,
        cursor: LibraryMarkdownBackupSourceCursor?
    ) async throws -> LibraryMarkdownBackupSourceAdoption {
        let stageCursor = cursor.map {
            MeetingMarkdownBackupStageCursor(
                startedAt: $0.startedAt,
                recordID: $0.recordID)
        }
        switch try await adoptLibraryMarkdownBackupStage(
            id: id,
            cursor: stageCursor
        ) {
        case .ready(let stage):
            return .ready(MeetingStoreLibraryMarkdownBackupSource(
                stage: stage,
                preservesStageOnAbandon: true))
        case .unavailable:
            return .unavailable
        }
    }

    public func cleanupAbandonedLibraryMarkdownBackupSources(
        preserving operationIDs: Set<UUID>
    ) async -> Set<UUID> {
        await cleanupAbandonedLibraryMarkdownBackupStages(
            preserving: operationIDs)
    }
}

private actor MeetingStoreLibraryMarkdownBackupSource:
    LibraryMarkdownBackupSourceSession {
    nonisolated let id: UUID
    nonisolated let totalMeetings: Int
    private let stage: MeetingMarkdownBackupStage
    private let preservesStageOnAbandon: Bool

    init(
        stage: MeetingMarkdownBackupStage,
        preservesStageOnAbandon: Bool = false
    ) {
        self.stage = stage
        self.preservesStageOnAbandon = preservesStageOnAbandon
        id = stage.id
        totalMeetings = stage.totalMeetings
    }

    func next() async throws -> LibraryMarkdownBackupSourceEntry? {
        guard let entry = try await stage.next() else { return nil }
        switch entry {
        case .meeting(let snapshot):
            return .content(LibraryMarkdownBackupContent(
                meeting: snapshot.meeting,
                speakers: snapshot.speakers,
                segments: snapshot.segments,
                summary: snapshot.summary,
                summaryVersion: snapshot.summaryVersion))
        case .failure(let failure):
            return .failure(LibraryMarkdownBackupSourceFailure(
                meetingID: failure.meetingID,
                title: failure.title))
        }
    }

    func checkpoint() async throws -> LibraryMarkdownBackupSourceCursor? {
        guard let cursor = try await stage.checkpoint() else { return nil }
        return LibraryMarkdownBackupSourceCursor(
            startedAt: cursor.startedAt,
            recordID: cursor.recordID)
    }

    func close() async {
        await stage.close()
    }

    func abandon() async {
        if preservesStageOnAbandon {
            await stage.abandon()
        } else {
            await stage.close()
        }
    }
}
