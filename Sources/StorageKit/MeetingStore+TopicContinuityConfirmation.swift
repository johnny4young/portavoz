import Foundation
import GRDB
import PortavozCore

extension MeetingStore {
    struct ValidatedTopicProposal {
        let label: String
        let normalizedAlias: String
        let language: String?
        let candidate: TopicSimilarityCandidate?
        let confirmedAt: Date
    }

    struct ReplayedTopicProposal {
        let evidence: TopicMeetingEvidence
        let alias: TopicAliasRecord
        let observed: TopicRecord
    }
    static func confirmTopicProposal(
        _ proposal: TopicLinkProposal,
        mergeTargetID: TopicID?,
        in database: Database
    ) throws -> ConfirmedTopicLink {
        let validated = try validateTopicProposalShape(proposal)
        if let existing = try TopicMeetingEvidenceRecord.fetchOne(
            database,
            key: proposal.evidenceID.rawValue.uuidString) {
            return try replayConfirmedTopicProposal(
                proposal,
                mergeTargetID: mergeTargetID,
                validated: validated,
                evidence: existing,
                in: database)
        }
        try validateTopicProposalSource(
            proposal,
            candidate: validated.candidate,
            in: database)
        try requireAvailableTopicProposalIdentities(proposal, in: database)
        let target = try validatedTopicTarget(
            proposal,
            mergeTargetID: mergeTargetID,
            candidate: validated.candidate,
            in: database)
        return try persistConfirmedTopicProposal(
            proposal,
            validated: validated,
            target: target,
            in: database)
    }

    static func persistConfirmedTopicProposal(
        _ proposal: TopicLinkProposal,
        validated: ValidatedTopicProposal,
        target: TopicRecord?,
        in database: Database
    ) throws -> ConfirmedTopicLink {
        let observedTopic = Topic(
            id: proposal.observedTopicID,
            preferredLabel: validated.label)
        var observedRecord = TopicRecord(
            observedTopic,
            createdAt: validated.confirmedAt,
            updatedAt: validated.confirmedAt)
        let alias = TopicAlias(
            id: proposal.aliasID,
            topicID: observedTopic.id,
            displayLabel: validated.label,
            normalizedAlias: validated.normalizedAlias,
            language: validated.language,
            source: proposal.origin)
        let resolution: TopicLinkResolution = target == nil
            ? .keptDistinct
            : .mergedIntoExisting
        let evidence = makeTopicEvidence(
            proposal,
            topicID: observedTopic.id,
            alias: alias,
            resolution: resolution,
            confirmedAt: validated.confirmedAt)

        try observedRecord.insert(database)
        try TopicAliasRecord(
            alias,
            createdAt: validated.confirmedAt,
            updatedAt: validated.confirmedAt)
            .insert(database)
        try TopicMeetingEvidenceRecord(evidence).insert(database)

        let identityEvent = try attachConfirmedTopic(
            proposal,
            source: &observedRecord,
            target: target,
            confirmedAt: validated.confirmedAt,
            in: database)

        return ConfirmedTopicLink(
            observedTopic: try observedRecord.topic,
            canonicalTopic: try (target ?? observedRecord).topic,
            alias: alias,
            evidence: evidence,
            identityEvent: identityEvent)
    }

    static func attachConfirmedTopic(
        _ proposal: TopicLinkProposal,
        source: inout TopicRecord,
        target: TopicRecord?,
        confirmedAt: Date,
        in database: Database
    ) throws -> TopicIdentityEvent? {
        guard let target else { return nil }
        let eventDate = try topicIdentityTimestamp(
            confirmedAt,
            source: source,
            target: target,
            in: database)
        let event = TopicIdentityEvent(
            id: proposal.identityEventID,
            kind: .merge,
            sourceTopicID: proposal.observedTopicID,
            targetTopicID: try target.topic.id,
            occurredAt: eventDate)
        try TopicIdentityEventRecord(event).insert(database)
        source.mergedIntoTopicID = target.id
        source.updatedAt = eventDate
        try source.update(database)
        guard let persisted = try TopicIdentityEventRecord.fetchOne(
            database,
            key: event.id.rawValue.uuidString)
        else {
            throw StorageError.invalidTopicContinuity(
                "confirmed merge history was not persisted")
        }
        return try persisted.event
    }

