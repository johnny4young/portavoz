import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

private struct CommitmentSeedContext {
    let language: String
    let meetingIDByExternalID: [String: MeetingID]
    let evidenceIDByExternalID: [String: UUID]
    let speakerIDByTargetID: [String: SpeakerID]
    let personIDByExternalID: [String: PersonID]
    let store: MeetingStore
}

struct CommitmentLinkQualityCorpusMapping: Sendable {
    private let meetingIDByExternalID: [String: MeetingID]
    private let externalEvidenceIDByUUID: [UUID: String]
    private let externalCommitmentIDByDomainID: [CommitmentID: String]
    private let personIDByExternalID: [String: PersonID]
    private let externalPersonIDByDomainID: [PersonID: String]

    static func seed(
        fixtureCase: CommitmentLinkQualityCase,
        store: MeetingStore
    ) async throws -> Self {
        let externalMeetingIDs = Set(
            [fixtureCase.candidate.sourceMeetingID]
                + fixtureCase.targets.flatMap(\.sourceMeetingIDs))
        let meetingIDByExternalID = try Dictionary(uniqueKeysWithValues:
            externalMeetingIDs.map { externalID in
                (
                    externalID,
                    MeetingID(rawValue: try deterministicUUID(
                        namespace: "commitment-link-quality-meeting",
                        identifier: externalID))
                )
            })
        let personIDs = Set(
            ([fixtureCase.candidate.assignee]
                + fixtureCase.targets.map(\.assignee)).compactMap { assignee in
                assignee.kind == "person" ? assignee.id : nil
            })
        let personIDByExternalID = try await seedPeople(
            personIDs,
            caseID: fixtureCase.id,
            store: store)
        let evidenceIDByExternalID = try makeEvidenceIDs(fixtureCase.targets)
        let speakerIDByTargetID = try makeSpeakerIDs(fixtureCase.targets)
        try await seedEvidenceMeetings(
            fixtureCase: fixtureCase,
            meetingIDByExternalID: meetingIDByExternalID,
            evidenceIDByExternalID: evidenceIDByExternalID,
            speakerIDByTargetID: speakerIDByTargetID,
            store: store)

        let commitmentIDByExternalID = try await seedCommitments(
            fixtureCase: fixtureCase,
            meetingIDByExternalID: meetingIDByExternalID,
            evidenceIDByExternalID: evidenceIDByExternalID,
            speakerIDByTargetID: speakerIDByTargetID,
            personIDByExternalID: personIDByExternalID,
            store: store)

        return Self(
            meetingIDByExternalID: meetingIDByExternalID,
            externalEvidenceIDByUUID: Dictionary(uniqueKeysWithValues:
                evidenceIDByExternalID.map { ($0.value, $0.key) }),
            externalCommitmentIDByDomainID: Dictionary(uniqueKeysWithValues:
                commitmentIDByExternalID.map { ($0.value, $0.key) }),
            personIDByExternalID: personIDByExternalID,
            externalPersonIDByDomainID: Dictionary(uniqueKeysWithValues:
                personIDByExternalID.map { ($0.value, $0.key) }))
    }

