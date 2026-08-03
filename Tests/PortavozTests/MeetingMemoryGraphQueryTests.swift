import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class MeetingMemoryGraphQueryTests: XCTestCase {
    private static let baseDate = Date(timeIntervalSince1970: 1_787_020_000)

    func testInvalidQueryAndUnreadyProjectionAbstain() async throws {
        let fixture = try await queryFixture(includeBlocker: true)

        let invalid = try await fixture.store.commitmentBlockerFacts(
            CommitmentBlockerQuery(
                commitmentID: fixture.commitmentID,
                itemLimit: 0))
        let unready = try await fixture.store.commitmentBlockerFacts(
            CommitmentBlockerQuery(commitmentID: fixture.commitmentID))

        XCTAssertEqual(invalid, .abstained(.invalidQuery))
        XCTAssertEqual(unready, .abstained(.projectionNotReady))
    }

    func testUnavailableCommitmentAbstainsAfterProjectionIsReady() async throws {
        let fixture = try await queryFixture(includeBlocker: true)
        _ = try await projectGraph(in: fixture.store)

        let result = try await fixture.store.commitmentBlockerFacts(
            CommitmentBlockerQuery(commitmentID: CommitmentID()))

        XCTAssertEqual(result, .abstained(.commitmentUnavailable))
    }

    func testActiveBlockerHydratesTypedFactAndExactEvidence() async throws {
        let fixture = try await queryFixture(includeBlocker: true)
        _ = try await projectGraph(in: fixture.store)

        let result = try await fixture.store.commitmentBlockerFacts(
            CommitmentBlockerQuery(commitmentID: fixture.commitmentID))
        guard case .facts(let page) = result else {
            return XCTFail("Expected source-backed blocker facts, got \(result)")
        }
        let fact = try XCTUnwrap(page.facts.first)

        XCTAssertEqual(page.facts.count, 1)
        XCTAssertFalse(page.hasMore)
        XCTAssertGreaterThan(page.projectionGeneration, 0)
        XCTAssertEqual(page.omittedStaleCount, 0)
        XCTAssertEqual(page.omittedUnavailableCount, 0)
        XCTAssertEqual(fact.id, fixture.blockerID)
        XCTAssertEqual(fact.kind, .decisionBlocksCommitment)
        XCTAssertEqual(fact.subject, .decision(fixture.decisionID))
        XCTAssertEqual(fact.object, .commitment(fixture.commitmentID))
        XCTAssertEqual(fact.subjectText, "Security approval is required.")
        XCTAssertEqual(fact.objectText, "Prepare release notes")
        XCTAssertEqual(fact.status, .active)
        XCTAssertEqual(
            fact.evidence.map(\.segmentID),
            [fixture.segments[1].id, fixture.segments[2].id])
        XCTAssertEqual(
            fact.evidence.map(\.text),
            [fixture.segments[1].text, fixture.segments[2].text])
        XCTAssertEqual(fact.navigation?.meetingID, fixture.meeting.id)
        XCTAssertEqual(fact.navigation?.segmentID, fixture.segments[2].id)
        XCTAssertEqual(fact.navigation?.timestamp, fixture.segments[2].startTime)
    }

    func testClearedOrAbsentCausalLinkAbstainsWithoutGuessing() async throws {
        let fixture = try await queryFixture(includeBlocker: true)
        _ = try await projectGraph(in: fixture.store)
        _ = try await fixture.store.applyDecisionCommitmentBlockerTransition(
            DecisionBlockerTransitionConfirmation(
                blockerID: fixture.blockerID,
                transition: .clear,
                evidence: fixture.evidence(segmentIDs: [fixture.segments[3].id]),
                confirmedAt: Self.baseDate.addingTimeInterval(30)))
        _ = try await projectGraph(in: fixture.store)

        let result = try await fixture.store.commitmentBlockerFacts(
            CommitmentBlockerQuery(commitmentID: fixture.commitmentID))

        XCTAssertEqual(result, .abstained(.unsupportedCausalLink))
    }

    func testCorrectedOpeningEvidenceFailsClosedWithoutTopologyRebuild() async throws {
        let fixture = try await queryFixture(includeBlocker: true)
        _ = try await projectGraph(in: fixture.store)
        _ = try await fixture.store.appendTranscriptCorrection(
            TranscriptCorrectionEvent(
                meetingID: fixture.meeting.id,
                baseTranscriptRevision: fixture.meeting.transcriptRevision,
                targetSegmentIDs: [fixture.segments[2].id],
                kind: .replaceText(
                    text: "Security approval no longer blocks the release.",
                    language: "en"),
                sourceDeviceID: UUID(),
                createdAt: Self.baseDate.addingTimeInterval(40)))

        let result = try await fixture.store.commitmentBlockerFacts(
            CommitmentBlockerQuery(commitmentID: fixture.commitmentID))

        XCTAssertEqual(result, .abstained(.evidenceUnavailable))
    }

    func testBoundedPageReportsMoreWithoutDroppingDeterministicOrder() async throws {
        let fixture = try await queryFixture(includeBlocker: true)
        let secondDecisionID = DecisionID()
        try await insertQueryDecision(
            id: secondDecisionID,
            statement: "Privacy review is required.",
            meeting: fixture.meeting,
            segmentID: fixture.segments[3].id,
            occurredAt: Self.baseDate.addingTimeInterval(3),
            in: fixture.store)
        let secondBlockerID = DecisionCommitmentBlockerID()
        _ = try await fixture.store.confirmDecisionCommitmentBlocker(
            DecisionCommitmentBlockerConfirmation(
                blockerID: secondBlockerID,
                decisionID: secondDecisionID,
                commitmentID: fixture.commitmentID,
                evidence: fixture.evidence(segmentIDs: [fixture.segments[3].id]),
                confirmedAt: Self.baseDate.addingTimeInterval(20)))
        _ = try await projectGraph(in: fixture.store)

        let result = try await fixture.store.commitmentBlockerFacts(
            CommitmentBlockerQuery(
                commitmentID: fixture.commitmentID,
                itemLimit: 1))
        guard case .facts(let page) = result else {
            return XCTFail("Expected a bounded fact page, got \(result)")
        }

        XCTAssertEqual(page.facts.map(\.id), [secondBlockerID])
        XCTAssertTrue(page.hasMore)
    }

    func testUnavailableNewerCandidateDoesNotHideCurrentOlderFact() async throws {
        let fixture = try await queryFixture(includeBlocker: true)
        let secondDecisionID = DecisionID()
        try await insertQueryDecision(
            id: secondDecisionID,
            statement: "Privacy review is required.",
            meeting: fixture.meeting,
            segmentID: fixture.segments[3].id,
            occurredAt: Self.baseDate.addingTimeInterval(3),
            in: fixture.store)
        let secondBlockerID = DecisionCommitmentBlockerID()
        _ = try await fixture.store.confirmDecisionCommitmentBlocker(
            DecisionCommitmentBlockerConfirmation(
                blockerID: secondBlockerID,
                decisionID: secondDecisionID,
                commitmentID: fixture.commitmentID,
                evidence: fixture.evidence(segmentIDs: [fixture.segments[3].id]),
                confirmedAt: Self.baseDate.addingTimeInterval(20)))
        _ = try await projectGraph(in: fixture.store)
        _ = try await fixture.store.appendTranscriptCorrection(
            TranscriptCorrectionEvent(
                meetingID: fixture.meeting.id,
                baseTranscriptRevision: fixture.meeting.transcriptRevision,
                targetSegmentIDs: [fixture.segments[3].id],
                kind: .replaceText(
                    text: "Privacy review was discussed without a blocker.",
                    language: "en"),
                sourceDeviceID: UUID(),
                createdAt: Self.baseDate.addingTimeInterval(40)))

        let result = try await fixture.store.commitmentBlockerFacts(
            CommitmentBlockerQuery(
                commitmentID: fixture.commitmentID,
                itemLimit: 1))
        guard case .facts(let page) = result else {
            return XCTFail("Expected the older current fact, got \(result)")
        }

        XCTAssertEqual(page.facts.map(\.id), [fixture.blockerID])
        XCTAssertEqual(page.omittedUnavailableCount, 1)
        XCTAssertFalse(page.hasMore)
    }

    func testCandidateBudgetExhaustionAbstainsInsteadOfClaimingNoBlockers() async throws {
        let fixture = try await queryFixture(includeBlocker: false)
        _ = try await fixture.store.confirmDecisionCommitmentBlocker(
            DecisionCommitmentBlockerConfirmation(
                blockerID: fixture.blockerID,
                decisionID: fixture.decisionID,
                commitmentID: fixture.commitmentID,
                evidence: fixture.evidence(segmentIDs: [fixture.segments[2].id]),
                confirmedAt: Self.baseDate.addingTimeInterval(10)))
        for index in 0..<32 {
            let decisionID = DecisionID()
            try await insertQueryDecision(
                id: decisionID,
                statement: "Additional approval \(index) is required.",
                meeting: fixture.meeting,
                segmentID: fixture.segments[0].id,
                occurredAt: Self.baseDate.addingTimeInterval(Double(index + 2)),
                in: fixture.store)
            _ = try await fixture.store.confirmDecisionCommitmentBlocker(
                DecisionCommitmentBlockerConfirmation(
                    blockerID: DecisionCommitmentBlockerID(),
                    decisionID: decisionID,
                    commitmentID: fixture.commitmentID,
                    evidence: fixture.evidence(segmentIDs: [fixture.segments[2].id]),
                    confirmedAt: Self.baseDate.addingTimeInterval(
                        Double(index + 20))))
        }
        _ = try await projectGraph(in: fixture.store)
        _ = try await fixture.store.appendTranscriptCorrection(
            TranscriptCorrectionEvent(
                meetingID: fixture.meeting.id,
                baseTranscriptRevision: fixture.meeting.transcriptRevision,
                targetSegmentIDs: [fixture.segments[2].id],
                kind: .replaceText(
                    text: "The relationship requires renewed confirmation.",
                    language: "en"),
                sourceDeviceID: UUID(),
                createdAt: Self.baseDate.addingTimeInterval(80)))

        let result = try await fixture.store.commitmentBlockerFacts(
            CommitmentBlockerQuery(
                commitmentID: fixture.commitmentID,
                itemLimit: 1))

        XCTAssertEqual(result, .abstained(.candidateBudgetExceeded))
    }

    func testApplicationUseCasePreservesTypedRepositoryResult() async throws {
        let commitmentID = CommitmentID()
        let expected = MeetingMemoryGraphQueryResult.abstained(
            .unsupportedCausalLink)
        let repository = BlockerFactRepositoryStub(result: expected)

        let result = try await LoadCommitmentBlockers(repository: repository)
            .execute(CommitmentBlockerQuery(commitmentID: commitmentID))

        XCTAssertEqual(result, expected)
        let received = await repository.receivedQuery
        XCTAssertEqual(received, CommitmentBlockerQuery(commitmentID: commitmentID))
    }

    func testCommitmentWithoutExactTranscriptEvidenceFailsClosed() async throws {
        let fixture = try await queryFixture(
            includeBlocker: true,
            sourceBackedCommitment: false)
        _ = try await projectGraph(in: fixture.store)

        let result = try await fixture.store.commitmentBlockerFacts(
            CommitmentBlockerQuery(commitmentID: fixture.commitmentID))

        XCTAssertEqual(result, .abstained(.evidenceUnavailable))
    }

    func testCurrentCommitmentSourceWinsOverCorrectedHistoricalSource() async throws {
        let fixture = try await queryFixture(includeBlocker: true)
        try await insertAdditionalQueryCommitmentSource(
            commitmentID: fixture.commitmentID,
            meeting: fixture.meeting,
            segmentID: fixture.segments[4].id,
            firstSeenAt: Self.baseDate.addingTimeInterval(3),
            in: fixture.store)
        _ = try await projectGraph(in: fixture.store)
        _ = try await fixture.store.appendTranscriptCorrection(
            TranscriptCorrectionEvent(
                meetingID: fixture.meeting.id,
                baseTranscriptRevision: fixture.meeting.transcriptRevision,
                targetSegmentIDs: [fixture.segments[1].id],
                kind: .replaceText(
                    text: "The release note commitment was superseded.",
                    language: "en"),
                sourceDeviceID: UUID(),
                createdAt: Self.baseDate.addingTimeInterval(40)))

        let result = try await fixture.store.commitmentBlockerFacts(
            CommitmentBlockerQuery(commitmentID: fixture.commitmentID))
        guard case .facts(let page) = result else {
            return XCTFail("Expected a current linked source, got \(result)")
        }

        XCTAssertEqual(
            page.facts.first?.evidence.map(\.segmentID),
            [fixture.segments[4].id, fixture.segments[2].id])
        XCTAssertEqual(page.facts.first?.navigation?.segmentID, fixture.segments[2].id)
    }

    func testMismatchedDerivedEdgeCannotOverrideAuthoritativeEndpoints() async throws {
        let fixture = try await queryFixture(includeBlocker: true)
        let unrelatedDecisionID = DecisionID()
        try await insertQueryDecision(
            id: unrelatedDecisionID,
            statement: "An unrelated decision exists.",
            meeting: fixture.meeting,
            segmentID: fixture.segments[3].id,
            occurredAt: Self.baseDate.addingTimeInterval(3),
            in: fixture.store)
        _ = try await projectGraph(in: fixture.store)
        try await fixture.store.database.write { database in
            try database.execute(
                sql: """
                    UPDATE meetingMemoryGraphDecisionCommitmentBlocker
                    SET decisionID = ?
                    WHERE blockerID = ?
                    """,
                arguments: [
                    unrelatedDecisionID.rawValue.uuidString,
                    fixture.blockerID.rawValue.uuidString
                ])
        }

        let result = try await fixture.store.commitmentBlockerFacts(
            CommitmentBlockerQuery(commitmentID: fixture.commitmentID))

        XCTAssertEqual(result, .abstained(.unsupportedCausalLink))
    }

    private func queryFixture(
        includeBlocker: Bool,
        sourceBackedCommitment: Bool = true
    ) async throws -> GraphQueryFixture {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Launch blocker query",
            startedAt: Self.baseDate)
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "Security approval is required.",
                language: "en",
                startTime: 1,
                endTime: 2,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "Mara committed to prepare the release notes.",
                language: "en",
                startTime: 3,
                endTime: 4,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "The security decision explicitly blocks the release notes.",
                language: "en",
                startTime: 5,
                endTime: 6,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "Privacy review is also required before launch.",
                language: "en",
                startTime: 7,
                endTime: 8,
                isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .system,
                text: "Mara renewed the release note commitment.",
                language: "en",
                startTime: 9,
                endTime: 10,
                isFinal: true)
        ]
        try await store.database.write { database in
            try MeetingRecord(
                meeting,
                createdAt: Self.baseDate,
                updatedAt: Self.baseDate)
                .insert(database)
            for segment in segments {
                try SegmentRecord(
                    segment,
                    createdAt: Self.baseDate,
                    updatedAt: Self.baseDate)
                    .insert(database)
            }
        }
        let decisionID = DecisionID()
        try await insertQueryDecision(
            id: decisionID,
            statement: "Security approval is required.",
            meeting: meeting,
            segmentID: segments[0].id,
            occurredAt: Self.baseDate.addingTimeInterval(1),
            in: store)
        let commitmentID = CommitmentID()
        if sourceBackedCommitment {
            try await insertQueryCommitment(
                id: commitmentID,
                title: "Prepare release notes",
                meeting: meeting,
                segmentID: segments[1].id,
                occurredAt: Self.baseDate.addingTimeInterval(2),
                in: store)
        } else {
            _ = try await store.confirmCommitment(
                CommitmentConfirmation(
                    commitmentID: commitmentID,
                    title: "Prepare release notes",
                    origin: .manual(meetingID: meeting.id)),
                at: Self.baseDate.addingTimeInterval(2))
        }
        let blockerID = DecisionCommitmentBlockerID()
        let fixture = GraphQueryFixture(
            store: store,
            meeting: meeting,
            segments: segments,
            decisionID: decisionID,
            commitmentID: commitmentID,
            blockerID: blockerID)
        if includeBlocker {
            _ = try await store.confirmDecisionCommitmentBlocker(
                DecisionCommitmentBlockerConfirmation(
                    blockerID: blockerID,
                    decisionID: decisionID,
                    commitmentID: commitmentID,
                    evidence: fixture.evidence(segmentIDs: [segments[2].id]),
                    confirmedAt: Self.baseDate.addingTimeInterval(10)))
        }
        return fixture
    }
}

