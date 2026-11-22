import Foundation
import PortavozCore

/// Query-specific row for the Library's recency-grouped meeting shelf.
public struct LibraryMeetingRow: Sendable, Identifiable {
    public let meeting: Meeting
    /// Drawn with the meeting's own cast; the sidebar spans several days.
    public let voiceStrip: VoiceStripColumns
    /// The same strip for a page cast to recolour.
    public let voiceSource: VoiceStripSource?
    public var id: MeetingID { meeting.id }

    public init(meeting: Meeting, voiceStrip: VoiceStripColumns, voiceSource: VoiceStripSource? = nil) {
        self.meeting = meeting
        self.voiceStrip = voiceStrip
        self.voiceSource = voiceSource
    }
}

/// One open commitment and the meeting that provides its navigation target.
public struct LibraryOpenItem: Sendable, Identifiable {
    public let meetingID: MeetingID
    public let meetingTitle: String
    public let item: ActionItem
    public var id: UUID { item.id }

    public init(meetingID: MeetingID, meetingTitle: String, item: ActionItem) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.item = item
    }
}

/// One tombstoned meeting exposed by the Library's Recently Deleted section.
public struct LibraryTrashItem: Sendable, Identifiable {
    public let meeting: Meeting
    public let deletedAt: Date
    public var id: MeetingID { meeting.id }

    public init(meeting: Meeting, deletedAt: Date) {
        self.meeting = meeting
        self.deletedAt = deletedAt
    }
}

/// A full-text hit shaped specifically for the Library search result list.
public struct LibrarySearchHit: Sendable, Identifiable {
    public let meetingID: MeetingID
    public let meetingTitle: String
    /// Stable visible retrieval-unit identity (accepted segment, split part,
    /// or merge correction).
    public let segmentID: UUID
    public let sourceSegmentIDs: [UUID]
    public let snippet: String
    public let startTime: TimeInterval
    public var id: UUID { segmentID }

    public init(
        meetingID: MeetingID,
        meetingTitle: String,
        segmentID: UUID,
        sourceSegmentIDs: [UUID]? = nil,
        snippet: String,
        startTime: TimeInterval
    ) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.segmentID = segmentID
        self.sourceSegmentIDs = sourceSegmentIDs ?? [segmentID]
        self.snippet = snippet
        self.startTime = startTime
    }
}

/// Independently observed Library query families. A failure in one family
/// must not stop healthy sections from continuing to update.
public enum LibrarySection: CaseIterable, Hashable, Sendable {
    case meetings
    case openItems
    case trash
}

/// Query-scoped changes consumed by the per-window Library feature model.
public enum LibraryUpdate: Sendable {
    case meetings([LibraryMeetingRow], failures: Int)
    case openItems([LibraryOpenItem])
    case trash([LibraryTrashItem])
    case failed(LibrarySection)
}
