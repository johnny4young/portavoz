import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class MeetingMemoryGraphProductConformanceTests: XCTestCase {
    func testCanonicalCommitmentBlockerCasesTraverseProductPath() async throws {
        let fixture = try GraphProductFixture.load()
        let cases = fixture.cases.filter { $0.job == "commitmentBlockers" }

        XCTAssertEqual(fixture.kind, "meeting-memory-graph-query-fixture")
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.generation, "public-synthetic-v1")
        XCTAssertEqual(cases.count, 6)
        XCTAssertEqual(
            Set(cases.map(\.relationship)),
            [
                "englishToEnglish", "spanishToSpanish",
                "englishToSpanish", "spanishToEnglish",
                "codeSwitched", "abstention",
            ])

        for fixtureCase in cases {
            let adapter = try await GraphProductCaseAdapter(fixtureCase)
            let result = try await LoadCommitmentBlockers(
                repository: adapter.store
            ).execute(CommitmentBlockerQuery(
                commitmentID: adapter.commitmentID))

            try assert(
                result,
                matches: fixtureCase.expected,
                adapter: adapter,
                caseID: fixtureCase.id)
        }
    }

    private func assert(
        _ result: MeetingMemoryGraphQueryResult,
        matches expected: GraphProductExpected,
        adapter: GraphProductCaseAdapter,
        caseID: String
    ) throws {
        switch result {
        case .facts(let page):
            XCTAssertEqual(expected.answerPolicy, "answer", caseID)
            let resultIDs = try page.facts.map { fact in
                guard case .decision(let decisionID) = fact.subject else {
                    throw GraphProductFixtureError.invalid(
                        "\(caseID): product returned a non-decision subject")
                }
                return try XCTUnwrap(
                    adapter.externalFactIDByDecisionID[decisionID.rawValue],
                    "\(caseID): product returned an unmapped blocker fact")
            }
            let evidenceIDs = try page.facts.flatMap(\.evidence).map { evidence in
                return try XCTUnwrap(
                    adapter.externalEvidenceIDBySegmentID[evidence.segmentID],
                    "\(caseID): product returned unmapped evidence")
            }
            XCTAssertEqual(resultIDs, expected.resultIDs, caseID)
            XCTAssertEqual(evidenceIDs, expected.evidenceIDs, caseID)
            XCTAssertTrue(
                Set(expected.forbiddenResultIDs).isDisjoint(with: resultIDs),
                caseID)
        case .abstained(let reason):
            XCTAssertEqual(expected.answerPolicy, "abstain", caseID)
            XCTAssertEqual(expected.abstentionReason, "unsupportedCausalLink", caseID)
            XCTAssertEqual(reason, .unsupportedCausalLink, caseID)
            XCTAssertTrue(expected.resultIDs.isEmpty, caseID)
            XCTAssertTrue(expected.evidenceIDs.isEmpty, caseID)
        }
    }
}

private struct GraphProductCaseAdapter {
    let store: MeetingStore
    let commitmentID: CommitmentID
    let externalFactIDByDecisionID: [UUID: String]
    let externalEvidenceIDBySegmentID: [UUID: String]

    init(_ fixtureCase: GraphProductCase) async throws {
        let store = try MeetingStore.inMemory()
        let namespace = "meeting-memory-graph-\(fixtureCase.id)"
        let meetingIDByExternalID = try Dictionary(uniqueKeysWithValues:
            fixtureCase.corpus.meetings.map { meeting in
                (
                    meeting.id,
                    MeetingID(rawValue: try Self.deterministicUUID(
                        namespace: namespace,
                        identifier: meeting.id))
                )
            })
        let evidenceByID = Dictionary(uniqueKeysWithValues:
            fixtureCase.corpus.evidence.map { ($0.id, $0) })
        let segmentIDByEvidenceID = try Dictionary(uniqueKeysWithValues:
            fixtureCase.corpus.evidence.map { evidence in
                (
                    evidence.id,
                    try Self.deterministicUUID(
                        namespace: namespace,
                        identifier: evidence.segmentID)
                )
            })

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
        }

        let segments = try fixtureCase.corpus.evidence.map { evidence in
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
        }
        try await store.save(segments)