private actor BlockerFactRepositoryStub: CommitmentBlockerFactReading {
    let result: MeetingMemoryGraphQueryResult
    private(set) var receivedQuery: CommitmentBlockerQuery?

    init(result: MeetingMemoryGraphQueryResult) {
        self.result = result
    }

    func commitmentBlockerFacts(
        _ query: CommitmentBlockerQuery
    ) -> MeetingMemoryGraphQueryResult {
        receivedQuery = query
        return result
    }
}

private struct GraphQueryFixture {
    let store: MeetingStore
    let meeting: Meeting
    let segments: [TranscriptSegment]
    let decisionID: DecisionID
    let commitmentID: CommitmentID
    let blockerID: DecisionCommitmentBlockerID

    func evidence(
        segmentIDs: [UUID]
    ) -> DecisionCommitmentBlockerEvidence {
        DecisionCommitmentBlockerEvidence(
            meetingID: meeting.id,
            sourceTranscriptRevision: meeting.transcriptRevision,
            segmentIDs: segmentIDs)
    }
}

private func insertQueryDecision(
    id: DecisionID,
    statement: String,
    meeting: Meeting,
    segmentID: UUID,
    occurredAt: Date,
    in store: MeetingStore
) async throws {
    let sourceID = DecisionSourceID()
    let source = DecisionSource(
        id: sourceID,
        decisionID: id,
        observationID: SummaryDecisionID(),
        summaryID: SummaryID(),
        meetingID: meeting.id,
        observedStatement: statement,
        sourceTranscriptRevision: meeting.transcriptRevision,
        observedAt: meeting.startedAt,
        linkedAt: occurredAt,
        evidence: [DecisionEvidenceSegment(segmentID: segmentID, ordinal: 0)],
        availability: .current)
    let event = DecisionEvent(
        decisionID: id,
        kind: .confirm,
        sourceID: sourceID,
        occurredAt: occurredAt)
    try await store.database.write { database in
        try DecisionContinuityRecord(MeetingDecision(
            id: id,
            statement: statement,
            status: .confirmed,
            createdAt: occurredAt,
            updatedAt: occurredAt))
            .insert(database)
        try DecisionContinuitySourceRecord(source).insert(database)
        try DecisionContinuityEvidenceSegmentRecord(
            sourceID: sourceID,
            evidence: source.evidence[0])
            .insert(database)
        try DecisionContinuityEventRecord(event).insert(database)
    }
}