    static func requireAvailableTopicProposalIdentities(
        _ proposal: TopicLinkProposal,
        in database: Database
    ) throws {
        guard try TopicRecord.fetchOne(
            database,
            key: proposal.observedTopicID.rawValue.uuidString) == nil,
              try TopicAliasRecord.fetchOne(
                database,
                key: proposal.aliasID.rawValue.uuidString) == nil
        else {
            throw StorageError.invalidTopicContinuity(
                "proposal identities are already in use")
        }
    }

    static func validatedTopicTarget(
        _ proposal: TopicLinkProposal,
        mergeTargetID: TopicID?,
        candidate: TopicSimilarityCandidate?,
        in database: Database
    ) throws -> TopicRecord? {
        let target = try mergeTargetID.map { try activeTopic($0, in: database) }
        if proposal.origin == .generatedSimilarity,
           candidate?.topicID != mergeTargetID,
           mergeTargetID != nil {
            throw StorageError.invalidTopicContinuity(
                "generated candidate does not match the selected topic")
        }
        if mergeTargetID != nil,
           try TopicIdentityEventRecord.fetchOne(
            database,
            key: proposal.identityEventID.rawValue.uuidString) != nil {
            throw StorageError.invalidTopicContinuity(
                "topic identity event is already in use")
        }
        return target
    }

    static func replayConfirmedTopicProposal(
        _ proposal: TopicLinkProposal,
        mergeTargetID: TopicID?,
        validated: ValidatedTopicProposal,
        evidence record: TopicMeetingEvidenceRecord,
        in database: Database
    ) throws -> ConfirmedTopicLink {
        let replay = try validatedTopicReplay(
            proposal,
            mergeTargetID: mergeTargetID,
            validated: validated,
            evidence: record,
            in: database)
        let topics = try liveTopicRecords(in: database)
        let root = try topicRoot(replay.observed.id, among: topics)
        let event = try replayedTopicIdentityEvent(
            proposal,
            mergeTargetID: mergeTargetID,
            in: database)
        return ConfirmedTopicLink(
            observedTopic: try replay.observed.topic,
            canonicalTopic: try root.topic,
            alias: try replay.alias.alias,
            evidence: replay.evidence,
            identityEvent: event)
    }

    static func validatedTopicReplay(
        _ proposal: TopicLinkProposal,
        mergeTargetID: TopicID?,
        validated: ValidatedTopicProposal,
        evidence record: TopicMeetingEvidenceRecord,
        in database: Database
    ) throws -> ReplayedTopicProposal {
        let expectedResolution: TopicLinkResolution = mergeTargetID == nil
            ? .keptDistinct
            : .mergedIntoExisting
        let evidence = try record.evidence(
            availability: try topicEvidenceAvailability(record, in: database))
        guard evidence.id == proposal.evidenceID,
              evidence.topicID == proposal.observedTopicID,
              evidence.aliasID == proposal.aliasID,
              evidence.meetingID == proposal.meetingID,
              evidence.segmentID == proposal.segmentID,
              evidence.sourceTranscriptRevision == proposal.sourceTranscriptRevision,
              evidence.observedLabel == validated.label,
              evidence.language == validated.language,
              evidence.origin == proposal.origin,
              evidence.resolution == expectedResolution,
              evidence.suggestedTopicID == validated.candidate?.topicID,
              evidence.similarity == validated.candidate?.similarity,
              evidence.profileFingerprint == validated.candidate?.profileFingerprint,
              sameTopicDate(evidence.confirmedAt, validated.confirmedAt),
              let aliasRecord = try TopicAliasRecord.fetchOne(
                database,
                key: proposal.aliasID.rawValue.uuidString),
              let observedRecord = try liveTopic(proposal.observedTopicID, in: database),
              try aliasRecord.alias.topicID == proposal.observedTopicID,
              try aliasRecord.alias.displayLabel == validated.label,
              try aliasRecord.alias.normalizedAlias == validated.normalizedAlias,
              try aliasRecord.alias.language == validated.language,
              try aliasRecord.alias.source == proposal.origin,
              try observedRecord.topic.preferredLabel == validated.label
        else {
            throw StorageError.invalidTopicContinuity(
                "proposal identity was reused with different content")
        }
        return ReplayedTopicProposal(
            evidence: evidence,
            alias: aliasRecord,
            observed: observedRecord)
    }

