import Foundation

public enum CommitmentRadarOwnerFilter: Sendable, Equatable {
    case all
    case mine
    case others
    case unassigned
    case person(PersonID)
}

public enum CommitmentRadarDueFilter: Sendable, Equatable {
    case all
    case dueSoon
    case overdue
    case noDate
}

public enum CommitmentRadarActivity: String, Sendable, Equatable, CaseIterable {
    case new
    case unchanged
    case completed
    case reopened
}

public enum CommitmentRadarActivityFilter: Sendable, Equatable {
    case all
    case activity(CommitmentRadarActivity)
}

public enum CommitmentRadarQueryError: Error, Sendable, Equatable {
    case invalidDateWindow
    case invalidLimit
}

/// Fully bounded storage query. Application policy supplies the calendar
/// boundaries so persistence never guesses what "today" or "new" means.
public struct CommitmentRadarQuery: Sendable, Equatable {
    public static let maximumItemCount = 200
    public static let maximumRelatedRowCount = 20

    public let owner: CommitmentRadarOwnerFilter
    public let commitmentID: CommitmentID?
    public let due: CommitmentRadarDueFilter
    public let activity: CommitmentRadarActivityFilter
    public let dayStart: Date
    public let dueSoonEnd: Date
    public let newSince: Date
    public let itemLimit: Int
    public let sourceLimitPerItem: Int
    public let historyLimitPerItem: Int

    public init(
        owner: CommitmentRadarOwnerFilter = .all,
        commitmentID: CommitmentID? = nil,
        due: CommitmentRadarDueFilter = .all,
        activity: CommitmentRadarActivityFilter = .all,
        dayStart: Date,
        dueSoonEnd: Date,
        newSince: Date,
        itemLimit: Int = 100,
        sourceLimitPerItem: Int = 3,
        historyLimitPerItem: Int = 8
    ) throws {
        guard dayStart.timeIntervalSinceReferenceDate.isFinite,
              dueSoonEnd.timeIntervalSinceReferenceDate.isFinite,
              newSince.timeIntervalSinceReferenceDate.isFinite,
              dueSoonEnd > dayStart,
              newSince <= dayStart
        else { throw CommitmentRadarQueryError.invalidDateWindow }
        guard (1...Self.maximumItemCount).contains(itemLimit),
              (1...Self.maximumRelatedRowCount).contains(sourceLimitPerItem),
              (1...Self.maximumRelatedRowCount).contains(historyLimitPerItem)
        else { throw CommitmentRadarQueryError.invalidLimit }

        self.owner = owner
        self.commitmentID = commitmentID
        self.due = due
        self.activity = activity
        self.dayStart = dayStart
        self.dueSoonEnd = dueSoonEnd
        self.newSince = newSince
        self.itemLimit = itemLimit
        self.sourceLimitPerItem = sourceLimitPerItem
        self.historyLimitPerItem = historyLimitPerItem
    }
}

public struct CommitmentRadarSource: Sendable, Equatable, Identifiable {
    public let id: CommitmentSourceID
    public let kind: CommitmentSourceKind
    public let meetingID: MeetingID?
    public let meetingTitle: String?
    public let actionItemID: UUID?
    public let contextItemID: UUID?
    public let transcriptRevision: Int?
    public let firstSeenAt: Date
    public let evidenceCount: Int
    public let isMeetingAvailable: Bool

    public init(
        id: CommitmentSourceID,
        kind: CommitmentSourceKind,
        meetingID: MeetingID?,
        meetingTitle: String?,
        actionItemID: UUID?,
        contextItemID: UUID?,
        transcriptRevision: Int?,
        firstSeenAt: Date,
        evidenceCount: Int,
        isMeetingAvailable: Bool
    ) {
        self.id = id
        self.kind = kind
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.actionItemID = actionItemID
        self.contextItemID = contextItemID
        self.transcriptRevision = transcriptRevision
        self.firstSeenAt = firstSeenAt
        self.evidenceCount = evidenceCount
        self.isMeetingAvailable = isMeetingAvailable
    }
}

public struct CommitmentRadarHistoryEvent: Sendable, Equatable, Identifiable {
    public let id: CommitmentEventID
    public let kind: CommitmentEventKind
    public let assignee: CommitmentAssignee?
    public let assigneeDisplayName: String?
    public let dueAt: Date?
    public let sourceMeetingID: MeetingID?
    public let sourceMeetingTitle: String?
    public let isSourceMeetingAvailable: Bool
    public let occurredAt: Date

    public init(
        id: CommitmentEventID,
        kind: CommitmentEventKind,
        assignee: CommitmentAssignee?,
        assigneeDisplayName: String?,
        dueAt: Date?,
        sourceMeetingID: MeetingID?,
        sourceMeetingTitle: String?,
        isSourceMeetingAvailable: Bool,
        occurredAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.assignee = assignee
        self.assigneeDisplayName = assigneeDisplayName
        self.dueAt = dueAt
        self.sourceMeetingID = sourceMeetingID
        self.sourceMeetingTitle = sourceMeetingTitle
        self.isSourceMeetingAvailable = isSourceMeetingAvailable
        self.occurredAt = occurredAt
    }
}

public struct CommitmentRadarItem: Sendable, Equatable, Identifiable {
    public var id: CommitmentID { commitment.id }

    public let commitment: Commitment
    public let assigneeDisplayName: String?
    public let activity: CommitmentRadarActivity
    public let sources: [CommitmentRadarSource]
    public let sourceCount: Int
    public let history: [CommitmentRadarHistoryEvent]
    public let historyCount: Int

    public var hasMoreSources: Bool { sourceCount > sources.count }
    public var hasMoreHistory: Bool { historyCount > history.count }

    public init(
        commitment: Commitment,
        assigneeDisplayName: String?,
        activity: CommitmentRadarActivity,
        sources: [CommitmentRadarSource],
        sourceCount: Int,
        history: [CommitmentRadarHistoryEvent],
        historyCount: Int
    ) {
        self.commitment = commitment
        self.assigneeDisplayName = assigneeDisplayName
        self.activity = activity
        self.sources = sources
        self.sourceCount = sourceCount
        self.history = history
        self.historyCount = historyCount
    }
}

public struct CommitmentRadarPage: Sendable, Equatable {
    public let items: [CommitmentRadarItem]
    public let totalCount: Int

    public var hasMore: Bool { totalCount > items.count }

    public init(items: [CommitmentRadarItem], totalCount: Int) {
        self.items = items
        self.totalCount = totalCount
    }
}
