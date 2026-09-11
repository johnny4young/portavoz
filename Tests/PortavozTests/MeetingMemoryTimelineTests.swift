import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class MeetingMemoryTimelineTests: XCTestCase {
    private static let baseDate = Date(timeIntervalSince1970: 1_786_700_000)

    func testTopicTimelineReturnsOnlyConfirmedCurrentFactsWithExactNavigation() async throws {
        let fixture = try await seededTimelineFixture(projectGraph: true)

        let result = try await fixture.store.meetingMemoryTimeline(
            MeetingMemoryTimelineQuery(
                subject: .topic(fixture.topicID),
                throughMeetingID: fixture.through.id))
        guard case .timeline(let page) = result else {
            return XCTFail("Expected a source-backed topic timeline, got \(result)")
        }

        XCTAssertEqual(page.subject, .topic(fixture.topicID))
        XCTAssertEqual(page.baseline.id, fixture.baseline.id)
        XCTAssertEqual(page.through.id, fixture.through.id)
        XCTAssertEqual(page.items.map(\.kind), [
            .commitmentConfirmed,
            .decisionSuperseded,
            .decisionConfirmed,
        ])
        XCTAssertEqual(page.items.map(\.origin), [.confirmed, .confirmed, .confirmed])
        XCTAssertEqual(page.items[0].navigation?.segmentID, fixture.commitmentSegment.id)
        XCTAssertEqual(page.items[0].navigation?.timestamp, fixture.commitmentSegment.startTime)
        XCTAssertEqual(page.items[1].evidence.map(\.segmentID), [
            fixture.baselineDecisionSegment.id,
            fixture.throughDecisionSegment.id,
        ])
        XCTAssertEqual(page.items[1].relatedText, "Ship every ten minutes.")
        XCTAssertEqual(page.items[2].evidence.map(\.text), [
            fixture.throughDecisionSegment.text,
        ])
        XCTAssertEqual(page.omittedStaleCount, 0)
        XCTAssertEqual(page.omittedUnavailableCount, 0)
        XCTAssertTrue(page.unsupportedKinds.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertGreaterThan(page.projectionGeneration, 0)
    }

    func testPersonTimelineUsesOwnedCommitmentsWithoutAttributingMeetingDecisions() async throws {
        let fixture = try await seededTimelineFixture(projectGraph: true)

        let result = try await fixture.store.meetingMemoryTimeline(
            MeetingMemoryTimelineQuery(
                subject: .person(fixture.personID),
                throughMeetingID: fixture.through.id))
        guard case .timeline(let page) = result else {
            return XCTFail("Expected a source-backed person timeline, got \(result)")
        }

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.kind, .commitmentConfirmed)
        XCTAssertEqual(page.items.first?.entity, .commitment(fixture.commitmentID))
        XCTAssertFalse(page.items.contains(where: {
            if case .decision = $0.entity { return true }
            return false
        }))
        XCTAssertTrue(page.unsupportedKinds.contains(.unresolvedQuestion))
        XCTAssertTrue(page.unsupportedKinds.contains(.questionResolved))
    }

    func testTimelineServesOnlyExactEvidenceForMeetingScopedCommitmentChanges() async throws {
        let fixture = try await seededTimelineFixture(projectGraph: true)
        let dueAt = Self.baseDate.addingTimeInterval(172_800)
        _ = try await fixture.store.applyCommitmentTransition(
            .reschedule(dueAt),
            to: fixture.commitmentID,
            evidence: CommitmentEventEvidence(
                meetingID: fixture.through.id,
                sourceTranscriptRevision: fixture.through.transcriptRevision,
                segmentIDs: [fixture.commitmentChangeSegment.id]),
            at: fixture.through.startedAt.addingTimeInterval(50))

        let result = try await fixture.store.meetingMemoryTimeline(
            MeetingMemoryTimelineQuery(
                subject: .topic(fixture.topicID),
                throughMeetingID: fixture.through.id))
        guard case .timeline(let page) = result else {
            return XCTFail("Expected a source-backed commitment change, got \(result)")
        }

        let item = try XCTUnwrap(page.items.first(where: {
            $0.kind == .commitmentRescheduled
        }))
        XCTAssertEqual(item.commitmentChange, .rescheduled(dueAt))
        XCTAssertEqual(item.navigation?.segmentID, fixture.commitmentChangeSegment.id)
        XCTAssertFalse(page.unsupportedKinds.contains(.commitmentRescheduled))

        _ = try await fixture.store.appendTranscriptCorrection(TranscriptCorrectionEvent(
            meetingID: fixture.through.id,
            baseTranscriptRevision: fixture.through.transcriptRevision,
            targetSegmentIDs: [fixture.commitmentChangeSegment.id],
            kind: .replaceText(text: "Move the release notes deadline to Monday.", language: "en"),
            sourceDeviceID: UUID(),
            createdAt: fixture.through.startedAt.addingTimeInterval(60)))
        let correctedResult = try await fixture.store.meetingMemoryTimeline(
            MeetingMemoryTimelineQuery(
                subject: .topic(fixture.topicID),
                throughMeetingID: fixture.through.id))
        guard case .timeline(let correctedPage) = correctedResult else {
            return XCTFail("Expected remaining current facts, got \(correctedResult)")
        }
        XCTAssertFalse(correctedPage.items.contains(where: {
            $0.kind == .commitmentRescheduled
        }))
        XCTAssertGreaterThan(correctedPage.omittedUnavailableCount, 0)
    }

    func testTopicTimelineServesExplicitQuestionLifecycleWithoutCompanionPromotion()
        async throws {
        let fixture = try await seededTimelineFixture(projectGraph: true)
        let questionID = MeetingQuestionID()
        _ = try await fixture.store.confirmMeetingQuestion(
            MeetingQuestionConfirmation(
                questionID: questionID,
                topicID: fixture.topicID,
                text: "Which rollout policy remains open?",
                evidence: MeetingQuestionEvidence(
                    meetingID: fixture.through.id,
                    sourceTranscriptRevision: fixture.through.transcriptRevision,
                    segmentIDs: [fixture.throughDecisionSegment.id]),
                confirmedAt: fixture.through.startedAt.addingTimeInterval(70)))
        _ = try await fixture.store.applyMeetingQuestionTransition(
            MeetingQuestionTransitionConfirmation(
                questionID: questionID,
                transition: .resolve,
                evidence: MeetingQuestionEvidence(
                    meetingID: fixture.through.id,
                    sourceTranscriptRevision: fixture.through.transcriptRevision,
                    segmentIDs: [fixture.commitmentChangeSegment.id]),
                confirmedAt: fixture.through.startedAt.addingTimeInterval(75)))
        try await projectAll(in: fixture.store)

        let result = try await fixture.store.meetingMemoryTimeline(
            MeetingMemoryTimelineQuery(
                subject: .topic(fixture.topicID),
                throughMeetingID: fixture.through.id))
        guard case .timeline(let page) = result else {
            return XCTFail("Expected question lifecycle facts, got \(result)")
        }
        let questionItems = page.items.filter {
            $0.entity == .question(questionID)
        }
        XCTAssertEqual(questionItems.map(\.kind), [
            .questionResolved,
            .unresolvedQuestion,
        ])
        XCTAssertEqual(questionItems.map(\.questionChange), [.resolved, .opened])
        XCTAssertEqual(
            questionItems.map { $0.navigation?.segmentID },
            [fixture.commitmentChangeSegment.id, fixture.throughDecisionSegment.id])
        XCTAssertFalse(page.unsupportedKinds.contains(.unresolvedQuestion))
        XCTAssertFalse(page.unsupportedKinds.contains(.commitmentBlocked))
    }

    func testTimelineServesExplicitBlockerLifecycleWithExactNavigation() async throws {
        let fixture = try await seededTimelineFixture(projectGraph: false)
        let blockerID = DecisionCommitmentBlockerID()
        _ = try await fixture.store.confirmDecisionCommitmentBlocker(
            DecisionCommitmentBlockerConfirmation(
                blockerID: blockerID,
                decisionID: fixture.newDecisionID,
                commitmentID: fixture.commitmentID,
                evidence: DecisionCommitmentBlockerEvidence(
                    meetingID: fixture.through.id,
                    sourceTranscriptRevision: fixture.through.transcriptRevision,
                    segmentIDs: [fixture.throughDecisionSegment.id]),
                confirmedAt: fixture.through.startedAt.addingTimeInterval(70)))
        _ = try await fixture.store.applyDecisionCommitmentBlockerTransition(
            DecisionBlockerTransitionConfirmation(
                blockerID: blockerID,
                transition: .clear,
                evidence: DecisionCommitmentBlockerEvidence(
                    meetingID: fixture.through.id,
                    sourceTranscriptRevision: fixture.through.transcriptRevision,
                    segmentIDs: [fixture.commitmentChangeSegment.id]),
                confirmedAt: fixture.through.startedAt.addingTimeInterval(71)))
        _ = try await fixture.store.applyDecisionCommitmentBlockerTransition(
            DecisionBlockerTransitionConfirmation(
                blockerID: blockerID,
                transition: .reopen,
                evidence: DecisionCommitmentBlockerEvidence(
                    meetingID: fixture.through.id,
                    sourceTranscriptRevision: fixture.through.transcriptRevision,
                    segmentIDs: [fixture.commitmentSegment.id]),
                confirmedAt: fixture.through.startedAt.addingTimeInterval(72)))
        try await projectAll(in: fixture.store)

        let result = try await fixture.store.meetingMemoryTimeline(
            MeetingMemoryTimelineQuery(
                subject: .topic(fixture.topicID),
                throughMeetingID: fixture.through.id))
        guard case .timeline(let page) = result else {
            return XCTFail("Expected blocker lifecycle facts, got \(result)")
        }
        let blockerItems = page.items.filter { $0.blockerChange != nil }
        XCTAssertEqual(blockerItems.map(\.kind), [
            .commitmentBlockerReopened,
            .commitmentUnblocked,
            .commitmentBlocked
        ])
        XCTAssertEqual(blockerItems.map(\.blockerChange), [
            .reopened,
            .cleared,
            .blocked
        ])
        XCTAssertEqual(
            blockerItems.map { $0.navigation?.segmentID },
            [
                fixture.commitmentSegment.id,
                fixture.commitmentChangeSegment.id,
                fixture.throughDecisionSegment.id
            ])
        XCTAssertTrue(blockerItems.allSatisfy {
            $0.entity == .commitment(fixture.commitmentID)
                && $0.relatedEntity == .decision(fixture.newDecisionID)
        })
        XCTAssertFalse(page.unsupportedKinds.contains(.commitmentBlocked))
        XCTAssertFalse(page.unsupportedKinds.contains(.commitmentUnblocked))
        XCTAssertFalse(page.unsupportedKinds.contains(.commitmentBlockerReopened))

        let personResult = try await fixture.store.meetingMemoryTimeline(
            MeetingMemoryTimelineQuery(
                subject: .person(fixture.personID),
                throughMeetingID: fixture.through.id))
        guard case .timeline(let personPage) = personResult else {
            return XCTFail("Expected person blocker lifecycle facts, got \(personResult)")
        }
        let personBlockerItems = personPage.items.filter { $0.blockerChange != nil }
        XCTAssertEqual(personBlockerItems.map(\.kind), blockerItems.map(\.kind))
        XCTAssertEqual(
            personBlockerItems.map { $0.navigation?.segmentID },
            blockerItems.map { $0.navigation?.segmentID })
    }

    func testTimelineReportsLegacyCommitmentChangesWithoutExactEvidenceAsUnsupported()
        async throws {
        let fixture = try await seededTimelineFixture(projectGraph: true)
        _ = try await fixture.store.applyCommitmentTransition(
            .reschedule(Self.baseDate.addingTimeInterval(172_800)),
            to: fixture.commitmentID,
            sourceMeetingID: fixture.through.id,
            at: fixture.through.startedAt.addingTimeInterval(50))

        let result = try await fixture.store.meetingMemoryTimeline(
            MeetingMemoryTimelineQuery(
                subject: .topic(fixture.topicID),
                throughMeetingID: fixture.through.id))
        guard case .timeline(let page) = result else {
            return XCTFail("Expected an honest partial timeline, got \(result)")
        }

        XCTAssertFalse(page.items.contains(where: {
            $0.kind == .commitmentRescheduled
        }))
        XCTAssertTrue(page.unsupportedKinds.contains(.commitmentRescheduled))
    }

    func testTimelineAbstainsUntilProjectionIsReadyAndForInvalidAnchors() async throws {
        let fixture = try await seededTimelineFixture(projectGraph: false)
        let query = MeetingMemoryTimelineQuery(
            subject: .topic(fixture.topicID),
            throughMeetingID: fixture.through.id)

        let unprojectedResult = try await fixture.store.meetingMemoryTimeline(query)
        XCTAssertEqual(unprojectedResult, .abstained(.projectionNotReady))

        try await projectAll(in: fixture.store)
        let missingBaselineResult = try await fixture.store.meetingMemoryTimeline(
            MeetingMemoryTimelineQuery(
                subject: .topic(fixture.topicID),
                throughMeetingID: fixture.baseline.id))
        XCTAssertEqual(missingBaselineResult, .abstained(.missingTemporalBaseline))

        let unrelatedAnchorResult = try await fixture.store.meetingMemoryTimeline(
            MeetingMemoryTimelineQuery(
                subject: .topic(fixture.topicID),
                throughMeetingID: MeetingID()))
        XCTAssertEqual(unrelatedAnchorResult, .abstained(.anchorNotRelated))

        let invalidQueryResult = try await fixture.store.meetingMemoryTimeline(
            MeetingMemoryTimelineQuery(
                subject: .topic(fixture.topicID),
                itemLimit: 0))
        XCTAssertEqual(invalidQueryResult, .abstained(.invalidQuery))
    }

    func testTimelineRehydratesCorrectionFreshnessAndAbstainsFromStaleOnlyFacts() async throws {
        let fixture = try await seededTimelineFixture(projectGraph: true)
        try await fixture.store.database.write { database in
            try database.execute(
                sql: "UPDATE meeting SET transcriptRevision = 1 WHERE id = ?",
                arguments: [fixture.through.id.rawValue.uuidString])
        }
        try await projectAll(in: fixture.store)

        let result = try await fixture.store.meetingMemoryTimeline(
            MeetingMemoryTimelineQuery(
                subject: .topic(fixture.topicID),
                throughMeetingID: fixture.through.id))

        XCTAssertEqual(result, .abstained(.staleEvidenceOnly))
    }

    func testTimelinePrefersCurrentSameMeetingEvidenceOverAnOlderStaleSource() async throws {
        let fixture = try await seededTimelineFixture(projectGraph: true)
        try await fixture.store.database.write { database in
            try database.execute(
                sql: "UPDATE meeting SET transcriptRevision = 1 WHERE id = ?",
                arguments: [fixture.baseline.id.rawValue.uuidString])
            let currentSource = DecisionSource(
                decisionID: fixture.oldDecisionID,
                observationID: SummaryDecisionID(),
                summaryID: SummaryID(),
                meetingID: fixture.baseline.id,
                observedStatement: "Ship every hour.",
                sourceTranscriptRevision: 1,
                observedAt: fixture.baseline.startedAt,
                linkedAt: fixture.baseline.startedAt.addingTimeInterval(40),
                evidence: [DecisionEvidenceSegment(
                    segmentID: fixture.baselineDecisionSegment.id,
                    ordinal: 0)],
                availability: .current)
            try DecisionContinuitySourceRecord(currentSource).insert(database)
            try DecisionContinuityEvidenceSegmentRecord(
                sourceID: currentSource.id,
                evidence: currentSource.evidence[0])
                .insert(database)
        }
        try await projectAll(in: fixture.store)

        let result = try await fixture.store.meetingMemoryTimeline(
            MeetingMemoryTimelineQuery(
                subject: .topic(fixture.topicID),
                throughMeetingID: fixture.through.id))
        guard case .timeline(let page) = result else {
            return XCTFail("Expected a current timeline, got \(result)")
        }

        XCTAssertEqual(page.items.map(\.kind), [
            .commitmentConfirmed,
            .decisionSuperseded,
            .decisionConfirmed,
        ])
        XCTAssertEqual(page.omittedStaleCount, 0)
        XCTAssertEqual(page.items[1].evidence.first?.transcriptRevision, 1)
    }

    func testTimelineUsesDeterministicNewestFirstLimit() async throws {
        let fixture = try await seededTimelineFixture(projectGraph: true)

        let result = try await fixture.store.meetingMemoryTimeline(
            MeetingMemoryTimelineQuery(
                subject: .topic(fixture.topicID),
                throughMeetingID: fixture.through.id,
                itemLimit: 2))
        guard case .timeline(let page) = result else {
            return XCTFail("Expected a bounded timeline, got \(result)")
        }

        XCTAssertEqual(page.items.map(\.kind), [
            .commitmentConfirmed,
            .decisionSuperseded,
        ])
        XCTAssertTrue(page.hasMore)
    }

    func testApplicationUseCaseDelegatesExactIdentityQuery() async throws {
        let expected = MeetingMemoryTimelineResult.abstained(.projectionNotReady)
        let repository = TimelineRepositoryStub(result: expected)
        let query = MeetingMemoryTimelineQuery(subject: .person(PersonID()))

        let actual = try await LoadMeetingMemoryTimeline(repository: repository)
            .execute(query)
        let received = await repository.receivedQuery()

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(received, query)
    }

    private struct TimelineFixture {
        let store: MeetingStore
        let baseline: Meeting
        let through: Meeting
        let personID: PersonID
        let topicID: TopicID
        let oldDecisionID: DecisionID
        let newDecisionID: DecisionID
        let commitmentID: CommitmentID
        let baselineDecisionSegment: TranscriptSegment
        let throughDecisionSegment: TranscriptSegment
        let commitmentSegment: TranscriptSegment
        let commitmentChangeSegment: TranscriptSegment
    }

    private func seededTimelineFixture(
        projectGraph: Bool
    ) async throws -> TimelineFixture {
        let store = try MeetingStore.inMemory()
        let baseline = Meeting(title: "Atlas baseline", startedAt: Self.baseDate)
        let through = Meeting(
            title: "Atlas follow-up",
            startedAt: Self.baseDate.addingTimeInterval(3_600))
        let baselineSpeaker = Speaker(meetingID: baseline.id, label: "S1")
        let throughSpeaker = Speaker(meetingID: through.id, label: "S1")
        let baselineDecisionSegment = TranscriptSegment(
            meetingID: baseline.id,
            speakerID: baselineSpeaker.id,
            channel: .system,
            text: "Ship every hour.",
            language: "en",
            startTime: 1,
            endTime: 3,
            isFinal: true)
        let throughDecisionSegment = TranscriptSegment(
            meetingID: through.id,
            speakerID: throughSpeaker.id,
            channel: .system,
            text: "Ship every ten minutes instead.",
            language: "en",
            startTime: 5,
            endTime: 8,
            isFinal: true)
        let commitmentSegment = TranscriptSegment(
            meetingID: through.id,
            speakerID: throughSpeaker.id,
            channel: .system,
            text: "Ana will prepare the release notes.",
            language: "en",
            startTime: 10,
            endTime: 13,
            isFinal: true)
        let commitmentChangeSegment = TranscriptSegment(
            meetingID: through.id,
            speakerID: throughSpeaker.id,
            channel: .system,
            text: "Move the release notes deadline to Friday.",
            language: "en",
            startTime: 14,
            endTime: 17,
            isFinal: true)

        try await store.save(baseline)
        try await store.save(through)
        try await store.save([baselineSpeaker, throughSpeaker])
        try await store.save([
            baselineDecisionSegment,
            throughDecisionSegment,
            commitmentSegment,
            commitmentChangeSegment
        ])
        let person = try await store.createPersonAndLink(
            speakerID: baselineSpeaker.id,
            preferredName: "Ana",
            source: .manualName)
        _ = try await store.linkSpeaker(
            throughSpeaker.id,
            to: person.person.id,
            observedAlias: "Ana",
            source: .manualName)

        let topic = try await store.createTopicAndLink(TopicLinkProposal(
            meetingID: baseline.id,
            segmentID: baselineDecisionSegment.id,
            sourceTranscriptRevision: baseline.transcriptRevision,
            observedLabel: "Atlas release",
            language: "en",
            origin: .manual))
        _ = try await store.linkTopic(
            TopicLinkProposal(
                meetingID: through.id,
                segmentID: throughDecisionSegment.id,
                sourceTranscriptRevision: through.transcriptRevision,
                observedLabel: "Atlas release",
                language: "en",
                origin: .manual),
            to: topic.topic.id)

        let oldDecisionID = DecisionID()
        let newDecisionID = DecisionID()
        let oldSourceID = DecisionSourceID()
        let newSourceID = DecisionSourceID()
        let relationshipID = DecisionEventID()
        let oldConfirmedAt = Self.baseDate.addingTimeInterval(20)
        let newConfirmedAt = through.startedAt.addingTimeInterval(20)
        let relationshipAt = through.startedAt.addingTimeInterval(30)
        let commitmentID = CommitmentID()
        try await store.database.write { database in
            try Self.insertDecision(
                id: oldDecisionID,
                sourceID: oldSourceID,
                statement: "Ship every hour.",
                meeting: baseline,
                segmentID: baselineDecisionSegment.id,
                confirmedAt: oldConfirmedAt,
                in: database)
            try Self.insertDecision(
                id: newDecisionID,
                sourceID: newSourceID,
                statement: "Ship every ten minutes.",
                meeting: through,
                segmentID: throughDecisionSegment.id,
                confirmedAt: newConfirmedAt,
                in: database)
            let relationship = DecisionEvent(
                id: relationshipID,
                decisionID: oldDecisionID,
                kind: .supersede,
                relatedDecisionID: newDecisionID,
                occurredAt: relationshipAt)
            try DecisionContinuityEventRecord(relationship).insert(database)
            try DecisionContinuityRecord(MeetingDecision(
                id: oldDecisionID,
                statement: "Ship every hour.",
                status: .superseded,
                createdAt: oldConfirmedAt,
                updatedAt: relationshipAt))
                .update(database)

            let commitmentEvent = CommitmentEvent(
                commitmentID: commitmentID,
                kind: .confirm,
                assignee: .person(person.person.id),
                sourceMeetingID: through.id,
                occurredAt: through.startedAt.addingTimeInterval(40))
            let commitment = try CommitmentContinuityPolicy.projectedCommitment(
                id: commitmentID,
                title: "Prepare the release notes",
                events: [commitmentEvent])
            let source = CommitmentSource(
                commitmentID: commitmentID,
                kind: .generatedActionItem,
                meetingID: through.id,
                actionItemID: UUID(),
                transcriptRevision: through.transcriptRevision,
                firstSeenAt: commitmentEvent.occurredAt,
                evidence: [CommitmentEvidenceSegment(
                    segmentID: commitmentSegment.id,
                    role: .promise,
                    ordinal: 0)])
            _ = try CommitmentContinuityEnvelope(
                commitment: commitment,
                sources: [source],
                events: [commitmentEvent])
            try CommitmentRecord(commitment).insert(database)
            try CommitmentSourceRecord(source).insert(database)
            try CommitmentEvidenceSegmentRecord(
                sourceID: source.id,
                evidence: source.evidence[0])
                .insert(database)
            try CommitmentEventRecord(commitmentEvent).insert(database)
        }
        if projectGraph { try await projectAll(in: store) }
        return TimelineFixture(
            store: store,
            baseline: baseline,
            through: through,
            personID: person.person.id,
            topicID: topic.topic.id,
            oldDecisionID: oldDecisionID,
            newDecisionID: newDecisionID,
            commitmentID: commitmentID,
            baselineDecisionSegment: baselineDecisionSegment,
            throughDecisionSegment: throughDecisionSegment,
            commitmentSegment: commitmentSegment,
            commitmentChangeSegment: commitmentChangeSegment)
    }

    private static func insertDecision(
        id: DecisionID,
        sourceID: DecisionSourceID,
        statement: String,
        meeting: Meeting,
        segmentID: UUID,
        confirmedAt: Date,
        in database: Database
    ) throws {
        let source = DecisionSource(
            id: sourceID,
            decisionID: id,
            observationID: SummaryDecisionID(),
            summaryID: SummaryID(),
            meetingID: meeting.id,
            observedStatement: statement,
            sourceTranscriptRevision: meeting.transcriptRevision,
            observedAt: meeting.startedAt,
            linkedAt: confirmedAt,
            evidence: [DecisionEvidenceSegment(segmentID: segmentID, ordinal: 0)],
            availability: .current)
        let event = DecisionEvent(
            decisionID: id,
            kind: .confirm,
            sourceID: sourceID,
            occurredAt: confirmedAt)
        let decision = MeetingDecision(
            id: id,
            statement: statement,
            status: .confirmed,
            createdAt: confirmedAt,
            updatedAt: confirmedAt)
        try DecisionContinuityRecord(decision).insert(database)
        try DecisionContinuitySourceRecord(source).insert(database)
        try DecisionContinuityEvidenceSegmentRecord(
            sourceID: sourceID,
            evidence: source.evidence[0])
            .insert(database)
        try DecisionContinuityEventRecord(event).insert(database)
    }

    @discardableResult
    private func projectAll(in store: MeetingStore) async throws
        -> MeetingMemoryGraphProjectionResult {
        let owner = "timeline-test-owner-\(UUID().uuidString)"
        let timestamp = Date()
        _ = try await store.admitMeetingMemoryGraphMaintenance(at: timestamp)
        let claimedJob = try await store.claimMeetingMemoryGraphMaintenance(
            owner: owner,
            leaseDuration: 120,
            at: timestamp)
        let job = try XCTUnwrap(claimedJob)
        let result = try await ProjectMeetingMemoryGraph(
            store: store,
            now: { timestamp }).all(
                job: job,
                owner: owner,
                batchSize: 128)
        _ = try await store.completeMeetingMemoryGraphMaintenance(
            job.id,
            owner: owner,
            at: timestamp)
        return result
    }
}

private actor TimelineRepositoryStub: MeetingMemoryTimelineReading {
    private let result: MeetingMemoryTimelineResult
    private var query: MeetingMemoryTimelineQuery?

    init(result: MeetingMemoryTimelineResult) {
        self.result = result
    }

    func meetingMemoryTimeline(
        _ query: MeetingMemoryTimelineQuery
    ) async throws -> MeetingMemoryTimelineResult {
        self.query = query
        return result
    }

    func receivedQuery() -> MeetingMemoryTimelineQuery? { query }
}
