import Foundation

/// The event class a standing rule may observe. The first release keeps this
/// closed to the already bounded pre-meeting calendar producer.
public enum StandingSkillRuleTrigger: String, Codable, CaseIterable, Sendable {
    case upcomingCalendarEvent = "upcoming-calendar-event"
}

/// A content-free subject selector. Meeting titles, attendees, transcripts,
/// and model output never become executable predicates.
public enum StandingSkillRuleSubjectPredicate:
    String, Codable, CaseIterable, Sendable {
    case anyUpcomingCalendarEvent = "any-upcoming-calendar-event"
}

/// The closed action vocabulary for unattended local work. A new case is an
/// authority expansion and must be admitted independently.
public enum StandingSkillRuleAction: String, Codable, CaseIterable, Sendable {
    case preparePreMeetingBrief = "prepare-pre-meeting-brief"
}

public enum StandingSkillRuleInsertionOutcome: Equatable, Sendable {
    case inserted
    case duplicate
    case capacityReached
}

/// One user-authored, device-local automation authority.
///
/// This value carries no meeting content, provider identity, destination, or
/// credentials. Execution receipts are separate so deleting the rule cannot
/// erase what it previously authorized.
public struct StandingSkillRule: Equatable, Identifiable, Sendable {
    public static let maximumRuleCount = 32
    public static let maximumDailyExecutionCount = 8

    public let id: StandingSkillRuleID
    public let skillID: String
    public let skillVersion: Int
    public let trigger: StandingSkillRuleTrigger
    public let subjectPredicate: StandingSkillRuleSubjectPredicate
    public let action: StandingSkillRuleAction
    public let maximumDailyExecutions: Int
    public let isEnabled: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: StandingSkillRuleID = StandingSkillRuleID(),
        skillID: String,
        skillVersion: Int,
        trigger: StandingSkillRuleTrigger,
        subjectPredicate: StandingSkillRuleSubjectPredicate,
        action: StandingSkillRuleAction,
        maximumDailyExecutions: Int,
        isEnabled: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.skillID = skillID
        self.skillVersion = skillVersion
        self.trigger = trigger
        self.subjectPredicate = subjectPredicate
        self.action = action
        self.maximumDailyExecutions = maximumDailyExecutions
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isValid: Bool {
        let trimmedSkillID = skillID.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmedSkillID.isEmpty,
              trimmedSkillID == skillID,
              skillID.utf8.count <= SkillDefinition.maximumIDByteCount,
              skillVersion >= 1,
              (1...Self.maximumDailyExecutionCount).contains(
                  maximumDailyExecutions),
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt >= createdAt
        else { return false }

        return switch (trigger, subjectPredicate, action) {
        case (
            .upcomingCalendarEvent,
            .anyUpcomingCalendarEvent,
            .preparePreMeetingBrief
        ):
            true
        }
    }
}
