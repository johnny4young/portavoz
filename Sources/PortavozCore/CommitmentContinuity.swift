import Foundation

/// User-confirmed continuity state. Generated action items never enter this
/// status model until an explicit confirmation boundary creates a commitment.
public enum CommitmentStatus: String, Codable, CaseIterable, Sendable, Equatable {
    case confirmed
    case done
    case dismissed
}

/// Explicit ownership for user-confirmed continuity. The structural local
/// speaker is not a canonical `Person`, so `me` must remain distinct from an
/// unassigned commitment instead of relying on a display-name convention.
public enum CommitmentAssigneeKind: String, Codable, CaseIterable, Sendable {
    case me
    case person
    case unassigned
}

public enum CommitmentAssignee: Sendable, Equatable, Hashable {
    case me
    case person(PersonID)
    case unassigned

    public var canonicalPersonID: PersonID? {
        guard case .person(let personID) = self else { return nil }
        return personID
    }

    public var kind: CommitmentAssigneeKind {
        switch self {
        case .me: .me
        case .person: .person
        case .unassigned: .unassigned
        }
    }

    public init?(
        kind: CommitmentAssigneeKind,
        canonicalPersonID: PersonID?
    ) {
        switch (kind, canonicalPersonID) {
        case (.me, nil): self = .me
        case (.person, .some(let personID)): self = .person(personID)
        case (.unassigned, nil): self = .unassigned
        default: return nil
        }
    }
}

public struct Commitment: Sendable, Equatable, Identifiable {
    public let id: CommitmentID
    public let title: String
    public let status: CommitmentStatus
    public let assignee: CommitmentAssignee
    public let dueAt: Date?
    public let createdAt: Date
    public let updatedAt: Date
    public let deletedAt: Date?

    public init(
        id: CommitmentID = CommitmentID(),
        title: String,
        status: CommitmentStatus = .confirmed,
        assignee: CommitmentAssignee = .unassigned,
        dueAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.assignee = assignee
        self.dueAt = dueAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
    }

    /// Source-compatible convenience for callers that already hold an exact
    /// canonical person. New code should prefer the typed assignee.
    public init(
        id: CommitmentID = CommitmentID(),
        title: String,
        status: CommitmentStatus = .confirmed,
        canonicalPersonID: PersonID?,
        dueAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.init(
            id: id,
            title: title,
            status: status,
            assignee: canonicalPersonID.map(CommitmentAssignee.person) ?? .unassigned,
            dueAt: dueAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt)
    }

    public var canonicalPersonID: PersonID? { assignee.canonicalPersonID }
}

extension Commitment: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case assigneeKind
        case canonicalPersonID
        case dueAt
        case createdAt
        case updatedAt
        case deletedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let personID = try container.decodeIfPresent(PersonID.self, forKey: .canonicalPersonID)
        let assignee: CommitmentAssignee
        if let kind = try container.decodeIfPresent(
            CommitmentAssigneeKind.self,
            forKey: .assigneeKind
        ) {
            guard let decoded = CommitmentAssignee(
                kind: kind,
                canonicalPersonID: personID)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .assigneeKind,
                    in: container,
                    debugDescription: "Commitment assignee payload is inconsistent.")
            }
            assignee = decoded
        } else {
            // Format 1 represented only an optional external person. A nil
            // person was unassigned; it could not represent the local user.
            assignee = personID.map(CommitmentAssignee.person) ?? .unassigned
        }
        self.init(
            id: try container.decode(CommitmentID.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            status: try container.decode(CommitmentStatus.self, forKey: .status),
            assignee: assignee,
            dueAt: try container.decodeIfPresent(Date.self, forKey: .dueAt),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            deletedAt: try container.decodeIfPresent(Date.self, forKey: .deletedAt))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(status, forKey: .status)
        try container.encode(assignee.kind, forKey: .assigneeKind)
        try container.encodeIfPresent(assignee.canonicalPersonID, forKey: .canonicalPersonID)
        try container.encodeIfPresent(dueAt, forKey: .dueAt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }
}

/// The durable authority that justified creating a confirmed commitment.
/// Model output stays represented by its existing ActionItem identity.
public enum CommitmentSourceKind: String, Codable, CaseIterable, Sendable, Equatable {
    case generatedActionItem = "generated-action-item"
    case userNote = "user-note"
    case manual
}

