import ApplicationKit
import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class PersonCommitmentsQueryTests: XCTestCase {
    private static let baseDate = Date(timeIntervalSince1970: 1_787_120_000)

    func testInvalidQueryAndUnreadyProjectionAbstain() async throws {
        let fixture = try await personCommitmentFixture(commitmentCount: 1)

        let invalid = try await fixture.store.personCommitmentFacts(
            PersonCommitmentsQuery(personID: fixture.person.id, itemLimit: 0))
        let unready = try await fixture.store.personCommitmentFacts(
            PersonCommitmentsQuery(personID: fixture.person.id))

        XCTAssertEqual(invalid, .abstained(.invalidQuery))
        XCTAssertEqual(unready, .abstained(.projectionNotReady))
    }

    func testUnavailablePersonAbstainsAfterProjectionIsReady() async throws {
        let fixture = try await personCommitmentFixture(commitmentCount: 1)
        _ = try await projectPersonCommitmentGraph(in: fixture.store)

        let result = try await fixture.store.personCommitmentFacts(
            PersonCommitmentsQuery(personID: PersonID()))

        XCTAssertEqual(result, .abstained(.personUnavailable))
    }

    func testCurrentOwnedCommitmentHydratesTypedFactAndExactEvidence() async throws {
        let fixture = try await personCommitmentFixture(commitmentCount: 1)
        _ = try await projectPersonCommitmentGraph(in: fixture.store)

        let result = try await fixture.store.personCommitmentFacts(
            PersonCommitmentsQuery(personID: fixture.person.id))
        guard case .facts(let page) = result else {
            return XCTFail("Expected source-backed person commitments, got \(result)")
        }
        let fact = try XCTUnwrap(page.facts.first)

        XCTAssertEqual(page.facts.count, 1)
        XCTAssertFalse(page.hasMore)
        XCTAssertGreaterThan(page.projectionGeneration, 0)
        XCTAssertEqual(page.omittedStaleCount, 0)
        XCTAssertEqual(page.omittedUnavailableCount, 0)
        XCTAssertEqual(fact.id, .commitment(fixture.commitments[0].id))
        XCTAssertEqual(fact.kind, .personCommittedTo)
        XCTAssertEqual(fact.subject, .person(fixture.person.id))
        XCTAssertEqual(fact.object, .commitment(fixture.commitments[0].id))
        XCTAssertEqual(fact.subjectText, "Mara")
        XCTAssertEqual(fact.objectText, "Deliver checklist 1")
        XCTAssertEqual(fact.status, .active)
        XCTAssertEqual(fact.evidence.map(\.segmentID), [fixture.segments[0].id])
        XCTAssertEqual(fact.navigation?.meetingID, fixture.meeting.id)
        XCTAssertEqual(fact.navigation?.segmentID, fixture.segments[0].id)
    }

    func testCompletedCommitmentIsNotReturnedAsCurrentWork() async throws {
        let fixture = try await personCommitmentFixture(commitmentCount: 1)
        _ = try await fixture.store.applyCommitmentTransition(
            .complete,
            to: fixture.commitments[0].id,
            evidence: CommitmentEventEvidence(
                meetingID: fixture.meeting.id,
                sourceTranscriptRevision: fixture.meeting.transcriptRevision,
                segmentIDs: [fixture.segments[0].id]),
            at: Self.baseDate.addingTimeInterval(20))
        _ = try await projectPersonCommitmentGraph(in: fixture.store)

        let result = try await fixture.store.personCommitmentFacts(
            PersonCommitmentsQuery(personID: fixture.person.id))

        XCTAssertEqual(result, .abstained(.noActiveCommitments))
    }

    func testReassignedCommitmentUsesCurrentAssignmentAsPrimaryEvidence() async throws {
        let fixture = try await personCommitmentFixture(commitmentCount: 1)
        let target = try await reassignmentTarget(in: fixture.store)
        let reassignedAt = Self.baseDate.addingTimeInterval(200)
        _ = try await fixture.store.applyCommitmentTransition(
            .reassign(.person(target.person.id)),
            to: fixture.commitments[0].id,
            evidence: target.evidence,
            at: reassignedAt)
        _ = try await projectPersonCommitmentGraph(in: fixture.store)

        let result = try await fixture.store.personCommitmentFacts(
            PersonCommitmentsQuery(personID: target.person.id))
        guard case .facts(let page) = result else {
            return XCTFail("Expected reassigned commitment, got \(result)")
        }
        let fact = try XCTUnwrap(page.facts.first)

        XCTAssertEqual(fact.subject, .person(target.person.id))
        XCTAssertEqual(fact.subjectText, "Noah")
        XCTAssertEqual(fact.occurredAt, reassignedAt)
        XCTAssertEqual(fact.evidence.map(\.segmentID), [
            target.segment.id,
            fixture.segments[0].id,
        ])
        XCTAssertEqual(fact.primaryEvidenceSegmentID, target.segment.id)
        XCTAssertEqual(fact.navigation?.meetingID, target.meeting.id)
        XCTAssertEqual(fact.navigation?.segmentID, target.segment.id)

        let formerOwner = try await fixture.store.personCommitmentFacts(
            PersonCommitmentsQuery(personID: fixture.person.id))
        XCTAssertEqual(formerOwner, .abstained(.noActiveCommitments))
    }

    func testReassignmentWithoutEvidenceDoesNotBorrowOriginalOwnerSource() async throws {
        let fixture = try await personCommitmentFixture(commitmentCount: 1)
        let target = try await reassignmentTarget(in: fixture.store)
        _ = try await fixture.store.applyCommitmentTransition(
            .reassign(.person(target.person.id)),
            to: fixture.commitments[0].id,
            at: Self.baseDate.addingTimeInterval(200))
        _ = try await projectPersonCommitmentGraph(in: fixture.store)

        let result = try await fixture.store.personCommitmentFacts(
            PersonCommitmentsQuery(personID: target.person.id))

        XCTAssertEqual(result, .abstained(.evidenceUnavailable))
    }

    func testStaleReassignmentEvidenceFailsClosed() async throws {
        let fixture = try await personCommitmentFixture(commitmentCount: 1)
        let target = try await reassignmentTarget(in: fixture.store)
        _ = try await fixture.store.applyCommitmentTransition(
            .reassign(.person(target.person.id)),
            to: fixture.commitments[0].id,
            evidence: target.evidence,
            at: Self.baseDate.addingTimeInterval(200))
        var changedMeeting = target.meeting
        changedMeeting.transcriptRevision += 1
        try await fixture.store.save(changedMeeting)
        _ = try await projectPersonCommitmentGraph(in: fixture.store)

        let result = try await fixture.store.personCommitmentFacts(
            PersonCommitmentsQuery(personID: target.person.id))

        XCTAssertEqual(result, .abstained(.staleEvidenceOnly))
    }

    func testMissingDerivedOwnershipEdgeFailsAsProjectionInconsistency() async throws {
        let fixture = try await personCommitmentFixture(commitmentCount: 2)
        _ = try await projectPersonCommitmentGraph(in: fixture.store)
        try await fixture.store.database.write { database in
            try database.execute(
                sql: """
                    DELETE FROM meetingMemoryGraphCommitmentPerson
                    WHERE personID = ? AND commitmentID = ?
                    """,
                arguments: [
                    fixture.person.id.rawValue.uuidString,
                    fixture.commitments[0].id.rawValue.uuidString,
                ])
        }

        let result = try await fixture.store.personCommitmentFacts(
            PersonCommitmentsQuery(personID: fixture.person.id))

        XCTAssertEqual(result, .abstained(.projectionInconsistent))
    }

    func testStaleSourceEvidenceFailsClosed() async throws {
        let fixture = try await personCommitmentFixture(commitmentCount: 1)
        var changedMeeting = fixture.meeting
        changedMeeting.transcriptRevision += 1
        try await fixture.store.save(changedMeeting)
        _ = try await projectPersonCommitmentGraph(in: fixture.store)

        let result = try await fixture.store.personCommitmentFacts(
            PersonCommitmentsQuery(personID: fixture.person.id))

        XCTAssertEqual(result, .abstained(.staleEvidenceOnly))
    }

    func testBoundedPageKeepsNewestAuthoritativeCommitmentFirst() async throws {
        let fixture = try await personCommitmentFixture(commitmentCount: 2)
        _ = try await projectPersonCommitmentGraph(in: fixture.store)

        let result = try await fixture.store.personCommitmentFacts(
            PersonCommitmentsQuery(
                personID: fixture.person.id,
                itemLimit: 1))
        guard case .facts(let page) = result else {
            return XCTFail("Expected a bounded commitment page, got \(result)")
        }

        XCTAssertEqual(page.facts.map(\.id), [
            .commitment(fixture.commitments[1].id),
        ])
        XCTAssertTrue(page.hasMore)
    }

    func testApplicationUseCasePreservesTypedRepositoryResult() async throws {
        let personID = PersonID()
        let expected = MeetingMemoryGraphQueryResult.abstained(
            .noActiveCommitments)
        let repository = PersonCommitmentRepositoryStub(result: expected)

        let result = try await LoadPersonCommitments(repository: repository)
            .execute(PersonCommitmentsQuery(personID: personID))

        XCTAssertEqual(result, expected)
        let received = await repository.receivedQuery
        XCTAssertEqual(received, PersonCommitmentsQuery(personID: personID))
    }

    func testAliasLookupRejectsInvalidAndMissingIdentityBeforeFactRead() async throws {
        let people = PersonCandidateRepositoryStub(candidates: [])
        let commitments = PersonCommitmentRepositoryStub(
            result: .abstained(.projectionNotReady))
        let useCase = LoadPersonCommitmentsByAlias(
            people: people,
            commitments: commitments)

        let invalid = try await useCase.execute(PersonCommitmentsAliasQuery(
            alias: "   "))
        let missing = try await useCase.execute(PersonCommitmentsAliasQuery(
            alias: "Unknown"))
        let receivedAliases = await people.receivedAliases
        let commitmentCallCount = await commitments.callCount

        XCTAssertEqual(invalid, .abstained(.invalidQuery))
        XCTAssertEqual(missing, .abstained(.personUnavailable))
        XCTAssertEqual(receivedAliases, ["Unknown"])
        XCTAssertEqual(commitmentCallCount, 0)
    }

    func testAmbiguousAliasAbstainsBeforeExactPersonFactRead() async throws {
        let people = PersonCandidateRepositoryStub(candidates: [
            Person(preferredName: "Alex"),
            Person(preferredName: "Alex"),
        ])
        let commitments = PersonCommitmentRepositoryStub(
            result: .abstained(.projectionNotReady))

        let result = try await LoadPersonCommitmentsByAlias(
            people: people,
            commitments: commitments
        ).execute(PersonCommitmentsAliasQuery(alias: "ÁLEX"))
        let receivedAliases = await people.receivedAliases
        let commitmentCallCount = await commitments.callCount

        XCTAssertEqual(result, .abstained(.ambiguousPerson))
        XCTAssertEqual(receivedAliases, ["ÁLEX"])
        XCTAssertEqual(commitmentCallCount, 0)
    }

    func testUniqueAliasDelegatesExactPersonAndLimit() async throws {
        let person = Person(preferredName: "Mara")
        let people = PersonCandidateRepositoryStub(candidates: [person])
        let expected = MeetingMemoryGraphQueryResult.abstained(
            .noActiveCommitments)
        let commitments = PersonCommitmentRepositoryStub(result: expected)

        let result = try await LoadPersonCommitmentsByAlias(
            people: people,
            commitments: commitments
        ).execute(PersonCommitmentsAliasQuery(alias: "mára", itemLimit: 7))
        let receivedAliases = await people.receivedAliases
        let receivedQuery = await commitments.receivedQuery
        let commitmentCallCount = await commitments.callCount

        XCTAssertEqual(result, expected)
        XCTAssertEqual(receivedAliases, ["mára"])
        XCTAssertEqual(
            receivedQuery,
            PersonCommitmentsQuery(personID: person.id, itemLimit: 7))
        XCTAssertEqual(commitmentCallCount, 1)
    }

    private func personCommitmentFixture(
        commitmentCount: Int
    ) async throws -> PersonCommitmentFixture {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Atlas planning", startedAt: Self.baseDate)
        let speaker = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: "Mara")
        var segments: [TranscriptSegment] = []
        for index in 0..<max(commitmentCount, 1) {
            let number = index + 1
            let start = TimeInterval(index * 2 + 1)
            segments.append(TranscriptSegment(
                meetingID: meeting.id,
                speakerID: speaker.id,
                channel: .system,
                text: "Mara will deliver checklist \(number).",
                language: "en",
                startTime: start,
                endTime: start + 1,
                isFinal: true))
        }
        try await store.save(meeting)
        try await store.save([speaker])
        try await store.save(segments)
        let link = try await store.createPersonAndLink(
            speakerID: speaker.id,
            preferredName: "Mara",
            source: .manualName)

        let actionItems = (0..<commitmentCount).map { index in
            ActionItem(
                text: "Deliver checklist \(index + 1)",
                ownerSpeakerID: speaker.id)
        }
        if !actionItems.isEmpty {
            _ = try await store.saveSummary(SummaryDraft(
                meetingID: meeting.id,
                recipeID: Recipe.general.id,
                language: "en",
                markdown: "Mara owns the rollout checklists.",
                actionItems: actionItems,
                actionItemEvidence: zip(actionItems, segments).map { item, segment in
                    SummaryActionItemEvidence(
                        actionItemID: item.id,
                        evidenceSegmentIDs: [segment.id])
                }))
        }
        var commitments: [Commitment] = []
        for (index, actionItem) in actionItems.enumerated() {
            let envelope = try await store.confirmCommitment(
                CommitmentConfirmation(
                    title: actionItem.text,
                    assignee: .person(link.person.id),
                    origin: .generatedActionItem(actionItem.id)),
                at: Self.baseDate.addingTimeInterval(Double(index + 10)))
            commitments.append(envelope.commitment)
        }
        return PersonCommitmentFixture(
            store: store,
            meeting: meeting,
            person: link.person,
            segments: segments,
            commitments: commitments)
    }

    private func reassignmentTarget(
        in store: MeetingStore
    ) async throws -> PersonReassignmentTarget {
        let meeting = Meeting(
            title: "Atlas ownership follow-up",
            startedAt: Self.baseDate.addingTimeInterval(100))
        let speaker = Speaker(
            meetingID: meeting.id,
            label: "S2",
            displayName: "Noah")
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: "Noah will own the rollout checklist now.",
            language: "en",
            startTime: 3,
            endTime: 6,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([speaker])
        try await store.save([segment])
        let link = try await store.createPersonAndLink(
            speakerID: speaker.id,
            preferredName: "Noah",
            source: .manualName)
        return PersonReassignmentTarget(
            meeting: meeting,
            person: link.person,
            segment: segment,
            evidence: CommitmentEventEvidence(
                meetingID: meeting.id,
                sourceTranscriptRevision: meeting.transcriptRevision,
                segmentIDs: [segment.id]))
    }
}