        let commitmentFact = try Self.onlyFact(
            in: fixtureCase,
            where: {
                $0.kind == "commitment"
                    && $0.predicate == "committedTo"
                    && $0.origin == "confirmed"
            },
            named: "confirmed commitment")
        let commitmentEvidence = try commitmentFact.evidenceIDs.map {
            try Self.required(evidenceByID[$0], "unknown commitment evidence \($0)")
        }
        let commitmentMeetingID = try Self.oneMeetingID(
            for: commitmentEvidence,
            meetingIDByExternalID: meetingIDByExternalID)
        let actionItemID = try Self.deterministicUUID(
            namespace: namespace,
            identifier: "action-\(commitmentFact.id)")
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: commitmentMeetingID,
            recipeID: "graph-product-commitment",
            language: commitmentEvidence[0].language,
            markdown: "# Summary\n\n## Action Items\n- \(commitmentEvidence[0].text)",
            actionItems: [ActionItem(
                id: actionItemID,
                text: commitmentEvidence[0].text)],
            actionItemEvidence: [SummaryActionItemEvidence(
                actionItemID: actionItemID,
                sourceTranscriptRevision: commitmentEvidence[0].transcriptRevision,
                evidenceSegmentIDs: try commitmentFact.evidenceIDs.map {
                    try Self.required(
                        segmentIDByEvidenceID[$0],
                        "unknown commitment segment \($0)")
                })]))

        let commitmentID = CommitmentID(rawValue: try Self.deterministicUUID(
            namespace: namespace,
            identifier: commitmentFact.subjectID))
        _ = try await store.confirmCommitment(
            CommitmentConfirmation(
                commitmentID: commitmentID,
                title: commitmentEvidence[0].text,
                origin: .generatedActionItem(actionItemID)),
            at: Date().addingTimeInterval(1))

        let relationshipFact = try Self.onlyFact(
            in: fixtureCase,
            where: {
                $0.kind == "relation"
                    && $0.objectID == commitmentFact.subjectID
                    && $0.subjectID.hasPrefix("decision-")
            },
            named: "decision relationship")
        let decisionEvidenceIDs = relationshipFact.evidenceIDs.filter {
            !commitmentFact.evidenceIDs.contains($0)
        }
        let decisionEvidence = try decisionEvidenceIDs.map {
            try Self.required(evidenceByID[$0], "unknown decision evidence \($0)")
        }
        let decisionMeetingID = try Self.oneMeetingID(
            for: decisionEvidence,
            meetingIDByExternalID: meetingIDByExternalID)
        let observationID = SummaryDecisionID(rawValue: try Self.deterministicUUID(
            namespace: namespace,
            identifier: "observation-\(relationshipFact.id)"))
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: decisionMeetingID,
            recipeID: "graph-product-decision",
            language: decisionEvidence[0].language,
            markdown: "# Summary\n\n## Decisions\n- \(decisionEvidence[0].text)",
            actionItems: [],
            decisionEvidence: [SummaryDecisionEvidence(
                id: observationID,
                sectionOrdinal: 0,
                bulletOrdinal: 0,
                sourceTranscriptRevision: decisionEvidence[0].transcriptRevision,
                evidenceSegmentIDs: try decisionEvidenceIDs.map {
                    try Self.required(
                        segmentIDByEvidenceID[$0],
                        "unknown decision segment \($0)")
                })]))

        let decisionID = DecisionID(rawValue: try Self.deterministicUUID(
            namespace: namespace,
            identifier: relationshipFact.subjectID))
        _ = try await store.confirmDecision(DecisionConfirmation(
            decisionID: decisionID,
            observationID: observationID,
            confirmedAt: Date().addingTimeInterval(2)))

        var externalFactIDByDecisionID: [UUID: String] = [:]
        if relationshipFact.predicate == "blocks",
           relationshipFact.origin == "confirmed" {
            let blockerID = DecisionCommitmentBlockerID(
                rawValue: try Self.deterministicUUID(
                    namespace: namespace,
                    identifier: relationshipFact.id))
            _ = try await store.confirmDecisionCommitmentBlocker(
                DecisionCommitmentBlockerConfirmation(
                    blockerID: blockerID,
                    decisionID: decisionID,
                    commitmentID: commitmentID,
                    evidence: DecisionCommitmentBlockerEvidence(
                        meetingID: decisionMeetingID,
                        sourceTranscriptRevision:
                            decisionEvidence[0].transcriptRevision,
                        segmentIDs: try decisionEvidenceIDs.map {
                            try Self.required(
                                segmentIDByEvidenceID[$0],
                                "unknown blocker segment \($0)")
                        }),
                    confirmedAt: Date().addingTimeInterval(3)))
            externalFactIDByDecisionID[decisionID.rawValue] = relationshipFact.id
        }

        try await projectProductGraph(in: store)

        self.store = store
        self.commitmentID = commitmentID
        self.externalFactIDByDecisionID = externalFactIDByDecisionID
        self.externalEvidenceIDBySegmentID = Dictionary(uniqueKeysWithValues:
            segmentIDByEvidenceID.map { externalID, segmentID in
                (segmentID, externalID)
            })
    }

    private static let baseDate = Date(timeIntervalSince1970: 1_787_100_000)

    private static func onlyFact(
        in fixtureCase: GraphProductCase,
        where predicate: (GraphProductFact) -> Bool,
        named name: String
    ) throws -> GraphProductFact {
        let facts = fixtureCase.corpus.facts.filter(predicate)
        guard facts.count == 1, let fact = facts.first else {
            throw GraphProductFixtureError.invalid(
                "\(fixtureCase.id) requires one \(name)")
        }
        guard !fact.stale else {
            throw GraphProductFixtureError.invalid(
                "\(fixtureCase.id) cannot seed stale authority")
        }
        return fact
    }

    private static func oneMeetingID(
        for evidence: [GraphProductEvidence],
        meetingIDByExternalID: [String: MeetingID]
    ) throws -> MeetingID {
        let externalIDs = Set(evidence.map(\.meetingID))
        guard externalIDs.count == 1, let externalID = externalIDs.first else {
            throw GraphProductFixtureError.invalid(
                "one authority source must belong to one meeting")
        }
        return try required(
            meetingIDByExternalID[externalID],
            "unknown authority meeting \(externalID)")
    }

    private static func required<Value>(
        _ value: Value?,
        _ message: String
    ) throws -> Value {
        guard let value else { throw GraphProductFixtureError.invalid(message) }
        return value
    }

    private static func deterministicUUID(
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
            compact.dropFirst(20).prefix(12),
        ].map(String.init).joined(separator: "-")
        guard let result = UUID(uuidString: value) else {
            throw GraphProductFixtureError.invalid(
                "deterministic identity is invalid")
        }
        return result
    }

}