public enum CommitmentEvidenceRole: String, Codable, CaseIterable, Sendable, Equatable {
    case promise
    case deadline
    case statusUpdate = "status-update"
}

public struct CommitmentEvidenceSegment: Codable, Sendable, Equatable {
    /// A nil identity means that a portable source can prove an evidence slot
    /// but no longer carries its identity. Persisted UUIDs intentionally remain
    /// even when the source segment is later retired.
    public let segmentID: UUID?
    public let role: CommitmentEvidenceRole
    public let ordinal: Int

    public init(
        segmentID: UUID?,
        role: CommitmentEvidenceRole,
        ordinal: Int
    ) {
        self.segmentID = segmentID
        self.role = role
        self.ordinal = ordinal
    }
}

public struct CommitmentSource: Codable, Sendable, Equatable, Identifiable {
    public let id: CommitmentSourceID
    public let commitmentID: CommitmentID
    public let kind: CommitmentSourceKind
    public let meetingID: MeetingID?
    public let actionItemID: UUID?
    public let contextItemID: UUID?
    public let transcriptRevision: Int?
    public let firstSeenAt: Date
    public let evidence: [CommitmentEvidenceSegment]

    public init(
        id: CommitmentSourceID = CommitmentSourceID(),
        commitmentID: CommitmentID,
        kind: CommitmentSourceKind,
        meetingID: MeetingID?,
        actionItemID: UUID? = nil,
        contextItemID: UUID? = nil,
        transcriptRevision: Int? = nil,
        firstSeenAt: Date,
        evidence: [CommitmentEvidenceSegment] = []
    ) {
        self.id = id
        self.commitmentID = commitmentID
        self.kind = kind
        self.meetingID = meetingID
        self.actionItemID = actionItemID
        self.contextItemID = contextItemID
        self.transcriptRevision = transcriptRevision
        self.firstSeenAt = firstSeenAt
        self.evidence = evidence
    }
}

public enum CommitmentEventKind: String, Codable, CaseIterable, Sendable, Equatable {
    case confirm
    case reassign
    case reschedule
    case complete
    case reopen
    case dismiss
}

/// One append-only user-truth transition. Kind-specific payload validation is
/// owned by CommitmentContinuityPolicy, not by callers or transport adapters.
public struct CommitmentEvent: Sendable, Equatable, Identifiable {
    public let id: CommitmentEventID
    public let commitmentID: CommitmentID
    public let kind: CommitmentEventKind
    public let assignee: CommitmentAssignee?
    public let dueAt: Date?
    public let sourceMeetingID: MeetingID?
    public let occurredAt: Date

    public init(
        id: CommitmentEventID = CommitmentEventID(),
        commitmentID: CommitmentID,
        kind: CommitmentEventKind,
        assignee: CommitmentAssignee? = nil,
        dueAt: Date? = nil,
        sourceMeetingID: MeetingID? = nil,
        occurredAt: Date
    ) {
        self.id = id
        self.commitmentID = commitmentID
        self.kind = kind
        if kind == .confirm || kind == .reassign {
            self.assignee = assignee ?? .unassigned
        } else {
            self.assignee = assignee
        }
        self.dueAt = dueAt
        self.sourceMeetingID = sourceMeetingID
        self.occurredAt = occurredAt
    }

    public init(
        id: CommitmentEventID = CommitmentEventID(),
        commitmentID: CommitmentID,
        kind: CommitmentEventKind,
        canonicalPersonID: PersonID?,
        dueAt: Date? = nil,
        sourceMeetingID: MeetingID? = nil,
        occurredAt: Date
    ) {
        self.init(
            id: id,
            commitmentID: commitmentID,
            kind: kind,
            assignee: (kind == .confirm || kind == .reassign)
                ? canonicalPersonID.map(CommitmentAssignee.person) ?? .unassigned
                : nil,
            dueAt: dueAt,
            sourceMeetingID: sourceMeetingID,
            occurredAt: occurredAt)
    }

    public var canonicalPersonID: PersonID? { assignee?.canonicalPersonID }
}

