import Foundation

/// One calendar occurrence covered by a standing rule. The provider identity
/// remains opaque; its start instant is part of the identity so a moved event
/// cannot inherit authority granted to an earlier occurrence.
public struct StandingSkillOccurrence: Equatable, Sendable {
    public static let fingerprintVersion = "standing-skill-occurrence-v2"

    public let eventID: String
    public let eventStartAt: Date
    public let fingerprint: String

    public init(eventID: String, eventStartAt: Date) {
        self.eventID = eventID
        self.eventStartAt = eventStartAt
        fingerprint = Self.makeFingerprint(
            eventID: eventID,
            eventStartAt: eventStartAt)
    }

    public var isValid: Bool {
        UpcomingEvent.isValidIdentity(eventID)
            && Self.canonicalStartMilliseconds(eventStartAt) != nil
            && fingerprint == Self.makeFingerprint(
                eventID: eventID,
                eventStartAt: eventStartAt)
    }

    /// EventKit and SQLite do not promise identical floating-point `Date`
    /// payloads. GRDB persists dates at millisecond precision, so durable
    /// occurrence identity uses that same canonical boundary.
    public static func canonicalStartMilliseconds(_ date: Date) -> Int64? {
        let seconds = date.timeIntervalSinceReferenceDate
        guard seconds.isFinite else { return nil }
        let milliseconds = (seconds * 1_000).rounded()
        guard milliseconds.isFinite else { return nil }
        return Int64(exactly: milliseconds)
    }

    public func matches(eventID: String, eventStartAt: Date) -> Bool {
        guard self.eventID == eventID,
              let storedStart = Self.canonicalStartMilliseconds(
                self.eventStartAt),
              let candidateStart = Self.canonicalStartMilliseconds(
                eventStartAt)
        else { return false }
        return storedStart == candidateStart
    }

    public static func makeFingerprint(
        eventID: String,
        eventStartAt: Date
    ) -> String {
        let canonicalStart = canonicalStartMilliseconds(eventStartAt)
            .map(String.init) ?? "invalid"
        return OperationFingerprint.make(
            version: fingerprintVersion,
            components: [
                eventID,
                canonicalStart
            ])
    }
}

public enum StandingSkillExecutionIdentity {
    public static func idempotencyKey(
        ruleID: StandingSkillRuleID,
        occurrence: StandingSkillOccurrence
    ) -> String {
        "standing-skill:\(ruleID.rawValue.uuidString.lowercased()):"
            + occurrence.fingerprint
    }
}

public enum StandingSkillExecutionPolicy {
    public static let maximumAutomaticAttempts = 3
    public static let maximumPendingExecutionCount = 32
}

/// An explicit local-day budget window resolved by ApplicationKit. StorageKit
/// receives absolute instants and therefore never owns locale, time-zone, or
/// daylight-saving policy.
public struct StandingSkillDailyWindow: Equatable, Sendable {
    public static let maximumDuration: TimeInterval = 30 * 60 * 60

    public let startInclusive: Date
    public let endExclusive: Date

    public init(startInclusive: Date, endExclusive: Date) {
        self.startInclusive = startInclusive
        self.endExclusive = endExclusive
    }

    public var isValid: Bool {
        guard startInclusive.timeIntervalSinceReferenceDate.isFinite,
              endExclusive.timeIntervalSinceReferenceDate.isFinite
        else { return false }
        let duration = endExclusive.timeIntervalSince(startInclusive)
        return duration > 0 && duration <= Self.maximumDuration
    }
}

/// The complete content-free request for one autonomous claim. Every field is
/// independently rechecked inside the SQLite transaction that consumes the
/// daily budget.
public struct StandingSkillExecutionClaim: Equatable, Sendable {
    public let proposalID: UUID
    public let ruleID: StandingSkillRuleID
    public let skillID: String
    public let skillVersion: Int
    public let trigger: StandingSkillRuleTrigger
    public let subjectPredicate: StandingSkillRuleSubjectPredicate
    public let action: StandingSkillRuleAction
    public let occurrence: StandingSkillOccurrence
    public let dailyWindow: StandingSkillDailyWindow
    public let oneShotOfferKey: String
    public let idempotencyKey: String
    public let occurredAt: Date

    public init(
        proposalID: UUID,
        ruleID: StandingSkillRuleID,
        skillID: String,
        skillVersion: Int,
        trigger: StandingSkillRuleTrigger,
        subjectPredicate: StandingSkillRuleSubjectPredicate,
        action: StandingSkillRuleAction,
        occurrence: StandingSkillOccurrence,
        dailyWindow: StandingSkillDailyWindow,
        oneShotOfferKey: String,
        idempotencyKey: String,
        occurredAt: Date
    ) {
        self.proposalID = proposalID
        self.ruleID = ruleID
        self.skillID = skillID
        self.skillVersion = skillVersion
        self.trigger = trigger
        self.subjectPredicate = subjectPredicate
        self.action = action
        self.occurrence = occurrence
        self.dailyWindow = dailyWindow
        self.oneShotOfferKey = oneShotOfferKey
        self.idempotencyKey = idempotencyKey
        self.occurredAt = occurredAt
    }

    public var isValid: Bool {
        let trimmedSkillID = skillID.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let trimmedKey = idempotencyKey.trimmingCharacters(
            in: .whitespacesAndNewlines)
        return !trimmedSkillID.isEmpty
            && trimmedSkillID == skillID
            && skillID.utf8.count <= SkillDefinition.maximumIDByteCount
            && skillVersion >= 1
            && occurrence.isValid
            && dailyWindow.isValid
            && !oneShotOfferKey.isEmpty
            && oneShotOfferKey == "\(skillID):\(occurrence.eventID)"
            && !trimmedKey.isEmpty
            && trimmedKey == idempotencyKey
            && idempotencyKey.utf8.count <= 256
            && idempotencyKey == StandingSkillExecutionIdentity.idempotencyKey(
                ruleID: ruleID,
                occurrence: occurrence)
            && occurredAt.timeIntervalSinceReferenceDate.isFinite
            && dailyWindow.startInclusive <= occurredAt
            && occurredAt < dailyWindow.endExclusive
    }
}

/// Opaque contentful artifact persisted by an application-owned standing
/// action. Storage verifies its digest and size without decoding a higher-
/// layer payload.
public struct StandingSkillArtifact: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case preMeetingBrief = "pre-meeting-brief"
    }

    public static let currentFormatVersion = 1
    public static let maximumPayloadByteCount = 128 * 1_024

    public let kind: Kind
    public let formatVersion: Int
    public let payload: Data
    public let sha256: String
    public let createdAt: Date

    public init(
        kind: Kind,
        formatVersion: Int = currentFormatVersion,
        payload: Data,
        createdAt: Date
    ) {
        self.kind = kind
        self.formatVersion = formatVersion
        self.payload = payload
        sha256 = ContentDigest.sha256(payload)
        self.createdAt = createdAt
    }

    public var isValid: Bool {
        formatVersion == Self.currentFormatVersion
            && !payload.isEmpty
            && payload.count <= Self.maximumPayloadByteCount
            && sha256.count == 64
            && sha256.allSatisfy(\.isHexDigit)
            && sha256 == ContentDigest.sha256(payload)
            && createdAt.timeIntervalSinceReferenceDate.isFinite
    }
}