private func insertQueryCommitment(
    id: CommitmentID,
    title: String,
    meeting: Meeting,
    segmentID: UUID,
    occurredAt: Date,
    in store: MeetingStore
) async throws {
    let event = CommitmentEvent(
        commitmentID: id,
        kind: .confirm,
        sourceMeetingID: meeting.id,
        occurredAt: occurredAt)
    let commitment = try CommitmentContinuityPolicy.projectedCommitment(
        id: id,
        title: title,
        events: [event])
    let source = CommitmentSource(
        commitmentID: id,
        kind: .generatedActionItem,
        meetingID: meeting.id,
        actionItemID: UUID(),
        transcriptRevision: meeting.transcriptRevision,
        firstSeenAt: occurredAt,
        evidence: [CommitmentEvidenceSegment(
            segmentID: segmentID,
            role: .promise,
            ordinal: 0)])
    _ = try CommitmentContinuityEnvelope(
        commitment: commitment,
        sources: [source],
        events: [event])
    try await store.database.write { database in
        try CommitmentRecord(commitment).insert(database)
        try CommitmentSourceRecord(source).insert(database)
        try CommitmentEvidenceSegmentRecord(
            sourceID: source.id,
            evidence: source.evidence[0])
            .insert(database)
        try CommitmentEventRecord(event).insert(database)
    }
}