extension CommitmentEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case commitmentID
        case kind
        case assigneeKind
        case canonicalPersonID
        case dueAt
        case sourceMeetingID
        case occurredAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(CommitmentEventKind.self, forKey: .kind)
        let personID = try container.decodeIfPresent(PersonID.self, forKey: .canonicalPersonID)
        let assignee: CommitmentAssignee?
        if kind == .confirm || kind == .reassign {
            if let assigneeKind = try container.decodeIfPresent(
                CommitmentAssigneeKind.self,
                forKey: .assigneeKind
            ) {
                guard let decoded = CommitmentAssignee(
                    kind: assigneeKind,
                    canonicalPersonID: personID)
                else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .assigneeKind,
                        in: container,
                        debugDescription: "Commitment event assignee payload is inconsistent.")
                }
                assignee = decoded
            } else {
                assignee = personID.map(CommitmentAssignee.person) ?? .unassigned
            }
        } else {
            guard personID == nil,
                  !container.contains(.assigneeKind)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .assigneeKind,
                    in: container,
                    debugDescription: "This commitment event cannot carry an assignee.")
            }
            assignee = nil
        }
        self.init(
            id: try container.decode(CommitmentEventID.self, forKey: .id),
            commitmentID: try container.decode(CommitmentID.self, forKey: .commitmentID),
            kind: kind,
            assignee: assignee,
            dueAt: try container.decodeIfPresent(Date.self, forKey: .dueAt),
            sourceMeetingID: try container.decodeIfPresent(
                MeetingID.self,
                forKey: .sourceMeetingID),
            occurredAt: try container.decode(Date.self, forKey: .occurredAt))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(commitmentID, forKey: .commitmentID)
        try container.encode(kind, forKey: .kind)
        if let assignee {
            try container.encode(assignee.kind, forKey: .assigneeKind)
            try container.encodeIfPresent(
                assignee.canonicalPersonID,
                forKey: .canonicalPersonID)
        }
        try container.encodeIfPresent(dueAt, forKey: .dueAt)
        try container.encodeIfPresent(sourceMeetingID, forKey: .sourceMeetingID)
        try container.encode(occurredAt, forKey: .occurredAt)
    }
}

public enum CommitmentTransition: Sendable, Equatable {
    case reassign(CommitmentAssignee)
    case reschedule(Date?)
    case complete
    case reopen
    case dismiss
}

/// Explicit confirmation input. There is intentionally no generated-candidate
/// case: a stored ActionItem is the only model-owned source this type accepts.
public enum CommitmentOrigin: Sendable, Equatable {
    case generatedActionItem(UUID)
    case userNote(UUID)
    case manual(meetingID: MeetingID?)
}

public struct CommitmentConfirmation: Sendable, Equatable {
    public let commitmentID: CommitmentID
    public let sourceID: CommitmentSourceID
    public let eventID: CommitmentEventID
    public let title: String
    public let assignee: CommitmentAssignee
    public let dueAt: Date?
    public let origin: CommitmentOrigin

    public init(
        commitmentID: CommitmentID = CommitmentID(),
        sourceID: CommitmentSourceID = CommitmentSourceID(),
        eventID: CommitmentEventID = CommitmentEventID(),
        title: String,
        assignee: CommitmentAssignee = .unassigned,
        dueAt: Date? = nil,
        origin: CommitmentOrigin
    ) {
        self.commitmentID = commitmentID
        self.sourceID = sourceID
        self.eventID = eventID
        self.title = title
        self.assignee = assignee
        self.dueAt = dueAt
        self.origin = origin
    }

    public init(
        commitmentID: CommitmentID = CommitmentID(),
        sourceID: CommitmentSourceID = CommitmentSourceID(),
        eventID: CommitmentEventID = CommitmentEventID(),
        title: String,
        canonicalPersonID: PersonID?,
        dueAt: Date? = nil,
        origin: CommitmentOrigin
    ) {
        self.init(
            commitmentID: commitmentID,
            sourceID: sourceID,
            eventID: eventID,
            title: title,
            assignee: canonicalPersonID.map(CommitmentAssignee.person) ?? .unassigned,
            dueAt: dueAt,
            origin: origin)
    }

    public var canonicalPersonID: PersonID? { assignee.canonicalPersonID }
}

public enum CommitmentContinuityValidationError: Error, Equatable, Sendable {
    case invalidCommitment
    case invalidSource(CommitmentSourceID)
    case invalidEvent(CommitmentEventID)
    case duplicateSource(CommitmentSourceID)
    case duplicateEvent(CommitmentEventID)
    case invalidLifecycle(CommitmentEventID)
    case projectionMismatch
}

