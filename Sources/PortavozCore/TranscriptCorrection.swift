import Foundation

/// One stable visible row produced by a user-requested transcript split.
public struct TranscriptCorrectionPart: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let speakerID: SpeakerID?
    public let language: String?
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(
        id: UUID = UUID(),
        text: String,
        speakerID: SpeakerID?,
        language: String?,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        self.id = id
        self.text = text
        self.speakerID = speakerID
        self.language = language
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// A typed transcript edit over immutable accepted segment identities.
public enum TranscriptCorrectionKind: Codable, Sendable, Equatable {
    case replaceText(text: String, language: String?)
    case changeSpeaker(SpeakerID?)
    case split([TranscriptCorrectionPart])
    case merge(replacementText: String?, language: String?)
    case suppress
    case restore
}

/// Independent correction lanes that may coexist over one accepted segment.
/// Text and speaker edits do not destroy one another; structural edits own the
/// complete visible row and therefore remain exclusive.
public enum TranscriptCorrectionDomain: String, Codable, Sendable, Equatable, Hashable {
    case text
    case speaker
    case structure
}

/// Corrections are user-authored truth until another explicit author class is
/// designed and admitted. Generated suggestions never enter this enum.
public enum TranscriptCorrectionAuthor: String, Codable, Sendable, Equatable {
    case user
}

/// Portable invariants shared by local persistence and future sync decoding.
/// Meeting-local segment and speaker existence remain StorageKit concerns.
public enum TranscriptCorrectionValidationError: Error, Equatable, Sendable {
    case invalidMetadata(UUID)
    case invalidTargets(UUID)
    case invalidKind(UUID)
    case invalidLanguage(UUID)
    case duplicateEventID(UUID)
    case wrongMeeting(UUID)
    case missingPredecessor(UUID)
    case invalidSupersession(UUID)
    case branchedSupersession(UUID)
    case overlappingTargets(UUID, UUID)
}

/// One immutable correction event plus portable ordering and sync metadata.
/// Updating an event is limited to its tombstone; undo is another event that
/// supersedes the current terminal event.
public struct TranscriptCorrectionEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let meetingID: MeetingID
    public let baseTranscriptRevision: Int
    public let targetSegmentIDs: [UUID]
    public let kind: TranscriptCorrectionKind
    public let author: TranscriptCorrectionAuthor
    public let sourceDeviceID: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let deletedAt: Date?
    public let supersedesCorrectionID: UUID?

    public init(
        id: UUID = UUID(),
        meetingID: MeetingID,
        baseTranscriptRevision: Int,
        targetSegmentIDs: [UUID],
        kind: TranscriptCorrectionKind,
        author: TranscriptCorrectionAuthor = .user,
        sourceDeviceID: UUID,
        createdAt: Date,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil,
        supersedesCorrectionID: UUID? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.baseTranscriptRevision = baseTranscriptRevision
        self.targetSegmentIDs = targetSegmentIDs
        self.kind = kind
        self.author = author
        self.sourceDeviceID = sourceDeviceID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.deletedAt = deletedAt
        self.supersedesCorrectionID = supersedesCorrectionID
    }
}

