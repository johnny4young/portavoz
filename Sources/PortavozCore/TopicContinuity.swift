import Foundation

/// A stable topic identity. Labels are presentation metadata and never replace
/// the UUID identity.
public struct Topic: Codable, Equatable, Sendable, Identifiable {
    public let id: TopicID
    public let preferredLabel: String
    public let mergedIntoTopicID: TopicID?

    public init(
        id: TopicID = TopicID(),
        preferredLabel: String,
        mergedIntoTopicID: TopicID? = nil
    ) {
        self.id = id
        self.preferredLabel = preferredLabel
        self.mergedIntoTopicID = mergedIntoTopicID
    }
}

/// Provenance for a proposed topic link. Neither case grants mutation
/// authority; both must cross an explicit ApplicationKit confirmation command.
public enum TopicLinkProposalOrigin: String, Codable, CaseIterable, Sendable {
    case manual
    case generatedSimilarity = "generated-similarity"
}

/// Profile-local similarity evidence for one generated candidate. The value is
/// retained for explanation only: Core owns no threshold and scores from
/// different profiles are never comparable.
public struct TopicSimilarityCandidate: Codable, Equatable, Sendable {
    public let topicID: TopicID
    public let similarity: Double
    public let profileFingerprint: String

    public init(
        topicID: TopicID,
        similarity: Double,
        profileFingerprint: String
    ) {
        self.topicID = topicID
        self.similarity = similarity
        self.profileFingerprint = profileFingerprint
    }
}

/// A searchable presentation label owned by one observed topic. The same
/// normalized alias may belong to several topics so ambiguity remains
/// representable. Different-language labels can present one merged family
/// without becoming its identity.
public struct TopicAlias: Codable, Equatable, Sendable, Identifiable {
    public let id: TopicAliasID
    public let topicID: TopicID
    public let displayLabel: String
    public let normalizedAlias: String
    public let language: String?
    public let source: TopicLinkProposalOrigin

    public init(
        id: TopicAliasID = TopicAliasID(),
        topicID: TopicID,
        displayLabel: String,
        normalizedAlias: String,
        language: String?,
        source: TopicLinkProposalOrigin
    ) {
        self.id = id
        self.topicID = topicID
        self.displayLabel = displayLabel
        self.normalizedAlias = normalizedAlias
        self.language = language
        self.source = source
    }
}

/// An inert suggestion tied to exact transcript evidence. Stable identities
/// make a user-confirmed retry idempotent. Generated similarity must carry one
/// exact candidate; manual proposals carry none.
public struct TopicLinkProposal: Equatable, Sendable {
    public let observedTopicID: TopicID
    public let aliasID: TopicAliasID
    public let evidenceID: TopicMeetingEvidenceID
    public let identityEventID: TopicIdentityEventID
    public let meetingID: MeetingID
    public let segmentID: UUID
    public let sourceTranscriptRevision: Int
    public let observedLabel: String
    public let language: String?
    public let origin: TopicLinkProposalOrigin
    public let similarityCandidate: TopicSimilarityCandidate?
    public let confirmedAt: Date

    public init(
        observedTopicID: TopicID = TopicID(),
        aliasID: TopicAliasID = TopicAliasID(),
        evidenceID: TopicMeetingEvidenceID = TopicMeetingEvidenceID(),
        identityEventID: TopicIdentityEventID = TopicIdentityEventID(),
        meetingID: MeetingID,
        segmentID: UUID,
        sourceTranscriptRevision: Int,
        observedLabel: String,
        language: String?,
        origin: TopicLinkProposalOrigin,
        similarityCandidate: TopicSimilarityCandidate? = nil,
        confirmedAt: Date = Date()
    ) {
        self.observedTopicID = observedTopicID
        self.aliasID = aliasID
        self.evidenceID = evidenceID
        self.identityEventID = identityEventID
        self.meetingID = meetingID
        self.segmentID = segmentID
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.observedLabel = observedLabel
        self.language = language
        self.origin = origin
        self.similarityCandidate = similarityCandidate
        self.confirmedAt = confirmedAt
    }
}

public enum TopicLinkResolution: String, Codable, CaseIterable, Sendable {
    case keptDistinct = "kept-distinct"
    case mergedIntoExisting = "merged-into-existing"
}

public enum TopicEvidenceAvailability: String, Codable, CaseIterable, Sendable {
    case current
    case stale
    case unavailable
}

