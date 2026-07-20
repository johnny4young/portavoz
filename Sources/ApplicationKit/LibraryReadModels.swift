import Foundation
import PortavozCore

/// One speaker's contribution to a meeting row's compact voice-mix bar.
public struct LibraryVoiceMixSlice: Equatable, Sendable {
    public let isMe: Bool
    public let displayName: String?
    public let fraction: Double
    public let order: Int

    public init(isMe: Bool, displayName: String?, fraction: Double, order: Int) {
        self.isMe = isMe
        self.displayName = displayName
        self.fraction = fraction
        self.order = order
    }
}

/// Query-specific row for the Library's recency-grouped meeting shelf.
public struct LibraryMeetingRow: Sendable, Identifiable {
    public let meeting: Meeting
    public let voiceMix: [LibraryVoiceMixSlice]
    public var id: MeetingID { meeting.id }

    public init(meeting: Meeting, voiceMix: [LibraryVoiceMixSlice]) {
        self.meeting = meeting
        self.voiceMix = voiceMix
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
    public let segmentID: UUID
    public let snippet: String
    public let startTime: TimeInterval
    public var id: UUID { segmentID }

    public init(
        meetingID: MeetingID,
        meetingTitle: String,
        segmentID: UUID,
        snippet: String,
        startTime: TimeInterval
    ) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.segmentID = segmentID
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