/// Versioned, transport-neutral correction history. CloudKit adoption remains
/// a separate conflict-policy decision; this envelope prevents storage rows
/// from becoming the wire contract.
public struct TranscriptCorrectionSyncEnvelope: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let meetingID: MeetingID
    public let events: [TranscriptCorrectionEvent]

    public init(
        meetingID: MeetingID,
        events: [TranscriptCorrectionEvent]
    ) throws {
        let orderedEvents = events.sorted(by: TranscriptCorrectionPolicy.precedes)
        try TranscriptCorrectionPolicy.validateHistory(
            orderedEvents,
            meetingID: meetingID)
        formatVersion = Self.currentFormatVersion
        self.meetingID = meetingID
        self.events = orderedEvents
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case meetingID
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        let meetingID = try container.decode(MeetingID.self, forKey: .meetingID)
        let events = try container.decode(
            [TranscriptCorrectionEvent].self,
            forKey: .events)
        guard formatVersion == Self.currentFormatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "Unsupported transcript correction envelope version.")
        }
        do {
            try TranscriptCorrectionPolicy.validateHistory(
                events,
                meetingID: meetingID)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .events,
                in: container,
                debugDescription: "Invalid transcript correction history: \(error)")
        }
        guard events == events.sorted(by: TranscriptCorrectionPolicy.precedes) else {
            throw DecodingError.dataCorruptedError(
                forKey: .events,
                in: container,
                debugDescription: "Transcript correction events are not canonically ordered.")
        }
        self.formatVersion = formatVersion
        self.meetingID = meetingID
        self.events = events
    }
}

/// Deterministic validation for correction data that can cross process or
/// device boundaries. It never consults a database or mutates the events.
public enum TranscriptCorrectionPolicy {
    /// Describes a forbidden rewrite of immutable event material. Tombstone
    /// metadata is validated separately as a monotonic state transition.
    public static func immutableDifference(
        _ lhs: TranscriptCorrectionEvent,
        _ rhs: TranscriptCorrectionEvent
    ) -> String? {
        guard lhs.id == rhs.id else { return "identity" }
        guard lhs.meetingID == rhs.meetingID else { return "meeting relation" }
        guard lhs.baseTranscriptRevision == rhs.baseTranscriptRevision else {
            return "base transcript revision"
        }
        guard lhs.targetSegmentIDs == rhs.targetSegmentIDs else { return "targets" }
        guard lhs.kind == rhs.kind else { return "payload" }
        guard lhs.author == rhs.author else { return "author" }
        guard lhs.sourceDeviceID == rhs.sourceDeviceID else { return "source device" }
        guard samePersistedInstant(lhs.createdAt, rhs.createdAt) else {
            return "creation time"
        }
        guard lhs.supersedesCorrectionID == rhs.supersedesCorrectionID else {
            return "supersession"
        }
        return nil
    }

    /// A published tombstone cannot disappear or move to another instant;
    /// restore is represented by a new immutable correction event.
    public static func validateTombstoneTransition(
        from local: TranscriptCorrectionEvent,
        to remote: TranscriptCorrectionEvent
    ) throws {
        if let localDeletedAt = local.deletedAt {
            guard let remoteDeletedAt = remote.deletedAt,
                  samePersistedInstant(localDeletedAt, remoteDeletedAt),
                  samePersistedInstant(local.updatedAt, remote.updatedAt)
            else {
                throw TranscriptCorrectionValidationError.invalidMetadata(remote.id)
            }
            return
        }
        guard remote.updatedAt >= local.updatedAt else {
            throw TranscriptCorrectionValidationError.invalidMetadata(remote.id)
        }
        if let remoteDeletedAt = remote.deletedAt {
            guard samePersistedInstant(remoteDeletedAt, remote.updatedAt) else {
                throw TranscriptCorrectionValidationError.invalidMetadata(remote.id)
            }
        } else {
            guard samePersistedInstant(local.updatedAt, remote.updatedAt) else {
                throw TranscriptCorrectionValidationError.invalidMetadata(remote.id)
            }
        }
    }

    public static func validatePortable(
        _ event: TranscriptCorrectionEvent
    ) throws {
        try validateMetadata(event)
        try validateTargets(event)
        try validateKind(event)
    }

    private static func validateMetadata(
        _ event: TranscriptCorrectionEvent
    ) throws {
        let deletedAtIsValid = event.deletedAt.map {
            $0.timeIntervalSinceReferenceDate.isFinite
                && $0 >= event.createdAt
                && $0 <= event.updatedAt
        } ?? true
        guard event.baseTranscriptRevision >= 0,
              event.createdAt.timeIntervalSinceReferenceDate.isFinite,
              event.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              event.updatedAt >= event.createdAt,
              deletedAtIsValid,
              event.supersedesCorrectionID != event.id
        else {
            throw TranscriptCorrectionValidationError.invalidMetadata(event.id)
        }
    }