private struct PersonCommitmentFixture {
    let store: MeetingStore
    let meeting: Meeting
    let person: Person
    let segments: [TranscriptSegment]
    let commitments: [Commitment]
}

private struct PersonReassignmentTarget {
    let meeting: Meeting
    let person: Person
    let segment: TranscriptSegment
    let evidence: CommitmentEventEvidence
}

private actor PersonCommitmentRepositoryStub: PersonCommitmentFactReading {
    let result: MeetingMemoryGraphQueryResult
    private(set) var receivedQuery: PersonCommitmentsQuery?
    private(set) var callCount = 0

    init(result: MeetingMemoryGraphQueryResult) {
        self.result = result
    }

    func personCommitmentFacts(
        _ query: PersonCommitmentsQuery
    ) -> MeetingMemoryGraphQueryResult {
        callCount += 1
        receivedQuery = query
        return result
    }
}

private actor PersonCandidateRepositoryStub: CanonicalPersonCandidateReading {
    let candidates: [Person]
    private(set) var receivedAliases: [String] = []

    init(candidates: [Person]) {
        self.candidates = candidates
    }

    func people(matchingAlias alias: String) -> [Person] {
        receivedAliases.append(alias)
        return candidates
    }
}

@discardableResult
private func projectPersonCommitmentGraph(
    in store: MeetingStore
) async throws -> MeetingMemoryGraphProjectionResult {
    let owner = "person-commitment-query-test-\(UUID().uuidString)"
    let sourceGeneration = try await store.database.read { database in
        try Int.fetchOne(
            database,
            sql: """
                SELECT sourceGeneration
                FROM derivedMaintenanceSource
                WHERE kind = 'meeting-memory-graph'
                """) ?? 0
    }
    let timestamp = Date(timeIntervalSince1970: 1_787_130_000)
        .addingTimeInterval(TimeInterval(sourceGeneration))
    _ = try await store.admitMeetingMemoryGraphMaintenance(at: timestamp)
    let job = try await store.claimMeetingMemoryGraphMaintenance(
        owner: owner,
        leaseDuration: 120,
        at: timestamp)
    guard let job else {
        throw StorageError.invalidDerivedMaintenanceJob(
            "person commitment fixture could not claim projection")
    }
    let result = try await ProjectMeetingMemoryGraph(
        store: store,
        now: { timestamp }).all(job: job, owner: owner)
    _ = try await store.completeMeetingMemoryGraphMaintenance(
        job.id,
        owner: owner,
        at: timestamp)
    return result
}