    static func replayedTopicIdentityEvent(
        _ proposal: TopicLinkProposal,
        mergeTargetID: TopicID?,
        in database: Database
    ) throws -> TopicIdentityEvent? {
        guard let mergeTargetID else { return nil }
        guard let eventRecord = try TopicIdentityEventRecord.fetchOne(
            database,
            key: proposal.identityEventID.rawValue.uuidString),
              eventRecord.kind == TopicIdentityEventKind.merge.rawValue,
              eventRecord.sourceTopicID == proposal.observedTopicID.rawValue.uuidString,
              eventRecord.targetTopicID == mergeTargetID.rawValue.uuidString
        else {
            throw StorageError.invalidTopicContinuity(
                "confirmed merge history is unavailable or different")
        }
        return try eventRecord.event
    }

    static func validateTopicProposalShape(
        _ proposal: TopicLinkProposal
    ) throws -> ValidatedTopicProposal {
        guard proposal.sourceTranscriptRevision >= 0 else {
            throw StorageError.invalidTopicContinuity(
                "transcript revision must not be negative")
        }
        guard let label = TopicAliasNormalizer.displayLabel(proposal.observedLabel),
              let normalizedAlias = TopicAliasNormalizer.normalize(label)
        else {
            throw StorageError.invalidTopicContinuity(
                "observed label must not be empty")
        }
        let candidate: TopicSimilarityCandidate?
        switch (proposal.origin, proposal.similarityCandidate) {
        case (.manual, nil):
            candidate = nil
        case (.generatedSimilarity, .some(let value)):
            guard value.similarity.isFinite,
                  (-1.0...1.0).contains(value.similarity),
                  TopicAliasNormalizer.displayLabel(value.profileFingerprint) != nil
            else {
                throw StorageError.invalidTopicContinuity(
                    "generated similarity evidence is invalid")
            }
            candidate = TopicSimilarityCandidate(
                topicID: value.topicID,
                similarity: value.similarity,
                profileFingerprint: value.profileFingerprint.trimmingCharacters(
                    in: .whitespacesAndNewlines))
        default:
            throw StorageError.invalidTopicContinuity(
                "proposal origin and similarity evidence disagree")
        }

        return ValidatedTopicProposal(
            label: label,
            normalizedAlias: normalizedAlias,
            language: TopicAliasNormalizer.language(proposal.language),
            candidate: candidate,
            confirmedAt: canonicalTopicDate(proposal.confirmedAt))
    }

    static func validateTopicProposalSource(
        _ proposal: TopicLinkProposal,
        candidate: TopicSimilarityCandidate?,
        in database: Database
    ) throws {
        if let candidate,
           try liveTopic(candidate.topicID, in: database) == nil {
            throw StorageError.invalidTopicContinuity(
                "generated similarity candidate is unavailable")
        }

        let meetingKey = proposal.meetingID.rawValue.uuidString
        guard let meeting = try MeetingRecord.fetchOne(database, key: meetingKey),
              meeting.deletedAt == nil
        else {
            throw StorageError.invalidTopicContinuity("source meeting is unavailable")
        }
        guard meeting.transcriptRevision == proposal.sourceTranscriptRevision else {
            throw StorageError.invalidTopicContinuity(
                "source transcript revision is stale")
        }
        guard try Bool.fetchOne(
            database,
            sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM segment
                    WHERE segment.id = ?
                      AND segment.meetingID = ?
                      AND segment.deletedAt IS NULL
                      AND segment.isFinal = 1
                      AND \(acceptedSegmentHasNoActiveCorrectionSQL)
                )
                """,
            arguments: [proposal.segmentID.uuidString, meetingKey]) == true
        else {
            throw StorageError.invalidTopicContinuity(
                "source segment is unavailable, nonfinal, corrected, or foreign")
        }
    }

    static func makeTopicEvidence(
        _ proposal: TopicLinkProposal,
        topicID: TopicID,
        alias: TopicAlias,
        resolution: TopicLinkResolution,
        confirmedAt: Date
    ) -> TopicMeetingEvidence {
        TopicMeetingEvidence(
            id: proposal.evidenceID,
            topicID: topicID,
            aliasID: alias.id,
            meetingID: proposal.meetingID,
            segmentID: proposal.segmentID,
            sourceTranscriptRevision: proposal.sourceTranscriptRevision,
            observedLabel: alias.displayLabel,
            language: alias.language,
            origin: proposal.origin,
            resolution: resolution,
            suggestedTopicID: proposal.similarityCandidate?.topicID,
            similarity: proposal.similarityCandidate?.similarity,
            profileFingerprint: proposal.similarityCandidate.map {
                $0.profileFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            },
            confirmedAt: confirmedAt,
            availability: .current)
    }

}