    private static func validateTargets(
        _ event: TranscriptCorrectionEvent
    ) throws {
        let targetIDs = Set(event.targetSegmentIDs)
        guard !targetIDs.isEmpty,
              targetIDs.count == event.targetSegmentIDs.count,
              !targetIDs.contains(event.id)
        else {
            throw TranscriptCorrectionValidationError.invalidTargets(event.id)
        }
    }

    private static func validateKind(
        _ event: TranscriptCorrectionEvent
    ) throws {
        switch event.kind {
        case .replaceText(let text, let language):
            guard event.targetSegmentIDs.count == 1,
                  TranscriptContentPolicy.hasLexicalContent(text)
            else { throw TranscriptCorrectionValidationError.invalidKind(event.id) }
            try validateLanguage(language, eventID: event.id)
        case .changeSpeaker:
            guard event.targetSegmentIDs.count == 1 else {
                throw TranscriptCorrectionValidationError.invalidKind(event.id)
            }
        case .split(let parts):
            try validateSplit(parts, event: event)
        case .merge(let replacementText, let language):
            guard event.targetSegmentIDs.count >= 2,
                  replacementText.map(TranscriptContentPolicy.hasLexicalContent) ?? true
            else { throw TranscriptCorrectionValidationError.invalidKind(event.id) }
            try validateLanguage(language, eventID: event.id)
        case .suppress:
            guard event.targetSegmentIDs.count == 1 else {
                throw TranscriptCorrectionValidationError.invalidKind(event.id)
            }
        case .restore:
            guard event.supersedesCorrectionID != nil else {
                throw TranscriptCorrectionValidationError.invalidKind(event.id)
            }
        }
    }

    public static func validateHistory(
        _ events: [TranscriptCorrectionEvent],
        meetingID: MeetingID
    ) throws {
        let grouped = Dictionary(grouping: events, by: \.id)
        if let duplicate = grouped
            .filter({ $0.value.count > 1 })
            .map(\.key)
            .min(by: { $0.uuidString < $1.uuidString }) {
            throw TranscriptCorrectionValidationError.duplicateEventID(duplicate)
        }
        let byID = grouped.mapValues { $0[0] }
        var successorByPredecessor: [UUID: UUID] = [:]
        var supersededIDs = Set<UUID>()
        for event in events.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try validatePortable(event)
            guard event.meetingID == meetingID else {
                throw TranscriptCorrectionValidationError.wrongMeeting(event.id)
            }
            guard let predecessorID = event.supersedesCorrectionID else { continue }
            guard let predecessor = byID[predecessorID] else {
                throw TranscriptCorrectionValidationError.missingPredecessor(event.id)
            }
            guard predecessor.meetingID == event.meetingID,
                  predecessor.baseTranscriptRevision == event.baseTranscriptRevision,
                  predecessor.targetSegmentIDs == event.targetSegmentIDs,
                  precedes(predecessor, event)
            else {
                throw TranscriptCorrectionValidationError.invalidSupersession(event.id)
            }
            if successorByPredecessor.updateValue(event.id, forKey: predecessorID) != nil {
                throw TranscriptCorrectionValidationError.branchedSupersession(predecessorID)
            }
            supersededIDs.insert(predecessorID)
        }

