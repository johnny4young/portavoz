import Foundation

/// Why an inert Skill offer became eligible. Reasons are product policy, not
/// generated prose, so Settings can explain them without retaining content.
public enum SkillOfferReason: String, Codable, Sendable, CaseIterable {
    case meetingSummaryReady = "meeting-summary-ready"
    case upcomingCalendarEvent = "upcoming-calendar-event"
    case confirmedCommitment = "confirmed-commitment"
}

/// Content-free declaration written when a real subject surface makes an
/// offer. This is not the exact execution proposal: preview material and its
/// UUID are still allocated only after the user opens confirmation.
public struct SkillOfferRegistration: Equatable, Sendable, Identifiable {
    /// Covers the longest current identity: a bounded 2,000-byte EventKit
    /// identifier plus the Skill prefix and separator.
    public static let maximumOfferKeyByteCount = 2_200

    public let offerKey: String
    public let definition: SkillDefinition
    public let requestedInputDataClasses: Set<SkillInputDataClass>
    public let subject: SkillOfferSubject
    public let reason: SkillOfferReason
    public let proposedAt: Date
    public let expiresAt: Date?

    public var id: String { offerKey }

    public init(
        offerKey: String,
        definition: SkillDefinition,
        requestedInputDataClasses: Set<SkillInputDataClass>,
        subject: SkillOfferSubject,
        reason: SkillOfferReason,
        proposedAt: Date,
        expiresAt: Date? = nil
    ) {
        self.offerKey = offerKey
        self.definition = definition
        self.requestedInputDataClasses = requestedInputDataClasses
        self.subject = subject
        self.reason = reason
        self.proposedAt = proposedAt
        self.expiresAt = expiresAt
    }

    public var isValid: Bool {
        guard !offerKey.isEmpty,
              offerKey.utf8.count <= Self.maximumOfferKeyByteCount,
              definition.isValid,
              !requestedInputDataClasses.isEmpty,
              requestedInputDataClasses.isSubset(of: definition.inputDataClasses),
              subject.isValid,
              proposedAt.timeIntervalSinceReferenceDate.isFinite,
              expiresAt?.timeIntervalSinceReferenceDate.isFinite ?? true
        else { return false }

        return switch (reason, subject) {
        case (.meetingSummaryReady, .meeting):
            requestedInputDataClasses.contains(.meetingSummary)
        case (.upcomingCalendarEvent, .calendarEvent):
            requestedInputDataClasses.contains(.calendarEvent)
        case (.confirmedCommitment, .commitment):
            requestedInputDataClasses.contains(.commitment)
        default:
            false
        }
    }
}

/// Privacy-preserving row returned to a central review UI. Subject and offer
/// identities stay behind StorageKit; only an unrelated UUID reaches SwiftUI.
public struct SkillOfferReviewRecord: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let skillID: String
    public let skillVersion: Int
    public let reason: SkillOfferReason
    public let inputDataClasses: Set<SkillInputDataClass>
    public let proposedAt: Date
    public let lastObservedAt: Date

    public init(
        id: UUID,
        skillID: String,
        skillVersion: Int,
        reason: SkillOfferReason,
        inputDataClasses: Set<SkillInputDataClass>,
        proposedAt: Date,
        lastObservedAt: Date
    ) {
        self.id = id
        self.skillID = skillID
        self.skillVersion = skillVersion
        self.reason = reason
        self.inputDataClasses = inputDataClasses
        self.proposedAt = proposedAt
        self.lastObservedAt = lastObservedAt
    }
}

/// Content-free authority returned only after someone explicitly asks to
/// review one opaque central row in its original context. Unlike the bounded
/// list projection, this transient record may carry the subject identity
/// required for navigation. It still contains no title, preview, arguments,
/// destination, recipient, or execution authority.
public struct SkillOfferReviewSubjectRecord: Equatable, Sendable {
    public let skillID: String
    public let skillVersion: Int
    public let reason: SkillOfferReason
    public let subject: SkillOfferSubject

    public init(
        skillID: String,
        skillVersion: Int,
        reason: SkillOfferReason,
        subject: SkillOfferSubject
    ) {
        self.skillID = skillID
        self.skillVersion = skillVersion
        self.reason = reason
        self.subject = subject
    }

    public var isValid: Bool {
        guard !skillID.isEmpty,
              skillID == skillID.trimmingCharacters(
                  in: .whitespacesAndNewlines),
              skillID.utf8.count <= SkillDefinition.maximumIDByteCount,
              skillVersion >= 1,
              subject.isValid
        else { return false }

        return switch (reason, subject) {
        case (.meetingSummaryReady, .meeting),
             (.upcomingCalendarEvent, .calendarEvent),
             (.confirmedCommitment, .commitment):
            true
        default:
            false
        }
    }
}

/// Missing, expired, disabled, dismissed, and concurrently retired rows share
/// one unavailable result so the resolver does not disclose why authority is
/// gone.
public enum SkillOfferReviewSubjectOutcome: Equatable, Sendable {
    case active(SkillOfferReviewSubjectRecord)
    case unavailable
}

/// Result of acting on one opaque central-review identity. `unavailable`
/// deliberately reveals neither whether the subject expired nor whether
/// another owner retired it first.
public enum SkillOfferReviewDismissalOutcome: Equatable, Sendable {
    case dismissed
    case unavailable
}