private func insertAdditionalQueryCommitmentSource(
    commitmentID: CommitmentID,
    meeting: Meeting,
    segmentID: UUID,
    firstSeenAt: Date,
    in store: MeetingStore
) async throws {
    let source = CommitmentSource(
        commitmentID: commitmentID,
        kind: .generatedActionItem,
        meetingID: meeting.id,
        actionItemID: UUID(),
        transcriptRevision: meeting.transcriptRevision,
        firstSeenAt: firstSeenAt,
        evidence: [CommitmentEvidenceSegment(
            segmentID: segmentID,
            role: .promise,
            ordinal: 0)])
    try await store.database.write { database in
        try CommitmentSourceRecord(source).insert(database)
        try CommitmentEvidenceSegmentRecord(
            sourceID: source.id,
            evidence: source.evidence[0])
            .insert(database)
    }
}

@discardableResult
private func projectGraph(
    in store: MeetingStore
) async throws -> MeetingMemoryGraphProjectionResult {
    let owner = "graph-query-test-\(UUID().uuidString)"
    let sourceGeneration = try await store.database.read { database in
        try Int.fetchOne(
            database,
            sql: """
                SELECT sourceGeneration
                FROM derivedMaintenanceSource
                WHERE kind = 'meeting-memory-graph'
                """) ?? 0
    }
    let timestamp = Date(timeIntervalSince1970: 1_787_030_000)
        .addingTimeInterval(TimeInterval(sourceGeneration))
    _ = try await store.admitMeetingMemoryGraphMaintenance(
        at: timestamp)
    let job = try await store.claimMeetingMemoryGraphMaintenance(
        owner: owner,
        leaseDuration: 120,
        at: timestamp)
    guard let job else {
        throw StorageError.invalidDerivedMaintenanceJob(
            "graph query fixture could not claim projection")
    }
    let result = try await ProjectMeetingMemoryGraph(
        store: store,
        now: { timestamp }).all(
        job: job,
        owner: owner)
    _ = try await store.completeMeetingMemoryGraphMaintenance(
        job.id,
        owner: owner,
        at: timestamp)
    return result
}