private func projectProductGraph(in store: MeetingStore) async throws {
    let owner = "graph-product-conformance-\(UUID().uuidString)"
    let timestamp = Date().addingTimeInterval(10)
    _ = try await store.admitMeetingMemoryGraphMaintenance(at: timestamp)
    guard let job = try await store.claimMeetingMemoryGraphMaintenance(
        owner: owner,
        leaseDuration: 120,
        at: timestamp
    ) else {
        throw GraphProductFixtureError.invalid(
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

private struct GraphProductFixture: Decodable {
    let kind: String
    let schemaVersion: Int
    let generation: String
    let cases: [GraphProductCase]

    static func load() throws -> GraphProductFixture {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("MeetingMemoryGraph", isDirectory: true)
            .appendingPathComponent("public-synthetic-v1.json")
        return try JSONDecoder().decode(
            GraphProductFixture.self,
            from: Data(contentsOf: url))
    }
}

private struct GraphProductCase: Decodable {
    let id: String
    let job: String
    let relationship: String
    let corpus: GraphProductCorpus
    let expected: GraphProductExpected
}

private struct GraphProductCorpus: Decodable {
    let evidence: [GraphProductEvidence]
    let facts: [GraphProductFact]
    let meetings: [GraphProductMeeting]
}

private struct GraphProductEvidence: Decodable {
    let id: String
    let language: String
    let meetingID: String
    let segmentID: String
    let text: String
    let timestampMilliseconds: Int
    let transcriptRevision: Int
}

private struct GraphProductFact: Decodable {
    let evidenceIDs: [String]
    let id: String
    let kind: String
    let objectID: String
    let origin: String
    let predicate: String
    let stale: Bool
    let subjectID: String
}

private struct GraphProductMeeting: Decodable {
    let id: String
    let sequence: Int
    let title: String
}

private struct GraphProductExpected: Decodable {
    let abstentionReason: String?
    let answerPolicy: String
    let evidenceIDs: [String]
    let forbiddenResultIDs: [String]
    let resultIDs: [String]
}

private enum GraphProductFixtureError: Error {
    case invalid(String)
}