    func request(
        for candidate: CommitmentLinkQualityCandidate
    ) throws -> ObserveCommitmentLinkSuggestionsRequest {
        guard let meetingID = meetingIDByExternalID[candidate.sourceMeetingID] else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "candidate source meeting is unknown")
        }
        return ObserveCommitmentLinkSuggestionsRequest(
            sourceMeetingID: meetingID,
            actionItemID: try Self.deterministicUUID(
                namespace: "commitment-link-quality-candidate-action",
                identifier: candidate.actionItemID),
            candidateText: candidate.text,
            candidateAssignee: try Self.domainAssignee(
                candidate.assignee,
                personIDByExternalID: personIDByExternalID))
    }

    func observation(
        caseID: String,
        result: CommitmentLinkSuggestionObservation
    ) throws -> CommitmentLinkQualityCaseObservation {
        let semanticIDs = try result.semanticHitSegmentIDs.map { segmentID in
            guard let externalID = externalEvidenceIDByUUID[segmentID] else {
                throw CommitmentLinkQualityBenchmarkError.invalidObservation(
                    "semantic result references unknown evidence")
            }
            return externalID
        }
        let suggestions = try result.suggestions.map { suggestion in
            guard let commitmentID = externalCommitmentIDByDomainID[suggestion.id] else {
                throw CommitmentLinkQualityBenchmarkError.invalidObservation(
                    "suggestion references unknown commitment")
            }
            return CommitmentLinkSuggestionRow(
                commitmentID: commitmentID,
                assignee: try externalAssignee(suggestion.assignee),
                matchedEvidenceSegmentIDs: try suggestion.matchedEvidenceSegmentIDs.map {
                    guard let externalID = externalEvidenceIDByUUID[$0] else {
                        throw CommitmentLinkQualityBenchmarkError.invalidObservation(
                            "suggestion references unknown evidence")
                    }
                    return externalID
                },
                bestSemanticRank: suggestion.bestSemanticRank)
        }
        return CommitmentLinkQualityCaseObservation(
            caseID: caseID,
            semanticHitSegmentIDs: semanticIDs,
            suggestions: suggestions)
    }

    private func externalAssignee(
        _ assignee: CommitmentAssignee
    ) throws -> CommitmentLinkQualityAssignee {
        switch assignee {
        case .me:
            return CommitmentLinkQualityAssignee(kind: "me", id: nil)
        case .unassigned:
            return CommitmentLinkQualityAssignee(kind: "unassigned", id: nil)
        case .person(let personID):
            guard let externalID = externalPersonIDByDomainID[personID] else {
                throw CommitmentLinkQualityBenchmarkError.invalidObservation(
                    "suggestion references unknown person")
            }
            return CommitmentLinkQualityAssignee(kind: "person", id: externalID)
        }
    }
}

private extension CommitmentLinkQualityCorpusMapping {
    static func seedCommitments(
        fixtureCase: CommitmentLinkQualityCase,
        meetingIDByExternalID: [String: MeetingID],
        evidenceIDByExternalID: [String: UUID],
        speakerIDByTargetID: [String: SpeakerID],
        personIDByExternalID: [String: PersonID],
        store: MeetingStore
    ) async throws -> [String: CommitmentID] {
        let context = CommitmentSeedContext(
            language: fixtureCase.language,
            meetingIDByExternalID: meetingIDByExternalID,
            evidenceIDByExternalID: evidenceIDByExternalID,
            speakerIDByTargetID: speakerIDByTargetID,
            personIDByExternalID: personIDByExternalID,
            store: store)
        var result: [String: CommitmentID] = [:]
        for (targetIndex, target) in fixtureCase.targets.enumerated() {
            result[target.id] = try await seedCommitment(
                target: target,
                targetIndex: targetIndex,
                context: context)
        }
        return result
    }

