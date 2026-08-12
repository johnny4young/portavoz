import Foundation
import PortavozCore
import StorageKit

/// One read-consistent meeting snapshot for terminal, protocol, and future
/// non-SwiftUI interfaces. Storage metadata never crosses this value boundary.
public struct MeetingLibraryDetail: Sendable {
    public let meeting: Meeting
    public let speakers: [Speaker]
    public let segments: [TranscriptSegment]
    public let corrections: [TranscriptCorrectionEvent]
    public let correctionRevision: TranscriptCorrectionRevision
    public let isRefinedTranscript: Bool
    public let summary: SummaryDraft?
    public let summaryVersion: Int?
    public let summaryCorrectionSource: TranscriptCorrectionArtifactSource

    public init(
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment],
        corrections: [TranscriptCorrectionEvent] = [],
        correctionRevision: TranscriptCorrectionRevision? = nil,
        isRefinedTranscript: Bool = false,
        summary: SummaryDraft?,
        summaryVersion: Int?,
        summaryCorrectionSource: TranscriptCorrectionArtifactSource = .legacyAccepted
    ) {
        self.meeting = meeting
        self.speakers = speakers
        self.segments = segments
        self.corrections = corrections
        self.correctionRevision = correctionRevision ?? Self.derivedCorrectionRevision(
            meeting: meeting,
            corrections: corrections)
        self.isRefinedTranscript = isRefinedTranscript
        self.summary = summary
        self.summaryVersion = summaryVersion
        self.summaryCorrectionSource = summaryCorrectionSource
    }

    private static func derivedCorrectionRevision(
        meeting: Meeting,
        corrections: [TranscriptCorrectionEvent]
    ) -> TranscriptCorrectionRevision {
        guard !corrections.isEmpty else { return .accepted }
        return (try? TranscriptCorrectionRevision.current(
            meetingID: meeting.id,
            baseTranscriptRevision: meeting.transcriptRevision,
            history: corrections)) ?? .unavailable
    }
}

/// Minimum read capability needed by command-line and local protocol clients.
/// Implementations return domain/application values rather than GRDB records.
public protocol MeetingLibraryQueryReading: Sendable {
    func meetingLibraryMeetings(limit: Int?) async throws -> [Meeting]
    func meetingLibraryDetail(_ id: MeetingID) async throws -> MeetingLibraryDetail?
    func meetingLibrarySearch(
        _ query: String,
        limit: Int
    ) async throws -> [LibrarySearchHit]
    func meetingLibraryOpenItems(limit: Int) async throws -> [LibraryOpenItem]
}

public enum MeetingLibraryQueryRequest: Sendable {
    case meetings(limit: Int?)
    case detail(MeetingID)
    case search(query: String, limit: Int)
    case openItems(limit: Int)
}

public enum MeetingLibraryQueryResponse: Sendable {
    case meetings([Meeting])
    case detail(MeetingLibraryDetail?)
    case search([LibrarySearchHit])
    case openItems([LibraryOpenItem])
}

/// Shared application boundary for non-visual library reads. It owns input
/// normalization and bounded result policy while callers retain presentation.
public struct QueryMeetingLibrary: ApplicationUseCase {
    private let reader: any MeetingLibraryQueryReading

    public init(reader: any MeetingLibraryQueryReading) {
        self.reader = reader
    }

    public static func local(store: MeetingStore) -> Self {
        Self(reader: LocalMeetingLibraryQueryReader(store: store))
    }

    public func execute(
        _ request: MeetingLibraryQueryRequest
    ) async throws -> MeetingLibraryQueryResponse {
        switch request {
        case .meetings(let limit):
            return .meetings(try await meetings(limit: limit))
        case .detail(let id):
            return .detail(try await detail(id))
        case .search(let query, let limit):
            return .search(try await search(query, limit: limit))
        case .openItems(let limit):
            return .openItems(try await openItems(limit: limit))
        }
    }

    public func meetings(limit: Int? = nil) async throws -> [Meeting] {
        if let limit, limit <= 0 { return [] }
        return try await reader.meetingLibraryMeetings(limit: limit)
    }

    public func detail(_ id: MeetingID) async throws -> MeetingLibraryDetail? {
        try await reader.meetingLibraryDetail(id)
    }

    public func search(
        _ query: String,
        limit: Int = 20
    ) async throws -> [LibrarySearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        return try await reader.meetingLibrarySearch(query, limit: limit)
    }

    public func openItems(limit: Int = 50) async throws -> [LibraryOpenItem] {
        guard limit > 0 else { return [] }
        return try await reader.meetingLibraryOpenItems(limit: limit)
    }
}

private struct LocalMeetingLibraryQueryReader: MeetingLibraryQueryReading {
    let store: MeetingStore

    func meetingLibraryMeetings(limit: Int?) async throws -> [Meeting] {
        if let limit { return try await store.meetings(limit: limit) }
        return try await store.meetings()
    }

    func meetingLibraryDetail(
        _ id: MeetingID
    ) async throws -> MeetingLibraryDetail? {
        guard let snapshot = try await store.meetingLibrarySnapshot(id) else {
            return nil
        }
        return MeetingLibraryDetail(
            meeting: snapshot.detail.meeting,
            speakers: snapshot.detail.speakers,
            segments: snapshot.detail.segments,
            corrections: snapshot.corrections,
            correctionRevision: snapshot.correctionRevision,
            isRefinedTranscript: snapshot.isRefinedTranscript,
            summary: snapshot.summary?.draft,
            summaryVersion: snapshot.summary?.version,
            summaryCorrectionSource: snapshot.summary?.correctionSource ?? .legacyAccepted)
    }

    func meetingLibrarySearch(
        _ query: String,
        limit: Int
    ) async throws -> [LibrarySearchHit] {
        try await store.search(query, limit: limit).map { hit in
            LibrarySearchHit(
                meetingID: hit.meetingID,
                meetingTitle: hit.meetingTitle,
                segmentID: hit.segmentID,
                sourceSegmentIDs: hit.sourceSegmentIDs,
                snippet: hit.snippet,
                startTime: hit.startTime)
        }
    }

    func meetingLibraryOpenItems(limit: Int) async throws -> [LibraryOpenItem] {
        try await store.openActionItems(limit: limit).map { item in
            LibraryOpenItem(
                meetingID: item.meetingID,
                meetingTitle: item.meetingTitle,
                item: item.item)
        }
    }
}