/// Versioned, transport-neutral representation for backup/import and future
/// private sync. Persistence records never become the wire contract.
public struct CommitmentContinuityEnvelope: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 2

    public let formatVersion: Int
    public let commitment: Commitment
    public let sources: [CommitmentSource]
    public let events: [CommitmentEvent]

    public init(
        commitment: Commitment,
        sources: [CommitmentSource],
        events: [CommitmentEvent]
    ) throws {
        let orderedSources = sources.sorted(by: CommitmentContinuityPolicy.precedes)
        let orderedEvents = events.sorted(by: CommitmentContinuityPolicy.precedes)
        try CommitmentContinuityPolicy.validate(
            commitment: commitment,
            sources: orderedSources,
            events: orderedEvents)
        formatVersion = Self.currentFormatVersion
        self.commitment = commitment
        self.sources = orderedSources
        self.events = orderedEvents
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case commitment
        case sources
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard (1...Self.currentFormatVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "Unsupported commitment continuity envelope version.")
        }
        let commitment = try container.decode(Commitment.self, forKey: .commitment)
        let sources = try container.decode([CommitmentSource].self, forKey: .sources)
        let events = try container.decode([CommitmentEvent].self, forKey: .events)
        do {
            try CommitmentContinuityPolicy.validate(
                commitment: commitment,
                sources: sources,
                events: events)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .events,
                in: container,
                debugDescription: "Invalid commitment continuity envelope: \(error)")
        }
        guard sources == sources.sorted(by: CommitmentContinuityPolicy.precedes),
              events == events.sorted(by: CommitmentContinuityPolicy.precedes)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .events,
                in: container,
                debugDescription: "Commitment continuity rows are not canonically ordered.")
        }
        formatVersion = version
        self.commitment = commitment
        self.sources = sources
        self.events = events
    }
}

public enum CommitmentContinuityPolicy {
    public static func validate(
        commitment: Commitment,
        sources: [CommitmentSource],
        events: [CommitmentEvent]
    ) throws {
        guard hasContent(commitment.title),
              commitment.createdAt.timeIntervalSinceReferenceDate.isFinite,
              commitment.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              commitment.updatedAt >= commitment.createdAt,
              commitment.deletedAt == nil,
              commitment.dueAt?.timeIntervalSinceReferenceDate.isFinite ?? true
        else { throw CommitmentContinuityValidationError.invalidCommitment }

        let sourceGroups = Dictionary(grouping: sources, by: \CommitmentSource.id)
        if let duplicate = sourceGroups.first(where: { $0.value.count > 1 })?.key {
            throw CommitmentContinuityValidationError.duplicateSource(duplicate)
        }
        for source in sources {
            try validate(source: source, commitmentID: commitment.id)
        }

        let eventGroups = Dictionary(grouping: events, by: \CommitmentEvent.id)
        if let duplicate = eventGroups.first(where: { $0.value.count > 1 })?.key {
            throw CommitmentContinuityValidationError.duplicateEvent(duplicate)
        }
        guard !sources.isEmpty, !events.isEmpty else {
            throw CommitmentContinuityValidationError.invalidCommitment
        }
        let projection = try projectedCommitment(
            id: commitment.id,
            title: commitment.title,
            events: events)
        guard projection == commitment else {
            throw CommitmentContinuityValidationError.projectionMismatch
        }
    }

    public static func projectedCommitment(
        id: CommitmentID,
        title: String,
        events: [CommitmentEvent]
    ) throws -> Commitment {
        let ordered = events.sorted(by: precedes)
        guard let first = ordered.first,
              first.commitmentID == id,
              first.kind == .confirm,
              validPayload(first)
        else {
            throw CommitmentContinuityValidationError.invalidLifecycle(
                ordered.first?.id ?? CommitmentEventID())
        }
        var projection = Projection(
            status: .confirmed,
            assignee: first.assignee ?? .unassigned,
            dueAt: first.dueAt)
        var previousDate = first.occurredAt
        for event in ordered.dropFirst() {
            guard event.commitmentID == id,
                  event.occurredAt >= previousDate,
                  validPayload(event)
            else { throw CommitmentContinuityValidationError.invalidEvent(event.id) }
            try apply(event, to: &projection)
            previousDate = event.occurredAt
        }
        return Commitment(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            status: projection.status,
            assignee: projection.assignee,
            dueAt: projection.dueAt,
            createdAt: first.occurredAt,
            updatedAt: ordered.last?.occurredAt ?? first.occurredAt)
    }