        let active = events
            .filter { $0.deletedAt == nil && !supersededIDs.contains($0.id) }
            .sorted(by: precedes)
        var ownersByRevisionAndTarget: [Int: [UUID: [TranscriptCorrectionDomain: UUID]]] = [:]
        for event in active {
            let domain = try correctionDomain(of: event, indexedBy: byID)
            for targetID in event.targetSegmentIDs {
                var ownersByTarget = ownersByRevisionAndTarget[
                    event.baseTranscriptRevision,
                    default: [:]]
                var owners = ownersByTarget[targetID, default: [:]]
                let conflictingOwner = domain == .structure
                    ? owners.values.first
                    : owners[domain] ?? owners[.structure]
                if let conflictingOwner {
                    throw TranscriptCorrectionValidationError.overlappingTargets(
                        conflictingOwner,
                        event.id)
                }
                owners[domain] = event.id
                ownersByTarget[targetID] = owners
                ownersByRevisionAndTarget[event.baseTranscriptRevision] = ownersByTarget
            }
        }
    }

    /// Resolves the lane owned by an event. A restore remains in its
    /// predecessor's lane, so undo can be superseded later without rewriting
    /// or deactivating an independent correction.
    public static func correctionDomain(
        of event: TranscriptCorrectionEvent,
        in history: [TranscriptCorrectionEvent]
    ) throws -> TranscriptCorrectionDomain {
        let grouped = Dictionary(grouping: history, by: \.id)
        guard grouped.values.allSatisfy({ $0.count == 1 }) else {
            throw TranscriptCorrectionValidationError.duplicateEventID(event.id)
        }
        return try correctionDomain(
            of: event,
            indexedBy: grouped.mapValues { $0[0] },
            visited: [])
    }

    public static func precedes(
        _ lhs: TranscriptCorrectionEvent,
        _ rhs: TranscriptCorrectionEvent
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    public static func samePersistedInstant(_ lhs: Date, _ rhs: Date) -> Bool {
        Int64((lhs.timeIntervalSince1970 * 1_000).rounded())
            == Int64((rhs.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func validateLanguage(
        _ language: String?,
        eventID: UUID
    ) throws {
        guard let language else { return }
        guard LanguageCode(language)?.identifier == language else {
            throw TranscriptCorrectionValidationError.invalidLanguage(eventID)
        }
    }

    private static func validateSplit(
        _ parts: [TranscriptCorrectionPart],
        event: TranscriptCorrectionEvent
    ) throws {
        let partIDs = Set(parts.map(\.id))
        guard event.targetSegmentIDs.count == 1,
              parts.count >= 2,
              partIDs.count == parts.count,
              !partIDs.contains(event.id),
              partIDs.isDisjoint(with: event.targetSegmentIDs)
        else { throw TranscriptCorrectionValidationError.invalidKind(event.id) }

        var priorEnd: TimeInterval?
        for part in parts {
            guard TranscriptContentPolicy.hasLexicalContent(part.text),
                  part.startTime.isFinite,
                  part.endTime.isFinite,
                  part.startTime >= 0,
                  part.endTime > part.startTime,
                  priorEnd.map({ $0 == part.startTime }) ?? true
            else { throw TranscriptCorrectionValidationError.invalidKind(event.id) }
            try validateLanguage(part.language, eventID: event.id)
            priorEnd = part.endTime
        }
    }

    private static func correctionDomain(
        of event: TranscriptCorrectionEvent,
        indexedBy events: [UUID: TranscriptCorrectionEvent],
        visited: Set<UUID> = []
    ) throws -> TranscriptCorrectionDomain {
        guard !visited.contains(event.id) else {
            throw TranscriptCorrectionValidationError.invalidSupersession(event.id)
        }
        var visited = visited
        visited.insert(event.id)
        switch event.kind {
        case .replaceText:
            return .text
        case .changeSpeaker:
            return .speaker
        case .split, .merge, .suppress:
            return .structure
        case .restore:
            guard let predecessorID = event.supersedesCorrectionID,
                  let predecessor = events[predecessorID]
            else {
                throw TranscriptCorrectionValidationError.missingPredecessor(event.id)
            }
            return try correctionDomain(
                of: predecessor,
                indexedBy: events,
                visited: visited)
        }
    }
}