    static func seedCommitment(
        target: CommitmentLinkQualityTarget,
        targetIndex: Int,
        context: CommitmentSeedContext
    ) async throws -> CommitmentID {
        let commitmentID = CommitmentID(rawValue: try deterministicUUID(
            namespace: "commitment-link-quality-target",
            identifier: target.id))
        let actionItemID = try deterministicUUID(
            namespace: "commitment-link-quality-target-action",
            identifier: target.id)
        guard let sourceMeetingID = target.sourceMeetingIDs.first,
              let meetingID = context.meetingIDByExternalID[sourceMeetingID],
              let speakerID = context.speakerIDByTargetID[target.id]
        else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "target \(target.id) lost its source identity")
        }
        let evidence = try target.evidence.map { row -> UUID in
            guard let segmentID = context.evidenceIDByExternalID[row.id] else {
                throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                    "target \(target.id) lost evidence identity")
            }
            return segmentID
        }
        _ = try await context.store.saveSummary(SummaryDraft(
            meetingID: meetingID,
            recipeID: Recipe.general.id,
            language: context.language,
            markdown: target.title,
            actionItems: [ActionItem(
                id: actionItemID,
                text: target.title,
                ownerSpeakerID: speakerID)],
            actionItemEvidence: [SummaryActionItemEvidence(
                actionItemID: actionItemID,
                evidenceSegmentIDs: evidence)]))
        let timestamp = Date(
            timeIntervalSince1970: 1_720_000_000 + TimeInterval(targetIndex * 10))
        try await confirm(
            target: target,
            commitmentID: commitmentID,
            actionItemID: actionItemID,
            personIDByExternalID: context.personIDByExternalID,
            timestamp: timestamp,
            store: context.store)
        try await applyTerminalState(
            target: target,
            commitmentID: commitmentID,
            meetingID: meetingID,
            timestamp: timestamp,
            store: context.store)
        return commitmentID
    }

    static func confirm(
        target: CommitmentLinkQualityTarget,
        commitmentID: CommitmentID,
        actionItemID: UUID,
        personIDByExternalID: [String: PersonID],
        timestamp: Date,
        store: MeetingStore
    ) async throws {
        _ = try await store.confirmCommitment(
            CommitmentConfirmation(
                commitmentID: commitmentID,
                sourceID: CommitmentSourceID(rawValue: try deterministicUUID(
                    namespace: "commitment-link-quality-source",
                    identifier: target.id)),
                eventID: CommitmentEventID(rawValue: try deterministicUUID(
                    namespace: "commitment-link-quality-confirm",
                    identifier: target.id)),
                title: target.title,
                assignee: try domainAssignee(
                    target.assignee,
                    personIDByExternalID: personIDByExternalID),
                origin: .generatedActionItem(actionItemID)),
            at: timestamp)
    }

    static func applyTerminalState(
        target: CommitmentLinkQualityTarget,
        commitmentID: CommitmentID,
        meetingID: MeetingID,
        timestamp: Date,
        store: MeetingStore
    ) async throws {
        guard target.status != "confirmed" else { return }
        let transition: CommitmentTransition = target.status == "done"
            ? .complete
            : .dismiss
        _ = try await store.applyCommitmentTransition(
            transition,
            to: commitmentID,
            eventID: CommitmentEventID(rawValue: try deterministicUUID(
                namespace: "commitment-link-quality-transition",
                identifier: target.id)),
            sourceMeetingID: meetingID,
            at: timestamp.addingTimeInterval(1))
    }

    static func makeEvidenceIDs(
        _ targets: [CommitmentLinkQualityTarget]
    ) throws -> [String: UUID] {
        let evidence = targets.flatMap(\.evidence)
        return try Dictionary(uniqueKeysWithValues: evidence.map { row in
            (
                row.id,
                try deterministicUUID(
                    namespace: "commitment-link-quality-evidence",
                    identifier: row.id)
            )
        })
    }

    static func makeSpeakerIDs(
        _ targets: [CommitmentLinkQualityTarget]
    ) throws -> [String: SpeakerID] {
        try Dictionary(uniqueKeysWithValues: targets.map { target in
            (
                target.id,
                SpeakerID(rawValue: try deterministicUUID(
                    namespace: "commitment-link-quality-target-speaker",
                    identifier: target.id))
            )
        })
    }

    static func seedPeople(
        _ externalPersonIDs: Set<String>,
        caseID: String,
        store: MeetingStore
    ) async throws -> [String: PersonID] {
        var result: [String: PersonID] = [:]
        for externalID in externalPersonIDs.sorted() {
            let meeting = Meeting(
                id: MeetingID(rawValue: try deterministicUUID(
                    namespace: "commitment-link-quality-person-meeting",
                    identifier: "\(caseID):\(externalID)")),
                title: "Synthetic identity fixture",
                startedAt: Date(timeIntervalSince1970: 1_719_000_000))
            let speaker = Speaker(
                id: SpeakerID(rawValue: try deterministicUUID(
                    namespace: "commitment-link-quality-person-speaker",
                    identifier: "\(caseID):\(externalID)")),
                meetingID: meeting.id,
                label: externalID,
                displayName: externalID)
            try await store.save(meeting)
            try await store.save([speaker])
            let link = try await store.createPersonAndLink(
                speakerID: speaker.id,
                preferredName: externalID,
                source: .manualName)
            result[externalID] = link.person.id
        }
        return result
    }

    static func seedEvidenceMeetings(
        fixtureCase: CommitmentLinkQualityCase,
        meetingIDByExternalID: [String: MeetingID],
        evidenceIDByExternalID: [String: UUID],
        speakerIDByTargetID: [String: SpeakerID],
        store: MeetingStore
    ) async throws {
        let rows = fixtureCase.targets.flatMap { target in
            target.evidence.map { (target, $0) }
        }
        let grouped = Dictionary(grouping: rows, by: { $0.1.meetingID })
        for (meetingIndex, externalMeetingID) in grouped.keys.sorted().enumerated() {
            guard let meetingID = meetingIDByExternalID[externalMeetingID],
                  let meetingRows = grouped[externalMeetingID]
            else {
                throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                    "evidence meeting is unknown")
            }
            let startedAt = Date(
                timeIntervalSince1970: 1_720_000_000
                    + TimeInterval(meetingIndex * 3_600))
            let meeting = Meeting(
                id: meetingID,
                title: "Synthetic commitment evidence",
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(
                    TimeInterval(meetingRows.count + 2)),
                language: fixtureCase.language)
            var speakerByID: [SpeakerID: Speaker] = [:]
            for (target, _) in meetingRows {
                guard let speakerID = speakerIDByTargetID[target.id] else {
                    throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                        "target speaker is unknown")
                }
                speakerByID[speakerID] = Speaker(
                    id: speakerID,
                    meetingID: meetingID,
                    label: target.id,
                    displayName: target.id)
            }
            let speakers = speakerByID.values.sorted {
                $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
            let segments = try meetingRows.enumerated().map { offset, row in
                let (target, evidence) = row
                guard let segmentID = evidenceIDByExternalID[evidence.id],
                      let speakerID = speakerIDByTargetID[target.id]
                else {
                    throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                        "evidence identity is unknown")
                }
                return TranscriptSegment(
                    id: segmentID,
                    meetingID: meetingID,
                    speakerID: speakerID,
                    channel: .system,
                    text: evidence.text,
                    language: evidence.language,
                    startTime: TimeInterval(offset + 1),
                    endTime: TimeInterval(offset + 2),
                    confidence: 1,
                    isFinal: true)
            }
            try await store.save(meeting)
            try await store.save(speakers)
            try await store.save(segments)
        }
    }

    static func domainAssignee(
        _ assignee: CommitmentLinkQualityAssignee,
        personIDByExternalID: [String: PersonID]
    ) throws -> CommitmentAssignee {
        switch assignee.kind {
        case "me": return .me
        case "unassigned": return .unassigned
        case "person":
            guard let externalID = assignee.id,
                  let personID = personIDByExternalID[externalID]
            else {
                throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                    "person assignee is unknown")
            }
            return .person(personID)
        default:
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "assignee kind is unknown")
        }
    }

    static func deterministicUUID(
        namespace: String,
        identifier: String
    ) throws -> UUID {
        let digest = OperationFingerprint.make(
            version: namespace,
            components: [identifier])
        let compact = String(digest.prefix(32))
        let value = [
            compact.prefix(8),
            compact.dropFirst(8).prefix(4),
            compact.dropFirst(12).prefix(4),
            compact.dropFirst(16).prefix(4),
            compact.dropFirst(20).prefix(12)
        ].map(String.init).joined(separator: "-")
        guard let result = UUID(uuidString: value) else {
            throw CommitmentLinkQualityBenchmarkError.invalidFixture(
                "identity digest is invalid")
        }
        return result
    }
}