/// One user-confirmed meeting/topic edge with exact source identity. Segment
/// IDs survive physical transcript removal so unavailable evidence stays
/// explainable instead of being silently rewritten.
public struct TopicMeetingEvidence: Codable, Equatable, Sendable, Identifiable {
    public let id: TopicMeetingEvidenceID
    public let topicID: TopicID
    public let aliasID: TopicAliasID
    public let meetingID: MeetingID
    public let segmentID: UUID
    public let sourceTranscriptRevision: Int
    public let observedLabel: String
    public let language: String?
    public let origin: TopicLinkProposalOrigin
    public let resolution: TopicLinkResolution
    public let suggestedTopicID: TopicID?
    public let similarity: Double?
    public let profileFingerprint: String?
    public let confirmedAt: Date
    public let availability: TopicEvidenceAvailability

    public init(
        id: TopicMeetingEvidenceID = TopicMeetingEvidenceID(),
        topicID: TopicID,
        aliasID: TopicAliasID,
        meetingID: MeetingID,
        segmentID: UUID,
        sourceTranscriptRevision: Int,
        observedLabel: String,
        language: String?,
        origin: TopicLinkProposalOrigin,
        resolution: TopicLinkResolution,
        suggestedTopicID: TopicID?,
        similarity: Double?,
        profileFingerprint: String?,
        confirmedAt: Date,
        availability: TopicEvidenceAvailability
    ) {
        self.id = id
        self.topicID = topicID
        self.aliasID = aliasID
        self.meetingID = meetingID
        self.segmentID = segmentID
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.observedLabel = observedLabel
        self.language = language
        self.origin = origin
        self.resolution = resolution
        self.suggestedTopicID = suggestedTopicID
        self.similarity = similarity
        self.profileFingerprint = profileFingerprint
        self.confirmedAt = confirmedAt
        self.availability = availability
    }
}

/// Result of one idempotent confirmation. Evidence and aliases remain attached
/// to the observed source topic; `canonicalTopic` is the current merged root.
public struct ConfirmedTopicLink: Equatable, Sendable {
    public let observedTopic: Topic
    public let canonicalTopic: Topic
    public let alias: TopicAlias
    public let evidence: TopicMeetingEvidence
    public let identityEvent: TopicIdentityEvent?

    public init(
        observedTopic: Topic,
        canonicalTopic: Topic,
        alias: TopicAlias,
        evidence: TopicMeetingEvidence,
        identityEvent: TopicIdentityEvent?
    ) {
        self.observedTopic = observedTopic
        self.canonicalTopic = canonicalTopic
        self.alias = alias
        self.evidence = evidence
        self.identityEvent = identityEvent
    }

    /// Compatibility name for callers interested only in the current root.
    public var topic: Topic { canonicalTopic }
}

public enum TopicIdentityEventKind: String, Codable, CaseIterable, Sendable {
    case merge
    case split
}

/// Immutable user-confirmed topic identity history. The `topic` row keeps only
/// the current redirect projection; this event explains every transition.
public struct TopicIdentityEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: TopicIdentityEventID
    public let kind: TopicIdentityEventKind
    public let sourceTopicID: TopicID
    public let targetTopicID: TopicID
    public let occurredAt: Date

    public init(
        id: TopicIdentityEventID = TopicIdentityEventID(),
        kind: TopicIdentityEventKind,
        sourceTopicID: TopicID,
        targetTopicID: TopicID,
        occurredAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.sourceTopicID = sourceTopicID
        self.targetTopicID = targetTopicID
        self.occurredAt = occurredAt
    }
}

public struct ConfirmedTopicIdentityChange: Equatable, Sendable {
    public let source: Topic
    public let target: Topic
    public let event: TopicIdentityEvent

    public init(source: Topic, target: Topic, event: TopicIdentityEvent) {
        self.source = source
        self.target = target
        self.event = event
    }
}

/// Stable, locale-independent lookup normalization. A match is candidate
/// evidence only; it never authorizes a link or merge.
public enum TopicAliasNormalizer {
    private static let locale = Locale(identifier: "en_US_POSIX")

    public static func displayLabel(_ value: String) -> String? {
        let collapsed = value.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    public static func normalize(_ value: String) -> String? {
        guard let label = displayLabel(value) else { return nil }
        return label
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale)
            .lowercased(with: locale)
    }

    public static func language(_ value: String?) -> String? {
        let normalized = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased(with: locale)
        return normalized.isEmpty || normalized == "und" ? nil : normalized
    }
}