    public static func precedes(_ lhs: CommitmentSource, _ rhs: CommitmentSource) -> Bool {
        if !sameInstant(lhs.firstSeenAt, rhs.firstSeenAt) {
            return lhs.firstSeenAt < rhs.firstSeenAt
        }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }

    public static func precedes(_ lhs: CommitmentEvent, _ rhs: CommitmentEvent) -> Bool {
        if !sameInstant(lhs.occurredAt, rhs.occurredAt) {
            return lhs.occurredAt < rhs.occurredAt
        }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }

    private static func validate(
        source: CommitmentSource,
        commitmentID: CommitmentID
    ) throws {
        let evidenceOrdinals = source.evidence.map(\.ordinal)
        let liveEvidenceIDs = source.evidence.compactMap(\.segmentID)
        let validEvidence = Set(evidenceOrdinals).count == evidenceOrdinals.count
            && evidenceOrdinals.sorted() == Array(0..<evidenceOrdinals.count)
            && Set(liveEvidenceIDs).count == liveEvidenceIDs.count
        guard source.commitmentID == commitmentID,
              source.firstSeenAt.timeIntervalSinceReferenceDate.isFinite,
              source.transcriptRevision.map({ $0 >= 0 }) ?? true,
              validEvidence
        else { throw CommitmentContinuityValidationError.invalidSource(source.id) }

        switch source.kind {
        case .generatedActionItem:
            guard source.meetingID != nil,
                  source.actionItemID != nil,
                  source.contextItemID == nil,
                  source.transcriptRevision != nil,
                  !source.evidence.isEmpty
            else { throw CommitmentContinuityValidationError.invalidSource(source.id) }
        case .userNote:
            guard source.meetingID != nil,
                  source.actionItemID == nil,
                  source.contextItemID != nil,
                  source.transcriptRevision == nil,
                  source.evidence.isEmpty
            else { throw CommitmentContinuityValidationError.invalidSource(source.id) }
        case .manual:
            guard source.actionItemID == nil,
                  source.contextItemID == nil,
                  source.transcriptRevision == nil,
                  source.evidence.isEmpty
            else { throw CommitmentContinuityValidationError.invalidSource(source.id) }
        }
    }

    private static func validPayload(_ event: CommitmentEvent) -> Bool {
        guard event.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              event.dueAt?.timeIntervalSinceReferenceDate.isFinite ?? true
        else { return false }
        switch event.kind {
        case .confirm:
            return event.assignee != nil
        case .reassign:
            return event.assignee != nil && event.dueAt == nil
        case .reschedule:
            return event.assignee == nil
        case .complete, .reopen, .dismiss:
            return event.assignee == nil && event.dueAt == nil
        }
    }

    private static func apply(
        _ event: CommitmentEvent,
        to projection: inout Projection
    ) throws {
        switch event.kind {
        case .confirm:
            throw CommitmentContinuityValidationError.invalidLifecycle(event.id)
        case .reassign:
            try requireConfirmed(projection, for: event.id)
            projection.assignee = event.assignee ?? .unassigned
        case .reschedule:
            try requireConfirmed(projection, for: event.id)
            projection.dueAt = event.dueAt
        case .complete:
            try requireConfirmed(projection, for: event.id)
            projection.status = .done
        case .reopen:
            guard projection.status == .done || projection.status == .dismissed else {
                throw CommitmentContinuityValidationError.invalidLifecycle(event.id)
            }
            projection.status = .confirmed
        case .dismiss:
            try requireConfirmed(projection, for: event.id)
            projection.status = .dismissed
        }
    }

    private static func requireConfirmed(
        _ projection: Projection,
        for eventID: CommitmentEventID
    ) throws {
        guard projection.status == .confirmed else {
            throw CommitmentContinuityValidationError.invalidLifecycle(eventID)
        }
    }

    private static func hasContent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func sameInstant(_ lhs: Date, _ rhs: Date) -> Bool {
        Int64((lhs.timeIntervalSince1970 * 1_000).rounded())
            == Int64((rhs.timeIntervalSince1970 * 1_000).rounded())
    }

    private struct Projection {
        var status: CommitmentStatus
        var assignee: CommitmentAssignee
        var dueAt: Date?
    }
}
