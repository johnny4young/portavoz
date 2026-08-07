import ApplicationKit
import CryptoKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

/// GRAPH-5b: decisionConflicts and changeSince answer from explicitly
/// confirmed authority through public product boundaries. A generated note
/// that "guessed" a replacement is not a conflict, an unresolvable baseline
/// abstains rather than guessing, and every returned fact carries the exact
/// current source segments of both decisions in the relationship.
final class DecisionRelationshipProductConformanceTests: XCTestCase {
    func testCanonicalDecisionConflictCasesTraverseProductPath() async throws {
        let fixture = try RelationshipFixtureDocument.load()
        let cases = fixture.cases.filter { $0.job == "decisionConflicts" }

        XCTAssertEqual(fixture.kind, "meeting-memory-graph-query-fixture")
        XCTAssertEqual(cases.count, 6)
        XCTAssertEqual(
            Set(cases.map(\.relationship)),
            [
                "englishToEnglish", "spanishToSpanish",
                "englishToSpanish", "spanishToEnglish",
                "codeSwitched", "abstention",
            ])

        for fixtureCase in cases {
            let adapter = try await RelationshipProductAdapter(fixtureCase)
            let result = try await LoadDecisionConflicts(
                repository: adapter.store
            ).execute(DecisionConflictsQuery(topicID: adapter.topicID))

            try assert(
                result,
                matches: fixtureCase.expected,
                expectedAbstention: .unsupportedConflict,
                canonicalAbstention: "unsupportedConflict",
                adapter: adapter,
                caseID: fixtureCase.id)
        }
    }

    func testCanonicalChangeSinceCasesTraverseProductPath() async throws {
        let fixture = try RelationshipFixtureDocument.load()
        let cases = fixture.cases.filter { $0.job == "changeSince" }

        XCTAssertEqual(cases.count, 6)
        XCTAssertEqual(
            Set(cases.map(\.relationship)),
            [
                "englishToEnglish", "spanishToSpanish",
                "englishToSpanish", "spanishToEnglish",
                "codeSwitched", "abstention",
            ])

        for fixtureCase in cases {
            let adapter = try await RelationshipProductAdapter(fixtureCase)
            // "Since the last meeting" resolves to the exact baseline meeting
            // before the query exists; when the corpus has no baseline, the
            // anchor is unresolvable and the adapter must abstain.
            let result = try await LoadChangeSince(
                repository: adapter.store
            ).execute(ChangeSinceQuery(
                topicID: adapter.topicID,
                sinceMeetingID: adapter.anchorMeetingID ?? MeetingID()))

            try assert(
                result,
                matches: fixtureCase.expected,
                expectedAbstention: .missingTemporalBaseline,
                canonicalAbstention: "missingTemporalBaseline",
                adapter: adapter,
                caseID: fixtureCase.id)
        }
    }

    private func assert(
        _ result: MeetingMemoryGraphQueryResult,
        matches expected: RelationshipExpected,
        expectedAbstention: MeetingMemoryGraphQueryAbstention,
        canonicalAbstention: String,
        adapter: RelationshipProductAdapter,
        caseID: String
    ) throws {
        switch result {
        case .facts(let page):
            XCTAssertEqual(expected.answerPolicy, "answer", caseID)
            let resultIDs = try page.facts.map { fact in
                guard case .decisionRelationship(let eventID) = fact.id else {
                    throw RelationshipFixtureError.invalid(
                        "\(caseID): product returned a non-relationship fact")
                }
                XCTAssertEqual(fact.kind, .decisionSupersededDecision, caseID)
                return try XCTUnwrap(
                    adapter.externalFactIDByEventID[eventID],
                    "\(caseID): product returned an unmapped relationship")
            }
            let evidenceIDs = try page.facts.flatMap(\.evidence).map { evidence in
                try XCTUnwrap(
                    adapter.externalEvidenceIDBySegmentID[evidence.segmentID],
                    "\(caseID): product returned unmapped transcript evidence")
            }
            XCTAssertEqual(resultIDs, expected.resultIDs, caseID)
            XCTAssertEqual(evidenceIDs, expected.evidenceIDs, caseID)
            XCTAssertTrue(
                Set(expected.forbiddenResultIDs).isDisjoint(with: resultIDs),
                caseID)
        case .abstained(let reason):
            XCTAssertEqual(expected.answerPolicy, "abstain", caseID)
            XCTAssertEqual(expected.abstentionReason, canonicalAbstention, caseID)
            XCTAssertEqual(reason, expectedAbstention, caseID)
            XCTAssertTrue(expected.resultIDs.isEmpty, caseID)
            XCTAssertTrue(expected.evidenceIDs.isEmpty, caseID)
        }
    }
}

/// Seeds one canonical case entirely through public product boundaries:
/// summaries carry the generated observations, explicit confirmations create
/// decisions and their supersessions, and the decision-topic authority links
/// every confirmed decision to the queried subject. Generated facts are seeded
/// as unconfirmed observations only, so nothing needs to "exclude" them — they
/// simply never became truth.
private struct RelationshipProductAdapter {
    let store: MeetingStore
    let topicID: TopicID
    let anchorMeetingID: MeetingID?
    let externalFactIDByEventID: [DecisionEventID: String]
    let externalEvidenceIDBySegmentID: [UUID: String]

    // swiftlint:disable:next function_body_length
    init(_ fixtureCase: RelationshipCase) async throws {
        let store = try MeetingStore.inMemory()
        let namespace = "decision-relationship-product-\(fixtureCase.id)"
        let evidenceByID = Dictionary(uniqueKeysWithValues:
            fixtureCase.corpus.evidence.map { ($0.id, $0) })
        let meetingIDByExternalID = try Dictionary(uniqueKeysWithValues:
            fixtureCase.corpus.meetings.map { meeting in
                (
                    meeting.id,
                    MeetingID(rawValue: try Self.deterministicUUID(
                        namespace: namespace,
                        identifier: meeting.id))
                )
            })
        let segmentIDByEvidenceID = try Dictionary(uniqueKeysWithValues:
            fixtureCase.corpus.evidence.map { evidence in
                (
                    evidence.id,
                    try Self.deterministicUUID(
                        namespace: namespace,
                        identifier: evidence.segmentID)
                )
            })

        var anchorMeetingID: MeetingID?
        for source in fixtureCase.corpus.meetings.sorted(by: {
            $0.sequence < $1.sequence
        }) {
            let meetingID = try Self.required(
                meetingIDByExternalID[source.id],
                "unknown meeting \(source.id)")
            let evidence = fixtureCase.corpus.evidence.filter {
                $0.meetingID == source.id
            }
            let startedAt = Self.baseDate.addingTimeInterval(
                TimeInterval(source.sequence * 100))
            try await store.save(Meeting(
                id: meetingID,
                title: source.title,
                startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(60),
                transcriptRevision: evidence.map(\.transcriptRevision).max() ?? 0))
            if source.sequence == 1 {
                anchorMeetingID = meetingID
            }
        }
        try await store.save(try fixtureCase.corpus.evidence.map { evidence in
            TranscriptSegment(
                id: try Self.required(
                    segmentIDByEvidenceID[evidence.id],
                    "unknown evidence \(evidence.id)"),
                meetingID: try Self.required(
                    meetingIDByExternalID[evidence.meetingID],
                    "unknown evidence meeting \(evidence.meetingID)"),
                channel: .system,
                text: evidence.text,
                language: evidence.language,
                startTime: TimeInterval(evidence.timestampMilliseconds) / 1_000,
                endTime: TimeInterval(evidence.timestampMilliseconds) / 1_000 + 1,
                confidence: 1,
                isFinal: true)
        })

        // Confirmed decision facts become durable decisions. The changeSince
        // corpus expresses its successor only through the confirmed "changes"
        // relation, so that successor is derived from the relation's own
        // fresh evidence.
        var decisions = fixtureCase.corpus.facts.filter {
            $0.kind == "decision" && $0.origin == "confirmed"
        }
        let relation = fixtureCase.corpus.facts.first {
            $0.kind == "relation"
                && $0.origin == "confirmed"
                && ["supersedes", "changes"].contains($0.predicate)
        }
        // A confirmed relation without its baseline decision cannot become
        // authority — exactly the shape of the missing-baseline abstention
        // case, whose change was asserted but never grounded.
        var groundedRelation = relation
        if let candidate = relation, candidate.predicate == "changes" {
            if let baseline = decisions.first(
                where: { $0.objectID == candidate.objectID }) {
                let freshEvidence = candidate.evidenceIDs.filter {
                    !baseline.evidenceIDs.contains($0)
                }
                decisions.append(RelationshipFact(
                    id: "derived-\(candidate.id)",
                    kind: "decision",
                    subjectID: baseline.subjectID,
                    objectID: candidate.subjectID,
                    predicate: "decisionAbout",
                    origin: "confirmed",
                    status: "confirmed",
                    stale: false,
                    evidenceIDs: freshEvidence))
            } else {
                groundedRelation = nil
            }
        }

        var decisionIDByChoice: [String: DecisionID] = [:]
        var observationIDByChoice: [String: SummaryDecisionID] = [:]
        for (index, fact) in decisions.enumerated() {
            let factEvidence = try fact.evidenceIDs.map {
                try Self.required(evidenceByID[$0], "unknown evidence \($0)")
            }
            guard let primary = factEvidence.first else {
                throw RelationshipFixtureError.invalid(
                    "\(fixtureCase.id): decision \(fact.id) has no evidence")
            }
            let meetingID = try Self.required(
                meetingIDByExternalID[primary.meetingID],
                "unknown decision meeting \(primary.meetingID)")
            let observationID = SummaryDecisionID(
                rawValue: try Self.deterministicUUID(
                    namespace: namespace,
                    identifier: "observation-\(fact.id)"))
            _ = try await store.saveSummary(SummaryDraft(
                meetingID: meetingID,
                recipeID: "decision-relationship-product",
                language: primary.language,
                markdown: "# Summary\n\n## Decisions\n- \(primary.text)",
                actionItems: [],
                decisionEvidence: [SummaryDecisionEvidence(
                    id: observationID,
                    sectionOrdinal: 0,
                    bulletOrdinal: 0,
                    sourceTranscriptRevision: primary.transcriptRevision,
                    evidenceSegmentIDs: try fact.evidenceIDs.map {
                        try Self.required(
                            segmentIDByEvidenceID[$0],
                            "unknown decision segment \($0)")
                    })]))
            let decisionID = DecisionID(rawValue: try Self.deterministicUUID(
                namespace: namespace,
                identifier: fact.objectID))
            _ = try await store.confirmDecision(DecisionConfirmation(
                decisionID: decisionID,
                observationID: observationID,
                confirmedAt: Self.baseDate.addingTimeInterval(
                    1_000 + TimeInterval(index))))
            decisionIDByChoice[fact.objectID] = decisionID
            observationIDByChoice[fact.objectID] = observationID
        }

        // The queried subject becomes a topic through the public topic path,
        // and every confirmed decision is linked through the decision-topic
        // authority — the explicit gesture GRAPH-5a demands.
        // A case with no confirmed decision (the unresolvable-baseline shape)
        // still queries a real topic; the label content is immaterial because
        // the adapter abstains before topology is consulted.
        let subject = decisions.first?.subjectID
            ?? "\(fixtureCase.id)-subject"
        let firstEvidence = try Self.required(
            (decisions.first.flatMap { $0.evidenceIDs.first }
                ?? fixtureCase.corpus.evidence.first?.id)
                .flatMap { evidenceByID[$0] },
            "missing subject evidence")
        let topic = try await store.createTopicAndLink(TopicLinkProposal(
            meetingID: try Self.required(
                meetingIDByExternalID[firstEvidence.meetingID],
                "unknown topic meeting"),
            segmentID: try Self.required(
                segmentIDByEvidenceID[firstEvidence.id],
                "unknown topic segment"),
            sourceTranscriptRevision: firstEvidence.transcriptRevision,
            observedLabel: subject,
            language: firstEvidence.language,
            origin: .manual))
        for fact in decisions {
            _ = try await store.confirmDecisionTopicLink(
                DecisionTopicLinkConfirmation(
                    decisionID: try Self.required(
                        decisionIDByChoice[fact.objectID],
                        "unlinked decision \(fact.objectID)"),
                    topicID: topic.topic.id,
                    observationID: try Self.required(
                        observationIDByChoice[fact.objectID],
                        "missing observation \(fact.objectID)"),
                    confirmedAt: Self.baseDate.addingTimeInterval(2_000)))
        }

        // The confirmed relationship: the newer decision explicitly supersedes
        // the older one. Generated relations are never confirmed, so the
        // "guess" cannot exist as authority.
        var externalFactIDByEventID: [DecisionEventID: String] = [:]
        if let relation = groundedRelation {
            let replacedChoice: String
            let successorChoice: String
            if relation.predicate == "supersedes" {
                // Subject/object name the corpus fact ids of the decisions.
                let byFactID = Dictionary(uniqueKeysWithValues:
                    fixtureCase.corpus.facts
                        .filter { $0.kind == "decision" }
                        .map { ($0.id, $0.objectID) })
                replacedChoice = try Self.required(
                    byFactID[relation.objectID], "unknown replaced decision")
                successorChoice = try Self.required(
                    byFactID[relation.subjectID], "unknown successor decision")
            } else {
                // "changes" names the choices directly.
                replacedChoice = relation.objectID
                successorChoice = relation.subjectID
            }
            let eventID = DecisionEventID(rawValue: try Self.deterministicUUID(
                namespace: namespace,
                identifier: "relationship-\(relation.id)"))
            _ = try await store.confirmDecisionRelationship(
                DecisionRelationshipConfirmation(
                    targetDecisionID: try Self.required(
                        decisionIDByChoice[replacedChoice],
                        "replaced decision is not confirmed"),
                    successorDecisionID: try Self.required(
                        decisionIDByChoice[successorChoice],
                        "successor decision is not confirmed"),
                    kind: .supersede,
                    eventID: eventID,
                    confirmedAt: Self.baseDate.addingTimeInterval(3_000)))
            externalFactIDByEventID[eventID] = relation.id
        }

        try await Self.projectGraph(in: store)

        self.store = store
        self.topicID = topic.topic.id
        self.anchorMeetingID = anchorMeetingID
        self.externalFactIDByEventID = externalFactIDByEventID
        self.externalEvidenceIDBySegmentID = Dictionary(
            uniqueKeysWithValues: segmentIDByEvidenceID.map { ($1, $0) })
    }

    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func projectGraph(in store: MeetingStore) async throws {
        let owner = "decision-relationship-conformance-\(UUID().uuidString)"
        let timestamp = Date().addingTimeInterval(10)
        _ = try await store.admitMeetingMemoryGraphMaintenance(at: timestamp)
        guard let job = try await store.claimMeetingMemoryGraphMaintenance(
            owner: owner,
            leaseDuration: 120,
            at: timestamp
        ) else {
            throw RelationshipFixtureError.invalid(
                "graph projection could not be claimed")
        }
        _ = try await ProjectMeetingMemoryGraph(
            store: store,
            now: { timestamp }
        ).all(job: job, owner: owner)
        _ = try await store.completeMeetingMemoryGraphMaintenance(
            job.id,
            owner: owner,
            at: timestamp)
    }

    private static func deterministicUUID(
        namespace: String,
        identifier: String
    ) throws -> UUID {
        let digest = SHA256.hash(data: Data("\(namespace)|\(identifier)".utf8))
        let bytes = Array(digest.prefix(16))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let formatted = """
            \(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\
            \(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\
            \(hex.dropFirst(20).prefix(12))
            """
        guard let uuid = UUID(uuidString: formatted) else {
            throw RelationshipFixtureError.invalid(
                "deterministic identifier failed for \(identifier)")
        }
        return uuid
    }

    private static func required<Value>(
        _ value: Value?,
        _ message: String
    ) throws -> Value {
        guard let value else {
            throw RelationshipFixtureError.invalid(message)
        }
        return value
    }
}

private enum RelationshipFixtureError: Error {
    case invalid(String)
}

private struct RelationshipFixtureDocument: Decodable {
    let kind: String
    let schemaVersion: Int
    let generation: String
    let cases: [RelationshipCase]

    static func load() throws -> RelationshipFixtureDocument {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/MeetingMemoryGraph/public-synthetic-v1.json")
        return try JSONDecoder().decode(
            RelationshipFixtureDocument.self,
            from: try Data(contentsOf: url))
    }
}

private struct RelationshipCase: Decodable {
    let id: String
    let job: String
    let relationship: String
    let corpus: RelationshipCorpus
    let expected: RelationshipExpected
}

private struct RelationshipCorpus: Decodable {
    let meetings: [RelationshipMeeting]
    let evidence: [RelationshipEvidence]
    let facts: [RelationshipFact]
}

private struct RelationshipMeeting: Decodable {
    let id: String
    let sequence: Int
    let title: String
}

private struct RelationshipEvidence: Decodable {
    let id: String
    let meetingID: String
    let segmentID: String
    let text: String
    let language: String
    let timestampMilliseconds: Int
    let transcriptRevision: Int
}

private struct RelationshipFact: Decodable {
    let id: String
    let kind: String
    let subjectID: String
    let objectID: String
    let predicate: String
    let origin: String
    let status: String
    let stale: Bool
    let evidenceIDs: [String]
}

private struct RelationshipExpected: Decodable {
    let answerPolicy: String
    let abstentionReason: String?
    let resultIDs: [String]
    let forbiddenResultIDs: [String]
    let evidenceIDs: [String]
}
